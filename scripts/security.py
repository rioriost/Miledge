"""Gate Python CodeQL evidence; retain Swift tracing as an optional comparator.

The active Swift release gate is swift_security.py, not build-swift or the
legacy Swift CodeQL evidence format. Only re-evaluate that comparator on a
genuinely compatible toolchain/platform; never widen its compatibility guard.

The workflow uses CodeQL Action v4.38.3 / CLI 2.27.2 and security-extended.
Public GitHub repositories can use code scanning without GHAS. Private/internal
repositories require eligible GitHub Code Security licensing; local CLI use is
subject to CodeQL terms (not an unconditional free proprietary-code license).
See https://docs.github.com/en/code-security/concepts/code-scanning/code-scanning
and https://github.com/github/codeql-cli-binaries/blob/main/LICENSE.md.
Automated OSS database generation under the public terms requires the open
source codebase to be hosted and maintained on GitHub.com. Optional Swift
comparison on Apple Silicon also needs Xcode tools and Rosetta 2 for this bundle.
No external secret service, database upload, or SARIF upload is required here.
Adding this framework is not evidence that a security audit has run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import gates
import release


ROOT = Path(__file__).resolve().parents[1]


def build_swift() -> None:
    config = {
        key: release.required(key) for key in (
            "XCODE_VERSION", "XCODE_BUILD_VERSION", "XCODE_PROJECT", "IOS_SCHEME", "MACOS_SCHEME",
        )
    }
    release.check_xcode(config)
    compiler = release.run(["xcrun", "swift", "--version"], capture=True).decode()
    gates.check_swift_version(compiler)
    gates.source_inventory(ROOT, "app")
    project = (ROOT / config["XCODE_PROJECT"]).resolve()
    if not project.is_relative_to(ROOT) or not project.is_dir():
        raise gates.GateError("Missing/ineligible first-party Xcode project.")
    scratch = ROOT / ".build/codeql-package"
    release.run(["swift", "package", "clean", "--scratch-path", str(scratch)])
    release.run(["swift", "build", "--arch", "arm64", "--scratch-path", str(scratch)])
    for platform in release.PLATFORMS:
        release.run([
            "xcodebuild", "clean", "build", *release.project_arguments(config, platform),
            "-configuration", "Release", "-destination",
            "generic/platform=iOS Simulator" if platform == "ios" else "platform=macOS,arch=arm64",
            "-derivedDataPath", str(ROOT / f".build/codeql-{platform}"),
            "-disableAutomaticPackageResolution", *release.platform_build_settings(platform),
            "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        ])


def verify(language: str, codeql: Path, database: Path, sarif: Path, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    evidence_path = directory / f"security-{language}.json"
    evidence_path.unlink(missing_ok=True)
    version = json.loads(subprocess.check_output([str(codeql), "version", "--format=json"], cwd=ROOT))
    if not isinstance(version, dict) or version.get("version") != gates.CODEQL_VERSION:
        raise gates.GateError("CodeQL CLI does not match the pinned version.")
    pack = ROOT / "scripts/codeql" / language
    subprocess.run([str(codeql), "pack", "install", str(pack)], cwd=ROOT, check=True)
    bqrs = directory / f"inventory-{language}.bqrs"
    bqrs.unlink(missing_ok=True)
    subprocess.run([
        str(codeql), "query", "run", str(pack / "inventory.ql"),
        f"--database={database}", f"--output={bqrs}",
    ], cwd=ROOT, check=True)
    decoded = json.loads(subprocess.check_output([
        str(codeql), "bqrs", "decode", str(bqrs), "--format=json",
    ], cwd=ROOT))
    if not isinstance(decoded, dict) or not isinstance(decoded.get("#select"), dict):
        raise gates.GateError("CodeQL returned no source inventory result set.")
    selected = decoded["#select"]
    rows = selected.get("tuples")
    extraction = gates.check_extraction(rows, ROOT, language)
    extracted_path = directory / f"extracted-{language}.json"
    extracted_path.write_text(json.dumps(rows, sort_keys=True) + "\n")
    result = gates.check_sarif(gates.load_json(sarif), language)
    evidence = {
        "provenance": gates.provenance(ROOT),
        "codeqlAction": gates.CODEQL_ACTION, "codeqlVersion": gates.CODEQL_VERSION,
        "sources": gates.source_inventory(ROOT, "app"),
        "reportSHA256": hashlib.sha256(sarif.read_bytes()).hexdigest(),
        "extractionSHA256": hashlib.sha256(extracted_path.read_bytes()).hexdigest(),
        "analysis": result, "extraction": extraction,
    }
    if language == "swift":
        output = release.run(["xcrun", "swift", "--version"], capture=True).decode()
        evidence["swiftVersion"] = gates.check_swift_version(output)
    evidence_path.write_text(json.dumps(evidence, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build-swift")
    audit = commands.add_parser("verify")
    audit.add_argument("--language", choices=("swift", "python"), required=True)
    audit.add_argument("--codeql", type=Path, required=True)
    audit.add_argument("--database", type=Path, required=True)
    audit.add_argument("--sarif", type=Path, required=True)
    audit.add_argument("--output", type=Path, default=ROOT / ".build/gates")
    args = parser.parse_args()
    try:
        if args.command == "build-swift":
            build_swift()
        else:
            verify(args.language, args.codeql, args.database, args.sarif, args.output)
    except (gates.GateError, release.ReleaseError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Security gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
