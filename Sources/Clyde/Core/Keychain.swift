import Foundation

/// Stores small secrets (API keys) for Clyde.
///
/// This was originally a macOS Keychain (Security framework) wrapper. In practice, on a Mac
/// whose "login" keychain password has drifted out of sync with the account password (a common
/// state after an account password reset), *every* Keychain read triggers a blocking OS
/// password prompt that the account password can't satisfy — there is no way for an app to work
/// around that from within Keychain Services, and walking a user through resetting their login
/// keychain is a destructive, machine-wide change well outside what a meeting-copilot app should
/// ask for. So this stores secrets in a plain file instead, at
/// `~/Library/Application Support/Clyde/secrets.json`, permissioned `0600` (readable/writable
/// only by the current user) — the same trust model most CLI tools use for local credentials
/// (e.g. `~/.aws/credentials`, `~/.netrc`). It is not encrypted at rest beyond whatever disk
/// encryption (FileVault) the Mac already has, which is a deliberate trade-off for something
/// that "just works" regardless of the host's keychain health.
enum Keychain {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("secrets.json")
    }

    static func set(_ value: String, account: String) {
        var secrets = readAll()
        secrets[account] = value
        write(secrets)
    }

    static func get(account: String) -> String? {
        readAll()[account]
    }

    static func remove(account: String) {
        var secrets = readAll()
        secrets.removeValue(forKey: account)
        write(secrets)
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return secrets
    }

    private static func write(_ secrets: [String: String]) {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.app.error("Failed to write secrets file: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum Account {
        static let anthropicAPIKey = "anthropic-api-key"
        static let geminiAPIKey = "gemini-api-key"
        static let calendarAPIKey = "cs-calendar-api-key"
    }
}
