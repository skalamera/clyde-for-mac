import Foundation

/// Fallback LLM backend for when the user has not configured an Anthropic API key: shells out
/// to a locally installed, already-authenticated `claude` CLI in headless mode.
///
/// This intentionally uses `--print --output-format json` (a single, complete JSON result)
/// rather than `--output-format stream-json`. The CLI's streaming line schema is an
/// implementation detail of Claude Code that isn't a documented public contract, whereas the
/// single-result JSON shape (`{"type":"result","is_error":Bool,"result":"<text>",...}`, verified
/// against a live `claude -p ... --output-format json` invocation) is stable and simple to
/// parse. The one user-visible cost is that this backend's replies arrive all-at-once rather
/// than token-by-token — acceptable for a fallback path.
///
/// This backend does not use Clyde's in-app MCP tool-use loop (`tools` is ignored) — instead,
/// Clyde's configured MCP servers are handed to the CLI itself via `--mcp-config`, regenerated
/// per request so OAuth-protected servers get whatever access token Clyde's own connections
/// most recently stored/refreshed. `--strict-mcp-config` keeps the CLI from also loading the
/// user's personal Claude Code MCP setup (which could be large and slow every request), and
/// `--allowedTools mcp__<server>` grants headless permission to each server's tools.
final class ClaudeCodeCLIBackend: LLMBackend, @unchecked Sendable {
    private let executableURL: URL?

    init() {
        self.executableURL = Self.locateCLI()
    }

    func stream(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool],
        model: String,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let executableURL else {
                        throw LLMError.cliUnavailable("`claude` executable not found on PATH or in common install locations.")
                    }

                    let prompt = Self.flattenPrompt(messages)
                    let process = Process()
                    process.executableURL = executableURL
                    var arguments = [
                        "-p", prompt,
                        "--append-system-prompt", system,
                        "--output-format", "json"
                    ]
                    if !model.isEmpty {
                        arguments += ["--model", model]
                    }
                    arguments += Self.mcpArguments()
                    process.arguments = arguments

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    let outputData = try stdout.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()

                    guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                        let errorData = try? stderr.fileHandleForReading.readToEnd()
                        let errorText = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? "no output"
                        throw LLMError.cliUnavailable("Unexpected output from claude CLI: \(errorText)")
                    }

                    let isError = json["is_error"] as? Bool ?? false
                    let result = json["result"] as? String ?? ""

                    if isError {
                        throw LLMError.cliUnavailable(result.isEmpty ? "claude CLI reported an error." : result)
                    }

                    continuation.yield(.textDelta(result))
                    continuation.yield(.messageComplete(stopReason: "end_turn"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// This backend has no first-class "messages" concept — it takes one prompt string — so the
    /// running conversation is flattened into a plain transcript-style prompt.
    private static func flattenPrompt(_ messages: [LLMMessage]) -> String {
        messages.map { message in
            let text = message.content.compactMap { content -> String? in
                switch content {
                case .text(let t): return t
                case .toolResult(let r): return "[tool result: \(r.content)]"
                case .toolUse: return nil
                }
            }.joined(separator: "\n")
            return "\(message.role.rawValue): \(text)"
        }.joined(separator: "\n\n")
    }

    /// Builds `--mcp-config`/`--strict-mcp-config`/`--allowedTools` arguments exposing Clyde's
    /// own MCP servers to the CLI. Regenerated on every request: OAuth access tokens rotate
    /// (Clyde's in-app connections refresh them), so the config must snapshot the *current*
    /// stored token, not one from launch time. An OAuth server whose token is missing is
    /// skipped — the CLI can't run Clyde's interactive browser login itself.
    private static func mcpArguments() -> [String] {
        var mcpServers: [String: Any] = [:]
        for config in MCPConfigStore.load() where config.enabled {
            switch config.transport {
            case .stdio:
                guard let command = config.command, !command.isEmpty else { continue }
                var entry: [String: Any] = ["command": command]
                if let args = config.args, !args.isEmpty { entry["args"] = args }
                if let env = config.env, !env.isEmpty { entry["env"] = env }
                mcpServers[config.name] = entry
            case .http:
                guard let url = config.url else { continue }
                var entry: [String: Any] = ["type": "http", "url": url.absoluteString]
                if config.oauthEnabled {
                    guard let accessToken = storedAccessToken(for: config.name) else {
                        Log.llm.info("CLI MCP passthrough: skipping '\(config.name, privacy: .public)' — no stored OAuth token yet.")
                        continue
                    }
                    entry["headers"] = ["Authorization": "Bearer \(accessToken)"]
                }
                mcpServers[config.name] = entry
            }
        }
        guard !mcpServers.isEmpty else { return [] }

        // Same directory + permissions as secrets.json — the config embeds bearer tokens.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let configURL = base.appendingPathComponent("cli-mcp.json")
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": mcpServers]) else { return [] }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            Log.llm.error("CLI MCP passthrough: failed to write cli-mcp.json: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let allowedTools = mcpServers.keys.sorted().map { "mcp__\($0)" }.joined(separator: ",")
        return ["--mcp-config", configURL.path, "--strict-mcp-config", "--allowedTools", allowedTools]
    }

    /// Reads the access token Clyde's own OAuth flow stored for `serverName` (see
    /// `FileTokenStorage` — a JSON blob whose `value` field is the bearer token).
    private static func storedAccessToken(for serverName: String) -> String? {
        guard let raw = Keychain.get(account: "mcp-oauth-token-\(serverName)"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func locateCLI() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to resolving via the user's shell PATH.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    var isAvailable: Bool { executableURL != nil }
}
