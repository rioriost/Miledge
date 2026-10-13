import Foundation
import XCTest
@testable import MiledgeDomain

final class RevisionCodecTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_791_590_400)
    private func revision() -> VaultRevision { .init(title: "Synthetic", createdAt: epoch) }

    func testContractDefaultsAndCodable() throws {
        let value = revision()
        XCTAssertEqual(value.id, value.revisionId)
        XCTAssertEqual(value.schemaVersion, 1)
        XCTAssertEqual(value.templateVersion, 1)
        XCTAssertEqual(value.storageScope, .deviceLocal)
        XCTAssertEqual(value.modifiedAt, value.createdAt)
        XCTAssertEqual(try JSONDecoder().decode(VaultRevision.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(StorageScope.self, from: Data(#""synchronizable""#.utf8)), .synchronizable)
        XCTAssertEqual(try JSONDecoder().decode(StorageScope.self, from: JSONEncoder().encode(StorageScope.deviceLocal)), .deviceLocal)
        let field = VaultField(label: "Synthetic", unknownProperties: ["future": .array([.bool(true), .null])])
        XCTAssertNotNil(UUID(uuidString: field.id))
        XCTAssertEqual(try JSONDecoder().decode(VaultField.self, from: JSONEncoder().encode(field)), field)
        let section = VaultSection(fields: [field], unknownProperties: ["future": .string("retained")])
        XCTAssertNotNil(UUID(uuidString: section.id))
        XCTAssertEqual(try JSONDecoder().decode(VaultSection.self, from: JSONEncoder().encode(section)), section)
    }

    func testAllJSONTypesAndArbitraryPrecisionRoundTrip() throws {
        let tokens = ["0", "-0", "1844674407370955161600000000000000000000000",
                      "0.000000000000000000000000000000000000000000000000000001",
                      "-123456789012345678901234567890.987654321098765432109876543210",
                      "1e999999", "-1E-999999", "3.14000e+002"]
        var value = revision()
        value.unknownProperties = [
            "future": .object([
                "numberTokens": .array(tokens.map(JSONValue.number)),
                "strings": .array([.string("0001"), .string("👩🏽‍💻\n\"\\\t"), .string("\u{202E}秘密")]),
                "false": .bool(false), "true": .bool(true), "null": .null, "emptyObject": .object([:]), "emptyArray": .array([])
            ])
        ]
        let data = try RevisionCodec.encode(value)
        let decoded = try RevisionCodec.decode(data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.unknownProperties, value.unknownProperties)
        XCTAssertTrue(decoded.isReadOnly)
        for token in tokens { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(token)) }
        XCTAssertEqual(try RevisionCodec.encode(decoded), data)
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(decoded))
    }

    func testUnknownAttributesKindsTemplatesAndVersionsStayIntact() throws {
        var value = revision()
        value.schemaVersion = 22
        value.templateId = "future-non-health"
        value.templateVersion = 8
        value.storageScope = .synchronizable
        value.sections = [
            .init(id: "second", fields: [
                .init(id: "f2", kind: "future-kind", value: .object(["nested": .number("2e999")]), concealed: true,
                      unknownProperties: ["futureFlag": .null])
            ], unknownProperties: ["version": .number("9")]),
            .init(id: "first", fields: [.init(id: "f1", value: .string("  MiXeD\n原文\n"), concealed: true)])
        ]
        value.attachments = [.object(["futureBlob": .number("234567890123456789012345678901234567890")])]
        value.linkedRecordIds = [UUID(), UUID()]
        value.tags = ["العربية", "日本語"]
        value.favorite = true
        let decoded = try RevisionCodec.decode(RevisionCodec.encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.sections.map(\.id), ["second", "first"])
        XCTAssertEqual(decoded.sections[1].fields[0].value, .string("  MiXeD\n原文\n"))
        XCTAssertEqual(try RevisionGraph.heads(in: [decoded]), [decoded])
    }

    func testUnknownStorageScopeIsNotWritableLocalFallback() throws {
        var object = try JSONObject(revision().json, path: "revision").values
        object["storageScope"] = .string("future-scope")
        let data = try LosslessJSON.encode(.object(object))
        let decoded = try RevisionCodec.decode(data)
        XCTAssertEqual(decoded.unsupportedStorageScope, "future-scope")
        XCTAssertTrue(decoded.isReadOnly)
        XCTAssertEqual(try RevisionCodec.encode(decoded), data)
        XCTAssertThrowsError(try VaultPolicy.validateForWrite(decoded)) {
            XCTAssertEqual($0 as? RevisionError, .unsupported(["storageScope:future-scope"]))
        }
    }

    func testISOTimestampsPreservePrecisionAndUTCSyntax() throws {
        for time in ["2026-10-10T00:00:00Z", "2026-10-10T00:00:00.123456789Z", "2026-10-10T00:00:00.999999999Z", "2024-02-29T23:59:59.000Z"] {
            var object = try JSONObject(revision().json, path: "revision").values
            object["createdAt"] = .string(time)
            object["modifiedAt"] = .string(time)
            let decoded = try RevisionCodec.decode(LosslessJSON.encode(.object(object)))
            let roundtrip = try JSONObject(LosslessJSON.decode(RevisionCodec.encode(decoded)), path: "revision").values
            XCTAssertEqual(roundtrip["createdAt"], .string(time))
            XCTAssertEqual(roundtrip["modifiedAt"], .string(time))
        }
        var value = revision()
        value.modifiedAt = value.createdAt.addingTimeInterval(60)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
        for timestamp in [813_024_456.1234567, -0.123456789, 0.0000000001] {
            value.createdAt = Date(timeIntervalSinceReferenceDate: timestamp)
            value.modifiedAt = value.createdAt
            let restored = try RevisionCodec.decode(RevisionCodec.encode(value))
            XCTAssertEqual(restored, value)
            XCTAssertEqual(restored.createdAt, value.createdAt)
        }
        for invalid in [
            "", "2026-10-10", "2026-10-10T00:00:00+00:00", "2026-10-10T00:00:00z",
            "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-10T25:00:00Z",
            "2026-10-10T23:59:60Z", "2026-10-10T00:00:00.Z", "2026-10-10T00:00:00Z\n"
        ] {
            XCTAssertThrowsError(try RevisionTimestamp.parse(invalid, path: "date"), invalid)
        }
        var invalid = value
        invalid.createdAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try RevisionCodec.encode(invalid))
        XCTAssertThrowsError(try RevisionTimestamp.string(Date(timeIntervalSince1970: .nan), original: nil))
        var decoded = try RevisionCodec.decode(RevisionCodec.encode(value))
        decoded.modifiedAt = decoded.modifiedAt.addingTimeInterval(100)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(decoded)), decoded)
    }

    func testMalformedRequiredPropertyTypesNeverBecomeEmptyRecords() throws {
        let valid = try JSONObject(revision().json, path: "revision").values
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try RevisionCodec.decode(LosslessJSON.encode(.object(missing))), key)
            var wrongType = valid
            wrongType[key] = .null
            XCTAssertThrowsError(try RevisionCodec.decode(LosslessJSON.encode(.object(wrongType))), key)
        }
        for (key, invalid) in [
            ("recordId", JSONValue.string("not-a-uuid")), ("revisionId", .string("")),
            ("parentRevisionIds", .array([.string("bad-uuid")])), ("linkedRecordIds", .array([.bool(false)])),
            ("tags", .array([.number("3")])), ("schemaVersion", .number("1.0")),
            ("schemaVersion", .number("99999999999999999999999999999999")), ("templateVersion", .number("0"))
        ] {
            var object = valid
            object[key] = invalid
            XCTAssertThrowsError(try RevisionCodec.decode(LosslessJSON.encode(.object(object))), key)
        }
        XCTAssertThrowsError(try RevisionCodec.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try VaultField(json: .array([])))
        XCTAssertThrowsError(try VaultSection(json: .bool(true)))
        for key in ["id", "kind", "value", "concealed"] {
            var field: [String: JSONValue] = ["id": .string("f"), "kind": .string("string"), "value": .string("v"), "concealed": .bool(false)]
            field.removeValue(forKey: key)
            XCTAssertThrowsError(try VaultField(json: .object(field)))
        }
        XCTAssertThrowsError(try VaultField(json: .object(["id": .string("f"), "kind": .string("string"), "value": .null, "concealed": .bool(true), "label": .number("1")])))
        let nullLabel = try VaultField(json: .object(["id": .string("f"), "kind": .string("string"), "value": .null, "concealed": .bool(true), "label": .null]))
        XCTAssertNil(nullLabel.label)
        XCTAssertThrowsError(try VaultSection(json: .object(["id": .string("s"), "fields": .string("wrong")])))
    }

    func testJSONParserSyntaxBoundariesAndDuplicateKeys() throws {
        for text in [
            "", " ", "{", "[", "{\"x\" 1}", "{\"x\":1 \"y\":2}", "{\"x\":1,}", "[1,]", "[1 2]",
            "\"unterminated", "\"\\", "\"\\x\"", "\"\n\"", "\"\\uD800\"", "tru", "fals", "nul",
            "01", "-", "+1", ".5", "1.", "1e", "1e+", "--1", "1e--2", "1 true", "truefalse", "NaN"
        ] {
            XCTAssertThrowsError(try LosslessJSON.decode(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try LosslessJSON.decode(Data([0xFF])))
        XCTAssertThrowsError(try LosslessJSON.decode(Data(#"{"x":null,"x":2}"#.utf8))) {
            XCTAssertEqual($0 as? RevisionError, .duplicateJSONKey("x"))
        }
        XCTAssertThrowsError(try LosslessJSON.decode(Data(#"{"a":{"x":1,"x":1}}"#.utf8)))
        XCTAssertThrowsError(try LosslessJSON.decode(Data(#"{"a":1,"\u0061":2}"#.utf8))) {
            XCTAssertEqual($0 as? RevisionError, .duplicateJSONKey("a"))
        }
        let escaped = try LosslessJSON.decode(Data(#"{"\u0061":"\uD83D\uDE00","quoted":"\\\""}"#.utf8))
        XCTAssertEqual(escaped, .object(["a": .string("😀"), "quoted": .string("\\\"")]))
        XCTAssertEqual(try LosslessJSON.decode(Data(" \n\r\t[ true , false , null, {}, [] ] \n".utf8)),
                       .array([.bool(true), .bool(false), .null, .object([:]), .array([])]))
        for invalid in ["", "00", "-", "1.", "1e", "true", "2 3", " 1"] {
            XCTAssertThrowsError(try LosslessJSON.encode(.number(invalid))) {
                XCTAssertEqual($0 as? RevisionError, .invalidNumber(invalid))
            }
        }
        let deepJSON = String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130)
        XCTAssertThrowsError(try LosslessJSON.decode(Data(deepJSON.utf8))) {
            XCTAssertEqual($0 as? RevisionError, .nestingLimitExceeded)
        }
        var deep: JSONValue = .null
        for _ in 0..<130 { deep = .array([deep]) }
        XCTAssertThrowsError(try LosslessJSON.encode(deep))
    }

    func testGenericCodableFailsClosedRatherThanRoundNumbers() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data("123456789012345678901234567890".utf8))) {
            XCTAssertEqual($0 as? RevisionError, .losslessCodecRequired)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number("1"))) {
            XCTAssertEqual($0 as? RevisionError, .losslessCodecRequired)
        }
        for value: JSONValue in [.string("text"), .array([.null, .bool(true)]), .object(["x": .string("y")]), .bool(false), .null] {
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
        }
    }
}
