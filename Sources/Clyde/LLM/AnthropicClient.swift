import Foundation

/// Direct client for the Anthropic Messages API (`POST /v1/messages`, streamed via SSE). There
/// is no official Anthropic Swift SDK, so this is a small hand-rolled client over
/// `URLSession.bytes` rather than a community dependency whose model constants tend to lag the
/// current lineup — model IDs are passed through as plain strings from `Settings`.
///
/// Streaming event handling follows the documented SSE sequence:
///   message_start → { content_block_start, content_block_delta*, content_block_stop } →
///   message_delta (carries stop_reason) → message_stop, with `ping` and possible `error`
///   events interleaved. `input_json_delta.partial_json` arrives in fragments and must be
///   accumulated per content-block index, then parsed once `content_block_stop` closes that
///   block — trying to parse it incrementally will fail on every delta but the last.
final class AnthropicClient: LLMBackend, @unchecked Sendable {
    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession

    init(apiKeyProvider: @escaping @Sendable () -> String? = { Settings.shared.anthropicAPIKey }) {
        self.apiKeyProvider = apiKeyProvider
        let configuration = URLSessionConfiguration.default
        // Streaming responses can have long gaps between chunks while the model is "thinking"
        // or generating tool-call JSON; a short request timeout would abort a healthy stream.
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

                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try Self.encodeBody(
                        system: system, messages: messages, tools: tools, model: model, options: options
                    )

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.decoding("No HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(http.statusCode, body)
                    }

                    var parser = SSEStreamParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeBody(
        system: String, messages: [LLMMessage], tools: [LLMTool], model: String, options: LLMRequestOptions
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens,
            "stream": true,
            // Cache the (usually large, slow-changing) system prompt + tool definitions.
            // Below the model's minimum cacheable-prefix length this is simply a no-op.
            "system": [
                ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
            ] as [Any]
        ]

        body["messages"] = messages.map(encodeMessage)

        if !tools.isEmpty {
            // Sorted so the tool list — which sits at the front of the cached prefix — stays
            // byte-stable across turns; any reordering would invalidate the whole cache.
            body["tools"] = tools.sorted { $0.name < $1.name }.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.anyValue
                ]
            }
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        var blocks: [[String: Any]] = []
        for content in message.content {
            switch content {
            case .text(let text):
                blocks.append(["type": "text", "text": text])
            case .toolUse(let call):
                blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.input.anyValue])
            case .toolResult(let result):
                blocks.append([
                    "type": "tool_result",
                    "tool_use_id": result.toolUseID,
                    "content": result.content,
                    "is_error": result.isError
                ])
            case .image(let data, let mimeType):
                blocks.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": mimeType, "data": data.base64EncodedString()]
                ])
            }
        }
        return ["role": message.role.rawValue, "content": blocks]
    }
}

/// Accumulates Anthropic's per-content-block SSE deltas into `LLMStreamEvent`s. Kept separate
/// from networking so it can be unit-tested against captured event logs without a live request.
struct SSEStreamParser {
    private enum BlockKind { case text, toolUse(id: String, name: String) }
    private var blockKinds: [Int: BlockKind] = [:]
    private var partialJSON: [Int: String] = [:]
    private var dataBuffer = ""

    /// Feed one line of the SSE body. Returns a decoded event if this line completed one
    /// (multiple lines are often needed to reach a `data:` line that parses to something we care
    /// about); returns nil for blank lines, `event:` lines, and events we deliberately ignore
    /// (`ping`, unrecognized types — future-proofing against new event types).
    mutating func consume(line: String) -> LLMStreamEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "content_block_start":
            guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return nil }
            if blockType == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                blockKinds[index] = .toolUse(id: id, name: name)
                partialJSON[index] = ""
            } else {
                blockKinds[index] = .text
            }
            return nil

        case "content_block_delta":
            guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return nil }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String else { return nil }
                return .textDelta(text)
            case "input_json_delta":
                guard let fragment = delta["partial_json"] as? String else { return nil }
                partialJSON[index, default: ""] += fragment
                return nil
            default:
                return nil // thinking_delta / signature_delta: not surfaced to callers yet.
            }

        case "content_block_stop":
            guard let index = json["index"] as? Int, case .toolUse(let id, let name)? = blockKinds[index] else {
                return nil
            }
            let jsonString = partialJSON[index] ?? ""
            let input: JSONValue = jsonString.isEmpty ? .object([:]) : .fromJSONString(jsonString)
            blockKinds[index] = nil
            partialJSON[index] = nil
            return .toolCall(LLMToolCall(id: id, name: name, input: input))

        case "message_delta":
            let stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return .messageComplete(stopReason: stopReason)

        case "message_stop":
            return nil // message_delta already carried the stop_reason we care about.

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            Log.llm.error("Anthropic stream error event: \(message, privacy: .public)")
            return nil

        default:
            return nil // ping, message_start, thinking-related types: nothing to surface.
        }
    }
}
