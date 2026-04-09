// Settings tab — read-only config view + action buttons.

import Cocoa
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state = DashboardState.shared
    @State private var configValues: [String: String] = [:]
    @State private var currentCleanupId: String? = nil
    @State private var currentAsrId: String? = nil
    // Per-action shortcut state, keyed by action name (dictate, command, …).
    @State private var shortcuts: [String: String] = [
        "dictate": "fn",
        "command": "right_cmd+right_option",
    ]

    /// User-selectable shortcut options. Empty string disables the binding.
    private static let shortcutChoices: [(String, String)] = [
        ("",                          "— disabled —"),
        // Modifier keys (hold-to-talk friendly)
        ("fn",                        "fn (Function)"),
        ("right_option",              "Right ⌥ Option"),
        ("right_cmd",                 "Right ⌘ Command"),
        ("right_shift",               "Right ⇧ Shift"),
        ("caps_lock",                 "⇪ Caps Lock"),
        // Modifier chords
        ("right_cmd+right_option",    "Right ⌘ + Right ⌥"),
        ("right_cmd+right_shift",     "Right ⌘ + Right ⇧"),
        ("right_option+right_shift",  "Right ⌥ + Right ⇧"),
        // Function keys
        ("f1",  "F1"),  ("f2",  "F2"),  ("f3",  "F3"),  ("f4",  "F4"),
        ("f5",  "F5"),  ("f6",  "F6"),  ("f7",  "F7"),  ("f8",  "F8"),
        ("f9",  "F9"),  ("f10", "F10"), ("f11", "F11"), ("f12", "F12"),
        ("f13", "F13"), ("f14", "F14"), ("f15", "F15"), ("f16", "F16"),
        ("f17", "F17"), ("f18", "F18"), ("f19", "F19"), ("f20", "F20"),
        // Other standalone keys
        ("space",  "Space"),
        ("escape", "Escape"),
        ("return", "Return"),
        ("tab",    "Tab"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsSectionHeader("CONFIGURATION")
                VStack(alignment: .leading, spacing: 6) {
                    kv("HOTKEY", configValues["hotkey"] ?? state.hotkeyLabel, .bbCyan)
                    kv("MICROPHONE", configValues["mic"] ?? "System Default", .bbCyan)
                    kv("STYLE", "casual", .bbGreen)
                    kv("PRIVACY", "100% LOCAL", .bbGreen)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                ModelPickerView(
                    title: "CLEANUP LLM (HOT PATH)",
                    configSection: "cleanup",
                    configKey: "model",
                    options: ModelCatalog.cleanup,
                    currentModelId: currentCleanupId
                )

                ModelPickerView(
                    title: "ASR (SPEECH-TO-TEXT)",
                    configSection: "asr.speed",
                    configKey: "model",
                    options: ModelCatalog.asr,
                    currentModelId: currentAsrId
                )

                ModelPickerView(
                    title: "COMMAND MODE LLM (LAZY-LOADED)",
                    configSection: "command",
                    configKey: "model",
                    options: ModelCatalog.command,
                    currentModelId: nil
                )

                settingsSectionHeader("SHORTCUTS")
                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow(action: "dictate", label: "DICTATE")
                    shortcutRow(action: "command", label: "COMMAND MODE")
                    Text("CHANGES TAKE EFFECT AFTER RESTART DAEMON BELOW")
                        .font(.bbSmall).foregroundColor(.bbDim)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                settingsSectionHeader("ACTIONS")
                VStack(alignment: .leading, spacing: 8) {
                    actionButton("REOPEN SETUP WIZARD") {
                        OnboardingState.shared.step = 0
                        OnboardingWindowController.shared.show()
                    }
                    actionButton("OPEN ACCESSIBILITY SETTINGS") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    actionButton("OPEN INPUT MONITORING SETTINGS") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    actionButton("RESTART DAEMON") {
                        restartDaemon()
                    }
                    actionButton("QUIT WITZPER") {
                        NSApp.terminate(nil)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 20)

                Spacer()
            }
        }
        .background(Color.bbBlack)
        .onAppear { loadConfig() }
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.bbHeader).foregroundColor(.bbAmber)
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.04))
    }

    private func kv(_ key: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(key).font(.bbSmall).foregroundColor(.bbDim).frame(width: 130, alignment: .leading)
            Text(value).font(.bbBody).foregroundColor(color).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    private func shortcutRow(action: String, label: String) -> some View {
        let current = shortcuts[action] ?? ""
        let displayLabel = SettingsView.shortcutChoices
            .first(where: { $0.0 == current })?.1 ?? current
        return HStack {
            Text(label)
                .font(.bbSmall).foregroundColor(.bbDim)
                .frame(width: 130, alignment: .leading)
            Menu {
                ForEach(SettingsView.shortcutChoices, id: \.0) { choice in
                    Button(choice.1) {
                        shortcuts[action] = choice.0
                        writeShortcut(action: action, key: choice.0)
                    }
                }
            } label: {
                Text(displayLabel.isEmpty ? "— disabled —" : displayLabel)
                    .font(.bbBody).foregroundColor(.bbCyan)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbCyan, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.bbHeader).foregroundColor(.bbAmber)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: 320, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.bbAmber, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadConfig() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper/config.toml")
        guard let txt = try? String(contentsOf: path, encoding: .utf8) else { return }
        var hotkey = ""
        var mic = ""
        for raw in txt.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("key") {
                if let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 != q2 {
                    hotkey = String(s[s.index(after: q1)..<q2])
                }
            } else if s.hasPrefix("device") {
                if let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 != q2 {
                    mic = String(s[s.index(after: q1)..<q2])
                }
            }
        }
        if !hotkey.isEmpty { configValues["hotkey"] = hotkey }
        if !mic.isEmpty { configValues["mic"] = mic }

        // Read current model selections from default + user config
        currentCleanupId = readModelFromConfig(section: "cleanup") ?? "mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit"
        currentAsrId = readModelFromConfig(section: "asr.speed") ?? "mlx-community/parakeet-tdt-0.6b-v3"

        // Load existing per-action shortcuts. Falls back to defaults that
        // match flow/config.py's _default_hotkeys.
        loadShortcuts()
    }

    private func loadShortcuts() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper/config.toml")
        guard let txt = try? String(contentsOf: path, encoding: .utf8) else { return }
        var current = ""
        for raw in txt.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[") && s.hasSuffix("]") {
                current = String(s.dropFirst().dropLast())
                continue
            }
            guard current.hasPrefix("hotkeys."),
                  s.hasPrefix("key"),
                  let q1 = s.firstIndex(of: "\""),
                  let q2 = s.lastIndex(of: "\""),
                  q1 != q2 else { continue }
            let action = String(current.dropFirst("hotkeys.".count))
            shortcuts[action] = String(s[s.index(after: q1)..<q2])
        }
    }

    /// Persist a single shortcut to the user config. We rewrite the
    /// `[hotkeys.<action>]` section in place if present, or append it
    /// otherwise. Intentionally does NOT touch other sections — keeps the
    /// blast radius tiny so a buggy write doesn't blow away the user's
    /// model picks or mic preference.
    private func writeShortcut(action: String, key: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        let header = "[hotkeys.\(action)]"
        let body = "key = \"\(key)\"\nmode = \"hold\""
        let block = "\(header)\n\(body)\n"

        var existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        if existing.contains(header) {
            // Replace the existing section's body lines (until next [section]
            // header or EOF). Build the rewrite line by line.
            var out: [String] = []
            var inSection = false
            for line in existing.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == header {
                    inSection = true
                    out.append(header)
                    out.append("key = \"\(key)\"")
                    out.append("mode = \"hold\"")
                    continue
                }
                if inSection {
                    if t.hasPrefix("[") && t.hasSuffix("]") {
                        inSection = false
                        out.append(line)
                    }
                    // Drop old key/mode lines while inside the section.
                    continue
                }
                out.append(line)
            }
            existing = out.joined(separator: "\n")
        } else {
            if !existing.hasSuffix("\n") { existing += "\n" }
            existing += "\n" + block
        }
        try? existing.write(to: path, atomically: true, encoding: .utf8)
    }

    private func readModelFromConfig(section: String) -> String? {
        // Check user config first
        let userPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper/config.toml")
        if let txt = try? String(contentsOf: userPath, encoding: .utf8),
           let val = parseModel(txt: txt, section: section) {
            return val
        }
        // Fall back to default config
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Witzper/configs/default.toml")
        if let txt = try? String(contentsOf: defaultPath, encoding: .utf8),
           let val = parseModel(txt: txt, section: section) {
            return val
        }
        return nil
    }

    private func parseModel(txt: String, section: String) -> String? {
        var current = ""
        for raw in txt.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[") && s.hasSuffix("]") {
                current = String(s.dropFirst().dropLast())
                continue
            }
            if current == section, s.hasPrefix("model"),
               let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 != q2 {
                return String(s[s.index(after: q1)..<q2])
            }
        }
        return nil
    }

    private func restartDaemon() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        cd \(home)/Witzper && source .venv/bin/activate && \
        pkill -9 -f 'flow run' ; pkill -9 -f './Witzper --verbose' ; sleep 1 ; \
        rm -f /tmp/Witzper.pid ; \
        if [[ -x ./Witzper ]]; then \
          PATH=/opt/homebrew/bin:$PATH nohup ./Witzper --verbose > /tmp/flow-daemon.log 2>&1 & \
        else \
          PATH=/opt/homebrew/bin:$PATH nohup python -u -m flow run --verbose > /tmp/flow-daemon.log 2>&1 & \
        fi
        """
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-c", script]
        try? p.run()
    }
}
