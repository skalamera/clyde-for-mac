import Foundation

/// Loads/saves past meeting summaries from `~/Library/Application Support/Clyde/notes.json` —
/// same directory/convention as `MCPConfigStore`. Kept as a flat JSON array (not a database)
/// since meeting-note volume for a single user is small and this needs no querying beyond
/// "show me everything, newest first," which the UI already does by reversing the array.
enum MeetingNotesStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notes.json")
    }

    static func load() -> [MeetingNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MeetingNote].self, from: data)) ?? []
    }

    static func save(_ notes: [MeetingNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
