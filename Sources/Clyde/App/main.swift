import AppKit

// Plain AppKit entry point (no SwiftUI `App` lifecycle): Clyde has no primary window of its
// own — its only UI is the always-on-top overlay panel and an optional settings window — so
// `AppDelegate` manages everything directly rather than fighting SwiftUI's window management.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
