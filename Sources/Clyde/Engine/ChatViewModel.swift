import Foundation
import Observation

/// Backs the chat panel in the overlay: the user's own questions, answered with the live
/// meeting transcript (and any connected MCP tools) as context. Uses `ConversationRunner` so a
/// question like "can you check our Q3 numbers against what they just said" transparently
/// round-trips through MCP tools before answering.
@MainActor
@Observable
final class ChatViewModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var lastErrorDescription: String?

    private let meetingContext: MeetingContext
    private let mcp: MCPManager
    private let runner: ConversationRunner

    /// Full LLM-facing history, kept in parallel to `messages` (which is what the UI renders).
    /// Includes the tool_use/tool_result round-trip turns that the chat bubbles collapse away.
    private var history: [LLMMessage] = []

    private let router: LLMRouter

    init(meetingContext: MeetingContext, llm: LLMRouter, mcp: MCPManager) {
        self.meetingContext = meetingContext
        self.mcp = mcp
        self.router = llm
        self.runner = ConversationRunner(llm: llm, mcp: mcp)
    }

    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastErrorDescription = nil

        messages.append(ChatMessage(role: .user, text: text))
        history.append(.user(text))

        let assistantIndex = messages.count
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        isResponding = true
        defer { isResponding = false }

        do {
            let tools = await mcp.allTools
            let system = Self.systemPrompt(
                transcript: meetingContext.finalizedTranscriptText,
                priorMeetingContext: meetingContext.priorMeetingContext,
                userProvidedContext: meetingContext.userProvidedContext
            )
            let updatedHistory = try await runner.run(
                system: system,
                messages: history,
                tools: tools,
                model: router.effectiveModel(for: .chat),
                options: .chat,
                // Mid-meeting questions need answers in seconds, not minutes.
                maxToolRounds: 3,
                onTextDelta: { [weak self] delta in
                    Task { @MainActor in
                        guard let self, assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].text += delta
                    }
                }
            )
            history = updatedHistory
            if assistantIndex < messages.count {
                messages[assistantIndex].isStreaming = false
            }
        } catch {
            lastErrorDescription = error.localizedDescription
            if assistantIndex < messages.count {
                messages[assistantIndex].text = "⚠️ \(error.localizedDescription)"
                messages[assistantIndex].isStreaming = false
            }
            Log.llm.error("Chat turn failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        messages.removeAll()
        history.removeAll()
    }

    private static func systemPrompt(transcript: String, priorMeetingContext: String, userProvidedContext: String) -> String {
        """
        You are Clyde, a live meeting copilot embedded in a translucent overlay only the current \
        user can see — the other meeting participants never see this window, even if the user is \
        sharing their screen. You are chatting privately with that user during their meeting.

        You have access to the live transcript below, attributed as "You" (the user) and "Them" \
        (everyone else on the call). Use it as ground truth for what has been said. If the \
        transcript doesn't cover what's being asked, say so rather than guessing. Be concise — \
        the user is in the middle of a live conversation and needs quick, scannable answers, not \
        essays. Speed matters more than completeness: answer from the transcript and context \
        below when they cover it. If you need tools, make one or two targeted lookups (run \
        independent lookups in parallel in the same turn), then answer. Never keep searching \
        across sources for marginal extra detail; a short answer now beats a perfect one later.
        \(userProvidedContext.isEmpty ? "" : "\nThe user told you this about the meeting before it started — treat it as reliable background, not something said in the meeting itself:\n\(userProvidedContext)\n")
        \(priorMeetingContext.isEmpty ? "" : "\n" + priorMeetingContext + "\n")
        --- LIVE TRANSCRIPT ---
        \(transcript.isEmpty ? "(nothing transcribed yet)" : transcript)
        --- END TRANSCRIPT ---
        """
    }
}
