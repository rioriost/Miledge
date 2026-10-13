# Miledge

[日本語](README.ja.md) · [Privacy policy](PRIVACY.md)

**My Ledger, for private information that does not fit in Apple Passwords.** Miledge is a native SwiftUI app for Apple Silicon Mac, iPhone and iPad. It supports 30 item types plus custom items, including credentials, affiliate accounts, non-health insurance, identity and tax documents, contracts, keys and private notes. Health information is excluded; there is no HealthKit integration.

Current version: **0.1.0** (build **2**). Both platforms have been distributed to an internal TestFlight group. **Miledge has not been released yet** on the App Store; TestFlight distribution is not production or security approval.

## Installation

Public installation will be through the App Store or Mac App Store. Store links will be added after publication. This repository contains source and development tooling, not end-user binaries.

## Current implementation

Browsing follows category → list → detail, with three columns on Mac and wide iPad windows and native back navigation on iPhone. The editor uses a scrolling grouped form, fixed Save/Cancel actions, optional and custom fields, tags, favorites and related items.

Country/region and currency fields have searchable selection; common categories have native pop-ups and an Other option. Dates use a calendar; month-only values use month/year controls. Existing custom values remain intact. New titles default to the localized type plus registration date and stop updating after a manual edit or clear. Display settings control font size and initial concealment; concealed fields support eye buttons and copying without revealing.

Records are immutable Keychain revisions. Attachments use encrypted local storage, with explicit preview and export. Encrypted backup and restore use native file dialogs. Conflicts require choosing a complete revision; this is not field-by-field merging. Unknown data, original strings and attachment bytes are preserved.

There is no proprietary account or server. The current app uses a development vault; official shared Keychain/iCloud configuration and cloud attachment delivery are incomplete. Health exclusion also applies to custom items and backups, but arbitrary text or files cannot be perfectly classified automatically.

**Do not use this version for real secrets.** Signed-device authentication and persistence, cross-device synchronization/recovery, complete native UI and accessibility acceptance, reviewed translations, and independent security approval remain outstanding. Use synthetic data in TestFlight, tests, issues and screenshots.

## Build and test

Use Xcode 27 / Swift 6.4, XcodeGen 2.46.0 and Python 3.10 or later. The deployment minimum is macOS/iOS/iPadOS 27.0. Mac targets are arm64-only; iOS supports both iPhone and iPad. Recheck Apple's current hardware compatibility before release.

```sh
xcodegen generate
swift test --enable-code-coverage
python3 -m unittest discover -s scripts/tests -v

xcodebuild -project Miledge.xcodeproj -scheme Miledge-macOS \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

The unsigned command checks compilation, not authentication or Keychain behavior. Open `Miledge.xcodeproj` in Xcode for simulator or signed-device development; use your own signing team where required.

For a local Mac launchable product, use an ad-hoc signature rather than an unsigned or coverage-instrumented bundle:

```sh
xcodebuild -project Miledge.xcodeproj -scheme Miledge-macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/development-macos build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

Both production schemes, `Miledge-iOS` and `Miledge-macOS`, produce **`Miledge.app`** with Bundle ID **`st.rio.miledge`**. The development Keychain service is `st.rio.miledge.development.revisions`; this is not an officially approved cross-device vault.

| Path | Purpose |
| --- | --- |
| `Sources/` | Domain models, Keychain/encrypted storage and application services; also built by Swift Package |
| `App/` | Shared SwiftUI interface, native input adapters, localizations and AppIcon |
| `Tests/`, `AppTests/` | Library and native application tests |
| `InteractionHost/`, `InteractionTests/` | Synthetic UI hosts and actual-control interaction tests |
| `project.yml`, `Miledge.xcodeproj/` | XcodeGen specification and generated project/shared schemes |
| `scripts/`, `.github/workflows/` | Validation, coverage, security and guarded App Store upload |

`MiledgeInteraction-iOS` and `MiledgeInteraction-macOS` use synthetic fixtures and in-memory callbacks, not personal Keychain records, authentication or the general clipboard. These targets are excluded from product archives. Their results do not establish production persistence.

There are no third-party application dependencies. Draft resources cover 12 localizations: `en`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `fr`, `de`, `es`, `pt-BR`, `it`, `ar`, `hi`. Native-speaker review and complete visual/RTL acceptance are pending. Simplified Chinese localization does not decide mainland-China distribution.

## Release and contributions

The [release guide](docs/release.en.md) describes required GitHub configuration, signing and App Store steps. Upload requires passing native interactions on Mac/iPhone/iPad, at least **90% executable-line production coverage**, security analysis, current readiness evidence and an independently signed security review. Missing evidence blocks upload. Internal TestFlight builds do not bypass the public-release gates.

Swift analysis uses pinned offline Semgrep CE 1.179.0 and project security regressions; Python uses CodeQL 2.27.2. These are not substitutes for an independent audit.

Keep English/Japanese documentation consistent. Preserve unknown fields, history, exact strings and attachment bytes when changing storage. Prefer native controls and short contextual feedback. Never commit real credentials, personal files/screenshots, API keys, signing certificates or private keys; use protected GitHub environment secrets for distribution.

## License

[MIT](LICENSE). Apple materials and any third-party resources retain their respective terms.
