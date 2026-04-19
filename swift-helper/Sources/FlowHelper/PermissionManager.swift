// Central permission state — replaces scattered AXIsProcessTrustedWithOptions
// calls across the app.
//
// The problem we're fixing: the old code called AXIsProcessTrustedWithOptions
// with `prompt: true` on every app launch AND inside onboarding button
// handlers. Every single one of those calls can potentially show macOS's
// Accessibility dialog. When users saw the dialog pop up unexpectedly
// (outside of onboarding), that was why.
//
// New contract:
//   - Permissions.current()        — SILENT status check. Never prompts.
//                                    Safe to call every second.
//   - Permissions.requestAX()      — Shows the macOS prompt. Call ONLY in
//                                    response to explicit user action (a
//                                    button press in onboarding).
//   - Permissions.requestInputMon  — Same contract.
//   - Permissions.requestMic       — Same contract.
//
// On top of that we expose an ObservableObject (`PermissionWatcher`) that
// polls the status adaptively and publishes changes to SwiftUI. Polling
// frequency adapts to whether the user is currently "in a permission flow"
// (onboarding visible, settings pane open from us) so we don't burn cycles
// for the 99% of the session where the state never changes.

import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation
import IOKit.hid

// MARK: - Status

struct PermissionStatus: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool
    var microphone: Bool

    var allGranted: Bool { accessibility && inputMonitoring && microphone }
    var missing: [String] {
        var m: [String] = []
        if !accessibility { m.append("Accessibility") }
        if !inputMonitoring { m.append("Input Monitoring") }
        if !microphone { m.append("Microphone") }
        return m
    }
}

// MARK: - Probe

enum Permissions {
    /// SILENT status probe. Never triggers a system dialog. Safe from any
    /// thread, but callers should marshal results back to MainActor before
    /// touching SwiftUI.
    static func current() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    /// Shows the macOS Accessibility prompt. ONLY call in response to a
    /// user-initiated action (e.g. a button press in onboarding). Opens
    /// System Settings so the user can flip the toggle. macOS deduplicates
    /// the dialog itself if the permission is already resolved.
    static func requestAX() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        )
    }

    /// Requests Input Monitoring access. Like requestAX, only call on
    /// explicit user action. Returns immediately — the dialog is async.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Requests microphone access. macOS presents the prompt at most once
    /// per app; further calls are no-ops if the user previously declined.
    /// In that case, the onboarding UI directs them to System Settings.
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

// MARK: - Live watcher

/// Publishes permission status to SwiftUI and keeps it in sync with macOS
/// without spamming the system. Adaptive polling strategy:
///
///   * During onboarding (`setAttentive(true)`):  every 500ms
///   * Otherwise:                                 every 5s
///
/// Also triggers an immediate re-check when the app becomes active, since
/// that's almost always the moment the user has just finished flipping a
/// toggle in System Settings and returned to us.
@MainActor
final class PermissionWatcher: ObservableObject {
    static let shared = PermissionWatcher()

    @Published private(set) var status: PermissionStatus = Permissions.current()

    /// Callbacks fired when any permission transitions from false→true.
    /// Used by the onboarding flow to auto-advance when the user grants a
    /// permission while the setup window is visible.
    var onAccessibilityGranted: (() -> Void)?
    var onInputMonitoringGranted: (() -> Void)?
    var onMicrophoneGranted: (() -> Void)?

    private var timer: Timer?
    private var attentive = false
    private var activateObserver: Any?

    private init() {
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            // When Witzper itself becomes active, refresh — the user likely
            // just returned from System Settings.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier {
                Task { @MainActor in self.poll() }
            }
        }
        schedule()
    }

    deinit {
        if let obs = activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        timer?.invalidate()
    }

    /// Call when the user is actively in a permission-related flow
    /// (onboarding visible, Settings tab open with permission buttons).
    /// Bumps the poll rate so UI feels instant when they flip a toggle.
    func setAttentive(_ on: Bool) {
        guard on != attentive else { return }
        attentive = on
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = attentive ? 0.5 : 5.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let next = Permissions.current()
        let prev = status
        if next != prev {
            status = next
            if !prev.accessibility && next.accessibility { onAccessibilityGranted?() }
            if !prev.inputMonitoring && next.inputMonitoring { onInputMonitoringGranted?() }
            if !prev.microphone && next.microphone { onMicrophoneGranted?() }
        }
    }
}
