import Foundation
import AppKit
import Network
import MCP

/// Persists an MCP server's OAuth access/refresh token in Clyde's local secrets file, keyed per
/// server so multiple OAuth-protected MCP servers don't clobber each other's tokens. Backed by
/// the same store as the Anthropic/Gemini API keys (see Core/Keychain.swift) — a permissioned
/// local file rather than the system Keychain, for the same reason: it must work regardless of
/// the host Mac's login-keychain health.
final class FileTokenStorage: TokenStorage, @unchecked Sendable {
    private let account: String

    init(serverName: String) {
        self.account = "mcp-oauth-token-\(serverName)"
    }

    func save(_ token: OAuthAccessToken) {
        guard let data = try? JSONEncoder().encode(token),
              let string = String(data: data, encoding: .utf8) else { return }
        Keychain.set(string, account: account)
    }

    func load() -> OAuthAccessToken? {
        guard let string = Keychain.get(account: account),
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthAccessToken.self, from: data)
    }

    func clear() {
        Keychain.remove(account: account)
    }
}

enum OAuthDelegateError: Error, LocalizedError {
    case cancelled
    case invalidRedirectURI(String)
    case listenerFailed(String)
    case malformedCallbackRequest

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The sign-in flow was cancelled or timed out."
        case .invalidRedirectURI(let uri): return "Unusable OAuth redirect URI: \(uri)"
        case .listenerFailed(let reason): return "Could not start local sign-in listener: \(reason)"
        case .malformedCallbackRequest: return "Sign-in redirect could not be understood."
        }
    }
}

/// Drives the user-facing half of an MCP server's OAuth login. OAuth 2.1 (correctly) rejects
/// custom URL schemes as unsafe redirect targets for native apps — only `https` or loopback
/// `http://127.0.0.1:<port>/...` are accepted (RFC 8252 §7.3), which the MCP SDK's authorizer
/// enforces. That rules out `ASWebAuthenticationSession`'s usual custom-scheme callback
/// interception, so this instead opens the authorization URL in the user's actual default
/// browser (so it behaves like signing into any other web app, and reuses existing login
/// sessions/cookies) and runs a one-shot local TCP listener bound to loopback on the exact port
/// the SDK generated for `redirect_uri`, to catch that single incoming redirect directly.
final class BrowserOAuthDelegate: NSObject, OAuthAuthorizationDelegate, @unchecked Sendable {
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirectURIString = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirectURI = URL(string: redirectURIString),
              let host = redirectURI.host,
              let port = redirectURI.port else {
            throw OAuthDelegateError.invalidRedirectURI("(missing redirect_uri in authorization URL)")
        }

        // Start listening before opening the browser, so the redirect can never arrive before
        // something is there to catch it.
        let listener = try Self.makeListener(host: host, port: port)
        do {
            let callbackURL = try await Self.awaitCallback(on: listener, host: host, port: port) {
                guard NSWorkspace.shared.open(url) else {
                    throw OAuthDelegateError.listenerFailed("Could not open the default browser.")
                }
            }
            return callbackURL
        } catch {
            listener.cancel()
            throw error
        }
    }

    private static func makeListener(host: String, port: Int) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw OAuthDelegateError.invalidRedirectURI("port \(port) out of range")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        do {
            return try NWListener(using: parameters)
        } catch {
            throw OAuthDelegateError.listenerFailed(error.localizedDescription)
        }
    }

    /// Resolves exactly once with the first result reported to it, ignoring any further calls.
    /// A plain local closure captured across `NWListener`'s several independent `@Sendable`
    /// callback closures doesn't satisfy Swift's strict-concurrency checker even though those
    /// callbacks all happen to run serially on the same (`.main`) queue here; wrapping the
    /// one-shot state in a small `@unchecked Sendable` class sidesteps that without pretending
    /// the mutation is something other than what it is — a single-writer-at-a-time value used
    /// from a fixed serial queue.
    private final class SingleResult: @unchecked Sendable {
        private let continuation: CheckedContinuation<URL, Error>
        private var finished = false
        init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
        func succeed(_ url: URL) {
            guard !finished else { return }
            finished = true
            continuation.resume(returning: url)
        }
        func fail(_ error: Error) {
            guard !finished else { return }
            finished = true
            continuation.resume(throwing: error)
        }
    }

    /// Waits for the single inbound HTTP GET the browser sends once the user finishes signing
    /// in, extracts and reconstructs the full callback URL from it, replies with a small "you
    /// can close this tab" page, and reports the result. `afterListening` is invoked once the
    /// listener is actually up (to open the browser at exactly that point, not before).
    private static func awaitCallback(
        on listener: NWListener, host: String, port: Int, afterListening: @escaping @Sendable () throws -> Void
    ) async throws -> URL {
        let base = "http://\(host):\(port)"
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let result = SingleResult(continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    result.fail(OAuthDelegateError.listenerFailed(error.localizedDescription))
                case .ready:
                    do { try afterListening() } catch { result.fail(error) }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    defer { connection.cancel() }
                    if let error {
                        result.fail(OAuthDelegateError.listenerFailed(error.localizedDescription))
                        return
                    }
                    guard let data, let requestText = String(data: data, encoding: .utf8),
                          let requestLine = requestText.split(separator: "\r\n").first,
                          let path = requestLine.split(separator: " ").dropFirst().first,
                          let callbackURL = URL(string: base + path) else {
                        result.fail(OAuthDelegateError.malformedCallbackRequest)
                        return
                    }
                    let body = "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding-top:4em;\">Signed in. You can close this tab and return to Clyde.</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        result.succeed(callbackURL)
                    })
                }
            }

            listener.start(queue: .main)
        }
    }
}
