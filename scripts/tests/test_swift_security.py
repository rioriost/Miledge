import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gates
import swift_security


PROJECT = Path(__file__).resolve().parents[2]
INPUT_NAMES = (
    "scripts/semgrep/swift.yml",
    "scripts/semgrep/tests/swift.swift",
    "scripts/semgrep-requirements.in",
    "scripts/semgrep-requirements.txt",
    "scripts/swift_security.py",
    "scripts/gates.py",
)


class SwiftSecurityFixtures(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miledge-swift-tests-", dir=Path.cwd())
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name).resolve()
        self.root = self.workspace / "checkout"
        self.files = [
            "App/Fixture.swift",
            *(f"Sources/{library}/Fixture.swift" for library in gates.LIBRARIES),
        ]
        for name in self.files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("import Foundation\nstruct SyntheticFixture {}\n")
        for name in INPUT_NAMES:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((PROJECT / name).read_bytes())
        self.directory = self.root / ".build/gates"
        self.directory.mkdir(parents=True)
        self.scanner = self.root / ".venv/bin/semgrep"
        self.current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        self.positive = {rule: set() for rule in swift_security.RULE_IDS}
        self.negative = {rule: set() for rule in swift_security.RULE_IDS}
        for index, text in enumerate((self.root / swift_security.FIXTURE).read_text().splitlines()):
            text = text.strip()
            for prefix, expected in (("// ruleid: ", self.positive), ("// ok: ", self.negative)):
                if text.startswith(prefix):
                    for rule in text[len(prefix):].split(","):
                        expected[rule.strip()].add(index + 2)

    def inventory(self):
        return {
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            for name in self.files
        }

    def scan_report(self):
        return {
            "version": swift_security.SEMGREP_VERSION,
            "engine_requested": "OSS",
            "errors": [],
            "skipped_rules": [],
            "paths": {"scanned": sorted(self.files)},
            "results": [{
                "check_id": swift_security.PARSER_RULE,
                "path": name,
                "start": {"line": 1, "col": 1, "offset": 0},
                "end": {"line": 1, "col": 18, "offset": 17},
                "extra": {"severity": "INFO", "engine_kind": "OSS"},
            } for name in sorted(self.files)],
        }

    def rule_report(self):
        return {
            "config_missing_tests": [],
            "config_missing_fixtests": [],
            "config_with_errors": [],
            "fixtest_results": {},
            "results": {swift_security.RULES: {"checks": {
                rule: {
                    "passed": True,
                    "errors": [],
                    "matches": {swift_security.FIXTURE: {
                        "expected_lines": sorted(self.positive[rule]),
                        "reported_lines": sorted(self.positive[rule]),
                    }},
                } for rule in sorted(swift_security.RULE_IDS)
            }}},
        }

    def scan(self, *, attest=False, reports=None):
        if reports is None:
            reports = [self.rule_report(), self.scan_report()]
        with patch.object(swift_security, "execute", side_effect=reports) as execute:
            with patch.object(gates, "provenance", return_value=self.current) as provenance:
                result = swift_security.scan(self.root, self.scanner, self.directory, attest=attest)
        return result, execute, provenance

    def evidence(self):
        self.scan(attest=True)
        return gates.load_json(self.directory / "security-swift.json")

    def write_evidence(self, evidence):
        (self.directory / "security-swift.json").write_text(json.dumps(evidence))

    def verify(self):
        swift_security.verify_evidence(self.root, self.directory, self.current)


class SwiftScanReportTests(SwiftSecurityFixtures):
    def test_pinned_engine_and_reviewed_rule_inventory(self):
        self.assertEqual(swift_security.SEMGREP_VERSION, "1.179.0")
        self.assertEqual(len(swift_security.RULE_IDS), 11)
        self.assertEqual(swift_security.PARSER_RULE, "miledge.swift.parse-inventory")
        self.assertEqual(gates.source_inventory(self.root, "app"), self.inventory())
        self.assertEqual(swift_security.check_scan(self.scan_report(), self.root), {
            "files": 4, "securityRules": 10, "findings": 0,
        })

    def test_nonobject_reports_raise_gate_error(self):
        for report in (None, [], "report", 1, True):
            with self.subTest(report=report), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_missing_and_malformed_report_sections_fail_closed(self):
        for field in ("version", "engine_requested", "errors", "skipped_rules", "paths", "results"):
            report = self.scan_report()
            del report[field]
            with self.subTest(missing=field), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)
        for field, values in (
            ("paths", (None, [], "", {"scanned": None}, {"scanned": {}}, {"scanned": [None]})),
            ("results", (None, {}, "", 0, False)),
        ):
            for value in values:
                report = self.scan_report()
                report[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    swift_security.check_scan(report, self.root)

    def test_wrong_missing_and_unknown_engine_or_version_fail(self):
        for field, values in (
            ("version", (None, "", "1.178.0", "1.179.1", "unknown", 1)),
            ("engine_requested", (None, "", "PRO", "OSS,PRO", "CE", "unknown", [])),
        ):
            for value in values:
                report = self.scan_report()
                report[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    swift_security.check_scan(report, self.root)

    def test_non_oss_result_engine_cannot_hide_in_an_oss_report(self):
        for engine in ("PRO", "unknown", [], False):
            report = self.scan_report()
            report["results"][0]["extra"]["engine_kind"] = engine
            with self.subTest(engine=engine), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_errors_and_skipped_rules_fail_even_with_complete_parser_inventory(self):
        for field in ("errors", "skipped_rules"):
            for value in (None, {}, "", [{"type": "PartialParsing", "rule_id": swift_security.PARSER_RULE}]):
                report = self.scan_report()
                report[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    swift_security.check_scan(report, self.root)

    def test_each_production_file_is_required_in_scanned_inventory(self):
        for name in self.files:
            report = self.scan_report()
            report["paths"]["scanned"].remove(name)
            with self.subTest(missing=name), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_duplicate_scanned_paths_fail_instead_of_masking_missing_sources(self):
        for replace in (False, True):
            report = self.scan_report()
            scanned = report["paths"]["scanned"]
            if replace:
                scanned[-1] = scanned[0]
            else:
                scanned.append(scanned[0])
            with self.subTest(replace=replace), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_outside_unknown_generated_and_test_paths_cannot_be_scanned_production(self):
        for path in (
            "../App/Fixture.swift", str(self.workspace / "outside.swift"),
            "https://example.invalid/source.swift", "App/Deleted.swift",
            ".build/Generated.swift", "Tests/Fixture.swift",
        ):
            report = self.scan_report()
            report["paths"]["scanned"][-1] = path
            with self.subTest(path=path), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_source_inventory_does_not_trust_the_report_or_generated_markers(self):
        path = self.root / "App/New.swift"
        path.write_text("// @generated\nimport Foundation\nstruct NewFixture {}\n")
        with self.assertRaises(gates.GateError):
            swift_security.check_scan(self.scan_report(), self.root)

    def test_parser_inventory_requires_each_production_source_not_just_scanned_paths(self):
        for path in self.files:
            report = self.scan_report()
            report["results"] = [match for match in report["results"] if match["path"] != path]
            with self.subTest(path=path), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_multiple_distinct_imports_are_valid_parser_evidence(self):
        path = self.root / "App/Fixture.swift"
        path.write_text("import Foundation\nimport SwiftUI\nstruct SyntheticFixture {}\n")
        report = self.scan_report()
        second = copy.deepcopy(report["results"][0])
        second["start"] = {"line": 2, "col": 1, "offset": 18}
        second["end"] = {"line": 2, "col": 15, "offset": 32}
        report["results"].append(second)
        self.assertEqual(swift_security.check_scan(report, self.root)["files"], 4)

    def test_parser_inventory_outside_or_unknown_paths_fail(self):
        for path in ("App/Deleted.swift", "../App/Fixture.swift", str(self.workspace / "outside.swift"), None):
            report = self.scan_report()
            report["results"][0]["path"] = path
            with self.subTest(path=path), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_malformed_results_raise_gate_error_not_type_error(self):
        for value in (None, [], "result", {}, {"check_id": []}, {"check_id": {}}):
            report = self.scan_report()
            report["results"][0] = value
            with self.subTest(result=value), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)
        for value in ([], {}):
            report = self.scan_report()
            report["results"][0]["path"] = value
            with self.subTest(path=value), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_unknown_rule_cannot_be_reported_as_nonblocking_parser_information(self):
        report = self.scan_report()
        report["results"][0]["check_id"] = "miledge.swift.unreviewed"
        with self.assertRaises(gates.GateError):
            swift_security.check_scan(report, self.root)

    def test_parser_results_require_info_severity_and_well_formed_extra(self):
        for extra in (None, [], {}, {"severity": "ERROR"}, {"severity": "WARNING"}, {"severity": None}):
            report = self.scan_report()
            report["results"][0]["extra"] = extra
            with self.subTest(extra=extra), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)

    def test_parser_positions_require_integer_coordinates_and_forward_ranges(self):
        for field in ("start", "end"):
            for position in (None, [], {}, {"line": 1, "col": 1}):
                report = self.scan_report()
                report["results"][0][field] = position
                with self.subTest(field=field, position=position), self.assertRaises(gates.GateError):
                    swift_security.check_scan(report, self.root)
            for coordinate in ("line", "col", "offset"):
                invalid = (None, True, False, "1", 1.0, -1)
                if coordinate != "offset":
                    invalid += (0,)
                for value in invalid:
                    report = self.scan_report()
                    report["results"][0][field][coordinate] = value
                    with self.subTest(field=field, coordinate=coordinate, value=value), self.assertRaises(gates.GateError):
                        swift_security.check_scan(report, self.root)
        for end in (
            {"line": 1, "col": 1, "offset": 0},
            {"line": 1, "col": 1, "offset": 17},
            {"line": 1, "col": 18, "offset": 0},
        ):
            report = self.scan_report()
            report["results"][0]["end"] = end
            with self.subTest(end=end), self.assertRaises(gates.GateError):
                swift_security.check_scan(report, self.root)
        report = self.scan_report()
        report["results"][0]["start"] = {"line": 2, "col": 1, "offset": 18}
        with self.assertRaises(gates.GateError):
            swift_security.check_scan(report, self.root)

    def test_every_security_rule_blocks_even_info_ignored_or_suppressed_findings(self):
        for rule in sorted(swift_security.RULE_IDS - {swift_security.PARSER_RULE}):
            for extra in (
                {"severity": "ERROR"},
                {"severity": "WARNING"},
                {"severity": "INFO"},
                {"severity": "INFO", "is_ignored": True},
                {"severity": "INFO", "suppressions": [{"kind": "inSource"}]},
            ):
                report = self.scan_report()
                finding = copy.deepcopy(report["results"][0])
                finding.update(check_id=rule, extra=extra, is_ignored=True)
                report["results"].append(finding)
                with self.subTest(rule=rule, extra=extra), self.assertRaises(gates.GateError):
                    swift_security.check_scan(report, self.root)


class SwiftRuleTestReportTests(SwiftSecurityFixtures):
    def test_expected_lines_come_from_actual_reviewed_fixture_annotations(self):
        self.assertEqual(swift_security.fixture_expectations(self.root), (self.positive, self.negative))
        self.assertTrue(all(self.positive.values()))
        self.assertTrue(all(lines for rule, lines in self.negative.items() if rule != swift_security.PARSER_RULE))
        self.assertEqual(swift_security.check_rule_tests(self.rule_report(), self.root), {
            "rules": 11,
            "positiveCases": sum(map(len, self.positive.values())),
            "negativeCases": sum(map(len, self.negative.values())),
        })

    def test_nonobject_rule_test_reports_raise_gate_error(self):
        for report in (None, [], "report", 1, True):
            with self.subTest(report=report), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_missing_configuration_execution_and_autofix_fields_fail_closed(self):
        for field in (
            "config_missing_tests", "config_missing_fixtests",
            "config_with_errors", "fixtest_results", "results",
        ):
            report = self.rule_report()
            del report[field]
            with self.subTest(missing=field), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_configuration_errors_missing_tests_and_unexpected_autofixes_fail(self):
        for field in ("config_missing_tests", "config_missing_fixtests", "config_with_errors"):
            for value in (None, {}, [swift_security.RULES]):
                report = self.rule_report()
                report[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    swift_security.check_rule_tests(report, self.root)
        for value in (None, [], {"unexpected": {"passed": True}}):
            report = self.rule_report()
            report["fixtest_results"] = value
            with self.subTest(fixtest_results=value), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_exactly_one_approved_configuration_is_required(self):
        for value in (None, [], {}, {swift_security.RULES: {}, "other.yml": {}}):
            report = self.rule_report()
            report["results"] = value
            with self.subTest(results=value), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)
        for value in (None, [], {}, {"checks": []}):
            report = self.rule_report()
            report["results"][swift_security.RULES] = value
            with self.subTest(config=value), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_unknown_outside_and_traversing_configuration_or_fixture_paths_fail(self):
        for kind in ("configuration", "fixture"):
            for path in (
                "", "../swift.yml", str(self.workspace / "outside.swift"),
                "https://example.invalid/swift.swift", "scripts/unreviewed.swift",
            ):
                report = self.rule_report()
                if kind == "configuration":
                    report["results"] = {path: report["results"][swift_security.RULES]}
                else:
                    checks = report["results"][swift_security.RULES]["checks"]
                    first = checks[swift_security.PARSER_RULE]
                    first["matches"] = {path: first["matches"][swift_security.FIXTURE]}
                with self.subTest(kind=kind, path=path), self.assertRaises(gates.GateError):
                    swift_security.check_rule_tests(report, self.root)

    def test_absolute_local_reviewed_configuration_and_fixture_paths_are_accepted(self):
        report = self.rule_report()
        result = report["results"].pop(swift_security.RULES)
        report["results"][str(self.root / swift_security.RULES)] = result
        for check in result["checks"].values():
            match = check["matches"].pop(swift_security.FIXTURE)
            check["matches"][str(self.root / swift_security.FIXTURE)] = match
        self.assertEqual(swift_security.check_rule_tests(report, self.root)["rules"], 11)

    def test_each_rule_is_required_and_unknown_extra_rules_fail(self):
        for rule in sorted(swift_security.RULE_IDS):
            report = self.rule_report()
            del report["results"][swift_security.RULES]["checks"][rule]
            with self.subTest(missing=rule), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)
        report = self.rule_report()
        report["results"][swift_security.RULES]["checks"]["miledge.swift.unknown"] = {}
        with self.assertRaises(gates.GateError):
            swift_security.check_rule_tests(report, self.root)

    def test_passed_is_exactly_true_and_check_errors_are_explicitly_empty(self):
        for value in (None, {}, [], {"passed": 1, "errors": []}, {"passed": False, "errors": []},
                      {"passed": True}, {"passed": True, "errors": ["error"]}):
            report = self.rule_report()
            report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE] = value
            with self.subTest(check=value), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_missing_extra_and_malformed_fixture_match_sections_fail(self):
        for value in (None, [], {}, {swift_security.FIXTURE: None},
                      {swift_security.FIXTURE: {}, "extra.swift": {}}):
            report = self.rule_report()
            check = report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE]
            check["matches"] = value
            with self.subTest(matches=value), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_missing_nondetection_and_unannotated_positive_lines_fail(self):
        for rule in sorted(swift_security.RULE_IDS):
            for field in ("expected_lines", "reported_lines"):
                for mutation in ("missing", "empty", "omitted", "extra", "shifted"):
                    report = self.rule_report()
                    match = report["results"][swift_security.RULES]["checks"][rule]["matches"][swift_security.FIXTURE]
                    if mutation == "missing":
                        del match[field]
                    elif mutation == "empty":
                        match[field] = []
                    elif mutation == "omitted":
                        match[field].pop()
                    elif mutation == "extra":
                        match[field].append(10000)
                    else:
                        match[field] = [line + 1 for line in match[field]]
                    with self.subTest(rule=rule, field=field, mutation=mutation), self.assertRaises(gates.GateError):
                        swift_security.check_rule_tests(report, self.root)

    def test_expected_and_reported_lines_cannot_agree_on_invented_expectations(self):
        report = self.rule_report()
        match = report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE]["matches"][swift_security.FIXTURE]
        match.update(expected_lines=[10000], reported_lines=[10000])
        with self.assertRaises(gates.GateError):
            swift_security.check_rule_tests(report, self.root)

    def test_each_negative_fixture_line_is_a_blocking_false_positive(self):
        for rule, lines in sorted(self.negative.items()):
            for line in sorted(lines):
                report = self.rule_report()
                match = report["results"][swift_security.RULES]["checks"][rule]["matches"][swift_security.FIXTURE]
                match["reported_lines"].append(line)
                with self.subTest(rule=rule, negative_line=line), self.assertRaises(gates.GateError):
                    swift_security.check_rule_tests(report, self.root)

    def test_line_arrays_require_unique_positive_integers_not_bools(self):
        for field in ("expected_lines", "reported_lines"):
            for value in (None, {}, "2", [True], [False], [2.0], ["2"], [0], [-1]):
                report = self.rule_report()
                match = report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE]["matches"][swift_security.FIXTURE]
                match[field] = value
                with self.subTest(field=field, lines=value), self.assertRaises(gates.GateError):
                    swift_security.check_rule_tests(report, self.root)
            report = self.rule_report()
            match = report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE]["matches"][swift_security.FIXTURE]
            match[field].append(match[field][0])
            with self.subTest(field=field, duplicate=True), self.assertRaises(gates.GateError):
                swift_security.check_rule_tests(report, self.root)

    def test_positive_and_negative_fixture_annotations_cannot_be_removed(self):
        path = self.root / swift_security.FIXTURE
        original = path.read_text()
        for marker, expectations in (("ruleid", self.positive), ("ok", self.negative)):
            for rule, lines in sorted(expectations.items()):
                if not lines:
                    continue
                text = original
                for line in original.splitlines():
                    if line.strip().startswith(f"// {marker}: "):
                        rules = [name.strip() for name in line.split(": ", 1)[1].split(",")]
                        if rule in rules:
                            rules.remove(rule)
                            replacement = "// annotation removed" if not rules else f"// {marker}: " + ", ".join(rules)
                            text = text.replace(line, replacement)
                path.write_text(text)
                with self.subTest(marker=marker, rule=rule), self.assertRaises(gates.GateError):
                    swift_security.fixture_expectations(self.root)
                path.write_text(original)

    def test_unknown_fixture_annotation_is_rejected(self):
        path = self.root / swift_security.FIXTURE
        path.write_text(path.read_text() + "\n// ruleid: miledge.swift.unreviewed\nimport Foundation\n")
        with self.assertRaises(gates.GateError):
            swift_security.fixture_expectations(self.root)


class SwiftInputTests(SwiftSecurityFixtures):
    def test_all_reviewed_rules_fixtures_pins_and_gate_code_are_hash_bound(self):
        expected = {
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            for name in INPUT_NAMES
        }
        self.assertEqual(swift_security.inputs(self.root), expected)

    def test_each_missing_input_fails(self):
        for name in INPUT_NAMES:
            path = self.root / name
            content = path.read_bytes()
            path.unlink()
            with self.subTest(input=name), self.assertRaises(gates.GateError):
                swift_security.inputs(self.root)
            path.write_bytes(content)

    def test_input_read_oserrors_are_wrapped_in_gate_error(self):
        read_bytes = Path.read_bytes
        for name in INPUT_NAMES:
            failing = self.root / name

            def read(path):
                if path == failing:
                    raise PermissionError("synthetic unreadable input")
                return read_bytes(path)

            with (
                self.subTest(input=name),
                patch.object(Path, "read_bytes", autospec=True, side_effect=read),
                self.assertRaises(gates.GateError),
            ):
                swift_security.inputs(self.root)

    def test_each_input_hash_changes_when_its_contents_change(self):
        initial = swift_security.inputs(self.root)
        for name in INPUT_NAMES:
            path = self.root / name
            content = path.read_bytes()
            path.write_bytes(content + b"\n")
            actual = swift_security.inputs(self.root)
            with self.subTest(input=name):
                self.assertNotEqual(actual[name], initial[name])
                self.assertEqual({key for key in actual if actual[key] != initial[key]}, {name})
            path.write_bytes(content)

    def test_input_file_symlinks_are_rejected_even_for_local_targets(self):
        target = self.root / "synthetic-input"
        target.write_text("synthetic")
        outside = self.workspace / "outside-input"
        outside.write_text("synthetic")
        for name in INPUT_NAMES:
            path = self.root / name
            content = path.read_bytes()
            for destination in (target, outside):
                path.unlink()
                path.symlink_to(destination)
                with self.subTest(input=name, destination=destination.name), self.assertRaises(gates.GateError):
                    swift_security.inputs(self.root)
                path.unlink()
                path.write_bytes(content)

    def test_source_file_and_directory_symlinks_fail_before_any_scanner_call(self):
        for name, destination in (
            ("App/Alias.swift", self.root / "App/Fixture.swift"),
            ("Sources/Alias", self.root / "Sources/MiledgeStorage"),
            ("App/Outside.swift", self.workspace / "outside.swift"),
        ):
            link = self.root / name
            link.symlink_to(destination)
            with self.subTest(link=name), patch.object(swift_security, "execute") as execute:
                with self.assertRaises(gates.GateError):
                    swift_security.scan(self.root, self.scanner, self.directory)
                execute.assert_not_called()
            link.unlink()


class SwiftScanRunnerTests(SwiftSecurityFixtures):
    def test_local_scan_runs_rule_tests_then_all_sources_without_release_attestation(self):
        stale = self.directory / "security-swift.json"
        stale.write_text('{"old":"passed"}')
        result, execute, provenance = self.scan()
        self.assertEqual(result["analysis"], {"files": 4, "securityRules": 10, "findings": 0})
        self.assertFalse(result["releaseAttestation"])
        self.assertFalse(stale.exists())
        provenance.assert_not_called()
        self.assertEqual(execute.call_count, 2)
        for call, arguments in zip(execute.call_args_list, (["--test", swift_security.FIXTURE], sorted(self.files))):
            self.assertEqual(call.args[:3], (self.scanner, arguments, self.root))
            self.assertTrue(call.args[3].is_relative_to(self.directory.resolve()))
            self.assertFalse(call.args[3].exists())
        self.assertTrue((self.directory / "swift-semgrep.json").is_file())
        self.assertTrue((self.directory / "swift-rule-tests.json").is_file())
        self.assertFalse(list(self.directory.glob("swift-scan-*")))

    def test_rule_test_failure_prevents_production_scan_and_removes_stale_attestation(self):
        stale = self.directory / "security-swift.json"
        stale.write_text('{"old":"passed"}')
        report = self.rule_report()
        report["config_missing_tests"] = [swift_security.RULES]
        with patch.object(swift_security, "execute", return_value=report) as execute:
            with self.assertRaises(gates.GateError):
                swift_security.scan(self.root, self.scanner, self.directory, attest=True)
        self.assertEqual(execute.call_count, 1)
        self.assertFalse(stale.exists())
        self.assertFalse(list(self.directory.glob("swift-scan-*")))

    def test_scanner_and_policy_failure_remove_stale_attestation(self):
        for failure in ("rule-process", "scan-process", "finding"):
            stale = self.directory / "security-swift.json"
            stale.write_text('{"old":"passed"}')
            report = self.scan_report()
            finding = copy.deepcopy(report["results"][0])
            finding["check_id"] = "miledge.swift.no-production-logging"
            report["results"].append(finding)
            outputs = {
                "rule-process": [gates.GateError("synthetic scanner failure")],
                "scan-process": [self.rule_report(), gates.GateError("synthetic scanner failure")],
                "finding": [self.rule_report(), report],
            }[failure]
            with self.subTest(failure=failure), patch.object(swift_security, "execute", side_effect=outputs):
                with self.assertRaises(gates.GateError):
                    swift_security.scan(self.root, self.scanner, self.directory, attest=True)
                self.assertFalse(stale.exists())
                self.assertFalse(list(self.directory.glob("swift-scan-*")))

    def test_missing_parser_positions_raise_gate_error_not_sanitizer_key_error(self):
        for field in ("start", "end"):
            report = self.scan_report()
            del report["results"][0][field]
            with self.subTest(missing=field), self.assertRaises(gates.GateError):
                self.scan(reports=[self.rule_report(), report])

    def test_sources_and_every_reviewed_input_must_remain_unchanged_during_analysis(self):
        for name in (*self.files, *INPUT_NAMES):
            path = self.root / name
            original = path.read_bytes()
            reports = iter((self.rule_report(), self.scan_report()))

            def execute(*args):
                report = next(reports)
                if "version" in report:
                    path.write_bytes(original + b"\n")
                return report

            with self.subTest(changed=name), patch.object(swift_security, "execute", side_effect=execute):
                with self.assertRaises(gates.GateError):
                    swift_security.scan(self.root, self.scanner, self.directory, attest=True)
                self.assertFalse((self.directory / "security-swift.json").exists())
            path.write_bytes(original)

    def test_inputs_replaced_by_symlinks_during_scan_are_not_attested(self):
        path = self.root / swift_security.RULES
        target = self.root / "synthetic-rule-copy.yml"
        target.write_bytes(path.read_bytes())
        reports = iter((self.rule_report(), self.scan_report()))

        def execute(*args):
            report = next(reports)
            if "version" in report:
                path.unlink()
                path.symlink_to(target)
            return report

        with patch.object(swift_security, "execute", side_effect=execute):
            with self.assertRaises(gates.GateError):
                swift_security.scan(self.root, self.scanner, self.directory, attest=True)
        self.assertFalse((self.directory / "security-swift.json").exists())

    def test_source_added_between_rule_tests_and_scan_cannot_be_omitted(self):
        reports = iter((self.rule_report(), self.scan_report()))

        def execute(*args):
            report = next(reports)
            if "version" in report:
                (self.root / "App/Added.swift").write_text("import Foundation\nstruct AddedFixture {}\n")
            return report

        with patch.object(swift_security, "execute", side_effect=execute):
            with self.assertRaises(gates.GateError):
                swift_security.scan(self.root, self.scanner, self.directory, attest=True)
        self.assertFalse((self.directory / "security-swift.json").exists())

    def test_attestation_is_requested_and_binds_verified_provenance_and_exact_artifacts(self):
        result, _, provenance = self.scan(attest=True)
        provenance.assert_called_once_with(self.root)
        self.assertTrue(result["releaseAttestation"])
        evidence = gates.load_json(self.directory / "security-swift.json")
        self.assertEqual(evidence["schemaVersion"], 1)
        self.assertEqual(evidence["provenance"], self.current)
        self.assertEqual(evidence["sources"], self.inventory())
        self.assertEqual(evidence["inputs"], swift_security.inputs(self.root))
        self.assertEqual(evidence["scanner"], {"name": "Semgrep CE", "version": "1.179.0"})
        self.assertEqual(evidence["networkPolicy"], swift_security.NETWORK_POLICY)
        self.assertEqual(evidence["analysis"], result["analysis"])
        self.assertEqual(evidence["ruleTests"], result["ruleTests"])
        for filename, key in (("swift-semgrep.json", "reportSHA256"), ("swift-rule-tests.json", "ruleTestsSHA256")):
            self.assertEqual(evidence[key], hashlib.sha256((self.directory / filename).read_bytes()).hexdigest())
        self.verify()

    def test_attestation_requires_real_commit_verification_not_just_environment_values(self):
        environment = {
            "GITHUB_SHA": self.current["commit"],
            "GITHUB_RUN_ID": self.current["runId"],
            "GITHUB_RUN_ATTEMPT": self.current["runAttempt"],
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(subprocess, "check_output", return_value=self.current["commit"] + "\n") as git,
            patch.object(swift_security, "execute", side_effect=[self.rule_report(), self.scan_report()]),
        ):
            swift_security.scan(self.root, self.scanner, self.directory, attest=True)
        git.assert_called_once_with(["git", "rev-parse", "HEAD"], cwd=self.root, text=True)
        self.assertEqual(gates.load_json(self.directory / "security-swift.json")["provenance"], self.current)

    def test_missing_or_wrong_commit_run_provenance_never_creates_attestation(self):
        valid = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
        for environment, head in (
            ({}, "a" * 40),
            ({**valid, "GITHUB_RUN_ID": "not-a-run"}, "a" * 40),
            ({**valid, "GITHUB_RUN_ATTEMPT": "0"}, "a" * 40),
            (valid, "b" * 40),
        ):
            stale = self.directory / "security-swift.json"
            stale.write_text('{"old":"passed"}')
            with (
                self.subTest(environment=environment, head=head),
                patch.dict(os.environ, environment, clear=True),
                patch.object(subprocess, "check_output", return_value=head),
                patch.object(swift_security, "execute", side_effect=[self.rule_report(), self.scan_report()]),
            ):
                with self.assertRaises(gates.GateError):
                    swift_security.scan(self.root, self.scanner, self.directory, attest=True)
                self.assertFalse(stale.exists())

    def test_successful_scan_report_strips_source_snippets_metavariables_and_messages(self):
        sentinel = "SYNTHETIC_SOURCE_MUST_NOT_BE_RETAINED"
        report = self.scan_report()
        report["source"] = sentinel
        report["paths"]["source"] = sentinel
        for match in report["results"]:
            match["source"] = sentinel
            for position in ("start", "end"):
                match[position]["source"] = sentinel
            match["extra"].update(
                lines=sentinel, message=sentinel,
                metavars={"$MODULE": {"abstract_content": sentinel}},
            )
        self.scan(attest=True, reports=[self.rule_report(), report])
        for path in self.directory.glob("*.json"):
            self.assertNotIn(sentinel, path.read_text())
        clean = gates.load_json(self.directory / "swift-semgrep.json")
        self.assertEqual(set(clean), {"version", "engine_requested", "errors", "skipped_rules", "paths", "results"})
        self.assertEqual(clean["paths"], {"scanned": sorted(self.files)})
        for original, result in zip(report["results"], clean["results"]):
            self.assertEqual(set(result), {"check_id", "path", "start", "end", "extra"})
            for position in ("start", "end"):
                self.assertEqual(result[position], {
                    key: original[position][key] for key in ("line", "col", "offset")
                })
            self.assertEqual(result["extra"], {"severity": "INFO", "engine_kind": "OSS"})
        self.verify()

    def test_successful_rule_test_report_does_not_retain_source_snippets(self):
        sentinel = "SYNTHETIC_FIXTURE_SOURCE_MUST_NOT_BE_RETAINED"
        report = self.rule_report()
        report["source"] = sentinel
        report["results"][swift_security.RULES]["source"] = sentinel
        for check in report["results"][swift_security.RULES]["checks"].values():
            check["source"] = sentinel
            check["matches"][swift_security.FIXTURE]["lines"] = sentinel
        self.scan(attest=True, reports=[report, self.scan_report()])
        for path in self.directory.glob("*.json"):
            self.assertNotIn(sentinel, path.read_text())
        clean = gates.load_json(self.directory / "swift-rule-tests.json")
        self.assertEqual(set(clean), {
            "config_missing_tests", "config_missing_fixtests", "config_with_errors", "fixtest_results", "results",
        })
        self.assertEqual(set(clean["results"]), {swift_security.RULES})
        self.assertEqual(set(clean["results"][swift_security.RULES]), {"checks"})
        for check in clean["results"][swift_security.RULES]["checks"].values():
            self.assertEqual(set(check), {"passed", "errors", "matches"})
            self.assertEqual(set(check["matches"]), {swift_security.FIXTURE})
            self.assertEqual(set(check["matches"][swift_security.FIXTURE]), {"expected_lines", "reported_lines"})
        self.verify()


class SwiftEvidenceTests(SwiftSecurityFixtures):
    def test_valid_evidence_fixture_includes_exact_report_derived_summaries(self):
        evidence = self.evidence()
        self.assertEqual(evidence["analysis"], {
            "files": len(self.files), "securityRules": len(swift_security.RULE_IDS) - 1, "findings": 0,
        })
        self.assertEqual(evidence["ruleTests"], {
            "rules": len(swift_security.RULE_IDS),
            "positiveCases": sum(map(len, self.positive.values())),
            "negativeCases": sum(map(len, self.negative.values())),
        })
        self.verify()

    def test_missing_malformed_nonobject_and_duplicate_key_attestations_fail(self):
        path = self.directory / "security-swift.json"
        with self.assertRaises(gates.GateError):
            self.verify()
        for text in ("", "{", "null", "[]", '{"schemaVersion":1,"schemaVersion":1}', '{"schemaVersion":NaN}'):
            path.write_text(text)
            with self.subTest(json=text), self.assertRaises(gates.GateError):
                self.verify()

    def test_evidence_schema_scanner_and_offline_policy_are_exact(self):
        original = self.evidence()
        for field, values in (
            ("schemaVersion", (None, True, "1", 0, 2)),
            ("scanner", (None, {}, {"name": "Semgrep CE", "version": "1.178.0"},
                         {"name": "Semgrep PRO", "version": "1.179.0"})),
            ("networkPolicy", (None, "", "(version 1)(allow default)")),
        ):
            for value in values:
                evidence = copy.deepcopy(original)
                evidence[field] = value
                self.write_evidence(evidence)
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    self.verify()
        for field in ("schemaVersion", "scanner", "networkPolicy", "provenance", "sources", "inputs"):
            evidence = copy.deepcopy(original)
            del evidence[field]
            self.write_evidence(evidence)
            with self.subTest(missing=field), self.assertRaises(gates.GateError):
                self.verify()

    def test_evidence_is_bound_to_current_commit_run_id_and_run_attempt(self):
        original = self.evidence()
        for field, value in (("commit", "b" * 40), ("runId", "124"), ("runAttempt", "2")):
            evidence = copy.deepcopy(original)
            evidence["provenance"][field] = value
            self.write_evidence(evidence)
            with self.subTest(stale=field), self.assertRaises(gates.GateError):
                self.verify()
        self.write_evidence(original)
        for field, value in (("commit", "b" * 40), ("runId", "124"), ("runAttempt", "2")):
            with self.subTest(current=field), self.assertRaises(gates.GateError):
                swift_security.verify_evidence(self.root, self.directory, {**self.current, field: value})

    def test_each_source_and_reviewed_input_hash_is_rechecked_against_disk(self):
        self.evidence()
        for name in (*self.files, *INPUT_NAMES):
            path = self.root / name
            content = path.read_bytes()
            path.write_bytes(content + b"\n")
            with self.subTest(changed=name), self.assertRaises(gates.GateError):
                self.verify()
            path.write_bytes(content)

    def test_fabricated_source_and_input_manifest_entries_fail(self):
        original = self.evidence()
        for field in ("sources", "inputs"):
            for mutation in ("missing", "digest", "extra"):
                evidence = copy.deepcopy(original)
                name = next(iter(evidence[field]))
                if mutation == "missing":
                    del evidence[field][name]
                elif mutation == "digest":
                    evidence[field][name] = "0" * 64
                else:
                    evidence[field]["unreviewed"] = "0" * 64
                self.write_evidence(evidence)
                with self.subTest(field=field, mutation=mutation), self.assertRaises(gates.GateError):
                    self.verify()

    def test_report_and_rule_test_byte_digests_are_independently_bound(self):
        original = self.evidence()
        for filename in ("swift-semgrep.json", "swift-rule-tests.json"):
            path = self.directory / filename
            content = path.read_bytes()
            path.write_bytes(content + b" ")
            with self.subTest(report=filename), self.assertRaises(gates.GateError):
                self.verify()
            path.write_bytes(content)
        for field in ("reportSHA256", "ruleTestsSHA256"):
            for value in (None, "", "0" * 64):
                evidence = copy.deepcopy(original)
                evidence[field] = value
                self.write_evidence(evidence)
                with self.subTest(digest=field, value=value), self.assertRaises(gates.GateError):
                    self.verify()

    def test_missing_malformed_and_altered_evidence_summaries_fail(self):
        original = self.evidence()
        for field in ("analysis", "ruleTests"):
            evidence = copy.deepcopy(original)
            del evidence[field]
            self.write_evidence(evidence)
            with self.subTest(missing=field), self.assertRaises(gates.GateError):
                self.verify()
            for value in (None, {}, [], "passed", {**original[field], "unreviewed": 1}):
                evidence = copy.deepcopy(original)
                evidence[field] = value
                self.write_evidence(evidence)
                with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                    self.verify()
            for count in original[field]:
                evidence = copy.deepcopy(original)
                evidence[field][count] += 1
                self.write_evidence(evidence)
                with self.subTest(field=field, count=count), self.assertRaises(gates.GateError):
                    self.verify()
        self.write_evidence(original)
        self.verify()

    def test_missing_bound_reports_raise_gate_error_not_file_not_found(self):
        self.evidence()
        for filename in ("swift-semgrep.json", "swift-rule-tests.json"):
            path = self.directory / filename
            content = path.read_bytes()
            path.unlink()
            with self.subTest(missing=filename), self.assertRaises(gates.GateError):
                self.verify()
            path.write_bytes(content)

    def test_bound_report_symlinks_fail_even_with_identical_content_and_digest(self):
        self.evidence()
        for filename in ("swift-semgrep.json", "swift-rule-tests.json"):
            path = self.directory / filename
            content = path.read_bytes()
            for directory in (self.directory, self.workspace):
                target = directory / ("synthetic-copy-" + filename)
                target.write_bytes(content)
                path.unlink()
                path.symlink_to(target)
                with self.subTest(report=filename, target=directory.name), self.assertRaises(gates.GateError):
                    self.verify()
                path.unlink()
                path.write_bytes(content)
        self.verify()

    def test_malformed_bound_json_fails_even_when_its_digest_matches(self):
        original = self.evidence()
        for filename, field in (("swift-semgrep.json", "reportSHA256"), ("swift-rule-tests.json", "ruleTestsSHA256")):
            path = self.directory / filename
            content = path.read_bytes()
            for text in ("", "{", "[]", "null", '{"results":[],"results":[]}'):
                path.write_text(text)
                evidence = copy.deepcopy(original)
                evidence[field] = hashlib.sha256(path.read_bytes()).hexdigest()
                self.write_evidence(evidence)
                with self.subTest(report=filename, json=text), self.assertRaises(gates.GateError):
                    self.verify()
            path.write_bytes(content)
        self.write_evidence(original)

    def test_matching_digest_cannot_override_scan_or_fixture_validation(self):
        original = self.evidence()
        for filename, field in (("swift-semgrep.json", "reportSHA256"), ("swift-rule-tests.json", "ruleTestsSHA256")):
            path = self.directory / filename
            content = path.read_bytes()
            report = json.loads(content)
            if filename == "swift-semgrep.json":
                report["results"][0]["check_id"] = "miledge.swift.no-production-logging"
            else:
                check = report["results"][swift_security.RULES]["checks"][swift_security.PARSER_RULE]
                check["matches"][swift_security.FIXTURE]["reported_lines"] = []
            path.write_text(json.dumps(report))
            evidence = copy.deepcopy(original)
            evidence[field] = hashlib.sha256(path.read_bytes()).hexdigest()
            self.write_evidence(evidence)
            with self.subTest(report=filename), self.assertRaises(gates.GateError):
                self.verify()
            path.write_bytes(content)
        self.write_evidence(original)


class SwiftScannerProcessTests(SwiftSecurityFixtures):
    def process(self, stdout=b'{"synthetic":true}', returncode=0):
        process = Mock()
        process.pid = 4242
        process.returncode = returncode
        process.communicate.return_value = (stdout, b"SYNTHETIC_STDERR")
        return process

    def test_scanner_is_process_locally_offline_pinned_strict_and_environment_clean(self):
        process = self.process()
        environment = {
            "PATH": "/synthetic/bin", "HOME": "/synthetic/personal-home",
            "GITHUB_TOKEN": "synthetic-token", "AWS_SECRET_ACCESS_KEY": "synthetic-key",
            "HTTP_PROXY": "http://example.invalid", "HTTPS_PROXY": "http://example.invalid",
            "SEMGREP_APP_TOKEN": "synthetic-token", "SEMGREP_SEND_METRICS": "on",
            "SEMGREP_ENABLE_VERSION_CHECK": "1",
        }
        arguments = sorted(self.files)
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(sys, "platform", "darwin"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(subprocess, "Popen", return_value=process) as popen,
        ):
            result = swift_security.execute(self.scanner, arguments, self.root, self.directory)
        self.assertEqual(result, {"synthetic": True})
        popen.assert_called_once()
        command = popen.call_args.args[0]
        self.assertEqual(command[:3], ["/usr/bin/sandbox-exec", "-p", swift_security.NETWORK_POLICY])
        self.assertIn("(deny network*)", command[2])
        self.assertEqual(command[3:5], [str(self.scanner.resolve()), "scan"])
        for flag in (
            "--oss-only", "--metrics=off", "--disable-version-check", "--disable-nosem",
            "--no-git-ignore", "--no-rewrite-rule-ids", "--project-root=.", "--jobs=2",
            "--strict", "--timeout=10", "--json",
        ):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index("--config") + 1], swift_security.RULES)
        self.assertEqual(command[-len(arguments):], arguments)
        self.assertEqual(popen.call_args.kwargs, {
            "cwd": self.root,
            "env": {
                "PATH": "/synthetic/bin", "HOME": str(self.directory), "TMPDIR": str(self.directory),
                "SEMGREP_SEND_METRICS": "off", "SEMGREP_ENABLE_VERSION_CHECK": "0",
            },
            "stdout": subprocess.PIPE, "stderr": subprocess.PIPE, "start_new_session": True,
        })
        process.communicate.assert_called_once_with(timeout=120)

    def test_rule_test_mode_uses_the_same_offline_scanner_command(self):
        process = self.process(json.dumps(self.rule_report()).encode())
        with (
            patch.object(sys, "platform", "darwin"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(subprocess, "Popen", return_value=process) as popen,
        ):
            result = swift_security.execute(self.scanner, ["--test", swift_security.FIXTURE], self.root, self.directory)
        self.assertEqual(result, self.rule_report())
        self.assertEqual(popen.call_args.args[0][-2:], ["--test", swift_security.FIXTURE])
        self.assertIn("--oss-only", popen.call_args.args[0])
        process.communicate.assert_called_once_with(timeout=120)

    def test_missing_path_gets_a_minimal_system_path_not_personal_environment(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(sys, "platform", "darwin"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(subprocess, "Popen", return_value=self.process()) as popen,
        ):
            swift_security.execute(self.scanner, [], self.root, self.directory)
        self.assertEqual(popen.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin")

    def test_total_timeout_kills_only_the_scanner_process_group_and_fails_closed(self):
        process = self.process()
        process.communicate.side_effect = [subprocess.TimeoutExpired("synthetic-semgrep", 120), (b"", b"")]
        with (
            patch.object(sys, "platform", "darwin"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(subprocess, "Popen", return_value=process),
            patch.object(os, "killpg") as killpg,
        ):
            with self.assertRaises(gates.GateError):
                swift_security.execute(self.scanner, [], self.root, self.directory)
        killpg.assert_called_once_with(process.pid, signal.SIGKILL)
        self.assertEqual(process.communicate.call_args_list[0].kwargs, {"timeout": 120})
        self.assertEqual(process.communicate.call_count, 2)
        self.assertEqual(process.communicate.call_args_list[1].args, ())
        self.assertEqual(process.communicate.call_args_list[1].kwargs, {})
        self.assertFalse((self.directory / "result.json").exists())

    def test_nonzero_scanner_exit_never_accepts_stdout_or_exposes_stderr(self):
        for code in (1, 2, 3, -9):
            process = self.process(returncode=code)
            with (
                self.subTest(code=code),
                patch.object(sys, "platform", "darwin"),
                patch.object(Path, "is_file", return_value=True),
                patch.object(subprocess, "Popen", return_value=process),
            ):
                with self.assertRaises(gates.GateError) as error:
                    swift_security.execute(self.scanner, [], self.root, self.directory)
                self.assertNotIn("SYNTHETIC_STDERR", str(error.exception))
                self.assertFalse((self.directory / "result.json").exists())

    def test_process_launch_oserrors_raise_gate_error_without_creating_a_report(self):
        for error in (
            FileNotFoundError("synthetic missing scanner"),
            PermissionError("synthetic denied scanner"),
            OSError("synthetic launch failure"),
        ):
            with (
                self.subTest(error=type(error).__name__),
                patch.object(sys, "platform", "darwin"),
                patch.object(Path, "is_file", return_value=True),
                patch.object(subprocess, "Popen", side_effect=error) as popen,
                self.assertRaises(gates.GateError),
            ):
                swift_security.execute(self.scanner, [], self.root, self.directory)
            popen.assert_called_once()
            self.assertFalse((self.directory / "result.json").exists())

    def test_empty_malformed_duplicate_key_and_nonobject_scanner_json_fail_closed(self):
        for stdout in (b"", b"{", b"null", b"[]", b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}'):
            with (
                self.subTest(stdout=stdout),
                patch.object(sys, "platform", "darwin"),
                patch.object(Path, "is_file", return_value=True),
                patch.object(subprocess, "Popen", return_value=self.process(stdout)),
            ):
                with self.assertRaises(gates.GateError):
                    swift_security.execute(self.scanner, [], self.root, self.directory)

    def test_non_macos_and_missing_sandbox_fail_before_launching_any_process(self):
        for platform, sandbox in (("linux", True), ("win32", True), ("darwin", False)):
            with (
                self.subTest(platform=platform, sandbox=sandbox),
                patch.object(sys, "platform", platform),
                patch.object(Path, "is_file", return_value=sandbox),
                patch.object(subprocess, "Popen") as popen,
            ):
                with self.assertRaises(gates.GateError):
                    swift_security.execute(self.scanner, [], self.root, self.directory)
                popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
