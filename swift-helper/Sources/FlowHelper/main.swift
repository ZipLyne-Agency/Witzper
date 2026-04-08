// FlowHelper — a tiny macOS menu-bar helper that:
//   1. Registers a global hotkey via CGEventTap (lower-level than NSEvent),
//      catching it even when other apps have focus.
//   2. Posts hotkey_down / hotkey_up events as newline-delimited JSON over a
//      Unix socket at /tmp/flow-local.sock.
//   3. Exposes an AXUIElement snapshot server on /tmp/flow-context.sock that
//      returns {app_name, bundle_id, window_title, surrounding_text, selected_text}.
//
// Requires Accessibility permission. On first launch, the user is prompted.

import Cocoa
import ApplicationServices
import Foundation

// MARK: - Unix socket server (line-delimited JSON)

final class UnixSocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private let queue: DispatchQueue

    init(path: String, queueLabel: String) {
        self.path = path
        self.queue = DispatchQueue(label: queueLabel)
    }

    func start() {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fatalError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = strncpy(dst, cstr, 103)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bindResult == 0 else { fatalError("bind() failed") }
        guard listen(listenFD, 4) == 0 else { fatalError("listen() failed") }
        chmod(path, 0o600)

        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            queue.async { [weak self] in self?.clients.append(fd) }
        }
    }

    func broadcast(_ json: String) {
        var line = json
        if !line.hasSuffix("\n") { line += "\n" }
        let bytes = [UInt8](line.utf8)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.clients.removeAll { fd in
                let n = bytes.withUnsafeBufferPointer { buf in
                    send(fd, buf.baseAddress, buf.count, 0)
                }
                if n < 0 { close(fd); return true }
                return false
            }
        }
    }

    // Optional simple request/response handler
    func serveRequests(handler: @escaping (String) -> String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            while true {
                let fd = accept(self.listenFD, nil, nil)
                if fd < 0 { continue }
                DispatchQueue.global().async {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    let n = buf.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
                    if n > 0 {
                        let req = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
                        var resp = handler(req)
                        if !resp.hasSuffix("\n") { resp += "\n" }
                        _ = resp.withCString { send(fd, $0, strlen($0), 0) }
                    }
                    close(fd)
                }
            }
        }
    }
}

// MARK: - Hotkey tap (right-option as default for dev; swap to Fn via IOHID)

final class HotkeyTap {
    let onDown: () -> Void
    let onUp: () -> Void
    private var tap: CFMachPort?

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let this = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                let flags = event.flags
                // Right-option as the default hotkey
                let isRightOption = flags.contains(.maskAlternate) &&
                    (event.getIntegerValueField(.keyboardEventKeycode) == 61)
                if isRightOption {
                    this.onDown()
                } else if !flags.contains(.maskAlternate) {
                    this.onUp()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            FileHandle.standardError.write("Failed to create event tap. Grant Accessibility permission.\n".data(using: .utf8)!)
            return
        }
        self.tap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - AX snapshot provider

func frontApp() -> NSRunningApplication? {
    NSWorkspace.shared.frontmostApplication
}

func axSnapshot() -> [String: Any] {
    var out: [String: Any] = [:]
    guard let app = frontApp() else { return out }
    out["app_name"] = app.localizedName ?? ""
    out["bundle_id"] = app.bundleIdentifier ?? ""

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedWindow: AnyObject?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
       let win = focusedWindow {
        var title: AnyObject?
        if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
           let s = title as? String {
            out["window_title"] = s
        }
    }
    var focusedElement: AnyObject?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
       let el = focusedElement {
        var selected: AnyObject?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String {
            out["selected_text"] = s
        }
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String {
            out["surrounding_text"] = String(s.suffix(2048))
        }
    }
    return out
}

// MARK: - Main

let hotkeyServer = UnixSocketServer(path: "/tmp/flow-local.sock", queueLabel: "flow.hotkey")
hotkeyServer.start()

let contextServer = UnixSocketServer(path: "/tmp/flow-context.sock", queueLabel: "flow.context")
contextServer.start()
contextServer.serveRequests { _req in
    let snap = axSnapshot()
    if let data = try? JSONSerialization.data(withJSONObject: snap),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "{}"
}

// Ensure Accessibility permission prompt
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
)
if !trusted {
    FileHandle.standardError.write(
        "Grant Accessibility permission, then relaunch flow-helper.\n".data(using: .utf8)!
    )
}

let tap = HotkeyTap(
    onDown: { hotkeyServer.broadcast("{\"type\":\"hotkey_down\"}") },
    onUp: { hotkeyServer.broadcast("{\"type\":\"hotkey_up\"}") }
)
tap.start()

CFRunLoopRun()
