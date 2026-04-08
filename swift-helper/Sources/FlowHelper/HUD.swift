// Floating "listening" HUD — centered-bottom, always on top, all spaces.
// Shows a pulsing red dot + live streaming partial transcript (IDEAS #1).

import Cocoa

final class HUD {
    static let shared = HUD()
    private var window: NSPanel?
    private var partialLabel: NSTextField?
    private var statusLabel: NSTextField?

    private let width: CGFloat = 520
    private let height: CGFloat = 110

    func show() {
        DispatchQueue.main.async { self._show() }
    }

    func hide() {
        DispatchQueue.main.async { self._hide() }
    }

    /// Update the live partial transcript under "Listening…".
    func setPartial(_ text: String) {
        DispatchQueue.main.async {
            guard self.window != nil else { return }
            self.partialLabel?.stringValue = text
        }
    }

    /// Flip the top-line label (e.g. "Listening…" → "Processing…").
    func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = text
        }
    }

    private func _show() {
        if window != nil {
            // Reset partial text on re-show.
            partialLabel?.stringValue = ""
            statusLabel?.stringValue = "Listening…"
            window?.orderFrontRegardless()
            return
        }
        let size = NSSize(width: width, height: height)
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
        container.layer?.cornerRadius = 20

        // Pulsing red dot
        let dot = NSView(frame: NSRect(x: 20, y: height - 36, width: 16, height: 16))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 8
        container.addSubview(dot)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        // Status label
        let status = NSTextField(labelWithString: "Listening…")
        status.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        status.textColor = .white
        status.frame = NSRect(x: 46, y: height - 40, width: width - 60, height: 20)
        container.addSubview(status)
        self.statusLabel = status

        // Live partial transcript label
        let partial = NSTextField(wrappingLabelWithString: "")
        partial.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        partial.textColor = NSColor(white: 1.0, alpha: 0.92)
        partial.frame = NSRect(x: 20, y: 12, width: width - 40, height: 54)
        partial.maximumNumberOfLines = 2
        partial.lineBreakMode = .byTruncatingHead
        partial.alignment = .left
        container.addSubview(partial)
        self.partialLabel = partial

        panel.contentView = container
        panel.orderFrontRegardless()
        window = panel
    }

    private func _hide() {
        window?.orderOut(nil)
        window = nil
        partialLabel = nil
        statusLabel = nil
    }
}
