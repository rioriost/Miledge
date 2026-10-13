"""Validate, test, and upload tagged App Store builds using Apple's tools."""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Iterator

import gates


ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("ios", "macos")
DEPLOYMENT_TARGET = "27.0"
LAUNCH_LOCALIZATIONS = (
    "en", "ja", "zh-Hans", "zh-Hant", "ko", "fr",
    "de", "es", "pt-BR", "it", "ar", "hi",
)
MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
CONFIG_KEYS = (
    "RELEASE_VERSION",
    "RELEASE_BUILD_NUMBER",
    "RELEASE_RUNNER",
    "XCODE_DEVELOPER_DIR",
    "XCODE_VERSION",
    "XCODE_BUILD_VERSION",
    "XCODE_PROJECT",
    "APPLE_TEAM_ID",
    "KEYCHAIN_ACCESS_GROUP",
    "ICLOUD_CONTAINER_ID",
    "IOS_SCHEME",
    "MACOS_SCHEME",
    "IOS_BUNDLE_ID",
    "MACOS_BUNDLE_ID",
    "IOS_TEST_DESTINATION",
    "IPAD_TEST_DESTINATION",
)


class ReleaseError(Exception):
    pass


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip() or "\n" in value or "\r" in value:
        raise ReleaseError(f"Set a nonempty, single-line {name}. See docs/release.en.md.")
    return value


def validate_config() -> dict[str, str]:
    config = {name: required(name) for name in CONFIG_KEYS}
    version = config["RELEASE_VERSION"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ReleaseError("RELEASE_VERSION must be X.Y.Z without a prerelease suffix.")
    if not re.fullmatch(r"[1-9][0-9]{0,8}", config["RELEASE_BUILD_NUMBER"]):
        raise ReleaseError("RELEASE_BUILD_NUMBER must be a positive integer of up to 9 digits.")
    if os.environ.get("GITHUB_REF") != f"refs/tags/v{version}":
        raise ReleaseError("Dispatch the workflow at the matching vX.Y.Z tag, not a branch.")
    if not re.fullmatch(r"macos-[0-9]+(?:-(?:large|xlarge))?", config["RELEASE_RUNNER"]):
        raise ReleaseError("RELEASE_RUNNER must name a pinned GitHub-hosted macOS runner.")
    if not re.fullmatch(r"[A-Z0-9]{10}", config["APPLE_TEAM_ID"]):
        raise ReleaseError("APPLE_TEAM_ID must be a 10-character team identifier.")
    if not config["KEYCHAIN_ACCESS_GROUP"].startswith(config["APPLE_TEAM_ID"] + "."):
        raise ReleaseError("KEYCHAIN_ACCESS_GROUP must include the official team prefix.")
    if not config["ICLOUD_CONTAINER_ID"].startswith("iCloud."):
        raise ReleaseError("ICLOUD_CONTAINER_ID must start with iCloud.")
    if not config["XCODE_DEVELOPER_DIR"].startswith("/") or not config[
        "XCODE_DEVELOPER_DIR"
    ].endswith("/Contents/Developer"):
        raise ReleaseError("XCODE_DEVELOPER_DIR must be an absolute Xcode developer path.")
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", config["XCODE_VERSION"]):
        raise ReleaseError("XCODE_VERSION must be an exact numeric Xcode version.")
    if not re.fullmatch(r"[A-Za-z0-9]+", config["XCODE_BUILD_VERSION"]):
        raise ReleaseError("XCODE_BUILD_VERSION must be the exact verified Xcode build identifier.")
    for name, family in (("IOS_TEST_DESTINATION", "iPhone"), ("IPAD_TEST_DESTINATION", "iPad")):
        match = re.fullmatch(
            rf"platform=iOS Simulator,name={family}[^,]+,OS=([0-9]+\.[0-9]+(?:\.[0-9]+)?)",
            config[name],
        )
        if not match:
            raise ReleaseError(
                f"{name} must select an installed {family} simulator by name and exact OS."
            )
        if int(match.group(1).split(".")[0]) < int(DEPLOYMENT_TARGET.split(".")[0]):
            raise ReleaseError(f"{name} must support the {DEPLOYMENT_TARGET} deployment minimum.")
    for platform in PLATFORMS:
        bundle_id = config[f"{platform.upper()}_BUNDLE_ID"]
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
            raise ReleaseError(f"Invalid {platform.upper()}_BUNDLE_ID.")

    project = (ROOT / config["XCODE_PROJECT"]).resolve()
    if not project.is_relative_to(ROOT) or project.suffix not in (".xcodeproj", ".xcworkspace"):
        raise ReleaseError("XCODE_PROJECT must be an in-repository .xcodeproj or .xcworkspace.")
    if not project.is_dir():
        raise ReleaseError(
            "The Xcode project is missing. Implement the app and shared test schemes before release."
        )
    return config


def run(arguments: list[str], *, capture: bool = False) -> bytes:
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = required("XCODE_DEVELOPER_DIR")
    try:
        result = subprocess.run(
            arguments,
            check=True,
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except subprocess.CalledProcessError as error:
        # Do not echo command arguments: signing commands include credentials.
        raise ReleaseError(
            f"{Path(arguments[0]).name} failed with exit status {error.returncode}."
        ) from None
    return result.stdout if capture else b""


def check_xcode(config: dict[str, str]) -> None:
    if sys.platform != "darwin":
        raise ReleaseError("Platform tests and uploads require macOS with Xcode.")
    output = run(["xcodebuild", "-version"], capture=True).decode()
    expected = [
        f"Xcode {config['XCODE_VERSION']}",
        f"Build version {config['XCODE_BUILD_VERSION']}",
    ]
    if output.splitlines() != expected:
        raise ReleaseError("Installed Xcode does not match the pinned version and build.")


def project_arguments(config: dict[str, str], platform: str) -> list[str]:
    project = config["XCODE_PROJECT"]
    kind = "-workspace" if project.endswith(".xcworkspace") else "-project"
    return [kind, project, "-scheme", config[f"{platform.upper()}_SCHEME"]]


def platform_build_settings(platform: str) -> list[str]:
    if platform == "ios":
        return [
            "TARGETED_DEVICE_FAMILY=1,2",
            f"IPHONEOS_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
        ]
    return [
        "ARCHS=arm64",
        "ONLY_ACTIVE_ARCH=NO",
        f"MACOSX_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
    ]


def test_platform(config: dict[str, str], platform: str) -> None:
    destinations = (
        [config["IOS_TEST_DESTINATION"], config["IPAD_TEST_DESTINATION"]]
        if platform == "ios" else ["platform=macOS,arch=arm64"]
    )
    directory = ROOT / ".build/gates"
    directory.mkdir(parents=True, exist_ok=True)
    keys = ("ios-iphone", "ios-ipad") if platform == "ios" else ("macos",)
    # Invalidate all platform attestations before any run; a later iPad UI
    # failure must never leave an earlier iPhone coverage attestation reusable.
    for key in keys:
        (directory / f"coverage-{key}.json").unlink(missing_ok=True)
        (directory / f"interaction-{key}.json").unlink(missing_ok=True)
    for key, destination in zip(keys, destinations):
        test_interaction(config, platform, key, destination, directory)
    for key, destination in zip(keys, destinations):
        bundle = directory / f"{key}.xcresult"
        report_path = directory / f"xccov-{key}.json"
        evidence_path = directory / f"coverage-{key}.json"
        evidence_path.unlink(missing_ok=True)
        report_path.unlink(missing_ok=True)
        if bundle.exists():
            shutil.rmtree(bundle)
        run(
            [
                "xcodebuild",
                "test",
                *project_arguments(config, platform),
                "-configuration",
                "Release",
                "-destination",
                destination,
                "-derivedDataPath",
                str(directory / f"DerivedData-{platform}"),
                "-enableCodeCoverage",
                "YES",
                "-resultBundlePath",
                str(bundle),
                "-disableAutomaticPackageResolution",
                *platform_build_settings(platform),
                "ENABLE_TESTABILITY=YES",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
            ]
        )
        report_path.write_bytes(run(
            ["xcrun", "xccov", "view", "--report", "--json", str(bundle)], capture=True
        ))
        scheme = config[f"{platform.upper()}_SCHEME"]
        result = gates.check_coverage(
            gates.load_json(report_path), ROOT, format="xccov", scope="app",
            expected_targets=(gates.APP_PRODUCT_NAME,),
        )
        print(f"{key} executable-line coverage: {result['coveredLines']}/{result['executableLines']}.")
        if os.environ.get("GITHUB_ACTIONS") == "true":
            evidence_path.write_text(json.dumps({
                "provenance": gates.provenance(ROOT), "scheme": scheme,
                "sources": gates.source_inventory(ROOT, "app"),
                "reportSHA256": gates.hashlib.sha256(report_path.read_bytes()).hexdigest(),
                "coverage": result,
            }, sort_keys=True) + "\n")


def test_interaction(
    config: dict[str, str], platform: str, key: str, destination: str, directory: Path,
) -> None:
    gates.interaction_sources(ROOT)
    scheme = gates.INTERACTION_SCHEMES[platform]
    project = config["XCODE_PROJECT"]
    kind = "-workspace" if project.endswith(".xcworkspace") else "-project"
    bundle = directory / f"interaction-{key}.xcresult"
    evidence_path = directory / f"interaction-{key}.json"
    evidence_path.unlink(missing_ok=True)
    reports = {
        name: directory / f"interaction-{name}-{key}.json"
        for name in ("summary", "tests", "availability")
    }
    for path in reports.values():
        path.unlink(missing_ok=True)
    if bundle.exists():
        shutil.rmtree(bundle)
    signing = (
        [
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Manual",
        ]
        if platform == "macos"
        else ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    )
    run([
        "xcodebuild", "test", kind, project, "-scheme", scheme,
        "-configuration", "Release", "-destination", destination,
        "-derivedDataPath", str(directory / f"DerivedData-interaction-{platform}"),
        "-enableCodeCoverage", "NO", "-resultBundlePath", str(bundle),
        "-disableAutomaticPackageResolution", "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "90",
        *platform_build_settings(platform),
        "CLANG_ENABLE_CODE_COVERAGE=NO", *signing,
    ])
    for name, path in reports.items():
        subcommand = (
            ["get", "content-availability"] if name == "availability"
            else ["get", "test-results", name]
        )
        path.write_bytes(run([
            "xcrun", "xcresulttool", *subcommand, "--schema-version", gates.XCRESULT_SCHEMA,
            "--path", str(bundle), "--compact",
        ], capture=True))
    result = gates.check_interactions(
        gates.load_json(reports["summary"]), gates.load_json(reports["tests"]),
        gates.load_json(reports["availability"]), scheme,
    )
    print(f"{key} interaction tests: {result['executedTests']} passed; no skips or runtime warnings.")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        evidence_path.write_text(json.dumps({
            "provenance": gates.provenance(ROOT), "sources": gates.interaction_sources(ROOT),
            "scheme": scheme, "destination": destination, "results": result,
            **{
                f"{name}SHA256": gates.hashlib.sha256(path.read_bytes()).hexdigest()
                for name, path in reports.items()
            },
        }, sort_keys=True) + "\n")


@contextmanager
def signing_keychain(directory: Path, certificate: Path) -> Iterator[Path]:
    keychain = directory / "signing.keychain-db"
    password = secrets.token_urlsafe(32)
    original = shlex.split(run(["security", "list-keychains", "-d", "user"], capture=True).decode())
    run(["security", "create-keychain", "-p", password, str(keychain)], capture=True)
    try:
        run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], capture=True)
        run(["security", "unlock-keychain", "-p", password, str(keychain)], capture=True)
        run(
            [
                "security", "import", str(certificate),
                "-k", str(keychain),
                "-P", required("SIGNING_CERTIFICATES_PASSWORD"),
                "-T", "/usr/bin/codesign",
                "-T", "/usr/bin/productbuild",
            ],
            capture=True,
        )
        run(
            [
                "security", "set-key-partition-list",
                "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, str(keychain),
            ],
            capture=True,
        )
        run(
            ["security", "list-keychains", "-d", "user", "-s", str(keychain), *original],
            capture=True,
        )
        yield keychain
    finally:
        try:
            run(["security", "list-keychains", "-d", "user", "-s", *original], capture=True)
        finally:
            run(["security", "delete-keychain", str(keychain)], capture=True)


def verify_bundle(
    info: dict, entitlements: dict, config: dict[str, str], platform: str
) -> None:
    expected = {
        "CFBundleIdentifier": config[f"{platform.upper()}_BUNDLE_ID"],
        "CFBundleShortVersionString": config["RELEASE_VERSION"],
        "CFBundleVersion": config["RELEASE_BUILD_NUMBER"],
        "CFBundleDevelopmentRegion": "en",
    }
    for name, value in expected.items():
        if info.get(name) != value:
            raise ReleaseError(f"Archived {name} does not match release configuration.")
    minimum_key = "MinimumOSVersion" if platform == "ios" else "LSMinimumSystemVersion"
    if info.get(minimum_key) != DEPLOYMENT_TARGET:
        raise ReleaseError(f"Archived {minimum_key} must be {DEPLOYMENT_TARGET}.")
    if platform == "ios":
        families = info.get("UIDeviceFamily")
        if (
            not isinstance(families, list)
            or any(type(family) is not int for family in families)
            or sorted(families) != [1, 2]
        ):
            raise ReleaseError("iOS archive must support both iPhone and iPad (UIDeviceFamily 1,2).")
    groups = entitlements.get(
        "keychain-access-groups", entitlements.get("com.apple.security.keychain-access-groups", [])
    )
    if config["KEYCHAIN_ACCESS_GROUP"] not in groups:
        raise ReleaseError("Archive is missing the shared Keychain Access Group.")
    containers = entitlements.get("com.apple.developer.ubiquity-container-identifiers", [])
    if config["ICLOUD_CONTAINER_ID"] not in containers:
        raise ReleaseError("Archive is missing the shared iCloud Drive container.")
    if "CloudDocuments" not in entitlements.get("com.apple.developer.icloud-services", []):
        raise ReleaseError("Archive is missing the iCloud Documents capability.")
    if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
        raise ReleaseError("Archive must not permit debugger attachment.")
    if platform == "macos" and entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ReleaseError("Mac App Store archive must enable App Sandbox.")
    if platform == "macos" and entitlements.get("com.apple.security.files.user-selected.read-write") is not True:
        raise ReleaseError("Mac archive must allow user-selected read-write access for encrypted backups.")
    declarations = info.get("UTExportedTypeDeclarations", [])
    if not isinstance(declarations, list):
        raise ReleaseError("Archive must declare the Miledge encrypted backup file type.")
    backup_types = [
        declaration for declaration in declarations
        if isinstance(declaration, dict)
        and declaration.get("UTTypeIdentifier") == "com.miledge.encrypted-backup"
    ]
    if len(backup_types) != 1:
        raise ReleaseError("Archive must declare exactly one Miledge encrypted backup file type.")
    declaration = backup_types[0]
    tags = declaration.get("UTTypeTagSpecification")
    conforms = declaration.get("UTTypeConformsTo")
    extensions = tags.get("public.filename-extension") if isinstance(tags, dict) else None
    if (
        not isinstance(conforms, list) or "public.data" not in conforms
        or not isinstance(extensions, list) or "miledge-backup" not in extensions
    ):
        raise ReleaseError("Encrypted backup type must conform to public.data and declare its extension.")


def verify_localizations(application: Path, platform: str) -> None:
    resources = application / "Contents/Resources" if platform == "macos" else application
    missing = []
    for localization in LAUNCH_LOCALIZATIONS:
        directory = resources / f"{localization}.lproj"
        tables = [directory / "Localizable.strings", directory / "Localizable.stringsdict"]
        if not any(table.is_file() and table.stat().st_size > 0 for table in tables):
            missing.append(localization)
    if missing:
        raise ReleaseError("Archive is missing Localizable translation resources: " + ", ".join(missing))


def verify_macos_architectures(application: Path, info: dict) -> None:
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ReleaseError("Mac archive must name its executable in CFBundleExecutable.")
    root = application.resolve()
    executable = (root / "Contents/MacOS" / name).resolve()
    if not executable.is_relative_to(root) or not executable.is_file():
        raise ReleaseError("Mac executable must be a file inside the application.")
    binaries = set()
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if not resolved.is_relative_to(root):
            raise ReleaseError("Mac application files must remain inside the application.")
        with resolved.open("rb") as stream:
            if stream.read(4) in MACH_O_MAGICS:
                binaries.add(resolved)
    if executable not in binaries:
        raise ReleaseError("Mac executable is not a Mach-O binary.")
    for binary in sorted(binaries):
        architectures = run(["lipo", "-archs", str(binary)], capture=True).decode().split()
        if architectures != ["arm64"]:
            raise ReleaseError(
                f"Mac code must be arm64-only: {binary.relative_to(root)}."
            )


def verify_archive(archive: Path, config: dict[str, str], platform: str) -> None:
    with (archive / "Info.plist").open("rb") as stream:
        archive_info = plistlib.load(stream)
    relative = archive_info.get("ApplicationProperties", {}).get("ApplicationPath")
    if not isinstance(relative, str):
        raise ReleaseError("Archive has no application; check the shared scheme and SKIP_INSTALL.")
    products = (archive / "Products").resolve()
    application = (products / relative).resolve()
    if not application.is_relative_to(products) or application.suffix != ".app":
        raise ReleaseError("Archive application path must remain inside its Products directory.")
    product = f"{gates.APP_PRODUCT_NAME}.app"
    if Path(relative).name != product or application.name != product:
        raise ReleaseError(f"Archive application must be named {product} on both platforms.")
    info_path = application / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    run(["codesign", "--verify", "--deep", "--strict", str(application)])
    entitlements = plistlib.loads(
        run(["codesign", "-d", "--entitlements", ":-", str(application)], capture=True)
    )
    verify_bundle(info, entitlements, config, platform)
    verify_localizations(application, platform)
    if platform == "macos":
        verify_macos_architectures(application, info)


def export_options(config: dict[str, str]) -> dict:
    return {
        "method": "app-store-connect",
        "destination": "upload",
        "teamID": config["APPLE_TEAM_ID"],
        "signingStyle": "automatic",
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
    }


def upload(config: dict[str, str], platform: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ReleaseError("Uploads are allowed only through the approved GitHub release workflow.")
    gates.verify_upload_evidence(ROOT, ROOT / ".build/gates", config)
    key_id = required("ASC_KEY_ID")
    issuer = required("ASC_ISSUER_ID")
    private_key = os.environ.get("ASC_PRIVATE_KEY", "")
    if "-----BEGIN PRIVATE KEY-----" not in private_key:
        raise ReleaseError("Configure ASC_PRIVATE_KEY with the App Store Connect .p8 contents.")
    try:
        certificates = base64.b64decode(required("SIGNING_CERTIFICATES_P12"), validate=True)
    except binascii.Error:
        raise ReleaseError("SIGNING_CERTIFICATES_P12 must be single-line base64.") from None
    if not certificates:
        raise ReleaseError("SIGNING_CERTIFICATES_P12 contains no signing material.")
    required("SIGNING_CERTIFICATES_PASSWORD")

    working_parent = ROOT / ".build/release"
    working_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="miledge-release-", dir=working_parent) as directory:
        working = Path(directory)
        key = working / "AuthKey.p8"
        key.write_text(private_key)
        key.chmod(0o600)
        certificate = working / "signing.p12"
        certificate.write_bytes(certificates)
        certificate.chmod(0o600)
        authentication = [
            "-allowProvisioningUpdates",
            "-authenticationKeyPath", str(key),
            "-authenticationKeyID", key_id,
            "-authenticationKeyIssuerID", issuer,
        ]
        archive = working / "Miledge.xcarchive"
        with signing_keychain(working, certificate) as keychain:
            print(f"Archiving {platform} {config['RELEASE_VERSION']} ({config['RELEASE_BUILD_NUMBER']}).")
            run(
                [
                    "xcodebuild", "archive",
                    *project_arguments(config, platform),
                    "-configuration", "Release",
                    "-destination", "generic/platform=iOS" if platform == "ios" else "generic/platform=macOS",
                    "-archivePath", str(archive),
                    "-derivedDataPath", str(working / "DerivedData"),
                    "-disableAutomaticPackageResolution",
                    *platform_build_settings(platform),
                    *authentication,
                    f"MARKETING_VERSION={config['RELEASE_VERSION']}",
                    f"CURRENT_PROJECT_VERSION={config['RELEASE_BUILD_NUMBER']}",
                    f"DEVELOPMENT_TEAM={config['APPLE_TEAM_ID']}",
                    "CODE_SIGN_STYLE=Automatic",
                    f"OTHER_CODE_SIGN_FLAGS=--keychain {shlex.quote(str(keychain))}",
                ]
            )
            verify_archive(archive, config, platform)
            symbols = archive / "dSYMs"
            if not symbols.is_dir() or not any(symbols.iterdir()):
                raise ReleaseError("Archive has no dSYMs; enable release debug symbol generation.")
            shutil.copytree(symbols, ROOT / ".build" / "release" / platform / "dSYMs")
            options = working / "ExportOptions.plist"
            with options.open("wb") as stream:
                plistlib.dump(export_options(config), stream)
            run(
                [
                    "xcodebuild", "-exportArchive",
                    "-archivePath", str(archive),
                    "-exportOptionsPlist", str(options),
                    "-exportPath", str(working / "export"),
                    *authentication,
                ]
            )
    print("Upload command completed. Confirm processing in App Store Connect; nothing was published.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "test", "upload"))
    parser.add_argument("--platform", choices=(*PLATFORMS, "all"), default="all")
    arguments = parser.parse_args()
    try:
        config = validate_config()
        if arguments.command == "preflight":
            platforms = list(PLATFORMS) if arguments.platform == "all" else [arguments.platform]
            output = os.environ.get("GITHUB_OUTPUT")
            if output:
                with Path(output).open("a") as stream:
                    stream.write(f"runner={config['RELEASE_RUNNER']}\n")
                    stream.write(f"platforms={json.dumps(platforms)}\n")
            print("Release prerequisites configured. Platform tests and approval are still required.")
        else:
            if arguments.platform == "all":
                raise ReleaseError("Choose one platform for each test or upload job.")
            check_xcode(config)
            if arguments.command == "test":
                test_platform(config, arguments.platform)
            else:
                upload(config, arguments.platform)
    except (ReleaseError, gates.GateError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
