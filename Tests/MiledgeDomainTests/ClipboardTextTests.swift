import MiledgeDomain
import XCTest

final class ClipboardTextTests: XCTestCase {
    func testStringsPreserveExactUTF8WithoutNormalizationOrDirectionCharacters() throws {
        for text in ["", "  0001  ", "Line one\r\nLine two\n", "العربية 日本語 e\u{301}", "0012.3000"] {
            XCTAssertEqual(Array(try JSONValue.string(text).plainTextForCopy().utf8), Array(text.utf8))
        }
    }

    func testNonStringsUseLosslessJSONAndBooleansDoNotDependOnLocale() throws {
        XCTAssertEqual(try JSONValue.number("9007199254740993.000001").plainTextForCopy(),
                       "9007199254740993.000001")
        XCTAssertEqual(try JSONValue.bool(false).plainTextForCopy(), "false")
        XCTAssertEqual(try JSONValue.bool(true).plainTextForCopy(), "true")
        XCTAssertEqual(try JSONValue.null.plainTextForCopy(), "null")
        XCTAssertEqual(try JSONValue.array([.string("B\nA"), .string("A"), .string("A")]).plainTextForCopy(),
                       "[\"B\\nA\",\"A\",\"A\"]")
        XCTAssertEqual(try JSONValue.object([
            "postalCode": .string("000001"), "exact": .number("9007199254740993"), "future": .null
        ]).plainTextForCopy(), "{\"exact\":9007199254740993,\"future\":null,\"postalCode\":\"000001\"}")
    }

    func testRecoveryCodeMetadataAndUnknownNestedDataAreNotDropped() throws {
        let value = JSONValue.array([.object([
            "id": .string("stable"), "code": .string(" 0001 "), "used": .bool(true),
            "future": .object(["order": .array([.string("A"), .string("A")])])
        ])])
        XCTAssertEqual(try value.plainTextForCopy(),
                       "[{\"code\":\" 0001 \",\"future\":{\"order\":[\"A\",\"A\"]},\"id\":\"stable\",\"used\":true}]")
    }

    func testInvalidNumberAndExcessiveNestingFailInsteadOfExportingChangedData() {
        XCTAssertThrowsError(try JSONValue.number("01").plainTextForCopy())
        var value = JSONValue.string("Synthetic")
        for _ in 0..<130 { value = .array([value]) }
        XCTAssertThrowsError(try value.plainTextForCopy())
    }
}
