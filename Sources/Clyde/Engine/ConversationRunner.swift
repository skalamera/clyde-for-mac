import Foundation

/// Drives one full turn of conversation against an `LLMBackend`, transparently executing any
/// MCP tool calls the model makes and looping until it produces a final answer. Shared by
/// `ChatViewModel` (user-driven chat) and `ProactiveAnalyzer` (background meeting analysis) so
/// the tool-use round-trip is implemented exactly once.
///
/// Per Anthropic's guidance, every tool_use block from one assistant turn gets its tool_result
/// returned in a single following user message (not split across messages) — splitting them
/// degrades the model's parallel-tool-call behavior.
struct ConversationRunner: Sendable {
    let llm: any LLMBackend
    let mcp: MCPManager

    func run(
        system: String,
        messages initialMessages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions,
        onTextDelta: @Sendable @escaping (String) -> Void
    ) async throws -> [LLMMessage] {
        var messages = initialMessages

        while true {
            var text = ""
            var toolCalls: [LLMToolCall] = []
            var stopReason: String?

            let stream = llm.stream(system: system, messages: messages, tools: tools, model: model, options: options)
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    onTextDelta(delta)
                case .toolCall(let call):
                    toolCalls.append(call)
                case .messageComplete(let reason):
                    stopReason = reason
                }
            }

            var assistantContent: [LLMMessage.Content] = []
            if !text.isEmpty { assistantContent.append(.text(text)) }
            for call in toolCalls { assistantContent.append(.toolUse(call)) }
            if !assistantContent.isEmpty {
                messages.append(LLMMessage(role: .assistant, content: assistantContent))
            }

            guard stopReason == "tool_use", !toolCalls.isEmpty else {
                return messages
            }

            var resultContent: [LLMMessage.Content] = []
            for call in toolCalls {
                let result = await mcp.callTool(toolUseID: call.id, qualifiedName: call.name, arguments: call.input)
                resultContent.append(.toolResult(result))
            }
            messages.append(LLMMessage(role: .user, content: resultContent))
        }
    }
}
