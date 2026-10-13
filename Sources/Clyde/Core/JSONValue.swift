import Foundation

/// A `Sendable` JSON value. Used everywhere a schema or payload needs to cross an
/// actor/concurrency boundary (Anthropic tool schemas/inputs, MCP tool schemas/results) without
/// relying on `[String: Any]`, which is not `Sendable`.
indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .number(Double(v))
        case let v as Double: self = .number(v)
        case let v as NSNumber:
            // NSNumber conflates Bool and numeric types; disambiguate via objCType.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else { self = .number(v.doubleValue) }
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as [Any]:
            self = .array(v.map { JSONValue(any: $0) })
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.anyValue }
        case .array(let v): return v.map { $0.anyValue }
        case .null: return NSNull()
        }
    }

    static func fromJSONData(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: object)
    }

    static func fromJSONString(_ string: String) -> JSONValue {
        guard let data = string.data(using: .utf8),
              let value = try? fromJSONData(data) else {
            return .string(string)
        }
        return value
    }

    func toJSONData() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])
    }

    /// Best-effort plain-text rendering, used when a tool result needs to be shown as text
    /// (e.g. in `tool_result` content or in the chat transcript).
    var asDisplayText: String {
        switch self {
        case .string(let v): return v
        default:
            guard let data = try? toJSONData(), let s = String(data: data, encoding: .utf8) else {
                return "\(anyValue)"
            }
            return s
        }
    }
}
