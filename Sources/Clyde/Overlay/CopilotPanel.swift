import AppKit
import SwiftUI

/// The always-on-top, translucent overlay panel that shows the live transcript, proactive
/// suggestion cards, and chat — and that must be invisible to screen sharing / recording.
///
/// Window configuration, and why:
///   - `.borderless` + `.nonactivatingPanel`: no title bar, and critically, clicking into it
///     never activates the app or steals key focus away from the meeting app the user is
///     actually presenting from.
///   - `level = .screenSaver`: keeps the panel above the menu bar and above other apps'
///     full-screen Spaces (a plain `.floating` level can end up behind a full-screen Zoom
///     window on another Space).
///   - `collectionBehavior`: `.canJoinAllSpaces` + `.fullScreenAuxiliary` so the panel follows
///     the user across Spaces and stays visible over a full-screened meeting app; `.stationary`
///     so it doesn't get swept away by Mission Control/Exposé animations; `.ignoresCycle` so it
///     never appears in Cmd-Tab or the Dock's window list.
///   - `isOpaque = false` / `backgroundColor = .clear`: lets the SwiftUI content (with its own
///     NSVisualEffectView background) show translucency instead of a solid AppKit backing.
///   - `sharingType = .none`: kept as defense-in-depth for the legacy CGWindowList capture path
///     and window picker, even though it is NOT sufficient by itself against ScreenCaptureKit —
///     see `CaptureExclusion`, which does the real work.
final class CopilotPanel: NSPanel {
    /// True once CaptureExclusion has confirmed the private API is present and usable. If this
    /// is false, the window is NOT protected from screen capture — the app should surface this
    /// to the user (see AppDelegate) rather than silently proceeding as if hidden.
    private(set) var isCaptureExcluded = false

    /// User-facing toggle (Settings > "Hide from screen shares") — defaults to on, but can be
    /// turned off e.g. to screenshot the panel itself for troubleshooting.
    private var captureExclusionDesired = Settings.shared.captureExclusionEnabled

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        sharingType = .none
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        self.contentView = contentView

        NotificationCenter.default.addObserver(
            self, selector: #selector(reapplyExclusion),
            name: NSWindow.didResizeNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reapplyExclusion),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    // A non-activating panel that can still become key lets the chat text field accept typing,
    // without ever making Clyde the frontmost/main app (which would minimize or hide the
    // meeting app behind it).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Show the panel and (re-)apply capture exclusion. Safe to call repeatedly.
    func present() {
        orderFrontRegardless()
        reapplyExclusion()
    }

    @objc private func reapplyExclusion() {
        // windowNumber is only valid once the window has been ordered on screen at least once.
        guard windowNumber > 0 else { return }
        guard captureExclusionDesired else {
            _ = CaptureExclusion.setExcluded(false, for: self)
            isCaptureExcluded = false
            return
        }
        isCaptureExcluded = CaptureExclusion.setExcluded(true, for: self)
        if !isCaptureExcluded {
            Log.overlay.warning("Capture exclusion failed to apply — overlay may be visible in screen shares/recordings.")
        }
    }

    /// Turns capture exclusion on/off live, e.g. from a Settings toggle. When turned off, the
    /// panel becomes visible in screen shares/recordings/screenshots immediately — intended for
    /// troubleshooting (e.g. screenshotting the panel itself), not everyday use.
    func setCaptureExclusionEnabled(_ enabled: Bool) {
        captureExclusionDesired = enabled
        reapplyExclusion()
    }

    /// Click-through mode: lets clicks pass to whatever is behind the panel (e.g. the meeting
    /// app) while it remains visible. Useful as a "get out of my way" toggle.
    func setClickThrough(_ enabled: Bool) {
        ignoresMouseEvents = enabled
    }


    /// Renders the panel's own content — the entire chat window UI — to an image, for the
    /// header's camera button. This does NOT go through screen capture (which the panel is
    /// deliberately excluded from) — it asks the content view's layer to draw itself directly
    /// into an offscreen bitmap context, entirely in-process, so it works regardless of the
    /// panel's capture-exclusion state or on-screen visibility.
    func captureSnapshot() -> NSImage? {
        guard let contentView, let layer = contentView.layer else { return nil }
        let scale = backingScaleFactor
        let size = contentView.bounds.size
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // CGContext is bottom-left-origin; CALayer.render(in:) draws using that context's
        // coordinate system as-is, so without this flip the image comes out upside-down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
