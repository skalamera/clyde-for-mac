import Foundation

/// Persists finished meeting-prep briefings to disk, keyed by calendar event id, so a brief
/// generated once is shown instantly on later launches instead of re-running the (slow,
/// multi-round) tool lookup. Only completed briefs are stored; in-flight/failed states are not.
/// Entries older than `maxAge` are pruned on load.
enum MeetingPrepStore {
    struct Entry: Codable {
        var brief: String
        var generatedAt: Date
    }

    private static let maxAge: TimeInterval = 60 * 60 * 24 * 30

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("meeting-preps.json")
    }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        return entries.filter { $0.value.generatedAt > cutoff }
    }

    static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
