# App Store release guide

[日本語](release.ja.md) · [README](../README.md)

The current version is **0.1.0**, build **6**. Mac and iOS/iPadOS builds have reached internal TestFlight. Device installation/acceptance, independent security approval and public-release readiness remain incomplete. No public App Store release has occurred. The guarded GitHub workflow must remain blocked until its evidence and configuration are complete.

## 1. Configure Apple distribution

Use the checked-in `Miledge-iOS` and `Miledge-macOS` schemes; regenerate with XcodeGen 2.46.0 after changing `project.yml`. Both products are `Miledge.app`, Bundle ID `st.rio.miledge`, with a 27.0 minimum OS. Require iOS `UIDeviceFamily` 1 and 2 and arm64-only Mac binaries, including embedded frameworks. Disable automatic iOS-app availability on Mac and Vision Pro.

Configure the official signing team, shared Keychain Access Group, iCloud Drive container and provisioning on both platforms. Keep Mac App Sandbox enabled. Current local development-vault behavior is not evidence of signed-device synchronization or cloud attachment delivery.

App and storage targets contain `PrivacyInfo.xcprivacy`. Review actual data handling, Required Reason API usage and export compliance before each release. The current `ITSAppUsesNonExemptEncryption=false` declaration covers the app's OS-provided encryption use; reassess it when encryption or dependencies change. Verify App Privacy answers, localized store metadata, privacy/support URLs, device support and eligible storefronts. Simplified Chinese localization does not determine mainland-China availability.

Use a new build number; **2, 3, 4, 5 and 6 have already been uploaded**. Preparing or uploading a binary does not submit it to App Review or publish it.

## 2. Protect GitHub configuration and credentials

Create an `app-store` environment with independent approval and protected `v*` deployment tags. Protect the default branch and prevent unauthorized tag replacement/deletion. Do not configure distribution credentials if equivalent approval protections are unavailable.

Use disposable GitHub-hosted Apple Silicon macOS runners. Do not use a shared workstation or persistent self-hosted runner for signing: the upload process temporarily modifies the keychain search list. Pin a runner/Xcode combination supporting OS 27.0 and unattended Mac XCUITest; unavailable automation must fail rather than skip the gate.

Repository variables are needed before environment approval:

| Variable | Required value |
| --- | --- |
| `RELEASE_RUNNER` | Explicit supported macOS label; not `macos-latest` |
| `XCODE_DEVELOPER_DIR` | Absolute selected Xcode `Contents/Developer` path |
| `XCODE_VERSION`, `XCODE_BUILD_VERSION` | Exact `xcodebuild -version` output |
| `XCODE_PROJECT` | `Miledge.xcodeproj` |
| `APPLE_TEAM_ID` | Official signing-team identifier |
| `KEYCHAIN_ACCESS_GROUP` | Shared group including the official team prefix |
| `ICLOUD_CONTAINER_ID` | Shared `iCloud.…` container |
| `IOS_SCHEME`, `MACOS_SCHEME` | `Miledge-iOS`, `Miledge-macOS` |
| `IOS_TEST_DESTINATION` | Installed iPhone: `platform=iOS Simulator,name=<device>,OS=<exact version>` |
| `IPAD_TEST_DESTINATION` | Installed iPad: `platform=iOS Simulator,name=<device>,OS=<exact version>` |

The workflow fixes `IOS_BUNDLE_ID` and `MACOS_BUNDLE_ID` to `st.rio.miledge`. Simulator destinations must support 27.0 or later.

Store distribution credentials only as protected `app-store` environment secrets:

| Secret | Content |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect team API-key identifiers |
| `ASC_PRIVATE_KEY` | Complete `.p8` key, including line breaks |
| `SIGNING_CERTIFICATES_P12` | Single-line base64 PKCS#12 certificate/private-key export |
| `SIGNING_CERTIFICATES_PASSWORD` | PKCS#12 password |

The export must include the applicable signing/installer identities. Upload uses Apple's tools and `-allowProvisioningUpdates`, which may change portal signing resources. An API key alone cannot sign the app.

Set trusted `SECURITY_REVIEWER_ID` and `SECURITY_REVIEW_PUBLIC_KEY` as protected environment variables. The latter is the independent reviewer's RSA/ECDSA public-key PEM. Verify ownership outside this repository; never commit or upload the reviewer's private key.

## 3. Keep all release gates intact

Release tooling requires Python 3.10 or later and OpenSSL. Run:

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/coverage.py swift --measure --report .build/gates/package-llvm.json
```

With the configured variables and matching release tag:

```sh
python3 scripts/release.py test --platform ios
python3 scripts/release.py test --platform macos
```

Each native destination first runs actual synthetic interaction tests, then measures all production `App/` and `Sources/` code in Release configuration. iPhone and iPad run independently. UI tests must be nonempty, serial, without retries, failures, skips or structured runtime warnings; their coverage is disabled. Mac interaction requires local ad-hoc signing and working automation. The test host excludes production authentication/persistence, so synthetic results do not approve those features.

Production executable-line coverage must be **at least 90%** on each destination, with no missing/uninstrumented files or UI/storage exemptions. Test-only testability and coverage overrides must not enter distribution archives. Package coverage is an additional requirement, not a substitute for native coverage.

Swift security analysis uses Semgrep CE 1.179.0, hash-locked dependencies and project rule regressions. The analysis is offline, has suppressions disabled and requires the complete production-source/parser inventory. Python uses CodeQL 2.27.2 with `security-extended`. Verify CodeQL eligibility for the repository's visibility and GitHub plan. These scans do not provide an independent audit.

The workflow binds gate reports to source hashes, commit, run and attempt. Upload reparses evidence before accessing signing material. Missing, stale, partial or mismatched reports fail closed.

`release-readiness.json` must contain substantive passing evidence for backup portability, translations, signed-device/hardware behavior, accessibility and conflict recovery. It is currently blocked. Compute the final digest with:

```sh
python3 scripts/gates.py readiness-digest
```

A digest does not establish readiness. Complete real-device authentication/Keychain/backup testing, cloud delivery/recovery, keyboard/VoiceOver/appearance acceptance, all 12 reviewed localizations and current device compatibility before approving these checks.

`release-security-review.json` is a separate blocked gate. An implementation-independent reviewer must cover every recorded iOS MASVS/MASTG, Mac and scanner-gap scope, resolve findings and document residual risks. Store only a non-sensitive final report under `docs/security-reviews/`, bind its SHA-256 and the final source digest, and sign the exact manifest:

```sh
openssl dgst -sha256 -sign <reviewer-private-key.pem> \
  -out docs/release-security-review.sig docs/release-security-review.json
```

Commit the report, manifest and detached signature, never the private key. Product/test/tool/workflow changes require a fresh review. Environment approval does not waive any gate.

## 4. Upload, test and publish separately

Create an immutable reviewed `vX.Y.Z` tag matching the marketing version. In **Actions → Upload App Store build**, select that tag, the matching version, a new positive integer build number of at most nine digits and the platform. Choose `all` for the first public release.

The workflow performs preflight, both platforms' native interactions/coverage, package coverage and security checks before protected upload approval. It verifies archive identity, architecture, device families, 12 nonempty localization resources, sandbox and absence of debugger entitlement, then uses `xcodebuild -exportArchive` with `app-store-connect`. It retains gate JSON and dSYMs, not signing keys or private app data. Runner termination can interrupt cleanup, so runners must be disposable.

Confirm Apple processing in App Store Connect. If only one upload succeeds, do not reuse its accepted build number. Use synthetic internal TestFlight testing first; external testing may need Beta App Review. Record final-source/device acceptance and test upgrade/recovery behavior.

App Review submission and publication remain manual. Supply synthetic review steps, reviewed store/privacy/export information and no real vault. Use manual release after approval, with both platforms ready. Add store links to the READMEs only after actual availability.

For serious defects, pause pending/phased publication as appropriate and submit a new build. Do not assume immediate App Store rollback or downgrade data to an unreadable schema.

## Distribution references

- [App Store submission](https://developer.apple.com/app-store/submitting/) and [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/): recheck SDK and processing requirements at release time.
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): privacy, health exclusion, review and distribution conditions.
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) and [Required Reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api): review actual implementation, not assumptions.

2026-10-17: Build 6, including international and structured input assistance and optional personal-name components, is Testing on both platforms in Miledge Internal. See the [delivery record](testflight-build6-2026-10-17.md).


2026-10-17: **0.1.0 (build 7)** was submitted to App Review on both platforms and shows **Waiting for Review**. It includes the macOS synchronized-list correction and Settings links to the privacy policy and support. For this submission, the user explicitly selected **free, all 175 offered countries/regions, automatic release after approval**. Submission does not establish approval or independent security sign-off. See the [submission record](app-review-2026-10-17.md) for evidence and remaining verification limits.
