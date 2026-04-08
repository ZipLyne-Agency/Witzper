// FlowHelper — macOS helper providing global hotkey + AX context over Unix sockets.
//
// Usage:
//   flow-helper --hotkey right_option
//   flow-helper --hotkey right_cmd
//   flow-helper --hotkey right_shift
//   flow-helper --hotkey caps_lock
//   flow-helper --hotkey fn
//
// Emits line-delimited JSON to /tmp/flow-local.sock:
//   {"type":"hotkey_down"}
//   {"type":"hotkey_up"}
//
// Hold-to-talk: down on press, up on release. Single event per transition.

import Cocoa
import ApplicationServices
import AVFoundation
import Foundation

// MARK: - Hotkey spec

enum Hotkey: String, CaseIterable {
    case rightOption = "right_option"
    case rightCmd = "right_cmd"
    case rightShift = "right_shift"
    case capsLock = "caps_lock"
    case fn = "fn"

    /// CGEventFlags bit that goes high while this key is held.
    var flag: CGEventFlags {
        switch self {
        case .rightOption, .fn: return .maskAlternate
        case .rightCmd: return .maskCommand
        case .rightShift: return .maskShift
        case .capsLock: return .maskAlphaShift
        }
    }

    /// HID keycode for discriminating left vs right modifier on flagsChanged.
    /// Nil means we match on the flag bit alone.
    var keycode: Int64? {
        switch self {
        case .rightOption: return 61   // kVK_RightOption
        case .rightCmd: return 54      // kVK_RightCommand
        case .rightShift: return 60    // kVK_RightShift
        case .capsLock: return 57      // kVK_CapsLock
        case .fn: return 63            // kVK_Function
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCmd: return "Right ⌘ Command"
        case .rightShift: return "Right ⇧ Shift"
        case .capsLock: return "⇪ Caps Lock"
        case .fn: return "fn (Function)"
        }
    }
}

// MARK: - Unix socket server

final class UnixSocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let queue: DispatchQueue
    private let clientsLock = NSLock()
    private var clients: [Int32] = []
    private var requestHandler: ((String) -> String)?

    init(path: String, queueLabel: String) {
        self.path = path
        self.queue = DispatchQueue(label: queueLabel)
    }

    func start(requestHandler: ((String) -> String)? = nil) {
        self.requestHandler = requestHandler
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fatalError("socket() failed") }
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
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bindResult == 0 else { fatalError("bind() failed: \(String(cString: strerror(errno)))") }
        guard listen(listenFD, 8) == 0 else { fatalError("listen() failed") }
        chmod(path, 0o600)
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            if let handler = requestHandler {
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
            } else {
                clientsLock.lock()
                clients.append(fd)
                clientsLock.unlock()
            }
        }
    }

    func broadcast(_ json: String) {
        var line = json
        if !line.hasSuffix("\n") { line += "\n" }
        let bytes = [UInt8](line.utf8)
        clientsLock.lock()
        let snapshot = clients
        clientsLock.unlock()
        var dead: [Int32] = []
        for fd in snapshot {
            let n = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { dead.append(fd); close(fd) }
        }
        if !dead.isEmpty {
            clientsLock.lock()
            clients.removeAll { dead.contains($0) }
            clientsLock.unlock()
        }
    }
}

// MARK: - Hotkey tap

final class HotkeyTap {
    let hotkey: Hotkey
    let onDown: () -> Void
    let onUp: () -> Void
    private var tap: CFMachPort?
    private var isDown = false

    init(hotkey: Hotkey, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.hotkey = hotkey
        self.onDown = onDown
        self.onUp = onUp
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let this = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                this.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            FileHandle.standardError.write(
                "Failed to create event tap. Grant Accessibility + Input Monitoring permissions in System Settings.\n".data(using: .utf8)!
            )
            return
        }
        self.tap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        let flags = event.flags
        // Match on the modifier flag bit alone — this accepts BOTH left and
        // right side of the modifier (e.g. either Option key triggers).
        // Trying to distinguish left/right via keycode is unreliable across
        // keyboards.
        let pressed = flags.contains(hotkey.flag)

        // For caps lock specifically: pressed=true means the latched LED is on,
        // which would fire on every toggle. Special-case it as a single-tap
        // toggle below.
        if hotkey == .capsLock {
            if pressed {
                if !isDown { isDown = true; onDown() }
                else { isDown = false; onUp() }
            }
            return
        }

        if pressed && !isDown {
            isDown = true
            onDown()
        } else if !pressed && isDown {
            isDown = false
            onUp()
        }
    }
}

// MARK: - AX snapshot

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

// MARK: - Args

func parseArgs() -> Hotkey {
    var hotkey: Hotkey = .rightOption
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--hotkey" || a == "-k", i + 1 < args.count {
            if let hk = Hotkey(rawValue: args[i + 1]) {
                hotkey = hk
            } else {
                let valid = Hotkey.allCases.map { $0.rawValue }.joined(separator: ", ")
                FileHandle.standardError.write("invalid --hotkey. valid: \(valid)\n".data(using: .utf8)!)
                exit(2)
            }
            i += 2
        } else if a == "--list-hotkeys" {
            for hk in Hotkey.allCases { print("\(hk.rawValue)\t\(hk.label)") }
            exit(0)
        } else if a == "--help" || a == "-h" {
            print("flow-helper [--hotkey <name>]")
            print("valid hotkeys:")
            for hk in Hotkey.allCases { print("  \(hk.rawValue)\t\(hk.label)") }
            exit(0)
        } else {
            i += 1
        }
    }
    // Allow env override (used by run.sh after reading user config)
    if let env = ProcessInfo.processInfo.environment["FLOW_HOTKEY"],
       let hk = Hotkey(rawValue: env) {
        hotkey = hk
    }
    return hotkey
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotkey: Hotkey = .rightOption
    var isListening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // menu-bar only, no dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(listening: false)

        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: "flow-local", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(title: "Hotkey: \(hotkey.label)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        hotkeyItem.tag = 100
        menu.addItem(hotkeyItem)

        let changeItem = NSMenuItem(title: "Change hotkey…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for hk in Hotkey.allCases {
            let item = NSMenuItem(
                title: hk.label,
                action: #selector(changeHotkey(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = hk.rawValue
            if hk == hotkey { item.state = .on }
            submenu.addItem(item)
        }
        changeItem.submenu = submenu
        menu.addItem(changeItem)

        // Microphone picker
        let micMenuItem = NSMenuItem(title: "Microphone…", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu()
        let currentMic = readCurrentMic()
        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(pickMic(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = "default"
        if currentMic == "default" || currentMic.isEmpty { defaultItem.state = .on }
        micSubmenu.addItem(defaultItem)
        micSubmenu.addItem(NSMenuItem.separator())
        let micTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            micTypes = [.microphone, .external]
        } else {
            micTypes = [.builtInMicrophone, .externalUnknown]
        }
        for dev in AVCaptureDevice.DiscoverySession(
            deviceTypes: micTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices {
            let item = NSMenuItem(
                title: dev.localizedName,
                action: #selector(pickMic(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = dev.localizedName
            if dev.localizedName == currentMic { item.state = .on }
            micSubmenu.addItem(item)
        }
        micMenuItem.submenu = micSubmenu
        menu.addItem(micMenuItem)

        menu.addItem(NSMenuItem.separator())

        let dashItem = NSMenuItem(
            title: "Open Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        )
        dashItem.target = self
        menu.addItem(dashItem)

        let testItem = NSMenuItem(
            title: "▶ Test (sound + HUD, 2s)",
            action: #selector(runTest),
            keyEquivalent: "t"
        )
        testItem.target = self
        menu.addItem(testItem)

        let statusDiag = NSMenuItem(
            title: "Show diagnostics…",
            action: #selector(showDiagnostics),
            keyEquivalent: ""
        )
        statusDiag.target = self
        menu.addItem(statusDiag)

        menu.addItem(NSMenuItem.separator())

        let axItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)

        let micItem = NSMenuItem(
            title: "Open Input Monitoring Settings…",
            action: #selector(openInputMonitoring),
            keyEquivalent: ""
        )
        micItem.target = self
        menu.addItem(micItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "Quit flow-local",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Start servers
        let hotkeyServer = UnixSocketServer(path: "/tmp/flow-local.sock", queueLabel: "flow.hotkey")
        hotkeyServer.start()
        let contextServer = UnixSocketServer(path: "/tmp/flow-context.sock", queueLabel: "flow.context")
        contextServer.start(requestHandler: { req in
            // Two ops: snapshot (default) and insert (paste text via clipboard + ⌘V).
            if let data = req.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let op = obj["op"] as? String,
               op == "insert",
               let text = obj["text"] as? String {
                Inserter.paste(text: text)
                return "{\"ok\":true}"
            }
            let snap = axSnapshot()
            if let data = try? JSONSerialization.data(withJSONObject: snap),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        })

        // Request Accessibility (non-blocking; user can click menu to open settings)
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        )
        if !trusted {
            FileHandle.standardError.write(
                "flow-local: Accessibility not granted. Click the menu bar icon → Open Accessibility Settings.\n".data(using: .utf8)!
            )
            updateIconNotTrusted()
        }

        // Start hotkey tap
        let tap = HotkeyTap(
            hotkey: hotkey,
            onDown: { [weak self] in
                hotkeyServer.broadcast("{\"type\":\"hotkey_down\"}")
                DispatchQueue.main.async {
                    Sounds.playStart()
                    self?.updateIcon(listening: true)
                }
            },
            onUp: { [weak self] in
                hotkeyServer.broadcast("{\"type\":\"hotkey_up\"}")
                DispatchQueue.main.async {
                    Sounds.playStop()
                    self?.updateIcon(listening: false)
                }
            }
        )
        tap.start()
        self.retainedTap = tap
    }

    var retainedTap: HotkeyTap?

    func updateIcon(listening: Bool) {
        isListening = listening
        if let button = statusItem.button {
            button.title = listening ? "🔴 flow" : "⚪ flow"
            button.toolTip = listening ? "Listening…" : "flow-local ready"
        }
        if listening {
            HUD.shared.show()
        } else {
            HUD.shared.hide()
        }
    }

    func updateIconNotTrusted() {
        if let button = statusItem.button {
            button.title = "⚠ flow"
            button.toolTip = "flow-local: grant Accessibility permission"
        }
    }

    @objc func changeHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let hk = Hotkey(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "Change hotkey to \(hk.label)?"
        alert.informativeText = "flow-local will quit. Relaunch it from your Applications folder or Terminal."
        alert.addButton(withTitle: "Change & Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            // Write to user config
            let home = FileManager.default.homeDirectoryForCurrentUser
            let cfgDir = home.appendingPathComponent(".config/flow-local")
            try? FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
            let cfgPath = cfgDir.appendingPathComponent("config.toml")
            let content = "# flow-local user config\n[hotkey]\nkey = \"\(hk.rawValue)\"\ntoggle_mode = false\n"
            try? content.write(to: cfgPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func readCurrentMic() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flow-local/config.toml")
        guard let txt = try? String(contentsOf: path, encoding: .utf8) else { return "default" }
        // crude parse: look for device = "..."
        for line in txt.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("device") {
                if let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 != q2 {
                    return String(s[s.index(after: q1)..<q2])
                }
            }
        }
        return "default"
    }

    @objc func pickMic(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        writeUserConfig { dict in
            var audio = dict["audio"] as? [String: Any] ?? [:]
            audio["device"] = name
            dict["audio"] = audio
        }
        let alert = NSAlert()
        alert.messageText = "Microphone set to: \(name)"
        alert.informativeText = "Restarting daemon for change to take effect."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        // Restart Python daemon via launchctl-style: just kill it; user's run.sh will restart
        // For now, ask user to restart manually
        restartPythonDaemon()
    }

    func writeUserConfig(_ mutator: (inout [String: Any]) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/flow-local")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        // Read existing
        var sections: [String: [String: Any]] = [:]
        if let txt = try? String(contentsOf: path, encoding: .utf8) {
            var current = ""
            for raw in txt.components(separatedBy: "\n") {
                let s = raw.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("#") || s.isEmpty { continue }
                if s.hasPrefix("[") && s.hasSuffix("]") {
                    current = String(s.dropFirst().dropLast())
                    if sections[current] == nil { sections[current] = [:] }
                } else if let eq = s.firstIndex(of: "=") {
                    let k = s[..<eq].trimmingCharacters(in: .whitespaces)
                    var v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("\"") && v.hasSuffix("\"") {
                        v = String(v.dropFirst().dropLast())
                    }
                    if sections[current] == nil { sections[current] = [:] }
                    sections[current]![k] = v
                }
            }
        }
        var dict: [String: Any] = [:]
        for (k, v) in sections { dict[k] = v }
        mutator(&dict)

        var lines: [String] = ["# flow-local user config", ""]
        for (section, kv) in dict {
            guard let kvDict = kv as? [String: Any] else { continue }
            lines.append("[\(section)]")
            for (k, v) in kvDict {
                if let s = v as? String {
                    if s == "true" || s == "false" {
                        lines.append("\(k) = \(s)")
                    } else if Int(s) != nil || Double(s) != nil {
                        lines.append("\(k) = \(s)")
                    } else {
                        lines.append("\(k) = \"\(s)\"")
                    }
                } else {
                    lines.append("\(k) = \(v)")
                }
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    func restartPythonDaemon() {
        // Kill existing python -m flow processes
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-f", "python -u -m flow run"]
        try? task.run()
        task.waitUntilExit()
        // Spawn new daemon
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        cd \(home)/Desktop/flow-local && \
        source .venv/bin/activate && \
        nohup python -u -m flow run --verbose > /tmp/flow-daemon.log 2>&1 &
        """
        let spawn = Process()
        spawn.launchPath = "/bin/zsh"
        spawn.arguments = ["-c", script]
        try? spawn.run()
    }

    @objc func openDashboard() {
        DashboardWindowController.shared.showDashboard()
    }

    @objc func runTest() {
        Sounds.playStart()
        updateIcon(listening: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            Sounds.playStop()
            self?.updateIcon(listening: false)
        }
    }

    @objc func showDiagnostics() {
        let trusted = AXIsProcessTrustedWithOptions(nil)
        let alert = NSAlert()
        alert.messageText = "flow-local diagnostics"
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "✅ granted"
        case .denied: mic = "❌ denied"
        case .restricted: mic = "❌ restricted"
        case .notDetermined: mic = "⚠️ not requested yet"
        @unknown default: mic = "unknown"
        }
        alert.informativeText = """
            Accessibility (hotkey + AX context): \(trusted ? "✅ granted" : "❌ NOT GRANTED")
            Microphone: \(mic)
            Hotkey: \(hotkey.label)
            Sockets: /tmp/flow-local.sock, /tmp/flow-context.sock

            If Accessibility is not granted, the hotkey will silently do nothing.
            Use the menu to open settings and toggle flow-local on, then quit and relaunch this app.
            """
        alert.addButton(withTitle: "Request Microphone Now")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func showAXAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission required"
        alert.informativeText = """
            flow-local needs Accessibility + Input Monitoring permission to capture your hotkey globally \
            and read the focused text field for context.

            1. Click "Open Settings" below
            2. Add flow-local (or drag it from Applications)
            3. Enable the toggle
            4. Quit and relaunch flow-local
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }
}

// MARK: - Main

let chosen = parseArgs()
FileHandle.standardError.write("flow-helper: hotkey = \(chosen.label)\n".data(using: .utf8)!)

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.hotkey = chosen
app.delegate = delegate
app.run()
