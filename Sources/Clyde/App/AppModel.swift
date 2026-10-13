import Foundation
import AVFAudio
import AppKit
import Observation

/// Composition root: owns every long-lived piece (audio capture, transcription, the meeting
/// transcript, the LLM router, MCP connections, chat, and proactive analysis) and wires them
/// together. `AppDelegate` creates exactly one of these and hands it to the SwiftUI content.
@MainActor
@Observable
final class AppModel {
    let meetingContext = MeetingContext()
    let mcp = MCPManager()
    let llmRouter = LLMRouter()

    // Plain `let`s assigned in `init()` rather than `lazy var`s: the `@Observable` macro cannot
    // instrument lazy storage, so a lazy property here would silently fail to trigger SwiftUI
    // view updates when its contents change.
    let chat: ChatViewModel
    let proactive: ProactiveAnalyzer

    private(set) var isMeetingActive = false
    private(set) var meetingStatusMessage = "Not in a meeting"
    private(set) var systemAudioRMSObserved = false
    private(set) var microphoneRMSObserved = false

    private(set) var notes: [MeetingNote] = []
    private(set) var isGeneratingSummary = false
    var activeTab: CopilotTab = .meetings

    /// Non-nil while the "tell Clyde about this meeting" modal is up, waiting on the user before
    /// transcription actually begins. Every "Start" entry point (header button, menu-bar item,
    /// a Meetings-tab row) sets this instead of calling `startMeeting()` directly.
    var pendingMeetingStart: PendingMeetingStart?

    private(set) var calendarEvents: [CalendarEvent] = []
    private(set) var isLoadingCalendar = false
    private(set) var calendarError: String?

    var calendarViewMode: CalendarViewMode = .list
    var displayedMonth: Date = Date()
    var selectedDay: Date?
    private(set) var monthEvents: [CalendarEvent] = []
    private(set) var isLoadingMonthEvents = false
    private(set) var monthCalendarError: String?

    private var systemTap: SystemAudioTap?
    private var micCapture: MicCapture?
    private var systemTranscriber: AppleTranscriber?
    private var micTranscriber: AppleTranscriber?
    private var transcriberTasks: [Task<Void, Never>] = []
    private var rmsMonitorTask: Task<Void, Never>?
    private var meetingStartedAt: Date?

    /// Identity of the calendar event the CURRENT meeting was started from, if any — carried
    /// from `startMeetingFromCalendar(_:)` through to `stopMeeting()`, where it's used both to
    /// look up prior occurrences of this same standing meeting and to tag the new summary with
    /// the same identity so IT becomes findable next time.
    private var currentMeetingCalendarTitle: String?
    private var currentMeetingRecurringEventId: String?

    /// Set by `AppDelegate` once the overlay panel exists, so Settings (which only knows about
    /// `AppModel`, not AppKit window objects) can toggle the panel's live capture-exclusion
    /// state without needing a direct reference to it.
    var applyCaptureExclusionSetting: ((Bool) -> Void)?

    /// Set by `AppDelegate` so the panel's own close button can hide it — the same action as
    /// the status-bar menu's "Show/Hide Overlay" item, just reachable from inside the panel too.
    /// Hiding (not closing/deallocating) the window: the status-bar item can always bring it back.
    var hidePanel: (() -> Void)?

    /// Set by `AppDelegate` so requesting a meeting start brings the panel to the front even if
    /// it was hidden — otherwise the "tell Clyde about this meeting" modal would pop up on a
    /// panel the user can't see.
    var presentPanel: (() -> Void)?

    /// Set by `AppDelegate` so the header's camera button can render the panel's own contents —
    /// see `CopilotPanel.captureSnapshot()`.
    var captureScreenshotHandler: (() -> NSImage?)?

    var captureExclusionEnabled: Bool { Settings.shared.captureExclusionEnabled }

    func setCaptureExclusionEnabled(_ enabled: Bool) {
        Settings.shared.captureExclusionEnabled = enabled
        applyCaptureExclusionSetting?(enabled)
    }

    /// Fades only the panel's glass background, not the content — `CopilotView` reads this
    /// directly (Settings is @Observable), so slider changes render live with no plumbing.
    var overlayOpacity: Double { Settings.shared.overlayOpacity }

    func setOverlayOpacity(_ opacity: Double) {
        Settings.shared.overlayOpacity = opacity
    }

    func closePanel() {
        hidePanel?()
    }

    /// Renders the panel to an image, saves it to `~/Pictures/Clyde Screenshots/`, and copies it
    /// to the clipboard. Returns whether it succeeded, so the header button can flash feedback.
    @discardableResult
    func captureScreenshot() -> Bool {
        guard let image = captureScreenshotHandler?(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Log.overlay.error("Screenshot capture failed — could not render the panel to an image.")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Clyde \(formatter.string(from: Date())).png")

        do {
            try png.write(to: fileURL)
            return true
        } catch {
            Log.overlay.error("Screenshot save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    init() {
        chat = ChatViewModel(meetingContext: meetingContext, llm: llmRouter, mcp: mcp)
        proactive = ProactiveAnalyzer(meetingContext: meetingContext, llm: llmRouter, mcp: mcp)
    }

    func bootstrap() async {
        notes = MeetingNotesStore.load()
        await mcp.reload(MCPConfigStore.load())
        proactive.setEnabled(Settings.shared.proactiveEnabled)
        await loadCalendarEvents()
    }

    func loadCalendarEvents() async {
        guard let apiKey = Settings.shared.calendarAPIKey, !apiKey.isEmpty else {
            calendarError = "No calendar API key configured — add one in Settings."
            return
        }
        isLoadingCalendar = true
        calendarError = nil
        defer { isLoadingCalendar = false }

        let client = CalendarClient(baseURL: Settings.shared.calendarAPIURL, apiKey: apiKey)
        do {
            calendarEvents = try await client.fetchMyUpcomingEvents(selfEmail: Settings.shared.calendarSelfEmail)
        } catch {
            calendarError = error.localizedDescription
            Log.app.error("Calendar fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads every event on the user's calendar for the month containing `month` (the full
    /// grid range, including a little of the adjacent months so the leading/trailing grid
    /// cells aren't empty).
    func loadMonthEvents(for month: Date) async {
        guard let apiKey = Settings.shared.calendarAPIKey, !apiKey.isEmpty else {
            monthCalendarError = "No calendar API key configured — add one in Settings."
            return
        }
        var calendar = Calendar.current
        calendar.timeZone = .current
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return }
        let rangeStart = calendar.date(byAdding: .day, value: -7, to: monthInterval.start) ?? monthInterval.start
        let rangeEnd = calendar.date(byAdding: .day, value: 7, to: monthInterval.end) ?? monthInterval.end

        isLoadingMonthEvents = true
        monthCalendarError = nil
        defer { isLoadingMonthEvents = false }

        let client = CalendarClient(baseURL: Settings.shared.calendarAPIURL, apiKey: apiKey)
        do {
            monthEvents = try await client.fetchEvents(selfEmail: Settings.shared.calendarSelfEmail, timeMin: rangeStart, timeMax: rangeEnd)
        } catch {
            monthCalendarError = error.localizedDescription
            Log.app.error("Month calendar fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func changeMonth(by delta: Int) {
        var calendar = Calendar.current
        calendar.timeZone = .current
        guard let newMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = newMonth
        selectedDay = nil
        Task { await loadMonthEvents(for: newMonth) }
    }

    // MARK: - "Tell Clyde about this meeting" modal

    /// Requests the manual (menu-bar / header button) start flow — shows the modal instead of
    /// starting immediately.
    func requestStartMeeting() {
        guard !isMeetingActive else { return }
        presentPanel?()
        pendingMeetingStart = .manual
    }

    /// Requests the calendar-linked start flow for a specific event — shows the modal instead
    /// of starting immediately.
    func requestStartMeeting(fromCalendar event: CalendarEvent) {
        guard !isMeetingActive else { return }
        presentPanel?()
        pendingMeetingStart = .fromCalendar(event)
    }

    func cancelPendingMeetingStart() {
        pendingMeetingStart = nil
    }

    /// Called by the modal once the user hits Start (or Skip, with an empty context) — actually
    /// begins transcription.
    func confirmPendingMeetingStart(userContext: String) async {
        guard let pending = pendingMeetingStart else { return }
        pendingMeetingStart = nil
        switch pending {
        case .manual:
            await startMeeting(userContext: userContext)
        case .fromCalendar(let event):
            await startMeetingFromCalendar(event, userContext: userContext)
        }
    }

    /// Switches to the Live tab immediately (so the user sees progress right away — model
    /// loading, permission prompts, etc.) and starts the meeting. Unlike a plain menu-bar
    /// "Start Meeting", this carries the calendar event's identity through so prior occurrences
    /// of the same standing meeting can be looked up as context, and so this meeting's own
    /// summary gets tagged for future ones to find.
    private func startMeetingFromCalendar(_ event: CalendarEvent, userContext: String) async {
        activeTab = .live
        currentMeetingCalendarTitle = event.title
        currentMeetingRecurringEventId = event.recurringEventId
        await startMeeting(userContext: userContext)
    }

    func reloadMCPServers() async {
        await mcp.reload(MCPConfigStore.load())
    }

    func startMeeting(userContext: String = "") async {
        guard !isMeetingActive else { return }
        meetingContext.reset()
        meetingContext.userProvidedContext = userContext
        meetingContext.priorMeetingContext = Self.priorMeetingContext(
            in: notes,
            calendarTitle: currentMeetingCalendarTitle,
            recurringEventId: currentMeetingRecurringEventId
        )
        meetingStatusMessage = "Requesting permissions…"

        Log.audio.info("startMeeting() called — requesting microphone access…")
        let micGranted = await MicCapture.requestAccess()
        guard micGranted else {
            meetingStatusMessage = "Microphone access denied — enable it in System Settings > Privacy & Security."
            Log.audio.error("Microphone access denied or not determined — aborting meeting start.")
            return
        }

        let systemTranscriber = AppleTranscriber(locale: Locale(identifier: Settings.shared.locale), debugLabel: "system")
        let micTranscriber = AppleTranscriber(locale: Locale(identifier: Settings.shared.locale), debugLabel: "mic")
        self.systemTranscriber = systemTranscriber
        self.micTranscriber = micTranscriber

        do {
            meetingStatusMessage = "Loading speech models…"
            try await systemTranscriber.prepare()
            try await micTranscriber.prepare()
            try await systemTranscriber.start()
            try await micTranscriber.start()
        } catch {
            meetingStatusMessage = "Failed to start transcription: \(error.localizedDescription)"
            Log.transcribe.error("Transcriber startup failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // The live view deliberately shows all system-audio speech as plain "Them": live CoreML
        // diarization (tried with FluidAudio's LS-EEND and Sortformer models) proved unreliable
        // on real VoIP meeting audio — voices collapsed into one slot. Per-speaker attribution
        // happens after the meeting instead, in TranscriptRefiner, where the LLM separates
        // speakers from conversational context far more reliably.
        transcriberTasks.append(Task { [weak self] in
            guard let self else { return }
            for await update in systemTranscriber.updates {
                await MainActor.run { self.meetingContext.upsert(update, stream: .system, speaker: .them) }
            }
        })
        transcriberTasks.append(Task { [weak self] in
            guard let self else { return }
            for await update in micTranscriber.updates {
                await MainActor.run { self.meetingContext.upsert(update, stream: .mic, speaker: .me) }
            }
        })

        // Captures the transcriber instances directly (not via `self`) so the real-time audio
        // callback — invoked off the main actor, many times per second — never has to hop
        // actors to reach it; only the much-lower-frequency transcript *updates* get marshaled
        // back to the main actor above.
        let systemTap = SystemAudioTap { buffer, time in
            systemTranscriber.ingest(buffer, at: time)
        }
        let micCapture = MicCapture { buffer, time in
            micTranscriber.ingest(buffer, at: time)
        }

        // Order matters here: enabling AVAudioEngine's voice-processing (echo cancellation,
        // inside MicCapture.start()) triggers a brief system-wide Core Audio hardware
        // reconfiguration — confirmed by direct instrumentation, where the system tap's IOProc
        // kept firing throughout but its cached tap format silently stopped matching the actual
        // delivered buffers the moment voice processing engaged, right after MicCapture started.
        // Starting the mic FIRST means that reconfiguration happens before the system tap reads
        // and caches its format, so the format it caches is the one that's actually stable
        // afterward.
        do {
            try micCapture.start()
        } catch {
            meetingStatusMessage = "Microphone capture failed: \(error.localizedDescription)"
            Log.audio.error("MicCapture failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            try systemTap.start()
        } catch {
            micCapture.stop()
            meetingStatusMessage = "System audio capture failed: \(error.localizedDescription) — check System Settings > Privacy & Security > Screen & System Audio Recording."
            Log.audio.error("SystemAudioTap failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.systemTap = systemTap
        self.micCapture = micCapture
        meetingStartedAt = Date()
        isMeetingActive = true
        meetingStatusMessage = "Meeting in progress"
        proactive.start()

        rmsMonitorTask = Task { [weak self] in
            while let self, self.isMeetingActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.systemAudioRMSObserved = self.systemTap?.hasObservedNonSilentAudio ?? false
                self.microphoneRMSObserved = self.micCapture?.hasObservedNonSilentAudio ?? false
            }
        }
    }

    func stopMeeting() async {
        guard isMeetingActive else { return }
        isMeetingActive = false
        proactive.stop()
        rmsMonitorTask?.cancel()
        rmsMonitorTask = nil

        systemTap?.stop()
        micCapture?.stop()
        systemTap = nil
        micCapture = nil

        await systemTranscriber?.stop()
        await micTranscriber?.stop()
        systemTranscriber = nil
        micTranscriber = nil

        transcriberTasks.forEach { $0.cancel() }
        transcriberTasks.removeAll()

        // Captured before clearing the Live tab below — this is the last point at which the
        // meeting that just ended's transcript is available for the summary.
        let transcript = meetingContext.finalizedTranscriptText
        let startedAt = meetingStartedAt ?? Date()
        let endedAt = Date()
        meetingStartedAt = nil
        let calendarTitle = currentMeetingCalendarTitle
        let recurringEventId = currentMeetingRecurringEventId
        let userContext = meetingContext.userProvidedContext
        currentMeetingCalendarTitle = nil
        currentMeetingRecurringEventId = nil

        // The Live tab (transcript + suggestion cards) is meeting-scoped — clear it now rather
        // than leaving the last meeting's content sitting there until the next one starts.
        meetingContext.reset()
        proactive.clear()

        meetingStatusMessage = "Not in a meeting"
        systemAudioRMSObserved = false
        microphoneRMSObserved = false

        guard transcript.count > 40 else { return } // not enough happened to be worth summarizing
        generateSummary(
            transcript: transcript, startedAt: startedAt, endedAt: endedAt,
            calendarEventTitle: calendarTitle, recurringEventId: recurringEventId, userContext: userContext
        )
    }

    /// Runs in the background so the user isn't blocked waiting on it — `notes`/`isGeneratingSummary`
    /// are `@Observable`, so the Notes tab updates live once it lands.
    private func generateSummary(
        transcript: String, startedAt: Date, endedAt: Date,
        calendarEventTitle: String?, recurringEventId: String?, userContext: String
    ) {
        isGeneratingSummary = true
        activeTab = .notes
        Task {
            defer { isGeneratingSummary = false }
            do {
                // Clean the transcript first (LLM re-attributes speakers from context and strips
                // STT junk), then summarize FROM the cleaned version — the summary benefits from
                // knowing who said what just as much as the saved note does.
                let refiner = TranscriptRefiner(router: llmRouter)
                let refinedTranscript = await refiner.refine(transcript: transcript, userContext: userContext)
                let summarizer = MeetingSummarizer(router: llmRouter)
                var note = try await summarizer.summarize(
                    transcript: refinedTranscript, startedAt: startedAt, endedAt: endedAt, userContext: userContext
                )
                // Prefer the actual calendar event's name over the LLM's own guess at a title —
                // it's the name the user already recognizes this meeting by.
                if let calendarEventTitle, !calendarEventTitle.isEmpty {
                    note.title = calendarEventTitle
                }
                note.calendarEventTitle = calendarEventTitle
                note.recurringEventId = recurringEventId
                notes.append(note)
                MeetingNotesStore.save(notes)
            } catch {
                Log.llm.error("Meeting summary generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finds past notes belonging to the same standing meeting as the one about to start (by
    /// recurring-event identity when available, else exact calendar-title match) and formats
    /// their summaries/action items as context — this is Clyde's "memory" of prior occurrences.
    /// Deliberately excludes full past transcripts to keep prompt size sane; the Notes tab is
    /// where the complete detail lives if the user wants it. Nothing is looked up (empty string)
    /// when the meeting wasn't started from a calendar event, since there's no known series to
    /// match against.
    /// All saved notes belonging to the same standing meeting (by recurring-series id when
    /// available, else exact calendar-title match), oldest-first. Shared by the prior-context
    /// block fed into a starting meeting and by meeting prep.
    static func matchingPriorNotes(in notes: [MeetingNote], calendarTitle: String?, recurringEventId: String?) -> [MeetingNote] {
        guard calendarTitle != nil || recurringEventId != nil else { return [] }

        func normalize(_ text: String) -> String {
            text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return notes.filter { note in
            if let recurringEventId, let noteSeriesId = note.recurringEventId, !recurringEventId.isEmpty, recurringEventId == noteSeriesId {
                return true
            }
            if let calendarTitle, let noteTitle = note.calendarEventTitle {
                return normalize(calendarTitle) == normalize(noteTitle)
            }
            return false
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    private static func priorMeetingContext(in notes: [MeetingNote], calendarTitle: String?, recurringEventId: String?) -> String {
        let matches = matchingPriorNotes(in: notes, calendarTitle: calendarTitle, recurringEventId: recurringEventId)
        guard !matches.isEmpty else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        // Most recent 3 prior occurrences, oldest-first so they read chronologically.
        let recent = matches.suffix(3)
        let sections = recent.map { note -> String in
            var lines = ["[Meeting on \(dateFormatter.string(from: note.startedAt))] \(note.title)", note.summary]
            let openItems = note.actionItems.filter { !$0.completed }
            if !openItems.isEmpty {
                lines.append("Open action items from that meeting:")
                lines.append(contentsOf: openItems.map { "- \($0.description)" + ($0.owner.map { " (\($0))" } ?? "") })
            }
            return lines.joined(separator: "\n")
        }

        return """
        This is a recurring/standing meeting. Here's what was discussed in recent prior occurrences \
        (most recent last) — use this as background memory, e.g. to recognize follow-ups or note \
        whether an open action item finally got addressed:

        \(sections.joined(separator: "\n\n"))
        """
    }

    // MARK: - Manual event descriptions

    /// User-written meeting descriptions (see EventDescriptionStore). Kept in the model (and
    /// mirrored to disk on every change) so views re-render live when one is edited.
    private(set) var manualEventDescriptions: [String: String] = EventDescriptionStore.load()

    /// The event whose "edit description" sheet is currently shown, if any.
    var presentedDescriptionEvent: CalendarEvent?

    /// The user's own description for this event: the occurrence-specific one if set, else the
    /// recurring series' one.
    func manualDescription(for event: CalendarEvent) -> (text: String, appliesToSeries: Bool)? {
        if let text = manualEventDescriptions[EventDescriptionStore.eventKey(for: event)] {
            return (text, false)
        }
        if let seriesKey = EventDescriptionStore.seriesKey(for: event),
           let text = manualEventDescriptions[seriesKey] {
            return (text, true)
        }
        return nil
    }

    /// What Prep and the start-meeting modal should treat as "the description": the manual one
    /// when present, else whatever the calendar feed provided (currently nothing — see
    /// CalendarEvent.description).
    func effectiveDescription(for event: CalendarEvent) -> String? {
        manualDescription(for: event)?.text ?? event.description
    }

    /// Saves (or clears, when `text` is empty/nil) the manual description. `allOccurrences`
    /// stores it against the recurring series so every occurrence shows it; otherwise it's
    /// pinned to just this event. Saving in either scope clears the other scope's entry for
    /// this event so there's one unambiguous source of truth.
    func setManualDescription(_ text: String?, for event: CalendarEvent, allOccurrences: Bool) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventKey = EventDescriptionStore.eventKey(for: event)
        let seriesKey = EventDescriptionStore.seriesKey(for: event)

        if let trimmed, !trimmed.isEmpty {
            if allOccurrences, let seriesKey {
                manualEventDescriptions[seriesKey] = trimmed
                manualEventDescriptions.removeValue(forKey: eventKey)
            } else {
                manualEventDescriptions[eventKey] = trimmed
            }
        } else {
            manualEventDescriptions.removeValue(forKey: eventKey)
            if allOccurrences, let seriesKey {
                manualEventDescriptions.removeValue(forKey: seriesKey)
            }
        }
        EventDescriptionStore.save(manualEventDescriptions)
        // A changed description invalidates any cached prep brief for this event.
        meetingPreps.removeValue(forKey: event.id)
    }

    // MARK: - Meeting prep

    enum MeetingPrepState: Equatable {
        case generating
        case ready(String)
        case failed(String)
    }

    /// One briefing per calendar event id, kept for the app session so re-opening the sheet is
    /// instant. Regenerating replaces the cached one.
    private(set) var meetingPreps: [String: MeetingPrepState] = [:]

    /// The event whose prep sheet is currently shown, if any (drives `.sheet(item:)`).
    var presentedPrepEvent: CalendarEvent?

    /// Opens the prep sheet for `event` and kicks off generation unless a briefing is already
    /// cached (pass `regenerate: true` to force a fresh one).
    func requestMeetingPrep(for event: CalendarEvent, regenerate: Bool = false) {
        presentedPrepEvent = event
        if !regenerate, let existing = meetingPreps[event.id], existing != .generating {
            if case .ready = existing { return }
        }
        if case .generating? = meetingPreps[event.id] { return }
        meetingPreps[event.id] = .generating

        // The prep prompt reads `event.description` — substitute the effective one (the user's
        // manual description wins over the feed's, which is currently always absent anyway).
        var enrichedEvent = event
        enrichedEvent.description = effectiveDescription(for: event)

        Task {
            let priorNotes = Array(Self.matchingPriorNotes(
                in: notes, calendarTitle: event.title, recurringEventId: event.recurringEventId
            ).suffix(3))
            do {
                let generator = MeetingPrepGenerator(router: llmRouter, mcp: mcp)
                let brief = try await generator.generate(event: enrichedEvent, priorNotes: priorNotes)
                meetingPreps[event.id] = .ready(brief)
            } catch {
                meetingPreps[event.id] = .failed(error.localizedDescription)
                Log.llm.error("Meeting prep failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func toggleActionItem(noteID: UUID, itemID: UUID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let itemIndex = notes[noteIndex].actionItems.firstIndex(where: { $0.id == itemID }) else { return }
        notes[noteIndex].actionItems[itemIndex].completed.toggle()
        MeetingNotesStore.save(notes)
    }

    func renameNote(id: UUID, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].title = title
        MeetingNotesStore.save(notes)
    }

    func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        MeetingNotesStore.save(notes)
    }

    /// Forces the currently-forming utterance on both streams to settle, then returns the most
    /// recent settled text — used by the "what did they just say?" hotkey.
    func finalizeAndSummarizeRecent() async -> String {
        await systemTranscriber?.finalizeNow()
        await micTranscriber?.finalizeNow()
        return meetingContext.finalizedTranscriptText
    }
}
