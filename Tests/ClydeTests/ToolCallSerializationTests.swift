import Foundation
import MCP
import Testing
@testable import Clyde

/// CRIT-42: one MCP server's calls share one HTTPClientTransport/OAuthAuthorizer, whose 401 and
/// refresh handling breaks when two calls are in flight at once (the second starts an
/// interactive browser login). Calls to one server must run one at a time; different servers
/// still run in parallel. Servers here are in-process (InMemoryTransport); nothing hits a network.
@Suite(.serialized) struct ToolCallSerializationTests {
    static let tools = [
        Tool(name: "search", description: "search", inputSchema: emptySchema()),
        Tool(name: "lookup", description: "lookup", inputSchema: emptySchema()),
    ]

    @Test func callsToOneServerInOneRoundRunOneAtATime() async throws {
        let mcp = MCPManager()
        let recorder = ToolCallRecorder()
        _ = try await connectInProcessServer(mcp, name: "alpha", tools: Self.tools, recorder: recorder)
        _ = try await connectInProcessServer(mcp, name: "beta", tools: Self.tools, recorder: recorder)

        let llm = ScriptedLLM(turns: [
            ScriptedLLM.toolTurn([("1", "alpha__search"), ("2", "alpha__lookup"), ("3", "beta__search")]),
            [.textDelta("answer"), .messageComplete(stopReason: "end_turn")],
        ])
        let runner = ConversationRunner(llm: llm, mcp: mcp)
        let messages = try await runner.run(
            system: "", messages: [.user("q")], tools: await mcp.allTools, model: "m", options: .chat,
            maxToolRounds: 3, onTextDelta: { _ in }
        )

        #expect(recorder.maxConcurrent(server: "alpha") == 1, "two calls to the same server overlapped")
        #expect(recorder.maxConcurrentOverall >= 2, "different servers should still run in parallel")

        // Results still come back in call order, each paired with its own call.
        let resultTurn = try #require(messages.first { m in m.content.contains { if case .toolResult = $0 { return true } else { return false } } })
        let results = resultTurn.content.compactMap { c -> LLMToolResult? in if case .toolResult(let r) = c { return r } else { return nil } }
        #expect(results.map(\.toolUseID) == ["1", "2", "3"])
        #expect(results.map(\.content) == ["result of search", "result of lookup", "result of search"])
    }

    @Test func concurrentConversationsShareOneQueuePerServer() async throws {
        // Chat and a proactive pass can run at the same time against the same server.
        let mcp = MCPManager()
        let recorder = ToolCallRecorder()
        _ = try await connectInProcessServer(mcp, name: "alpha", tools: Self.tools, recorder: recorder)

        async let a = mcp.callTool(toolUseID: "a", qualifiedName: "alpha__search", arguments: .object([:]))
        async let b = mcp.callTool(toolUseID: "b", qualifiedName: "alpha__lookup", arguments: .object([:]))
        let (ra, rb) = await (a, b)

        #expect(!ra.isError && !rb.isError)
        #expect(recorder.maxConcurrent(server: "alpha") == 1)
    }
}
