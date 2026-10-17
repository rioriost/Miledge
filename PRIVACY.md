# Privacy Policy

Last updated: October 17, 2026

This policy describes Miledge **0.1.0** (build **7**) for Apple Silicon Mac, iPhone and iPad, including its App Store and TestFlight distributions. Availability on either service does not constitute an independent security certification.

Miledge stores ledger contents on your device and does not send them to a developer-operated server. It requires no Miledge account and includes no advertising, tracking or third-party analytics SDK. Apple's TestFlight diagnostics and information you choose to send for support are separate data flows, as explained below.

## Information handled by the app

Miledge processes information you enter or explicitly import to provide its storage, editing, search, preview, copying, backup and restore features.

| Information | Purpose and storage |
| --- | --- |
| Ledger contents | Titles, field values, notes, tags, relationships, identifiers, timestamps and revision history are stored in Apple's Keychain. These may contain personal or confidential information if you enter it. |
| Attachments | Files you choose to import are encrypted in local app storage. Their original filenames, media types and decryption keys are kept in the protected ledger revision. |
| Display preferences | Font size and initial concealment preferences are stored in local system preferences, separately from the ledger. |

The app does not request contacts, location, microphone or camera access. Health information is outside Miledge's intended scope, and there is no HealthKit integration. Do not enter health information in custom fields, attachments or backups; arbitrary text and files cannot be completely classified automatically.

## Device authentication and storage

Unlocking uses Apple's device-owner authentication interface. The operating system performs the authentication; Miledge receives its result, not your biometric templates, device passcode or account password.

Records are stored in Apple's Keychain using a shared access group for the signed macOS and iOS apps. The service identifier retains the word "development" for compatibility with earlier installations; changing it would make those records inaccessible to the app. Attachments are encrypted with AES-GCM in the app's local storage. Locking closes access to the ledger and attempts to clean up active preview files. These protections are not a guarantee against a compromised device, screenshots, other software or disclosure after copying or export. Concealing a field on screen is not a separate encryption boundary.

New records use synchronizable Keychain storage. When Passwords & Keychain is enabled in iCloud on devices using the same Apple Account, Apple can synchronize these records, including their fields and revision history, between Miledge installations. Apple manages delivery timing; Miledge checks the local Keychain on unlock, on returning to the foreground, periodically while unlocked, and when you choose Refresh. A refresh is not confirmation that every other device has received the data.

Records created by earlier device-local versions remain local until you explicitly migrate an eligible record. Attachment files are device-local and do not synchronize through iCloud Keychain. The app restricts attachments to device-local records. An encrypted backup and restore can transfer local records and attachments. This policy does not promise a delivery deadline, protection against Apple, or any particular outcome for government disclosure requests.

Apple's operating-system, device-backup and account services may handle information under your settings and [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). They are not Miledge-operated services. Local attachment storage is excluded from automatic backup by the app; do not rely on a device backup as a complete Miledge backup.

## Copying, previews and files you export

You control these actions, but they create copies outside the protected ledger:

- **Clipboard:** Copy writes the selected value as plaintext to the system clipboard. Miledge requests device-local copying and attempts to clear its own contents after 60 seconds or an explicit lock, without clearing a later copy made by another app. Other software may read or retain the value before it is cleared, and cleanup is not guaranteed after a crash or process termination.
- **Attachment previews and exports:** An explicit preview creates a temporary decrypted file and attempts to remove it when the preview ends or the ledger locks. Export writes a decrypted copy to a location you choose. Cleanup does not remove exported copies or copies retained by a viewer.
- **Backups:** An explicit backup export creates a passphrase-encrypted file containing ledger revision history and referenced attachments, including retained data from deleted items. Restore reads a file you select. The developer does not receive your backup or its passphrase and cannot recover a lost passphrase.

Files you select or export may be in iCloud Drive or another provider's storage. That provider may process the files under its own terms. Protect exported files, backup passphrases and screenshots, and remove copies you no longer need.

## TestFlight diagnostics and support

The app itself does not send analytics or crash reports to a Miledge backend. However, **TestFlight automatically collects beta-app crash logs and usage information and shares them with the developer; this collection cannot be opted out of while using TestFlight.** Depending on how you were invited, the developer may also receive your name and email address, invitation status, app version, device and operating-system information, install counts and session information.

If you submit TestFlight feedback, Apple also shares your comments, screenshots and associated diagnostic information with the developer. See [TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/) for the full categories, invitation-specific differences, Apple's retention and data-management options.

The developer uses beta diagnostics and feedback to manage testing, investigate defects and improve Miledge. Information you voluntarily send by email or through an issue is used to respond to your request. Developer-held copies are retained only as long as needed for these purposes or applicable legal obligations. They are not used for advertising or sold. Apple's own retention is separate.

Do not include real credentials, ledger contents, backups, personal documents or unredacted screenshots in diagnostics or support messages. GitHub issues and their attachments may be public and are also subject to [GitHub's Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Retention and deletion

Miledge keeps immutable revisions to preserve history and resolve conflicts. **Deleting an item marks it as deleted in a new revision; it does not securely erase earlier revisions or attachment files.** Earlier data can remain in Keychain storage and encrypted backups. The current app does not provide a complete vault-erasure operation.

Uninstalling the app is not a guarantee that Keychain records or system/provider backups are erased. Copies you exported, screenshots, clipboard history and files kept by other apps are outside Miledge's control. The developer cannot remotely access or erase your on-device ledger.

For access or deletion requests concerning developer-held TestFlight or support information, use the contact below. Apple account and service data must also be managed through Apple, including [Apple's Data and Privacy page](https://privacy.apple.com/), where applicable. Do not send your ledger to make a privacy request.

## Contact and changes

For privacy questions or requests, contact the maintainer at [rio_github@rio.st](mailto:rio_github@rio.st). Include only the information needed to identify your request; never send secrets or a backup passphrase.

This policy will be updated when Miledge's data handling changes or services are added. Changes will be recorded in this file and its revision history. App Store privacy disclosures and this policy must reflect the actual released implementation.
