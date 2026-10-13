import Foundation
import MiledgeApplication
import MiledgeDomain
import XCTest

@MainActor
final class VaultSessionTests: XCTestCase {
    enum Failure: Error { case authentication, storage }

    @MainActor
    final class MemoryStore {
        var records: [Data] = []
        var failRead = false
        var failAppend = false
        var accounts: [String] = []

        func read() throws -> [Data] {
            if failRead { throw Failure.storage }
            return records
        }

        func append(_ data: Data, _ account: String, _ scope: StorageScope) throws {
            if failAppend { throw Failure.storage }
            records.append(data)
            accounts.append(account)
        }
    }

    private func session(
        store: MemoryStore = MemoryStore(),
        authenticate: @escaping @MainActor () async throws -> Void = {}
    ) -> VaultSession {
        VaultSession(
            authenticate: authenticate,
            load: { try store.read() },
            append: { try store.append($0, $1, $2) },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    private func draft(_ session: VaultSession, title: String = "Synthetic item") throws -> VaultRevision {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        var revision = try session.newDraft(template: template)
        revision.title = title
        return revision
    }

    func testStartsLockedAndRejectsAllWrites() throws {
        let session = session()
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.visibleItems().isEmpty)
        let template = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        XCTAssertThrowsError(try session.newDraft(template: template))
        let revision = VaultRevision(templateId: "secure-note", title: "Locked")
        XCTAssertThrowsError(try session.editDraft(revision))
        XCTAssertThrowsError(try session.save(revision))
        XCTAssertThrowsError(try session.delete(revision))
    }

    func testUnlockCreateEditDeletePreservesHistoryAndOpaqueAccounts() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        XCTAssertEqual(session.state, .unlocked)
        let original = try draft(session)
        XCTAssertEqual(original.storageScope, .deviceLocal)
        try session.save(original)
        XCTAssertEqual(session.visibleItems().map(\.title), ["Synthetic item"])
        XCTAssertEqual(store.accounts, ["\(original.recordId.uuidString)/\(original.revisionId.uuidString)"])
        var edit = try session.editDraft(original)
        XCTAssertEqual(edit.parentRevisionIds, [original.revisionId])
        edit.title = "Updated item"
        try session.save(edit)
        XCTAssertEqual(session.heads.map(\.title), ["Updated item"])
        try session.delete(edit)
        XCTAssertTrue(session.visibleItems().isEmpty)
        XCTAssertEqual(store.records.count, 3)
        XCTAssertTrue(try RevisionCodec.decode(store.records.last!).deleted)
        session.lock()
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.heads.isEmpty)
        try await session.unlock()
        XCTAssertTrue(session.visibleItems().isEmpty)
        XCTAssertEqual(session.heads.count, 1)
    }

    func testAuthenticationAndReadFailureNeverExposePartialData() async throws {
        let store = MemoryStore()
        let failedAuthentication = session(store: store) { throw Failure.authentication }
        do {
            try await failedAuthentication.unlock()
            XCTFail("Authentication must fail")
        } catch {}
        XCTAssertEqual(failedAuthentication.state, .locked)
        store.failRead = true
        let failedRead = session(store: store)
        do {
            try await failedRead.unlock()
            XCTFail("Loading must fail")
        } catch {}
        XCTAssertEqual(failedRead.state, .locked)
        XCTAssertTrue(failedRead.heads.isEmpty)
        store.failRead = false
        store.records = [Data("invalid".utf8)]
        do {
            try await failedRead.unlock()
            XCTFail("Malformed revisions must fail")
        } catch {}
        XCTAssertEqual(failedRead.state, .locked)
    }

    func testInterruptedUnlockCannotRepopulateLockedSession() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
        let session = VaultSession(
            authenticate: { await withCheckedContinuation { continuation = $0 } },
            cancelAuthentication: { cancelled = true },
            load: { [] }, append: { _, _, _ in }
        )
        let unlocking = Task { try await session.unlock() }
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(session.state, .unlocking)
        do {
            try await session.unlock()
            XCTFail("Concurrent authentication must fail")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        session.lock()
        XCTAssertTrue(cancelled)
        continuation?.resume()
        do {
            try await unlocking.value
            XCTFail("Interrupted authentication must fail")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testCancelledUnlockReturnsToLockedState() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let session = session { await withCheckedContinuation { continuation = $0 } }
        let task = Task { try await session.unlock() }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume()
        do {
            try await task.value
            XCTFail("Cancellation must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.state, .locked)
    }

    func testStorageFailurePreservesPreviousStateAndDraftCanBeRetried() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        let draft = try draft(session)
        store.failAppend = true
        XCTAssertThrowsError(try session.save(draft))
        XCTAssertTrue(session.heads.isEmpty)
        store.failAppend = false
        try session.save(draft)
        XCTAssertEqual(session.heads.count, 1)
    }

    func testInvalidAndHealthDraftsNeverReachStorage() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var invalid = try draft(session)
        invalid.title = "  "
        XCTAssertThrowsError(try session.save(invalid))
        var health = try draft(session)
        health.templateId = "medical-record"
        XCTAssertThrowsError(try session.save(health))
        var unsupported = try draft(session)
        unsupported.schemaVersion = 999
        XCTAssertThrowsError(try session.save(unsupported))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testAffiliateProfilesCreateDistinctFieldsAndRetainProfileVersion() async throws {
        let session = session()
        try await session.unlock()
        let template = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        let creators = try session.newDraft(template: template, affiliateProfileId: "amazon-creators-api")
        let ids = Set(creators.sections.flatMap(\.fields).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "credentialId", "credentialSecret", "credentialVersion", "partnerTag", "marketplace"
        ]))
        let profile = try XCTUnwrap(creators.sections.first { $0.id == "profile" })
        XCTAssertEqual(profile.fields.first?.value, .string("amazon-creators-api"))
        XCTAssertEqual(profile.fields.last?.value, .string("1"))
        let rakuten = try session.newDraft(template: template, affiliateProfileId: "rakuten-webservice-jp")
        let rakutenIDs = Set(rakuten.sections.flatMap(\.fields).map(\.id))
        XCTAssertTrue(rakutenIDs.isSuperset(of: ["applicationId", "accessKey"]))
        XCTAssertFalse(rakutenIDs.contains("secretKey"))
        for profile in TemplateCatalog.affiliateProfiles {
            var draft = try session.newDraft(template: template, affiliateProfileId: profile.id)
            draft.title = "Synthetic \(profile.id)"
            try session.save(draft)
        }
        XCTAssertEqual(session.heads.count, TemplateCatalog.affiliateProfiles.count)
        XCTAssertThrowsError(try session.newDraft(template: template, affiliateProfileId: "unknown"))
        let note = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        XCTAssertThrowsError(try session.newDraft(template: note, affiliateProfileId: "amazon-creators-api"))
    }

    func testSearchOnlyUsesMetadataAndSortIsStable() async throws {
        let session = session()
        try await session.unlock()
        var first = try draft(session, title: "Bravo")
        first.tags = ["Finance"]
        var secret = try XCTUnwrap(first.sections.first?.fields.first)
        secret.value = .string("never-search-this")
        secret.concealed = true
        first.sections = [VaultSection(id: "custom", fields: [secret])]
        try session.save(first)
        try session.save(draft(session, title: "Alpha"))
        try session.save(draft(session, title: "Alpha"))
        XCTAssertEqual(session.visibleItems().map(\.title), ["Alpha", "Alpha", "Bravo"])
        XCTAssertEqual(session.visibleItems(query: " finance ").count, 1)
        XCTAssertEqual(session.visibleItems(query: "BRAVO").count, 1)
        XCTAssertEqual(session.visibleItems(query: "secure-note").count, 3)
        XCTAssertTrue(session.visibleItems(query: "never-search-this").isEmpty)
        XCTAssertEqual(session.visibleItems().map(\.revisionId), session.visibleItems().map(\.revisionId))
    }

    func testOrganizationEditsAppendAndReloadWithoutChangingOtherData() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var original = try draft(session)
        original.tags = ["B", "A", "A", "", "  Work, العربية\r\n日本語  "]
        original.linkedRecordIds = [UUID(), UUID()]
        try session.save(original)
        var edit = try session.editDraft(original)
        edit.favorite = true
        edit.tags = ["A", "A", "", "  Exact Case  "]
        store.failAppend = true
        XCTAssertThrowsError(try session.save(edit))
        XCTAssertEqual(session.heads, [original])
        XCTAssertEqual(store.records.count, 1)
        store.failAppend = false
        try session.save(edit)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(try RevisionCodec.decode(store.records[0]), original)
        XCTAssertEqual(edit.sections, original.sections)
        XCTAssertEqual(edit.attachments, original.attachments)
        XCTAssertEqual(edit.linkedRecordIds, original.linkedRecordIds)
        XCTAssertEqual(edit.storageScope, original.storageScope)
        session.lock()
        XCTAssertTrue(session.visibleItems(favoritesOnly: true).isEmpty)
        try await session.unlock()
        XCTAssertEqual(session.heads, [edit])
        XCTAssertEqual(session.visibleItems(query: "exact", favoritesOnly: true), [edit])
        var cleared = try session.editDraft(edit)
        cleared.tags = []
        cleared.favorite = false
        try session.save(cleared)
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads, [cleared])
        XCTAssertTrue(session.visibleItems(favoritesOnly: true).isEmpty)
        XCTAssertTrue(session.visibleItems(query: "exact").isEmpty)
        XCTAssertEqual(store.records.count, 3)
    }

    func testRelatedLinksResolveCurrentHeadsAndSurviveFailedSaveCancelAndReload() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        let first = try draft(session, title: "First")
        let second = try draft(session, title: "Second")
        try session.save(first)
        try session.save(second)
        var source = try draft(session, title: "Source")
        let missing = UUID()
        source.linkedRecordIds = [second.recordId, second.recordId, missing, source.recordId]
        source.tags = ["  Keep exact tags  "]
        source.favorite = true
        try session.save(source)
        var targetEdit = try session.editDraft(second)
        targetEdit.title = "Current second"
        try session.save(targetEdit)
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: second.recordId, heads: session.heads), .available(targetEdit))
        var edit = try session.editDraft(source)
        var links = RelatedItemsDraft(recordIds: edit.linkedRecordIds)
        links.entries.removeFirst()
        links.entries.append(.init(recordId: first.recordId))
        edit.linkedRecordIds = links.recordIds
        store.failAppend = true
        XCTAssertThrowsError(try session.save(edit))
        XCTAssertTrue(session.heads.contains(source))
        store.failAppend = false
        try session.save(edit)
        XCTAssertEqual(edit.linkedRecordIds, [second.recordId, missing, source.recordId, first.recordId])
        XCTAssertEqual(edit.tags, source.tags)
        XCTAssertEqual(edit.favorite, source.favorite)
        XCTAssertEqual(edit.sections, source.sections)
        XCTAssertEqual(edit.attachments, source.attachments)
        XCTAssertEqual(edit.storageScope, source.storageScope)
        var abandoned = try session.editDraft(edit)
        abandoned.linkedRecordIds = []
        session.lock()
        XCTAssertTrue(session.heads.isEmpty)
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: second.recordId, heads: session.heads), .unavailable)
        try await session.unlock()
        XCTAssertTrue(session.heads.contains(edit))
        XCTAssertEqual(try RevisionCodec.decode(store.records[2]), source)
        try session.delete(targetEdit)
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: second.recordId, heads: session.heads), .unavailable)
        XCTAssertTrue(session.heads.contains(edit))
        var cleared = try session.editDraft(edit)
        cleared.linkedRecordIds = []
        try session.save(cleared)
        session.lock()
        try await session.unlock()
        XCTAssertTrue(session.heads.contains(cleared))
        XCTAssertTrue(session.heads.contains(first))
        XCTAssertEqual(store.records.count, 7)
    }

    func testFavoritesFilterCombinesMetadataSearchAndPreservesConflicts() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var alpha = try draft(session, title: "Alpha")
        alpha.tags = ["Work"]
        try session.save(alpha)
        var bravo = try draft(session, title: "Bravo")
        bravo.tags = ["Work"]
        bravo.favorite = true
        try session.save(bravo)
        var charlie = try draft(session, title: "Charlie")
        charlie.favorite = true
        try session.save(charlie)
        XCTAssertEqual(session.visibleItems().map(\.title), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(session.visibleItems(favoritesOnly: true).map(\.title), ["Bravo", "Charlie"])
        XCTAssertEqual(session.visibleItems(query: " WORK ", favoritesOnly: true), [bravo])
        XCTAssertEqual(session.visibleItems(query: "charlie", favoritesOnly: true), [charlie])
        XCTAssertEqual(session.visibleItems(query: "secure-note", favoritesOnly: true).count, 2)
        XCTAssertTrue(session.visibleItems(query: "alpha", favoritesOnly: true).isEmpty)
        var deletion = try session.editDraft(charlie)
        deletion.deleted = true
        var competing = deletion
        competing.revisionId = UUID()
        competing.deleted = false
        competing.favorite = false
        store.records += [try RevisionCodec.encode(deletion), try RevisionCodec.encode(competing)]
        session.lock()
        try await session.unlock()
        XCTAssertTrue(session.visibleItems(favoritesOnly: true).contains(deletion))
        XCTAssertFalse(session.visibleItems(favoritesOnly: true).contains(competing))
        XCTAssertTrue(session.hasConflict(deletion))
        XCTAssertThrowsError(try session.editDraft(deletion))
        try session.delete(bravo)
        XCTAssertFalse(session.visibleItems(favoritesOnly: true).contains { $0.recordId == bravo.recordId })
        session.lock()
        XCTAssertTrue(session.visibleItems(query: "work", favoritesOnly: true).isEmpty)
    }

    func testDiscardedOrganizationDraftDoesNotChangeStoredMetadata() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var original = try draft(session)
        original.tags = ["Original"]
        try session.save(original)
        var abandoned = try session.editDraft(original)
        abandoned.tags = ["Not saved"]
        abandoned.favorite = true
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads, [original])
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(session.visibleItems(favoritesOnly: true).isEmpty)
        var future = original
        future.revisionId = UUID()
        future.recordId = UUID()
        future.unknownProperties = ["futureMetadata": .number("9007199254740993")]
        store.records.append(try RevisionCodec.encode(future))
        session.lock()
        try await session.unlock()
        XCTAssertThrowsError(try session.editDraft(future))
        XCTAssertEqual(try RevisionCodec.decode(store.records.last!), future)
    }

    func testStaleDraftAndScopeChangeCannotOverwriteARecord() async throws {
        let session = session()
        try await session.unlock()
        let original = try draft(session)
        try session.save(original)
        var edit = try session.editDraft(original)
        var stale = edit
        stale.revisionId = UUID()
        edit.title = "Current"
        try session.save(edit)
        XCTAssertThrowsError(try session.save(stale)) { error in
            XCTAssertEqual(error as? SessionError, .staleRevision)
        }
        XCTAssertThrowsError(try session.editDraft(original)) { error in
            XCTAssertEqual(error as? SessionError, .missingRecord)
        }
        var changedScope = try session.editDraft(edit)
        changedScope.storageScope = .synchronizable
        XCTAssertThrowsError(try session.save(changedScope)) { error in
            XCTAssertEqual(error as? SessionError, .changedStorageScope)
        }
    }

    func testConcurrentEditDeleteHeadsAreBothVisibleAndNotEditable() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        let base = try draft(session)
        try session.save(base)
        var edited = try session.editDraft(base)
        edited.title = "Concurrent edit"
        var deleted = edited
        deleted.revisionId = UUID()
        deleted.deleted = true
        store.records += [try RevisionCodec.encode(edited), try RevisionCodec.encode(deleted)]
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.visibleItems().count, 2)
        XCTAssertTrue(session.hasConflict(edited))
        XCTAssertThrowsError(try session.editDraft(edited)) { error in
            XCTAssertEqual(error as? SessionError, .conflictRequiresMerge)
        }
        var attemptedMerge = edited
        attemptedMerge.revisionId = UUID()
        attemptedMerge.parentRevisionIds = [edited.revisionId, deleted.revisionId]
        XCTAssertThrowsError(try session.save(attemptedMerge)) { error in
            XCTAssertEqual(error as? SessionError, .conflictRequiresMerge)
        }
    }

    func testEveryTemplateWithOptionalFieldsPersistsAndReloadsWithoutChangingValues() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var expected: [UUID: VaultRevision] = [:]
        for template in TemplateCatalog.all {
            var draft = try session.newDraft(template: template)
            draft.title = "Synthetic \(template.id)"
            for option in try VaultEditor.availableSections(for: draft) {
                draft = try VaultEditor.addingSection(id: option.id, to: draft)
            }
            for kind in VaultEditor.supportedKinds {
                let field = try VaultEditor.customField(kind: kind, label: "Synthetic \(kind)")
                draft.sections.append(VaultSection(id: UUID().uuidString, fields: [field]))
            }
            try session.save(draft)
            expected[draft.recordId] = draft
        }
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads.count, TemplateCatalog.all.count)
        for head in session.heads { XCTAssertEqual(head, expected[head.recordId]) }
    }

    func testStructuredAndExactScalarEditsAppendAndReloadWithoutNormalization() async throws {
        let store = MemoryStore()
        let session = session(store: store)
        try await session.unlock()
        var revision = try draft(session)
        let samples: [(String, JSONValue)] = [
            ("number", .string("9007199254740993.000000000001")),
            ("date", .string("2026-10-10")),
            ("year-month", .string("2026-10")),
            ("key-material", .string("  HEADER\r\n001 Exact Case\r\nEND  ")),
            ("address", .object(["custom region": .string("東京都\n住所"), "postalCode": .string("000001")])),
            ("multi-select", .array([.string("B"), .string("A"), .string("A")])),
            ("boolean", .bool(false)),
            ("recovery-codes", .array([
                .object(["id": .string("stable-code"), "code": .string(" 0001 "), "used": .bool(false)])
            ]))
        ]
        revision.sections = try samples.enumerated().map { index, sample in
            var field = try VaultEditor.customField(kind: sample.0, label: "Synthetic \(index)")
            field = try VaultEditor.replacingValue(in: field, with: sample.1)
            return VaultSection(id: "section-\(index)", fields: [field])
        }
        try session.save(revision)
        var edit = try session.editDraft(revision)
        let field = try XCTUnwrap(edit.sections.last?.fields.first)
        let editedCode: JSONValue = .array([
            .object(["id": .string("stable-code"), "code": .string(" 0001 "), "used": .bool(true)])
        ])
        edit = try VaultEditor.replacingValue(in: edit, sectionID: "section-7", fieldID: field.id, with: editedCode)
        try session.save(edit)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(try RevisionCodec.decode(store.records[0]), revision)
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads, [edit])
        XCTAssertEqual(Array(edit.sections.dropLast()), Array(revision.sections.dropLast()))
    }
}
