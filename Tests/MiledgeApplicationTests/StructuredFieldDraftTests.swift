import MiledgeApplication
import MiledgeDomain
import XCTest

final class StructuredFieldDraftTests: XCTestCase {
    func testAddressRetainsEveryComponentWithoutNormalizingText() throws {
        let value: JSONValue = .object([
            "custom locality": .string("  城区\nLine two\r\n"),
            "": .string("Unusual but existing component"),
            "postalCode": .string("000001"),
            "Country": .string("JP")
        ])
        let draft = try AddressFieldDraft(value: value)
        XCTAssertEqual(try draft.json(), value)
        XCTAssertEqual(Set(draft.components.map(\.id)).count, 4)
        XCTAssertEqual(draft.components.map(\.name), ["", "Country", "custom locality", "postalCode"])
    }

    func testAddressDuplicateRenameDoesNotDiscardEitherDraftComponent() throws {
        var draft = try AddressFieldDraft(value: .object(["city": .string("First"), "region": .string("Second")]))
        let identities = draft.components.map(\.id)
        draft.components[1].name = "city"
        XCTAssertThrowsError(try draft.json()) { error in
            XCTAssertEqual(error as? StructuredFieldError, .duplicateComponents)
        }
        XCTAssertEqual(draft.components.map(\.value), ["First", "Second"])
        draft.components[1].name = "custom"
        XCTAssertEqual(try draft.json(), .object(["city": .string("First"), "custom": .string("Second")]))
        XCTAssertEqual(draft.components.map(\.id), identities)
    }

    func testAddressAdditionRemovalAndEmptyValue() throws {
        var draft = try AddressFieldDraft(value: .object([:]))
        draft.components.append(.init(name: "Line", value: "Exact value"))
        XCTAssertEqual(try draft.json(), .object(["Line": .string("Exact value")]))
        draft.components.removeAll()
        XCTAssertEqual(try draft.json(), .object([:]))
        XCTAssertThrowsError(try AddressFieldDraft(value: .string("not an address")))
        XCTAssertThrowsError(try AddressFieldDraft(value: .object(["city": .bool(false)])))
    }

    func testMultipleValuesPreserveDuplicatesOrderWhitespaceAndStableEditingIdentity() throws {
        let original: JSONValue = .array([.string("001"), .string("001"), .string("  a\nb  "), .string("")])
        var draft = try StringListFieldDraft(value: original)
        XCTAssertEqual(draft.json, original)
        let identities = draft.entries.map(\.id)
        XCTAssertEqual(Set(identities).count, 4)
        draft.entries.remove(at: 0)
        draft.entries[0].value = "0002"
        XCTAssertEqual(draft.entries.map(\.id), Array(identities.dropFirst()))
        XCTAssertEqual(draft.json, .array([.string("0002"), .string("  a\nb  "), .string("")]))
        draft.entries.append(.init(value: "last"))
        XCTAssertEqual(draft.entries.last?.value, "last")
        XCTAssertEqual(try StringListFieldDraft(value: .array([])).json, .array([]))
        XCTAssertThrowsError(try StringListFieldDraft(value: .object([:])))
        XCTAssertThrowsError(try StringListFieldDraft(value: .array([.bool(false)])))
    }

    func testTagStringsRetainOrderDuplicatesEmptyValuesAndEditingIdentity() {
        let tags = ["B", "A", "A", "", "  Exact Case, العربية\r\n日本語  "]
        var draft = StringListFieldDraft(strings: tags)
        XCTAssertEqual(draft.strings, tags)
        XCTAssertEqual(draft.json, .array(tags.map(JSONValue.string)))
        let identities = draft.entries.map(\.id)
        XCTAssertEqual(Set(identities).count, tags.count)
        draft.entries.removeFirst()
        draft.entries[0].value = "Changed"
        draft.entries.append(.init(value: "  Last  "))
        XCTAssertEqual(Array(draft.entries.dropLast()).map(\.id), Array(identities.dropFirst()))
        XCTAssertEqual(draft.strings, ["Changed", "A", "", tags[4], "  Last  "])
        draft.entries.removeAll()
        XCTAssertEqual(draft.strings, [])
        XCTAssertEqual(draft.json, .array([]))
    }

    func testRelatedItemsKeepDuplicateReferencesAndStableRowIdentity() {
        let first = UUID()
        let missing = UUID()
        var draft = RelatedItemsDraft(recordIds: [first, first, missing])
        XCTAssertEqual(draft.recordIds, [first, first, missing])
        let identities = draft.entries.map(\.id)
        XCTAssertEqual(Set(identities).count, 3)
        draft.entries.removeAll { $0.id == identities[0] }
        XCTAssertEqual(draft.recordIds, [first, missing])
        XCTAssertEqual(draft.entries.map(\.id), Array(identities.dropFirst()))
        let last = UUID()
        draft.entries.append(.init(recordId: last))
        XCTAssertEqual(draft.recordIds, [first, missing, last])
        draft.entries.removeAll()
        XCTAssertTrue(draft.recordIds.isEmpty)
        XCTAssertTrue(RelatedItemsDraft(recordIds: []).entries.isEmpty)
    }

    func testRelatedItemResolutionNeverChoosesAnArbitraryConflictHead() {
        let target = VaultRevision(title: "Synthetic target")
        let unrelated = VaultRevision(title: "Unrelated")
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: target.recordId, heads: [unrelated]), .unavailable)
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: target.recordId, heads: [unrelated, target]), .available(target))
        var deleted = target
        deleted.deleted = true
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: target.recordId, heads: [deleted]), .unavailable)
        var concurrent = target
        concurrent.revisionId = UUID()
        concurrent.title = "Concurrent"
        for heads in [[concurrent, target], [target, concurrent], [concurrent, deleted], [deleted, concurrent]] {
            XCTAssertEqual(RelatedItemResolution.resolve(recordId: target.recordId, heads: heads), .conflicted)
        }
        var future = target
        future.schemaVersion = 999
        XCTAssertTrue(future.isReadOnly)
        XCTAssertEqual(RelatedItemResolution.resolve(recordId: target.recordId, heads: [future]), .available(future))
    }

    func testRecoveryCodesRetainStableIDsOrderWhitespaceAndUsedState() throws {
        let original: JSONValue = .array([
            .object(["id": .string("stable-one"), "code": .string(" 0001\nEXACT "), "used": .bool(false)]),
            .object(["id": .string("stable-two"), "code": .string("0002"), "used": .bool(true)])
        ])
        var draft = try RecoveryCodesFieldDraft(value: original)
        XCTAssertEqual(try draft.json(), original)
        draft.entries[0].used = true
        draft.entries[1].code = "00002"
        XCTAssertEqual(draft.entries.map(\.id), ["stable-one", "stable-two"])
        XCTAssertEqual(try draft.json(), .array([
            .object(["id": .string("stable-one"), "code": .string(" 0001\nEXACT "), "used": .bool(true)]),
            .object(["id": .string("stable-two"), "code": .string("00002"), "used": .bool(true)])
        ]))
        draft.entries.append(.init(code: "new"))
        XCTAssertEqual(Set(draft.entries.map(\.id)).count, 3)
        draft.entries.removeFirst()
        XCTAssertEqual(draft.entries.first?.id, "stable-two")
        XCTAssertEqual(try RecoveryCodesFieldDraft(value: .array([])).json(), .array([]))
    }

    func testRecoveryMalformedUnknownAndDuplicateEntriesFailWithoutLossyConversion() throws {
        let valid: JSONValue = .object(["id": .string("same"), "code": .string("secret"), "used": .bool(false)])
        XCTAssertThrowsError(try RecoveryCodesFieldDraft(value: .string("wrong type")))
        XCTAssertThrowsError(try RecoveryCodesFieldDraft(value: .array([.string("wrong entry")])))
        XCTAssertThrowsError(try RecoveryCodesFieldDraft(value: .array([.object([
            "id": .string("one"), "code": .string("secret"), "used": .bool(false), "future": .string("keep")
        ])])))
        XCTAssertThrowsError(try RecoveryCodesFieldDraft(value: .array([.object([
            "id": .string("one"), "code": .bool(false), "used": .bool(false)
        ])])))
        XCTAssertThrowsError(try RecoveryCodesFieldDraft(value: .array([valid, valid]))) { error in
            XCTAssertEqual(error as? StructuredFieldError, .invalidRecoveryIdentifiers)
        }
        var draft = try RecoveryCodesFieldDraft(value: .array([valid]))
        draft.entries.append(.init(code: "another", id: ""))
        XCTAssertThrowsError(try draft.json()) { error in
            XCTAssertEqual(error as? StructuredFieldError, .invalidRecoveryIdentifiers)
        }
        draft.entries.removeLast()
        XCTAssertEqual(try draft.json(), .array([valid]))
    }
}
