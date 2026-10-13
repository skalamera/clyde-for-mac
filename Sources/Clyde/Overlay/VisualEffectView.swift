import SwiftUI
import AppKit

/// SwiftUI wrapper around NSVisualEffectView for the translucent "glass" background behind
/// the copilot UI. NSVisualEffectView is the safe cross-version choice (works back to old macOS
/// releases); the macOS-26-only NSGlassEffectView "Liquid Glass" look could be layered in later
/// behind an `@available(macOS 26, *)` check, but is not required for functionality.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    /// Settings > "Overlay opacity" — fades only this background layer, so the text/buttons
    /// drawn on top of it stay fully opaque while the panel's glass becomes more see-through.
    var opacity: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.alphaValue = opacity
    }
}
