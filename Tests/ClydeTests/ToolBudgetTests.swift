import Foundation
import MCP
import Testing
@testable import Clyde

/// CRIT-45: when the tool budget runs out, the "answer now" instruction must not be added as a
/// text part next to the tool results. Gemini requires the turn after a functionCall turn to be
/// functionResponse parts only, and 400s the whole request otherwise.
@Suite struct ToolBudgetTests {
    @Test func budgetInstructionTravelsInsideTheToolResultTurn() async throws {
        let mcp = MCPManager()
        let recorder = ToolCallRecorder()
        _ = try await connectInProcessServer(mcp, name: "alpha", tools: [
            Tool(name: "search", description: "", inputSchema: emptySchema()),
            Tool(name: "lookup", description: "", inputSchema: emptySchema()),
        ], recorder: recorder, callDuration: .zero)
        let llm = ScriptedLLM(turns: [
            ScriptedLLM.toolTurn([("search", "alpha__search"), ("lookup", "alpha__lookup")]),
            [.textDelta("final answer"), .messageComplete(stopReason: "end_turn")],
        ])

        _ = try await ConversationRunner(llm: llm, mcp: mcp).run(
            system: "", messages: [.user("q")], tools: await mcp.allTools, model: "m", options: .chat,
            maxToolRounds: 1, onTextDelta: { _ in }
        )

        // The final (budget-exhausted) request.
        let finalRequest = try #require(llm.calls.last)
        let resultTurn = try #require(finalRequest.messages.last)
        #expect(resultTurn.role == .user)
        let onlyToolResults = resultTurn.content.allSatisfy { if case .toolResult = $0 { return true } else { return false } }
        #expect(onlyToolResults, "the tool-result turn must contain tool results only")
        #expect(resultTurn.content.count == 2, "one result per call")

        let instructionCarried = resultTurn.content.contains {
            if case .toolResult(let r) = $0 { return r.content.contains(ConversationRunner.budgetExhaustedInstruction) }
            return false
        }
        #expect(instructionCarried, "the model must still be told the budget is spent")

        // And as Gemini would see it: functionResponse parts only, one per functionCall.
        let parts = try #require(GeminiClient.encodeMessage(resultTurn)["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { $0["functionResponse"] != nil && $0["text"] == nil })
    }
}
