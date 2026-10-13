import Foundation

enum CalendarViewMode: String, CaseIterable, Sendable {
    case list = "Upcoming"
    case month = "Month"
}

struct CalendarAttendee: Sendable, Equatable {
    var email: String
    var displayName: String?
    var responseStatus: String?
    var isSelf: Bool
}

/// One event from the user's own Google Calendar, via the Hadrius CS calendar feed proxy —
/// see CalendarClient.swift. Only events on the user's own `calendarId` are kept; the feed
/// itself returns every csteam@hadrius.com member's calendar in one call.
struct CalendarEvent: Sendable, Equatable, Identifiable {
    var id: String
    var iCalUID: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var organizer: String?
    var attendees: [CalendarAttendee]
    /// Present when this event is one occurrence of a recurring series — used to recognize
    /// "this is the same standing meeting as before" across weeks. Not guaranteed to be stable
    /// for every recurring series in this feed, so title matching is used as a fallback/primary
    /// signal alongside it — see AppModel.priorMeetingContext(for:).
    var recurringEventId: String?
    /// The event's body/agenda text. NOTE: the Hadrius CS calendar feed currently strips this
    /// field server-side (confirmed against a live 529-event response — zero carried the key),
    /// so this is nil until the proxy starts passing Google's `description` through; decoding
    /// is already wired so it lights up automatically when that happens.
    var description: String?

    var externalAttendees: [CalendarAttendee] {
        attendees.filter { attendee in
            let email = attendee.email.lowercased()
            return !attendee.isSelf && !email.hasSuffix("@hadrius.com")
        }
    }
}
