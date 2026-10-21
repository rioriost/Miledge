# Custom text privacy and automatic locking — 2026-10-20

## Behavior

- On macOS and iOS/iPadOS, additional **Text** fields offer **Conceal value**
  (Japanese: **値を隠す**), both during creation and subsequent editing.
  The flag uses the existing `VaultField.concealed` representation; field identity,
  type, label, whitespace, and content are preserved without a schema migration.
- Concealed custom text uses the existing password input, reveal, detail, copy,
  and accessibility behavior. The app-wide **Conceal by default** display preference
  applies just as it does to passwords. Enabling concealment on a newly added text
  field no longer inherits the new-field exception that initially reveals inputs.
- Both platforms lock after **60 seconds without input**, with a timer checked
  every second. This interval is a product choice, not a claimed Apple Passwords
  specification. The previous code only locked on scene lifecycle transitions.
- Input resets the deadline; synchronization refreshes do not. Expired deadlines
  cannot be revived by the next input. Monotonic uptime avoids wall-clock changes.
- macOS observes local keyboard, pointer movement, click, drag, and scroll events. It also locks when
  the app resigns active, the screen/system sleeps, or the user session resigns
  active. No global keyboard monitoring or additional permissions are used.
- iOS observes touches/scrolling and key presses in the ledger window, including
  presented sheets, plus native text-field/text-view changes for keyboard input.
  The gesture observer neither cancels touches nor delays their delivery.
  Existing scene inactivity/background locking remains in place.
- Automatic inactivity locking uses the existing lock cleanup: close editors and
  conflict/backup flows, clear temporary files, clear the owned clipboard, and
  clear session contents. Unsaved editor changes are discarded, as they already
  were on background locking. App switching preserves the existing clipboard
  grace behavior for pasting into another app.
- macOS **Lock** is in the app menu with **⌘L**, replacing the former **Ledger**
  menu / **⇧⌘L** command. The production command is also available from Settings
  while the session is unlocked.

## Design and source scope

Preserve the existing SwiftUI architecture, system controls, navigation, deployment
targets (macOS/iOS 27.0), Keychain storage, synchronization, and privacy boundaries.
The new toggle has a field-specific accessibility name containing only its label,
not its private value. All 12 bundled localizations include the new labels.

Retrieved 2026-10-20:

- APPLE-HIG: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
  and [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios):
  preserve platform input and navigation conventions.
- APPLE-HIG: [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar):
  expose commands through the standard menu system and keyboard shortcuts.
- APPLE-HIG: [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields):
  use secure text entry for private values.
- ACCESSIBILITY / APPLE-HIG: [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility):
  semantic labels, system controls, alternative input, and readable text.
- APPLE-SDK: [NSEvent](https://developer.apple.com/documentation/appkit/nsevent):
  local event monitoring receives this app's input.
- APPLE-SDK: [UIGestureRecognizer](https://developer.apple.com/documentation/uikit/uigesturerecognizer)
  and [textDidChangeNotification](https://developer.apple.com/documentation/uikit/uitextfield/textdidchangenotification):
  UIKit input observation; implementation also checked against the installed SDK.
- [Apple releases](https://developer.apple.com/news/releases/): Xcode 27.1
  (27A9275) was released October 15; tests use that installed toolchain.
  Tested runtimes are macOS 27.0.1 (26A434) and iOS Simulator 27.0 (24A434).
  Simulator/runtime versions are independent of the SDK and release feed.

## Verification

Evidence is retained under `.build/privacy-lock-review/` and
`artwork/privacy-lock-20261020/`; all records and entered text were synthetic.

- PASS: 26 selected macOS unit tests in `mac-final.xcresult`, including deadline
  boundaries, activity renewal, fresh unlock, lifecycle notifications, cleanup of
  observers, and concealed custom text encoding/decoding/value editing.
- PASS: Native macOS creation via Additional fields → Text, conceal, reveal, and
  save. Runtime accessibility exposed a secure text field and masked value;
  saved JSON retained `concealed: true` with `kind: "string"`.
- PASS: Native macOS app-menu placement and ⌘L immediately returned to the locked
  screen. A subsequent 70-second observation also showed the locked screen; exact
  timer boundary is covered by unit tests rather than inferred from screenshots.
- PASS: iPhone concealment, reveal-by-switching-off, content preservation, and
  serialized privacy flag (`ios-ui-final.xcresult`). Screenshot visually inspected.
  Initial test attempts were corrected for offscreen fields and tapping the actual
  native switch rather than its containing label.
- PASS: iOS production simulator build (`ios-production-build-fixed.log`).
- PASS: 24 selected iOS unit tests in `ios-unit-final.xcresult`, including the
  shared deadline and persisted custom text privacy tests.
- PASS: Both iOS interaction tests in `ios-complete-fixed.xcresult`. After opening
  an editor, input at 35 seconds extended the session beyond its original expiry;
  the editor was still present after another 35 seconds. With no further input,
  the app locked and dismissed the editor. The final locked screenshot was
  visually inspected. The concealment test was also rerun successfully.
- PASS: `git diff --check`.

Unit runs used `xcodebuild test`, the `Miledge-macOS` / `Miledge-iOS` schemes,
and the `AutomaticLockTests`, `DisplaySettingsTests`, `FieldPresentationTests`,
and `VaultEditorTests` selections. iOS interaction runs used the
`MiledgeInteraction-iOS` scheme and
`GUIReviewRegressionTests/testCustomTextConcealmentPreservesValueAndSavesPrivacy`
plus `GUIReviewRegressionTests/testIdleLockExtendsForInputAndDismissesEditor`.
Destinations were `platform=macOS` and
`platform=iOS Simulator,id=026F2D0F-435C-41E9-9578-36790C2A9CC6`.
Final runs exited successfully; earlier compiler diagnostics for Swift 6 actor
isolation were fixed before these runs.

Not run: physical iPhone/iPad, VoiceOver spoken task completion, full external
keyboard/assistive input matrix, all locales and appearance combinations, and
device sleep/biometric flows on physical iOS hardware. Runtime AX observations
are not VoiceOver validation. No TestFlight/App Store upload is part of this change.
