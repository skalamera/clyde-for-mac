import CoreGraphics
import Foundation
import MCP
import Synchronization
@testable import Clyde

// Shared fakes for the regression tests. Nothing here touches the network, the real screen,
// the microphone, or the user's LLM keys: the LLM is scripted, MCP servers run in-process over
// `InMemoryTransport`, and ScreenWatcher gets an injected Environment.

/// Polls `condition` until it holds or `timeout` elapses. Returns whether it held.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// A one-shot latch: callers of `pass()` suspend until `open()`; `arrivals` counts callers.
actor Gate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A solid grayscale image; different `gray` values are a "meaningful change" to ScreenWatcher.
func solidImage(gray: UInt8, width: Int = 320, height: Int = 180) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    ctx.setFillColor(gray: CGFloat(gray) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Mutable stand-in for the system state ScreenWatcher reads (frontmost app, clock, screen).
@MainActor
final class FakeScreenSystem {
    var frontmostBundleID: String? = "com.apple.Safari"
    var frontmostName: String? = "Safari"
    var image: CGImage = solidImage(gray: 40)
    var now: Date = Date()
    /// Runs inside the capture call, before it returns (simulates work during the capture awaits).
    var duringCapture: (@MainActor () async -> Void)?
    var captureCount = 0

    func environment(recognizeText: @escaping @Sendable (CGImage) async -> String = { _ in "screen text" }) -> ScreenWatcher.Environment {
        ScreenWatcher.Environment(
            isEnabled: { true },
            ensureCaptureAccess: {},
            frontmostApp: { [unowned self] in (self.frontmostBundleID, self.frontmostName) },
            captureDisplayUnderMouse: { [unowned self] _ in
                self.captureCount += 1
                if let duringCapture = self.duringCapture { await duringCapture() }
                return self.image
            },
            recognizeText: recognizeText,
            now: { [unowned self] in self.now },
            pollInterval: .milliseconds(5)
        )
    }
}

/// Scripted LLM backend: each `stream` call replays the next scripted turn and records what
/// it was sent. Never touches the network.
final class ScriptedLLM: ModelRoutingBackend, @unchecked Sendable {
    struct Call {
        var system: String
        var messages: [LLMMessage]
        var tools: [LLMTool]
    }

    private let state: Mutex<(turns: [[LLMStreamEvent]], calls: [Call])>

    init(turns: [[LLMStreamEvent]]) {
        state = Mutex((turns, []))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func effectiveModel(for purpose: ModelPurpose) -> String { "scripted-model" }

    func stream(system: String, messages: [LLMMessage], tools: [LLMTool], model: String, options: LLMRequestOptions) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let events: [LLMStreamEvent] = state.withLock { s in
            s.calls.append(Call(system: system, messages: messages, tools: tools))
            if s.turns.isEmpty { return [.textDelta("done"), .messageComplete(stopReason: "end_turn")] }
            return s.turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    static func toolTurn(_ calls: [(id: String, name: String)]) -> [LLMStreamEvent] {
        calls.map { .toolCall(LLMToolCall(id: $0.id, name: $0.name, input: .object([:]))) }
            + [.messageComplete(stopReason: "tool_use")]
    }
}

/// Records how many calls of each tool are running at once, and which tools ran at all.
final class ToolCallRecorder: @unchecked Sendable {
    private let state = Mutex<(running: [String: Int], maxRunning: [String: Int], totalRunning: Int, maxTotal: Int, invoked: [String])>(([:], [:], 0, 0, []))

    func begin(server: String, tool: String) {
        state.withLock { s in
            s.running[server, default: 0] += 1
            s.maxRunning[server] = max(s.maxRunning[server] ?? 0, s.running[server]!)
            s.totalRunning += 1
            s.maxTotal = max(s.maxTotal, s.totalRunning)
            s.invoked.append("\(server)__\(tool)")
        }
    }

    func end(server: String) {
        state.withLock { s in
            s.running[server, default: 0] -= 1
            s.totalRunning -= 1
        }
    }

    func maxConcurrent(server: String) -> Int { state.withLock { $0.maxRunning[server] ?? 0 } }
    var maxConcurrentOverall: Int { state.withLock { $0.maxTotal } }
    var invoked: [String] { state.withLock { $0.invoked } }
}

/// Starts an in-process MCP server exposing `tools` and connects `manager` to it under `name`.
/// Every tool call sleeps `callDuration` so overlapping calls are observable.
func connectInProcessServer(
    _ manager: MCPManager, name: String, tools: [Tool], recorder: ToolCallRecorder,
    callDuration: Duration = .milliseconds(150)
) async throws -> Server {
    let server = Server(name: name, version: "1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
    await server.withMethodHandler(CallTool.self) { params in
        recorder.begin(server: name, tool: params.name)
        try? await Task.sleep(for: callDuration)
        recorder.end(server: name)
        return .init(content: [.text(text: "result of \(params.name)", annotations: nil, _meta: nil)], isError: false)
    }
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    try await manager.connect(
        MCPServerConfig(name: name, transport: .stdio, command: "in-process-test-server"),
        transport: clientTransport
    )
    return server
}

func emptySchema() -> Value { .object(["type": .string("object"), "properties": .object([:])]) }
