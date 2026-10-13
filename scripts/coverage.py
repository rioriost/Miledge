"""Measure and gate all package Sources/ executable lines with llvm-cov JSON."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import gates


ROOT = Path(__file__).resolve().parents[1]


def measure(report: Path) -> None:
    report.unlink(missing_ok=True)
    report.parent.mkdir(parents=True, exist_ok=True)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        import release
        release.check_xcode({
            key: release.required(key) for key in ("XCODE_VERSION", "XCODE_BUILD_VERSION")
        })
    scratch = ROOT / ".build/package-coverage"
    for pattern in ("*.profraw", "*.profdata"):
        for previous in scratch.rglob(pattern):
            previous.unlink()
    subprocess.run(
        ["swift", "test", "--enable-code-coverage", "--scratch-path", str(scratch)],
        cwd=ROOT, check=True,
    )
    products = subprocess.check_output(
        ["swift", "build", "--show-bin-path", "--scratch-path", str(scratch)],
        cwd=ROOT, text=True,
    ).strip()
    binaries = sorted(Path(products).glob("*.xctest"))
    if not binaries:
        raise gates.GateError("Missing instrumented Swift package test binaries.")
    objects = [
        binary / "Contents/MacOS" / binary.stem if binary.is_dir() else binary
        for binary in binaries
    ]
    profiles = sorted(scratch.rglob("*.profraw"))
    if not profiles:
        raise gates.GateError("Missing fresh instrumented Swift package profiles.")
    profiler = ["xcrun", "llvm-profdata"] if sys.platform == "darwin" else ["llvm-profdata"]
    merged = scratch / "coverage.profdata"
    subprocess.run(
        [*profiler, "merge", "--sparse", *map(str, profiles), "-o", str(merged)],
        cwd=ROOT, check=True,
    )
    command = ["xcrun", "llvm-cov"] if sys.platform == "darwin" else ["llvm-cov"]
    output = subprocess.check_output(
        [
            *command, "export", str(objects[0]), f"-instr-profile={merged}",
            *(f"-object={binary}" for binary in objects[1:]),
        ], cwd=ROOT
    )
    report.write_bytes(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("swift",))
    parser.add_argument("--report", type=Path, default=ROOT / ".build/gates/package-llvm.json")
    parser.add_argument("--measure", action="store_true", help="Run swift test and llvm-cov before gating")
    args = parser.parse_args()
    try:
        if args.measure:
            measure(args.report)
        result = gates.check_coverage(
            gates.load_json(args.report), ROOT, format="llvm", scope="package"
        )
        print(json.dumps(result, sort_keys=True))
    except (gates.GateError, OSError, subprocess.CalledProcessError) as error:
        print(f"Coverage gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
