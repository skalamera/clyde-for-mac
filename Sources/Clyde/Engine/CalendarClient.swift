import Foundation

/// Client for the Hadrius CS calendar feed — an internal proxy (NOT the direct Google Calendar
/// API) that reads Google Calendar server-side for every member of csteam@hadrius.com in one
/// authenticated call. Response/behavior confirmed against a live request during development:
///   - `GET {baseURL}/api/cs-calendar/events?timeMin=...&timeMax=...`, `Authorization: Bearer
///     <key>`. ISO 8601 timestamps for the window.
///   - Response: `{"group", "window", "memberCount", "members", "excluded", "eventCount",
///     "events": [...], "errors": []}`. Each event has `calendarId` (whose calendar it came
///     from), `id`, `iCalUID`, `status`, `summary`, `start`/`end` (ISO 8601 with offset, or a
///     plain "YYYY-MM-DD" for all-day events), `allDay`, `organizer`, `creator`, `attendees`
///     (each with `email`, `displayName`, `responseStatus`, `organizer`, `optional`, `self`).
///   - The SAME meeting appears once per CS-team attendee's calendar — filtering to a single
///     `calendarId` (the user's own) is what makes this "my meetings" rather than the whole
///     team's, with no need for the iCalUID de-duplication the wider feed would require.
///   - A 207 response means partial success (some calendars failed) — still has a usable body.
///   - Cancelled/private/non-meeting events are already filtered server-side.
struct CalendarClient {
    let baseURL: String
    let apiKey: String

    /// Fetches events on `selfEmail`'s own calendar within a window around now, sorted
    /// soonest-first, excluding all-day events and ones the user has declined — for the flat
    /// "upcoming meetings" list.
    func fetchMyUpcomingEvents(
        selfEmail: String,
        lookbackHours: Double = 2,
        horizonDays: Int = 7
    ) async throws -> [CalendarEvent] {
        let now = Date()
        let events = try await fetchEvents(
            selfEmail: selfEmail,
            timeMin: now.addingTimeInterval(-lookbackHours * 3600),
            timeMax: now.addingTimeInterval(Double(horizonDays) * 86400)
        )
        return events
            .filter { event in
                !event.allDay && event.end > now.addingTimeInterval(-lookbackHours * 3600)
                    && !(event.attendees.first(where: \.isSelf)?.responseStatus == "declined")
            }
            .sorted { $0.start < $1.start }
    }

    /// Fetches every event on `selfEmail`'s own calendar within an explicit date range —
    /// including all-day events and declined ones — for the month-grid view, which should show
    /// everything on the calendar for a given day rather than a curated subset.
    func fetchEvents(selfEmail: String, timeMin: Date, timeMax: Date) async throws -> [CalendarEvent] {
        guard var components = URLComponents(string: baseURL + "/api/cs-calendar/events") else {
            throw CalendarClientError.invalidURL
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: isoFormatter.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: isoFormatter.string(from: timeMax))
        ]
        guard let url = components.url else { throw CalendarClientError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 // the server reads many calendars per call

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarClientError.unreachable
        }
        // 207 (partial success — some calendars failed) still carries a usable body; only treat
        // genuine error statuses as failures.
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            let message = (try? JSONDecoder().decode(RawErrorResponse.self, from: data).error) ?? "HTTP \(http.statusCode)"
            throw CalendarClientError.server(http.statusCode, message)
        }

        let feed = try JSONDecoder().decode(RawFeedResponse.self, from: data)
        return feed.events
            .filter { $0.calendarId.lowercased() == selfEmail.lowercased() }
            .compactMap(Self.toCalendarEvent)
            .sorted { $0.start < $1.start }
    }

    private static func toCalendarEvent(_ raw: RawEvent) -> CalendarEvent? {
        guard let start = parseEventDate(raw.start), let end = parseEventDate(raw.end) else { return nil }
        return CalendarEvent(
            id: raw.id,
            iCalUID: raw.iCalUID,
            title: (raw.summary?.isEmpty == false ? raw.summary! : nil) ?? "(No title)",
            start: start,
            end: end,
            allDay: raw.allDay,
            organizer: raw.organizer,
            attendees: (raw.attendees ?? []).compactMap { attendee in
                guard let email = attendee.email, !email.isEmpty else { return nil }
                return CalendarAttendee(
                    email: email,
                    displayName: attendee.displayName,
                    responseStatus: attendee.responseStatus,
                    isSelf: attendee.isSelf ?? false
                )
            },
            recurringEventId: raw.recurringEventId,
            description: raw.description?.isEmpty == false ? raw.description : nil
        )
    }

    /// ISO 8601 with a time/offset for timed events; a plain "YYYY-MM-DD" for all-day ones.
    private static func parseEventDate(_ value: String) -> Date? {
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: value)
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value)
    }
}

// MARK: - Wire format

private struct RawFeedResponse: Decodable {
    var events: [RawEvent]
}

private struct RawEvent: Decodable {
    var calendarId: String
    var id: String
    var iCalUID: String
    var summary: String?
    var start: String
    var end: String
    var allDay: Bool
    var organizer: String?
    var recurringEventId: String?
    var description: String?
    var attendees: [RawAttendee]?
}

private struct RawAttendee: Decodable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus
        case isSelf = "self"
    }
}

private struct RawErrorResponse: Decodable {
    var error: String?
}

enum CalendarClientError: Error, LocalizedError {
    case invalidURL
    case unreachable
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid calendar API URL."
        case .unreachable: return "Could not reach the calendar feed."
        case .server(let code, let message): return "Calendar feed error (\(code)): \(message)"
        }
    }
}
