import AppKit
import CoreGraphics
import Observation
@preconcurrency import ScreenCaptureKit
import Vision

/// One meaningful screen state: a downscaled JPEG of the display the mouse was on, plus the
/// text Vision read off it locally. Held in memory only — never written to disk.
struct ScreenSnapshot: Sendable {
    var jpeg: Data
    var ocrText: String
    var frontmostApp: String?
    var capturedAt: Date
}

/// Watches the user's screen during an active meeting so suggestions and chat can react to
/// what's actually happening (an error being reproduced, a page the customer is describing).
///
/// Design:
///   - Polls a still frame every `pollInterval` via ScreenCaptureKit from whichever display the
///     mouse is on. Clyde's own windows are excluded from the capture filter.
///   - Compares a tiny grayscale thumbnail against the last kept frame; only a meaningful
///     change becomes a new `ScreenSnapshot` (cursor blinks / clock ticks are ignored).
///   - On a kept change, runs on-device OCR so the text on screen can go to any backend as text.
///   - Pauses while a password manager / sensitive app is frontmost.
/// `changeGeneration` increments on every kept change so ProactiveAnalyzer can tell "the
/// screen changed since my last pass" without any callback plumbing.
@MainActor
@Observable
final class ScreenWatcher {
    private(set) var isWatching = false
    private(set) var isPausedForPrivacy = false
    private(set) var lastError: String?
    private(set) var latest: ScreenSnapshot?
    private(set) var changeGeneration = 0
    private(set) var lastChangeAt: Date = .distantPast

    private var loopTask: Task<Void, Never>?
    private var lastThumbnail: [UInt8]?

    /// Everything the watcher needs from the system. Injected so tests can drive capture and
    /// OCR timing without screen-recording permission; the app uses `.live`.
    struct Environment {
        var isEnabled: @MainActor () -> Bool
        var ensureCaptureAccess: @MainActor () -> Void
        var frontmostApp: @MainActor () -> (bundleID: String?, name: String?)
        var captureDisplayUnderMouse: @MainActor (_ maxImageWidth: Int) async throws -> CGImage?
        var recognizeText: @Sendable (CGImage) async -> String
        var now: @MainActor () -> Date
        var pollInterval: Duration

        static var live: Environment {
            Environment(
                isEnabled: { Settings.shared.screenWatchEnabled },
                ensureCaptureAccess: {
                    if !CGPreflightScreenCaptureAccess() {
                        // Prompts once; the user may have to relaunch after granting.
                        _ = CGRequestScreenCaptureAccess()
                    }
                },
                frontmostApp: {
                    let app = NSWorkspace.shared.frontmostApplication
                    return (app?.bundleIdentifier, app?.localizedName)
                },
                captureDisplayUnderMouse: { try await ScreenWatcher.captureDisplayUnderMouse(maxImageWidth: $0) },
                recognizeText: { await ScreenWatcher.recognizeText(in: $0) },
                now: { Date() },
                pollInterval: .milliseconds(1500)
            )
        }
    }

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Mean absolute per-pixel difference (0-255) on the 64x36 thumbnail that counts as a
    /// meaningful change. ~3 ignores cursor/caret/clock noise but catches dialogs and page loads.
    private let changeThreshold: Double = 3.0
    private let maxImageWidth: Int = 1440

    /// Frontmost apps during which nothing is captured.
    static let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess", "com.apple.Passwords"
    ]

    func start() {
        guard loopTask == nil else { return }
        guard environment.isEnabled() else { return }
        environment.ensureCaptureAccess()
        isWatching = true
        lastError = nil
        let pollInterval = environment.pollInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: pollInterval)
            }
        }
        Log.app.info("Screen watcher started")
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isWatching = false
        isPausedForPrivacy = false
        latest = nil
        lastThumbnail = nil
        Log.app.info("Screen watcher stopped")
    }

    private func tick() async {
        let front = environment.frontmostApp()
        if let bundleID = front.bundleID, Self.sensitiveBundleIDs.contains(bundleID) {
            isPausedForPrivacy = true
            return
        }
        isPausedForPrivacy = false

        do {
            guard let image = try await environment.captureDisplayUnderMouse(maxImageWidth) else { return }
            let thumb = Self.thumbnail(of: image)
            if let previous = lastThumbnail, Self.meanDifference(previous, thumb) < changeThreshold {
                return
            }
            lastThumbnail = thumb
            guard let jpeg = Self.jpegData(image) else { return }
            let text = await environment.recognizeText(image)
            latest = ScreenSnapshot(jpeg: jpeg, ocrText: text, frontmostApp: front.name, capturedAt: environment.now())
            changeGeneration += 1
            lastChangeAt = environment.now()
            lastError = nil
        } catch {
            if lastError != error.localizedDescription {
                Log.app.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            }
            lastError = error.localizedDescription
        }
    }

    private static func captureDisplayUnderMouse(maxImageWidth: Int) async throws -> CGImage? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = min(1.0, Double(maxImageWidth) / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Change detection

    private static let thumbW = 64, thumbH = 36

    private static func thumbnail(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbW * thumbH)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8,
                bytesPerRow: thumbW, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        }
        return pixels
    }

    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    // MARK: - OCR

    private nonisolated static func recognizeText(in image: CGImage) async -> String {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image)
            do { try handler.perform([request]) } catch { return "" }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n")
            return String(joined.prefix(6000))
        }.value
    }
}
