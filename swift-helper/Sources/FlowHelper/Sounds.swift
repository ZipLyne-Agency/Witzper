// Start/stop tones for hotkey press/release.

import AppKit

enum Sounds {
    // macOS system sounds — no files to ship.
    static let start: NSSound? = NSSound(named: NSSound.Name("Tink"))
    static let stop: NSSound? = NSSound(named: NSSound.Name("Pop"))

    static func playStart() {
        start?.stop()
        start?.play()
    }

    static func playStop() {
        stop?.stop()
        stop?.play()
    }
}
