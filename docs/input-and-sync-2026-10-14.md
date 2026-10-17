# Input visibility, settings and Keychain synchronization — 2026-10-14

## Diagnosis

Builds 2 and 3 contained the synchronizable Keychain storage adapter, but the production app supplied no access group and created only `deviceLocal` drafts. Consequently, those builds did not write new entries as synchronizable items. Waiting or relaunching could not transfer those local entries to another device.

The apps already have the same signed app identifier. The missing application wiring and default storage scope were the blockers; a custom iCloud container is not required for Keychain synchronization.

## Build 4 changes

- Give single-line, secure and multiline inputs a visible border and adaptive background. Preserve native Mac editing, selection, focus and secure input.
- Put text size under Settings. On Mac, use the app Settings menu; on iPhone/iPad, show Settings after unlocking. Keep Add visible by grouping backup and sort under More on iOS.
- Supply the expanded shared group `23889H77KX.st.rio.miledge` to both production stores and signed entitlements. Preserve the existing service `st.rio.miledge.development.revisions` so earlier local data remains addressable.
- Create new production drafts with synchronizable storage by default; creation can explicitly choose device-only storage. Synchronizable writes use `kSecAttrSynchronizable=true` and `kSecAttrAccessibleWhenUnlocked` through the existing storage adapter.
- Read on unlock, every five seconds while unlocked, and on manual Refresh. Refresh reads the local Keychain; it does not force Apple's network delivery or acknowledge arrival on another device.
- Hold incomplete synchronized history branches until their ancestors arrive. Complete items remain usable. Local history corruption and backup validation remain strict.
- Offer an explicit copy of a local item's current values into a new synchronizable item. Retain the original and its immutable history. Reject stale/conflicted sources and local attachments. Do not silently migrate existing data.
- Add settings, storage and copy text in all 12 resource languages. Resource parity does not constitute native-speaker approval.

## Validation and limits

- Package tests rerun for the final delivery: **48 passed** (8 synchronization session, 17 existing session, 13 Keychain adapter and 10 catalog/localization tests). Log: `.build/testflight-20261014-build4/tests.log`.
- Both Release archives built with Xcode 27.0 (27A266a). Bundle `st.rio.miledge`, version 0.1.0, build 4, matching expanded access group, signature integrity, 12 locale resources, Mac arm64/sandbox and iOS device families 1/2 verified. Record: `.build/testflight-20261014-build4/archive-verification.json`.
- iPhone simulator: Settings font change/reopen, copy retaining original, light/dark create/edit/save/delete and generated-backup-passphrase checks passed during implementation. A toolbar overflow failure was found and corrected before the passing rerun.
- iPad Pro 13-inch simulator: final Settings, copy-value, edit/save, create and delete workflow passed; light input and Settings screenshots inspected. Result: `.build/testflight-20261014-build4/ipad.xcresult`.
- Mac XCTest could not initialize automation twice (`Timed out while enabling automation mode`); no Mac automated UI pass is claimed. Direct native checks used an isolated in-memory fixture: Japanese light/dark input screenshots, typing, Tab navigation, save, copy retaining original and Settings 16→20 pt/reopen. No user Keychain records were read or modified for those checks.
- Screenshot evidence is retained in `artwork/input-sync-20261014/`. Contrast audits still report findings; passing task assertions are not a declaration that every accessibility audit passed.
- Real signed-device Keychain delivery, offline convergence, cross-device conflict recovery and assistive-technology acceptance remain unverified. Internal TestFlight delivery is for these checks, not a public-release approval.

## Device test

1. Install build 4 on both devices, using the same Apple Account with Passwords & Keychain enabled in iCloud settings.
2. Create a synthetic item with storage set to iCloud Keychain, or explicitly copy an earlier local item using its detail action. The original local item remains separate; edit the new iCloud item when testing subsequent synchronization.
3. Unlock the other device and use Refresh in Settings. Apple determines delivery timing; the app's five-second read interval is not a five-second delivery guarantee.
4. Confirm values, edits in both directions and conflict handling with synthetic content before using real secrets.

Files currently require device-only storage. Cloud attachment delivery is not implemented. Copying an item does not recursively copy its related local items.

## Sources and claim boundaries

Retrieved 2026-10-14:

- [Apple HIG: Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) — visible, identifiable editing controls; tested rendering is separate evidence.
- [Apple HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings) — platform-appropriate settings placement.
- [Security: kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable) — synchronizable versus device-only Keychain attributes.
- [Security: Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) — access groups and signed identifiers.

No exact delivery latency or successful real-device synchronization is inferred from a successful local write, mock test, archive or upload.

## Delivery

Both 0.1.0 (4) uploads succeeded on 2026-10-14 (JST): macOS at 21:06:25 and iOS/iPadOS at 21:06:39. The archives, source digests, verification records and upload logs are in `.build/testflight-20261014-build4/`. These uploads contain the uncommitted working-tree fixes; no Git commit, push or public App Review submission was performed.

Apple processing completed for both platforms. Both builds were added to the existing **Miledge Internal** group (one existing tester) and visibly showed **テスト中 / Testing**. Japanese test notes were saved on both builds. Proof: `artwork/testflight-20261014/build4-internal.jpg`. Build IDs: macOS `cddb60e2-509b-482e-af8f-51846da923ce`; iOS `e89da660-b18d-4e87-bebf-351d2ef75bfc`.
