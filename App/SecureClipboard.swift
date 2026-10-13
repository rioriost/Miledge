import Foundation
import MiledgeDomain
import Observation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ClipboardIssue: Equatable {
    case copyFailed
    case clearingFailed
}

@MainActor
@Observable
final class SecureClipboard {
    static let lifetime: TimeInterval = 60
    static let ownerType = "com.miledge.clipboard-owner"

    var issue: ClipboardIssue?
    private var owner: UUID?
    private var expires: Date?
    private let cleanup = ClipboardCleanup()
    private let write: (String, UUID, Date) throws -> Void
    private let clear: (UUID) throws -> Void
    private let now: () -> Date
    private let wait: (Duration) async throws -> Void

    init(
        write: @escaping (String, UUID, Date) throws -> Void,
        clear: @escaping (UUID) throws -> Void,
        now: @escaping () -> Date = Date.init,
        wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.write = write
        self.clear = clear
        self.now = now
        self.wait = wait
    }

    @discardableResult
    func copy(_ value: JSONValue) -> Bool {
        do {
            let text = try value.plainTextForCopy()
            guard !text.isEmpty else {
                issue = .copyFailed
                return false
            }
            let token = UUID()
            let expiry = now().addingTimeInterval(Self.lifetime)
            try write(text, token, expiry)
            cleanup.task?.cancel()
            owner = token
            expires = expiry
            issue = nil
            let wait = self.wait
            cleanup.task = Task { [weak self] in
                do {
                    try await wait(.seconds(Self.lifetime))
                } catch is CancellationError {
                    return
                } catch {
                    if self?.owner == token { self?.issue = .clearingFailed }
                    return
                }
                guard self?.owner == token else { return }
                self?.clearOwnedContents()
            }
            return true
        } catch {
            issue = .copyFailed
            return false
        }
    }

    func expireIfNeeded() {
        if let expires, now() >= expires { clearOwnedContents() }
    }

    func clearOwnedContents() {
        cleanup.task?.cancel()
        cleanup.task = nil
        guard let owner else { return }
        do {
            try clear(owner)
            self.owner = nil
            expires = nil
            issue = nil
        } catch {
            issue = .clearingFailed
        }
    }

    static func system() -> SecureClipboard {
        using(.general)
    }

    private final class ClipboardCleanup {
        var task: Task<Void, Never>?

        deinit { task?.cancel() }
    }

    #if os(macOS)
    static func using(_ pasteboard: NSPasteboard) -> SecureClipboard {
        let ownerType = NSPasteboard.PasteboardType(Self.ownerType)
        var ownedChangeCount: Int?
        return SecureClipboard(write: { text, token, _ in
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string),
                  item.setData(Data(token.uuidString.utf8), forType: ownerType) else {
                throw CocoaError(.coderInvalidValue)
            }
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            guard pasteboard.writeObjects([item]) else {
                if pasteboard.data(forType: ownerType) == Data(token.uuidString.utf8) {
                    pasteboard.clearContents()
                }
                throw CocoaError(.fileWriteUnknown)
            }
            ownedChangeCount = pasteboard.changeCount
        }, clear: { token in
            // Read only our ownership marker, never clipboard text from another app.
            guard pasteboard.changeCount == ownedChangeCount,
                  pasteboard.data(forType: ownerType) == Data(token.uuidString.utf8),
                  pasteboard.changeCount == ownedChangeCount else { return }
            pasteboard.clearContents()
        })
    }
    #else
    static func using(_ pasteboard: UIPasteboard) -> SecureClipboard {
        return SecureClipboard(write: { text, token, expiry in
            pasteboard.setItems([[
                UTType.utf8PlainText.identifier: text,
                Self.ownerType: Data(token.uuidString.utf8)
            ]], options: [.localOnly: true, .expirationDate: expiry])
            guard pasteboard.data(forPasteboardType: Self.ownerType) == Data(token.uuidString.utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }, clear: { token in
            // UIKit may defer changeCount updates until the end of the event loop.
            let changeCount = pasteboard.changeCount
            guard pasteboard.data(forPasteboardType: Self.ownerType) == Data(token.uuidString.utf8),
                  pasteboard.changeCount == changeCount else { return }
            pasteboard.setItems([], options: [.localOnly: true])
        })
    }
    #endif
}
