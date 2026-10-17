# App Store Review Preflight — 2026-10-17

App / platform: Miledge / macOS and iOS/iPadOS
Version / build: 0.1.0 / 7
Submission type: first App Store submission
Guidelines checked: Apple App Review Guidelines, last updated October 16, 2026
Readiness: Apple submission validation passed; remaining verification limits are recorded below
Scope: preparation and submission to Apple, with automatic release after approval as explicitly requested by the user. This does not establish independent security approval.

## Preparation completed

- Created both Release archives with Xcode 27.1 (27A9275), verified their signatures, and uploaded build 7 to App Store Connect. Both appeared in the build selector and were selected for version 0.1.0.
- Retook and uploaded 84 actual app screenshots in 12 locales: iPhone 36, iPad 24, Mac 24. Used fictional data with the production views in InteractionHost. All images were visually reviewed; an earlier contaminated Mac capture was rejected and replaced.
- Confirmed localized descriptions and promotional text; supplied the existing public GitHub Issues support URL and repository marketing URL where absent.
- Set price to free and availability to all 175 offered countries/regions, as requested. Both version pages use automatic release after approval, explicitly confirmed by the user after the release setting changed during preparation.
- The user entered the review contact information in App Store Connect for both platforms. Contact data is not included in this report. The initial empty-contact save error was resolved. Browser-protected values could not be transferred programmatically; the user completed the Mac entry directly.
- Added privacy-policy and support links to Settings in all 12 localizations, and visually checked the Mac Settings view. Updated the existing public privacy policy to describe current Keychain sync, local attachments, and encrypted backup behavior. The policy-only public commit is `9916833c6fe0371323e459981fd4a26528903efa`.
- Preserved existing source changes, deployment targets, signing team, shared Keychain access group, and internal release gates.

## Actionable findings and limits

### RESOLVED — Apple privacy publication consent

The privacy declaration says no data is collected. Source inspection found no developer-operated network transport, advertising, or analytics. The app uses Apple-managed synchronizable Keychain items and local encrypted files. Publishing the declaration includes Apple's accuracy, legal-compliance, and future-update consent. The user explicitly confirmed that agreement and publication; App Store Connect displayed the published declaration. The policy URL was filled for all 12 locales. Apple's initial validation also identified an unsaved Traditional Chinese support URL, which was saved before both platforms passed validation.

### MANUAL — signed physical-device acceptance

The current turn verified builds, upload acceptance, synthetic functional tests, and Simulator/native UI. It did not establish full physical-device authentication, upgrade retention, cross-device cloud delivery timing, conflict recovery, or portable-backup acceptance. Prior TestFlight reports and local polling tests are not a substitute for that coverage. Apple controls Keychain delivery; a local refresh is not a cloud completion acknowledgment. See the existing release-readiness record and the October 17 synchronization report.

### MANUAL — independent security review

`docs/release-security-review.json` remains blocked and has no independent sign-off. No independent security approval is claimed. App Review submission and Apple's acceptance do not satisfy that internal gate. The user explicitly requested automatic public release after Apple approval; the local gate records were preserved and were not marked passed.

### WARNING — localization review

All 12 locales were rendered and visually inspected in the screenshot workflows. This does not establish native-speaker review of every translation or full task completion in every locale. The existing translation release gate remains unchanged.

### WARNING — accessibility scope

Prior bounded accessibility checks are documented in `docs/accessibility-2026-10-13.md`. This turn did not repeat every assistive-technology workflow and did not perform actual VoiceOver navigation. Accessibility trees and screenshots are not VoiceOver proof. Do not infer comprehensive accessibility certification from the current screenshots.

### WARNING — iPhone Duo coverage

Installed the official iOS 27.1 Simulator runtime and used a dedicated Miledge iPhone Duo device. Inspected the closed outer display, open inner display, and partially open editor. Selection remained visible across layout changes. Entered `Miledge Duo test`, confirmed the input survived pose changes, and saved it; the detail view displayed the saved value. Device Hub briefly showed stale/black frames and background coordinate input failed; raising its window restored live interaction and the save succeeded. No new Miledge crash report was produced. Another task later selected a different Device Hub device, so additional pose/appearance checks were not continued in that shared window.

These checks cover representative navigation, editing, keyboard presentation, and state retention using synthetic records. They do not cover physical Duo hardware, every rotation, all Dynamic Type settings, all locales on Duo, or every workflow. No claim of complete Duo optimization or verification is made, and no Duo Store badge or screenshot set was added.

## Coverage of the five review families

| Family | Status | Evidence / applicability |
|---|---|---|
| Safety | PASS for inspected scope; specialized rules N/A | Personal local ledger; no public UGC, social feed, ads, contests, gambling, medical diagnosis, or Kids Category features. User-entered private records are not distributed content. |
| Performance | PASS for technical checks; MANUAL device acceptance | Swift tests 107 passed; tool tests 210 passed; three locale screenshot suites passed; both archives and uploads succeeded. The source inventory matched the archived candidate before commit cleanup; only a trailing blank line in `App/InputValidationView.swift` was subsequently removed. Review access instructions require no separate account. |
| Business | PASS; IAP/subscription rules N/A | Free price in all offered regions; no StoreKit products, payment flows, subscription entitlements, or external purchase calls in the inspected source. Public App Store distribution selected. |
| Design | PASS for representative UI; WARNING coverage limits | Native navigation/forms and platform controls, retaken localized screenshots, Settings links, Duo adaptive layout checks. Existing Mac synchronization row-height fix included. No full HIG or assistive-technology certification claimed. |
| Legal | PASS for inspected implementation and metadata; publication consent confirmed | Public privacy policy and in-app links; no collection/tracking declarations; packaged privacy manifests and third-party notices; standard existing EULA and trader setting observed. Required-API reasons and sandbox/access-group entitlements checked. Privacy publication was explicitly confirmed by the user. |

N/A groups include public-UGC moderation, health/medical advice, gambling/contests, digital-goods billing/subscriptions, and app-account deletion/third-party sign-in (the app has no app account). The ledger can store a user's private documents; this does not turn it into a provider of those regulated services.

## Technical evidence

- `.build/app-review-20261017/swift-test.log`: 107 tests, zero failures.
- `.build/app-review-20261017/tool-tests.log`: 210 tests passed.
- `.build/app-review-20261017/screenshots-iphone.xcresult`, `screenshots-ipad.xcresult`, `screenshots-macos-v3.xcresult`: localized capture workflows. Earlier rejected Mac results are not delivery assets.
- `.build/app-review-20261017/Miledge-macOS-7.xcarchive` and `Miledge-iOS-7.xcarchive`: version 0.1.0, build 7, `st.rio.miledge`.
- `.build/app-review-20261017/archive-macos.log`, `archive-ios.log`, `upload-macos.log`, `upload-ios.log`: archive/export/upload success. Upload success is distinguished from review acceptance.
- `.build/app-review-20261017/signed-bundle-evidence.json`: 12 localizations, bundled PhoneNumberKit metadata, postal rules, third-party notices, privacy manifests, team `23889H77KX`, shared access group `23889H77KX.st.rio.miledge`, macOS sandbox and user-selected files. The iOS archive has development-signing entitlements; App Store export re-signing and upload were performed by Xcode. Do not describe the archive's entitlement dump as the final transported IPA's signature.
- `.build/app-review-20261017/source-sha256.json`: archived source inventory; all 141 files matched before commit cleanup. The later commit cleanup removed only a trailing blank line in `App/InputValidationView.swift`; executable content is unchanged.
- `artwork/app-store/2026-10-17/`: RGB screenshots, manifest, ZIP, contact sheets, App Store Connect and Duo evidence.
- `docs/list-sync-layout-2026-10-17.md`: prior focused Mac table and refresh regression checks; current build includes that fix.

The two October 17 16:03 crash reports came from the earlier synthetic test investigation. No later Miledge crash report was found during this preparation. This does not establish that every user-reported crash has been reproduced or fixed.

## Apple primary sources

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — policy; checked October 17, displayed update October 16, 2026.
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/) — submission workflow.
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) — accepted sizes; current uploaded sizes match the UI's requirements.
- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) — HIG; current full source retrieved with SHA-256 `0e832233d32dbfa22655ec027281c6c5d5dd5d9a91382f5c0073c3749c4f77e3`.
- [Prepare for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/) — platform guidance; adaptive size classes and system layouts distinguished from review policy.
- [Apple developer releases](https://developer.apple.com/news/releases/) — Xcode 27.1 release verification.

## Submission status

Both final submission actions completed on October 17, 2026 (JST). The App Review overview and each submission detail showed **Waiting for Review** (`審査待ち`). This is submission receipt, not approval.

| Platform | Version / build | Submitted (JST) | Submission ID | Status |
|---|---|---|---|---|
| macOS | 0.1.0 / 7 | 2026-10-17 17:24 | `69d17211-4fad-4e6a-a9d9-d065b6e0ee12` | Waiting for Review |
| iOS / iPadOS | 0.1.0 / 7 | 2026-10-17 17:25 | `4a67c204-8282-4b1b-b2db-935c6c6e89bb` | Waiting for Review |

Both builds also show Testing in the existing **Miledge Internal** TestFlight group (one tester). Build identifiers: macOS `ef08ee43-306b-43e1-9d5f-15f3168fabc6`, iOS `7c36b6e4-982d-480f-aea5-cb800e77dd13`.

Release configuration: **free, all 175 offered countries/regions, automatic release after approval**. The user explicitly confirmed automatic release for both platforms. No approval or public availability is claimed at this stage.

Evidence: `artwork/app-store/2026-10-17/evidence/asc-both-review-submitted.png`, `asc-submission-status.txt`, platform-specific submission screenshots, and `asc-testflight-build7.png`.
