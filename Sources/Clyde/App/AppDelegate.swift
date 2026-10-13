import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: CopilotPanel!
    private var statusItemController: StatusItemController!
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: Dock icon + Cmd-Tab entry. The overlay panel itself is nonactivating
        // and capture-excluded regardless of activation policy.
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.makeMainMenu()

        let model = AppModel()
        self.model = model

        let hostingView = NSHostingView(rootView: CopilotView(model: model))
        let panel = CopilotPanel(contentView: hostingView)
        self.panel = panel
        model.applyCaptureExclusionSetting = { [weak panel] enabled in
            panel?.setCaptureExclusionEnabled(enabled)
        }
        model.hidePanel = { [weak panel] in
            panel?.orderOut(nil)
        }
        model.presentPanel = { [weak panel] in
            panel?.present()
        }
        model.captureScreenshotHandler = { [weak panel] in
            panel?.captureSnapshot()
        }

        statusItemController = StatusItemController(model: model, panel: panel) { [weak self] in
            self?.presentSettings()
        }

        // Position near the top-right of the main screen by default.
        if let screenFrame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(x: screenFrame.maxX - panel.frame.width - 24, y: screenFrame.maxY - panel.frame.height - 24)
            panel.setFrameOrigin(origin)
        }
        panel.present()

        if !CaptureExclusion.isSupported {
            Log.overlay.warning("Screen-capture exclusion API unavailable on this macOS build — the overlay is NOT hidden from screen shares/recordings.")
        }

        Task {
            await model.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await model.stopMeeting() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // closing the overlay panel must never quit Clyde
    }

    /// Clicking the Dock icon (or reopening from Finder/Launchpad) brings the overlay back —
    /// without this, a hidden panel would make the Dock click appear to do nothing, since the
    /// panel is not a standard window AppKit knows to restore.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.present()
        return false
    }

    /// Minimal main menu so a regular (Dock) app has working standard shortcuts — Cmd+Q to
    /// quit, Cmd+C/V/X/A in text fields (Settings, chat input), Cmd+W to close Settings.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Hide Clyde", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Clyde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        return main
    }

    private func presentSettings() {
        if let controller = settingsWindowController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clyde Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
