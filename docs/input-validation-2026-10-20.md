# Deferred editor validation — 2026-10-20

## Behavior and scope

The macOS and iOS/iPadOS editor now retains unvalidated input in a separate
`EditorDraftValues` buffer. Typing no longer calls `VaultEditor.replacingValue`,
validates the entire revision to enable Save, or runs phone/email/URL/postal
advisory checks during view rendering.

- Save stays available for editable items. It merges the current raw values,
  validates the complete candidate, and invokes persistence only if validation
  succeeds. The persistence layer retains its own write validation.
- Invalid saves show the existing localized error alert and mark invalid fields.
  Input remains editable and its exact contents survive correction, conceal/reveal,
  font changes, and supported type changes. Empty titles are rejected at Save.
- Format advice is cached. Existing values get initial advice when the editor
  opens; advice for an active field is hidden and refreshed after focus leaves.
  Explicit choices, including a country, calendar date, common port, or adding
  `https://`, refresh the related advice after selection.
- Postal advice follows the address component's focus. Related checks use the
  current draft values, including country/region and associated dates.
- Numeric examples and other static input hints remain visible. Advisory warnings
  remain nonblocking; malformed values prohibited by the storage schema remain
  blocking at Save.
- Copy reads the current raw draft, never a previous valid value. Unencodable
  address buffers still disable copy and block Save.
- Address duplicate-key and recovery-code serialization checks remain lightweight
  input-time guards so no row can silently disappear during JSON construction.
  Full value validation is deferred. Structural actions still use the domain's
  safety checks; template availability/removal permissions are cached between
  structural changes. Recognized profile choices update the structural context
  after the control finishes editing.

The change preserves SwiftUI/AppKit controls, field privacy, exact numeric
precision, Unicode/line breaks, deployment targets, Keychain persistence, and the
preceding custom-concealment and automatic-lock changes. No new network operation,
normalization, schema migration, or release is involved.

## Design and sources

This is a scoped input-behavior change, not a visual redesign. Native focus,
keyboard order, secure entry, localized error text, and explicit correction remain
the design contract. Advice uses the existing icon/text components.

Sources retrieved 2026-10-20:

- APPLE-HIG: [Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)
  describes context-dependent validation timing, including checking email when
  leaving its field, and logical Tab navigation. The broader Save-time policy is
  the user's requested product decision.
- APPLE-SDK: [FocusState](https://developer.apple.com/documentation/swiftui/focusstate)
  provides focus transitions for SwiftUI inputs.
- APPLE-SDK: [controlTextDidEndEditing](https://developer.apple.com/documentation/appkit/nscontroltexteditingdelegate/controltextdidendediting(_:))
  supplies the existing native AppKit text-field editing boundary.

Retrieved source snapshots and test results are in `.build/privacy-lock-review/`.

## Verification

Toolchain/runtime: Xcode 27.1, macOS 27.0.1 on Apple Silicon, iPhone 17 Pro
Simulator with iOS 27.0. Both production app targets compiled through hosted tests.

| Result bundle | Coverage | Result |
| --- | --- | --- |
| `mac-deferred-input.xcresult` | Rendering/input tests and raw-draft isolation/type retention | 34 passed |
| `mac-deferred-final.xcresult` | Final profile-context/Boolean changes; typed controls and raw drafts | 7 passed |
| `ios-deferred-unit.xcresult` | Raw-draft tests and native input preservation across font changes | 7 passed |
| `ios-deferred-ui.xcresult` | Save rejection/correction, exact decimals, duplicate address keys, raw copy, email/port blur, type change | 6 passed |
| `ios-deferred-blur.xcresult` | Final email/phone/postal focus and country-change checks, after updating postal test | 3 passed |

The initial postal-code regression test still expected feedback while the field
was focused. It was updated to assert that feedback is absent while typing and
appears after focusing the region field; its earlier failure is retained in
`ios-deferred-final.log`. That run's post-test Simulator diagnostics stalled;
the test command and its diagnostic collector were interrupted before the
corrected rerun. No application code change was needed for this expectation fix.

Actual macOS UI inspection with synthetic data verified:

- A focused number field accepts `-` without rejecting the edit.
- Save rejects it and leaves `-` in the editor.
- Correcting it to `-9007199254740993.00000100` and pressing Command-Return
  saves that exact string without requiring a prior focus change.
- Japanese email advice disappears during typing and reappears with the updated
  result after Tab moves to the next field. Saving retains the entered email.

Screenshots are under `artwork/input-validation-20261020/`. Native keyboard
actions and accessibility-tree observations are not VoiceOver testing.
Both the macOS Japanese form and the iOS before/after-focus screenshots were
visually inspected; input, advice, and Save remained legible and reachable.

## Limits

No latency benchmark or Instruments profile was taken, so this establishes removal
of repeated validation work rather than proving the sole cause of the reported
slowness. Physical iOS devices, an actual Japanese IME composition session, and
VoiceOver were not tested in this pass. This is not a full release certification.
