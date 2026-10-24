# Miledge

[日本語](README.ja.md) · [Privacy policy](PRIVACY.md)

**My Ledger, for private information that does not fit in Apple Passwords.** Miledge is a native SwiftUI app for Apple Silicon Mac, iPhone and iPad. It supports 30 item types plus custom items, including credentials, affiliate accounts, non-health insurance, identity and tax documents, contracts, keys and private notes. Health information is excluded; there is no HealthKit integration.

Current version: **0.1.0** (build **7**). Both platforms have been distributed to an internal TestFlight group. **Miledge has not been released yet** on the App Store; TestFlight distribution is not production or security approval.

## Installation

Public installation will be through the App Store or Mac App Store. Store links will be added after publication. This repository contains source and development tooling, not end-user binaries.

## Current implementation

Browsing follows category → list → detail, with three columns on Mac and wide iPad windows and native back navigation on iPhone. The editor uses a scrolling grouped form, fixed Save/Cancel actions, optional and custom fields, tags, favorites and related items.

Country/region and currency fields have searchable selection; common categories have native pop-ups and an Other option. Dates use a calendar; month-only values use month/year controls. Existing custom values remain intact. New titles default to the localized type plus registration date and stop updating after a manual edit or clear. Display settings control font size and initial concealment; concealed values reveal on hover and copy on click on Mac; on iOS, tapping reveals a value and offers a copy action.

Records are immutable Keychain revisions. Attachments use encrypted local storage, with explicit preview and export. Encrypted backup and restore use native file dialogs. Conflicts require choosing a complete revision; this is not field-by-field merging. Unknown data, original strings and attachment bytes are preserved.

There is no proprietary account or server. The current app uses a development vault; the signed apps share a Keychain access group and new records synchronize through iCloud Keychain. Attachments remain device-local. Health exclusion also applies to custom items and backups, but arbitrary text or files cannot be perfectly classified automatically.

**Do not use this version for real secrets.** Signed-device authentication and persistence, cross-device synchronization/recovery, complete native UI and accessibility acceptance, reviewed translations, and independent security approval remain outstanding. Use synthetic data in TestFlight, tests, issues and screenshots.

## Recovering data when Miledge is unavailable

The storage format is designed to let you recover record contents without launching Miledge if the items remain on a Mac or can synchronize from iCloud Keychain using the same Apple Account. Start by saving the JSON below, then interpret its fields and history. Attachment and encrypted-backup formats follow later in this section.

These instructions follow the current source and Apple's documentation. End-to-end extraction of Miledge's signed-device data has not been verified. They do not guarantee that items survive app removal or that unsynchronized items can be obtained on another device. Check the recovered contents before erasing the original device or app files.

### Save the record JSON using Keychain Access

1. Search for Keychain Access in Spotlight on Mac and open it. This is a separate app from Apple Passwords.
2. Select iCloud or Local Items in the keychain list, then All Items or Passwords. Use the Mac that stored the records, or enable iCloud Keychain with the same Apple Account for synchronizable records. `device-local` records exist only on the original device.
3. Search for `st.rio.miledge.development.revisions`, the service name used by the current app. If nothing appears, broaden the search to `miledge`, quit Keychain Access and reopen it. Record titles are not stored in searchable Keychain attributes, so searching for a title will not find the record.
4. Open an item, select Show password and complete macOS authentication. The password field contains the entire revision's JSON. Also note the account attribute, `recordId/revisionId`.
5. Copy the complete JSON and save it in a text editor as plain text in UTF-8. Use a filename such as `revisionId.json` to distinguish revisions. In TextEdit, choose Format > Make Plain Text and check whether `.txt` is being appended automatically.
6. Save every item for the service. Items represent individual revisions, including earlier contents and deletion records, rather than one item per record. Check that the copy includes the end of the JSON without truncation. Escapes such as `\n` and `\u…` represent characters; retain them unchanged in your original copy.

Copied JSON includes values concealed in the app. Work in a protected location and do not paste it into online JSON formatters. Extracting data does not require editing or deleting the original Keychain items.

Apple references: [View information stored in a keychain](https://support.apple.com/guide/keychain-access/kyca1085/mac) and [TN3137: Mac keychain implementations and UI](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains). Keychain Access displays password items from the data protection keychain. The `security` command primarily targets the older file-based keychain and is not used as a substitute here.

### Read the storage format and revision history

Record contents are **one UTF-8 JSON object per revision**, stored as the data (`kSecValueData`) of a generic-password Keychain item (`kSecClassGenericPassword`). Keychain encryption and access control protect the data; Miledge adds no further encryption layer to the record JSON. On macOS it uses the data protection keychain with access group `$(AppIdentifierPrefix)st.rio.miledge`; signing replaces `$(AppIdentifierPrefix)` with the actual prefix.

| Attribute / JSON key | Meaning |
| --- | --- |
| Keychain service / account | `st.rio.miledge.development.revisions` / `recordId/revisionId` (compare UUIDs without regard to letter case) |
| `schemaVersion` | Record format version; currently `1` |
| `recordId`, `revisionId` | ID grouping revisions of one record, and ID identifying each revision |
| `parentRevisionIds` | IDs of revisions this revision supersedes; empty for the initial revision |
| `templateId`, `templateVersion`, `title` | Item type, its version and the title |
| `storageScope` | `synchronizable` selects iCloud Keychain synchronization; `device-local` stays on the device. Neither value confirms completed synchronization |
| `createdAt`, `modifiedAt` | UTC date/time strings (ISO 8601, ending in `Z`) |
| `sections[].fields[]` | Each field's `id`, `kind`, `value`, `concealed` and optional `label`; `value` holds the actual contents |
| `tags`, `favorite`, `linkedRecordIds` | Tags, favorite flag and related record IDs |
| `deleted` | `true` marks a revision representing deletion of the record |
| `attachments` | Attachment names, types and decryption keys, without the file contents |

Most field values are strings, including number, date and year/month values. Some kinds use booleans, arrays or objects: addresses use objects, multiple selections use string arrays, and recovery codes use arrays of objects containing `id`, `code` and `used`. `concealed: true` controls screen display; it does not add encryption to `value`. For unfamiliar field names, consult `label`, `id` and [TemplateCatalog.swift](Sources/MiledgeDomain/TemplateCatalog.swift). Preserve unknown keys and original strings too.

This is a synthetic record. Stored JSON has no formatting line breaks.

```json
{
  "schemaVersion": 1,
  "recordId": "11111111-1111-4111-8111-111111111111",
  "revisionId": "22222222-2222-4222-8222-222222222222",
  "parentRevisionIds": [],
  "templateId": "custom-item",
  "templateVersion": 1,
  "storageScope": "synchronizable",
  "title": "Example",
  "tags": [],
  "favorite": false,
  "createdAt": "2026-10-24T00:00:00Z",
  "modifiedAt": "2026-10-24T00:00:00Z",
  "deleted": false,
  "sections": [{"id": "notes", "fields": [
    {"id": "body", "kind": "string", "value": "Example text", "concealed": true, "label": "Memo"}
  ]}],
  "attachments": [],
  "linkedRecordIds": []
}
```

To identify the current contents:

1. Group the JSON objects by `recordId` and compare each `revisionId` with the `parentRevisionIds`. If a referenced parent is missing, first look for its JSON. Cycles or parent references to another record also mean the history cannot be treated as valid.
2. A revision not referenced as a parent by any revision of the same record is a history head. If there is one head, it represents the current state. A head with `deleted: true` means the record is deleted. To recover earlier contents, follow its parents to earlier revisions.
3. Multiple heads mean a conflict. Compare their contents and manually recover the values you need. Do not choose a winner solely by the largest `modifiedAt`. A conflict-resolution revision lists the competing heads in `parentRevisionIds`.

You can now read each field and manually move its contents to another storage location. Putting JSON files back into Keychain is not sufficient for safe re-import into Miledge.

### Attachments require the original device's files and keys from the JSON

Attachments currently belong only to `device-local` records and do not synchronize through iCloud Keychain. On Mac the usual directory is `~/Library/Containers/st.rio.miledge/Data/Library/Application Support/Miledge/DeviceLocalBlobs/`. The app resolves `Miledge/DeviceLocalBlobs/` under its Application Support directory. Filenames are lowercase `blobId.miledgeblob`. The directory is marked as excluded from OS backups, so retain separately exported attachments or a Miledge encrypted backup as well.

Each JSON `attachments[]` entry contains `blobId`, `originalFilename`, `mediaType`, `plaintextSize` (a decimal string), `formatVersion` (`"1"`), `algorithm` (`"AES-GCM"`) and `key` (a Base64-encoded 32-byte key). File format 1 starts with a 21-byte header: four bytes `MILD`, version byte `0x01`, and 16 UUID bytes. This is followed by a 12-byte nonce, ciphertext and a 16-byte authentication tag.

For manual decryption, work on copies and Base64-decode the key from the JSON entry with the matching `blobId`. Use a tool supporting AES-256-GCM with that key, nonce, ciphertext and tag, passing the entire 21-byte header as additional authenticated data (AAD). Only save the output after authentication succeeds and its length matches `plaintextSize`. Keychain Access alone cannot perform this decryption; losing either the file or its key prevents recovery. See [EncryptedBlobStore.swift](Sources/MiledgeStorage/EncryptedBlobStore.swift) and [AttachmentService.swift](Sources/MiledgeApplication/AttachmentService.swift) for implementation details.

### Extract an encrypted backup with standard macOS commands

A `.miledge-backup` file is a password-encrypted Apple Encrypted Archive (AEA1, profile 5: `hkdf_sha256_aesctr_hmac__scrypt__none`, no compression, 64 KiB blocks). Decryption produces a binary Property List (`bplist00`) containing `formatVersion: 1`, `revisions` and `blobs`. `revisions` is an array of data values holding UTF-8 revision JSON; `blobs` is an array of attachments containing `metadata`, `bytes` and `scope`. After AEA decryption, each blob's `bytes` is the original attachment content and needs no further AES-GCM decryption.

With the backup and its passphrase, use the Mac's built-in `aea`, `plutil` and `base64`. In a protected working folder, place a copy of the backup named `backup.miledge-backup` and save only the passphrase in `backup-password.txt` as UTF-8 without a BOM or trailing newline. Preserve spaces and the exact Unicode spelling. Change to that folder in Terminal and run:

```sh
umask 077
set -o pipefail
chmod 600 backup-password.txt
aea decrypt -i backup.miledge-backup -o recovered.plist -password backup-password.txt
plutil -convert xml1 -o recovered.xml recovered.plist
plutil -extract revisions.0 raw -o - recovered.plist | base64 -D > revision-0.json
plutil -extract blobs.0.bytes raw -o - recovered.plist | base64 -D > attachment-0.bin
```

Check each command succeeds before continuing. Inspect `recovered.xml` for array counts and contents, then replace `0` with `1`, `2`, etc. to extract the remaining entries. Skip the attachment command if `blobs` is empty. Match `metadata.blobId` against revisions' `attachments[].blobId` to identify the original filename; revision and attachment array positions do not necessarily correspond. Interpret revision history using the steps above.

These commands were checked with synthetic AEA/profile 5 and Property List data. End-to-end verification with a backup exported by Miledge on a device remains outstanding. The passphrase file and decrypted JSON, Property Lists and attachments contain secrets directly; protect any retained files and delete unnecessary working copies after recovery.

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

PhoneNumberKit provides offline phone-number parsing; bundled postal rules and their license notices are included. Draft resources cover 12 localizations: `en`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `fr`, `de`, `es`, `pt-BR`, `it`, `ar`, `hi`. Native-speaker review and complete visual/RTL acceptance are pending. Simplified Chinese localization does not decide mainland-China distribution.

## Release and contributions

The [release guide](docs/release.en.md) describes required GitHub configuration, signing and App Store steps. Upload requires passing native interactions on Mac/iPhone/iPad, at least **90% executable-line production coverage**, security analysis, current readiness evidence and an independently signed security review. Missing evidence blocks upload. Internal TestFlight builds do not bypass the public-release gates.

Swift analysis uses pinned offline Semgrep CE 1.179.0 and project security regressions; Python uses CodeQL 2.27.2. These are not substitutes for an independent audit.

Keep English/Japanese documentation consistent. Preserve unknown fields, history, exact strings and attachment bytes when changing storage. Prefer native controls and short contextual feedback. Never commit real credentials, personal files/screenshots, API keys, signing certificates or private keys; use protected GitHub environment secrets for distribution.

## License

[MIT](LICENSE). Apple materials and any third-party resources retain their respective terms.
