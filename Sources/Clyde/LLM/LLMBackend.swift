import Foundation

/// A tool advertised to the LLM, sourced from an MCP server (see MCP/ToolBridge.swift) — the
/// app never defines its own tools directly, everything flows in through MCP.
struct LLMTool: Sendable, Equatable {
    var name: String
    var description: String
    var inputSchema: JSONValue
}

struct LLMToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var input: JSONValue

    /// Gemini-specific: an opaque, base64 "thought signature" some models attach to a
    /// functionCall part. It must be echoed back verbatim on the same part when that assistant
    /// turn is replayed in a later request, or the API rejects the request — see
    /// GeminiClient.swift. Anthropic ignores this field entirely; it only exists here because
    /// `LLMToolCall` is the one shared shape both backends round-trip through ConversationRunner.
    var thoughtSignature: String? = nil
}

struct LLMToolResult: Sendable, Equatable {
    var toolUseID: String
    var content: String
    var isError: Bool
}

enum LLMRole: String, Sendable, Equatable {
    case user
    case assistant
}

struct LLMMessage: Sendable {
    enum Content: Sendable {
        case text(String)
        case toolUse(LLMToolCall)
        case toolResult(LLMToolResult)
    }
    var role: LLMRole
    var content: [Content]

    static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, content: [.text(text)]) }
    static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: .assistant, content: [.text(text)]) }
}

enum LLMStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(LLMToolCall)
    /// Sent once, at the end of the stream. `stopReason == "tool_use"` means the caller should
    /// execute the tool calls already emitted and send their results back in a follow-up turn.
    case messageComplete(stopReason: String?)
}

/// How hard/expensive a single turn should be. Not every backend honors every knob (e.g. the
/// Claude Code CLI fallback doesn't expose per-request effort control), so this is best-effort.
struct LLMRequestOptions: Sendable {
    var maxTokens: Int = 1024
    var enableThinking: Bool = false

    static let proactive = LLMRequestOptions(maxTokens: 1024, enableThinking: false)
    static let chat = LLMRequestOptions(maxTokens: 4096, enableThinking: false)
    /// Transcript refinement rewrites its input in full, so the output cap must comfortably
    /// exceed the per-chunk input size (see TranscriptRefiner.chunkCharacterLimit).
    static let refinement = LLMRequestOptions(maxTokens: 16384, enableThinking: false)
}

/// Abstraction over "something that can turn (system prompt, conversation, tools) into a
/// streamed reply", so the app can prefer the direct Anthropic API but fall back to a locally
/// installed, already-authenticated Claude Code CLI when no API key is configured.
protocol LLMBackend: Sendable {
    func stream(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

enum LLMError: Error, CustomStringConvertible, LocalizedError {
    case notConfigured
    case http(Int, String)
    case decoding(String)
    case cliUnavailable(String)

    // Without this, `.localizedDescription` (which is what every catch block in this app logs
    // and displays) ignores `description` below entirely and falls back to Foundation's generic
    // "The operation couldn't be completed (Domain error N.)" — useless for debugging. Every
    // error type in this app must conform to `LocalizedError`, not just `CustomStringConvertible`.
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notConfigured: return "No LLM backend is configured."
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let reason): return "Failed to decode response: \(reason)"
        case .cliUnavailable(let reason): return "Claude Code CLI unavailable: \(reason)"
        }
    }
}
