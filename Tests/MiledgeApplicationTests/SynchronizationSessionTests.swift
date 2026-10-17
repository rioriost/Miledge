import Foundation
import MiledgeApplication
import MiledgeDomain
import XCTest

/// Exercises application reads/writes, not Apple's cross-device transport.
@MainActor
final class SynchronizationSessionTests: XCTestCase {
    enum Failure: Error { case storage }
    @MainActor
    final class Store {
        var records: [Data] = []
        var writtenScopes: [StorageScope] = []
        var fails = false
        func session() -> VaultSession {
            VaultSession(authenticate: {}, load: {
                if self.fails { throw Failure.storage }
                return self.records
            }, append: { data, _, scope in
                if self.fails { throw Failure.storage }
                self.records.append(data)
                self.writtenScopes.append(scope)
            }, defaultStorageScope: .synchronizable)
        }
    }

    func testNewDraftSavesAsSynchronizableAndOtherSessionReadsOnlyAfterRefresh() async throws {
        let store = Store()
        let first = store.session(), second = store.session()
        try await first.unlock()
        try await second.unlock()
        let template = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        var draft = try first.newDraft(template: template)
        draft.title = "Synthetic synced note"
        XCTAssertEqual(draft.storageScope, .synchronizable)
        try first.save(draft)
        XCTAssertEqual(store.writtenScopes, [.synchronizable])
        XCTAssertTrue(second.heads.isEmpty)
        try second.refresh()
        XCTAssertEqual(second.heads, [draft])
        XCTAssertNotNil(second.lastReadAt)
    }

    func testChildArrivingBeforeParentWaitsWithoutHidingCompleteItems() async throws {
        let store = Store()
        let root = VaultRevision(templateId: "secure-note", storageScope: .synchronizable, title: "Root")
        var child = root
        child.revisionId = UUID()
        child.parentRevisionIds = [root.revisionId]
        child.title = "Latest"
        var descendant = child
        descendant.revisionId = UUID()
        descendant.parentRevisionIds = [child.revisionId]
        let local = VaultRevision(templateId: "secure-note", title: "Local")
        store.records = try [local, descendant, child].map(RevisionCodec.encode)
        let session = store.session()
        try await session.unlock()
        XCTAssertEqual(session.heads, [local])
        XCTAssertEqual(session.pendingRevisionCount, 2)
        store.records.append(try RevisionCodec.encode(root))
        try session.refresh()
        XCTAssertEqual(Set(session.heads.map(\.revisionId)), [local.revisionId, descendant.revisionId])
        XCTAssertEqual(session.pendingRevisionCount, 0)
    }

    func testMissingLocalHistoryStillFailsClosed() async throws {
        let store = Store()
        var local = VaultRevision(templateId: "secure-note", title: "Broken local")
        local.parentRevisionIds = [UUID()]
        store.records = [try RevisionCodec.encode(local)]
        let session = store.session()
        do { try await session.unlock(); XCTFail("Local corruption must not be treated as delivery delay") }
        catch { XCTAssertEqual(session.state, .locked) }
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testRefreshFailurePreservesVisibleDataAndRecovers() async throws {
        let store = Store()
        let original = VaultRevision(templateId: "secure-note", title: "Retained")
        store.records = [try RevisionCodec.encode(original)]
        let session = store.session()
        try await session.unlock()
        store.fails = true
        XCTAssertThrowsError(try session.refresh())
        XCTAssertEqual(session.heads, [original])
        XCTAssertTrue(session.refreshFailed)
        store.fails = false
        try session.refresh()
        XCTAssertFalse(session.refreshFailed)
    }

    func testCopyPreservesLocalIdentityAndHistoryAndCreatesIndependentSyncedItem() async throws {
        let store = Store()
        let original = VaultRevision(templateId: "secure-note", title: "Retained local")
        let originalBytes = try RevisionCodec.encode(original)
        store.records = [originalBytes]
        let session = store.session()
        try await session.unlock()
        let copy = try session.copyForSynchronization(original)
        XCTAssertNotEqual(copy.recordId, original.recordId)
        XCTAssertNotEqual(copy.revisionId, original.revisionId)
        XCTAssertTrue(copy.parentRevisionIds.isEmpty)
        XCTAssertEqual(copy.storageScope, .synchronizable)
        XCTAssertEqual(copy.sections, original.sections)
        XCTAssertEqual(copy.title, original.title)
        XCTAssertEqual(store.records.first, originalBytes)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.writtenScopes, [.synchronizable])
        XCTAssertTrue(session.heads.contains(original))
        XCTAssertTrue(session.heads.contains(copy))
        XCTAssertThrowsError(try session.copyForSynchronization(copy))
    }

    func testFailedCopyDoesNotRemoveOriginal() async throws {
        let store = Store()
        let original = VaultRevision(templateId: "secure-note", title: "Safe")
        store.records = [try RevisionCodec.encode(original)]
        let session = VaultSession(authenticate: {}, load: { store.records },
            append: { _, _, _ in throw Failure.storage }, defaultStorageScope: .synchronizable)
        try await session.unlock()
        XCTAssertThrowsError(try session.copyForSynchronization(original))
        XCTAssertEqual(session.heads, [original])
        XCTAssertEqual(store.records.count, 1)
    }

    func testCopyRefreshRejectsAStaleSource() async throws {
        let store = Store()
        let original = VaultRevision(templateId: "secure-note", title: "Old")
        store.records = [try RevisionCodec.encode(original)]
        let session = store.session()
        try await session.unlock()
        var edit = original
        edit.revisionId = UUID()
        edit.parentRevisionIds = [original.revisionId]
        edit.title = "New"
        store.records.append(try RevisionCodec.encode(edit))
        XCTAssertThrowsError(try session.copyForSynchronization(original)) { error in
            XCTAssertEqual(error as? SessionError, .staleRevision)
        }
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(session.heads, [edit])
    }

    func testCopyRejectsLocalAttachmentsAndConflictingBranches() async throws {
        let store = Store()
        let attached = VaultRevision(templateId: "secure-note", title: "Local file",
            attachments: [.object(["blobId": .string(UUID().uuidString)])])
        let root = VaultRevision(templateId: "secure-note", title: "Conflict")
        var left = root, right = root
        left.revisionId = UUID()
        right.revisionId = UUID()
        left.parentRevisionIds = [root.revisionId]
        right.parentRevisionIds = [root.revisionId]
        store.records = try [attached, root, left, right].map(RevisionCodec.encode)
        let session = store.session()
        try await session.unlock()
        XCTAssertThrowsError(try session.copyForSynchronization(attached)) { error in
            XCTAssertEqual(error as? SessionError, .changedStorageScope)
        }
        XCTAssertThrowsError(try session.copyForSynchronization(left)) { error in
            XCTAssertEqual(error as? SessionError, .conflictRequiresMerge)
        }
        XCTAssertEqual(store.records.count, 4)
        XCTAssertTrue(store.writtenScopes.isEmpty)
    }
}
