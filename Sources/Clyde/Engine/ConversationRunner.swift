import Foundation

/// Drives one full turn of conversation against an `LLMBackend`, transparently executing any
/// MCP tool calls the model makes and looping until it produces a final answer. Shared by
/// `ChatViewModel` (user-driven chat) and `ProactiveAnalyzer` (background meeting analysis) so
/// the tool-use round-trip is implemented exactly once.
///
/// Per Anthropic's guidance, every tool_use block from one assistant turn gets its tool_result
/// returned in a single following user message (not split across messages) — splitting them
/// degrades the model's parallel-tool-call behavior.
///
/// Tool rounds are capped (`maxToolRounds`). Without a cap a model that keeps "just checking one
/// more source" can loop for dozens of rounds (observed: ~40 rounds / several minutes for a
/// one-line chat question). When the budget is spent, the tool results go back with an
/// instruction to answer now; any further tool calls in that final turn are ignored. Tools stay
/// declared on that last request because both backends reject tool_use/functionCall history
/// when no tools are defined.
struct ConversationRunner: Sendable {
    let llm: any LLMBackend
    let mcp: MCPManager

    static let budgetExhaustedInstruction = """
    Tool budget reached. Do not call any more tools. Answer the user's question now using only \
    what you already have; if something is still unknown, say so briefly.
    """

    func run(
        system: String,
        messages initialMessages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions,
        maxToolRounds: Int = 8,
        onTextDelta: @Sendable @escaping (String) -> Void
    ) async throws -> [LLMMessage] {
        var messages = initialMessages
        var round = 0
        let started = Date()

        while true {
            let finalRound = round >= maxToolRounds
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

            if finalRound {
                // Drop any tool calls the model still made; keep only its text.
                if text.isEmpty {
                    let fallback = "I couldn't find that quickly enough. Try asking more specifically."
                    text = fallback
                    onTextDelta(fallback)
                }
                messages.append(LLMMessage(role: .assistant, content: [.text(text)]))
                let elapsed = Date().timeIntervalSince(started)
                Log.llm.info("Tool loop hit budget (\(maxToolRounds, privacy: .public) rounds) after \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
                return messages
            }

            var assistantContent: [LLMMessage.Content] = []
            if !text.isEmpty { assistantContent.append(.text(text)) }
            for call in toolCalls { assistantContent.append(.toolUse(call)) }
            if !assistantContent.isEmpty {
                messages.append(LLMMessage(role: .assistant, content: assistantContent))
            }

            guard stopReason == "tool_use", !toolCalls.isEmpty else {
                let elapsed = Date().timeIntervalSince(started)
                Log.llm.info("Turn finished after \(round, privacy: .public) tool rounds in \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
                return messages
            }

            round += 1
            let names = toolCalls.map(\.name).joined(separator: ", ")
            Log.llm.info("Tool round \(round, privacy: .public)/\(maxToolRounds, privacy: .public): \(names, privacy: .public)")

            // Run this round's tool calls in parallel, keeping results in call order.
            let mcp = self.mcp
            let results = await withTaskGroup(of: (Int, LLMToolResult).self) { group in
                for (index, call) in toolCalls.enumerated() {
                    group.addTask {
                        (index, await mcp.callTool(toolUseID: call.id, qualifiedName: call.name, arguments: call.input))
                    }
                }
                var collected: [(Int, LLMToolResult)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            var resultContent: [LLMMessage.Content] = results.map { .toolResult($0) }
            if round >= maxToolRounds {
                resultContent.append(.text(Self.budgetExhaustedInstruction))
            }
            messages.append(LLMMessage(role: .user, content: resultContent))
        }
    }
}
