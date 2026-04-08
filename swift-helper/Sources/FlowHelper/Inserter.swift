// Clipboard paste from inside the helper — runs with Accessibility privileges
// so synthetic keystrokes work, unlike Python's osascript fallback.

import Cocoa

enum Inserter {
    static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/flow-insert.log"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    static func paste(text: String) {
        DispatchQueue.main.async {
            log("paste called with \(text.count) chars: \(text.prefix(60))")
            let trusted = AXIsProcessTrustedWithOptions(nil)
            log("AX trusted = \(trusted)")
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log("frontmost = \(frontApp)")

            let pb = NSPasteboard.general
            let old = pb.string(forType: .string)
            pb.clearContents()
            let ok = pb.setString(text, forType: .string)
            log("clipboard set ok=\(ok)")

            // Small delay so the clipboard write settles before we send ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendCmdV()
                log("⌘V posted")
                if let old = old {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        pb.clearContents()
                        pb.setString(old, forType: .string)
                    }
                }
            }
        }
    }

    private static func sendCmdV() {
        // Use a NULL source for cleanest synthetic post (no flag inheritance)
        let src = CGEventSource(stateID: .hidSystemState)
        // V virtual keycode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            log("CGEvent creation failed")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
