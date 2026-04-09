// Reusable model picker block for the Settings tab.
// - Shows current selection
// - Lists catalog options with download status, RAM, latency, quality
// - Apply button writes user config + restarts daemon

import Cocoa
import SwiftUI

struct ModelPickerView: View {
    let title: String
    let configSection: String   // "cleanup" | "asr.speed" | "command"
    let configKey: String       // usually "model"
    let options: [ModelOption]
    let currentModelId: String?

    @State private var selectedId: String
    @State private var statusText: String = ""
    @ObservedObject private var downloads = DownloadManager.shared

    init(
        title: String,
        configSection: String,
        configKey: String,
        options: [ModelOption],
        currentModelId: String?
    ) {
        self.title = title
        self.configSection = configSection
        self.configKey = configKey
        self.options = options
        self.currentModelId = currentModelId
        _selectedId = State(initialValue: currentModelId ?? options.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options) { opt in
                    modelRow(opt)
                }
                actionRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private func modelRow(_ opt: ModelOption) -> some View {
        let isSelected = (opt.id == selectedId)
        let isCurrent = (opt.id == currentModelId)
        let downloaded = ModelStatus.isDownloaded(opt.id)

        return Button(action: { selectedId = opt.id }) {
            HStack(alignment: .top, spacing: 10) {
                // selection radio
                Circle()
                    .strokeBorder(isSelected ? Color.bbAmber : Color.bbBorder, lineWidth: 1.5)
                    .background(
                        Circle().fill(isSelected ? Color.bbAmber : Color.clear).padding(3)
                    )
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(opt.label)
                            .font(.bbBody)
                            .foregroundColor(isSelected ? .bbAmber : .bbCyan)
                        if isCurrent {
                            Text("ACTIVE")
                                .font(.bbSmall)
                                .foregroundColor(.bbGreen)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.bbGreen, lineWidth: 1)
                                )
                        }
                        if !downloaded {
                            Text("NOT DOWNLOADED")
                                .font(.bbSmall)
                                .foregroundColor(.bbRed)
                        }
                        Spacer()
                        Text(stars(opt.qualityStars))
                            .font(.bbSmall)
                            .foregroundColor(.bbAmber)
                    }
                    HStack(spacing: 14) {
                        Text(String(format: "RAM ~%.1f GB", opt.approxRamGB))
                            .font(.bbSmall)
                            .foregroundColor(.bbDim)
                        Text("LAT ~\(opt.approxLatencyMs) ms")
                            .font(.bbSmall)
                            .foregroundColor(.bbDim)
                    }
                    Text(opt.blurb)
                        .font(.bbSmall)
                        .foregroundColor(.bbDim)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color(white: 0.07) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.bbAmber : Color.bbBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                let downloaded = ModelStatus.isDownloaded(selectedId)
                let dl = downloads.state[selectedId]
                let isDownloading = dl?.isRunning ?? false
                if !downloaded && !isDownloading {
                    bbButton("DOWNLOAD") { downloadSelected() }
                }
                if isDownloading {
                    bbButton("CANCEL") { downloads.cancel(modelId: selectedId) }
                }
                bbButton("APPLY + RESTART") { applySelected() }
                    .disabled(!downloaded)
                    .opacity(downloaded ? 1.0 : 0.4)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.bbSmall).foregroundColor(.bbAmber)
                }
                Spacer()
            }
            if let dl = downloads.state[selectedId], dl.isRunning || dl.error != nil {
                downloadProgressBar(dl)
            }
        }
        .padding(.top, 6)
    }

    private func downloadProgressBar(_ dl: DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.1))
                    Rectangle()
                        .fill(dl.error == nil ? Color.bbGreen : Color.bbRed)
                        .frame(width: geo.size.width * CGFloat(min(max(dl.progress, 0.02), 1.0)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 8) {
                if let err = dl.error {
                    Text("ERROR: \(err)")
                        .font(.bbSmall).foregroundColor(.bbRed)
                } else {
                    Text(String(format: "%.0f%%  %@  ·  %@ / %@",
                                dl.progress * 100,
                                dl.isRunning ? "downloading" : "done",
                                formatBytes(dl.bytesDownloaded),
                                formatBytes(dl.bytesExpected)))
                        .font(.bbSmall).foregroundColor(.bbDim)
                }
                Spacer()
            }
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        let gb = Double(n) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(n) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    private func bbButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.bbHeader)
                .foregroundColor(.bbAmber)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 2).stroke(Color.bbAmber, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func stars(_ n: Int) -> String {
        String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n)
    }

    // ---- Actions ----------------------------------------------------

    private func downloadSelected() {
        guard let opt = options.first(where: { $0.id == selectedId }) else { return }
        statusText = ""
        // Rough expected size: use approxRamGB as a proxy, clamped so the
        // progress bar always moves (the real on-disk footprint is close to
        // the RAM footprint for MLX weights).
        let expectedBytes = Int64(max(opt.approxRamGB, 0.2) * 1_000_000_000)
        DownloadManager.shared.start(modelId: selectedId, expectedBytes: expectedBytes)
    }

    private func applySelected() {
        UserConfigWriter.set(section: configSection, key: configKey, value: selectedId)
        statusText = "restarting daemon…"
        DaemonControl.restart()
    }
}

// MARK: - Model download status (checks HF cache)

enum ModelStatus {
    static func isDownloaded(_ repoId: String) -> Bool {
        let safe = repoId.replacingOccurrences(of: "/", with: "--")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(safe)/snapshots")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        // Snapshot dir must contain at least one non-empty subdirectory
        for snap in contents {
            let snapPath = dir.appendingPathComponent(snap).path
            if let files = try? FileManager.default.contentsOfDirectory(atPath: snapPath),
               !files.isEmpty {
                return true
            }
        }
        return false
    }
}

// MARK: - User config writer (TOML, naive)

enum UserConfigWriter {
    static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper/config.toml")
    }

    /// Set a key inside a section. configSection may use dots to nest, e.g. "asr.speed".
    /// We always write top-level "[section]" headers and dotted keys ARE supported only
    /// for the asr.speed/asr.accuracy case which writes [asr.speed] section.
    static func set(section: String, key: String, value: String) {
        let path = configPath
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Read existing as nested dict
        var sections: [String: [(String, String)]] = [:]
        var order: [String] = []
        if let txt = try? String(contentsOf: path, encoding: .utf8) {
            var current = ""
            for raw in txt.components(separatedBy: "\n") {
                let s = raw.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.hasPrefix("#") { continue }
                if s.hasPrefix("[") && s.hasSuffix("]") {
                    current = String(s.dropFirst().dropLast())
                    if sections[current] == nil {
                        sections[current] = []
                        order.append(current)
                    }
                    continue
                }
                if let eq = s.firstIndex(of: "=") {
                    let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
                    var v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("\"") && v.hasSuffix("\"") {
                        v = String(v.dropFirst().dropLast())
                    }
                    sections[current, default: []].append((k, v))
                }
            }
        }

        // Set/replace key in target section
        if sections[section] == nil {
            sections[section] = []
            order.append(section)
        }
        var entries = sections[section] ?? []
        if let idx = entries.firstIndex(where: { $0.0 == key }) {
            entries[idx] = (key, value)
        } else {
            entries.append((key, value))
        }
        sections[section] = entries

        // Write
        var lines: [String] = ["# Witzper user config", ""]
        for sect in order {
            lines.append("[\(sect)]")
            for (k, v) in sections[sect] ?? [] {
                if v == "true" || v == "false" {
                    lines.append("\(k) = \(v)")
                } else if Int(v) != nil || Double(v) != nil {
                    lines.append("\(k) = \(v)")
                } else {
                    lines.append("\(k) = \"\(v)\"")
                }
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Daemon restart shim

enum DaemonControl {
    static func restart() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        cd \(home)/Witzper && source .venv/bin/activate && \
        pkill -9 -f 'flow run' ; pkill -9 -f 'Witzper.*--verbose' ; sleep 1 ; \
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

// Used by ModelPickerView's body — defined here so SettingsView and others can share
private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.bbHeader)
        .foregroundColor(.bbAmber)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.04))
}
