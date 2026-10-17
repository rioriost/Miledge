import LocalAuthentication
import MiledgeApplication
import MiledgeStorage
import SwiftUI

@main
struct MiledgeApp: App {
    @State private var session: VaultSession?
    @State private var attachments: AttachmentService?
    @State private var initializationFailed = false
    @State private var clipboard = SecureClipboard.system()
    @AppStorage("displayTextSize") private var displayTextSize = DisplayTextSize.standard

    var body: some Scene {
        #if os(macOS)
        Window("Miledge", id: "ledger") { ledgerContent.displayPreferences() }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1100 * displayTextSize.scale, height: 760 * displayTextSize.scale)
        .windowResizability(.contentMinSize)
        .commands {
            LedgerCommands()
            BackupCommands()
        }
        Settings { DisplaySettingsView(session: session) }
        #else
        WindowGroup { ledgerContent.displayPreferences() }
        #endif
    }

    private var ledgerContent: some View {
        Group {
            if let session, let attachments {
                LedgerView(session: session, attachments: attachments, clipboard: clipboard)
            } else if initializationFailed {
                ContentUnavailableView(
                    "Storage unavailable",
                    systemImage: "exclamationmark.lock",
                    description: Text("Close Miledge and try again.")
                )
            } else {
                ProgressView()
                    .task { initialize() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 520)
        .resizeForDisplayText()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            clipboard.clearOwnedContents()
        }
        #endif
    }

    @MainActor
    private func initialize() {
        do {
            guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "MiledgeKeychainAccessGroup") as? String,
                  !accessGroup.isEmpty, !accessGroup.contains("$(") else {
                throw KeychainStorageError.invalidConfiguration
            }
            let store = try KeychainRevisionStore(
                // Keep the existing service and default access group so build 2/3 data stays readable.
                configuration: KeychainConfiguration(
                    service: "st.rio.miledge.development.revisions", accessGroup: accessGroup
                )
            )
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Miledge/DeviceLocalBlobs", isDirectory: true)
            attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
            let authenticator = SystemOwnerAuthenticator()
            session = VaultSession(
                authenticate: { try await authenticator.authenticate() },
                cancelAuthentication: { authenticator.cancel() },
                load: { try store.readAll() },
                append: { data, account, scope in
                    try store.append(
                        data: data, account: account,
                        scope: scope == .deviceLocal ? .deviceLocal : .synchronizable
                    )
                },
                defaultStorageScope: .synchronizable
            )
        } catch {
            session = nil
            attachments = nil
            initializationFailed = true
        }
    }

    @MainActor
    final class SystemOwnerAuthenticator {
        private var context: LAContext?

        func authenticate() async throws {
            let context = LAContext()
            self.context = context
            defer {
                context.invalidate()
                self.context = nil
            }
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock your private ledger.")
            )
            guard success else { throw LAError(.authenticationFailed) }
        }

        func cancel() {
            context?.invalidate()
        }
    }
}
