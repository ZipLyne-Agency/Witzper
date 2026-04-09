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

// MARK: - Permission probing

enum OnboardingPermission {
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        // IOHIDCheckAccess returns .granted when Input Monitoring is on.
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Shared state

@MainActor
final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()

    @Published var step: Int = 0
    @Published var axGranted: Bool = OnboardingPermission.accessibilityGranted
    @Published var imGranted: Bool = OnboardingPermission.inputMonitoringGranted
    @Published var micGranted: Bool = OnboardingPermission.microphoneGranted
    @Published var selectedMic: String = "System Default"
    @Published var availableMics: [String] = []

    private var timer: Timer?

    func startPolling() {
        refreshMics()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let st = OnboardingState.shared
                st.axGranted = OnboardingPermission.accessibilityGranted
                st.imGranted = OnboardingPermission.inputMonitoringGranted
                st.micGranted = OnboardingPermission.microphoneGranted
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
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

    private let totalSteps = 5

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
        .frame(minWidth: 720, minHeight: 540)
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
            Text("STEP \(state.step + 1) / \(totalSteps)")
                .font(.bbSmall).foregroundColor(.bbDim)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case 0: welcomeStep
        case 1: accessibilityStep
        case 2: inputMonitoringStep
        case 3: micStep
        default: modelsStep
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
            explanation: "Needed so Witzper can watch your global hotkey and read the focused text field for context. Witzper doesn't log keystrokes.",
            granted: state.axGranted,
            openAction: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                // Also prompt so the app appears in the list
                _ = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
                )
            }
        )
    }

    private var inputMonitoringStep: some View {
        permissionStep(
            title: "INPUT MONITORING",
            explanation: "Lets Witzper distinguish modifier keys for the global hotkey (Right Option, Caps Lock, etc.). Without it, the hotkey silently won't fire.",
            granted: state.imGranted,
            openAction: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in
                            OnboardingState.shared.micGranted = OnboardingPermission.microphoneGranted
                            OnboardingState.shared.refreshMics()
                        }
                    }
                }
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

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MODELS").font(.bbHeader).foregroundColor(.bbAmber)
            Text("Witzper needs its default ASR and cleanup LLM before it can dictate. Downloads are one-time; models live in ~/.cache/huggingface.")
                .font(.bbBody).foregroundColor(.bbDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(requiredModels, id: \.id) { m in
                    modelRow(m)
                }
            }

            HStack(spacing: 10) {
                bigButton("DOWNLOAD ALL REQUIRED", color: .bbAmber) {
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
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.bbBorder, lineWidth: 1))
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
