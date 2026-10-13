import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gates
import interaction_fixtures
import swift_security


class GateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miledge-gates-", dir=Path.cwd())
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        for name in ("App", *(f"Sources/{name}" for name in gates.LIBRARIES)):
            source = self.root / name / "Fixture.swift"
            source.parent.mkdir(parents=True)
            source.write_text("import Foundation\nfunc fixture() -> Int { 1 }\n")
        self.files = sorted(gates.source_inventory(self.root, "app"))
        interaction_fixtures.source_files(self.root)

    def xccov(self, covered=90, total=100):
        files = [
            {"path": str(self.root / path), "coveredLines": covered, "executableLines": total}
            for path in self.files
        ]
        return {"targets": [{
            "name": "Miledge.app", "coveredLines": len(files) * covered,
            "executableLines": len(files) * total, "files": files,
        }]}

    def llvm(self, covered=90, total=100):
        files = [
            {
                "filename": str(self.root / path),
                "summary": {"lines": {"covered": covered, "count": total}},
            }
            for path in self.files if path.startswith("Sources/")
        ]
        return {
            "type": "llvm.coverage.json.export", "version": "2.0.1",
            "data": [{
                "files": files,
                "totals": {"lines": {"covered": len(files) * covered, "count": len(files) * total}},
            }],
        }

    def coverage(self, report, format="xccov"):
        return gates.check_coverage(
            report, self.root, format=format, scope="app" if format == "xccov" else "package",
            expected_targets=(gates.APP_PRODUCT_NAME,) if format == "xccov" else (),
        )

    def sarif(self, severity="3.9", level="warning", results=True):
        return {
            "version": "2.1.0", "runs": [{
                "tool": {"driver": {
                    "name": "CodeQL", "semanticVersion": gates.CODEQL_VERSION,
                    "rules": [{
                        "id": "swift/example", "properties": {
                            "tags": ["security"], "security-severity": severity,
                        },
                        "defaultConfiguration": {"level": level},
                    }],
                }},
                "invocations": [{"executionSuccessful": True}],
                "results": [{"ruleId": "swift/example", "ruleIndex": 0}] if results else [],
            }],
        }

    def test_exactly_90_percent_passes_for_both_formats(self):
        for format, report in (("xccov", self.xccov()), ("llvm", self.llvm())):
            with self.subTest(format=format):
                self.assertEqual(self.coverage(report, format)["lineCoverage"], 0.9)

    def test_89_point_999_percent_fails_without_rounding(self):
        for format, report in (("xccov", self.xccov(89999, 100000)), ("llvm", self.llvm(89999, 100000))):
            with self.subTest(format=format), self.assertRaisesRegex(gates.GateError, "below 90"):
                self.coverage(report, format)

    def test_aggregation_uses_line_counts_not_mean_percentages(self):
        report = self.xccov()
        files = report["targets"][0]["files"]
        for file in files:
            file.update(coveredLines=1, executableLines=1)
        files[0].update(coveredLines=87, executableLines=100)
        report["targets"][0].update(coveredLines=90, executableLines=103)
        # Mean file percentages is 96.75%; the true aggregate is 87.38%.
        with self.assertRaisesRegex(gates.GateError, "below 90"):
            self.coverage(report)

    def test_low_individual_file_can_pass_correct_weighted_aggregate(self):
        report = self.xccov(100, 100)
        report["targets"][0]["files"][0].update(coveredLines=0, executableLines=1)
        report["targets"][0].update(coveredLines=300, executableLines=301)
        self.assertGreater(self.coverage(report)["lineCoverage"], 0.9)

    def test_empty_or_missing_targets_fail(self):
        for report in ({}, {"targets": []}, {"targets": {}}, {"targets": None}):
            with self.subTest(report=report), self.assertRaises(gates.GateError):
                self.coverage(report)

    def test_expected_product_target_missing_fails(self):
        for name in ("Other.app", "Miledge-iOS.app", "Miledge-macOS.app"):
            report = self.xccov()
            report["targets"][0]["name"] = name
            with self.subTest(name=name), self.assertRaisesRegex(gates.GateError, "Missing coverage target"):
                self.coverage(report)

    def test_target_file_report_missing_fails(self):
        report = self.xccov()
        del report["targets"][0]["files"]
        with self.assertRaisesRegex(gates.GateError, "source coverage report"):
            self.coverage(report)

    def test_app_and_storage_sources_cannot_be_exempted(self):
        for missing in (self.files[0], self.files[-1]):
            report = self.xccov()
            target = report["targets"][0]
            target["files"] = [file for file in target["files"] if file["path"] != str(self.root / missing)]
            target.update(coveredLines=270, executableLines=300)
            with self.subTest(missing=missing), self.assertRaisesRegex(gates.GateError, "Missing/uninstrumented"):
                self.coverage(report)

    def test_source_inventory_is_independent_of_report(self):
        new = self.root / "App/Uncovered.swift"
        new.write_text("func uncovered() { print(1) }\n")
        with self.assertRaisesRegex(gates.GateError, "Uncovered.swift"):
            self.coverage(self.xccov())

    def test_missing_library_target_inventory_fails(self):
        path = self.root / "Sources/MiledgeStorage/Fixture.swift"
        path.unlink()
        with self.assertRaisesRegex(gates.GateError, "MiledgeStorage"):
            self.coverage(self.xccov())

    def test_tests_and_build_generated_files_are_outside_inventory(self):
        for name in ("Tests", "AppTests", ".build/generated"):
            source = self.root / name / "Fixture.swift"
            source.parent.mkdir(parents=True)
            source.write_text("func ignored() {}\n")
        self.assertEqual(sorted(gates.source_inventory(self.root, "app")), self.files)

    def test_generated_marker_does_not_exempt_checked_in_source(self):
        (self.root / "App/Generated.swift").write_text("// @generated\nfunc generated() { print(1) }\n")
        with self.assertRaisesRegex(gates.GateError, "Generated.swift"):
            self.coverage(self.xccov())

    def test_zero_instrumented_lines_fails(self):
        with self.assertRaisesRegex(gates.GateError, "Uninstrumented"):
            self.coverage(self.xccov(0, 0))

    def test_noninteger_negative_and_out_of_bounds_counts_fail(self):
        for value in (True, False, 90.0, "90", None, -1, 101):
            report = self.xccov()
            report["targets"][0]["files"][0]["coveredLines"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.coverage(report)

    def test_invalid_percentages_fail_even_with_valid_counts(self):
        for value in (True, "0.9", -1, 1.1, float("nan"), float("inf"), 0.899):
            report = self.xccov()
            report["targets"][0]["files"][0]["lineCoverage"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.coverage(report)

    def test_target_sum_mismatch_fails(self):
        report = self.xccov()
        report["targets"][0]["coveredLines"] += 1
        with self.assertRaisesRegex(gates.GateError, "totals disagree"):
            self.coverage(report)

    def test_duplicate_source_and_target_fail_instead_of_double_counting(self):
        report = self.xccov()
        target = report["targets"][0]
        target["files"].append(copy.deepcopy(target["files"][0]))
        target.update(coveredLines=450, executableLines=500)
        with self.assertRaisesRegex(gates.GateError, "Duplicate first-party"):
            self.coverage(report)
        report = self.xccov()
        report["targets"].append(copy.deepcopy(report["targets"][0]))
        with self.assertRaisesRegex(gates.GateError, "Duplicate coverage target"):
            self.coverage(report)

    def test_unknown_first_party_file_report_fails(self):
        report = self.xccov()
        report["targets"][0]["files"][0]["path"] = "App/Deleted.swift"
        with self.assertRaisesRegex(gates.GateError, "stale or unknown"):
            self.coverage(report)

    def test_source_path_traversal_and_foreign_paths_cannot_substitute(self):
        for value in ("../App/Fixture.swift", "https://example.invalid/Fixture.swift", "/other/App/Fixture.swift"):
            report = self.xccov()
            report["targets"][0]["files"][0]["path"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.coverage(report)

    def test_source_symlinks_fail(self):
        source = self.root / "App/Alias.swift"
        source.symlink_to(self.root / "App/Fixture.swift")
        with self.assertRaisesRegex(gates.GateError, "symlink"):
            gates.source_inventory(self.root, "app")

    def test_llvm_missing_empty_and_invalid_totals_fail(self):
        for totals in (None, {}, {"lines": {"covered": 0, "count": 0}}, {"lines": {"covered": 271, "count": 300}}):
            report = self.llvm()
            report["data"][0]["totals"] = totals
            with self.subTest(totals=totals), self.assertRaises(gates.GateError):
                self.coverage(report, "llvm")

    def test_llvm_schema_data_and_file_summary_are_required(self):
        for key, value in (("version", "1.0.0"), ("type", "other"), ("data", []), ("data", [{}])):
            report = self.llvm()
            report[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(gates.GateError):
                self.coverage(report, "llvm")

    def test_current_apple_llvm_21_schema_is_supported(self):
        report = self.llvm()
        report["version"] = "3.0.1"
        self.assertEqual(self.coverage(report, "llvm")["lineCoverage"], 0.9)

    def test_malformed_json_and_duplicate_keys_fail(self):
        path = self.root / "report.json"
        for content in ("", "[]", "{", '{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}'):
            path.write_text(content)
            with self.subTest(content=content), self.assertRaises(gates.GateError):
                gates.load_json(path)

    def test_missing_json_file_fails(self):
        with self.assertRaises(gates.GateError):
            gates.load_json(self.root / "absent.json")

    def test_missing_security_runs_results_queries_and_provenance_fail(self):
        reports = [{}, {"version": "2.1.0", "runs": []}]
        for field in ("results", "invocations", "tool"):
            report = self.sarif(results=False)
            del report["runs"][0][field]
            reports.append(report)
        report = self.sarif(results=False)
        report["runs"][0]["tool"]["driver"]["rules"] = []
        reports.append(report)
        for report in reports:
            with self.subTest(report=report), self.assertRaises(gates.GateError):
                gates.check_sarif(report, "swift")

    def test_empty_findings_only_pass_with_valid_run_and_rule_inventory(self):
        self.assertEqual(gates.check_sarif(self.sarif(results=False), "swift")["findings"], 0)

    def test_medium_high_and_critical_security_findings_block(self):
        for severity in ("4", "6.9", "7", "8.9", "9", "10"):
            with self.subTest(severity=severity), self.assertRaisesRegex(gates.GateError, "Blocking"):
                gates.check_sarif(self.sarif(severity), "swift")

    def test_suppression_baseline_and_reduced_result_severity_cannot_bypass(self):
        report = self.sarif("9")
        report["runs"][0]["results"][0].update({
            "level": "none", "kind": "pass", "baselineState": "unchanged",
            "suppressions": [{"kind": "inSource", "status": "accepted"}],
            "properties": {"security-severity": "0"},
        })
        with self.assertRaisesRegex(gates.GateError, "Blocking"):
            gates.check_sarif(report, "swift")

    def test_error_security_findings_block_below_medium(self):
        with self.assertRaisesRegex(gates.GateError, "Blocking"):
            gates.check_sarif(self.sarif("0", "error"), "swift")

    def test_security_findings_without_severity_fail_closed(self):
        report = self.sarif()
        del report["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"]
        with self.assertRaisesRegex(gates.GateError, "Blocking"):
            gates.check_sarif(report, "swift")

    def test_malformed_severity_fails_even_when_no_findings(self):
        for severity in (True, None, {}, "NaN", "Infinity", "-1", "10.1", "medium"):
            with self.subTest(severity=severity), self.assertRaises(gates.GateError):
                gates.check_sarif(self.sarif(severity, results=False), "swift")

    def test_failed_scanner_status_warning_and_error_fail(self):
        for invocation in (
            {}, {"executionSuccessful": False}, {"executionSuccessful": 1},
            {"executionSuccessful": True, "exitCode": 1},
            {"executionSuccessful": True, "toolExecutionNotifications": [{"level": "warning"}]},
            {"executionSuccessful": True, "toolConfigurationNotifications": [{"level": "error"}]},
        ):
            report = self.sarif(results=False)
            report["runs"][0]["invocations"] = [invocation]
            with self.subTest(invocation=invocation), self.assertRaises(gates.GateError):
                gates.check_sarif(report, "swift")

    def test_wrong_scanner_version_or_language_fails(self):
        report = self.sarif()
        report["runs"][0]["tool"]["driver"]["semanticVersion"] = "2.26.0"
        with self.assertRaisesRegex(gates.GateError, "pinned"):
            gates.check_sarif(report, "swift")
        with self.assertRaisesRegex(gates.GateError, "python"):
            gates.check_sarif(self.sarif(), "python")

    def test_unresolvable_rule_and_invalid_rule_indices_fail(self):
        for value in (True, -1, 0.0, "0", 1):
            report = self.sarif()
            report["runs"][0]["results"][0]["ruleIndex"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                gates.check_sarif(report, "swift")

    def test_all_runs_are_inspected(self):
        report = self.sarif(results=False)
        report["runs"].extend(self.sarif("9")["runs"])
        with self.assertRaisesRegex(gates.GateError, "Blocking"):
            gates.check_sarif(report, "swift")

    def test_extraction_requires_every_app_and_library_source(self):
        rows = [[str(self.root / path)] for path in self.files]
        self.assertEqual(gates.check_extraction(rows, self.root, "swift")["files"], 4)
        for incomplete in ([], rows[:-1], rows[1:]):
            with self.subTest(rows=incomplete), self.assertRaisesRegex(gates.GateError, "Missing first-party"):
                gates.check_extraction(incomplete, self.root, "swift")

    def test_malformed_extraction_rows_fail(self):
        for rows in (None, {}, ["file"], [[1]], [["a", "b"]]):
            with self.subTest(rows=rows), self.assertRaises(gates.GateError):
                gates.check_extraction(rows, self.root, "swift")

    def test_python_extraction_requires_release_tools_not_test_fixtures(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "release.py").write_text("print(1)\n")
        (scripts / "tests").mkdir()
        (scripts / "tests/test_release.py").write_text("print(2)\n")
        with self.assertRaises(gates.GateError):
            gates.check_extraction([], self.root, "python")
        self.assertEqual(
            gates.check_extraction([["scripts/release.py"]], self.root, "python")["files"], 1
        )

    def test_supported_swift_compilers_and_unsupported_6_point_4(self):
        for version in ("5.4", "5.10.1", "6.0.3", "6.3.0"):
            self.assertEqual(gates.check_swift_version(f"Apple Swift version {version}\nTarget: arm64"), version)
        for output in ("", "unknown compiler", "Swift version 5.3", "Swift version 6.4.0", "Swift version 7.0"):
            with self.subTest(output=output), self.assertRaises(gates.GateError):
                gates.check_swift_version(output)

    def test_commit_run_and_checkout_provenance_must_match(self):
        environment = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
        with patch.dict(os.environ, environment, clear=True):
            with patch.object(subprocess, "check_output", return_value="a" * 40 + "\n"):
                self.assertEqual(gates.provenance(self.root)["commit"], "a" * 40)
            with patch.object(subprocess, "check_output", return_value="b" * 40 + "\n"):
                with self.assertRaisesRegex(gates.GateError, "match"):
                    gates.provenance(self.root)

    def test_missing_provenance_noninteger_and_nonascii_fail(self):
        for environment in (
            {}, {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "１２３", "GITHUB_RUN_ATTEMPT": "1"},
            {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "0"},
        ):
            with patch.dict(os.environ, environment, clear=True), self.assertRaises(gates.GateError):
                gates.provenance(self.root)

    def readiness(self):
        for name in ("Tests", "AppTests", "scripts", ".github/workflows"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for name in ("Package.swift", "project.yml"):
            (self.root / name).write_text("fixture")
        return {
            "schemaVersion": 1, "reviewedSourceDigest": gates.readiness_digest(self.root),
            "checks": {
                name: {"status": "passed", "evidence": "Synthetic unit-test evidence"}
                for name in gates.READINESS_CHECKS
            },
        }

    def test_readiness_requires_passed_checks_real_evidence_and_matching_inputs(self):
        path = self.root / "readiness.json"
        evidence = self.readiness()
        path.write_text(json.dumps(evidence))
        gates.check_readiness(path, self.root)
        for name in gates.READINESS_CHECKS:
            modified = copy.deepcopy(evidence)
            modified["checks"][name]["status"] = "planned"
            path.write_text(json.dumps(modified))
            with self.subTest(name=name), self.assertRaisesRegex(gates.GateError, "still blocked"):
                gates.check_readiness(path, self.root)
        evidence["checks"][gates.READINESS_CHECKS[0]]["evidence"] = ""
        path.write_text(json.dumps(evidence))
        with self.assertRaisesRegex(gates.GateError, "Missing real"):
            gates.check_readiness(path, self.root)

    def test_readiness_digest_changes_when_app_or_release_gate_changes(self):
        evidence = self.readiness()
        (self.root / "scripts/gates.py").write_text("changed")
        self.assertNotEqual(evidence["reviewedSourceDigest"], gates.readiness_digest(self.root))

    def test_upload_evidence_cannot_be_from_other_run_or_omit_reports(self):
        directory = self.root / ".build/gates"
        directory.mkdir(parents=True)
        current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        config = self.upload_config()
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaises(gates.GateError):
                gates.verify_upload_evidence(self.root, directory, config)
            evidence = {
                "provenance": {**current, "runId": "122"},
                "sources": gates.interaction_sources(self.root),
            }
            (directory / "interaction-ios-iphone.json").write_text(json.dumps(evidence))
            with self.assertRaisesRegex(gates.GateError, "another commit/run"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_upload_rechecks_raw_reports_instead_of_trusting_pass_marker(self):
        directory = self.root / ".build/gates"
        directory.mkdir(parents=True)
        current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        config = self.upload_config()
        interaction_fixtures.write_evidence(self.root, directory, current, config)
        report = json.dumps(self.xccov(89, 100))
        (directory / "xccov-ios-iphone.json").write_text(report)
        evidence = {
            "provenance": current, "sources": gates.source_inventory(self.root, "app"),
            "scheme": "Miledge-iOS", "coverage": {"lineCoverage": 1.0},
            "reportSHA256": hashlib.sha256(report.encode()).hexdigest(),
        }
        (directory / "coverage-ios-iphone.json").write_text(json.dumps(evidence))
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "below 90"):
                gates.verify_upload_evidence(self.root, directory, config)

    def upload_fixtures(self):
        current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        config = self.upload_config()
        directory = self.root / ".build/gates"
        directory.mkdir(parents=True)
        self.readiness()
        (self.root / "scripts/release.py").write_text("synthetic")
        repository = Path(__file__).resolve().parents[2]
        for name in swift_security.inputs(repository):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((repository / name).read_bytes())
        (self.root / "docs").mkdir()
        evidence = self.readiness()
        (self.root / "docs/release-readiness.json").write_text(json.dumps(evidence))
        interaction_fixtures.write_evidence(self.root, directory, current, config)
        for key, scheme in (
            ("ios-iphone", "Miledge-iOS"), ("ios-ipad", "Miledge-iOS"), ("macos", "Miledge-macOS"),
        ):
            report = self.xccov()
            report["targets"][0]["name"] = "Miledge.app"
            report_bytes = json.dumps(report).encode()
            (directory / f"xccov-{key}.json").write_bytes(report_bytes)
            evidence = {
                "provenance": current, "scheme": scheme,
                "sources": gates.source_inventory(self.root, "app"),
                "reportSHA256": hashlib.sha256(report_bytes).hexdigest(),
            }
            (directory / f"coverage-{key}.json").write_text(json.dumps(evidence))
        report = {
            "version": swift_security.SEMGREP_VERSION, "engine_requested": "OSS",
            "errors": [], "skipped_rules": [], "paths": {"scanned": self.files},
            "results": [{
                "check_id": swift_security.PARSER_RULE, "path": path,
                "start": {"line": 1, "col": 1, "offset": 0},
                "end": {"line": 1, "col": 18, "offset": 17},
                "extra": {"severity": "INFO", "engine_kind": "OSS"},
            } for path in self.files],
        }
        positive, _ = swift_security.fixture_expectations(self.root)
        tests = {
            "config_missing_tests": [], "config_missing_fixtests": [], "config_with_errors": [],
            "fixtest_results": {}, "results": {swift_security.RULES: {"checks": {
                rule: {"passed": True, "errors": [], "matches": {swift_security.FIXTURE: {
                    "expected_lines": sorted(lines), "reported_lines": sorted(lines),
                }}} for rule, lines in positive.items()
            }}},
        }
        for name, data in (("swift-semgrep.json", report), ("swift-rule-tests.json", tests)):
            (directory / name).write_text(json.dumps(data))
        evidence = {
            "schemaVersion": 1, "provenance": current,
            "scanner": {"name": "Semgrep CE", "version": swift_security.SEMGREP_VERSION},
            "networkPolicy": swift_security.NETWORK_POLICY,
            "sources": gates.source_inventory(self.root, "app"), "inputs": swift_security.inputs(self.root),
            "reportSHA256": hashlib.sha256((directory / "swift-semgrep.json").read_bytes()).hexdigest(),
            "ruleTestsSHA256": hashlib.sha256((directory / "swift-rule-tests.json").read_bytes()).hexdigest(),
            "analysis": swift_security.check_scan(report, self.root),
            "ruleTests": swift_security.check_rule_tests(tests, self.root),
        }
        (directory / "security-swift.json").write_text(json.dumps(evidence))
        for language in ("python",):
            report = self.sarif(results=False)
            report["runs"][0]["tool"]["driver"]["rules"][0]["id"] = language + "/example"
            report_bytes = json.dumps(report).encode()
            (directory / f"{language}.sarif").write_bytes(report_bytes)
            rows = [[path.relative_to(self.root).as_posix()] for path in (self.root / "scripts").rglob("*.py")]
            extraction = json.dumps(rows).encode()
            (directory / f"extracted-{language}.json").write_bytes(extraction)
            evidence = {
                "provenance": current, "codeqlAction": gates.CODEQL_ACTION,
                "sources": gates.source_inventory(self.root, "app"),
                "reportSHA256": hashlib.sha256(report_bytes).hexdigest(),
                "extractionSHA256": hashlib.sha256(extraction).hexdigest(),
            }
            (directory / f"security-{language}.json").write_text(json.dumps(evidence))
        self.write_security_review()
        return current, config, directory

    def write_security_review(self):
        report = self.root / "docs/security-reviews/synthetic.md"
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text("Synthetic regression fixture; not a real security assessment.\n")
        review = {
            "schemaVersion": 1, "status": "approved",
            "reviewedSourceDigest": gates.readiness_digest(self.root),
            "reviewer": {"identity": "synthetic-reviewer"},
            "implementationAuthors": ["synthetic-author"],
            "independenceEvidence": "Synthetic separate implementation and review roles.",
            "reviewDate": "2026-01-01",
            "scopes": {
                scope: {"status": "reviewed", "evidence": "Synthetic scoped assessment."}
                for scope in gates.SECURITY_REVIEW_SCOPES
            },
            "findings": [], "residualRiskAcceptance": "Synthetic risk acceptance.",
            "report": {"path": report.relative_to(self.root).as_posix(),
                       "sha256": hashlib.sha256(report.read_bytes()).hexdigest()},
        }
        path = self.root / "docs/release-security-review.json"
        path.write_text(json.dumps(review))
        private = self.root / ".build/synthetic-reviewer.pem"
        public = self.root / ".build/synthetic-reviewer-public.pem"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(private)],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private), "-out",
                        str(path.with_suffix(".sig")), str(path)], check=True, capture_output=True)
        environment = patch.dict(os.environ, {
            "SECURITY_REVIEWER_ID": "synthetic-reviewer",
            "SECURITY_REVIEW_PUBLIC_KEY": public.read_text(),
        })
        environment.start()
        self.addCleanup(environment.stop)
        return path, review

    def upload_config(self):
        return {
            "IOS_SCHEME": "Miledge-iOS", "MACOS_SCHEME": "Miledge-macOS",
            "IOS_TEST_DESTINATION": "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "IPAD_TEST_DESTINATION": "platform=iOS Simulator,name=iPad mini (6th generation),OS=27.0",
        }

    def test_upload_requires_and_revalidates_complete_fresh_evidence(self):
        current, config, directory = self.upload_fixtures()
        with patch.object(gates, "provenance", return_value=current):
            gates.verify_upload_evidence(self.root, directory, config)

    def test_upload_rejects_tampered_report_digest(self):
        current, config, directory = self.upload_fixtures()
        (directory / "swift-semgrep.json").write_text("{}")
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "digest mismatch"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_upload_rejects_missing_python_scan_even_when_swift_is_clean(self):
        current, config, directory = self.upload_fixtures()
        (directory / "security-python.json").unlink()
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "security-python"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_upload_rejects_unextracted_storage_source(self):
        current, config, directory = self.upload_fixtures()
        report = gates.load_json(directory / "swift-semgrep.json")
        report["paths"]["scanned"] = [self.files[0]]
        report_path = directory / "swift-semgrep.json"
        report_path.write_text(json.dumps(report))
        evidence = gates.load_json(directory / "security-swift.json")
        evidence["reportSHA256"] = hashlib.sha256(report_path.read_bytes()).hexdigest()
        (directory / "security-swift.json").write_text(json.dumps(evidence))
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "every production"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_upload_rejects_unapproved_semgrep_version(self):
        current, config, directory = self.upload_fixtures()
        evidence = gates.load_json(directory / "security-swift.json")
        evidence["scanner"]["version"] = "1.180.0"
        (directory / "security-swift.json").write_text(json.dumps(evidence))
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "unapproved scanner"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_clean_coverage_and_scanning_do_not_bypass_independent_review(self):
        current, config, directory = self.upload_fixtures()
        path = self.root / "docs/release-security-review.json"
        review = gates.load_json(path)
        review["status"] = "blocked"
        path.write_text(json.dumps(review))
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "Independent security review is still blocked"):
                gates.verify_upload_evidence(self.root, directory, config)

    def test_security_review_rejects_missing_stale_self_review_or_incomplete_scopes(self):
        self.upload_fixtures()
        path = self.root / "docs/release-security-review.json"
        original = gates.load_json(path)
        for name, value in (
            ("reviewedSourceDigest", "b" * 64), ("implementationAuthors", ["synthetic-reviewer"]),
            ("scopes", {}), ("reviewDate", "2099-01-01"), ("residualRiskAcceptance", ""),
            ("findings", [{"id": "S1", "severity": "high", "status": "open"}]),
        ):
            review = copy.deepcopy(original)
            review[name] = value
            path.write_text(json.dumps(review))
            with self.subTest(name=name), self.assertRaises(gates.GateError):
                gates.check_security_review(self.root)
        path.unlink()
        with self.assertRaises(gates.GateError):
            gates.check_security_review(self.root)

    def test_security_review_requires_trusted_signature_and_report_digest(self):
        self.upload_fixtures()
        path = self.root / "docs/release-security-review.json"
        original = path.read_bytes()
        gates.check_security_review(self.root)
        path.write_bytes(original + b"\n")
        with self.assertRaisesRegex(gates.GateError, "signature is invalid"):
            gates.check_security_review(self.root)
        path.write_bytes(original)
        with patch.dict(os.environ, {"SECURITY_REVIEW_PUBLIC_KEY": ""}):
            with self.assertRaisesRegex(gates.GateError, "public key"):
                gates.check_security_review(self.root)
        (self.root / "docs/security-reviews/synthetic.md").write_text("tampered")
        with self.assertRaisesRegex(gates.GateError, "report digest"):
            gates.check_security_review(self.root)

    def test_security_review_rejects_missing_scope_evidence_unknown_reviewer_and_unresolved_low_finding(self):
        self.upload_fixtures()
        path = self.root / "docs/release-security-review.json"
        original = gates.load_json(path)
        for mutation in ("scope-evidence", "reviewer", "date", "low-finding", "missing-findings", "report-traversal"):
            review = copy.deepcopy(original)
            if mutation == "scope-evidence":
                review["scopes"][gates.SECURITY_REVIEW_SCOPES[0]]["evidence"] = ""
            elif mutation == "reviewer":
                review["reviewer"]["identity"] = "implementation-author"
            elif mutation == "date":
                review["reviewDate"] = None
            elif mutation == "low-finding":
                review["findings"] = [{"id": "S1", "severity": "low", "status": "accepted"}]
            elif mutation == "missing-findings":
                del review["findings"]
            else:
                review["report"]["path"] = "docs/security-reviews/../release-security-review.json"
            path.write_text(json.dumps(review))
            with self.subTest(mutation=mutation), self.assertRaises(gates.GateError):
                gates.check_security_review(self.root)

    def test_security_review_missing_signature_invalid_key_and_verifier_failure_block(self):
        self.upload_fixtures()
        signature = self.root / "docs/release-security-review.sig"
        content = signature.read_bytes()
        signature.unlink()
        with self.assertRaises(gates.GateError):
            gates.check_security_review(self.root)
        signature.write_bytes(content)
        with patch.dict(os.environ, {"SECURITY_REVIEW_PUBLIC_KEY": "not a public key"}):
            with self.assertRaisesRegex(gates.GateError, "signature is invalid"):
                gates.check_security_review(self.root)
        with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("openssl", 30)):
            with self.assertRaisesRegex(gates.GateError, "Cannot verify"):
                gates.check_security_review(self.root)

    def test_clean_coverage_and_scanning_do_not_bypass_product_readiness(self):
        current, config, directory = self.upload_fixtures()
        path = self.root / "docs/release-readiness.json"
        evidence = gates.load_json(path)
        evidence["checks"]["portableEncryptedBackup"]["status"] = "blocked"
        path.write_text(json.dumps(evidence))
        with patch.object(gates, "provenance", return_value=current):
            with self.assertRaisesRegex(gates.GateError, "portableEncryptedBackup"):
                gates.verify_upload_evidence(self.root, directory, config)


if __name__ == "__main__":
    unittest.main()
