import Foundation
import XCTest
@testable import MiledgeDomain

final class VaultPolicyTests: XCTestCase {
    func testRestorePreservesUnknownNonHealthDataWithoutPermittingScopeConversion() throws {
        var value = revision()
        try VaultPolicy.validateForRestore(value)
        value.schemaVersion = 99
        value.unknownProperties = ["future": .number("9007199254740993")]
        try VaultPolicy.validateForRestore(value)
        XCTAssertTrue(value.isReadOnly)
        value.templateId = "health-record"
        XCTAssertThrowsError(try VaultPolicy.validateForRestore(value)) {
            XCTAssertEqual($0 as? RevisionError, .healthInformationProhibited("health-record"))
        }
        guard case .object(var object) = try LosslessJSON.decode(RevisionCodec.encode(revision())) else {
            return XCTFail("Object required")
        }
        object["storageScope"] = .string("future-scope")
        let unsupported = try RevisionCodec.decode(LosslessJSON.encode(.object(object)))
        XCTAssertThrowsError(try VaultPolicy.validateForRestore(unsupported))
        value = revision()
        value.title = ""
        XCTAssertThrowsError(try VaultPolicy.validateForRestore(value))
        value.schemaVersion = 0
        XCTAssertThrowsError(try VaultPolicy.validateForRestore(value))
    }

    private func revision(field: VaultField? = nil) -> VaultRevision {
        .init(title: "Synthetic", createdAt: Date(timeIntervalSince1970: 0),
              sections: field.map { [.init(id: "test", fields: [$0])] } ?? [])
    }

    func testRequiresOnlyTypeAndTitleAndPreservesTitleWhitespace() throws {
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(VaultRevision()))
        for title in ["", "  ", "\n\t"] {
            var value = revision()
            value.title = title
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        }
        var value = revision()
        value.title = "  日本語 \n"
        try VaultPolicy.validateForWrite(value)
        XCTAssertEqual(value.title, "  日本語 \n")
        value.modifiedAt = Date(timeIntervalSince1970: -5)
        try VaultPolicy.validateForWrite(value)
    }

    func testEveryProhibitedHealthTypeIsRejectedBeforeUnsupportedPolicy() throws {
        for type in VaultPolicy.prohibitedHealthTypes {
            var value = revision()
            value.templateId = type
            value.schemaVersion = 999
            XCTAssertTrue(value.isReadOnly)
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(value)) {
                XCTAssertEqual($0 as? RevisionError, .healthInformationProhibited(type))
            }
            // Decode and backup do not silently omit health records; persistence is blocked.
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
        }
        var value = revision()
        value.templateId = " Medical_Record "
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value)) {
            XCTAssertEqual($0 as? RevisionError, .healthInformationProhibited(" Medical_Record "))
        }
    }

    func testHealthKindsFieldsStructuredAttachmentsAndMetadataCannotBypassPolicy() throws {
        for field in [
            VaultField(id: "diagnosis"),
            VaultField(kind: "medical-record"),
            VaultField(id: "policyType", kind: "select", value: .string("health-insurance")),
            VaultField(id: "identifierSystem", value: .string("health-insurance-card")),
            VaultField(id: "type", value: .string("prescription"))
        ] { XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: field))) }
        var value = revision()
        value.unknownProperties = ["nested": .array([.object(["templateId": .string("medical-record")])])]
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        value.unknownProperties = [:]
        value.attachments = [.object(["type": .string("medical-bill")])]
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        value = revision(field: .init(unknownProperties: ["type": .string("health-record")]))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        value = revision(field: .init())
        value.sections[0].unknownProperties = ["kind": .string("prescription")]
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        value = revision(field: .init(kind: "address", value: .object(["type": .string("medical-record")])))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        // No arbitrary-text classifier, external analysis, or conversion into a custom item.
        value = revision(field: .init(id: "notes", kind: "multiline", value: .string("Synthetic prose mentions health")))
        XCTAssertFalse(VaultPolicy.containsHealthInformation(value))
        try VaultPolicy.validateForWrite(value)
        value = revision(field: .init(id: "identifierSystem", value: .string("UK National Insurance")))
        value.templateId = "social-security-number"
        try VaultPolicy.validateForWrite(value)
    }

    func testUnsupportedReasonsIncludeEntireRecordAndUnknownValuesRemainUntouched() throws {
        var value = revision(field: .init(id: "f", kind: "future", value: .array([.number("1e999")])))
        value.schemaVersion = 2
        value.templateId = "future-non-health"
        value.unknownProperties = ["new": .bool(true)]
        value.sections[0].unknownProperties = ["new": .null]
        value.sections[0].fields[0].unknownProperties = ["new": .number("-0")]
        let reasons = VaultPolicy.unsupportedReasons(for: value)
        XCTAssertEqual(reasons.count, 6)
        XCTAssertTrue(value.isReadOnly)
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value)) {
            XCTAssertEqual($0 as? RevisionError, .unsupported(reasons))
        }
        var known = revision()
        known.templateVersion = 2
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: known), ["templateVersion:2"])
        known.templateVersion = 1
        known.templateId = "affiliate-account"
        known.sections = [.init(id: "profile", fields: [
            .init(id: "profileId", value: .string("future-network")),
            .init(id: "profileVersion", value: .string("77"))
        ])]
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: known), ["profileId:future-network", "profileVersion"])
        known.sections[0].fields[0].value = .string("amazon-creators-api")
        known.sections[0].fields[1].value = .string("1")
        try VaultPolicy.validateForWrite(known)
        known.sections[0].fields[0].value = .string("")
        known.sections[0].fields[1].value = .string("")
        try VaultPolicy.validateForWrite(known)
        known.sections[0].fields[0].value = .null
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: known), ["fieldValueType:profileId"])
        XCTAssertTrue(known.isReadOnly)
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(known))
        known = revision(field: .init(id: "profileId", value: .string("future-api")))
        known.templateId = "api-credential"
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: known), ["profileId:future-api"])
        known.sections[0].fields[0].value = .string("webhook-signing-key")
        try VaultPolicy.validateForWrite(known)
    }

    func testAttachmentVersionAndAlgorithmArePreservedButUnsupportedAreReadOnly() throws {
        var value = revision()
        value.attachments = [
            .string("future-reference"), .object(["formatVersion": .number("2")]),
            .object(["algorithm": .string("future-algorithm")])
        ]
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: value), ["attachment shape", "attachment formatVersion", "attachment algorithm"])
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        value.attachments = [
            .object(["formatVersion": .number("1"), "algorithm": .string("AES-GCM")]),
            .object(["formatVersion": .string("1")])
        ]
        try VaultPolicy.validateForWrite(value)
        value.attachments = [.object(["futureFlag": .null])]
        XCTAssertEqual(VaultPolicy.unsupportedReasons(for: value), ["unknown attachment attributes"])
        XCTAssertTrue(value.isReadOnly)
    }

    func testStructureRejectsEmptyAndDuplicateStableIDsNotIdenticalIDsAcrossSections() throws {
        var value = revision()
        value.schemaVersion = 0
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        value.schemaVersion = 1
        value.templateVersion = 0
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        value.templateVersion = 1
        value.templateId = ""
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        value.templateId = "custom-item"
        value.sections = [.init(id: "")]
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        value.sections = [.init(id: "s"), .init(id: "s")]
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        for fields in [[VaultField(id: "")], [.init(id: "f", kind: "")], [.init(id: "f"), .init(id: "f")]] {
            value.sections = [.init(id: "s", fields: fields)]
            XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        }
        value.sections = [.init(id: "rotation-1", fields: [.init(id: "credentialId")]),
                          .init(id: "rotation-2", fields: [.init(id: "credentialId")])]
        try VaultPolicy.validateForWrite(value)
        let parent = UUID()
        value.parentRevisionIds = [parent, parent]
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
        value.parentRevisionIds = []
        value.modifiedAt = Date(timeIntervalSince1970: -.infinity)
        XCTAssertThrowsError(try VaultPolicy.validateStructure(value))
    }

    func testStringSecretsIdentifiersURLsAndDecimalPrecisionNeverNormalize() throws {
        for kind in ["string", "concealed", "multiline", "url", "email", "phone", "select", "otp-seed", "key-material"] {
            let original = "  000-01-ÄaZ\n秘密\u{202E}\n"
            let value = revision(field: .init(id: "field", kind: kind, value: .string(original), concealed: true))
            try VaultPolicy.validateForWrite(value)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)).sections[0].fields[0].value, .string(original))
        }
        for number in ["0", "-0", "100", "0.001", "-12.000", "1234567890123456789012345678901234567890.12345678901234567890"] {
            try VaultPolicy.validateForWrite(revision(field: .init(id: "amount", kind: "number", value: .string(number))))
        }
        for number in ["1e3", "1,000", "NaN", "+1", "01", ".1", "1.", " 1", "1\n", "1.١"] {
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "amount", kind: "number", value: .string(number)))), number)
        }
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "identifier", value: .number("1")))))
    }

    func testDateOnlyYearMonthAddressAndMultiSelectBoundaries() throws {
        for date in ["", "2024-02-29", "2000-02-29", "2026-10-10"] {
            try VaultPolicy.validateForWrite(revision(field: .init(id: "date", kind: "date", value: .string(date))))
        }
        for date in ["2023-02-29", "1900-02-29", "2026-02-30", "2026-2-1", "2026-10-10Z"] {
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "date", kind: "date", value: .string(date)))))
        }
        for month in ["", "2026-01", "2026-12"] {
            try VaultPolicy.validateForWrite(revision(field: .init(id: "expiry", kind: "year-month", value: .string(month))))
        }
        for month in ["2026-00", "2026-13", "2026-1", "2026-10-01"] {
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "expiry", kind: "year-month", value: .string(month)))))
        }
        let address = JSONValue.object(["freeform": .string("住所"), "name": .string("单名")])
        try VaultPolicy.validateForWrite(revision(field: .init(id: "address", kind: "address", value: address)))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "address", kind: "address", value: .string("text")))))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "address", kind: "address", value: .object(["postalCode": .number("1")])))))
        try VaultPolicy.validateForWrite(revision(field: .init(id: "choices", kind: "multi-select", value: .array([.string("stable-b"), .string("stable-a")]))))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "choices", kind: "multi-select", value: .array([.bool(true)])))))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "choices", kind: "multi-select", value: .null))))
        try VaultPolicy.validateForWrite(revision(field: .init(id: "flag", kind: "boolean", value: .bool(true))))
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(revision(field: .init(id: "flag", kind: "boolean", value: .string("true")))))
    }

    func testOrderedRecoveryCodesRetainUsedStateAndConflicts() throws {
        let code: JSONValue = .object(["id": .string("code-1"), "code": .string("  0001-Ä\n"), "used": .bool(false)])
        var value = revision(field: .init(id: "codes", kind: "recovery-codes", value: .array([code]), concealed: true))
        try VaultPolicy.validateForWrite(value)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
        for invalid: JSONValue in [
            .string("code"), .array([code, code]), .array([.string("code")]),
            .array([.object(["id": .string(""), "code": .string("a"), "used": .bool(false)])]),
            .array([.object(["id": .string("code-1"), "code": .string("a"), "used": .string("false")])]),
            .array([.object(["id": .string("code-1"), "code": .string("a"), "used": .bool(false), "future": .number("1e999")])])
        ] {
            value.sections[0].fields[0].value = invalid
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
        }
    }
}
