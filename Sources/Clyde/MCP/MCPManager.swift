import Foundation
import MCP
import System

/// Owns every configured MCP server connection: spawns local stdio servers (arbitrary
/// `npx`/`uvx`/binary commands, same as Claude Desktop's `mcp.json` convention), connects to
/// remote streamable-HTTP servers, and exposes their tools to the LLM layer as `LLMTool`s.
///
/// The Anthropic API's own MCP connector cannot reach local stdio servers (Anthropic's servers
/// dial a URL; localhost is unreachable to them), so this in-app client bridge is what makes
/// local MCP servers usable at all — this is the only path for e.g. a filesystem or local-DB
/// MCP server the user runs on their own Mac.
actor MCPManager {
    private struct Connection {
        var config: MCPServerConfig
        var client: Client
        var process: Process?
        var tools: [Tool]
    }

    private var connections: [String: Connection] = [:]

    /// Last connection failure per server name, surfaced in Settings so an OAuth login that
    /// failed/was dismissed (or a bad URL/command) isn't a silent failure the user only finds
    /// out about by noticing the model never gets that tool.
    private(set) var lastErrors: [String: String] = [:]

    /// Connects to every enabled server in `configs`, concurrently and best-effort. Concurrency
    /// matters specifically for OAuth-protected servers: connecting is what triggers the
    /// interactive browser login, which blocks until the user completes it (or it fails) — if
    /// servers were connected one at a time, one unfinished login would prevent every other
    /// configured server from even being attempted, let alone connecting, for the entire
    /// duration. A bad command/unreachable URL for one server still never prevents others from
    /// working.
    func reload(_ configs: [MCPServerConfig]) async {
        await disconnectAll()
        await withTaskGroup(of: Void.self) { group in
            for config in configs where config.enabled {
                group.addTask { await self.connectAndRecordResult(config) }
            }
        }
    }

    private func connectAndRecordResult(_ config: MCPServerConfig) async {
        do {
            try await connect(config)
            lastErrors.removeValue(forKey: config.name)
        } catch {
            lastErrors[config.name] = error.localizedDescription
            Log.mcp.error("Failed to connect MCP server '\(config.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(_ config: MCPServerConfig) async throws {
        let client = Client(name: "Clyde", version: "0.1.0")
        var process: Process?

        switch config.transport {
        case .stdio:
            guard let command = config.command, !command.isEmpty else {
                throw MCPManagerError.invalidConfig("'\(config.name)' has no command configured.")
            }
            let launched = Process()
            let (executable, prefixArgs) = Self.resolveExecutable(command)
            launched.executableURL = executable
            launched.arguments = prefixArgs + (config.args ?? [])
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in config.env ?? [:] { environment[key] = value }
            launched.environment = environment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            launched.standardInput = stdinPipe
            launched.standardOutput = stdoutPipe
            launched.standardError = Pipe() // swallow stderr chatter; surfaced via terminationHandler on crash

            try launched.run()
            process = launched

            // From Clyde's point of view: we WRITE to the server's stdin, and READ from the
            // server's stdout — i.e. the opposite ends of the two pipes from the child process.
            let transport = StdioTransport(
                input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
            )
            try await client.connect(transport: transport)

        case .http:
            guard let url = config.url else {
                throw MCPManagerError.invalidConfig("'\(config.name)' has no URL configured.")
            }
            let authorizer: (any HTTPClientAuthorizer)? = config.oauthEnabled ? Self.makeOAuthAuthorizer(for: config) : nil
            let transport = HTTPClientTransport(endpoint: url, authorizer: authorizer)
            try await client.connect(transport: transport)
        }

        let (tools, _) = try await client.listTools()
        connections[config.name] = Connection(config: config, client: client, process: process, tools: tools)
        Log.mcp.info("Connected MCP server '\(config.name, privacy: .public)' — \(tools.count) tool(s).")
    }

    func disconnect(_ name: String) async {
        guard let connection = connections.removeValue(forKey: name) else { return }
        await connection.client.disconnect()
        connection.process?.terminate()
    }

    func disconnectAll() async {
        for name in connections.keys {
            await disconnect(name)
        }
    }

    /// All tools across all connected servers, mapped to Anthropic's tool schema and
    /// deterministically sorted (see `AnthropicClient` — sorted tool order keeps the prompt
    /// cache prefix stable across turns).
    var allTools: [LLMTool] {
        connections.values
            .flatMap { connection in connection.tools.map { ToolBridge.llmTool(from: $0, server: connection.config.name) } }
            .sorted { $0.name < $1.name }
    }

    var connectedServerNames: [String] {
        Array(connections.keys).sorted()
    }

    func callTool(toolUseID: String, qualifiedName: String, arguments: JSONValue) async -> LLMToolResult {
        guard let (serverName, toolName) = ToolBridge.split(qualifiedName: qualifiedName),
              let connection = connections[serverName] else {
            return LLMToolResult(toolUseID: toolUseID, content: "No such tool: \(qualifiedName)", isError: true)
        }

        let mcpArguments: [String: Value]?
        if case .object(let dict) = arguments {
            mcpArguments = dict.mapValues(ToolBridge.jsonToValue)
        } else {
            mcpArguments = nil
        }

        do {
            let (content, isError) = try await connection.client.callTool(name: toolName, arguments: mcpArguments)
            return LLMToolResult(toolUseID: toolUseID, content: ToolBridge.displayText(for: content), isError: isError ?? false)
        } catch {
            return LLMToolResult(toolUseID: toolUseID, content: "Tool call failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Resolves a bare command name (e.g. "npx") against common install locations first, since
    /// a GUI-launched app does not inherit the user's interactive shell PATH. Falls back to
    /// `/usr/bin/env <command>` (which does a PATH search at exec time) if not found anywhere
    /// we checked, rather than failing outright.
    private static func resolveExecutable(_ command: String) -> (executable: URL, prefixArgs: [String]) {
        if command.hasPrefix("/") { return (URL(fileURLWithPath: command), []) }
        let searchPaths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.nvm/current/bin"
        ]
        for dir in searchPaths {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return (URL(fileURLWithPath: candidate), [])
            }
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [command])
    }

    /// Builds an OAuth 2.1 authorizer (authorization_code + PKCE) for an OAuth-protected HTTP
    /// MCP server, using the SDK's built-in discovery/registration/refresh machinery.
    ///
    /// Most servers (confirmed for Hadrius, Vitally, Pylon, Sybill, Linear, Notion) advertise a
    /// `registration_endpoint` and accept `token_endpoint_auth_method: none`, so leaving
    /// `oauthClientID` unset lets Dynamic Client Registration (RFC 7591) get a public client
    /// automatically — no setup needed. A few (confirmed for HubSpot) don't support DCR at all
    /// and require a confidential client instead: the user has to register their own OAuth app
    /// with that service (outside Clyde entirely — it needs their own admin access to that
    /// service) to get a client ID + secret, then enter both in Settings. The secret, if any, is
    /// stored via `Keychain` (same permissioned local file as the API keys), keyed per server —
    /// never inline in `mcp.json`.
    private static func makeOAuthAuthorizer(for config: MCPServerConfig) -> OAuthAuthorizer {
        // No `authorizationRedirectURI` override: OAuth 2.1 (correctly, per RFC 8252 §7.3)
        // rejects custom URL schemes as redirect targets for native apps, so this relies on the
        // SDK's own default — a randomly-ported `http://127.0.0.1:<port>/callback` loopback URI —
        // which `BrowserOAuthDelegate` listens on directly. See its doc comment for why.
        let storage = FileTokenStorage(serverName: config.name)
        // Seed the authorizer with the client ID that Dynamic Client Registration obtained in a
        // PRIOR app session (persisted alongside the token). The SDK's refresh-token request
        // authenticates with `configuration.authentication` only — it never reads the stored
        // token's clientID — so without this seed, every fresh authorizer sends refresh grants
        // with no client_id. Some servers tolerate that; Pylon rejects it (HTTP 400, confirmed
        // by a direct token-endpoint test: refresh succeeds with client_id, fails without),
        // which made the SDK fall back to an interactive browser login on every single launch.
        let clientID = config.oauthClientID?.isEmpty == false
            ? config.oauthClientID!
            : (storage.load()?.clientID ?? "")
        let clientSecret = Keychain.get(account: Self.clientSecretAccount(for: config.name))

        let authentication: OAuthConfiguration.TokenEndpointAuthentication
        if let clientSecret, !clientSecret.isEmpty, !clientID.isEmpty {
            authentication = .clientSecretPost(clientID: clientID, clientSecret: clientSecret)
        } else {
            authentication = .none(clientID: clientID)
        }

        let oauthConfig = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: authentication,
            clientName: "Clyde",
            authorizationDelegate: BrowserOAuthDelegate()
        )
        return OAuthAuthorizer(configuration: oauthConfig, tokenStorage: storage)
    }

    static func clientSecretAccount(for serverName: String) -> String {
        "mcp-oauth-client-secret-\(serverName)"
    }
}

enum MCPManagerError: Error, CustomStringConvertible, LocalizedError {
    case invalidConfig(String)
    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .invalidConfig(let reason): return reason
        }
    }
}
