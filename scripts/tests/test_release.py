import base64
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
import interaction_fixtures


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="miledge-release-test-", dir=Path.cwd())
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "Miledge.xcodeproj").mkdir()
        for directory in ("App", *(f"Sources/{name}" for name in release.gates.LIBRARIES)):
            source = self.root / directory / "Fixture.swift"
            source.parent.mkdir(parents=True)
            source.write_text("func fixture() -> Int { 1 }\n")
        interaction_fixtures.source_files(self.root)
        self.config = {
            "RELEASE_VERSION": "1.2.3",
            "RELEASE_BUILD_NUMBER": "42",
            "RELEASE_RUNNER": "macos-26",
            "XCODE_DEVELOPER_DIR": "/Applications/Xcode_27.app/Contents/Developer",
            "XCODE_VERSION": "27.0",
            "XCODE_BUILD_VERSION": "27A266a",
            "XCODE_PROJECT": "Miledge.xcodeproj",
            "APPLE_TEAM_ID": "TESTTEAM01",
            "KEYCHAIN_ACCESS_GROUP": "TESTTEAM01.com.example.miledge.shared",
            "ICLOUD_CONTAINER_ID": "iCloud.com.example.miledge",
            "IOS_SCHEME": "Miledge-iOS",
            "MACOS_SCHEME": "Miledge-macOS",
            "IOS_BUNDLE_ID": "com.example.miledge",
            "MACOS_BUNDLE_ID": "com.example.miledge.mac",
            "IOS_TEST_DESTINATION": "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "IPAD_TEST_DESTINATION": "platform=iOS Simulator,name=iPad mini (6th generation),OS=27.0",
        }
        environment = {**self.config, "GITHUB_REF": "refs/tags/v1.2.3"}
        self.addCleanup(patch.stopall)
        patch.object(release, "ROOT", self.root).start()
        patch.dict(os.environ, environment, clear=True).start()

    def info(self, platform="ios"):
        info = {
            "CFBundleIdentifier": self.config[f"{platform.upper()}_BUNDLE_ID"],
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleDevelopmentRegion": "en",
            "UTExportedTypeDeclarations": [{
                "UTTypeIdentifier": "com.miledge.encrypted-backup",
                "UTTypeConformsTo": ["public.data"],
                "UTTypeTagSpecification": {"public.filename-extension": ["miledge-backup"]},
            }],
        }
        if platform == "ios":
            info.update({"MinimumOSVersion": "27.0", "UIDeviceFamily": [1, 2]})
        else:
            info.update({"LSMinimumSystemVersion": "27.0", "CFBundleExecutable": "Miledge"})
        return info

    def application(self, platform):
        app = self.root / f"{platform}.xcarchive/Products/Applications/Miledge.app"
        info = app / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps(self.info(platform)))
        resources = app / "Contents/Resources" if platform == "macos" else app
        for localization in release.LAUNCH_LOCALIZATIONS:
            directory = resources / f"{localization}.lproj"
            directory.mkdir(parents=True)
            (directory / "Localizable.strings").write_text('"synthetic" = "synthetic";')
        if platform == "macos":
            executable = app / "Contents/MacOS/Miledge"
            executable.parent.mkdir()
            executable.write_bytes(b"\xcf\xfa\xed\xfeSYNTHETIC-MACH-O")
        return app

    def entitlements(self):
        return {
            "keychain-access-groups": [self.config["KEYCHAIN_ACCESS_GROUP"]],
            "com.apple.developer.ubiquity-container-identifiers": [self.config["ICLOUD_CONTAINER_ID"]],
            "com.apple.developer.icloud-services": ["CloudDocuments"],
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
        }

    def test_valid_configuration(self):
        self.assertEqual(release.validate_config(), self.config)

    def test_missing_variables_fail(self):
        for name in release.CONFIG_KEYS:
            with self.subTest(name=name), patch.dict(os.environ, {name: ""}):
                with self.assertRaisesRegex(release.ReleaseError, name):
                    release.validate_config()

    def test_invalid_configuration_fails(self):
        cases = {
            "RELEASE_VERSION": ["1.2", "1.2.3-beta.1", "01.2.3", "1.2.３"],
            "RELEASE_BUILD_NUMBER": ["0", "-1", "1; echo unsafe", "00042", "1234567890"],
            "RELEASE_RUNNER": ["macos-latest", "self-hosted", "macos-26\nother"],
            "APPLE_TEAM_ID": ["wrong"],
            "KEYCHAIN_ACCESS_GROUP": ["OTHERTEAM1.com.example.shared"],
            "ICLOUD_CONTAINER_ID": ["com.example.miledge"],
            "XCODE_DEVELOPER_DIR": ["relative/Contents/Developer"],
            "XCODE_VERSION": ["27", "27.1 RC"],
            "XCODE_BUILD_VERSION": ["27A 266a"],
            "IOS_BUNDLE_ID": ["bad id"],
            "IOS_TEST_DESTINATION": [
                "platform=macOS",
                "platform=iOS Simulator,name=iPhone 17,OS=latest",
                "platform=iOS Simulator,name=iPhone 17",
                "platform=iOS Simulator,name=iPad mini (6th generation),OS=27.0",
                "platform=iOS Simulator,name=iPhone 17,OS=26.0",
                "platform=iOS Simulator,name=iPhone 17,OS=27.0,OS=latest",
            ],
            "IPAD_TEST_DESTINATION": [
                "platform=macOS",
                "platform=iOS Simulator,name=iPhone 17,OS=27.0",
                "platform=iOS Simulator,name=iPad Pro,OS=latest",
                "platform=iOS Simulator,name=iPad Pro",
                "platform=iOS Simulator,name=iPad Pro,OS=26.0",
            ],
        }
        for name, values in cases.items():
            for value in values:
                with self.subTest(name=name, value=value), patch.dict(os.environ, {name: value}):
                    with self.assertRaises(release.ReleaseError):
                        release.validate_config()

    def test_branch_or_wrong_tag_fails(self):
        for ref in ["refs/heads/main", "refs/tags/v2.0.0", ""]:
            with self.subTest(ref=ref), patch.dict(os.environ, {"GITHUB_REF": ref}):
                with self.assertRaisesRegex(release.ReleaseError, "matching"):
                    release.validate_config()

    def test_missing_project_fails(self):
        with patch.dict(os.environ, {"XCODE_PROJECT": "Missing.xcodeproj"}):
            with self.assertRaisesRegex(release.ReleaseError, "project is missing"):
                release.validate_config()

    def test_out_of_repository_project_fails(self):
        with patch.dict(os.environ, {"XCODE_PROJECT": "../Other.xcodeproj"}):
            with self.assertRaisesRegex(release.ReleaseError, "in-repository"):
                release.validate_config()

    def test_workspace_supported(self):
        (self.root / "Miledge.xcworkspace").mkdir()
        self.config["XCODE_PROJECT"] = "Miledge.xcworkspace"
        with patch.dict(os.environ, {"XCODE_PROJECT": "Miledge.xcworkspace"}):
            config = release.validate_config()
        self.assertEqual(
            release.project_arguments(config, "ios"),
            ["-workspace", "Miledge.xcworkspace", "-scheme", "Miledge-iOS"],
        )

    def test_preflight_outputs_matrix_without_credentials(self):
        output = self.root / "outputs"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
            with patch.object(sys, "argv", ["release.py", "preflight", "--platform", "macos"]):
                self.assertEqual(release.main(), 0)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs["runner"], "macos-26")
        self.assertEqual(json.loads(outputs["platforms"]), ["macos"])

    def test_test_and_upload_need_one_platform(self):
        with patch.object(sys, "argv", ["release.py", "test"]), redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(), 1)

    def test_xcode_version_and_build_are_pinned(self):
        with patch.object(sys, "platform", "darwin"), patch.object(release, "run") as run:
            run.return_value = b"Xcode 27.0\nBuild version 27A266a\n"
            release.check_xcode(self.config)
            run.return_value = b"Xcode 27.0\nBuild version 27A0000\n"
            with self.assertRaisesRegex(release.ReleaseError, "version and build"):
                release.check_xcode(self.config)

    def test_non_mac_tests_fail(self):
        with patch.object(sys, "platform", "linux"):
            with self.assertRaisesRegex(release.ReleaseError, "macOS"):
                release.check_xcode(self.config)

    def test_build_settings_enforce_device_and_deployment_policy(self):
        self.assertEqual(
            release.platform_build_settings("ios"),
            ["TARGETED_DEVICE_FAMILY=1,2", "IPHONEOS_DEPLOYMENT_TARGET=27.0"],
        )
        self.assertEqual(
            release.platform_build_settings("macos"),
            ["ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "MACOSX_DEPLOYMENT_TARGET=27.0"],
        )

    def test_platform_tests_use_pinned_destinations_without_signing(self):
        def command(arguments, **kwargs):
            if arguments[:2] == ["xcrun", "xcresulttool"]:
                scheme = (
                    release.gates.INTERACTION_SCHEMES["macos"]
                    if "macos.xcresult" in arguments[arguments.index("--path") + 1]
                    else release.gates.INTERACTION_SCHEMES["ios"]
                )
                name = arguments[3] if arguments[3] == "content-availability" else arguments[4]
                name = "availability" if name == "content-availability" else name
                return json.dumps(interaction_fixtures.reports(scheme)[name]).encode()
            if arguments[:2] == ["xcrun", "xccov"]:
                files = [
                    {"path": str(self.root / path), "coveredLines": 1, "executableLines": 1}
                    for path in release.gates.source_inventory(self.root, "app")
                ]
                return json.dumps({"targets": [{
                    "name": "Miledge.app",
                    "coveredLines": len(files), "executableLines": len(files), "files": files,
                }]}).encode()
            return b""

        with patch.object(release, "run", side_effect=command) as run:
            for platform in release.PLATFORMS:
                run.reset_mock()
                release.test_platform(self.config, platform)
                destinations = (
                    [self.config["IOS_TEST_DESTINATION"], self.config["IPAD_TEST_DESTINATION"]]
                    if platform == "ios" else ["platform=macOS,arch=arm64"]
                )
                self.assertEqual(run.call_count, len(destinations) * 6)
                interaction_calls = run.call_args_list[:len(destinations) * 4:4]
                for call, destination in zip(interaction_calls, destinations):
                    arguments = call.args[0]
                    self.assertIn(release.gates.INTERACTION_SCHEMES[platform], arguments)
                    self.assertIn(destination, arguments)
                    self.assertIn("Release", arguments)
                    if platform == "macos":
                        for setting in (
                            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
                            "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Manual",
                        ):
                            self.assertIn(setting, arguments)
                        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", arguments)
                    else:
                        self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
                        self.assertIn("CODE_SIGNING_REQUIRED=NO", arguments)
                        self.assertNotIn("CODE_SIGN_IDENTITY=-", arguments)
                    self.assertEqual(arguments[arguments.index("-enableCodeCoverage") + 1], "NO")
                    self.assertIn("CLANG_ENABLE_CODE_COVERAGE=NO", arguments)
                    self.assertIn("-resultBundlePath", arguments)
                    self.assertNotIn("ENABLE_TESTABILITY=YES", arguments)
                    self.assertEqual(arguments[arguments.index("-parallel-testing-enabled") + 1], "NO")
                    self.assertEqual(arguments[arguments.index("-test-timeouts-enabled") + 1], "YES")
                    self.assertEqual(
                        arguments[arguments.index("-maximum-test-execution-time-allowance") + 1], "90"
                    )
                    self.assertNotIn("-retry-tests-on-failure", arguments)
                    self.assertNotIn("-test-iterations", arguments)
                for call, destination in zip(run.call_args_list[len(destinations) * 4::2], destinations):
                    arguments = call.args[0]
                    self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
                    self.assertIn("-disableAutomaticPackageResolution", arguments)
                    self.assertIn(destination, arguments)
                    self.assertIn("-enableCodeCoverage", arguments)
                    self.assertEqual(arguments[arguments.index("-enableCodeCoverage") + 1], "YES")
                    self.assertIn("-resultBundlePath", arguments)
                    self.assertIn("ENABLE_TESTABILITY=YES", arguments)
                    for setting in release.platform_build_settings(platform):
                        self.assertIn(setting, arguments)

    def test_ipad_test_failure_stops_the_job(self):
        with patch.object(
            release, "run", side_effect=[
                b"",
                *(json.dumps(report).encode() for report in interaction_fixtures.reports(
                    release.gates.INTERACTION_SCHEMES["ios"]
                ).values()),
                release.ReleaseError("synthetic iPad failure"),
            ]
        ) as run:
            with self.assertRaisesRegex(release.ReleaseError, "iPad failure"):
                release.test_platform(self.config, "ios")
            self.assertEqual(run.call_count, 5)

    def test_signed_bundle_requirements(self):
        for platform in release.PLATFORMS:
            with self.subTest(platform=platform):
                release.verify_bundle(self.info(platform), self.entitlements(), self.config, platform)

    def test_wrong_versions_or_identifier_fail(self):
        for field in (
            "CFBundleIdentifier", "CFBundleShortVersionString",
            "CFBundleVersion", "CFBundleDevelopmentRegion",
        ):
            info = {**self.info(), field: "wrong"}
            with self.subTest(field=field):
                with self.assertRaisesRegex(release.ReleaseError, field):
                    release.verify_bundle(info, self.entitlements(), self.config, "ios")

    def test_incorrect_deployment_minimum_fails(self):
        for platform, key in (("ios", "MinimumOSVersion"), ("macos", "LSMinimumSystemVersion")):
            for value in (None, "26.0", "28.0"):
                info = {**self.info(platform), key: value}
                with self.subTest(platform=platform, value=value):
                    with self.assertRaisesRegex(release.ReleaseError, key):
                        release.verify_bundle(info, self.entitlements(), self.config, platform)

    def test_both_mobile_device_families_are_required(self):
        for families in (None, [1], [2], [1, 2, 7], [1, 1, 2], ["1", "2"], [True, 2]):
            with self.subTest(families=families):
                with self.assertRaisesRegex(release.ReleaseError, "UIDeviceFamily"):
                    release.verify_bundle(
                        {**self.info(), "UIDeviceFamily": families},
                        self.entitlements(), self.config, "ios",
                    )
        release.verify_bundle(
            {**self.info(), "UIDeviceFamily": [2, 1]},
            self.entitlements(), self.config, "ios",
        )

    def test_missing_entitlements_fail(self):
        for name in self.entitlements():
            entitlements = self.entitlements()
            del entitlements[name]
            with self.subTest(name=name):
                with self.assertRaises(release.ReleaseError):
                    release.verify_bundle(self.info("macos"), entitlements, self.config, "macos")

    def test_debug_entitlements_fail(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            with self.subTest(key=key):
                with self.assertRaisesRegex(release.ReleaseError, "debugger"):
                    release.verify_bundle(
                        self.info(), {**self.entitlements(), key: True}, self.config, "ios"
                    )

    def test_mac_backup_export_requires_user_selected_read_write(self):
        for value in (None, False, "true", 1):
            with self.subTest(value=value):
                entitlements = {**self.entitlements(), "com.apple.security.files.user-selected.read-write": value}
                with self.assertRaisesRegex(release.ReleaseError, "read-write"):
                    release.verify_bundle(self.info("macos"), entitlements, self.config, "macos")
        entitlements = self.entitlements()
        del entitlements["com.apple.security.files.user-selected.read-write"]
        release.verify_bundle(self.info(), entitlements, self.config, "ios")

    def test_backup_type_metadata_is_required_and_checked_on_both_platforms(self):
        valid = self.info()["UTExportedTypeDeclarations"][0]
        invalid = [
            None, {}, [], [valid, valid], [{}],
            [{**valid, "UTTypeConformsTo": "public.data"}],
            [{**valid, "UTTypeConformsTo": ["public.text"]}],
            [{**valid, "UTTypeTagSpecification": []}],
            [{**valid, "UTTypeTagSpecification": {"public.filename-extension": "miledge-backup"}}],
            [{**valid, "UTTypeTagSpecification": {"public.filename-extension": ["txt"]}}],
        ]
        for platform in release.PLATFORMS:
            for declarations in invalid:
                with self.subTest(platform=platform, declarations=declarations):
                    with self.assertRaises(release.ReleaseError):
                        release.verify_bundle(
                            {**self.info(platform), "UTExportedTypeDeclarations": declarations},
                            self.entitlements(), self.config, platform,
                        )

    def test_archive_verifies_actual_application(self):
        for platform in release.PLATFORMS:
            archive = self.root / f"{platform}.xcarchive"
            app = self.application(platform)
            (archive / "Info.plist").write_bytes(
                plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "Applications/Miledge.app"}})
            )

            def command(arguments, **kwargs):
                return b"arm64\n" if arguments[0] == "lipo" else plistlib.dumps(self.entitlements())

            with patch.object(release, "run", side_effect=command) as run:
                release.verify_archive(archive, self.config, platform)
                self.assertIn(str(app), run.call_args_list[0].args[0])
                self.assertEqual(run.call_count, 3 if platform == "macos" else 2)

    def test_archive_rejects_platform_suffixed_application_names(self):
        for platform, name in (("ios", "Miledge-iOS.app"), ("macos", "Miledge-macOS.app")):
            archive = self.root / f"{platform}.xcarchive"
            app = self.application(platform)
            app.rename(app.with_name(name))
            (archive / "Info.plist").write_bytes(
                plistlib.dumps({"ApplicationProperties": {"ApplicationPath": f"Applications/{name}"}})
            )
            with self.subTest(platform=platform), patch.object(release, "run") as run:
                with self.assertRaisesRegex(release.ReleaseError, "named Miledge.app"):
                    release.verify_archive(archive, self.config, platform)
                run.assert_not_called()

    def test_localization_resources_are_required_on_both_platforms(self):
        for platform in release.PLATFORMS:
            app = self.application(platform)
            directory = app / ("Contents/Resources" if platform == "macos" else "")
            arabic = directory / "ar.lproj/Localizable.strings"
            arabic.write_bytes(b"")
            with self.subTest(platform=platform):
                with self.assertRaisesRegex(release.ReleaseError, "ar"):
                    release.verify_localizations(app, platform)
                arabic.unlink()
                with self.assertRaisesRegex(release.ReleaseError, "ar"):
                    release.verify_localizations(app, platform)
                arabic.with_suffix(".stringsdict").write_bytes(
                    plistlib.dumps({"synthetic": {"NSStringLocalizedFormatKey": "%#@count@"}})
                )
                release.verify_localizations(app, platform)

    def test_archive_rejects_missing_localization_before_upload(self):
        app = self.application("ios")
        archive = self.root / "ios.xcarchive"
        (app / "hi.lproj/Localizable.strings").unlink()
        (archive / "Info.plist").write_bytes(
            plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "Applications/Miledge.app"}})
        )
        with patch.object(release, "run", return_value=plistlib.dumps(self.entitlements())):
            with self.assertRaisesRegex(release.ReleaseError, "hi"):
                release.verify_archive(archive, self.config, "ios")

    def test_mac_requires_arm64_main_executable(self):
        app = self.application("macos")
        for architectures in (b"x86_64\n", b"x86_64 arm64\n", b"arm64e\n", b""):
            with self.subTest(architectures=architectures):
                with patch.object(release, "run", return_value=architectures):
                    with self.assertRaisesRegex(release.ReleaseError, "arm64-only"):
                        release.verify_macos_architectures(app, self.info("macos"))

    def test_mac_checks_embedded_code_not_just_the_main_executable(self):
        app = self.application("macos")
        library = app / "Contents/Frameworks/Synthetic.dylib"
        library.parent.mkdir()
        library.write_bytes(b"\xca\xfe\xba\xbeSYNTHETIC-FAT-MACH-O")

        def command(arguments, **kwargs):
            return b"x86_64 arm64\n" if arguments[-1] == str(library) else b"arm64\n"

        with patch.object(release, "run", side_effect=command):
            with self.assertRaisesRegex(release.ReleaseError, "Synthetic.dylib"):
                release.verify_macos_architectures(app, self.info("macos"))

    def test_mac_architecture_check_handles_internal_symlinks(self):
        app = self.application("macos")
        (app / "Contents/MacOS/Alias").symlink_to("Miledge")
        with patch.object(release, "run", return_value=b"arm64\n") as run:
            release.verify_macos_architectures(app, self.info("macos"))
            self.assertEqual(run.call_count, 1)

    def test_mac_executable_must_be_an_in_bundle_mach_o_file(self):
        app = self.application("macos")
        for name in (None, "", "../Other", "Missing"):
            with self.subTest(name=name):
                with self.assertRaises(release.ReleaseError):
                    release.verify_macos_architectures(
                        app, {**self.info("macos"), "CFBundleExecutable": name}
                    )
        executable = app / "Contents/MacOS/Miledge"
        executable.write_text("not an executable")
        with self.assertRaisesRegex(release.ReleaseError, "Mach-O"):
            release.verify_macos_architectures(app, self.info("macos"))
        executable.unlink()
        outside = self.root / "Outside"
        outside.write_bytes(b"\xcf\xfa\xed\xfeSYNTHETIC")
        executable.symlink_to(outside)
        with self.assertRaisesRegex(release.ReleaseError, "inside"):
            release.verify_macos_architectures(app, self.info("macos"))

    def test_archive_paths_cannot_escape(self):
        archive = self.root / "Escape.xcarchive"
        archive.mkdir()
        (archive / "Info.plist").write_bytes(
            plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "../../Outside.app"}})
        )
        with self.assertRaisesRegex(release.ReleaseError, "inside"):
            release.verify_archive(archive, self.config, "ios")

    def test_export_upload_preserves_build_number(self):
        options = release.export_options(self.config)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "upload")
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)
        self.assertNotIn("password", options)

    def test_upload_is_not_a_local_command(self):
        with self.assertRaisesRegex(release.ReleaseError, "approved GitHub"):
            release.upload(self.config, "ios")

    def test_failed_commands_do_not_echo_credentials(self):
        arguments = ["security", "import", "-P", "synthetic-password"]
        with patch.object(
            subprocess, "run", side_effect=subprocess.CalledProcessError(3, arguments)
        ):
            with self.assertRaises(release.ReleaseError) as caught:
                release.run(arguments, capture=True)
        self.assertNotIn("synthetic-password", str(caught.exception))
        self.assertIn("exit status 3", str(caught.exception))

    def test_signing_keychain_restores_original_list_on_failure(self):
        def command(arguments, **kwargs):
            if arguments == ["security", "list-keychains", "-d", "user"]:
                return b'"/Users/runner/Library/Keychains/login.keychain-db"\n'
            return b""

        with patch.dict(os.environ, {"SIGNING_CERTIFICATES_PASSWORD": "synthetic-password"}):
            with patch.object(release, "run", side_effect=command) as run:
                with self.assertRaisesRegex(release.ReleaseError, "synthetic build failure"):
                    with release.signing_keychain(self.root, self.root / "signing.p12"):
                        raise release.ReleaseError("synthetic build failure")
        calls = [call.args[0] for call in run.call_args_list]
        self.assertEqual(
            calls[-2],
            ["security", "list-keychains", "-d", "user", "-s",
             "/Users/runner/Library/Keychains/login.keychain-db"],
        )
        self.assertEqual(calls[-1][:2], ["security", "delete-keychain"])

    def test_upload_flow_and_temporary_secret_cleanup(self):
        environment = {
            "GITHUB_ACTIONS": "true",
            "ASC_KEY_ID": "SYNTHETIC1",
            "ASC_ISSUER_ID": "synthetic-issuer",
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nSYNTHETIC\n-----END PRIVATE KEY-----",
            "SIGNING_CERTIFICATES_P12": base64.b64encode(b"synthetic certificates").decode(),
            "SIGNING_CERTIFICATES_PASSWORD": "synthetic-password",
        }
        paths = []

        def command(arguments, **kwargs):
            if arguments[:2] == ["xcodebuild", "archive"]:
                self.assertNotIn("-enableCodeCoverage", arguments)
                self.assertNotIn("ENABLE_TESTABILITY=YES", arguments)
                for setting in release.platform_build_settings("ios"):
                    self.assertIn(setting, arguments)
                archive = Path(arguments[arguments.index("-archivePath") + 1])
                symbols = archive / "dSYMs"
                symbols.mkdir(parents=True)
                (symbols / "Miledge.app.dSYM").mkdir()
                key = Path(arguments[arguments.index("-authenticationKeyPath") + 1])
                paths.append(key.parent)
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            elif arguments[:2] == ["xcodebuild", "-exportArchive"]:
                options = Path(arguments[arguments.index("-exportOptionsPlist") + 1])
                self.assertEqual(plistlib.loads(options.read_bytes()), release.export_options(self.config))
            return b""

        with (
            patch.dict(os.environ, environment),
            patch.object(release, "run", side_effect=command),
            patch.object(release.gates, "verify_upload_evidence") as gate,
        ):
            with patch.object(release, "verify_archive") as verify:
                release.upload(self.config, "ios")
                verify.assert_called_once()
                gate.assert_called_once_with(self.root, self.root / ".build/gates", self.config)
        self.assertFalse(paths[0].exists())
        self.assertTrue((self.root / ".build/release/ios/dSYMs/Miledge.app.dSYM").is_dir())

    def test_invalid_certificate_encoding_fails(self):
        with patch.object(release.gates, "verify_upload_evidence"), patch.dict(os.environ, {
            "GITHUB_ACTIONS": "true",
            "ASC_KEY_ID": "SYNTHETIC1",
            "ASC_ISSUER_ID": "synthetic-issuer",
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nSYNTHETIC",
            "SIGNING_CERTIFICATES_P12": "not valid base64",
        }):
            with self.assertRaisesRegex(release.ReleaseError, "base64"):
                release.upload(self.config, "ios")

    def test_archive_failure_cleans_temporary_keys_and_keychain(self):
        paths = []

        def command(arguments, **kwargs):
            if arguments[:2] == ["xcodebuild", "archive"]:
                key = Path(arguments[arguments.index("-authenticationKeyPath") + 1])
                paths.append(key.parent)
                raise release.ReleaseError("synthetic archive failure")
            return b""

        environment = {
            "GITHUB_ACTIONS": "true",
            "ASC_KEY_ID": "SYNTHETIC1",
            "ASC_ISSUER_ID": "synthetic-issuer",
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nSYNTHETIC",
            "SIGNING_CERTIFICATES_P12": base64.b64encode(b"synthetic certificates").decode(),
            "SIGNING_CERTIFICATES_PASSWORD": "synthetic-password",
        }
        with (
            patch.dict(os.environ, environment),
            patch.object(release, "run", side_effect=command) as run,
            patch.object(release.gates, "verify_upload_evidence"),
        ):
            with self.assertRaisesRegex(release.ReleaseError, "synthetic archive failure"):
                release.upload(self.config, "ios")
            self.assertEqual(run.call_args.args[0][:2], ["security", "delete-keychain"])
        self.assertFalse(paths[0].exists())

    def test_upload_fails_before_signing_when_gate_evidence_is_missing(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), patch.object(release, "run") as run:
            with self.assertRaises(release.gates.GateError):
                release.upload(self.config, "ios")
            run.assert_not_called()

    def test_native_coverage_parser_failure_blocks_the_test_command(self):
        with (
            patch.object(release, "test_interaction"),
            patch.object(release, "run", side_effect=[b"", b'{"targets": []}']),
        ):
            with self.assertRaisesRegex(release.gates.GateError, "targets"):
                release.test_platform(self.config, "macos")


if __name__ == "__main__":
    unittest.main()
