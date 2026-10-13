import AppKit

/// The menu-bar entry point. Clyde is an `LSUIElement` agent app with no Dock icon, so this
/// status item is the only always-visible affordance for showing/hiding the overlay, starting
/// or stopping a meeting, and reaching Settings/Quit.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private weak var panel: CopilotPanel?
    private var openSettings: (() -> Void)?

    init(model: AppModel, panel: CopilotPanel, openSettings: @escaping () -> Void) {
        self.model = model
        self.panel = panel
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Clyde")
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let toggleVisibility = NSMenuItem(title: "Show/Hide Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        toggleVisibility.target = self
        menu.addItem(toggleVisibility)

        let toggleClickThrough = NSMenuItem(title: "Toggle Click-Through", action: #selector(toggleClickThrough), keyEquivalent: "")
        toggleClickThrough.target = self
        menu.addItem(toggleClickThrough)

        menu.addItem(.separator())

        let toggleMeeting = NSMenuItem(title: "Start Meeting", action: #selector(toggleMeeting), keyEquivalent: "")
        toggleMeeting.target = self
        toggleMeeting.tag = MenuTag.toggleMeeting.rawValue
        menu.addItem(toggleMeeting)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Clyde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleOverlay() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.present()
        }
    }

    @objc private func toggleClickThrough() {
        guard let panel else { return }
        panel.setClickThrough(!panel.ignoresMouseEvents)
    }

    @objc private func toggleMeeting() {
        if model.isMeetingActive {
            Task { await model.stopMeeting() }
        } else {
            model.requestStartMeeting()
        }
    }

    @objc private func openSettingsAction() {
        openSettings?()
    }

    private enum MenuTag: Int { case toggleMeeting }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: MenuTag.toggleMeeting.rawValue) {
            item.title = model.isMeetingActive ? "Stop Meeting" : "Start Meeting"
        }
    }
}
