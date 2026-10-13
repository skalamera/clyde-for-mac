import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDraft: String = Settings.shared.anthropicAPIKey ?? ""
    @State private var geminiKeyDraft: String = Settings.shared.geminiAPIKey ?? ""
    @State private var calendarKeyDraft: String = Settings.shared.calendarAPIKey ?? ""
    @State private var servers: [MCPServerConfig] = MCPConfigStore.load()
    @State private var newServerName = ""
    @State private var newServerCommand = ""
    @State private var newServerArgs = ""
    @State private var newServerURL = ""
    @State private var newServerIsHTTP = false
    @State private var newServerRequiresOAuth = false
    @State private var newServerClientID = ""
    @State private var newServerClientSecret = ""
    @State private var connectedServers: Set<String> = []
    @State private var connectionErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clyde Settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Form {
                Section("Overlay") {
                    Toggle("Hide from screen shares & recordings", isOn: Binding(
                        get: { model.captureExclusionEnabled },
                        set: { model.setCaptureExclusionEnabled($0) }
                    ))
                    Text(model.captureExclusionEnabled
                         ? "The panel is invisible to Zoom, Meet, QuickTime, and screenshots — only you can see it."
                         : "⚠️ The panel is currently visible to screen shares, recordings, and screenshots. Turn this back on before your next meeting.")
                        .font(.caption2)
                        .foregroundStyle(model.captureExclusionEnabled ? Color.secondary : Color.orange)

                    HStack {
                        Text("Background opacity")
                        Slider(value: Binding(
                            get: { model.overlayOpacity },
                            set: { model.setOverlayOpacity($0) }
                        ), in: 0.3...1.0)
                        Text("\(Int(model.overlayOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("How see-through the panel's glass background is — text and buttons stay fully opaque. Updates live as you drag.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Toggle("Show screenshot button", isOn: Binding(
                        get: { Settings.shared.showScreenshotButton },
                        set: { Settings.shared.showScreenshotButton = $0 }
                    ))
                    Text("Adds a camera button to the panel header that saves a screenshot of the panel itself to Pictures/Clyde Screenshots and copies it to the clipboard.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("LLM Backend") {
                    Picker("Backend", selection: Binding(
                        get: { Settings.shared.preferredBackend },
                        set: { Settings.shared.preferredBackend = $0 }
                    )) {
                        ForEach(LLMBackendKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Text("Active backend: \(model.llmRouter.activeBackendDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Automatic prefers: Gemini > Anthropic > Claude Code CLI. \"Claude subscription\" uses the `claude` CLI's own sign-in (Pro/Team/Enterprise) — no API key needed, but replies arrive all-at-once (no streaming) and Clyde's MCP knowledge sources aren't available on that path.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section("Google Gemini") {
                    SecureField("API key (AIza…)", text: $geminiKeyDraft)
                    TextField("Model", text: Binding(
                        get: { Settings.shared.geminiModel },
                        set: { Settings.shared.geminiModel = $0 }
                    ))
                    HStack {
                        Button("Save") {
                            Settings.shared.geminiAPIKey = geminiKeyDraft
                        }
                        Button("Clear") {
                            geminiKeyDraft = ""
                            Settings.shared.geminiAPIKey = nil
                        }
                    }
                }

                Section("Anthropic API") {
                    SecureField("API key (sk-ant-…)", text: $apiKeyDraft)
                    HStack {
                        Button("Save") {
                            Settings.shared.anthropicAPIKey = apiKeyDraft
                        }
                        Button("Clear") {
                            apiKeyDraft = ""
                            Settings.shared.anthropicAPIKey = nil
                        }
                    }
                }

                Section("Calendar") {
                    TextField("API URL", text: Binding(
                        get: { Settings.shared.calendarAPIURL },
                        set: { Settings.shared.calendarAPIURL = $0 }
                    ))
                    TextField("Your email (which calendar is \"yours\")", text: Binding(
                        get: { Settings.shared.calendarSelfEmail },
                        set: { Settings.shared.calendarSelfEmail = $0 }
                    ))
                    SecureField("API key", text: $calendarKeyDraft)
                    HStack {
                        Button("Save") {
                            Settings.shared.calendarAPIKey = calendarKeyDraft
                            Task { await model.loadCalendarEvents() }
                        }
                        Button("Clear") {
                            calendarKeyDraft = ""
                            Settings.shared.calendarAPIKey = nil
                        }
                    }
                    Text("Powers the Meetings tab — the Hadrius CS calendar feed, not a direct Google login.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("Models") {
                    TextField("Proactive analysis model", text: Binding(
                        get: { Settings.shared.proactiveModel },
                        set: { Settings.shared.proactiveModel = $0 }
                    ))
                    TextField("Chat model", text: Binding(
                        get: { Settings.shared.chatModel },
                        set: { Settings.shared.chatModel = $0 }
                    ))
                    Toggle("Proactive suggestions", isOn: Binding(
                        get: { model.proactive.isEnabled },
                        set: { model.proactive.setEnabled($0) }
                    ))
                }

                Section("MCP Servers") {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(server.name).font(.system(size: 12, weight: .medium))
                                        if server.oauthEnabled {
                                            Text("OAuth").font(.system(size: 9, weight: .semibold))
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Capsule().fill(.blue.opacity(0.2)))
                                        }
                                    }
                                    Text(server.transport == .stdio ? (server.command ?? "") : (server.url?.absoluteString ?? ""))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { server.enabled },
                                    set: { newValue in
                                        if let index = servers.firstIndex(where: { $0.id == server.id }) {
                                            servers[index].enabled = newValue
                                            persistAndReload()
                                        }
                                    }
                                )).labelsHidden()
                                Button(role: .destructive) {
                                    servers.removeAll { $0.id == server.id }
                                    persistAndReload()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            if server.enabled {
                                if let error = connectionErrors[server.name] {
                                    Text("⚠️ \(error)").font(.system(size: 9)).foregroundStyle(.orange)
                                } else if connectedServers.contains(server.name) {
                                    Text("Connected").font(.system(size: 9)).foregroundStyle(.green)
                                } else {
                                    Text(server.oauthEnabled ? "Sign-in may be pending — check for a browser window." : "Connecting…")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add server").font(.caption.weight(.semibold))
                        TextField("Name", text: $newServerName)
                        Toggle("Remote (HTTP) server", isOn: $newServerIsHTTP)
                        if newServerIsHTTP {
                            TextField("https://…", text: $newServerURL)
                            Toggle("Requires sign-in (OAuth)", isOn: $newServerRequiresOAuth)
                            if newServerRequiresOAuth {
                                TextField("Client ID (optional — blank tries automatic registration)", text: $newServerClientID)
                                SecureField("Client secret (optional — only if the service issued one)", text: $newServerClientSecret)
                                Text("A system sign-in window opens the first time Clyde connects. Most services register a client automatically. A few (e.g. HubSpot) need you to register your own OAuth app with that service first and enter its client ID + secret here.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            TextField("Command (e.g. npx)", text: $newServerCommand)
                            TextField("Args (space-separated)", text: $newServerArgs)
                        }
                        Button("Add") { addServer() }
                            .disabled(newServerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 560)
        .task { await refreshConnectionStatus() }
    }

    private func addServer() {
        let config: MCPServerConfig
        if newServerIsHTTP {
            guard let url = URL(string: newServerURL) else { return }
            config = MCPServerConfig(
                name: newServerName, transport: .http, url: url,
                oauthEnabled: newServerRequiresOAuth,
                oauthClientID: newServerClientID.isEmpty ? nil : newServerClientID
            )
            if !newServerClientSecret.isEmpty {
                Keychain.set(newServerClientSecret, account: MCPManager.clientSecretAccount(for: newServerName))
            }
        } else {
            let args = newServerArgs.split(separator: " ").map(String.init)
            config = MCPServerConfig(name: newServerName, transport: .stdio, command: newServerCommand, args: args)
        }
        servers.append(config)
        newServerName = ""; newServerCommand = ""; newServerArgs = ""; newServerURL = ""
        newServerRequiresOAuth = false; newServerClientID = ""; newServerClientSecret = ""
        persistAndReload()
    }

    private func persistAndReload() {
        MCPConfigStore.save(servers)
        Task {
            await model.reloadMCPServers()
            await refreshConnectionStatus()
        }
    }

    private func refreshConnectionStatus() async {
        connectedServers = Set(await model.mcp.connectedServerNames)
        connectionErrors = await model.mcp.lastErrors
    }
}
