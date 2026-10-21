# App Store upload and macOS resubmission — 2026-10-20

App: Miledge (`st.rio.miledge`, App Store Connect `6822265197`).
Candidate: version **0.1.1**, build **8**, macOS and iOS/iPadOS.
Scope: upload both platforms; withdraw macOS 0.1.0 and resubmit macOS 0.1.1.
The user explicitly requested these actions. iOS review submission is outside
this request; its existing 0.1.0 showed Ready for Distribution.

## Candidate and preparation

- Updated the XcodeGen version/build settings and regenerated the project.
- Included the custom Text concealment, 60-second inactivity lock, macOS app-menu
  Command-L, and deferred input-validation changes documented in
  `privacy-lock-2026-10-20.md` and `input-validation-2026-10-20.md`.
- Created both Release archives with Xcode 27.1 and existing automatic signing.
  Bundle identity, team, deployment targets, storage, and privacy scope are unchanged.
- Both exports reported **Upload succeeded / EXPORT SUCCEEDED**. macOS completed
  at 18:57:38 JST; iOS at 18:59:28 JST.
- The first iOS export failed during packaging because the system rsync launched
  a Homebrew rsync child with incompatible options. Retrying with only Apple's
  standard executable directories in that command's PATH succeeded. No machine
  configuration was changed and the initial attempt did not upload a build.
- Saved an 88-file app/source/project hash inventory; all files still matched
  after upload. Test and documentation changes are not part of that inventory.
- Verified the macOS archive and iOS distribution pipeline's signed app with
  strict signature checks. Both are 0.1.1 (8). The distribution-signed iOS app has
  `get-task-allow=false`; the pre-export development archive is not represented
  as the transported signature. macOS has the existing sandbox and user-selected
  file entitlement. Both retain the shared Keychain group.
- Packaged app, storage, and PhoneNumberKit privacy manifests declare no tracking
  or collected data. Required-API declarations remain present.

Artifacts are in `.build/app-review-20261020/`: archives, upload logs,
`source-hashes.json`, and `signed-bundle-evidence.json`.

## Proportionate preflight

The current Apple App Review Guidelines and upload/removal instructions were
checked on October 20. This is a scoped update to the October 17 preflight,
not an independent security or comprehensive accessibility certification.

| Review family | Result and evidence |
| --- | --- |
| Safety | No new public UGC, social, medical, gambling, or Kids features. Private records remain on-device/Apple-managed Keychain. Specialized rules are not applicable to the inspected feature delta. |
| Performance | Both Release archives and uploads succeeded. Focused macOS/iOS input tests, simulator tests, and actual native Mac inspection are documented in the linked change reports. Apple submission validation is distinct from physical-device acceptance. |
| Business | No pricing, purchase, subscription, or entitlement changes. Existing free/all-region configuration from the October 17 submission is preserved; it was not independently re-audited country by country. |
| Design | Existing native UI, screenshots, localization, and metadata remain applicable. New focus/Save behavior, concealment, and Mac shortcut were inspected in the prior implementation pass. No comprehensive VoiceOver or actual Japanese IME test was performed. |
| Legal | Published No Data Collected declaration and Japanese privacy-policy URL verified in App Store Connect. Existing app information shows standard Apple EULA, no third-party content, trader status, and general 4+ rating. No privacy declaration or legal agreement was newly accepted. |

The existing independent security and signed physical-device acceptance gates
remain incomplete/blocked. No gate file was changed to passed. Actual cross-device
sync delivery, physical authentication, full upgrade retention, native-speaker
localization review, and all assistive-technology workflows were not established
by this release operation. The user was informed of the remaining device/security
limits before resubmission.

## App Store Connect changes

- Removed macOS 0.1.0 from review; the version then showed Developer Rejected.
- Changed that editable first macOS version to 0.1.1, selected build 8, and updated
  reviewer notes with concealment, idle-lock, Command-L, and Save/blur instructions.
- Preserved the review contact, no-account-required setting, screenshots,
  localized product information, and existing **automatic release after approval**.
- Apple accepted the candidate into the submission draft; the final review
  submission action was performed.

Final states were confirmed in the App Store Connect UI:

| Platform | Version/build | Confirmed state |
| --- | --- | --- |
| macOS | 0.1.1 (8) | Waiting for Review; submitted October 20 at 19:03 JST |
| iOS/iPadOS | 0.1.1 (8) | Processing complete; Ready to Submit in TestFlight; not submitted to App Review in this operation |

macOS submission ID: `5d11a92d-aef2-4781-924b-f67507431ad5`.
macOS build ID: `f64db52d-fe6f-4224-a58e-ffa9afa46567`.
iOS build ID: `e6b6db97-b644-42ae-90da-de49b3cfba14`.
The withdrawn macOS submission was
`69d17211-4fad-4e6a-a9d9-d065b6e0ee12` (0.1.0 / 7).

Screenshots and status text are in `artwork/app-store/2026-10-20/evidence/`.
`macos-011-review-submitted.png` shows the new version/build and Waiting for Review.
`ios-011-upload-processed.png` shows version 0.1.1, build 8, Ready to Submit.
These are submission/upload receipts, not approval of version 0.1.1.

## Apple sources

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Remove a submission from review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/remove-a-submission-from-review)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

## Follow-up: iOS added for review

At the user's subsequent request to add iOS 0.1.1 for review, the existing
0.1.1 draft already had build 8 selected. Added release notes in all 12 configured
locales and updated the reviewer notes for custom Text concealment, 60-second
inactivity locking, and Save/blur validation. Existing contact, release settings,
and other product information were preserved.

App Store Connect accepted **Add for Review** and displayed **Ready for Review**
(`審査準備完了`) with **iOS 0.1.1 (8)** in the submission draft on October 20,
approximately 20:03 JST. The final **Submit for Review** button was not pressed;
the requested scope was adding the version for review. This supersedes the earlier
upload-only state, but is not Waiting for Review.

Evidence: `artwork/app-store/2026-10-20/evidence/ios-011-added-for-review.png`
and the corresponding status text. The prior verification limits remain unchanged.
