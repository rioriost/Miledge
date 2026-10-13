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
import security


class SecurityRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miledge-security-", dir=Path.cwd())
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "Miledge.xcodeproj").mkdir()
        for name in ("App", *(f"Sources/{name}" for name in gates.LIBRARIES)):
            source = self.root / name / "Fixture.swift"
            source.parent.mkdir(parents=True)
            source.write_text("func fixture() { print(1) }")
        self.directory = self.root / ".build/gates"
        self.directory.mkdir(parents=True)
        self.sarif = self.directory / "swift.sarif"
        self.sarif.write_text(json.dumps({
            "version": "2.1.0", "runs": [{
                "tool": {"driver": {
                    "name": "CodeQL", "semanticVersion": gates.CODEQL_VERSION,
                    "rules": [{"id": "swift/example", "properties": {
                        "tags": ["security"], "security-severity": "3",
                    }}],
                }},
                "invocations": [{"executionSuccessful": True}], "results": [],
            }],
        }))
        self.addCleanup(patch.stopall)
        patch.object(security, "ROOT", self.root).start()
        patch.dict(os.environ, {
            "XCODE_VERSION": "27.0", "XCODE_BUILD_VERSION": "synthetic",
            "XCODE_PROJECT": "Miledge.xcodeproj",
            "IOS_SCHEME": "Miledge-iOS", "MACOS_SCHEME": "Miledge-macOS",
        }).start()

    def verify(self):
        security.verify(
            "swift", self.root / "codeql", self.root / ".build/codeql-db/swift",
            self.sarif, self.directory,
        )

    def test_clean_manual_package_and_both_native_builds_are_traced(self):
        def command(arguments, **kwargs):
            return b"Apple Swift version 6.3.0\n" if arguments[:2] == ["xcrun", "swift"] else b""

        with patch.object(security.release, "check_xcode"):
            with patch.object(security.release, "run", side_effect=command) as run:
                security.build_swift()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[1][:3], ["swift", "package", "clean"])
        self.assertEqual(commands[2][:2], ["swift", "build"])
        self.assertIn("--arch", commands[2])
        for command, scheme in zip(commands[3:], ("Miledge-iOS", "Miledge-macOS")):
            self.assertEqual(command[:3], ["xcodebuild", "clean", "build"])
            self.assertIn(scheme, command)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
            self.assertIn("ARCHS=arm64", command)

    def test_unsupported_swift_stops_before_any_build(self):
        with patch.object(security.release, "check_xcode"):
            with patch.object(security.release, "run", return_value=b"Apple Swift version 6.4.0") as run:
                with self.assertRaisesRegex(gates.GateError, "unsupported"):
                    security.build_swift()
                self.assertEqual(run.call_count, 1)

    def test_tool_failure_removes_stale_success_evidence(self):
        path = self.directory / "security-swift.json"
        path.write_text('{"old":"passed"}')
        with patch.object(subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, ["codeql"])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.verify()
        self.assertFalse(path.exists())

    def test_wrong_cli_version_fails_before_query_execution(self):
        with patch.object(subprocess, "check_output", return_value=b'{"version":"2.26.0"}'):
            with patch.object(subprocess, "run") as run:
                with self.assertRaisesRegex(gates.GateError, "pinned version"):
                    self.verify()
                run.assert_not_called()

    def test_missing_source_inventory_fails_after_scanner_analyze_success(self):
        outputs = [
            json.dumps({"version": gates.CODEQL_VERSION}).encode(),
            b'{"#select":{"tuples":[]}}',
        ]
        with patch.object(subprocess, "check_output", side_effect=outputs), patch.object(subprocess, "run"):
            with self.assertRaisesRegex(gates.GateError, "Missing first-party"):
                self.verify()
        self.assertFalse((self.directory / "security-swift.json").exists())

    def test_verified_scan_writes_commit_bound_evidence_and_fresh_extraction(self):
        rows = [[str(self.root / path)] for path in gates.source_inventory(self.root, "app")]
        outputs = [
            json.dumps({"version": gates.CODEQL_VERSION}).encode(),
            json.dumps({"#select": {"tuples": rows}}).encode(),
        ]
        current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        with (
            patch.object(subprocess, "check_output", side_effect=outputs),
            patch.object(subprocess, "run") as run,
            patch.object(gates, "provenance", return_value=current),
            patch.object(security.release, "run", return_value=b"Apple Swift version 6.3.0"),
        ):
            self.verify()
        evidence = gates.load_json(self.directory / "security-swift.json")
        self.assertEqual(evidence["provenance"], current)
        self.assertEqual(evidence["codeqlAction"], gates.CODEQL_ACTION)
        self.assertEqual(evidence["swiftVersion"], "6.3.0")
        self.assertEqual(json.loads((self.directory / "extracted-swift.json").read_text()), rows)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][1:3], ["pack", "install"])
        self.assertEqual(commands[1][1:3], ["query", "run"])

    def test_python_release_route_extracts_all_tools_without_swift_build_or_compiler(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("release.py", "swift_security.py"):
            (scripts / name).write_text("synthetic = True\n")
        report = gates.load_json(self.sarif)
        report["runs"][0]["tool"]["driver"]["rules"][0]["id"] = "python/example"
        sarif = self.directory / "python.sarif"
        sarif.write_text(json.dumps(report))
        rows = [["scripts/release.py"], ["scripts/swift_security.py"]]
        outputs = [
            json.dumps({"version": gates.CODEQL_VERSION}).encode(),
            json.dumps({"#select": {"tuples": rows}}).encode(),
        ]
        current = {"commit": "a" * 40, "runId": "123", "runAttempt": "1"}
        with (
            patch.object(subprocess, "check_output", side_effect=outputs),
            patch.object(subprocess, "run") as run,
            patch.object(gates, "provenance", return_value=current),
            patch.object(security.release, "run") as compiler,
        ):
            security.verify("python", self.root / "codeql", self.root / ".build/codeql-db/python",
                            sarif, self.directory)
        compiler.assert_not_called()
        self.assertIn("scripts/codeql/python/inventory.ql", run.call_args.args[0][3])
        evidence = gates.load_json(self.directory / "security-python.json")
        self.assertEqual(evidence["provenance"], current)
        self.assertEqual(evidence["extraction"], {"files": 2, "language": "python"})
        self.assertNotIn("swiftVersion", evidence)
        self.assertEqual(json.loads((self.directory / "extracted-python.json").read_text()), rows)


if __name__ == "__main__":
    unittest.main()
