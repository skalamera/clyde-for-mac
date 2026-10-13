import Foundation

/// A meeting-start request waiting on the "tell Clyde about this meeting" modal before
/// transcription actually begins — see AppModel.pendingMeetingStart.
enum PendingMeetingStart: Identifiable, Equatable {
    case manual
    case fromCalendar(CalendarEvent)

    var id: String {
        switch self {
        case .manual: return "manual-start"
        case .fromCalendar(let event): return "calendar-\(event.id)"
        }
    }

    var displayTitle: String {
        switch self {
        case .manual: return "Start Meeting"
        case .fromCalendar(let event): return event.title
        }
    }
}

/// Live-view attribution only: "You" (mic) vs "Them" (system audio, everyone else). Splitting
/// "Them" into individual speakers happens post-meeting in TranscriptRefiner — live on-device
/// diarization was tried (FluidAudio LS-EEND + Sortformer) and collapsed real VoIP voices into
/// one slot, so the LLM does it from conversational context at save time instead.
enum Speaker: String, Sendable, Codable, Equatable {
    case me
    case them

    var displayName: String {
        switch self {
        case .me: return "You"
        case .them: return "Them"
        }
    }
}

/// One line of the live transcript. `id` is stable per (speaker, range-start) so the UI/store
/// can replace a volatile line in place as SpeechAnalyzer refines it, rather than appending
/// duplicate lines.
struct TranscriptSegment: Identifiable, Sendable {
    let id: String
    var speaker: Speaker
    var text: String
    var isFinal: Bool
    var timestamp: Date
}

enum SuggestionKind: String, Sendable {
    case answer
    case clarification
    case factCheck
}

struct Suggestion: Identifiable, Sendable {
    let id = UUID()
    var kind: SuggestionKind
    var title: String
    var body: String
    var createdAt: Date = Date()
}

struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable, Equatable { case user, assistant, tool }
    let id = UUID()
    var role: Role
    var text: String
    var isStreaming: Bool = false
}

/// A single open (or completed) task surfaced by the meeting-summary generator.
struct ActionItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var description: String
    /// Who it's on — "you", "them", or "unclear", as reported by the summarizer. Free-form
    /// rather than tied to `Speaker` since a meeting can have several distinct "them" people.
    var owner: String?
    var completed: Bool = false

    init(id: UUID = UUID(), description: String, owner: String?, completed: Bool = false) {
        self.id = id
        self.description = description
        self.owner = owner
        self.completed = completed
    }
}

/// A saved, LLM-generated summary of one completed meeting — persisted locally so past
/// meetings remain browsable in the Notes tab after the app restarts.
struct MeetingNote: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [ActionItem]
    /// The finalized transcript the summary was generated from, kept for reference/lookup —
    /// not shown by default in the Notes tab, but available if the user wants the full detail.
    var transcript: String

    /// Identity of the calendar event this meeting was started from, if any — used to recognize
    /// "this is the same standing meeting as before" so past occurrences can be surfaced as
    /// context in a later one. Both nil when the meeting was started without a calendar event
    /// (no series to match against). See AppModel.priorMeetingContext(for:).
    var calendarEventTitle: String?
    var recurringEventId: String?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        title: String,
        summary: String,
        keyPoints: [String],
        actionItems: [ActionItem],
        transcript: String,
        calendarEventTitle: String? = nil,
        recurringEventId: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.transcript = transcript
        self.calendarEventTitle = calendarEventTitle
        self.recurringEventId = recurringEventId
    }
}
