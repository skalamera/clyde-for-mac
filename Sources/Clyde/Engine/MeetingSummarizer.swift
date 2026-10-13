import Foundation

/// Generates a structured `MeetingNote` from a finished meeting's transcript via the active LLM
/// backend (Gemini/Anthropic/CLI, whichever `LLMRouter` currently prefers) — a single one-shot
/// request, no MCP tools, since summarizing what was already said doesn't need external lookups.
struct MeetingSummarizer {
    let router: LLMRouter

    func summarize(transcript: String, startedAt: Date, endedAt: Date, userContext: String = "") async throws -> MeetingNote {
        var text = ""
        let userMessage = userContext.isEmpty
            ? transcript
            : "Background the user provided about this meeting before it started:\n\(userContext)\n\n--- TRANSCRIPT ---\n\(transcript)"
        let stream = router.stream(
            system: Self.systemPrompt,
            messages: [.user(userMessage)],
            tools: [],
            model: router.effectiveModel(for: .chat),
            options: .chat
        )
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
        }

        let parsed = Self.parse(text)
        return MeetingNote(
            startedAt: startedAt,
            endedAt: endedAt,
            title: parsed?.title ?? "Meeting on \(Self.dateFormatter.string(from: startedAt))",
            summary: parsed?.summary ?? text.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: parsed?.keyPoints ?? [],
            actionItems: parsed?.actionItems ?? [],
            transcript: transcript
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let systemPrompt = """
    You are Clyde's post-meeting summary generator. You are given the full transcript of a \
    meeting that just ended, attributed as "You" (the user) and named or numbered speakers \
    ("Gina", "Speaker 2", or "Them" when unattributed) for everyone else on the call — possibly \
    preceded by background the user typed in before the meeting started (who's involved, what \
    it's about). Use that background to interpret the transcript correctly rather \
    than guessing, but it describes context, not something that was said — don't quote it back \
    as if it were part of the conversation. Produce a clear, complete summary a busy person could \
    read in 15 seconds and still know what happened and what they need to do next.

    Respond with EXACTLY one JSON object, no other text, no markdown code fences:
    {
      "title": "<=8 words, specific to what this meeting was actually about",
      "summary": "2-5 sentences: what was discussed, what was decided, how it ended",
      "keyPoints": ["short bullet of a notable point or decision", "..."],
      "actionItems": [{"description": "concrete, specific task", "owner": "you" | "them" | "unclear"}]
    }

    If nothing substantive was discussed, keep the summary honest and brief rather than padding \
    it. If there are no clear action items, return an empty array — never invent one.
    """

    private struct Parsed {
        var title: String?
        var summary: String?
        var keyPoints: [String]
        var actionItems: [ActionItem]
    }

    private static func parse(_ rawText: String) -> Parsed? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let keyPoints = (json["keyPoints"] as? [String]) ?? []
        let actionItems = ((json["actionItems"] as? [[String: Any]]) ?? []).compactMap { item -> ActionItem? in
            guard let description = item["description"] as? String, !description.isEmpty else { return nil }
            return ActionItem(description: description, owner: item["owner"] as? String)
        }
        return Parsed(
            title: json["title"] as? String,
            summary: json["summary"] as? String,
            keyPoints: keyPoints,
            actionItems: actionItems
        )
    }
}
