import Foundation
import Observation

/// Watches the live transcript and, without being asked, surfaces answers, clarifications, and
/// fact-checks as `Suggestion` cards. Runs on a debounced loop against the fast/cheap model
/// (`claude-haiku-4-5` by default) so it doesn't compete on latency or cost with user-initiated
/// chat, and stays out of the way rather than firing on every single utterance.
///
/// Non-intrusiveness is enforced by two independent throttles: a minimum wall-clock interval
/// between analysis passes, AND a minimum amount of fresh transcript before a pass runs at all.
/// The model itself is also instructed to respond "NONE" when nothing is worth surfacing, and
/// that response is silently dropped rather than shown as an empty/low-value card.
@MainActor
@Observable
final class ProactiveAnalyzer {
    private(set) var suggestions: [Suggestion] = []
    private(set) var isEnabled: Bool = Settings.shared.proactiveEnabled {
        didSet { Settings.shared.proactiveEnabled = isEnabled }
    }
    /// True while a user-triggered nudge request is in flight — lets the button show a spinner
    /// and ignore repeated clicks instead of firing overlapping requests.
    private(set) var isNudging = false

    /// Set when a nudge completed without producing a card (model declined or errored), so the
    /// UI can say so instead of the button appearing to silently do nothing. Cleared when the
    /// next nudge starts.
    private(set) var lastNudgeProducedNothing = false

    private let meetingContext: MeetingContext
    private let mcp: MCPManager
    private let runner: ConversationRunner
    private let router: LLMRouter
    private var loopTask: Task<Void, Never>?

    private let minimumInterval: TimeInterval = 8
    private let minimumNewCharacters = 25
    private let pollInterval: TimeInterval = 3

    private let screen: ScreenWatcher
    /// Screen changes must sit still this long before triggering a pass, so a page that's
    /// still loading/animating is captured once settled rather than mid-transition.
    private let screenSettleInterval: TimeInterval = 1.5

    init(meetingContext: MeetingContext, llm: LLMRouter, mcp: MCPManager, screen: ScreenWatcher) {
        self.screen = screen
        self.meetingContext = meetingContext
        self.mcp = mcp
        self.router = llm
        self.runner = ConversationRunner(llm: llm, mcp: mcp)
    }

    func clear() {
        suggestions.removeAll()
    }

    func dismiss(id: Suggestion.ID) {
        suggestions.removeAll { $0.id == id }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            var lastRunAt: Date = .distantPast
            var lastScreenGeneration = await self.screen.changeGeneration
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollInterval))
                guard await self.isEnabled else { continue }
                guard Date().timeIntervalSince(lastRunAt) >= self.minimumInterval else { continue }

                // A pass runs on enough new speech OR a settled, meaningful screen change
                // (e.g. an error dialog appearing while nobody is talking).
                let generation = await self.screen.changeGeneration
                let lastChangeAt = await self.screen.lastChangeAt
                let screenChanged = generation != lastScreenGeneration
                    && Date().timeIntervalSince(lastChangeAt) >= self.screenSettleInterval
                let pending = await self.meetingContext.peekNewFinalizedCharacterCount()
                guard pending >= self.minimumNewCharacters || screenChanged else { continue }

                let newText = await self.meetingContext.consumeNewFinalizedText() ?? ""
                lastScreenGeneration = generation
                lastRunAt = Date()
                await self.analyze(newText: newText, screenChanged: screenChanged)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Manually triggered by the Live tab's "Nudge" button — the user is explicitly asking for
    /// help right now rather than Clyde deciding on its own, so this bypasses the periodic
    /// loop's throttling and "be conservative" framing entirely. Gives the model the full
    /// transcript for context, but is prompted to focus on the most recent turns, since that's
    /// almost always what the user actually wants a reaction to.
    func nudge() async {
        guard !isNudging else { return }
        let fullTranscript = meetingContext.finalizedTranscriptText
        guard !fullTranscript.isEmpty || screen.latest != nil else { return }
        let recentTranscript = Self.recentTail(of: fullTranscript)

        isNudging = true
        lastNudgeProducedNothing = false
        defer { isNudging = false }
        let countBefore = suggestions.count
        await performAnalysis(
            system: Self.nudgeSystemPrompt,
            userMessage: Self.nudgeUserPrompt(
                fullTranscript: fullTranscript, recentTranscript: recentTranscript,
                contextPreamble: Self.contextPreamble(meetingContext: meetingContext)
            ),
            screen: screen.latest
        )
        lastNudgeProducedNothing = suggestions.count == countBefore
    }

    private func analyze(newText: String, screenChanged: Bool) async {
        // Include the recent transcript tail alongside the new chunk: a question often spans
        // chunks or leans on what was just said, and live STT garble is much easier to read
        // through with surrounding context.
        let recentContext = Self.recentTail(of: meetingContext.finalizedTranscriptText)
        await performAnalysis(
            system: Self.systemPrompt,
            userMessage: Self.userPrompt(
                recentTranscript: newText,
                recentContext: recentContext,
                contextPreamble: Self.contextPreamble(meetingContext: meetingContext),
                recentCards: suggestions.suffix(6).map(\.title),
                screenChanged: screenChanged
            ),
            screen: screen.latest
        )
    }

    /// Combines the "tell Clyde about this meeting" background and the prior-occurrences
    /// summary — whichever are non-empty — into one block to prepend to the user message.
    private static func contextPreamble(meetingContext: MeetingContext) -> String {
        var parts: [String] = []
        if !meetingContext.userProvidedContext.isEmpty {
            parts.append("Background the user provided about this meeting before it started:\n\(meetingContext.userProvidedContext)")
        }
        if !meetingContext.calendarEventContext.isEmpty {
            parts.append(meetingContext.calendarEventContext)
        }
        if !meetingContext.priorMeetingContext.isEmpty {
            parts.append(meetingContext.priorMeetingContext)
        }
        return parts.joined(separator: "\n\n")
    }

    private func performAnalysis(system: String, userMessage: String, screen snapshot: ScreenSnapshot?) async {
        do {
            let tools = await mcp.allTools
            let messages = try await runner.run(
                system: system + Self.screenInstructions,
                messages: [Self.userMessage(text: userMessage, screen: snapshot)],
                tools: tools,
                model: router.effectiveModel(for: .proactive),
                options: .proactive,
                onTextDelta: { _ in } // proactive analysis is not shown token-by-token
            )

            guard let finalText = Self.lastAssistantText(in: messages) else {
                Log.llm.info("Proactive pass produced no assistant text (tool-use-only final turn).")
                return
            }
            guard let suggestion = Self.parseSuggestion(from: finalText) else {
                // Distinguish an intentional "nothing to surface" from a malformed response we
                // failed to parse — the latter is a bug worth seeing in the log, not silence.
                if Self.isNoneResponse(finalText) {
                    Log.llm.info("Proactive pass: model declined to surface a card (NONE).")
                } else {
                    Log.llm.error("Proactive pass: unparseable model response: \(finalText.prefix(300), privacy: .public)")
                }
                return
            }
            suggestions.append(suggestion)
            if suggestions.count > 20 { suggestions.removeFirst(suggestions.count - 20) }
        } catch {
            Log.llm.error("Proactive analysis failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds the user turn, appending the latest screen snapshot (OCR text + image) when the
    /// screen watcher has one from the last couple of minutes.
    static func userMessage(text: String, screen: ScreenSnapshot?) -> LLMMessage {
        guard let screen, Date().timeIntervalSince(screen.capturedAt) < 120 else { return .user(text) }
        let age = Int(Date().timeIntervalSince(screen.capturedAt))
        var block = "\n\n--- USER'S SCREEN (display under their mouse, captured \(age)s ago"
        if let app = screen.frontmostApp { block += ", frontmost app: \(app)" }
        block += ") ---\n"
        block += screen.ocrText.isEmpty ? "(no readable text)" : "Text on screen (OCR):\n\(screen.ocrText)"
        block += "\n--- END SCREEN ---"
        return LLMMessage(role: .user, content: [.text(text + block), .image(data: screen.jpeg, mimeType: "image/jpeg")])
    }

    private static let screenInstructions = """


    SCREEN CONTEXT: You may also get a screenshot of the user's screen (the display under their \
    mouse, often what's being screen shared) plus OCR'd text from it. Read the screen TOGETHER \
    with the transcript: the screenshot shows what the participants are looking at while they \
    say what's in the transcript. Your job is to keep the meeting moving: unblock confusion, \
    answer questions, clarify, and fact-check, using the screen as a reference for the most \
    concrete, actionable suggestion. For example:
    - Someone is confused, asking how something works, or where something is → use what's \
    visible to give concrete directions ("Click Settings in the left sidebar, then Users", \
    "Go back to the previous screen; the export button is top right", "That value comes from \
    the Status column shown here").
    - A statement in the conversation conflicts with what's on screen (a number, status, date, \
    name, setting) → factCheck card citing what the screen shows.
    - The discussion references something on screen ambiguously ("this one", "that field") → \
    clarify which element it most likely is and what it means.
    - An error, warning, failed request, or unexpected result is visible → explain what it \
    means and the likely cause/fix; look up matching tickets, bugs, or docs with your tools.
    - The conversation is stuck or circling → suggest the next concrete step based on what's \
    on screen.
    Only refer to UI elements you can actually see in the screenshot or OCR text; never invent \
    buttons, menus, or paths. If the screen is irrelevant to what's being discussed, decide \
    based on the transcript alone.
    """

    /// Last ~10 non-empty lines of the transcript, used to give the nudge prompt something to
    /// visually emphasize as "focus here" separate from the full transcript included for context.
    private static func recentTail(of transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(10).joined(separator: "\n")
    }

    private static func lastAssistantText(in messages: [LLMMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            for content in message.content {
                if case .text(let text) = content { return text }
            }
            return nil // most recent assistant turn had no text block (e.g. tool-use only)
        }
        return nil
    }

    /// "NONE" as the model actually emits it — despite "EXACTLY the string NONE", models
    /// (Gemini especially) routinely add a period or lowercase it.
    private static func isNoneResponse(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty || trimmed.uppercased() == "NONE"
    }

    private static func parseSuggestion(from rawText: String) -> Suggestion? {
        var trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isNoneResponse(trimmed) else { return nil }

        // Models also routinely fence the JSON in ```json ... ``` despite being told not to.
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = json["kind"] as? String,
              let title = json["title"] as? String,
              let body = json["body"] as? String else {
            return nil
        }
        let kind: SuggestionKind
        switch kindRaw {
        case "answer": kind = .answer
        case "clarification": kind = .clarification
        case "factCheck": kind = .factCheck
        default: return nil
        }
        return Suggestion(kind: kind, title: title, body: body)
    }

    private static let systemPrompt = """
    You are Clyde's proactive meeting analysis engine. You silently watch a live meeting \
    transcript (fed to you a chunk at a time) and decide, for each chunk, whether the user — who \
    can see your output in a small private overlay only they can see — would benefit from an \
    unprompted card right now. The transcript is live speech-to-text, so expect filler words and \
    garbled fragments; read through the noise for intent.

    Follow this procedure for every chunk, in order:

    STEP 1 — Scan the new transcript for ANY question anyone raised — the user's own questions \
    ("You:") and other participants' alike, e.g. "which modules does customer X have enabled?", \
    "do we have an open ticket for Y?", "who owns Z?", "what does that acronym mean?". If you \
    can answer it — from your tools (connected to the user's real knowledge sources: internal \
    company data, CRM, support tickets, project trackers, docs) or from your own knowledge — \
    you MUST answer it: call the tools NOW when they apply, and emit an "answer" card whose \
    body contains the ACTUAL ANSWER (names, numbers, statuses — the data itself). Answer even \
    if someone in the meeting already answered it — an authoritative confirmation with real \
    data lets the user verify what was said (if their answer disagrees with your data, say so; \
    that's a factCheck card). This step is mandatory, not optional: never respond NONE, and \
    never emit a card that merely says a question is open or suggests following up, when you \
    could have answered it. If your tools genuinely came up empty, emit a "clarification" card \
    saying exactly what you checked.

    STEP 2 — Only if step 1 found no answerable question: look for anything else genuinely \
    useful to surface, and lean toward surfacing it — the card appears in a private, dismissible \
    overlay, so a decent card costs the user almost nothing while a missed one can cost them the \
    moment. Good step-2 cards include:
    - A customer, account, deal, ticket, or project just got mentioned → look it up with your \
    tools and surface relevant context (status, health, open issues, recent activity) the user \
    would want at hand for this discussion.
    - A dubious or surprising claim was made → fact-check it (with tools when possible).
    - Something ambiguous or conflicting was said → clarify it.
    - A commitment, date, or number was stated → restate it crisply so it isn't lost.
    Skip a card only for pure small talk, or when you'd just be repeating what was already \
    surfaced (see the list of recent cards provided) or restating what the participants \
    themselves already made clear.

    If neither step produced a card, respond with EXACTLY the string NONE.
    Otherwise respond with EXACTLY one JSON object, no other text, no markdown fences:
    {"kind": "answer" | "clarification" | "factCheck", "title": "<=8 words", "body": "1-3 sentences"}
    """

    private static func userPrompt(recentTranscript: String, recentContext: String, contextPreamble: String, recentCards: [String], screenChanged: Bool) -> String {
        let preamble = contextPreamble.isEmpty ? "" : "\(contextPreamble)\n\n"
        let context = recentContext.isEmpty ? "" : "Recent transcript (context, already reviewed on earlier checks):\n\(recentContext)\n\n"
        let cards = recentCards.isEmpty ? "" : "Cards you already surfaced (do not repeat these):\n- \(recentCards.joined(separator: "\n- "))\n\n"
        let speech = recentTranscript.isEmpty
            ? "No new speech since your last check."
            : "New transcript since your last check (evaluate this):\n\(recentTranscript)"
        let screenNote = screenChanged
            ? "\n\nThe user's screen just changed meaningfully; the new screen is attached below. Read it together with the recent transcript: is there a way to help right now (directions, clarification, fact-check, next step)?"
            : ""
        return "\(preamble)\(context)\(cards)\(speech)\(screenNote)"
    }

    private static let nudgeSystemPrompt = """
    You are Clyde's meeting assistant. The user just explicitly pressed a "Nudge" button asking \
    you to offer a suggestion right now, based on the conversation so far — they want your take \
    on what's most relevant, not passive background monitoring. Answer a question that was asked \
    but not answered, clarify something confusing, fact-check a claim, or otherwise surface \
    whatever would genuinely help the user in this moment. You have tools connected to the \
    user's real knowledge sources (internal company data, CRM, support tickets, project \
    trackers, docs) — when the conversation raises a question those tools can answer, you MUST \
    call them and put the actual answer in the card, not merely note that the question is open. \
    Focus mainly on the most recent turns provided below; the full transcript is there only for \
    background context.

    The user asked directly, so you MUST produce a card — an empty response to an explicit \
    request is worse than a modest one. If nothing urgent stands out, surface the most useful \
    thing available anyway: a recap of where the conversation stands, an open question nobody \
    answered, a risk or ambiguity worth flagging, or a suggested next step. Only if the \
    transcript is entirely empty may you respond with EXACTLY the string NONE.

    Respond with EXACTLY one JSON object, no other text, no markdown fences:
    {"kind": "answer" | "clarification" | "factCheck", "title": "<=8 words", "body": "1-3 sentences"}
    """

    private static func nudgeUserPrompt(fullTranscript: String, recentTranscript: String, contextPreamble: String) -> String {
        """
        \(contextPreamble.isEmpty ? "" : contextPreamble + "\n")
        --- FULL TRANSCRIPT (context only) ---
        \(fullTranscript)
        --- END FULL TRANSCRIPT ---

        --- MOST RECENT TURNS (focus here) ---
        \(recentTranscript)
        --- END MOST RECENT TURNS ---
        """
    }
}
