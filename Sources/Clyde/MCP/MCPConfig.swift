import Foundation

/// One configured MCP server. Shape intentionally mirrors the widely-used
/// `claude_desktop_config.json` / `.mcp.json` convention (command + args + env for stdio
/// servers) so users can paste in configs they already have, plus a `url` variant for
/// streamable-HTTP servers.
struct MCPServerConfig: Codable, Identifiable, Sendable, Equatable {
    enum Transport: String, Codable, Sendable {
        case stdio
        case http
    }

    var id: String { name }
    var name: String
    var transport: Transport
    var command: String? = nil
    var args: [String]? = nil
    var env: [String: String]? = nil
    var url: URL? = nil
    var enabled: Bool = true

    /// Whether this (necessarily `.http`) server requires an interactive OAuth 2.1 login —
    /// e.g. an internal company MCP server like Hadrius's, rather than a static API key.
    /// Handled via the MCP Swift SDK's built-in OAuth client (PKCE, RFC 9728/8414 discovery,
    /// RFC 7591 dynamic client registration) — see MCP/OAuthSupport.swift.
    var oauthEnabled: Bool = false

    /// Pre-registered OAuth client ID, if the server's auth setup requires one rather than
    /// supporting Dynamic Client Registration (RFC 7591). Leave blank to rely on DCR.
    var oauthClientID: String? = nil

    init(
        name: String,
        transport: Transport,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: URL? = nil,
        enabled: Bool = true,
        oauthEnabled: Bool = false,
        oauthClientID: String? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.enabled = enabled
        self.oauthEnabled = oauthEnabled
        self.oauthClientID = oauthClientID
    }

    // Manual Decodable (rather than relying on synthesis) so that older saved `mcp.json` files
    // written before a field like `oauthEnabled` existed still decode cleanly with sensible
    // defaults, instead of failing to decode the whole server list over one missing key.
    private enum CodingKeys: String, CodingKey {
        case name, transport, command, args, env, url, enabled, oauthEnabled, oauthClientID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(Transport.self, forKey: .transport)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        oauthEnabled = try container.decodeIfPresent(Bool.self, forKey: .oauthEnabled) ?? false
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID)
    }
}

/// Loads/saves the list of configured MCP servers from `~/Library/Application Support/Clyde/mcp.json`.
enum MCPConfigStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clyde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mcp.json")
    }

    /// Servers Clyde ships with out of the box. Both require interactive OAuth login; no
    /// pre-registered client ID is known for either, so Dynamic Client Registration is
    /// attempted first — if a server's auth setup doesn't support DCR, the user will need to
    /// supply a client ID in Settings. Vitally's server was confirmed (via its
    /// `WWW-Authenticate`/discovery metadata) to advertise a registration_endpoint and
    /// `token_endpoint_auth_methods_supported: ["none"]`, so DCR should just work.
    private static let defaults: [MCPServerConfig] = [
        MCPServerConfig(
            name: "hadrius-codebase",
            transport: .http,
            url: URL(string: "https://mcp.hadriusapi.com/codebase"),
            enabled: true,
            oauthEnabled: true
        ),
        MCPServerConfig(
            name: "vitally",
            transport: .http,
            url: URL(string: "https://mcp.vitally.io/mcp/readonly/v0"),
            enabled: true,
            oauthEnabled: true
        ),
        MCPServerConfig(
            name: "pylon",
            transport: .http,
            url: URL(string: "https://mcp.usepylon.com"),
            enabled: true,
            oauthEnabled: true
        ),
        MCPServerConfig(
            name: "sybill",
            transport: .http,
            url: URL(string: "https://mcp.sybill.ai/mcp"),
            enabled: true,
            oauthEnabled: true
        ),
        MCPServerConfig(
            name: "linear",
            transport: .http,
            url: URL(string: "https://mcp.linear.app/mcp"),
            enabled: true,
            oauthEnabled: true
        ),
        MCPServerConfig(
            name: "notion",
            transport: .http,
            url: URL(string: "https://mcp.notion.com/mcp"),
            enabled: true,
            oauthEnabled: true
        ),
        // Disabled by default: HubSpot's server has no dynamic client registration endpoint and
        // requires a confidential client, so it needs a client ID + secret from an OAuth app the
        // user registers themselves in HubSpot's developer portal (their own admin access —
        // Clyde can't do this step) before it can connect at all. Enable it in Settings once
        // those are entered.
        MCPServerConfig(
            name: "hubspot",
            transport: .http,
            url: URL(string: "https://mcp.hubspot.com"),
            enabled: false,
            oauthEnabled: true
        )
    ]

    static func load() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: fileURL) else {
            save(defaults)
            return defaults
        }
        return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? defaults
    }

    static func save(_ servers: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
