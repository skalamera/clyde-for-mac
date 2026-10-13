import Foundation

/// Persists user-written meeting descriptions, keyed either to one calendar-event occurrence
/// or to a whole recurring series. Exists because the calendar feed can't be written to (and
/// currently doesn't even pass Google's own description field through) — this is Clyde's local
/// place for "what this meeting is about", feeding the Prep briefing and prefilling the
/// start-meeting context modal.
///
/// Keys: `event:<eventID>` for a single occurrence, `series:<recurringEventId>` for every
/// occurrence of a recurring meeting. An occurrence-specific entry wins over a series entry.
enum EventDescriptionStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("event-descriptions.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ descriptions: [String: String]) {
        guard let data = try? JSONEncoder().encode(descriptions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func eventKey(for event: CalendarEvent) -> String { "event:\(event.id)" }

    static func seriesKey(for event: CalendarEvent) -> String? {
        guard let seriesID = event.recurringEventId, !seriesID.isEmpty else { return nil }
        return "series:\(seriesID)"
    }
}
