// Settings tab — read-only config view + action buttons.

import Cocoa
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state = DashboardState.shared
    @State private var configValues: [String: String] = [:]
    @State private var currentCleanupId: String? = nil
    @State private var currentAsrId: String? = nil

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

                settingsSectionHeader("ACTIONS")
                VStack(alignment: .leading, spacing: 8) {
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
            .appendingPathComponent("Desktop/flow-local/configs/default.toml")
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
        let script = "cd \(home)/Desktop/flow-local && source .venv/bin/activate && pkill -9 -f 'python -u -m flow' ; PATH=/opt/homebrew/bin:$PATH nohup python -u -m flow run --verbose > /tmp/flow-daemon.log 2>&1 &"
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-c", script]
        try? p.run()
    }
}
