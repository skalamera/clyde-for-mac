import Foundation

/// Generates a pre-meeting briefing for one calendar event, on demand from the Meetings tab's
/// "Prep" button. Unlike the summarizer (one-shot, no tools), prep runs the full MCP tool-use
/// loop: the model is expected to actively look up background — the customer/account behind
/// the external attendees' email domains, open support tickets, CRM state, recent calls,
/// project status — in the user's connected knowledge sources, and weave it together with the
/// meeting's own context (description/agenda when the feed provides one, and prior occurrences'
/// notes + action-item status for recurring meetings).
struct MeetingPrepGenerator {
    let router: LLMRouter
    let mcp: MCPManager

    func generate(event: CalendarEvent, priorNotes: [MeetingNote]) async throws -> String {
        let runner = ConversationRunner(llm: router, mcp: mcp)
        let tools = await mcp.allTools
        let messages = try await runner.run(
            system: Self.systemPrompt,
            messages: [.user(Self.userPrompt(event: event, priorNotes: priorNotes))],
            tools: tools,
            model: router.effectiveModel(for: .chat),
            options: .chat,
            onTextDelta: { _ in } // rendered once complete; not streamed token-by-token
        )
        guard let brief = Self.lastAssistantText(in: messages), !brief.isEmpty else {
            throw MeetingPrepError.emptyResponse
        }
        return brief
    }

    private static func lastAssistantText(in messages: [LLMMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            for content in message.content {
                if case .text(let text) = content { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return nil
        }
        return nil
    }

    private static func userPrompt(event: CalendarEvent, priorNotes: [MeetingNote]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        var sections: [String] = []
        var meeting = ["Title: \(event.title)", "When: \(dateFormatter.string(from: event.start))"]
        if let organizer = event.organizer { meeting.append("Organizer: \(organizer)") }
        let attendees = event.attendees.filter { !$0.isSelf }
        if !attendees.isEmpty {
            meeting.append("Attendees: " + attendees.map { attendee in
                (attendee.displayName.map { "\($0) <\(attendee.email)>" } ?? attendee.email)
                    + (attendee.responseStatus == "declined" ? " (declined)" : "")
            }.joined(separator: ", "))
        }
        if let description = event.description {
            meeting.append("Description/agenda:\n\(description)")
        }
        sections.append("MEETING:\n" + meeting.joined(separator: "\n"))

        if !priorNotes.isEmpty {
            let noteFormatter = DateFormatter()
            noteFormatter.dateStyle = .medium
            let noteSections = priorNotes.map { note -> String in
                var lines = ["[\(noteFormatter.string(from: note.startedAt))] \(note.title)", note.summary]
                if !note.keyPoints.isEmpty {
                    lines.append("Key points: " + note.keyPoints.joined(separator: " • "))
                }
                let open = note.actionItems.filter { !$0.completed }
                let done = note.actionItems.filter(\.completed)
                if !open.isEmpty {
                    lines.append("STILL OPEN action items: " + open.map { $0.description + ($0.owner.map { " (\($0))" } ?? "") }.joined(separator: "; "))
                }
                if !done.isEmpty {
                    lines.append("Completed action items: " + done.map(\.description).joined(separator: "; "))
                }
                return lines.joined(separator: "\n")
            }
            sections.append("PRIOR OCCURRENCES of this recurring meeting (oldest first):\n" + noteSections.joined(separator: "\n\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private static let systemPrompt = """
    You are Clyde's meeting-prep assistant. The user is about to join the meeting described \
    below and pressed "Prep" — produce a briefing they can absorb in under a minute.

    USE YOUR TOOLS. They connect to the user's real knowledge sources (internal company data, \
    CRM, customer success platform, support tickets, project tracker, docs, call recordings). \
    Identify who/what this meeting is about — external attendees' email domains usually name \
    the customer, and the title/description often names the account, project, or deal — then \
    look them up: account health and usage, open support tickets, recent call summaries, \
    active projects/tasks, anything a well-prepared person would want at hand. If lookups for \
    a name come up empty, say so in one line rather than padding.

    Respond in Markdown with short sections (use only the ones that apply):
    ## What this meeting is
    One or two sentences: purpose and who's involved (with their roles/company if known).
    ## Background
    The useful facts your tools found — status, numbers, open tickets, recent activity. \
    Be specific; cite which system a fact came from in parentheses.
    ## Last time / open threads
    Only for recurring meetings: what happened recently, which action items are STILL OPEN \
    (call these out prominently — the user may be asked about them), which got done.
    ## Suggested focus
    2-4 bullets: questions worth asking or points worth raising, grounded in the above.

    Keep the whole thing tight — a briefing, not a report. No preamble, start directly with \
    the first section header.
    """
}

enum MeetingPrepError: Error, LocalizedError {
    case emptyResponse
    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The model returned an empty briefing."
        }
    }
}
