import SwiftUI
import AppKit

enum CopilotTab: String, CaseIterable {
    case meetings = "Meetings"
    case live = "Live"
    case chat = "Chat"
    case notes = "Notes"
}

struct CopilotView: View {
    let model: AppModel
    @State private var showingSettings = false
    @State private var didCaptureScreenshot = false

    var body: some View {
        ZStack {
            VisualEffectView(opacity: model.overlayOpacity)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.2)
                Picker("", selection: Binding(get: { model.activeTab }, set: { model.activeTab = $0 })) {
                    ForEach(CopilotTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(10)

                switch model.activeTab {
                case .meetings: MeetingsView(model: model)
                case .live: LiveView(model: model)
                case .chat: ChatView(model: model)
                case .notes: NotesView(model: model)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .sheet(item: Binding(get: { model.pendingMeetingStart }, set: { model.pendingMeetingStart = $0 })) { pending in
            StartMeetingModal(model: model, pending: pending)
        }
        .sheet(item: Binding(get: { model.presentedPrepEvent }, set: { model.presentedPrepEvent = $0 })) { event in
            MeetingPrepSheet(model: model, event: event)
        }
        .sheet(item: Binding(get: { model.presentedDescriptionEvent }, set: { model.presentedDescriptionEvent = $0 })) { event in
            EditDescriptionSheet(model: model, event: event)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isMeetingActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text("Clyde")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                if model.isMeetingActive { Task { await model.stopMeeting() } }
                else { model.requestStartMeeting() }
            } label: {
                Text(model.isMeetingActive ? "Stop" : "Start Meeting")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.1)))

            if Settings.shared.showScreenshotButton {
                Button {
                    didCaptureScreenshot = model.captureScreenshot()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCaptureScreenshot = false
                    }
                } label: {
                    Image(systemName: didCaptureScreenshot ? "checkmark" : "camera.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Screenshot the panel — saves to Pictures/Clyde Screenshots and copies to the clipboard")
            }

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                model.closePanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Hide Clyde — reopen from the menu-bar icon")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Shown before transcription actually begins, for every "Start" entry point (header button,
/// menu-bar item, a Meetings-tab row) — gives the user a chance to tell Clyde what the meeting
/// is about, who's involved, or anything else that would keep it from making wrong assumptions
/// purely from the transcript. Optional: "Skip" starts immediately with no extra context.
private struct StartMeetingModal: View {
    let model: AppModel
    let pending: PendingMeetingStart
    @State private var contextText: String
    @FocusState private var isTextFocused: Bool

    init(model: AppModel, pending: PendingMeetingStart) {
        self.model = model
        self.pending = pending
        // Prefill with the meeting's description when starting from a calendar event — the
        // user already wrote down what this meeting is about; let them add to it, not retype it.
        if case .fromCalendar(let event) = pending {
            _contextText = State(initialValue: model.effectiveDescription(for: event) ?? "")
        } else {
            _contextText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.displayTitle).font(.system(size: 15, weight: .semibold))
            Text("Give Clyde a quick heads-up about this meeting — what it's about, who's involved, anything it should already know. This helps it avoid wrong assumptions while it's listening in.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            TextEditor(text: $contextText)
                .font(.system(size: 12))
                .focused($isTextFocused)
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .scrollContentBackground(.hidden)

            HStack {
                Button("Cancel") {
                    model.cancelPendingMeetingStart()
                }
                Spacer()
                Button("Skip") {
                    Task { await model.confirmPendingMeetingStart(userContext: "") }
                }
                Button("Start Meeting") {
                    Task { await model.confirmPendingMeetingStart(userContext: contextText) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { isTextFocused = true }
    }
}

private struct MeetingsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.calendarViewMode }, set: { model.calendarViewMode = $0 })) {
                ForEach(CalendarViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            switch model.calendarViewMode {
            case .list: UpcomingListView(model: model)
            case .month: MonthCalendarView(model: model)
            }
        }
    }
}

private struct UpcomingListView: View {
    let model: AppModel

    private static let dayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    /// `model.calendarEvents` is already sorted soonest-first; this just buckets that same
    /// order into consecutive same-day runs, so date headers appear in the right place without
    /// re-sorting anything.
    private var groupedEvents: [(day: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        var groups: [(day: Date, events: [CalendarEvent])] = []
        for event in model.calendarEvents {
            let day = calendar.startOfDay(for: event.start)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].events.append(event)
            } else {
                groups.append((day, [event]))
            }
        }
        return groups
    }

    private func dayLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return Self.dayHeaderFormatter.string(from: day)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your upcoming meetings").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        Task { await model.loadCalendarEvents() }
                    } label: {
                        if model.isLoadingCalendar {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoadingCalendar)
                }

                if let error = model.calendarError {
                    Text("⚠️ \(error)").font(.system(size: 11)).foregroundStyle(.orange)
                }

                if model.calendarEvents.isEmpty && !model.isLoadingCalendar && model.calendarError == nil {
                    Text("Nothing on your calendar in the next week.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                ForEach(groupedEvents, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(dayLabel(for: group.day))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Divider()
                        }
                        ForEach(group.events) { event in
                            CalendarEventRow(model: model, event: event)
                        }
                    }
                }
            }
            .padding(12)
        }
        .task { await model.loadCalendarEvents() }
    }
}

private struct MonthCalendarView: View {
    let model: AppModel

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = .current
        return calendar
    }

    /// 42 consecutive days (6 weeks) forming the visible grid, starting from the Sunday/Monday
    /// (per the locale's first weekday) on or before the 1st of the displayed month.
    private var gridDays: [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: model.displayedMonth)) else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -offset, to: monthStart) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var eventsByDay: [Date: [CalendarEvent]] {
        Dictionary(grouping: model.monthEvents) { calendar.startOfDay(for: $0.start) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.changeMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                Text(Self.monthFormatter.string(from: model.displayedMonth))
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                Button { model.changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            if let error = model.monthCalendarError {
                Text("⚠️ \(error)").font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 12)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(gridDays, id: \.self) { day in
                    DayCell(
                        day: day,
                        isInDisplayedMonth: calendar.isDate(day, equalTo: model.displayedMonth, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isSelected: model.selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
                        eventCount: eventsByDay[calendar.startOfDay(for: day)]?.count ?? 0
                    )
                    .onTapGesture {
                        model.selectedDay = calendar.isDate(model.selectedDay ?? Date.distantPast, inSameDayAs: day) ? nil : day
                    }
                }
            }
            .padding(.horizontal, 12)

            if model.isLoadingMonthEvents {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 4)
            }

            if let selectedDay = model.selectedDay {
                Divider().padding(.horizontal, 12).padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.dayFormatter.string(from: selectedDay))
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        let dayEvents = eventsByDay[calendar.startOfDay(for: selectedDay)] ?? []
                        if dayEvents.isEmpty {
                            Text("Nothing on the calendar this day.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(dayEvents) { event in
                            CalendarEventRow(model: model, event: event)
                        }
                    }
                    .padding(12)
                }
            } else {
                Spacer()
            }
        }
        .padding(.top, 2)
        .task { await model.loadMonthEvents(for: model.displayedMonth) }
    }
}

private struct DayCell: View {
    let day: Date
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundStyle(isInDisplayedMonth ? .primary : .tertiary)
            Circle()
                .fill(eventCount > 0 ? Color.accentColor : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : (isToday ? Color.white.opacity(0.08) : .clear))
        )
        .contentShape(Rectangle())
    }
}

private struct CalendarEventRow: View {
    let model: AppModel
    let event: CalendarEvent

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, h:mm a"
        return formatter
    }()

    private var isHappeningNow: Bool {
        let now = Date()
        return event.start <= now && now <= event.end
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isHappeningNow {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    Text(event.title).font(.system(size: 12.5, weight: .medium))
                    if event.recurringEventId != nil {
                        // Standing meetings get Clyde's cross-meeting memory (prior occurrences'
                        // summaries feed the next one) — worth surfacing which ones those are.
                        Image(systemName: "repeat")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                            .padding(3)
                            .background(Circle().fill(Color.accentColor.opacity(0.18)))
                            .help("Recurring meeting — Clyde remembers prior occurrences")
                    }
                }
                Text(Self.timeFormatter.string(from: event.start))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if !event.externalAttendees.isEmpty {
                    Text(event.externalAttendees.compactMap { $0.displayName ?? $0.email }.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let description = model.effectiveDescription(for: event) {
                    Text(description)
                        .font(.system(size: 10)).italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.presentedDescriptionEvent = event
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .help("Add or edit a description for this meeting — Prep and meeting context use it")
            Button {
                model.requestMeetingPrep(for: event)
            } label: {
                HStack(spacing: 3) {
                    if model.meetingPreps[event.id] == .generating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 9))
                    }
                    Text("Prep").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))
            .help("Generate a pre-meeting briefing: context, background from your knowledge sources, and open threads")
            Button {
                if !model.isMeetingActive { model.requestStartMeeting(fromCalendar: event) }
                else { model.activeTab = .live }
            } label: {
                Text(model.isMeetingActive ? "Live" : "Start")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.3)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// Sheet for writing/editing a meeting's manual description — the calendar feed is read-only
/// (and currently strips Google's own description field), so this is where "what this meeting
/// is about" lives. For recurring meetings the user chooses whether it applies to every
/// occurrence or just this one.
private struct EditDescriptionSheet: View {
    let model: AppModel
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var applyToSeries: Bool

    init(model: AppModel, event: CalendarEvent) {
        self.model = model
        self.event = event
        let existing = model.manualDescription(for: event)
        _text = State(initialValue: existing?.text ?? event.description ?? "")
        // Default to series scope for recurring meetings (the common intent), unless an
        // occurrence-specific description already exists for this event.
        _applyToSeries = State(initialValue: existing.map(\.appliesToSeries) ?? (event.recurringEventId != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Description").font(.system(size: 15, weight: .semibold))
            Text(event.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .scrollContentBackground(.hidden)

            if event.recurringEventId != nil {
                Picker("Applies to", selection: $applyToSeries) {
                    Text("All occurrences").tag(true)
                    Text("Just this one").tag(false)
                }
                .pickerStyle(.segmented)
            }

            HStack {
                if model.manualDescription(for: event) != nil {
                    Button("Remove", role: .destructive) {
                        model.setManualDescription(nil, for: event, allOccurrences: true)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.setManualDescription(text, for: event, allOccurrences: applyToSeries)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

/// The pre-meeting briefing sheet — opened by a row's "Prep" button. Content is generated in
/// the background (with MCP tool lookups, so it can take ~15-60s) and cached per event for the
/// app session; "Regenerate" forces a fresh one.
private struct MeetingPrepSheet: View {
    let model: AppModel
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting Prep").font(.headline)
                    Text(event.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if case .ready = model.meetingPreps[event.id] {
                    Button("Regenerate") { model.requestMeetingPrep(for: event, regenerate: true) }
                        .font(.caption)
                }
                Button("Done") { dismiss() }
            }
            .padding()

            Divider().opacity(0.3)

            switch model.meetingPreps[event.id] {
            case .ready(let brief):
                ScrollView {
                    MarkdownText(text: brief)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("⚠️ Prep failed: \(message)")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button("Try again") { model.requestMeetingPrep(for: event, regenerate: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            default:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Researching this meeting — checking your knowledge sources…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(width: 460, height: 520)
    }
}

private struct LiveView: View {
    let model: AppModel
    /// Whether the transcript should auto-follow new lines as they arrive. Turns off the moment
    /// the user scrolls away from the bottom, and back on once they scroll back down (or tap the
    /// jump-to-latest button) — the same "auto-follow with manual override" pattern chat apps use.
    @State private var autoScrollToLatest = true

    private static let bottomAnchorID = "live-bottom-anchor"

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.meetingStatusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if model.isMeetingActive {
                            HStack(spacing: 12) {
                                AudioLevelIndicator(label: "Them (system)", detected: model.systemAudioRMSObserved)
                                AudioLevelIndicator(label: "You (mic)", detected: model.microphoneRMSObserved)
                            }
                            .font(.system(size: 10))
                        }

                        // Reserves space so the transcript never sits underneath the floating
                        // suggestion carousel overlaid on top of this ScrollView.
                        if !model.proactive.suggestions.isEmpty {
                            Color.clear.frame(height: 64)
                        }

                        Divider().opacity(0.15)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.meetingContext.segments) { segment in
                                TranscriptLineView(segment: segment).id(segment.id)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(12)
                    .padding(.bottom, 28)
                }
                .onScrollGeometryChange(for: Bool.self, of: { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
                }, action: { _, isNearBottom in
                    autoScrollToLatest = isNearBottom
                })
                .onChange(of: model.meetingContext.segments.count) {
                    guard autoScrollToLatest else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !autoScrollToLatest {
                        Button {
                            autoScrollToLatest = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(radius: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }

            if !model.proactive.suggestions.isEmpty {
                SuggestionCarousel(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, model.isMeetingActive ? 46 : 24)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.meetingContext.segments.isEmpty {
                NudgeButton(model: model)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Manually asks the proactive engine for a suggestion right now, instead of waiting for it to
/// decide on its own — always reachable regardless of scroll position, since the whole point is
/// to use it mid-meeting while the transcript keeps growing underneath.
private struct NudgeButton: View {
    let model: AppModel
    @State private var showingCameUpEmpty = false

    var body: some View {
        HStack(spacing: 8) {
            if showingCameUpEmpty {
                Text("Nothing new to add")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .transition(.opacity)
            }
            Button {
                Task {
                    await model.proactive.nudge()
                    if model.proactive.lastNudgeProducedNothing {
                        withAnimation { showingCameUpEmpty = true }
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { showingCameUpEmpty = false }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if model.proactive.isNudging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Nudge")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .disabled(model.proactive.isNudging)
            .help("Ask the AI for a suggestion right now, based on the conversation so far")
        }
    }
}

/// Shows the proactive suggestion cards floating above the transcript, pinned to the top
/// regardless of scroll position. When there's more than one, only the most recent is shown at
/// a time with left/right arrows to browse the rest, rather than stacking them all at once.
private struct SuggestionCarousel: View {
    let model: AppModel
    @State private var index = 0

    var body: some View {
        let suggestions = model.proactive.suggestions
        let clampedIndex = min(max(index, 0), max(suggestions.count - 1, 0))

        VStack(spacing: 4) {
            if let suggestion = suggestions[safe: clampedIndex] {
                SuggestionCardView(suggestion: suggestion) {
                    model.proactive.dismiss(id: suggestion.id)
                    if index >= suggestions.count - 1 { index = max(suggestions.count - 2, 0) }
                }
            }

            if suggestions.count > 1 {
                HStack(spacing: 10) {
                    Button {
                        index = max(clampedIndex - 1, 0)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                    }
                    .disabled(clampedIndex == 0)

                    Text("\(clampedIndex + 1) of \(suggestions.count)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)

                    Button {
                        index = min(clampedIndex + 1, suggestions.count - 1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                    }
                    .disabled(clampedIndex == suggestions.count - 1)
                }
                .font(.system(size: 14))
                .buttonStyle(.plain)
            }
        }
        // New cards arrive at the end of the array; jump to showing the newest one automatically.
        .onChange(of: suggestions.count) { oldCount, newCount in
            if newCount > oldCount { index = newCount - 1 }
        }
        .onAppear { index = suggestions.count - 1 }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Surfaces whether real (non-silent) audio has actually been observed on a capture stream —
/// TCC denial for the system-audio tap is silent at the Core Audio level (every call still
/// returns success; you just get buffers of zeros), so this is the only reliable signal that
/// audio is actually reaching the transcriber versus the pipeline merely having "started".
private struct AudioLevelIndicator: View {
    let label: String
    let detected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(detected ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(label + (detected ? ": audio detected" : ": no audio yet"))
                .foregroundStyle(.secondary)
        }
    }
}

private struct TranscriptLineView: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(segment.speaker.displayName + ":")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(segment.speaker == .me ? Color.accentColor : .secondary)
            Text(segment.text)
                .font(.system(size: 12))
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .italic(!segment.isFinal)
        }
    }
}

private struct ChatView: View {
    let model: AppModel
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chat.messages) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.chat.messages.count) {
                    if let last = model.chat.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider().opacity(0.2)
            HStack(spacing: 8) {
                TextField("Ask Clyde…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.chat.isResponding)
            }
            .padding(10)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.chat.send(text) }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user { Spacer(minLength: 24) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                Group {
                    if message.text.isEmpty && message.isStreaming {
                        Text("…")
                    } else {
                        MarkdownText(text: message.text)
                    }
                }
                    .font(.system(size: 12.5))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(message.role == .user ? Color.accentColor.opacity(0.25) : .white.opacity(0.08))
                    )
                if !message.text.isEmpty {
                    Button(action: copyToClipboard) {
                        HStack(spacing: 3) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            if didCopy { Text("Copied") }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || didCopy ? 1 : 0.35)
                    .help("Copy message")
                }
            }
            if message.role != .user { Spacer(minLength: 24) }
        }
        .onHover { isHovering = $0 }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

private struct NotesView: View {
    let model: AppModel
    @State private var isFilteringByDate = false
    @State private var filterDate = Date()

    private static let dayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    /// Newest-first, grouped into consecutive same-day runs (mirrors the Meetings tab's
    /// Upcoming list), and restricted to `filterDate` when the date filter is active.
    private var groupedNotes: [(day: Date, notes: [MeetingNote])] {
        let calendar = Calendar.current
        let source = model.notes.reversed()
        var groups: [(day: Date, notes: [MeetingNote])] = []
        for note in source {
            let day = calendar.startOfDay(for: note.startedAt)
            if isFilteringByDate, !calendar.isDate(day, inSameDayAs: filterDate) { continue }
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].notes.append(note)
            } else {
                groups.append((day, [note]))
            }
        }
        return groups
    }

    private func dayLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return Self.dayHeaderFormatter.string(from: day)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle(isOn: $isFilteringByDate.animation()) {
                        Text("Filter by date").font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    if isFilteringByDate {
                        DatePicker("", selection: $filterDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    Spacer()
                }

                if model.isGeneratingSummary {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Generating meeting summary…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                if model.notes.isEmpty && !model.isGeneratingSummary {
                    Text("Summaries of your past meetings will show up here after you end one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if groupedNotes.isEmpty {
                    Text("No meeting summaries on this date.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(groupedNotes, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(dayLabel(for: group.day))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Divider()
                        }
                        ForEach(group.notes) { note in
                            MeetingNoteCard(model: model, note: note)
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct MeetingNoteCard: View {
    let model: AppModel
    let note: MeetingNote
    @State private var isExpanded = false
    @State private var showingTranscript = false
    @State private var didCopyTranscript = false
    @State private var titleDraft: String

    init(model: AppModel, note: MeetingNote) {
        self.model = model
        self.note = note
        _titleDraft = State(initialValue: note.title)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .onSubmit { commitTitleIfChanged() }
                        .onChange(of: titleDraft) { _, _ in commitTitleIfChanged() }
                    Text(Self.dateFormatter.string(from: note.startedAt))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    model.deleteNote(id: note.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                Text(note.summary).font(.system(size: 12))

                if !note.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(note.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 5) {
                                Text("•").foregroundStyle(.secondary)
                                Text(point).font(.system(size: 11.5))
                            }
                        }
                    }
                }

                if !note.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Action items").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(note.actionItems) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Button {
                                    model.toggleActionItem(noteID: note.id, itemID: item.id)
                                } label: {
                                    Image(systemName: item.completed ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.completed ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.description)
                                        .font(.system(size: 11.5))
                                        .strikethrough(item.completed)
                                        .foregroundStyle(item.completed ? .secondary : .primary)
                                    if let owner = item.owner, owner.lowercased() != "unclear" {
                                        Text(owner.capitalized).font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !note.transcript.isEmpty {
                    Divider().opacity(0.15)
                    Button {
                        withAnimation { showingTranscript.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showingTranscript ? "chevron.down" : "chevron.right")
                            Text("Full transcript")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showingTranscript {
                        VStack(alignment: .trailing, spacing: 4) {
                            ScrollView {
                                Text(note.transcript)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                            Button {
                                copyTranscript()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: didCopyTranscript ? "checkmark" : "doc.on.doc")
                                    Text(didCopyTranscript ? "Copied" : "Copy transcript")
                                }
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.15)))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.transcript, forType: .string)
        didCopyTranscript = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyTranscript = false
        }
    }

    private func commitTitleIfChanged() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        model.renameNote(id: note.id, title: trimmed)
    }
}
