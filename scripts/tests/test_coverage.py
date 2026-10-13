import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import coverage
import gates


class CoverageRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miledge-coverage-", dir=Path.cwd())
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.scratch = self.root / ".build/package-coverage"
        self.products = self.scratch / "out/Products/Debug"
        self.report = self.root / ".build/gates/package-llvm.json"
        self.products.mkdir(parents=True)
        self.addCleanup(patch.stopall)
        patch.object(coverage, "ROOT", self.root).start()
        patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}).start()

    def create_binary(self, name):
        binary = self.products / f"{name}.xctest"
        if sys.platform == "darwin":
            path = binary / "Contents/MacOS" / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"synthetic")
        else:
            binary.write_bytes(b"synthetic")

    def test_all_separate_test_bundles_and_profiles_are_combined(self):
        stale = self.scratch / "old.profraw"
        stale.write_bytes(b"stale")
        for name in gates.LIBRARIES:
            self.create_binary(name + "Tests")

        def command(arguments, **kwargs):
            if arguments[:2] == ["swift", "test"]:
                self.assertFalse(stale.exists())
                self.assertIn("--enable-code-coverage", arguments)
                for name in gates.LIBRARIES:
                    (self.products / f"{name}.profraw").write_bytes(b"fresh synthetic profile")

        def output(arguments, **kwargs):
            if arguments[:2] == ["swift", "build"]:
                return str(self.products)
            self.assertIn("export", arguments)
            self.assertEqual(sum(argument.startswith("-object=") for argument in arguments), 2)
            return b'{"synthetic":true}'

        with patch.object(subprocess, "run", side_effect=command) as run:
            with patch.object(subprocess, "check_output", side_effect=output):
                coverage.measure(self.report)
        merge = run.call_args_list[1].args[0]
        self.assertIn("merge", merge)
        self.assertEqual(sum(argument.endswith(".profraw") for argument in merge), 3)
        self.assertEqual(json.loads(self.report.read_text()), {"synthetic": True})

    def test_failed_tests_do_not_export_or_preserve_stale_report(self):
        self.report.parent.mkdir(parents=True)
        self.report.write_text('{"old":true}')
        with patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["swift"])):
            with patch.object(subprocess, "check_output") as output:
                with self.assertRaises(subprocess.CalledProcessError):
                    coverage.measure(self.report)
                output.assert_not_called()
        self.assertFalse(self.report.exists())

    def test_missing_test_binary_fails(self):
        with patch.object(subprocess, "run"), patch.object(
            subprocess, "check_output", return_value=str(self.products)
        ):
            with self.assertRaisesRegex(gates.GateError, "test binaries"):
                coverage.measure(self.report)

    def test_missing_fresh_profile_fails(self):
        self.create_binary("MiledgeTests")
        stale = self.scratch / "stale.profraw"
        stale.write_bytes(b"stale")
        with patch.object(subprocess, "run"), patch.object(
            subprocess, "check_output", return_value=str(self.products)
        ):
            with self.assertRaisesRegex(gates.GateError, "fresh"):
                coverage.measure(self.report)
        self.assertFalse(stale.exists())


if __name__ == "__main__":
    unittest.main()
