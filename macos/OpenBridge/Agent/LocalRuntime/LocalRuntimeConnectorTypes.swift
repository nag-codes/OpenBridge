import Foundation

// MARK: - RPC Param Types

struct ReadParams: Decodable, Sendable {
    let path: String
    var offset: Int?
    var limit: Int?
}

struct WriteParams: Decodable, Sendable {
    let path: String
    let content: String
    var encoding: String?
    var mode: Int?
}

struct DeleteParams: Decodable, Sendable {
    let path: String
    var recursive: Bool?
}

struct StatParams: Decodable, Sendable {
    let path: String
}

struct ListParams: Decodable, Sendable {
    let path: String
}

struct GlobParams: Decodable, Sendable {
    let pattern: String
    var path: String?
}

struct GrepParams: Decodable, Sendable {
    let pattern: String
    var path: String?
    var glob: String?
    var context: Int?
}

struct ExecParams: Decodable, Sendable {
    let command: String
    var description: String?
    var workingDir: String?
    var timeout: Int?
    var env: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case command
        case description
        case workingDir = "working_dir"
        case timeout
        case env
    }
}

struct ComputerUseParams: Decodable, Sendable {
    let action: String
    var apps: [String]?
    var thinking: String?
    var x: Int?
    var y: Int?
    var x1: Int?
    var y1: Int?
    var x2: Int?
    var y2: Int?
    var amount: Int?
    var direction: String?
    var modifier: String?
    var combo: String?
    var text: String?
    var key: String?
    var duration: Double?
}

// MARK: - JSON Value Wrapper

/// A type-erased JSON value that supports Codable for raw params/result fields.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(v): try container.encode(v)
        case let .int(v): try container.encode(v)
        case let .double(v): try container.encode(v)
        case let .bool(v): try container.encode(v)
        case let .object(v): try container.encode(v)
        case let .array(v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience to build a JSONValue from a dictionary literal.
    nonisolated static func dict(_ pairs: [String: Any?]) -> JSONValue {
        var obj: [String: JSONValue] = [:]
        for (key, value) in pairs {
            obj[key] = from(value as Any)
        }
        return .object(obj)
    }

    nonisolated static func from(_ value: Any) -> JSONValue {
        switch value {
        case let v as JSONValue:
            v
        case let v as String:
            .string(v)
        case let v as Bool:
            .bool(v)
        case let v as Int:
            .int(v)
        case let v as Int64:
            .int(Int(v))
        case let v as Double:
            .double(v)
        case let v as [String: Any]:
            .dict(v)
        case let v as [Any]:
            .array(v.map { from($0) })
        default:
            .null
        }
    }

    /// Decode the params into a specific Decodable type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Connector Errors

enum ConnectorError: LocalizedError {
    case fileTooLarge(String, Int64)
    case unknownMethod(String)
    case invalidParams(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(path, size): "file too large: \(path) (\(size) bytes)"
        case let .unknownMethod(method): "unknown method: \(method)"
        case let .invalidParams(detail): "invalid params: \(detail)"
        case .notConnected: "connector is not connected"
        }
    }
}
