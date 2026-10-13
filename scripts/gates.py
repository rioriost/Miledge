"""Fail-closed coverage, security analysis, and source-bound release gates.

Coverage inventories every checked-in Swift file under Sources/ and, for app
schemes, App/. Generated DerivedData/.build files and test roots are outside that
inventory; there is no UI, storage, filename, or percentage exemption.
"""

from __future__ import annotations

import argparse
from datetime import date
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parents[1]
APP_PRODUCT_NAME = "Miledge"
LIBRARIES = ("MiledgeDomain", "MiledgeStorage", "MiledgeApplication")
CODEQL_VERSION = "2.27.2"
CODEQL_ACTION = "24c54180a607b1449ed407dd24f251e4e9147c8d"  # v4.38.3
# Verified against the compiler matrix checked in at codeql-cli/v2.27.2:
# https://github.com/github/codeql/blob/codeql-cli/v2.27.2/docs/codeql/reusables/supported-versions-compilers.rst
SWIFT_MIN = (5, 4)
SWIFT_MAX = (6, 3)
READINESS_CHECKS = (
    "portableEncryptedBackup", "translations", "hardwareValidation",
    "accessibility", "conflictRecovery",
)
SECURITY_REVIEW_SCOPES = (
    "ios-masvs-storage-crypto", "ios-masvs-auth-network",
    "ios-masvs-platform-code-resilience-privacy",
    "macos-keychain-access-groups", "macos-sandbox-entitlements",
    "macos-authentication-lock", "macos-encrypted-files-paths",
    "clipboard-logs", "sync-conflict-backup-recovery", "signed-device-distribution",
    "swift-parser-cross-function-cross-file-gaps",
)
INTERACTION_SCHEMES = {"ios": "MiledgeInteraction-iOS", "macos": "MiledgeInteraction-macOS"}
XCRESULT_SCHEMA = "0.4.0"


class GateError(Exception):
    pass


def integer(value: object, label: str) -> int:
    if type(value) is not int or value < 0:
        raise GateError(f"{label} must be a nonnegative integer.")
    return value


def load_json(path: Path) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise GateError(f"Duplicate JSON key: {key}.")
            result[key] = value
        return result

    try:
        result = json.loads(
            path.read_text(), object_pairs_hook=pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(GateError(f"Invalid JSON: {value}.")),
        )
    except (OSError, ValueError) as error:
        raise GateError(f"Cannot read JSON report {path.name}: {error}.") from None
    if not isinstance(result, dict):
        raise GateError(f"{path.name} must contain a JSON object.")
    return result


def source_inventory(root: Path, scope: str) -> dict[str, str]:
    if scope not in ("app", "package"):
        raise GateError("Coverage scope must be app or package.")
    root = root.resolve()
    result = {}
    for name in (("Sources", "App") if scope == "app" else ("Sources",)):
        directory = root / name
        if not directory.is_dir() or directory.is_symlink():
            raise GateError(f"Missing first-party source directory: {name}.")
        for entry in directory.rglob("*"):
            if entry.is_symlink():
                raise GateError(f"Source symlinks are not permitted: {entry.relative_to(root)}.")
        for path in sorted(directory.rglob("*.swift")):
            resolved = path.resolve()
            if not resolved.is_relative_to(directory.resolve()) or path.is_symlink():
                raise GateError(f"Source symlinks are not permitted: {path.relative_to(root)}.")
            relative = path.relative_to(root).as_posix()
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    for library in LIBRARIES:
        if not any(path.startswith(f"Sources/{library}/") for path in result):
            raise GateError(f"Missing library source target: {library}.")
    if scope == "app" and not any(path.startswith("App/") for path in result):
        raise GateError("No app source files were inventoried.")
    return result


def source_path(value: object, root: Path) -> str | None:
    if not isinstance(value, str) or not value or "\\" in value:
        raise GateError("A source report path is missing or invalid.")
    parsed = urlparse(value)
    if parsed.scheme:
        if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
            raise GateError("Only local source paths are permitted.")
        value = unquote(parsed.path)
    path = Path(value)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return None
    if ".." in path.parts:
        raise GateError("Source report paths must not traverse parent directories.")
    return path.as_posix()


def counts(entry: dict, covered_key: str, total_key: str) -> tuple[int, int]:
    if not isinstance(entry, dict):
        raise GateError("Malformed executable-line coverage entry.")
    covered = integer(entry.get(covered_key), covered_key)
    total = integer(entry.get(total_key), total_key)
    if covered > total:
        raise GateError("Covered executable lines exceed total executable lines.")
    if "lineCoverage" in entry:
        ratio = entry["lineCoverage"]
        if type(ratio) not in (int, float) or not math.isfinite(ratio) or not 0 <= ratio <= 1:
            raise GateError("Malformed lineCoverage ratio.")
        if total and abs(ratio - covered / total) > 0.000001:
            raise GateError("lineCoverage disagrees with executable-line counts.")
    if "percent" in entry:
        percent = entry["percent"]
        if type(percent) not in (int, float) or not math.isfinite(percent) or not 0 <= percent <= 100:
            raise GateError("Malformed executable-line percentage.")
        if total and abs(percent - 100 * covered / total) > 0.000001:
            raise GateError("Percentage disagrees with executable-line counts.")
    return covered, total


def check_coverage(
    report: dict, root: Path, *, format: str, scope: str,
    expected_targets: tuple[str, ...] = (),
) -> dict:
    inventory = source_inventory(root, scope)
    measured = {}
    targets_seen = set()

    def record(path, covered, total):
        relative = source_path(path, root)
        if relative not in inventory:
            if relative and relative.startswith(("App/", "Sources/")):
                raise GateError(f"Report includes a stale or unknown source file: {relative}.")
            return
        if relative in measured:
            raise GateError(f"Duplicate first-party coverage entry: {relative}.")
        if total == 0:
            raise GateError(f"Uninstrumented/empty first-party source coverage: {relative}.")
        measured[relative] = (covered, total)

    if format == "xccov":
        targets = report.get("targets")
        if not isinstance(targets, list) or not targets:
            raise GateError("Missing coverage targets.")
        for target in targets:
            if not isinstance(target, dict) or not isinstance(target.get("name"), str):
                raise GateError("Malformed coverage target.")
            name = target["name"].removesuffix(".app")
            if name in targets_seen:
                raise GateError(f"Duplicate coverage target: {name}.")
            targets_seen.add(name)
            target_counts = counts(target, "coveredLines", "executableLines")
            files = target.get("files")
            if not isinstance(files, list):
                raise GateError(f"Missing source coverage report for target {name}.")
            subtotal = [0, 0]
            for file in files:
                covered, total = counts(file, "coveredLines", "executableLines")
                subtotal[0] += covered
                subtotal[1] += total
                record(file.get("path"), covered, total)
            if tuple(subtotal) != target_counts:
                raise GateError(f"Target totals disagree with its source files: {name}.")
        missing_targets = set(expected_targets) - targets_seen
        if missing_targets:
            raise GateError("Missing coverage target(s): " + ", ".join(sorted(missing_targets)))
    elif format == "llvm":
        if report.get("type") != "llvm.coverage.json.export":
            raise GateError("Not an llvm-cov JSON export.")
        version = report.get("version")
        # Apple LLVM 21 emits 3.0.1; both supported schemas retain integer
        # summary.lines and totals.lines counts (not averaged percentages).
        if not isinstance(version, str) or not re.fullmatch(r"[23]\.[0-9]+\.[0-9]+", version):
            raise GateError("Unsupported llvm-cov JSON schema version.")
        data = report.get("data")
        if not isinstance(data, list) or not data:
            raise GateError("Empty llvm-cov data.")
        for unit in data:
            if not isinstance(unit, dict) or not isinstance(unit.get("files"), list):
                raise GateError("Missing llvm-cov source report.")
            totals = unit.get("totals", {})
            if not isinstance(totals, dict):
                raise GateError("Missing llvm-cov totals.")
            unit_counts = counts(totals.get("lines"), "covered", "count")
            if unit_counts[1] == 0:
                raise GateError("Empty llvm-cov executable-line total.")
            subtotal = [0, 0]
            for file in unit["files"]:
                if not isinstance(file, dict) or not isinstance(file.get("summary"), dict):
                    raise GateError("Missing llvm-cov file summary.")
                covered, total = counts(file["summary"].get("lines"), "covered", "count")
                subtotal[0] += covered
                subtotal[1] += total
                record(file.get("filename"), covered, total)
            if tuple(subtotal) != unit_counts:
                raise GateError("llvm-cov totals disagree with source files.")
    else:
        raise GateError("Unsupported coverage report format.")
    missing = set(inventory) - set(measured)
    if missing:
        raise GateError("Missing/uninstrumented source coverage: " + ", ".join(sorted(missing)))
    covered = sum(pair[0] for pair in measured.values())
    total = sum(pair[1] for pair in measured.values())
    if total == 0:
        raise GateError("Empty first-party executable-line total.")
    result = {
        "coveredLines": covered, "executableLines": total,
        "lineCoverage": covered / total, "files": len(measured),
    }
    # Integer cross-multiplication prevents rounding 89.999% to a passing 90%.
    if covered * 100 < total * 90:
        raise GateError(f"Coverage {covered}/{total} ({covered / total:.6%}) is below 90%.")
    return result


def check_swift_version(output: str) -> str:
    match = re.search(r"\bSwift version ([0-9]+)\.([0-9]+)(?:\.([0-9]+))?\b", output)
    if not match:
        raise GateError("Cannot determine the Swift compiler version.")
    pair = (int(match[1]), int(match[2]))
    if not SWIFT_MIN <= pair <= SWIFT_MAX:
        raise GateError(
            f"Swift {match[1]}.{match[2]} is unsupported by pinned CodeQL {CODEQL_VERSION} "
            "(official support: Swift 5.4–6.3). Update and verify the scanner; do not bypass."
        )
    return match[0].removeprefix("Swift version ")


def security_severity(value: object) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise GateError("Malformed security-severity.")
    try:
        severity = Decimal(str(value))
    except InvalidOperation:
        raise GateError("Malformed security-severity.") from None
    if not severity.is_finite() or not Decimal(0) <= severity <= Decimal(10):
        raise GateError("security-severity must be finite and between 0 and 10.")
    return severity


def check_sarif(report: dict, language: str) -> dict:
    if report.get("version") != "2.1.0":
        raise GateError("Unsupported SARIF version.")
    runs = report.get("runs")
    if not isinstance(runs, list) or not runs:
        raise GateError("SARIF has no analysis runs; missing results are not success.")
    findings = 0
    for run in runs:
        if not isinstance(run, dict):
            raise GateError("Malformed SARIF run.")
        tool = run.get("tool", {})
        driver = tool.get("driver", {}) if isinstance(tool, dict) else {}
        if not isinstance(driver, dict):
            raise GateError("Malformed SARIF tool.")
        if driver.get("name") != "CodeQL" or driver.get("semanticVersion") != CODEQL_VERSION:
            raise GateError("SARIF is not from the pinned CodeQL version.")
        rules = driver.get("rules")
        if not isinstance(rules, list) or not rules:
            raise GateError("SARIF has no rule inventory; queries may not have executed.")
        by_id = {}
        for rule in rules:
            if not isinstance(rule, dict) or not isinstance(rule.get("id"), str):
                raise GateError("Malformed SARIF rule.")
            rule_id = rule["id"]
            if rule_id in by_id:
                raise GateError("Duplicate SARIF rule.")
            by_id[rule_id] = rule
            properties = rule.get("properties", {})
            if not isinstance(properties, dict):
                raise GateError("Malformed SARIF rule properties.")
            tags = properties.get("tags", [])
            if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
                raise GateError("Malformed SARIF rule tags.")
            if "security-severity" in properties:
                security_severity(properties["security-severity"])
            defaults = rule.get("defaultConfiguration", {})
            if not isinstance(defaults, dict):
                raise GateError("Malformed SARIF rule configuration.")
        if not any(rule_id.startswith(language + "/") for rule_id in by_id):
            raise GateError(f"Missing {language} CodeQL queries.")
        invocations = run.get("invocations")
        if not isinstance(invocations, list) or not invocations:
            raise GateError("SARIF has no scanner invocation provenance.")
        for invocation in invocations:
            if not isinstance(invocation, dict) or invocation.get("executionSuccessful") is not True:
                raise GateError("CodeQL invocation failed or omitted its status.")
            if "exitCode" in invocation and (
                type(invocation["exitCode"]) is not int or invocation["exitCode"] != 0
            ):
                raise GateError("CodeQL invocation has a nonzero/invalid exit code.")
            for key in ("toolExecutionNotifications", "toolConfigurationNotifications"):
                notifications = invocation.get(key, [])
                if not isinstance(notifications, list):
                    raise GateError("Malformed scanner notifications.")
                for notification in notifications:
                    if not isinstance(notification, dict):
                        raise GateError("Malformed scanner notification.")
                    if notification.get("level", "warning") not in ("note", "warning", "error"):
                        raise GateError("Malformed scanner notification level.")
                    if notification.get("level", "warning") in ("error", "warning"):
                        raise GateError("CodeQL reported a scanner/extraction warning or error.")
        results = run.get("results")
        if not isinstance(results, list):
            raise GateError("SARIF is missing its results array.")
        for result in results:
            if not isinstance(result, dict):
                raise GateError("Malformed SARIF finding.")
            rule_id = result.get("ruleId")
            if rule_id not in by_id:
                raise GateError("SARIF finding has no matching rule.")
            rule = by_id[rule_id]
            if "ruleIndex" in result:
                index = integer(result["ruleIndex"], "ruleIndex")
                if index >= len(rules) or rules[index]["id"] != rule_id:
                    raise GateError("SARIF finding has an invalid ruleIndex.")
            properties = rule.get("properties", {})
            result_properties = result.get("properties", {})
            if not isinstance(properties, dict) or not isinstance(result_properties, dict):
                raise GateError("Malformed SARIF properties.")
            tags = properties.get("tags", [])
            if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
                raise GateError("Malformed SARIF security tags.")
            severities = [
                security_severity(props["security-severity"])
                for props in (properties, result_properties) if "security-severity" in props
            ]
            level = result.get("level", rule.get("defaultConfiguration", {}).get("level", "warning"))
            if level not in ("none", "note", "warning", "error"):
                raise GateError("Malformed SARIF finding level.")
            # Suppression, baselineState, kind, or result-level severity cannot
            # exempt a rule-level security finding from the release decision.
            if (severities and max(severities) >= 4) or (
                "security" in tags and (level == "error" or not severities)
            ):
                raise GateError(f"Blocking security finding: {rule_id}.")
            findings += 1
    return {"runs": len(runs), "findings": findings, "language": language}


def check_extraction(rows: list, root: Path, language: str) -> dict:
    if not isinstance(rows, list):
        raise GateError("Extraction inventory must be a JSON row array.")
    if language == "swift":
        expected = set(source_inventory(root, "app"))
    elif language == "python":
        expected = {
            path.relative_to(root).as_posix() for path in (root / "scripts").rglob("*.py")
            if "tests" not in path.relative_to(root).parts
        }
    else:
        raise GateError("Unsupported extraction language.")
    actual = set()
    for row in rows:
        if not isinstance(row, list) or len(row) != 1:
            raise GateError("Malformed CodeQL source inventory row.")
        relative = source_path(row[0], root)
        if relative:
            actual.add(relative)
    if not expected or expected - actual:
        raise GateError("Missing first-party CodeQL extraction: " + ", ".join(sorted(expected - actual)))
    return {"files": len(expected), "language": language}


def interaction_sources(root: Path) -> dict[str, str]:
    result = source_inventory(root, "app")
    for name in ("InteractionHost", "InteractionTests"):
        directory = root / name
        if not directory.is_dir() or directory.is_symlink():
            raise GateError(f"Missing synthetic interaction source directory: {name}.")
        if any(path.is_symlink() for path in directory.rglob("*")):
            raise GateError("Interaction source symlinks are not permitted.")
        files = sorted(directory.rglob("*.swift"))
        if not files:
            raise GateError(f"Missing synthetic interaction Swift sources: {name}.")
        for path in files:
            if path.is_symlink() or not path.resolve().is_relative_to(directory.resolve()):
                raise GateError("Interaction source symlinks are not permitted.")
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def check_interactions(summary: dict, tests: dict, availability: dict, scheme: str) -> dict:
    """Require real, wholly passing XCUITests, not merely an exit-zero build."""
    if not all(isinstance(report, dict) for report in (summary, tests, availability)):
        raise GateError("Missing or malformed structured interaction reports.")
    if scheme not in INTERACTION_SCHEMES.values():
        raise GateError("Unapproved interaction scheme.")
    if summary.get("title") != f"Test - {scheme}" or summary.get("result") != "Passed":
        raise GateError("Interaction summary is not a passed run of the required scheme.")
    counts = {
        name: integer(summary.get(name), name) for name in (
            "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures",
        )
    }
    total = counts["totalTestCount"]
    if total == 0 or counts["passedTests"] != total or any(
        counts[name] for name in ("failedTests", "skippedTests", "expectedFailures")
    ):
        raise GateError("Interaction tests must execute nonzero tests with no failures or skips.")
    for name in ("testFailures", "runtimeWarnings"):
        if not isinstance(summary.get(name), list) or summary[name]:
            raise GateError(f"Interaction results contain missing or nonempty {name}.")
    if availability.get("hasTestResults") is not True or availability.get("hasCoverage") is not False:
        raise GateError("Interaction bundle must contain test results and no coverage profiles.")
    devices = tests.get("devices")
    if not isinstance(devices, list) or not devices:
        raise GateError("Interaction result has no executed device inventory.")
    configurations = summary.get("devicesAndConfigurations")
    if not isinstance(configurations, list) or not configurations:
        raise GateError("Interaction summary has no device execution provenance.")
    device_ids = set()
    for device in devices:
        if not isinstance(device, dict) or not isinstance(device.get("deviceId"), str):
            raise GateError("Malformed interaction device inventory.")
        if not device["deviceId"] or device["deviceId"] in device_ids:
            raise GateError("Missing or duplicate interaction device identifier.")
        device_ids.add(device["deviceId"])
    device_total = 0
    for configuration in configurations:
        if not isinstance(configuration, dict):
            raise GateError("Malformed interaction device execution.")
        device = configuration.get("device")
        if not isinstance(device, dict) or device.get("deviceId") not in device_ids:
            raise GateError("Interaction executed device disagrees with the test inventory.")
        passed = integer(configuration.get("passedTests"), "device passedTests")
        if any(integer(configuration.get(name), name) for name in (
            "failedTests", "skippedTests", "expectedFailures",
        )):
            raise GateError("Interaction device has failed, skipped, or expected-failure tests.")
        device_total += passed
    if device_total != total:
        raise GateError("Interaction device totals disagree with the executed test count.")
    nodes = tests.get("testNodes")
    if not isinstance(nodes, list) or not nodes:
        raise GateError("Interaction report is missing its executed test tree.")
    executed = set()
    allowed_types = {
        "Test Plan", "UI test bundle", "Test Suite", "Test Case", "Device",
        "Test Plan Configuration", "Arguments", "Repetition", "Test Case Run",
        "Source Code Reference", "Attachment", "Expression", "Test Value",
    }

    def walk(node, ui_bundle=False):
        if not isinstance(node, dict) or node.get("nodeType") not in allowed_types:
            raise GateError("Interaction test tree contains a warning, skip, failure, or unknown node.")
        if not isinstance(node.get("name"), str) or not node["name"]:
            raise GateError("Malformed interaction test node name.")
        kind = node["nodeType"]
        if "result" in node and node["result"] != "Passed":
            raise GateError("Interaction test tree contains a non-passing result.")
        ui_bundle = ui_bundle or kind == "UI test bundle"
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not ui_bundle or node.get("result") != "Passed" or not isinstance(identifier, str) or not identifier:
                raise GateError("Interaction tests must be identifiable, passed XCUITest cases.")
            if identifier in executed:
                raise GateError("Duplicate interaction test case.")
            executed.add(identifier)
        children = node.get("children", [])
        if not isinstance(children, list):
            raise GateError("Malformed interaction test tree children.")
        for child in children:
            walk(child, ui_bundle)

    for node in nodes:
        walk(node)
    if len(executed) != total:
        raise GateError("Interaction test tree disagrees with the nonzero executed test count.")
    return {"executedTests": total, "scheme": scheme, "runtimeWarnings": 0, "skippedTests": 0}


def provenance(root: Path) -> dict:
    sha = os.environ.get("GITHUB_SHA", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not run_id.isascii() or not run_id.isdigit():
        raise GateError("Missing GitHub commit/run provenance.")
    if not attempt.isascii() or not attempt.isdigit() or int(attempt) < 1:
        raise GateError("Missing GitHub run attempt provenance.")
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        raise GateError("Cannot verify the checked-out commit.") from None
    if head != sha:
        raise GateError("Checked-out commit does not match GITHUB_SHA.")
    return {"commit": sha, "runId": run_id, "runAttempt": attempt}


def readiness_digest(root: Path) -> str:
    """Fingerprint release inputs without self-referencing the attestation file."""
    paths = set()
    for name in (
        "Sources", "App", "Tests", "AppTests", "InteractionHost", "InteractionTests",
        "scripts", ".github/workflows",
    ):
        directory = root / name
        if not directory.is_dir():
            raise GateError(f"Missing readiness input directory: {name}.")
        for path in directory.rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts or path.name == "codeql-pack.lock.yml":
                continue
            if path.is_symlink() or not path.resolve().is_relative_to(directory.resolve()):
                raise GateError("Readiness input symlink is not permitted.")
            paths.add(path)
    for name in ("Package.swift", "project.yml"):
        path = root / name
        if not path.is_file():
            raise GateError(f"Missing readiness input: {name}.")
        paths.add(path)
    manifest = {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(paths)
    }
    return hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()


def check_readiness(path: Path, root: Path) -> None:
    evidence = load_json(path)
    if type(evidence.get("schemaVersion")) is not int or evidence["schemaVersion"] != 1:
        raise GateError("Unsupported release-readiness evidence format.")
    if evidence.get("reviewedSourceDigest") != readiness_digest(root):
        raise GateError("Release-readiness attestation must match all current release inputs.")
    checks = evidence.get("checks")
    if not isinstance(checks, dict):
        raise GateError("Missing release-readiness checks.")
    for name in READINESS_CHECKS:
        check = checks.get(name)
        if not isinstance(check, dict) or check.get("status") != "passed":
            raise GateError(f"Release readiness still blocked: {name}.")
        detail = check.get("evidence")
        if not isinstance(detail, str) or not detail.strip():
            raise GateError(f"Missing real release-readiness evidence: {name}.")


def check_security_review(root: Path) -> None:
    """Require an independently signed assessment, not a self-authored pass flag."""
    path = root / "docs/release-security-review.json"
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise GateError("Unsafe independent security review manifest.")
    review = load_json(path)
    if type(review.get("schemaVersion")) is not int or review["schemaVersion"] != 1:
        raise GateError("Unsupported independent security review format.")
    if review.get("status") != "approved":
        raise GateError("Independent security review is still blocked.")
    if review.get("reviewedSourceDigest") != readiness_digest(root):
        raise GateError("Independent security review does not match current release inputs.")
    reviewer = review.get("reviewer")
    trusted_reviewer = os.environ.get("SECURITY_REVIEWER_ID", "").strip()
    if not isinstance(reviewer, dict) or not trusted_reviewer or reviewer.get("identity") != trusted_reviewer:
        raise GateError("Independent review is not from the configured reviewer.")
    authors = review.get("implementationAuthors")
    if not isinstance(authors, list) or not authors or any(
        not isinstance(author, str) or not author.strip() for author in authors
    ) or trusted_reviewer.casefold() in {author.casefold() for author in authors}:
        raise GateError("Security reviewer must be independent of implementation authors.")
    for name in ("independenceEvidence", "residualRiskAcceptance"):
        if not isinstance(review.get(name), str) or not review[name].strip():
            raise GateError(f"Independent review is missing {name}.")
    try:
        reviewed = date.fromisoformat(review["reviewDate"])
    except (KeyError, ValueError, TypeError):
        raise GateError("Independent review needs a valid review date.") from None
    if reviewed > date.today():
        raise GateError("Independent review date is in the future.")
    scopes = review.get("scopes")
    if not isinstance(scopes, dict) or set(scopes) != set(SECURITY_REVIEW_SCOPES):
        raise GateError("Independent review must cover iOS MASVS/MASTG, macOS, and scanner gaps.")
    for scope, assessment in scopes.items():
        if not isinstance(assessment, dict) or assessment.get("status") != "reviewed" or (
            not isinstance(assessment.get("evidence"), str) or not assessment["evidence"].strip()
        ):
            raise GateError(f"Independent security scope is incomplete: {scope}.")
    findings = review.get("findings")
    if not isinstance(findings, list):
        raise GateError("Independent review needs an explicit findings inventory.")
    identifiers = set()
    for finding in findings:
        if not isinstance(finding, dict) or not isinstance(finding.get("id"), str) or not finding["id"].strip():
            raise GateError("Malformed independent security finding.")
        if finding["id"] in identifiers or finding.get("severity") not in ("critical", "high", "medium", "low"):
            raise GateError("Duplicate or invalid independent security finding.")
        identifiers.add(finding["id"])
        if finding.get("status") != "resolved" or not isinstance(finding.get("resolutionEvidence"), str) or (
            not finding["resolutionEvidence"].strip()
        ):
            raise GateError(f"Unresolved independent security finding: {finding['id']}.")
    report = review.get("report")
    relative = source_path(report.get("path"), root) if isinstance(report, dict) else None
    if not relative or not relative.startswith("docs/security-reviews/"):
        raise GateError("Independent review report must be under docs/security-reviews/.")
    report_path = root / relative
    if not report_path.is_file() or report_path.is_symlink() or not report_path.resolve().is_relative_to(
        root.resolve()
    ) or any(parent.is_symlink() for parent in report_path.parents if parent.is_relative_to(root)):
        raise GateError("Missing/unsafe independent security review report.")
    if report.get("sha256") != hashlib.sha256(report_path.read_bytes()).hexdigest():
        raise GateError("Independent security review report digest mismatch.")
    public_key = os.environ.get("SECURITY_REVIEW_PUBLIC_KEY", "")
    signature = root / "docs/release-security-review.sig"
    if not public_key.strip() or not signature.is_file() or signature.is_symlink() or path.is_symlink():
        raise GateError("Missing trusted reviewer public key or detached signature.")
    # Only the protected environment supplies trust; no key from the reviewed tree is accepted.
    with tempfile.TemporaryDirectory(prefix="security-review-", dir=root) as name:
        key = Path(name) / "reviewer.pem"
        key.write_text(public_key)
        try:
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(key), "-signature", str(signature), str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            raise GateError("Cannot verify independent reviewer signature.") from None
    if result.returncode != 0:
        raise GateError("Independent reviewer signature is invalid.")


def verify_upload_evidence(root: Path, directory: Path, config: dict) -> None:
    import swift_security

    current = provenance(root)
    inventory = source_inventory(root, "app")
    for key, platform, destination in (
        ("ios-iphone", "ios", config["IOS_TEST_DESTINATION"]),
        ("ios-ipad", "ios", config["IPAD_TEST_DESTINATION"]),
        ("macos", "macos", "platform=macOS,arch=arm64"),
    ):
        evidence = load_json(directory / f"interaction-{key}.json")
        scheme = INTERACTION_SCHEMES[platform]
        if evidence.get("provenance") != current or evidence.get("sources") != interaction_sources(root):
            raise GateError("Interaction evidence is stale or from another commit/run.")
        if evidence.get("scheme") != scheme or evidence.get("destination") != destination:
            raise GateError("Interaction evidence is from the wrong scheme or destination.")
        reports = {}
        for kind in ("summary", "tests", "availability"):
            path = directory / f"interaction-{kind}-{key}.json"
            if evidence.get(f"{kind}SHA256") != hashlib.sha256(path.read_bytes()).hexdigest():
                raise GateError("Interaction result report digest mismatch.")
            reports[kind] = load_json(path)
        check_interactions(reports["summary"], reports["tests"], reports["availability"], scheme)
    for key, scheme in (
        ("ios-iphone", config["IOS_SCHEME"]), ("ios-ipad", config["IOS_SCHEME"]),
        ("macos", config["MACOS_SCHEME"]),
    ):
        evidence = load_json(directory / f"coverage-{key}.json")
        if evidence.get("provenance") != current or evidence.get("sources") != inventory:
            raise GateError("Coverage evidence is stale or from another commit/run.")
        if evidence.get("scheme") != scheme:
            raise GateError("Coverage evidence is from a different scheme.")
        report_path = directory / f"xccov-{key}.json"
        if evidence.get("reportSHA256") != hashlib.sha256(report_path.read_bytes()).hexdigest():
            raise GateError("Coverage report digest mismatch.")
        check_coverage(
            load_json(report_path), root, format="xccov", scope="app",
            expected_targets=(APP_PRODUCT_NAME,),
        )
    swift_security.verify_evidence(root, directory, current)
    evidence = load_json(directory / "security-python.json")
    if evidence.get("provenance") != current:
        raise GateError("Security evidence is stale or from another commit/run.")
    if evidence.get("codeqlAction") != CODEQL_ACTION:
        raise GateError("Security evidence is from an unapproved scanner action.")
    if evidence.get("sources") != inventory:
        raise GateError("Security evidence source inventory mismatch.")
    sarif = directory / "python.sarif"
    if evidence.get("reportSHA256") != hashlib.sha256(sarif.read_bytes()).hexdigest():
        raise GateError("Security report digest mismatch.")
    check_sarif(load_json(sarif), "python")
    extraction = directory / "extracted-python.json"
    if evidence.get("extractionSHA256") != hashlib.sha256(extraction.read_bytes()).hexdigest():
        raise GateError("Security extraction inventory digest mismatch.")
    rows = json.loads(extraction.read_text())
    check_extraction(rows, root, "python")
    check_readiness(root / "docs/release-readiness.json", root)
    check_security_review(root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    coverage = sub.add_parser("coverage")
    coverage.add_argument("--report", type=Path, required=True)
    coverage.add_argument("--format", choices=("xccov", "llvm"), required=True)
    coverage.add_argument("--scope", choices=("app", "package"), required=True)
    coverage.add_argument("--expected-target", action="append", default=[])
    sarif = sub.add_parser("sarif")
    sarif.add_argument("--report", type=Path, required=True)
    sarif.add_argument("--language", choices=("swift", "python"), required=True)
    extraction = sub.add_parser("extraction")
    extraction.add_argument("--report", type=Path, required=True)
    extraction.add_argument("--language", choices=("swift", "python"), required=True)
    sub.add_parser("swift-compatibility")
    sub.add_parser("readiness-digest")
    args = parser.parse_args()
    try:
        if args.command == "coverage":
            if args.format == "xccov" and not args.expected_target:
                raise GateError("Native coverage requires an explicit expected scheme target.")
            result = check_coverage(
                load_json(args.report), ROOT, format=args.format, scope=args.scope,
                expected_targets=tuple(args.expected_target),
            )
        elif args.command == "sarif":
            result = check_sarif(load_json(args.report), args.language)
        elif args.command == "extraction":
            result = check_extraction(json.loads(args.report.read_text()), ROOT, args.language)
        elif args.command == "readiness-digest":
            result = {"reviewedSourceDigest": readiness_digest(ROOT)}
        else:
            output = subprocess.check_output(["xcrun", "swift", "--version"], text=True)
            result = {"swiftVersion": check_swift_version(output), "codeqlVersion": CODEQL_VERSION}
        print(json.dumps(result, sort_keys=True))
    except (GateError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
