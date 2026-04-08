// Floating "listening" HUD — centered-bottom, always on top, all spaces.

import Cocoa

final class HUD {
    static let shared = HUD()
    private var window: NSPanel?

    func show() {
        DispatchQueue.main.async { self._show() }
    }

    func hide() {
        DispatchQueue.main.async { self._hide() }
    }

    private func _show() {
        if window != nil { return }
        let size = NSSize(width: 220, height: 64)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + 80,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 18

        // Pulsing red dot
        let dot = NSView(frame: NSRect(x: 20, y: 22, width: 20, height: 20))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 10
        container.addSubview(dot)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        // Label
        let label = NSTextField(labelWithString: "Listening…")
        label.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 54, y: 20, width: 150, height: 24)
        container.addSubview(label)

        panel.contentView = container
        panel.orderFrontRegardless()
        window = panel
    }

    private func _hide() {
        window?.orderOut(nil)
        window = nil
    }
}
