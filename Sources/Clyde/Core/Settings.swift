import Foundation
import Observation

/// Which model tier to use for a given purpose. Kept as raw strings (not an enum of fixed
/// cases) because Anthropic model IDs change over time and there is no official Swift SDK
/// to source constants from — see LLM/AnthropicClient.swift.
@Observable
final class Settings: @unchecked Sendable {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    var proactiveModel: String {
        didSet { defaults.set(proactiveModel, forKey: "proactiveModel") }
    }
    var chatModel: String {
        didSet { defaults.set(chatModel, forKey: "chatModel") }
    }
    var proactiveEnabled: Bool {
        didSet { defaults.set(proactiveEnabled, forKey: "proactiveEnabled") }
    }
    var preferredBackend: LLMBackendKind {
        didSet { defaults.set(preferredBackend.rawValue, forKey: "preferredBackend") }
    }
    var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    var locale: String {
        didSet { defaults.set(locale, forKey: "locale") }
    }
    /// Single model used for both chat and proactive analysis when Gemini is the active
    /// backend — unlike the Anthropic path, there's no fast/cheap-vs-quality split configured
    /// yet, since Gemini Flash-tier models are already cheap enough for both purposes.
    var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: "geminiModel") }
    }
    /// Whether the overlay panel is excluded from screen capture/sharing/recording. Defaults to
    /// true (the whole point of the app); exposed as a toggle so the user can turn it off when
    /// they specifically want to screenshot or record the panel itself, e.g. for troubleshooting.
    var captureExclusionEnabled: Bool {
        didSet { defaults.set(captureExclusionEnabled, forKey: "captureExclusionEnabled") }
    }
    /// Whether the panel's header shows the camera button for screenshotting the panel's own
    /// contents (saved to disk + copied to the clipboard) — separate from the capture-exclusion
    /// toggle above, since this is about deliberately capturing the panel yourself, not about
    /// whether screen shares/recordings can see it.
    var showScreenshotButton: Bool {
        didSet { defaults.set(showScreenshotButton, forKey: "showScreenshotButton") }
    }
    /// Base URL for the Hadrius CS calendar feed proxy (not the direct Google Calendar API) —
    /// see Engine/CalendarClient.swift.
    var calendarAPIURL: String {
        didSet { defaults.set(calendarAPIURL, forKey: "calendarAPIURL") }
    }
    /// Which calendar (by email) in the feed's multi-person response is "mine" — the feed
    /// returns every csteam@hadrius.com member's events in one call, so this is what actually
    /// scopes the Meetings tab to just the user's own meetings.
    var calendarSelfEmail: String {
        didSet { defaults.set(calendarSelfEmail, forKey: "calendarSelfEmail") }
    }

    private init() {
        proactiveModel = defaults.string(forKey: "proactiveModel") ?? "claude-haiku-4-5"
        chatModel = defaults.string(forKey: "chatModel") ?? "claude-sonnet-5"
        proactiveEnabled = defaults.object(forKey: "proactiveEnabled") as? Bool ?? true
        preferredBackend = LLMBackendKind(rawValue: defaults.string(forKey: "preferredBackend") ?? "") ?? .auto
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 0.92
        locale = defaults.string(forKey: "locale") ?? Locale.current.identifier
        geminiModel = defaults.string(forKey: "geminiModel") ?? "gemini-3.7-flash"
        captureExclusionEnabled = defaults.object(forKey: "captureExclusionEnabled") as? Bool ?? true
        showScreenshotButton = defaults.object(forKey: "showScreenshotButton") as? Bool ?? true
        calendarAPIURL = defaults.string(forKey: "calendarAPIURL") ?? "https://product.hadrius.com"
        calendarSelfEmail = defaults.string(forKey: "calendarSelfEmail") ?? "stephen@hadrius.com"
    }

    var anthropicAPIKey: String? {
        get { Keychain.get(account: Keychain.Account.anthropicAPIKey) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, account: Keychain.Account.anthropicAPIKey)
            } else {
                Keychain.remove(account: Keychain.Account.anthropicAPIKey)
            }
        }
    }

    var geminiAPIKey: String? {
        get { Keychain.get(account: Keychain.Account.geminiAPIKey) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, account: Keychain.Account.geminiAPIKey)
            } else {
                Keychain.remove(account: Keychain.Account.geminiAPIKey)
            }
        }
    }

    var calendarAPIKey: String? {
        get { Keychain.get(account: Keychain.Account.calendarAPIKey) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, account: Keychain.Account.calendarAPIKey)
            } else {
                Keychain.remove(account: Keychain.Account.calendarAPIKey)
            }
        }
    }
}

enum LLMBackendKind: String, CaseIterable, Sendable, Identifiable {
    /// Pick automatically by what's configured: Gemini key > Anthropic key > Claude CLI.
    case auto
    case gemini
    case anthropicAPI
    /// The local `claude` CLI — uses whatever that CLI is signed in as (e.g. a Claude
    /// Pro/Team/Enterprise subscription), no API key involved.
    case claudeCodeCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .gemini: return "Google Gemini"
        case .anthropicAPI: return "Anthropic API"
        case .claudeCodeCLI: return "Claude subscription (via Claude Code CLI)"
        }
    }
}
