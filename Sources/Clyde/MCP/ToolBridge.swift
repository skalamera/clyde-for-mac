import Foundation
import MCP

/// Converts between this app's `JSONValue` (used for Anthropic tool schemas/inputs) and the MCP
/// Swift SDK's own `Value` JSON representation, and between an MCP `Tool` and the `LLMTool`
/// shape the Anthropic client expects.
enum ToolBridge {
    /// Anthropic tool names are restricted to `[A-Za-z0-9_-]`, ≤64 chars. MCP tool names are
    /// namespaced by server (`server__tool`) so multiple servers can expose a tool with the same
    /// short name without colliding, and so a returned tool_use call can be routed back to the
    /// right MCP client.
    static func qualifiedName(server: String, tool: String) -> String {
        let sanitize: (String) -> String = { raw in
            String(raw.unicodeScalars.map { scalar in
                (CharacterSet(charactersIn: "A-Za-z0-9_-").contains(scalar) || scalar.properties.isAlphabetic || scalar.isASCII && (scalar.value >= 48 && scalar.value <= 57))
                    ? Character(scalar) : "_"
            })
        }
        let name = sanitize(server) + "__" + sanitize(tool)
        return String(name.prefix(64))
    }

    /// Splits a qualified name back into (server, tool). Assumes the server portion itself
    /// contains no "__" — true for the server keys we generate in MCPConfig.
    static func split(qualifiedName: String) -> (server: String, tool: String)? {
        guard let range = qualifiedName.range(of: "__") else { return nil }
        let server = String(qualifiedName[qualifiedName.startIndex..<range.lowerBound])
        let tool = String(qualifiedName[range.upperBound...])
        return (server, tool)
    }

    static func llmTool(from tool: Tool, server: String) -> LLMTool {
        LLMTool(
            name: qualifiedName(server: server, tool: tool.name),
            description: tool.description ?? "",
            inputSchema: valueToJSON(tool.inputSchema)
        )
    }

    static func valueToJSON(_ value: Value) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .int(let v): return .number(Double(v))
        case .double(let v): return .number(v)
        case .string(let v): return .string(v)
        case .data(let mimeType, let data):
            // Tool schemas/results don't carry raw binary in practice; represent as base64 text
            // so nothing is silently dropped.
            return .string("data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())")
        case .array(let v): return .array(v.map(valueToJSON))
        case .object(let v): return .object(v.mapValues(valueToJSON))
        }
    }

    static func jsonToValue(_ json: JSONValue) -> Value {
        switch json {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .number(let v):
            if v == v.rounded(), abs(v) < Double(Int.max) { return .int(Int(v)) }
            return .double(v)
        case .string(let v): return .string(v)
        case .array(let v): return .array(v.map(jsonToValue))
        case .object(let v): return .object(v.mapValues(jsonToValue))
        }
    }

    /// Flattens an MCP tool-call result (which can mix text/image/audio/resource blocks) into
    /// the plain text `tool_result` content Anthropic expects.
    static func displayText(for content: [Tool.Content]) -> String {
        content.map { block -> String in
            switch block {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[image: \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[audio: \(mimeType)]"
            case .resource(let resource, _, _):
                return "[resource: \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[resource link: \(name) (\(uri))]"
            @unknown default:
                return "[unsupported content block]"
            }
        }.joined(separator: "\n")
    }
}
