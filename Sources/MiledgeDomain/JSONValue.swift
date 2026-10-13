import Foundation

/// A JSON tree. Numbers retain their original JSON token, including arbitrary precision.
/// Use RevisionCodec for numeric JSON: Foundation's generic Decoder API exposes no raw tokens.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw RevisionError.losslessCodecRequired }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .number: throw RevisionError.losslessCodecRequired
        }
    }

    public func plainTextForCopy() throws -> String {
        if case .string(let text) = self { return text }
        return String(decoding: try LosslessJSON.encode(self), as: UTF8.self)
    }
}

public enum RevisionError: Error, Equatable, Sendable {
    case malformedJSON
    case duplicateJSONKey(String)
    case malformedProperty(String)
    case invalidNumber(String)
    case nestingLimitExceeded
    case losslessCodecRequired
    case healthInformationProhibited(String)
    case unsupported([String])
    case duplicateRevision(UUID)
    case duplicateParent(UUID)
    case missingParent(revision: UUID, parent: UUID)
    case invalidParent(revision: UUID, parent: UUID)
    case cycle(UUID)
}

enum LosslessJSON {
    static func decode(_ data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil else { throw RevisionError.malformedJSON }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw RevisionError.malformedJSON }
        return value
    }

    static func encode(_ value: JSONValue) throws -> Data {
        Data(try text(value, depth: 0).utf8)
    }

    private static func text(_ value: JSONValue, depth: Int) throws -> String {
        guard depth <= 128 else { throw RevisionError.nestingLimitExceeded }
        switch value {
        case .string(let string):
            return String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
        case .number(let token):
            var parser = Parser(bytes: Array(token.utf8))
            guard (try? parser.number()) == token, parser.index == parser.bytes.count else {
                throw RevisionError.invalidNumber(token)
            }
            return token
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let array):
            return "[" + (try array.map { try text($0, depth: depth + 1) }).joined(separator: ",") + "]"
        case .object(let object):
            return "{" + (try object.keys.sorted().map {
                try text(.string($0), depth: depth + 1) + ":" + text(object[$0]!, depth: depth + 1)
            }).joined(separator: ",") + "}"
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func whitespace() {
            while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth <= 128 else { throw RevisionError.nestingLimitExceeded }
            whitespace()
            switch current {
            case 34: return .string(try string())
            case 123:
                index += 1
                whitespace()
                var result: [String: JSONValue] = [:]
                if take(125) { return .object(result) }
                repeat {
                    whitespace()
                    let key = try string()
                    guard result[key] == nil else { throw RevisionError.duplicateJSONKey(key) }
                    whitespace()
                    guard take(58) else { throw RevisionError.malformedJSON }
                    result[key] = try value(depth: depth + 1)
                    whitespace()
                    if take(125) { return .object(result) }
                    guard take(44) else { throw RevisionError.malformedJSON }
                } while true
            case 91:
                index += 1
                whitespace()
                var result: [JSONValue] = []
                if take(93) { return .array(result) }
                repeat {
                    result.append(try value(depth: depth + 1))
                    whitespace()
                    if take(93) { return .array(result) }
                    guard take(44) else { throw RevisionError.malformedJSON }
                } while true
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57: return .number(try number())
            default: throw RevisionError.malformedJSON
            }
        }

        mutating func literal(_ literal: String) throws {
            let token = Array(literal.utf8)
            guard bytes.count - index >= token.count,
                  Array(bytes[index..<(index + token.count)]) == token else {
                throw RevisionError.malformedJSON
            }
            index += token.count
        }

        mutating func string() throws -> String {
            let start = index
            guard take(34) else { throw RevisionError.malformedJSON }
            while let byte = current {
                index += 1
                if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw RevisionError.malformedJSON }
                }
                if byte == 92 {
                    guard current != nil else { throw RevisionError.malformedJSON }
                    index += 1
                } else if byte < 32 { throw RevisionError.malformedJSON }
            }
            throw RevisionError.malformedJSON
        }

        mutating func number() throws -> String {
            let start = index
            _ = take(45)
            if !take(48) {
                guard let byte = current, (49...57).contains(byte) else { throw RevisionError.malformedJSON }
                digits()
            }
            if take(46) {
                guard let byte = current, (48...57).contains(byte) else { throw RevisionError.malformedJSON }
                digits()
            }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                guard let byte = current, (48...57).contains(byte) else { throw RevisionError.malformedJSON }
                digits()
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func digits() {
            while let byte = current, (48...57).contains(byte) { index += 1 }
        }
    }
}
