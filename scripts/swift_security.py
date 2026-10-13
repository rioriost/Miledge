"""Pinned offline Swift policy checks; not a general-purpose security audit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

import gates


ROOT = Path(__file__).resolve().parents[1]
SEMGREP_VERSION = "1.179.0"
PARSER_RULE = "miledge.swift.parse-inventory"
RULE_IDS = {
    PARSER_RULE,
    *("miledge.swift." + name for name in (
        "no-production-logging", "no-userdefaults-storage", "keychain-when-unlocked",
        "no-legacy-crypto", "no-explicit-gcm-nonce", "authenticated-envelope",
        "no-direct-file-write", "no-custom-network-client", "no-server-trust-bypass",
        "no-unrestricted-ios-clipboard",
    )),
}
RULES = "scripts/semgrep/swift.yml"
FIXTURE = "scripts/semgrep/tests/swift.swift"
NETWORK_POLICY = "(version 1)(allow default)(deny network*)"


def inputs(root: Path) -> dict[str, str]:
    names = (
        RULES, FIXTURE, "scripts/semgrep-requirements.in", "scripts/semgrep-requirements.txt",
        "scripts/swift_security.py", "scripts/gates.py",
    )
    result = {}
    for name in names:
        path = root / name
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise gates.GateError(f"Missing/unsafe Swift security input: {name}.")
        try:
            result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as error:
            raise gates.GateError(f"Cannot read Swift security input {name}: {error}.") from None
    return result


def check_scan(report: dict, root: Path) -> dict:
    if not isinstance(report, dict):
        raise gates.GateError("Swift report must be an object.")
    if report.get("version") != SEMGREP_VERSION or report.get("engine_requested") != "OSS":
        raise gates.GateError("Swift report is not from the pinned Semgrep CE engine.")
    if report.get("errors") != [] or report.get("skipped_rules") != []:
        raise gates.GateError("Swift analysis has errors, skipped rules, or missing execution status.")
    paths = report.get("paths")
    scanned = paths.get("scanned") if isinstance(paths, dict) else None
    if not isinstance(scanned, list) or not all(isinstance(path, str) for path in scanned):
        raise gates.GateError("Swift analysis has no scanned-file inventory.")
    expected = set(gates.source_inventory(root, "app"))
    if len(scanned) != len(set(scanned)) or set(scanned) != expected:
        raise gates.GateError("Swift analysis must scan every production source exactly once.")
    matches = report.get("results")
    if not isinstance(matches, list):
        raise gates.GateError("Swift analysis is missing its results array.")
    parsed = set()
    for match in matches:
        if not isinstance(match, dict) or not isinstance(match.get("check_id"), str) or match["check_id"] not in RULE_IDS:
            raise gates.GateError("Swift analysis has an unknown/malformed rule result.")
        if match["check_id"] != PARSER_RULE:
            raise gates.GateError(f"Blocking Swift policy finding: {match['check_id']}.")
        if not isinstance(match.get("path"), str) or match["path"] not in expected:
            raise gates.GateError("Swift parser inventory includes an unexpected source.")
        if not isinstance(match.get("extra"), dict) or match["extra"].get("severity") != "INFO" or (
            match["extra"].get("engine_kind") != "OSS"
        ):
            raise gates.GateError("Malformed Swift parser inventory result.")
        for name in ("start", "end"):
            position = match.get(name)
            if not isinstance(position, dict) or any(
                type(position.get(key)) is not int or position[key] < minimum
                for key, minimum in (("line", 1), ("col", 1), ("offset", 0))
            ):
                raise gates.GateError("Malformed Swift parser inventory position.")
        if match["end"]["offset"] <= match["start"]["offset"] or (
            match["end"]["line"], match["end"]["col"]
        ) <= (match["start"]["line"], match["start"]["col"]):
            raise gates.GateError("Invalid Swift parser inventory range.")
        parsed.add(match["path"])
    # A file with no import must fail this probe, not be silently called parsed.
    if parsed != expected:
        raise gates.GateError("Missing full Swift parser evidence for production sources.")
    return {"files": len(expected), "securityRules": len(RULE_IDS) - 1, "findings": 0}


def fixture_expectations(root: Path) -> tuple[dict[str, set[int]], dict[str, set[int]]]:
    positive = {rule: set() for rule in RULE_IDS}
    negative = {rule: set() for rule in RULE_IDS}
    for line, text in enumerate((root / FIXTURE).read_text().splitlines(), 1):
        marker = re.fullmatch(r"\s*// (ruleid|ok): (.+)", text)
        if marker:
            for rule in marker[2].split(","):
                rule = rule.strip()
                if rule not in RULE_IDS:
                    raise gates.GateError("Unknown rule in Swift security fixture.")
                (positive if marker[1] == "ruleid" else negative)[rule].add(line + 1)
    if any(not lines for lines in positive.values()) or any(
        not lines for rule, lines in negative.items() if rule != PARSER_RULE
    ):
        raise gates.GateError("Every security rule needs positive and negative fixtures.")
    return positive, negative


def check_rule_tests(report: dict, root: Path) -> dict:
    if not isinstance(report, dict):
        raise gates.GateError("Swift rule test report must be an object.")
    for name in ("config_missing_tests", "config_missing_fixtests", "config_with_errors"):
        if report.get(name) != []:
            raise gates.GateError("Swift rule tests have missing fixtures or configuration errors.")
    if report.get("fixtest_results") != {}:
        raise gates.GateError("Unexpected Swift autofix test results.")
    results = report.get("results")
    if not isinstance(results, dict) or len(results) != 1:
        raise gates.GateError("Swift rule tests must execute the one approved ruleset.")
    rule_path, result = next(iter(results.items()))
    if gates.source_path(rule_path, root) != RULES:
        raise gates.GateError("Swift rule tests used a different ruleset.")
    checks = result.get("checks") if isinstance(result, dict) else None
    if not isinstance(checks, dict) or set(checks) != RULE_IDS:
        raise gates.GateError("Swift rule tests omitted or added rules.")
    positive, negative = fixture_expectations(root)
    for rule, check in checks.items():
        if not isinstance(check, dict) or check.get("passed") is not True or check.get("errors") != []:
            raise gates.GateError(f"Swift rule test failed: {rule}.")
        matches = check.get("matches")
        if not isinstance(matches, dict) or len(matches) != 1:
            raise gates.GateError("Swift rule tests have missing/extra fixture files.")
        path, match = next(iter(matches.items()))
        if gates.source_path(path, root) != FIXTURE or not isinstance(match, dict):
            raise gates.GateError("Swift rule tests used an unexpected fixture.")
        for name in ("expected_lines", "reported_lines"):
            lines = match.get(name)
            if not isinstance(lines, list) or any(type(line) is not int or line < 1 for line in lines):
                raise gates.GateError("Malformed Swift rule test match lines.")
            if len(lines) != len(set(lines)) or set(lines) != positive[rule]:
                raise gates.GateError(f"Swift rule fixture detection mismatch: {rule}.")
        if set(match["reported_lines"]) & negative[rule]:
            raise gates.GateError(f"Swift rule false positive: {rule}.")
    return {
        "rules": len(checks), "positiveCases": sum(map(len, positive.values())),
        "negativeCases": sum(map(len, negative.values())),
    }


def execute(scanner: Path, arguments: list[str], root: Path, temporary: Path) -> dict:
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        raise gates.GateError("Swift offline analysis requires macOS with sandbox-exec.")
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(temporary), "TMPDIR": str(temporary),
        "SEMGREP_SEND_METRICS": "off", "SEMGREP_ENABLE_VERSION_CHECK": "0",
    }
    command = [
        "/usr/bin/sandbox-exec", "-p", NETWORK_POLICY, str(scanner.resolve()), "scan",
        "--oss-only", "--metrics=off", "--disable-version-check", "--disable-nosem",
        "--no-git-ignore", "--no-rewrite-rule-ids", "--project-root=.", "--jobs=2",
        "--strict", "--timeout=10", "--json", "--config", RULES, *arguments,
    ]
    try:
        process = subprocess.Popen(
            command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        raise gates.GateError(f"Cannot start Swift scanner: {error}.") from None
    try:
        stdout, _ = process.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise gates.GateError("Swift scanner timed out; no successful evidence was created.") from None
    if process.returncode != 0:
        raise gates.GateError(f"Swift scanner failed with exit status {process.returncode}.")
    raw = temporary / "result.json"
    raw.write_bytes(stdout)
    return gates.load_json(raw)


def scan(root: Path, scanner: Path, directory: Path, *, attest: bool = False) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    evidence_path = directory / "security-swift.json"
    evidence_path.unlink(missing_ok=True)
    initial_sources, initial_inputs = gates.source_inventory(root, "app"), inputs(root)
    with tempfile.TemporaryDirectory(prefix="swift-scan-", dir=directory.resolve()) as name:
        temporary = Path(name)
        rule_tests = execute(scanner, ["--test", FIXTURE], root, temporary)
        tested = check_rule_tests(rule_tests, root)
        report = execute(scanner, sorted(initial_sources), root, temporary)
        analysis = check_scan(report, root)
    if gates.source_inventory(root, "app") != initial_sources or inputs(root) != initial_inputs:
        raise gates.GateError("Swift sources or rules changed during analysis.")
    # Successful artifacts retain parser positions and hashes, never source snippets.
    clean_report = {
        key: report[key] for key in ("version", "engine_requested", "errors", "skipped_rules")
    }
    clean_report["paths"] = {"scanned": report["paths"]["scanned"]}
    clean_report["results"] = [
        {key: match[key] for key in ("check_id", "path")} | {
            name: {key: match[name][key] for key in ("line", "col", "offset")}
            for name in ("start", "end")
        } | {
            "extra": {"severity": match["extra"]["severity"], "engine_kind": "OSS"}
        } for match in report["results"]
    ]
    checks = next(iter(rule_tests["results"].values()))["checks"]
    clean_tests = {
        key: rule_tests[key] for key in (
            "config_missing_tests", "config_missing_fixtests", "config_with_errors", "fixtest_results"
        )
    }
    clean_tests["results"] = {RULES: {"checks": {
        rule: {"passed": True, "errors": [], "matches": {FIXTURE: {
            key: next(iter(check["matches"].values()))[key]
            for key in ("expected_lines", "reported_lines")
        }}}
        for rule, check in checks.items()
    }}}
    report_path, tests_path = directory / "swift-semgrep.json", directory / "swift-rule-tests.json"
    report_path.write_text(json.dumps(clean_report, sort_keys=True) + "\n")
    tests_path.write_text(json.dumps(clean_tests, sort_keys=True) + "\n")
    if attest:
        evidence = {
            "schemaVersion": 1, "provenance": gates.provenance(root),
            "scanner": {"name": "Semgrep CE", "version": SEMGREP_VERSION},
            "networkPolicy": NETWORK_POLICY, "sources": initial_sources, "inputs": initial_inputs,
            "reportSHA256": hashlib.sha256(report_path.read_bytes()).hexdigest(),
            "ruleTestsSHA256": hashlib.sha256(tests_path.read_bytes()).hexdigest(),
            "analysis": analysis, "ruleTests": tested,
        }
        evidence_path.write_text(json.dumps(evidence, sort_keys=True) + "\n")
    return {"analysis": analysis, "ruleTests": tested, "releaseAttestation": attest}


def verify_evidence(root: Path, directory: Path, current: dict) -> None:
    evidence = gates.load_json(directory / "security-swift.json")
    if type(evidence.get("schemaVersion")) is not int or evidence["schemaVersion"] != 1:
        raise gates.GateError("Unsupported Swift security evidence format.")
    if evidence.get("provenance") != current:
        raise gates.GateError("Swift security evidence is stale or from another commit/run.")
    if evidence.get("scanner") != {"name": "Semgrep CE", "version": SEMGREP_VERSION}:
        raise gates.GateError("Swift security evidence uses an unapproved scanner.")
    if evidence.get("networkPolicy") != NETWORK_POLICY:
        raise gates.GateError("Swift security evidence lacks enforced offline execution.")
    if evidence.get("sources") != gates.source_inventory(root, "app") or evidence.get("inputs") != inputs(root):
        raise gates.GateError("Swift security source/rule/tool input digest mismatch.")
    reports = {}
    for name, digest in (("swift-semgrep.json", "reportSHA256"), ("swift-rule-tests.json", "ruleTestsSHA256")):
        path = directory / name
        if not path.is_file() or path.is_symlink():
            raise gates.GateError(f"Missing/unsafe Swift security report: {name}.")
        if evidence.get(digest) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise gates.GateError("Swift security report digest mismatch.")
        reports[name] = gates.load_json(path)
    if evidence.get("analysis") != check_scan(reports["swift-semgrep.json"], root) or (
        evidence.get("ruleTests") != check_rule_tests(reports["swift-rule-tests.json"], root)
    ):
        raise gates.GateError("Swift security evidence summaries disagree with the raw reports.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--semgrep", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/gates")
    parser.add_argument("--attest", action="store_true")
    args = parser.parse_args()
    try:
        print(json.dumps(scan(ROOT, args.semgrep, args.output, attest=args.attest), sort_keys=True))
    except (gates.GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Swift security gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
