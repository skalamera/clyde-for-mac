import Foundation

/// Client for Google's Gemini API (`generativelanguage.googleapis.com`), streamed via SSE —
/// an alternative primary backend to the direct Anthropic API, for users who'd rather bring a
/// Gemini key. Conforms to the same `LLMBackend` protocol as `AnthropicClient`, so everything
/// above it (ConversationRunner, ChatViewModel, ProactiveAnalyzer, the MCP tool-use loop) works
/// unchanged regardless of which backend is active.
///
/// Gemini's wire format differs from Anthropic's in three ways this client has to bridge:
///   - Roles are "user"/"model" (not "user"/"assistant").
///   - Tool calls have no ID — the model just emits a `functionCall` part with a name, and the
///     matching `functionResponse` is correlated by that same name (and, implicitly, position:
///     Gemini's own examples pair up function calls/responses in emission order). This app's
///     `LLMToolCall.id` is a required field, so for Gemini-sourced calls it's simply set to the
///     function name — `ConversationRunner` and `MCPManager` never interpret the id themselves,
///     they just thread it back to whichever backend produced it.
///   - Streaming chunks are full `candidates[0].content.parts[]` snapshots, not incremental
///     text/JSON deltas the way Anthropic's are — but each part's `text` still arrives
///     incrementally chunk-to-chunk, so forwarding each chunk's text as one `.textDelta` still
///     produces correct streamed output.
///
/// Tool schemas are passed through to `functionDeclarations[].parameters` best-effort. Gemini's
/// schema dialect is a stricter subset of JSON Schema (no `$ref`, limited `additionalProperties`
/// support); a small minority of MCP tool schemas may be rejected by the API as a result — a
/// known limitation, not silently swallowed (the resulting HTTP error surfaces to the user).
final class GeminiClient: LLMBackend, @unchecked Sendable {
    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession

    init(apiKeyProvider: @escaping @Sendable () -> String? = { Settings.shared.geminiAPIKey }) {
        self.apiKeyProvider = apiKeyProvider
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        self.session = URLSession(configuration: configuration)
    }

    func stream(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = self.apiKeyProvider(), !apiKey.isEmpty else {
                        throw LLMError.notConfigured
                    }

                    var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
                    components.queryItems = [
                        URLQueryItem(name: "alt", value: "sse"),
                        URLQueryItem(name: "key", value: apiKey)
                    ]

                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try Self.encodeBody(system: system, messages: messages, tools: tools, options: options)

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.decoding("No HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(http.statusCode, Self.extractErrorMessage(from: body) ?? body)
                    }

                    var sawToolCall = false
                    var finalStopReason: String?

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let first = candidates.first else { continue }

                        if let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                            for part in parts {
                                if let text = part["text"] as? String {
                                    continuation.yield(.textDelta(text))
                                } else if let functionCall = part["functionCall"] as? [String: Any],
                                          let name = functionCall["name"] as? String {
                                    sawToolCall = true
                                    let args = functionCall["args"] as? [String: Any] ?? [:]
                                    // `thoughtSignature` lives on the part itself, alongside
                                    // `functionCall` — not inside it — and must be echoed back
                                    // verbatim when this assistant turn is replayed later.
                                    let thoughtSignature = part["thoughtSignature"] as? String
                                    continuation.yield(.toolCall(LLMToolCall(id: name, name: name, input: JSONValue(any: args), thoughtSignature: thoughtSignature)))
                                }
                            }
                        }

                        if let finishReason = first["finishReason"] as? String {
                            finalStopReason = finishReason
                        }
                    }

                    // Gemini's own finishReason vocabulary ("STOP", "MAX_TOKENS", ...) doesn't
                    // include a tool-call marker the way Anthropic's stop_reason does — a turn
                    // that emitted function calls can still report finishReason "STOP". Map to
                    // the "tool_use" sentinel ConversationRunner already understands whenever
                    // any functionCall part was seen this turn, regardless of finishReason.
                    let stopReason = sawToolCall ? "tool_use" : (finalStopReason ?? "end_turn")
                    continuation.yield(.messageComplete(stopReason: stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeBody(system: String, messages: [LLMMessage], tools: [LLMTool], options: LLMRequestOptions) throws -> Data {
        var body: [String: Any] = [
            "contents": messages.map(encodeMessage),
            "generationConfig": ["maxOutputTokens": options.maxTokens]
        ]
        if !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        if !tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": tools.sorted { $0.name < $1.name }.map { tool in
                    ["name": tool.name, "description": tool.description, "parameters": sanitizeSchema(tool.inputSchema).anyValue]
                }
            ]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Gemini's function-calling schema (`google.genai.types.Schema`) accepts only a fixed,
    /// documented set of fields — anything else in the request is an HTTP 400 for the *entire*
    /// request, not just the offending tool. MCP tool schemas are arbitrary JSON Schema (often
    /// generated by zod-to-json-schema or similar) and routinely include keywords outside that
    /// set (`additionalProperties`, `exclusiveMinimum`, `$schema`, ...) — denying known-bad
    /// keywords one at a time means every new one is a fresh outage, so this instead allows only
    /// the fields Gemini's Schema type actually defines and drops everything else.
    private static let allowedSchemaKeys: Set<String> = [
        "type", "format", "title", "description", "nullable", "enum",
        "maxItems", "minItems", "properties", "propertyOrdering", "required", "items",
        "minimum", "maximum", "minLength", "maxLength", "minProperties", "maxProperties",
        "anyOf", "default", "example", "pattern"
    ]

    private static func sanitizeSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let dict):
            var cleaned: [String: JSONValue] = [:]
            for (key, v) in dict where allowedSchemaKeys.contains(key) {
                switch key {
                case "properties":
                    // `properties` is a name -> schema map, not a schema: keep every property
                    // name and sanitize each value (filtering the names themselves against the
                    // schema-keyword allowlist silently dropped most properties).
                    if case .object(let props) = v {
                        cleaned[key] = .object(props.mapValues(sanitizeSchema))
                    }
                case "enum", "required", "propertyOrdering", "default", "example":
                    cleaned[key] = v
                case "type":
                    // JSON Schema allows `"type": ["string", "null"]`; Gemini's proto field is a
                    // single enum and 400s on a list. Collapse to the first non-null type and
                    // express the null as `nullable: true`.
                    if case .array(let types) = v {
                        let names = types.compactMap { t -> String? in
                            if case .string(let s) = t { return s }
                            return nil
                        }
                        if names.contains("null") { cleaned["nullable"] = .bool(true) }
                        if let first = names.first(where: { $0 != "null" }) {
                            cleaned[key] = .string(first)
                        }
                    } else {
                        cleaned[key] = v
                    }
                default:
                    cleaned[key] = sanitizeSchema(v)
                }
            }
            // Gemini cross-validates `required` against `properties`. Schemas whose property
            // definitions lived inside stripped constructs (`allOf`, `additionalProperties`, ...)
            // can be left with `required` names that no longer resolve — prune those, or the
            // whole request 400s with "required[N]: property is not defined".
            if case .array(let required)? = cleaned["required"] {
                let defined: Set<String>
                if case .object(let properties)? = cleaned["properties"] {
                    defined = Set(properties.keys)
                } else {
                    defined = []
                }
                let kept = required.filter {
                    if case .string(let name) = $0 { return defined.contains(name) }
                    return false
                }
                if kept.isEmpty {
                    cleaned.removeValue(forKey: "required")
                } else {
                    cleaned["required"] = .array(kept)
                }
            }
            return .object(cleaned)
        case .array(let items):
            return .array(items.map(sanitizeSchema))
        default:
            return value
        }
    }

    private static func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        var parts: [[String: Any]] = []
        for content in message.content {
            switch content {
            case .text(let text):
                parts.append(["text": text])
            case .toolUse(let call):
                // `thoughtSignature` is a sibling field on the part, not nested inside
                // `functionCall` — required by the API when replaying a prior functionCall turn,
                // or Gemini rejects the request (see LLMToolCall.thoughtSignature).
                var part: [String: Any] = ["functionCall": ["name": call.name, "args": call.input.anyValue]]
                if let thoughtSignature = call.thoughtSignature {
                    part["thoughtSignature"] = thoughtSignature
                }
                parts.append(part)
            case .toolResult(let result):
                parts.append([
                    "functionResponse": [
                        "name": result.toolUseID,
                        "response": ["result": result.content, "isError": result.isError]
                    ]
                ])
            }
        }
        // Gemini has no separate "tool" role: both our .toolUse (assistant-authored) and
        // .toolResult (fed back to the model) content travel as "user"/"model" turns, matching
        // whatever role the surrounding LLMMessage already carries.
        let role = message.role == .assistant ? "model" : "user"
        return ["role": role, "parts": parts]
    }

    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
