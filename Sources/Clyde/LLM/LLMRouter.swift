import Foundation

enum ModelPurpose {
    case chat
    case proactive
}

/// Picks which concrete backend actually handles a request. An explicit backend selected in
/// Settings always wins (falling back only if it isn't usable at all — no key / CLI missing);
/// "Automatic" preserves the original preference order:
///   1. Google Gemini, if a Gemini API key is configured.
///   2. The direct Anthropic API, if an Anthropic API key is configured.
///   3. The local Claude Code CLI, so the app is still useful with zero API-key setup for
///      anyone who already has Claude Code installed and signed in — including using a Claude
///      Pro/Team/Enterprise subscription (the CLI's own login) instead of any API key.
///
/// Model *names* are backend-specific (Anthropic's `claude-sonnet-5` vs Gemini's
/// `gemini-2.5-flash`), so callers must not hardcode a model string themselves — they ask
/// `effectiveModel(for:)` for whichever one matches the currently-active backend, then pass
/// that into `stream(model:)`.
final class LLMRouter: LLMBackend, @unchecked Sendable {
    private let gemini: GeminiClient
    private let anthropic: AnthropicClient
    private let cli: ClaudeCodeCLIBackend

    init(gemini: GeminiClient = GeminiClient(), anthropic: AnthropicClient = AnthropicClient(), cli: ClaudeCodeCLIBackend = ClaudeCodeCLIBackend()) {
        self.gemini = gemini
        self.anthropic = anthropic
        self.cli = cli
    }

    private enum ActiveBackend { case gemini, anthropic, claudeCLI, unconfigured }

    private var activeBackend: ActiveBackend {
        switch Settings.shared.preferredBackend {
        case .gemini where Settings.shared.geminiAPIKey?.isEmpty == false:
            return .gemini
        case .anthropicAPI where Settings.shared.anthropicAPIKey?.isEmpty == false:
            return .anthropic
        case .claudeCodeCLI where cli.isAvailable:
            return .claudeCLI
        default:
            // "Automatic", or the forced backend isn't usable (missing key / CLI not installed).
            if Settings.shared.geminiAPIKey?.isEmpty == false { return .gemini }
            if Settings.shared.anthropicAPIKey?.isEmpty == false { return .anthropic }
            if cli.isAvailable { return .claudeCLI }
            return .unconfigured
        }
    }

    var activeBackendDescription: String {
        switch activeBackend {
        case .gemini: return "Google Gemini"
        case .anthropic: return "Anthropic API"
        case .claudeCLI: return "Claude Code CLI (uses the CLI's own sign-in, e.g. a Claude subscription)"
        case .unconfigured: return "Unconfigured"
        }
    }

    func effectiveModel(for purpose: ModelPurpose) -> String {
        switch activeBackend {
        case .gemini:
            return Settings.shared.geminiModel
        case .anthropic:
            return purpose == .chat ? Settings.shared.chatModel : Settings.shared.proactiveModel
        case .claudeCLI:
            // Passed to the CLI as `--model` — the Anthropic model names in Settings are valid
            // CLI model arguments too.
            return purpose == .chat ? Settings.shared.chatModel : Settings.shared.proactiveModel
        case .unconfigured:
            return ""
        }
    }

    func stream(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        switch activeBackend {
        case .gemini:
            return gemini.stream(system: system, messages: messages, tools: tools, model: model, options: options)
        case .anthropic:
            return anthropic.stream(system: system, messages: messages, tools: tools, model: model, options: options)
        case .claudeCLI:
            return cli.stream(system: system, messages: messages, tools: tools, model: model, options: options)
        case .unconfigured:
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LLMError.notConfigured)
            }
        }
    }
}
