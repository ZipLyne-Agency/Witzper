// Clipboard paste from inside the helper — runs with Accessibility privileges
// so synthetic keystrokes work, unlike Python's osascript fallback.

import Cocoa

enum Inserter {
    private static let defaultRestoreClipboardAfterMS = 200

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

    static func insert(
        text: String,
        strategy: String = "paste",
        restoreClipboardAfterMS: Int = defaultRestoreClipboardAfterMS
    ) {
        switch strategy {
        case "type":
            type(text: text)
        default:
            paste(text: text, restoreClipboardAfterMS: restoreClipboardAfterMS)
        }
    }

    static func paste(
        text: String,
        restoreClipboardAfterMS: Int = defaultRestoreClipboardAfterMS
    ) {
        DispatchQueue.main.async {
            log("paste called with \(text.count) chars: \(text.prefix(60))")
            let trusted = AXIsProcessTrustedWithOptions(nil)
            log("AX trusted = \(trusted)")
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log("frontmost = \(frontApp)")

            let pb = NSPasteboard.general
            let oldItems = pb.pasteboardItems?.compactMap {
                $0.copy() as? NSPasteboardItem
            } ?? []
            pb.clearContents()
            let ok = pb.setString(text, forType: .string)
            log("clipboard set ok=\(ok)")

            // Small delay so the clipboard write settles before we send ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendCmdV()
                log("⌘V posted")
                let restoreDelay = Double(max(restoreClipboardAfterMS, 0)) / 1000.0
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    pb.clearContents()
                    if !oldItems.isEmpty {
                        _ = pb.writeObjects(oldItems)
                    }
                }
            }
        }
    }

    static func type(text: String) {
        DispatchQueue.main.async {
            log("type called with \(text.count) chars: \(text.prefix(60))")
            let trusted = AXIsProcessTrustedWithOptions(nil)
            log("AX trusted = \(trusted)")
            let src = CGEventSource(stateID: .hidSystemState)
            let chunks = chunked(text, size: 64)
            for chunk in chunks {
                var units = Array(chunk.utf16)
                guard !units.isEmpty else { continue }
                guard let down = CGEvent(
                    keyboardEventSource: src,
                    virtualKey: 0,
                    keyDown: true
                ), let up = CGEvent(
                    keyboardEventSource: src,
                    virtualKey: 0,
                    keyDown: false
                ) else {
                    log("CGEvent creation failed")
                    return
                }
                down.keyboardSetUnicodeString(
                    stringLength: units.count,
                    unicodeString: &units
                )
                up.keyboardSetUnicodeString(
                    stringLength: units.count,
                    unicodeString: &units
                )
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(1_000)
            }
            log("typed \(text.count) chars")
        }
    }

    private static func chunked(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var buffer = ""
        buffer.reserveCapacity(size)
        for character in text {
            buffer.append(character)
            if buffer.count >= size {
                chunks.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
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
