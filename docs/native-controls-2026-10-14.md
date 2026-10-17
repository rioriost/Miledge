# Native field actions and date controls — 2026-10-14

## Scope and design contract

Keep the existing SwiftUI forms, editor validation, Gregorian civil-date storage,
Keychain behavior, deployment targets (macOS/iOS 27.0), and secure clipboard policy.
Adapt field inspection/copy and date entry to the host platform. This is an interaction
correction, not a claim of complete HIG or accessibility conformance.

- macOS detail values: conceal by default; pointer entry reveals a concealed value;
  pointer exit conceals it again. Clicking the value copies through SecureClipboard
  and acknowledges the result in place. Keyboard focus reveals; Space or Command-C
  copies; Escape conceals. Context menus and accessibility actions also expose commands.
- iOS/iPadOS detail values: tap (or long press) reveals and opens UIKit's native edit menu
  with a field-specific Copy command. Dismissal conceals without copying; successful
  copy acknowledges and conceals. Menu titles never contain secret values.
- No eye icons. In editors, an explicit Show/Hide text action remains alongside editable
  secure input; clicking editable text still edits it rather than overwriting the clipboard.
- macOS dates: NSDatePicker with textFieldAndStepper and presentsCalendarOverlay.
  Year/month/day are independently editable and the same control opens the calendar.
  Month-only values use yearMonth. Empty dates require explicit confirmation and may
  be cancelled without silently inserting today; Clear remains explicit.
- iOS dates: the system graphical picker expands below the field. Its month heading
  switches to the system month/year wheels, allowing large jumps without repeated
  previous/next-month clicks. Month-only fields use UIDatePicker.yearAndMonth/wheels.
- System colors, native keyboard/focus semantics, localized field-action names,
  existing text-size preferences, and lifecycle concealment remain in place.

## Current Apple sources

Retrieved and read 2026-10-14. HIG text retrieved from Apple's DocC responses with the
skill's reader because the initial web HTML was a JavaScript shell. These are scoped
paraphrases; the user's Passwords/Calendar screenshots are observed interaction
references, not proof that the HIG mandates identical behavior for every app.

| Kind | Source | Decision supported |
|---|---|---|
| APPLE-HIG | [Pickers](https://developer.apple.com/design/human-interface-guidelines/pickers) | macOS textual selection for specific dates; graphical browsing; contextual inline pickers on iOS. |
| APPLE-HIG | [Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus) | Prefer the system edit menu; relevant commands, localized concise labels; support familiar long-press/secondary-click interaction. Single tap is the requested supplementary entry point. |
| APPLE-HIG | [Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices) | Predictable pointer feedback with keyboard alternatives. Does not mandate hover-to-reveal secrets universally. |
| APPLE-HIG | [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Precise input, keyboard commands and native platform behavior. |
| APPLE-HIG | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Alternatives to gestures, semantic labels/actions, system colors, text enlargement. |
| APPLE-SDK | [NSDatePicker](https://developer.apple.com/documentation/appkit/nsdatepicker) / [presentsCalendarOverlay](https://developer.apple.com/documentation/appkit/nsdatepicker/presentscalendaroverlay) | Native text-entry/calendar combination; overlay defaults off and is enabled explicitly. |
| APPLE-SDK | [UIEditMenuInteraction](https://developer.apple.com/documentation/uikit/uieditmenuinteraction) | UIKit owns floating edit-menu presentation and input adaptation. |
| APPLE-SDK | [yearAndMonth](https://developer.apple.com/documentation/uikit/uidatepicker/mode/yearandmonth) | Native month/year selection, available iOS 17.4+, requires wheels. |

Version context: Xcode 27.0 (27A266a), local macOS 27.0.1 (26A434), iOS 27.0
simulator. Apple's [release feed](https://developer.apple.com/news/releases/) lists
27.0.1 public releases (September 28) and 27.2 beta 4 (October 13); beta runtimes
were not substituted for the installed SDK/runtime or the project's minimum target.

## Verification record

All test data is synthetic; no personal Keychain values are used. Logs and xcresults
are in `.build/native-controls-20261014/`; retained screenshots are in
`artwork/native-controls-20261014/`.

| Check | Result | Evidence / boundary |
|---|---|---|
| Final macOS and iOS application builds | PASS | `final-mac-build.log`, `final-ios-build.log`; both BUILD SUCCEEDED. |
| Calendar serialization, labels, translations, clipboard ownership/expiry and native picker rendering | PASS | `unit.xcresult`: 26 tests, zero failures. |
| iPhone native menu, copy acknowledgement, exact multiline/Unicode, copy failure | PASS | `third-ios.xcresult`: 4 tests, zero failures. |
| Empty-date cancellation, explicit date/month clear at largest app size, canonical month/date storage | PASS | `date-regression.xcresult`: 3 tests, zero failures. |
| iPhone year/month jump, menu cancellation, isolated reveal state, structured copy, lock/expiry and another app's clipboard contents | PASS | `final-ios.xcresult`: 6 tests, zero failures. Selected 1996-01-15 directly from 2032 without month navigation. |
| Japanese iPad, dark appearance, repeated reveal/copy, calendar/year selection | PASS | `ipad-ja.xcresult`: 1 test, zero failures; screenshots visually inspected. |
| Japanese iPhone, dark appearance, repeated reveal/copy, calendar/year selection; editor at largest app text size | PASS | `iphone-ja.xcresult`: 2 tests, zero failures; screenshots visually inspected. |
| macOS direct date entry and calendar overlay | PASS, bounded native interaction | Clicked the year in 2032-02-29 and typed 1984; separately entered month 10 and day 14; control displayed 1984-10-14. Screenshot shows text entry and calendar together. |
| macOS focus, Command-C and click-to-copy | PASS, bounded native interaction | Shift-Tab revealed the focused synthetic value; Command-C and direct value activation acknowledged Copied; focus change concealed the prior value. Runtime accessibility tree exposed named copy/reveal actions. |
| macOS pointer hover and exit | IMPLEMENTED, runtime check BLOCKED | XCTest runner hung before establishing its connection (`mac-ui.xcresult`, 355 seconds). Available native-control tooling has no pointer-hover operation; keyboard/click checks do not establish physical hover behavior. |
| macOS Japanese/Arabic at 24pt | PASS, rendering only | Native date controls and actions rendered and images inspected. Not proof of screen-reader execution. |
| VoiceOver speech/tasks, physical iPhone/iPad, complete contrast/motion audit | NOT RUN | No claim of full accessibility conformance. |

A first menu test incorrectly searched for a Button instead of UIKit's MenuItem;
the visible menu was present and the test was corrected. A first year-selection test
incorrectly reused DatePicker.Show after UIKit changed it to DatePicker.Hide; the
corrected end-to-end test passed. The interrupted diagnostic `dates-ios.xcresult`
is incomplete and is not treated as a passing test suite.

## Retained images

- [Mac text entry and calendar together](../artwork/native-controls-20261014/mac-calendar-dark.jpg)
- [Mac concealed state](../artwork/native-controls-20261014/mac-secret-concealed.jpg)
- [Mac copy acknowledgement](../artwork/native-controls-20261014/mac-secret-copied.jpg)
- [iPhone Japanese calendar](../artwork/native-controls-20261014/iphone-ja-calendar.png)
- [iPhone Japanese month/year selector](../artwork/native-controls-20261014/iphone-ja-calendar-month-year.png)
- [iPhone Japanese native copy menu](../artwork/native-controls-20261014/iphone-ja-copy-menu.png)
- [iPad Japanese inline calendar](../artwork/native-controls-20261014/ipad-ja-calendar.png)

## Delivery boundary

Uploaded on 2026-10-15 as **0.1.0 (5)** for macOS and iOS/iPadOS. Apple processing
completed; both builds are **Testing** in the existing **Miledge Internal** group
(one tester). Japanese test notes describe the native controls and remaining
physical-device checks. This is internal TestFlight delivery, not public release or
hardware acceptance.

Both Release archives passed signature, bundle/version, arm64, shared Keychain
group and 12-localization checks. Distribution export/upload succeeded for both.
Source hashes, archive verification and delivery records are retained in
`.build/testflight-20261015-build5/`. The earlier verification limitations above,
including physical Mac pointer hover, VoiceOver and actual iCloud delivery, remain.

- macOS build ID: `964fabb4-4433-4c14-a0c2-bf4c3e474d45`
- iOS build ID: `ae953a7c-3f47-40be-943d-fa56c3ef39f0`
- [Both builds Testing](../artwork/testflight-20261015/build5-internal.jpg)
