// Press-a-key-to-set-it hotkey picker.
//
// The old UX was a dropdown of predefined hotkey names — functional but
// feels like a 2015 preference pane. This gives the user what apps like
// Raycast, CleanShot, Superwhisper, Wispr Flow all do: click a pill,
// press your desired hotkey, it's captured.
//
// Witzper's dictation hotkeys are push-to-talk. The picker accepts a
// single printable character, a modifier-only press, a modifier chord,
// or one of the known standalone keys (fn, F1-F20, space, escape,
// return, tab, arrows, caps lock).

import AppKit
import SwiftUI

// MARK: - Captured key → config string

/// Converts an NSEvent into the hotkey name used throughout Witzper
/// (`fn`, `right_option`, `caps_lock`, `right_cmd+right_option`, `f5`,
/// `space`, …) — matches exactly what `parseHotkeyTrigger` in main.swift
/// understands.
enum HotkeyName {
    /// Try to encode `event` as a valid push-to-talk hotkey. Returns
    /// nil if the press was something we refuse to bind (printable
    /// characters, shifted letters, etc.).
    static func fromEvent(_ event: NSEvent) -> String? {
        // Modifier-only press: flagsChanged with no other keycode of
        // interest. We detect this by looking at the modifier flags and
        // ignoring keyDown. Caller should pass flagsChanged events.
        if event.type == .flagsChanged {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Caps lock is reported as a latched bit; treat a press (bit
            // high) as a valid trigger.
            if mods.contains(.capsLock) { return "caps_lock" }
            if mods.contains(.function) { return "fn" }
            var chordParts: [String] = []
            if mods.contains(.command) { chordParts.append("right_cmd") }
            if mods.contains(.option) { chordParts.append("right_option") }
            if mods.contains(.shift) { chordParts.append("right_shift") }
            if mods.contains(.control) { chordParts.append("right_control") }
            if chordParts.count >= 2 { return chordParts.joined(separator: "+") }
            // Left vs right — NSEvent exposes the keyCode of the changed
            // modifier; we use that to disambiguate left/right.
            switch Int(event.keyCode) {
            case 54: return "right_cmd"
            case 55: return "left_cmd" // accepted as alias for right_cmd downstream? no — keep strict
            case 58: return "left_option"
            case 61: return "right_option"
            case 60: return "right_shift"
            case 56: return "left_shift"
            case 59: return "left_control"
            case 62: return "right_control"
            default: break
            }
            return nil
        }

        if event.type == .keyDown {
            if let name = printableKeyName(for: Int(event.keyCode)) { return name }
            // Use the raw keycode for non-printables — we don't want
            // character remapping (e.g. option-e producing ´) to influence
            // the binding.
            if let name = nonPrintableKeyName(for: Int(event.keyCode)) { return name }
            return nil
        }
        return nil
    }

    /// Inverse of the config string → readable label, for UI display.
    static func label(for raw: String) -> String {
        if raw.isEmpty { return "— not set —" }
        let parts = raw.split(separator: "+").map(displayForKey)
        return parts.joined(separator: " + ")
    }

    private static func displayForKey(_ s: Substring) -> String {
        switch s {
        case "fn": return "fn"
        case "right_option": return "Right ⌥"
        case "right_cmd": return "Right ⌘"
        case "right_shift": return "Right ⇧"
        case "right_control": return "Right ⌃"
        case "left_option": return "Left ⌥"
        case "left_cmd": return "Left ⌘"
        case "left_shift": return "Left ⇧"
        case "left_control": return "Left ⌃"
        case "caps_lock": return "⇪ Caps Lock"
        case "space": return "Space"
        case "escape": return "Esc"
        case "return": return "Return"
        case "tab": return "Tab"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return String(s).uppercased()
        }
    }

    /// Map printable virtual keycodes to the Witzper config name.
    private static func printableKeyName(for keycode: Int) -> String? {
        let table: [Int: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
            6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
            12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
        ]
        return table[keycode]
    }

    /// Map non-printable virtual keycodes (F1-F20, arrows, space, etc.)
    /// to the Witzper config name.
    private static func nonPrintableKeyName(for keycode: Int) -> String? {
        let table: [Int: String] = [
            122: "f1", 120: "f2", 99: "f3", 118: "f4",
            96: "f5", 97: "f6", 98: "f7", 100: "f8",
            101: "f9", 109: "f10", 103: "f11", 111: "f12",
            105: "f13", 107: "f14", 113: "f15", 106: "f16",
            64: "f17", 79: "f18", 80: "f19", 90: "f20",
            53: "escape",
            49: "space",
            36: "return",
            48: "tab",
            123: "left", 124: "right", 125: "down", 126: "up",
        ]
        return table[keycode]
    }
}

// MARK: - SwiftUI capture field

@MainActor
final class HotkeyCaptureState: ObservableObject {
    @Published var raw: String = ""
    @Published var listening: Bool = false
}

struct HotkeyCaptureField: View {
    /// Binding to the Witzper config value (e.g. "fn", "right_option+right_cmd").
    @Binding var rawValue: String
    var onCommit: (String) -> Void = { _ in }
    @State private var listening: Bool = false
    @State private var localMonitor: Any?
    @State private var hint: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Text(listening ? "PRESS ANY KEY…" : (rawValue.isEmpty ? "CLICK TO SET" : HotkeyName.label(for: rawValue)))
                    .font(.bbBody)
                    .foregroundColor(listening ? .bbAmber : .bbCyan)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(listening ? Color.bbAmber : Color.bbCyan, lineWidth: 1))
                    .frame(minWidth: 160)
            }
            .buttonStyle(.plain)
            if !rawValue.isEmpty {
                Button(action: clear) {
                    Text("CLEAR").font(.bbSmall).foregroundColor(.bbDim)
                }
                .buttonStyle(.plain)
            }
            if !hint.isEmpty {
                Text(hint).font(.bbSmall).foregroundColor(.bbRed)
            }
        }
        .onChange(of: listening) { _, on in
            if on { attachMonitor() } else { detachMonitor() }
        }
        .onDisappear { detachMonitor() }
    }

    private func toggle() {
        hint = ""
        listening.toggle()
    }

    private func clear() {
        rawValue = ""
        onCommit("")
    }

    private func attachMonitor() {
        detachMonitor()
        // Local monitor fires before the first responder receives the
        // event. Returning nil swallows it so random keys don't type
        // into the field while we're listening.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            if let name = HotkeyName.fromEvent(event), !name.isEmpty {
                rawValue = name
                onCommit(name)
                listening = false
                return nil
            }
            if event.type == .keyDown {
                hint = "Unsupported for push-to-talk — try one character, fn, a function key, or a modifier."
            }
            return nil
        }
    }

    private func detachMonitor() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }
}
