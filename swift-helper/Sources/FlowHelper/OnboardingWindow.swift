// First-launch onboarding.
//
// A 5-step flow that gets the user from "just opened the app" to
// "everything is granted, mic picked, models downloaded":
//
//   1. Welcome + privacy pitch
//   2. Accessibility permission (hotkey + AX context)
//   3. Input Monitoring permission
//   4. Microphone permission + device picker
//   5. Required models — download status + big "Download All" button
//
// Gated by UserDefaults(key: "witzperOnboardingComplete"). Can be reopened
// manually from the Settings tab.

import AppKit
import AVFoundation
import Combine
import SwiftUI
import ApplicationServices
import IOKit.hid

// MARK: - Shared state

/// Backs the setup wizard. Mirrors the live PermissionWatcher so the step
/// ticks green the instant the user flips a toggle in System Settings,
/// and auto-advances past permission steps when the user grants access
/// while looking at the step.
@MainActor
final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()

    @Published var step: Int = 0
    @Published var axGranted: Bool = Permissions.current().accessibility
    @Published var imGranted: Bool = Permissions.current().inputMonitoring
    @Published var micGranted: Bool = Permissions.current().microphone
    @Published var selectedMic: String = "System Default"
    @Published var availableMics: [String] = []
    @Published var hotkeyDictate: String = "fn"

    private var cancellables: Set<AnyCancellable> = []

    func startPolling() {
        refreshMics()
        hotkeyDictate = UserConfigWriter.read(section: "hotkeys.dictate", key: "key") ?? "fn"
        PermissionWatcher.shared.setAttentive(true)
        // Subscribe to the centralized watcher so the three published
        // booleans here are driven by a single source of truth and we
        // never drift. Also auto-advance when a permission flips from
        // off→on while the user is looking at that specific step — that's
        // the UX Wispr/Flow/etc. all do.
        PermissionWatcher.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self = self else { return }
                let prevAX = self.axGranted
                let prevIM = self.imGranted
                let prevMic = self.micGranted
                self.axGranted = s.accessibility
                self.imGranted = s.inputMonitoring
                self.micGranted = s.microphone
                if !prevAX && s.accessibility && self.step == 1 {
                    withAnimation { self.step = 2 }
                }
                if !prevIM && s.inputMonitoring && self.step == 2 {
                    withAnimation { self.step = 3 }
                }
                if !prevMic && s.microphone && self.step == 3 {
                    // Don't skip the mic step — the user needs to pick a
                    // device. Just refresh the list so new devices show up
                    // now that we're allowed to enumerate them.
                    self.refreshMics()
                }
            }
            .store(in: &cancellables)
    }

    func stopPolling() {
        cancellables.removeAll()
        PermissionWatcher.shared.setAttentive(false)
    }

    func refreshMics() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        let devs = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .audio, position: .unspecified
        ).devices
        availableMics = ["System Default"] + devs.map { $0.localizedName }
    }

    func markComplete() {
        UserDefaults.standard.set(true, forKey: "witzperOnboardingComplete")
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var state = OnboardingState.shared
    @ObservedObject var downloads = DownloadManager.shared
    let close: () -> Void

    private let totalSteps = 7

    var body: some View {
        ZStack {
            Color.bbBlack.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.bbBorder)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().background(Color.bbBorder)
                footer
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .onAppear { state.startPolling() }
        .onDisappear { state.stopPolling() }
    }

    // --- sections ---

    private var header: some View {
        HStack {
            Text("WITZPER · SETUP")
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(.bbAmber)
            Spacer()
            stepPips
            Text("STEP \(state.step + 1) / \(totalSteps)")
                .font(.bbSmall).foregroundColor(.bbDim)
                .padding(.leading, 12)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// A small row of pips under the header — reassures the user there's
    /// a finite number of steps and shows which ones are already done.
    private var stepPips: some View {
        HStack(spacing: 5) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Circle()
                    .fill(i < state.step ? Color.bbGreen : (i == state.step ? Color.bbAmber : Color.bbBorder))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case 0: welcomeStep
        case 1: accessibilityStep
        case 2: inputMonitoringStep
        case 3: micStep
        case 4: hotkeyStep
        case 5: modelsStep
        default: readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WELCOME")
                .font(.bbHeader).foregroundColor(.bbAmber)
            Text("Witzper is a 100% local dictation engine. Nothing you say leaves your Mac.")
                .font(.bbBody).foregroundColor(.bbGreen)
            Text("Setup takes about 60 seconds and a few permission clicks. You'll grant Accessibility + Input Monitoring (so the global hotkey works), allow microphone access, pick your mic, and download the models.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
    }

    private var accessibilityStep: some View {
        permissionStep(
            title: "ACCESSIBILITY",
            explanation: "Needed so Witzper can watch your global hotkey and read the focused text field for context. Witzper never logs keystrokes or exports what you type.",
            granted: state.axGranted,
            openAction: {
                // Fire the prompt THEN open System Settings. Calling
                // requestAX() first is what makes Witzper appear in the
                // Accessibility list pre-authorized, so the user only has
                // to flip one toggle. The prompt itself is a no-op if TCC
                // already has a decision on file.
                Permissions.requestAX()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        )
    }

    private var inputMonitoringStep: some View {
        permissionStep(
            title: "INPUT MONITORING",
            explanation: "Lets Witzper distinguish modifier keys for your global hotkey (Right Option, Caps Lock, fn, etc.). Without it, the hotkey silently won't fire.",
            granted: state.imGranted,
            openAction: {
                Permissions.requestInputMonitoring()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        )
    }

    private func permissionStep(
        title: String,
        explanation: String,
        granted: Bool,
        openAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.bbHeader).foregroundColor(.bbAmber)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(granted ? Color.bbGreen : Color.bbRed)
                        .frame(width: 10, height: 10)
                    Text(granted ? "GRANTED" : "NOT GRANTED")
                        .font(.bbSmall)
                        .foregroundColor(granted ? .bbGreen : .bbRed)
                }
            }
            Text(explanation)
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                bigButton("OPEN SETTINGS", color: .bbAmber, action: openAction)
                if granted {
                    Text("Auto-detected ✓").font(.bbSmall).foregroundColor(.bbGreen)
                } else {
                    Text("Waiting… this page auto-updates when you flip the toggle.")
                        .font(.bbSmall).foregroundColor(.bbDim)
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var micStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MICROPHONE").font(.bbHeader).foregroundColor(.bbAmber)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.micGranted ? Color.bbGreen : Color.bbRed)
                        .frame(width: 10, height: 10)
                    Text(state.micGranted ? "GRANTED" : "NOT GRANTED")
                        .font(.bbSmall)
                        .foregroundColor(state.micGranted ? .bbGreen : .bbRed)
                }
            }
            Text("Witzper needs microphone access. Audio is processed locally and never uploaded.")
                .font(.bbBody).foregroundColor(.bbDim)

            if !state.micGranted {
                bigButton("REQUEST MICROPHONE ACCESS", color: .bbAmber) {
                    Permissions.requestMicrophone { _ in
                        // PermissionWatcher will pick up the change and
                        // push it into state automatically. We only need
                        // to refresh the mic list here — macOS hides
                        // external devices until after the user grants
                        // access.
                        OnboardingState.shared.refreshMics()
                    }
                }
            } else {
                // Live level meter — lets the user confirm the mic is
                // actually picking up their voice before Witzper even
                // starts inference. Removes the #1 "I granted permission
                // but it's not working" support question.
                LiveMicMeter(deviceName: state.selectedMic)
                    .frame(height: 34)
            }

            Text("SELECT INPUT DEVICE").font(.bbHeader).foregroundColor(.bbAmber)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.availableMics, id: \.self) { mic in
                    Button(action: { selectMic(mic) }) {
                        HStack {
                            Circle()
                                .strokeBorder(
                                    state.selectedMic == mic ? Color.bbAmber : Color.bbBorder,
                                    lineWidth: 1.5
                                )
                                .background(Circle().fill(
                                    state.selectedMic == mic ? Color.bbAmber : Color.clear
                                ).padding(3))
                                .frame(width: 12, height: 12)
                            Text(mic).font(.bbBody)
                                .foregroundColor(state.selectedMic == mic ? .bbAmber : .bbCyan)
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.bbBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var hotkeyStep: some View {
        let dictateBinding = Binding<String>(
            get: { state.hotkeyDictate },
            set: { state.hotkeyDictate = $0 }
        )
        return VStack(alignment: .leading, spacing: 14) {
            Text("YOUR DICTATION KEY").font(.bbHeader).foregroundColor(.bbAmber)
            Text("Pick the key you'll hold down to dictate. The most common choices are fn (the Function key on recent MacBooks), Right Option, or Caps Lock. Press any key below to pick it.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("DICTATE")
                    .font(.bbSmall).foregroundColor(.bbDim).frame(width: 90, alignment: .leading)
                HotkeyCaptureField(rawValue: dictateBinding) { captured in
                    UserConfigWriter.set(section: "hotkeys.dictate", key: "key", value: captured)
                    UserConfigWriter.set(section: "hotkeys.dictate", key: "mode", value: "hold")
                }
                Spacer()
            }
            Text("Don't want to set it right now? Skip — the default is the fn key.")
                .font(.bbSmall).foregroundColor(.bbDim)
            Spacer()
        }
        .padding(24)
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MODELS").font(.bbHeader).foregroundColor(.bbAmber)
            Text("Witzper needs its default ASR (speech-to-text) and cleanup models before it can dictate. Downloads are one-time; models live in ~/.cache/huggingface.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(requiredModels, id: \.id) { m in
                    modelRow(m)
                }
            }

            HStack(spacing: 10) {
                let allDone = requiredModels.allSatisfy { ModelStatus.isDownloaded($0.id) }
                let anyRunning = requiredModels.contains(where: { downloads.state[$0.id]?.isRunning == true })
                bigButton(
                    allDone ? "ALL DOWNLOADED ✓" : (anyRunning ? "DOWNLOADING…" : "DOWNLOAD ALL REQUIRED"),
                    color: allDone ? .bbGreen : .bbAmber
                ) {
                    for m in requiredModels where !ModelStatus.isDownloaded(m.id) {
                        let expected = Int64(max(m.approxRamGB, 0.2) * 1_000_000_000)
                        DownloadManager.shared.start(modelId: m.id, expectedBytes: expected)
                    }
                }
                Text("You can skip this and download from the Settings tab later.")
                    .font(.bbSmall).foregroundColor(.bbDim)
            }
            Spacer()
        }
        .padding(24)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("READY")
                .font(.bbHeader).foregroundColor(.bbGreen)
            Text("You're all set. Hold down your dictate key, speak, release — Witzper will paste the transcript into whatever you're focused on.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                checklist("Accessibility permission", ok: state.axGranted)
                checklist("Input Monitoring permission", ok: state.imGranted)
                checklist("Microphone access", ok: state.micGranted)
                checklist("Dictation hotkey: \(HotkeyName.label(for: state.hotkeyDictate))", ok: !state.hotkeyDictate.isEmpty)
                let modelsOk = requiredModels.allSatisfy { ModelStatus.isDownloaded($0.id) }
                checklist("Required models downloaded", ok: modelsOk)
            }
            .padding(.top, 4)
            Text("Tips")
                .font(.bbHeader).foregroundColor(.bbAmber).padding(.top, 8)
            Text("· Look for the Witzper mic icon in your menu bar.\n· Open the Dashboard from the menu to see live transcripts and set snippets.\n· Re-open this wizard any time from Settings → Reopen Setup Wizard.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
    }

    private func checklist(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .bbGreen : .bbDim)
            Text(text).font(.bbBody).foregroundColor(ok ? .bbCyan : .bbDim)
        }
    }

    private var requiredModels: [ModelOption] {
        // Default cleanup is Qwen3 8B (~5 GB RAM, ~4.5 GB download) — the
        // smallest model that produces genuinely clean transcripts. The 30B
        // stays in the catalog for power users with ≥32 GB RAM who opt in
        // from the Settings tab.
        let cleanup = ModelCatalog.cleanup.first { $0.id == "mlx-community/Qwen3-8B-4bit" }
            ?? ModelCatalog.cleanup.first!
        return [ModelCatalog.asr.first!, cleanup]
    }

    private func modelRow(_ m: ModelOption) -> some View {
        let downloaded = ModelStatus.isDownloaded(m.id)
        let dl = downloads.state[m.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.label).font(.bbBody).foregroundColor(.bbCyan)
                Spacer()
                if downloaded {
                    Text("✓ DOWNLOADED").font(.bbSmall).foregroundColor(.bbGreen)
                } else if let dl = dl, dl.isRunning {
                    Text(String(format: "%.0f%%", dl.progress * 100))
                        .font(.bbSmall).foregroundColor(.bbAmber)
                    if let eta = dl.etaSeconds {
                        Text("·  \(humanEta(eta)) left")
                            .font(.bbSmall).foregroundColor(.bbDim)
                    }
                    Text("·  \(dl.rateLabel)").font(.bbSmall).foregroundColor(.bbDim)
                } else {
                    Text("NOT DOWNLOADED").font(.bbSmall).foregroundColor(.bbRed)
                }
            }
            if let dl = dl, dl.isRunning {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(white: 0.1))
                        Rectangle().fill(Color.bbGreen)
                            .frame(width: geo.size.width * CGFloat(min(max(dl.progress, 0.02), 1.0)))
                    }
                }
                .frame(height: 5)
                Text(humanBytes(dl.bytesDownloaded) + " / " + humanBytes(max(dl.bytesExpected, dl.bytesDownloaded)))
                    .font(.bbSmall).foregroundColor(.bbDim)
            } else if let err = dl?.error {
                Text("⚠ " + err).font(.bbSmall).foregroundColor(.bbRed)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.bbBorder, lineWidth: 1))
    }

    private func humanBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }

    private func humanEta(_ seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%dh %dm", seconds / 3600, (seconds % 3600) / 60) }
        if seconds >= 60 { return String(format: "%dm %ds", seconds / 60, seconds % 60) }
        return "\(seconds)s"
    }

    // --- footer ---

    private var footer: some View {
        HStack {
            if state.step > 0 {
                bigButton("BACK", color: .bbDim) { state.step -= 1 }
            }
            Spacer()
            if state.step < totalSteps - 1 {
                bigButton(nextLabel, color: canAdvance ? .bbAmber : .bbDim) {
                    if canAdvance { state.step += 1 }
                }
                .opacity(canAdvance ? 1.0 : 0.4)
            } else {
                bigButton("FINISH", color: .bbGreen) {
                    state.markComplete()
                    close()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var nextLabel: String { "NEXT →" }

    private var canAdvance: Bool {
        switch state.step {
        case 1: return state.axGranted
        case 2: return state.imGranted
        case 3: return state.micGranted
        default: return true
        }
    }

    private func selectMic(_ name: String) {
        state.selectedMic = name
        let device = name == "System Default" ? "default" : name
        UserConfigWriter.set(section: "audio", key: "device", value: device)
    }

    private func bigButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.bbHeader).foregroundColor(color)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window controller

final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Witzper — Setup"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)
        let root = OnboardingView { [weak self] in
            self?.window?.close()
        }
        win.contentViewController = NSHostingController(rootView: root)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
