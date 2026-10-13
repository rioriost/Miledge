import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gates
import interaction_fixtures
import release


class InteractionResultTests(unittest.TestCase):
    def setUp(self):
        self.scheme = gates.INTERACTION_SCHEMES["macos"]
        self.reports = interaction_fixtures.reports(self.scheme)

    def check(self):
        return gates.check_interactions(
            self.reports["summary"], self.reports["tests"], self.reports["availability"], self.scheme
        )

    def cases(self):
        return self.reports["tests"]["testNodes"][0]["children"][0]["children"]

    def test_passed_nonzero_ui_tests_are_required(self):
        self.assertEqual(self.check()["executedTests"], 2)

    def test_zero_tests_fail_even_when_result_says_passed(self):
        self.reports = interaction_fixtures.reports(self.scheme, 0)
        with self.assertRaisesRegex(gates.GateError, "nonzero"):
            self.check()

    def test_missing_noninteger_negative_or_inconsistent_counts_fail(self):
        for value in (None, True, "2", 2.0, -1, 0, 3):
            self.reports = interaction_fixtures.reports(self.scheme)
            self.reports["summary"]["totalTestCount"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.check()

    def test_failed_skipped_and_expected_failures_block(self):
        for name in ("failedTests", "skippedTests", "expectedFailures"):
            self.reports = interaction_fixtures.reports(self.scheme)
            self.reports["summary"][name] = 1
            with self.subTest(name=name), self.assertRaises(gates.GateError):
                self.check()

    def test_nonpassing_summary_and_wrong_scheme_fail(self):
        for result in ("Failed", "Skipped", "Expected Failure", "unknown", None):
            self.reports["summary"]["result"] = result
            with self.subTest(result=result), self.assertRaises(gates.GateError):
                self.check()
        self.reports = interaction_fixtures.reports("Miledge-macOS")
        with self.assertRaisesRegex(gates.GateError, "required scheme"):
            self.check()

    def test_runtime_warnings_and_failure_details_block_even_with_zero_counts(self):
        for name in ("runtimeWarnings", "testFailures"):
            for value in (None, {}, [{"message": "Synthetic runtime warning"}]):
                self.reports = interaction_fixtures.reports(self.scheme)
                self.reports["summary"][name] = value
                with self.subTest(name=name, value=value), self.assertRaises(gates.GateError):
                    self.check()

    def test_missing_results_or_unexpected_coverage_profiles_fail(self):
        for name, value in (
            ("hasTestResults", None), ("hasTestResults", False), ("hasTestResults", 1),
            ("hasCoverage", None), ("hasCoverage", True), ("hasCoverage", 0),
        ):
            self.reports = interaction_fixtures.reports(self.scheme)
            self.reports["availability"][name] = value
            with self.subTest(name=name, value=value), self.assertRaises(gates.GateError):
                self.check()

    def test_no_executed_device_inventory_is_not_success(self):
        for value in (None, {}, [], [{}]):
            self.reports["tests"]["devices"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.check()

    def test_device_execution_counts_and_provenance_must_match(self):
        for field, value in (
            ("passedTests", 0), ("passedTests", True), ("failedTests", 1),
            ("skippedTests", 1), ("expectedFailures", 1), ("device", {"deviceId": "unknown"}),
        ):
            self.reports = interaction_fixtures.reports(self.scheme)
            self.reports["summary"]["devicesAndConfigurations"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(gates.GateError):
                self.check()

    def test_missing_test_tree_is_not_success(self):
        for value in (None, {}, [], [{}]):
            self.reports["tests"]["testNodes"] = value
            with self.subTest(value=value), self.assertRaises(gates.GateError):
                self.check()

    def test_unit_tests_cannot_substitute_for_xcuitests(self):
        self.reports["tests"]["testNodes"][0]["children"][0]["nodeType"] = "Unit test bundle"
        with self.assertRaises(gates.GateError):
            self.check()

    def test_unknown_skipped_failed_and_runtime_warning_nodes_block(self):
        for kind in ("Runtime Warning", "Skip Message", "Failure Message", "Expected Failure", "unknown"):
            self.reports = interaction_fixtures.reports(self.scheme)
            self.cases()[0]["children"] = [{"nodeType": kind, "name": "Synthetic diagnostic"}]
            with self.subTest(kind=kind), self.assertRaises(gates.GateError):
                self.check()

    def test_nested_test_results_cannot_hide_retried_failures(self):
        self.cases()[0]["children"] = [{
            "nodeType": "Test Case Run", "name": "Attempt 1", "result": "Failed",
        }]
        with self.assertRaisesRegex(gates.GateError, "non-passing"):
            self.check()

    def test_duplicate_test_cases_and_missing_identifiers_fail(self):
        self.cases()[1]["nodeIdentifier"] = self.cases()[0]["nodeIdentifier"]
        with self.assertRaisesRegex(gates.GateError, "Duplicate"):
            self.check()
        self.reports = interaction_fixtures.reports(self.scheme)
        del self.cases()[0]["nodeIdentifier"]
        with self.assertRaisesRegex(gates.GateError, "identifiable"):
            self.check()

    def test_tree_count_must_match_summary(self):
        self.cases().pop()
        with self.assertRaisesRegex(gates.GateError, "test tree disagrees"):
            self.check()


class InteractionRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miledge-interactions-", dir=Path.cwd())
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        for name in ("App", *(f"Sources/{name}" for name in gates.LIBRARIES)):
            path = self.root / name / "Fixture.swift"
            path.parent.mkdir(parents=True)
            path.write_text("func synthetic() {}\n")
        interaction_fixtures.source_files(self.root)
        self.directory = self.root / ".build/gates"
        self.directory.mkdir(parents=True)
        self.config = {
            "XCODE_PROJECT": "Miledge.xcodeproj", "IOS_SCHEME": "Miledge-iOS",
            "MACOS_SCHEME": "Miledge-macOS",
            "IOS_TEST_DESTINATION": "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "IPAD_TEST_DESTINATION": "platform=iOS Simulator,name=iPad Pro (M5),OS=27.0",
        }
        self.scheme = gates.INTERACTION_SCHEMES["macos"]
        self.current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        self.addCleanup(patch.stopall)
        patch.object(release, "ROOT", self.root).start()
        patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}).start()

    def runner(self, reports=None):
        reports = reports or interaction_fixtures.reports(self.scheme)

        def command(arguments, **kwargs):
            if arguments[0] == "xcodebuild":
                return b""
            kind = (
                "availability" if "content-availability" in arguments
                else arguments[arguments.index("test-results") + 1]
            )
            return json.dumps(reports[kind]).encode()

        return command

    def test_valid_interactions_emit_raw_reports_and_ci_bound_evidence(self):
        with (
            patch.object(release, "run", side_effect=self.runner()) as run,
            patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}),
            patch.object(gates, "provenance", return_value=self.current),
        ):
            release.test_interaction(
                self.config, "macos", "macos", "platform=macOS,arch=arm64", self.directory
            )
        arguments = run.call_args_list[0].args[0]
        self.assertIn(self.scheme, arguments)
        self.assertIn("Release", arguments)
        signing = [
            argument for argument in arguments
            if argument.startswith(("CODE_SIGN", "DEVELOPMENT_TEAM", "PROVISIONING_PROFILE"))
        ]
        self.assertEqual(signing, [
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Manual",
        ])
        self.assertNotIn("ENABLE_TESTABILITY=YES", arguments)
        self.assertNotIn("-allowProvisioningUpdates", arguments)
        self.assertFalse(any("keychain" in argument.lower() for argument in arguments))
        self.assertEqual(arguments[arguments.index("-enableCodeCoverage") + 1], "NO")
        self.assertEqual(arguments[arguments.index("-parallel-testing-enabled") + 1], "NO")
        self.assertEqual(arguments[arguments.index("-test-timeouts-enabled") + 1], "YES")
        self.assertEqual(arguments[arguments.index("-maximum-test-execution-time-allowance") + 1], "90")
        self.assertNotIn("-test-iterations", arguments)
        self.assertNotIn("-retry-tests-on-failure", arguments)
        self.assertNotIn("-run-tests-until-failure", arguments)
        self.assertFalse(any(argument.startswith(("-skip-testing", "-only-testing")) for argument in arguments))
        evidence = gates.load_json(self.directory / "interaction-macos.json")
        self.assertEqual(evidence["provenance"], self.current)
        for kind in ("summary", "tests", "availability"):
            path = self.directory / f"interaction-{kind}-macos.json"
            self.assertEqual(evidence[kind + "SHA256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_runtime_warnings_invalidate_previous_success(self):
        reports = interaction_fixtures.reports(self.scheme)
        reports["summary"]["runtimeWarnings"] = [{"message": "Synthetic warning"}]
        evidence = self.directory / "interaction-macos.json"
        evidence.write_text('{"old":"passed"}')
        with patch.object(release, "run", side_effect=self.runner(reports)):
            with self.assertRaisesRegex(gates.GateError, "runtimeWarnings"):
                release.test_interaction(
                    self.config, "macos", "macos", "platform=macOS,arch=arm64", self.directory
                )
        self.assertFalse(evidence.exists())

    def test_interaction_failure_prevents_every_production_coverage_run(self):
        for key in ("ios-iphone", "ios-ipad"):
            for prefix in ("coverage", "interaction"):
                (self.directory / f"{prefix}-{key}.json").write_text('{"old":"passed"}')
        with (
            patch.object(release, "test_interaction", side_effect=[
                None, gates.GateError("Synthetic iPad interaction failure"),
            ]) as interactions,
            patch.object(release, "run") as run,
        ):
            with self.assertRaisesRegex(gates.GateError, "iPad interaction"):
                release.test_platform(self.config, "ios")
        self.assertEqual(interactions.call_count, 2)
        run.assert_not_called()
        for key in ("ios-iphone", "ios-ipad"):
            self.assertFalse((self.directory / f"coverage-{key}.json").exists())

    def test_missing_interaction_sources_fail_before_build(self):
        (self.root / "InteractionHost/Synthetic.swift").unlink()
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(gates.GateError, "interaction Swift sources"):
                release.test_interaction(
                    self.config, "macos", "macos", "platform=macOS,arch=arm64", self.directory
                )
        run.assert_not_called()

    def test_interaction_fixture_files_do_not_enter_production_coverage_inventory(self):
        inventory = gates.source_inventory(self.root, "app")
        self.assertEqual(len(inventory), 4)
        self.assertFalse(any(path.startswith("Interaction") for path in inventory))
        self.assertEqual(len(gates.interaction_sources(self.root)), 6)

    def test_automation_permissions_failure_remains_a_release_blocker(self):
        with patch.object(release, "run", side_effect=release.ReleaseError(
            "Synthetic automation initialization failure"
        )) as run:
            with self.assertRaisesRegex(release.ReleaseError, "automation"):
                release.test_interaction(
                    self.config, "macos", "macos", "platform=macOS,arch=arm64", self.directory
                )
        self.assertEqual(run.call_count, 1)
        self.assertFalse((self.directory / "interaction-macos.json").exists())


if __name__ == "__main__":
    unittest.main()
