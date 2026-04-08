// Bloomberg-terminal-style dashboard window for Witzper.
// Black background, monospace amber/green/cyan, live feed of transcriptions
// streamed from the Python daemon over a Unix socket.

import Cocoa
import SwiftUI

// MARK: - Event types streamed by the daemon

struct DaemonEvent: Decodable {
    let type: String
    let raw: String?
    let cleaned: String?
    let app: String?
    let category: String?
    let style: String?
    let total_ms: Double?
    let asr_ms: Double?
    let llm_ms: Double?
    let vad_ms: Double?
    let dict_size: Int?
    let snippet_count: Int?
    let correction_count: Int?
    let styles: [String: String]?
}

// MARK: - Observable state

@MainActor
final class DashboardState: ObservableObject {
    static let shared = DashboardState()

    @Published var entries: [TranscriptEntry] = []
    @Published var isListening: Bool = false
    @Published var lastTotalMs: Double = 0
    @Published var lastVadMs: Double = 0
    @Published var lastAsrMs: Double = 0
    @Published var lastLlmMs: Double = 0
    @Published var dictSize: Int = 0
    @Published var snippetCount: Int = 0
    @Published var correctionCount: Int = 0
    @Published var styles: [String: String] = [
        "personal_messages": "casual",
        "work_messages": "casual",
        "email": "formal",
        "other": "casual",
    ]
    @Published var status: String = "OFFLINE"
    @Published var asrModel: String = "parakeet-tdt-0.6b-v3"
    @Published var llmModel: String = "Qwen3-30B-A3B-Instruct-2507-8bit"
    @Published var hotkeyLabel: String = "Right ⌥ Option"
    @Published var micLevel: Float = 0
    @Published var latencyHistory: [Double] = Array(repeating: 0, count: 60)

    struct TranscriptEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let raw: String
        let cleaned: String
        let app: String
        let style: String
        let totalMs: Double
    }

    func setListening(_ listening: Bool) {
        isListening = listening
    }

    func ingest(_ event: DaemonEvent) {
        switch event.type {
        case "ready":
            status = "READY"
        case "transcript":
            let entry = TranscriptEntry(
                timestamp: Date(),
                raw: event.raw ?? "",
                cleaned: event.cleaned ?? "",
                app: event.app ?? "",
                style: event.style ?? "",
                totalMs: event.total_ms ?? 0
            )
            entries.insert(entry, at: 0)
            if entries.count > 200 { entries.removeLast() }
            lastTotalMs = event.total_ms ?? 0
            lastVadMs = event.vad_ms ?? 0
            lastAsrMs = event.asr_ms ?? 0
            lastLlmMs = event.llm_ms ?? 0
            latencyHistory.removeFirst()
            latencyHistory.append(event.total_ms ?? 0)
        case "stats":
            dictSize = event.dict_size ?? dictSize
            snippetCount = event.snippet_count ?? snippetCount
            correctionCount = event.correction_count ?? correctionCount
            if let s = event.styles { styles = s }
        default:
            break
        }
    }
}

// MARK: - Daemon socket reader

final class DaemonStreamReader {
    static let shared = DaemonStreamReader()
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task.detached {
            while !Task.isCancelled {
                await self.connectAndRead()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func connectAndRead() async {
        let path = "/tmp/flow-stream.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = strncpy(dst, cstr, 103)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if result != 0 { close(fd); return }

        await MainActor.run { DashboardState.shared.status = "READY" }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled {
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                await MainActor.run { DashboardState.shared.status = "OFFLINE" }
                break
            }
            buffer.append(chunk, count: n)
            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nlIdx)
                buffer.removeSubrange(0...nlIdx)
                if let event = try? JSONDecoder().decode(DaemonEvent.self, from: lineData) {
                    await MainActor.run { DashboardState.shared.ingest(event) }
                }
            }
        }
        close(fd)
    }
}

// MARK: - Bloomberg-style colors + fonts

extension Color {
    static let bbBlack = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let bbAmber = Color(red: 1.0, green: 0.65, blue: 0.0)
    static let bbGreen = Color(red: 0.0, green: 0.95, blue: 0.4)
    static let bbCyan = Color(red: 0.4, green: 0.9, blue: 1.0)
    static let bbRed = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let bbDim = Color(white: 0.45)
    static let bbBorder = Color(red: 0.15, green: 0.15, blue: 0.18)
}

extension Font {
    static let bbHeader = Font.system(size: 11, weight: .bold, design: .monospaced)
    static let bbBody = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let bbSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let bbBig = Font.system(size: 24, weight: .bold, design: .monospaced)
}

// MARK: - Dashboard SwiftUI view

enum DashboardTab: String, CaseIterable {
    case liveFeed = "LIVE FEED"
    case snippets = "SNIPPETS"
    case dictionary = "DICTIONARY"
    case settings = "SETTINGS"
}

struct DashboardView: View {
    @ObservedObject var state = DashboardState.shared
    @State private var selectedTab: DashboardTab = .liveFeed

    var body: some View {
        ZStack {
            Color.bbBlack.ignoresSafeArea()
            VStack(spacing: 0) {
                headerBar
                Divider().background(Color.bbBorder)
                tabBar
                Divider().background(Color.bbBorder)
                tabContent
                Divider().background(Color.bbBorder)
                statusBar
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .liveFeed:
            HStack(alignment: .top, spacing: 0) {
                leftPanel
                    .frame(width: 280)
                Divider().background(Color.bbBorder)
                centerPanel
                Divider().background(Color.bbBorder)
                rightPanel
                    .frame(width: 260)
            }
        case .snippets:
            SnippetsView()
        case .dictionary:
            DictionaryView()
        case .settings:
            SettingsView()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Color(white: 0.04))
    }

    private func tabButton(_ tab: DashboardTab) -> some View {
        let active = (tab == selectedTab)
        return Button(action: { selectedTab = tab }) {
            VStack(spacing: 4) {
                Text(tab.rawValue)
                    .font(.bbHeader)
                    .foregroundColor(active ? .bbAmber : .bbDim)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                Rectangle()
                    .fill(active ? Color.bbAmber : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: header

    private var headerBar: some View {
        HStack(spacing: 16) {
            Text("WITZPER")
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(.bbAmber)
            Text("v0.1.0")
                .font(.bbSmall)
                .foregroundColor(.bbDim)
            Spacer()
            label("STATUS", state.status, state.isListening ? .bbRed : .bbGreen)
            label("HOTKEY", state.hotkeyLabel, .bbCyan)
            label("DICT", "\(state.dictSize)", .bbAmber)
            label("SNIP", "\(state.snippetCount)", .bbAmber)
            label("CORR", "\(state.correctionCount)", .bbAmber)
            Text(currentTime())
                .font(.bbSmall)
                .foregroundColor(.bbDim)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bbBlack)
    }

    private func label(_ key: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.bbSmall).foregroundColor(.bbDim)
            Text(value).font(.bbBody).foregroundColor(color)
        }
    }

    // MARK: left panel — system

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("SYSTEM")
            VStack(alignment: .leading, spacing: 6) {
                kv("ASR", state.asrModel, .bbCyan)
                kv("LLM", state.llmModel, .bbCyan)
                kv("VAD", "silero", .bbCyan)
                kv("BACKEND", "MLX / Apple Silicon", .bbGreen)
                kv("PRIVACY", "100% LOCAL", .bbGreen)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            sectionHeader("LATENCY (LAST UTTERANCE)")
            VStack(alignment: .leading, spacing: 4) {
                latencyRow("VAD", state.lastVadMs, max: 100)
                latencyRow("ASR", state.lastAsrMs, max: 500)
                latencyRow("LLM", state.lastLlmMs, max: 1000)
                latencyRow("TOTAL", state.lastTotalMs, max: 1500)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            sectionHeader("LATENCY HISTORY (60s)")
            LatencyGraph(values: state.latencyHistory)
                .frame(height: 60)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            Spacer()
        }
        .background(Color.bbBlack)
    }

    // MARK: center panel — transcript feed

    private var centerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("LIVE TRANSCRIPT FEED")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.entries.isEmpty {
                        Text("waiting for utterance — hold your hotkey to dictate")
                            .font(.bbBody)
                            .foregroundColor(.bbDim)
                            .padding(20)
                    }
                    ForEach(state.entries) { entry in
                        transcriptCard(entry)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transcriptCard(_ entry: DashboardState.TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(timeOnly(entry.timestamp))
                    .font(.bbSmall).foregroundColor(.bbDim)
                Text(entry.app.uppercased())
                    .font(.bbSmall).foregroundColor(.bbCyan)
                if !entry.style.isEmpty {
                    Text("·").font(.bbSmall).foregroundColor(.bbDim)
                    Text(entry.style.uppercased())
                        .font(.bbSmall).foregroundColor(styleColor(entry.style))
                }
                Spacer()
                Text(String(format: "%.0f ms", entry.totalMs))
                    .font(.bbSmall).foregroundColor(.bbAmber)
            }
            Text("RAW  ▸ \(entry.raw)")
                .font(.bbBody).foregroundColor(.bbDim)
                .textSelection(.enabled)
            Text("OUT  ▸ \(entry.cleaned)")
                .font(.bbBody).foregroundColor(.bbGreen)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.bbBorder, lineWidth: 1)
        )
    }

    // MARK: right panel — controls + level

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("MIC LEVEL")
            MicLevelMeter(level: state.micLevel)
                .frame(height: 24)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            sectionHeader("FLOW STYLES")
            VStack(alignment: .leading, spacing: 4) {
                styleRow("PERSONAL", state.styles["personal_messages"] ?? "casual")
                styleRow("WORK", state.styles["work_messages"] ?? "casual")
                styleRow("EMAIL", state.styles["email"] ?? "formal")
                styleRow("OTHER", state.styles["other"] ?? "casual")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            sectionHeader("PERSONALIZATION")
            VStack(alignment: .leading, spacing: 6) {
                kv("AUTO-LEARN", "ON", .bbGreen)
                kv("EDIT WATCH", "10s", .bbAmber)
                kv("LORA NIGHTLY", "ENABLED", .bbGreen)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            sectionHeader("KEYBOARD SHORTCUTS")
            VStack(alignment: .leading, spacing: 4) {
                shortcutRow("HOLD", "dictate")
                shortcutRow("⌘T", "test sound + HUD")
                shortcutRow("⌘Q", "quit Witzper")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()
        }
        .background(Color.bbBlack)
    }

    // MARK: status bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(state.status == "READY" ? Color.bbGreen : Color.bbRed)
                .frame(width: 8, height: 8)
            Text(state.status == "READY" ? "DAEMON CONNECTED" : "DAEMON DISCONNECTED")
                .font(.bbSmall).foregroundColor(.bbDim)
            Spacer()
            Text("WITZPER — fully on-device dictation")
                .font(.bbSmall).foregroundColor(.bbDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.04))
    }

    // MARK: helpers

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

    private func kv(_ key: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(key).font(.bbSmall).foregroundColor(.bbDim).frame(width: 80, alignment: .leading)
            Text(value).font(.bbBody).foregroundColor(color).lineLimit(1).truncationMode(.middle)
        }
    }

    private func latencyRow(_ key: String, _ ms: Double, max: Double) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.bbSmall).foregroundColor(.bbDim).frame(width: 50, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.08))
                    Rectangle()
                        .fill(ms > max * 0.8 ? Color.bbRed : Color.bbGreen)
                        .frame(width: geo.size.width * CGFloat(min(ms / max, 1.0)))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.0fms", ms))
                .font(.bbSmall).foregroundColor(.bbAmber).frame(width: 60, alignment: .trailing)
        }
    }

    private func styleRow(_ category: String, _ style: String) -> some View {
        HStack {
            Text(category).font(.bbSmall).foregroundColor(.bbDim).frame(width: 70, alignment: .leading)
            Text(style.uppercased())
                .font(.bbBody)
                .foregroundColor(styleColor(style))
        }
    }

    private func styleColor(_ s: String) -> Color {
        switch s {
        case "formal": return .bbCyan
        case "casual": return .bbGreen
        case "very_casual": return .bbAmber
        case "excited": return .bbRed
        default: return .bbDim
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.bbBody).foregroundColor(.bbCyan).frame(width: 70, alignment: .leading)
            Text(desc).font(.bbSmall).foregroundColor(.bbDim)
        }
    }

    private func currentTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func timeOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - Latency sparkline

struct LatencyGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max((values.max() ?? 1), 1.0)
            let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height - geo.size.height * CGFloat(v / maxV)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.bbGreen, lineWidth: 1.5)
        }
    }
}

// MARK: - Mic level meter

struct MicLevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.08))
                HStack(spacing: 2) {
                    ForEach(0..<30, id: \.self) { i in
                        Rectangle()
                            .fill(self.barColor(i))
                            .frame(width: max(geo.size.width / 30 - 2, 1))
                    }
                }
            }
        }
    }
    private func barColor(_ idx: Int) -> Color {
        let lit = Int(level * 30)
        if idx >= lit { return Color(white: 0.12) }
        if idx < 18 { return .bbGreen }
        if idx < 25 { return .bbAmber }
        return .bbRed
    }
}

// MARK: - Window controller

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    convenience init() {
        let hosting = NSHostingController(rootView: DashboardView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Witzper"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.center()
        window.minSize = NSSize(width: 1100, height: 680)
        self.init(window: window)
    }

    func showDashboard() {
        DaemonStreamReader.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
