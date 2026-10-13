import AppKit
import CoreGraphics

/// Excludes a window from screen capture and screen sharing (Zoom "share entire screen",
/// Google Meet / Teams via ScreenCaptureKit or getDisplayMedia, QuickTime screen recording,
/// and Cmd-Shift-5 screenshots) while leaving it fully visible to the local user.
///
/// `NSWindow.sharingType = .none` alone is NOT sufficient on macOS 15/26: it only affects the
/// legacy CGWindowList capture path and the window picker. ScreenCaptureKit — which is what
/// Zoom, Chrome's getDisplayMedia, Teams, and the system screenshot/recording tools use today —
/// ignores `sharingType` entirely.
///
/// The mechanism that *does* work is the private SkyLight function
/// `CGSSetWindowCaptureExcludeShape`, which Chromium also relies on (as its own screenshot-
/// protection mechanism). It is resolved at runtime via dlopen/dlsym rather than linked, so:
///   - there is no link-time dependency on a private .tbd, so this compiles fine with only the
///     public CoreGraphics framework;
///   - every call is nil-checked, so if Apple ever removes/renames the symbol in a future
///     release the app simply stops excluding the window instead of crashing.
///
/// This uses an undocumented API. It must not ship through the Mac App Store (App Sandbox and
/// review would reject it); that matches this app's direct-distribution model.
enum CaptureExclusion {
    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias RegionCreateWithRectFn = @convention(c) (UnsafePointer<CGRect>) -> Unmanaged<CFTypeRef>?
    private typealias SetExcludeShapeFn = @convention(c) (UInt32, Int, CFTypeRef?) -> Int32

    // Resolved once at first use and never mutated afterward; `nonisolated(unsafe)` documents
    // that this is deliberately exempt from Swift's concurrency-safety checking rather than an
    // oversight — a raw dlopen handle has no Sendable conformance to check against.
    nonisolated(unsafe) private static let coreGraphicsHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    }()

    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = coreGraphicsHandle, let sym = dlsym(handle, name) else {
            Log.overlay.warning("CaptureExclusion: symbol \(name, privacy: .public) not found; window will remain visible to screen capture.")
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let cgsMainConnectionID = resolve("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let cgRegionCreateWithRect = resolve("CGRegionCreateWithRect", as: RegionCreateWithRectFn.self)
    private static let cgsSetWindowCaptureExcludeShape = resolve("CGSSetWindowCaptureExcludeShape", as: SetExcludeShapeFn.self)

    /// Whether the private APIs this relies on were successfully resolved at launch. If false,
    /// the window is NOT protected from screen capture and callers should surface that to the
    /// user rather than silently proceeding as if it were hidden.
    static var isSupported: Bool {
        cgsMainConnectionID != nil && cgRegionCreateWithRect != nil && cgsSetWindowCaptureExcludeShape != nil
    }

    /// Marks (or unmarks) `window` as excluded from screen capture. The excluded region is
    /// frame-relative, so callers MUST re-invoke this after every resize or move — see
    /// `CopilotPanel` which does this automatically via NSWindow notifications. Also only takes
    /// effect once the window has a valid `windowNumber` (i.e. after it has been ordered on
    /// screen at least once), so call this after `orderFrontRegardless()`/`makeKeyAndOrderFront`.
    @discardableResult
    static func setExcluded(_ excluded: Bool, for window: NSWindow) -> Bool {
        guard window.windowNumber > 0,
              let mainConnectionID = cgsMainConnectionID,
              let regionCreateWithRect = cgRegionCreateWithRect,
              let setExcludeShape = cgsSetWindowCaptureExcludeShape else {
            return false
        }

        let connection = mainConnectionID()
        var region: CFTypeRef?

        if excluded {
            var rect = CGRect(origin: .zero, size: window.frame.size)
            region = regionCreateWithRect(&rect)?.takeRetainedValue()
            guard region != nil else { return false }
        }
        // Passing a nil region clears any existing exclusion for this window.
        let result = setExcludeShape(connection, window.windowNumber, region)
        return result == 0
    }
}
