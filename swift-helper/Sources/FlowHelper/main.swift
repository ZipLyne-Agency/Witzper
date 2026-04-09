// FlowHelper — macOS helper providing global hotkey + AX context over Unix sockets.
//
// Usage:
//   flow-helper --hotkey right_option
//   flow-helper --hotkey right_cmd
//   flow-helper --hotkey right_shift
//   flow-helper --hotkey caps_lock
//   flow-helper --hotkey fn
//
// Emits line-delimited JSON to /tmp/Witzper.sock:
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

// MARK: - Stream listener (daemon → HUD)

/// Connects to the Python daemon's /tmp/flow-stream.sock and forwards
/// `partial` / `transcript` / `recording` events to the HUD so the user
/// sees their words appear live while dictating (IDEAS #1).
final class StreamListener {
    private let path: String
    private let queue = DispatchQueue(label: "flow.stream.listener")
    private var stopped = false

    init(path: String = "/tmp/flow-stream.sock") {
        self.path = path
    }

    func start() {
        queue.async { [weak self] in self?.runLoop() }
    }

    private func runLoop() {
        while !stopped {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { sleep(1); continue }
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
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, len)
                }
            }
            if ok != 0 {
                close(fd)
                sleep(1)
                continue
            }
            // Line-delimited JSON reader
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !stopped {
                let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                buffer.append(chunk, count: n)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    handleLine(line)
                }
            }
            close(fd)
            sleep(1) // reconnect
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "partial":
            if let text = obj["text"] as? String {
                HUD.shared.setPartial(text)
            }
        case "transcript":
            if let text = obj["cleaned"] as? String {
                HUD.shared.setPartial(text)
            }
            HUD.shared.setStatus("Inserted")
        case "recording":
            if let state = obj["state"] as? String, state == "start" {
                HUD.shared.setStatus("Listening…")
                HUD.shared.setPartial("")
            }
        default:
            break
        }
    }
}

// MARK: - Hotkey bindings

/// Two kinds of triggers:
///   .modifier — satisfied when a set of modifier flag bits are all high
///               (fn, right_cmd, chords like right_cmd+right_option).
///   .key      — satisfied when a raw keycode (F5, F6, space, escape, …)
///               is held. Tracked via keyDown/keyUp, autorepeat ignored.
enum HotkeyTrigger {
    case modifier(CGEventFlags)
    case key(Int64)
}

/// Non-modifier virtual keycode table — enough to cover "pick any key you
/// want" for push-to-talk. Names are lowercase, matching the config format.
/// Keys that normally type characters (letters, digits) are deliberately
/// excluded — they'd make the hotkey unusable for typing. Function keys,
/// arrows, and the "standalone" keys (space/escape/return/tab) are fine.
let nonModifierKeycodes: [String: Int64] = [
    "f1": 122, "f2": 120, "f3": 99, "f4": 118,
    "f5": 96,  "f6": 97,  "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106,
    "f17": 64,  "f18": 79,  "f19": 80,  "f20": 90,
    "escape": 53, "space": 49, "return": 36, "tab": 48,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

/// One configurable shortcut. When two modifier bindings are simultaneously
/// satisfied (e.g. a single-key binding and a chord that contains it), only
/// the binding with the maximal flag set fires — see `HotkeyTap.handle`.
struct HotkeyBinding {
    let action: String
    let rawKey: String
    let trigger: HotkeyTrigger
    var isDown: Bool = false

    var modifierFlags: CGEventFlags {
        if case .modifier(let f) = trigger { return f } else { return [] }
    }
    var keycode: Int64? {
        if case .key(let k) = trigger { return k } else { return nil }
    }
    var isCapsLock: Bool { modifierFlags == .maskAlphaShift }
}

/// Parse a hotkey name into a trigger. Modifier chords (`"right_cmd+right_option"`)
/// become `.modifier`, single non-modifier keys (`"f5"`, `"space"`) become
/// `.key`. Mixing modifiers and non-modifiers isn't supported yet.
func parseHotkeyTrigger(_ name: String) -> HotkeyTrigger? {
    let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty { return nil }
    // Non-modifier single key (no chord form supported yet).
    if !trimmed.contains("+"), let kc = nonModifierKeycodes[trimmed] {
        return .key(kc)
    }
    var result: CGEventFlags = []
    for token in trimmed.split(separator: "+") {
        let key = String(token).trimmingCharacters(in: .whitespaces)
        guard let hk = Hotkey(rawValue: key) else { return nil }
        result.insert(hk.flag)
    }
    return result.isEmpty ? nil : .modifier(result)
}

/// Legacy name kept for the settings loader which only deals with modifier
/// bindings. Returns nil for keycode-based triggers.
func parseHotkeyFlags(_ name: String) -> CGEventFlags? {
    if case .modifier(let f) = parseHotkeyTrigger(name) ?? .key(0) { return f }
    return nil
}

// MARK: - Hotkey tap

final class HotkeyTap {
    var bindings: [HotkeyBinding]
    let onDown: (String) -> Void
    let onUp: (String) -> Void
    private var tap: CFMachPort?

    init(
        bindings: [HotkeyBinding],
        onDown: @escaping (String) -> Void,
        onUp: @escaping (String) -> Void
    ) {
        self.bindings = bindings
        self.onDown = onDown
        self.onUp = onUp
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
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
        // Non-modifier key bindings are driven by keyDown / keyUp.
        if type == .keyDown || type == .keyUp {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat { return }
            for i in bindings.indices {
                guard let kc = bindings[i].keycode, kc == keycode else { continue }
                if type == .keyDown && !bindings[i].isDown {
                    bindings[i].isDown = true
                    onDown(bindings[i].action)
                } else if type == .keyUp && bindings[i].isDown {
                    bindings[i].isDown = false
                    onUp(bindings[i].action)
                }
            }
            return
        }
        guard type == .flagsChanged else { return }
        let flags = event.flags

        // 1. Determine which modifier bindings are physically satisfied.
        //    Key (non-modifier) bindings are driven by keyDown/keyUp above
        //    and must not be touched here.
        var satisfied = Set<Int>()
        for i in bindings.indices {
            let b = bindings[i]
            if b.keycode != nil { continue }
            if b.isCapsLock { continue } // handled separately below
            let fs = b.modifierFlags
            if !fs.isEmpty && flags.contains(fs) {
                satisfied.insert(i)
            }
        }
        // 2. If a chord (cmd+opt) is satisfied, suppress its sub-bindings
        //    (just-cmd or just-opt). A binding is "primary" only if no
        //    other satisfied binding is a strict superset of its flagSet.
        var primary = Set<Int>()
        for i in satisfied {
            let me = bindings[i].modifierFlags
            var superseded = false
            for j in satisfied where j != i {
                let other = bindings[j].modifierFlags
                if other.rawValue & me.rawValue == me.rawValue && other != me {
                    superseded = true
                    break
                }
            }
            if !superseded { primary.insert(i) }
        }
        // 3. Reconcile each modifier binding's down state.
        for i in bindings.indices where bindings[i].keycode == nil && !bindings[i].isCapsLock {
            let shouldBeDown = primary.contains(i)
            if shouldBeDown && !bindings[i].isDown {
                bindings[i].isDown = true
                onDown(bindings[i].action)
            } else if !shouldBeDown && bindings[i].isDown {
                bindings[i].isDown = false
                onUp(bindings[i].action)
            }
        }
        // 4. Caps lock toggle semantics — the bit is latched, so we treat
        //    every flagsChanged with caps high as a press transition.
        let capsHigh = flags.contains(.maskAlphaShift)
        for i in bindings.indices where bindings[i].isCapsLock {
            if capsHigh {
                if !bindings[i].isDown {
                    bindings[i].isDown = true
                    onDown(bindings[i].action)
                } else {
                    bindings[i].isDown = false
                    onUp(bindings[i].action)
                }
            }
        }
    }
}

// MARK: - AX snapshot

func frontApp() -> NSRunningApplication? {
    NSWorkspace.shared.frontmostApplication
}

/// Full AXValue read of the currently focused text element. Not truncated
/// like axSnapshot() — the edit watcher needs the whole value to diff
/// against the inserted text. Returns nil if the field doesn't expose
/// AXValue (most Electron apps, terminals, rich-text editors).
func readFocusedTextFull() -> String? {
    guard let app = frontApp() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedElement: AnyObject?
    guard AXUIElementCopyAttributeValue(
        axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement
    ) == .success, let el = focusedElement else {
        return nil
    }
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(
        el as! AXUIElement, kAXValueAttribute as CFString, &value
    ) == .success else {
        return nil
    }
    return value as? String
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

        // Install a real main menu so TextField/TextEditor get ⌘C / ⌘V / ⌘X / ⌘A
        // through the standard first-responder selectors. Without this, paste is
        // silently dead in an .accessory app — Snippets, Dictionary, any input.
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(listening: false)

        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: "Witzper", action: nil, keyEquivalent: "")
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

        let startDaemonItem = NSMenuItem(
            title: "Start / Restart Python Daemon",
            action: #selector(menuRestartDaemon),
            keyEquivalent: "r"
        )
        startDaemonItem.target = self
        menu.addItem(startDaemonItem)

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(menuCheckForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

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
            title: "Quit Witzper",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Start servers
        let hotkeyServer = UnixSocketServer(path: "/tmp/Witzper.sock", queueLabel: "flow.hotkey")
        hotkeyServer.start()

        // Listen to the daemon's event stream for live partial transcripts.
        let listener = StreamListener()
        listener.start()
        self.retainedListener = listener
        let contextServer = UnixSocketServer(path: "/tmp/flow-context.sock", queueLabel: "flow.context")
        contextServer.start(requestHandler: { req in
            // Ops:
            //   snapshot           — default; full AX context for the focused app
            //   insert             — paste text via clipboard + ⌘V
            //   read_focused_text  — full AXValue of the focused field
            //   get_selection      — selected text in the focused field
            //                        (used by Command Mode to grab the user's
            //                        highlighted source text). Also caches
            //                        the source PID so a later replace can
            //                        re-target the original window.
            //   command_result     — show the Command Mode result panel with
            //                        Copy / Replace Selection / Dismiss.
            if let data = req.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let op = obj["op"] as? String {
                if op == "insert", let text = obj["text"] as? String {
                    Inserter.paste(text: text)
                    return "{\"ok\":true}"
                }
                if op == "read_focused_text" {
                    let text = readFocusedTextFull() ?? ""
                    if let data = try? JSONSerialization.data(
                        withJSONObject: ["text": text]
                    ), let s = String(data: data, encoding: .utf8) {
                        return s
                    }
                    return "{\"text\":\"\"}"
                }
                if op == "get_selection" {
                    let snap = axSnapshot()
                    let sel = (snap["selected_text"] as? String) ?? ""
                    if let app = NSWorkspace.shared.frontmostApplication {
                        CommandResultPanel.lastSourcePID = app.processIdentifier
                    }
                    if let data = try? JSONSerialization.data(
                        withJSONObject: ["selected_text": sel]
                    ), let s = String(data: data, encoding: .utf8) {
                        return s
                    }
                    return "{\"selected_text\":\"\"}"
                }
                if op == "command_result" {
                    let result = (obj["result"] as? String) ?? ""
                    let instr = (obj["instruction"] as? String) ?? ""
                    let had = (obj["had_selection"] as? Bool) ?? false
                    DispatchQueue.main.async {
                        CommandResultPanel.show(
                            instruction: instr,
                            result: result,
                            hadSelection: had
                        )
                    }
                    return "{\"ok\":true}"
                }
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
                "Witzper: Accessibility not granted. Click the menu bar icon → Open Accessibility Settings.\n".data(using: .utf8)!
            )
            updateIconNotTrusted()
        }

        // Start hotkey tap with all configured bindings.
        let bindings = loadHotkeyBindings(legacyFallback: hotkey)
        for b in bindings {
            FileHandle.standardError.write(
                "flow-helper: binding \(b.action) → \(b.rawKey)\n".data(using: .utf8)!
            )
        }
        let tap = HotkeyTap(
            bindings: bindings,
            onDown: { [weak self] action in
                let line = "{\"type\":\"hotkey_down\",\"action\":\"\(action)\"}"
                hotkeyServer.broadcast(line)
                DispatchQueue.main.async {
                    Sounds.playStart()
                    self?.updateIcon(listening: true, action: action)
                }
            },
            onUp: { [weak self] action in
                let line = "{\"type\":\"hotkey_up\",\"action\":\"\(action)\"}"
                hotkeyServer.broadcast(line)
                DispatchQueue.main.async {
                    Sounds.playStop()
                    self?.updateIcon(listening: false, action: action)
                }
            }
        )
        tap.start()
        self.retainedTap = tap

        // Ensure the Python daemon is up. Opening Witzper.app from
        // /Applications should "just work" without a separate terminal.
        DispatchQueue.global().async { [weak self] in
            self?.ensureDaemonRunning()
        }

        // Silent update check: runs at most once per 24h, only prompts
        // the user if a newer release is actually available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in Updater.checkSilently() }
        }

        // First-launch onboarding: shows permissions + mic picker flow.
        if !UserDefaults.standard.bool(forKey: "witzperOnboardingComplete") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    var retainedTap: HotkeyTap?
    var retainedListener: StreamListener?

    func installMainMenu() {
        let main = NSMenu()

        // App menu (title ignored; macOS uses process name)
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Witzper", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Witzper",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Witzper",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        // Edit menu — the whole point of installing a main menu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete",
                         action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    func updateIcon(listening: Bool, action: String = "dictate") {
        isListening = listening
        if let button = statusItem.button {
            let glyph = action == "command" ? "🟣" : "🔴"
            button.title = listening ? "\(glyph) Witzper" : "⚪ Witzper"
            button.toolTip = listening
                ? (action == "command" ? "Command Mode…" : "Listening…")
                : "Witzper ready"
        }
        if listening {
            HUD.shared.show()
        } else {
            HUD.shared.hide()
        }
    }

    func updateIconNotTrusted() {
        if let button = statusItem.button {
            button.title = "⚠ Witzper"
            button.toolTip = "Witzper: grant Accessibility permission"
        }
    }

    @objc func changeHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let hk = Hotkey(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "Change hotkey to \(hk.label)?"
        alert.informativeText = "Witzper will quit. Relaunch it from your Applications folder or Terminal."
        alert.addButton(withTitle: "Change & Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            // Write to user config
            let home = FileManager.default.homeDirectoryForCurrentUser
            let cfgDir = home.appendingPathComponent(".config/Witzper")
            try? FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
            let cfgPath = cfgDir.appendingPathComponent("config.toml")
            let content = "# Witzper user config\n[hotkey]\nkey = \"\(hk.rawValue)\"\ntoggle_mode = false\n"
            try? content.write(to: cfgPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func readCurrentMic() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Witzper/config.toml")
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
        let dir = home.appendingPathComponent(".config/Witzper")
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

        var lines: [String] = ["# Witzper user config", ""]
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

    /// Spawn the Python daemon if it isn't already running. Called on app
    /// launch so opening Witzper.app from /Applications is a one-click start
    /// — previously the user had to manually run ``python -m flow run``.
    func ensureDaemonRunning() {
        let check = Process()
        check.launchPath = "/usr/bin/pgrep"
        check.arguments = ["-f", "flow run"]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = Pipe()
        do { try check.run() } catch { return }
        check.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let output = String(data: data, encoding: .utf8) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            FileHandle.standardError.write(
                "Witzper: python daemon already running — skip spawn\n".data(using: .utf8)!
            )
            return
        }
        FileHandle.standardError.write(
            "Witzper: spawning python daemon…\n".data(using: .utf8)!
        )
        spawnPythonDaemon()
    }

    /// Spawn the daemon unconditionally. Tries the native ./Witzper launcher
    /// first (shows "Witzper" in Activity Monitor), falls back to plain
    /// ``python -m flow run``. Both are detached via nohup+background so
    /// they outlive the Swift helper's own lifecycle if it crashes.
    func spawnPythonDaemon() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        cd \(home)/Witzper && \
        if [[ -f .venv/bin/activate ]]; then source .venv/bin/activate; fi && \
        export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH && \
        if [[ -x ./Witzper ]]; then \
          nohup ./Witzper --verbose > /tmp/flow-daemon.log 2>&1 & \
        else \
          nohup python3 -u -m flow run --verbose > /tmp/flow-daemon.log 2>&1 & \
        fi
        """
        let spawn = Process()
        spawn.launchPath = "/bin/zsh"
        spawn.arguments = ["-c", script]
        do {
            try spawn.run()
        } catch {
            FileHandle.standardError.write(
                "Witzper: failed to spawn daemon: \(error)\n".data(using: .utf8)!
            )
        }
    }

    func restartPythonDaemon() {
        // Kill any previous daemon instance. We match by:
        //   1. `flow run`            — plain `python -m flow run …`
        //   2. $HOME/Witzper/Witzper — native launcher, regardless of argv
        //                              (old bug: matching "./Witzper" or
        //                              "--verbose" missed the launcher once
        //                              argv[0] became a bare "Witzper").
        // The /Applications/Witzper.app menu-bar helper is deliberately
        // excluded by using the absolute repo path — pkill -f won't match
        // it.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for pattern in ["flow run", "\(home)/Witzper/Witzper"] {
            let k = Process()
            k.launchPath = "/usr/bin/pkill"
            k.arguments = ["-9", "-f", pattern]
            try? k.run()
            k.waitUntilExit()
        }
        // Give macOS a beat to reap the processes before we spawn a replacement.
        Thread.sleep(forTimeInterval: 0.3)
        // Spawn new daemon — prefer the native ./Witzper launcher so
        // Activity Monitor shows "Witzper" as the process name.
        let script = """
        cd \(home)/Witzper && \
        source .venv/bin/activate && \
        if [[ -x ./Witzper ]]; then \
          nohup ./Witzper --verbose > /tmp/flow-daemon.log 2>&1 & \
        else \
          nohup python -u -m flow run --verbose > /tmp/flow-daemon.log 2>&1 & \
        fi
        """
        let spawn = Process()
        spawn.launchPath = "/bin/zsh"
        spawn.arguments = ["-c", script]
        try? spawn.run()
    }

    @objc func menuRestartDaemon() {
        restartPythonDaemon()
    }

    @objc func menuCheckForUpdates() {
        Task { @MainActor in Updater.checkInteractively() }
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
        alert.messageText = "Witzper diagnostics"
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
            Sockets: /tmp/Witzper.sock, /tmp/flow-context.sock

            If Accessibility is not granted, the hotkey will silently do nothing.
            Use the menu to open settings and toggle Witzper on, then quit and relaunch this app.
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
            Witzper needs Accessibility + Input Monitoring permission to capture your hotkey globally \
            and read the focused text field for context.

            1. Click "Open Settings" below
            2. Add Witzper (or drag it from Applications)
            3. Enable the toggle
            4. Quit and relaunch Witzper
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }
}

// MARK: - User config reader

/// Minimal TOML reader: returns sections as `[section name → [key → value]]`.
/// Strings are unquoted; everything else stays as the raw token. Sufficient
/// for the small number of fields we read out of `~/.config/Witzper/config.toml`.
func readUserConfigSections() -> [String: [String: String]] {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Witzper/config.toml")
    guard let txt = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
    var sections: [String: [String: String]] = [:]
    var current = ""
    for raw in txt.components(separatedBy: "\n") {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { continue }
        if s.hasPrefix("[") && s.hasSuffix("]") {
            current = String(s.dropFirst().dropLast())
            if sections[current] == nil { sections[current] = [:] }
            continue
        }
        guard let eq = s.firstIndex(of: "=") else { continue }
        let k = s[..<eq].trimmingCharacters(in: .whitespaces)
        var v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        if sections[current] == nil { sections[current] = [:] }
        sections[current]![k] = v
    }
    return sections
}

/// Build the active hotkey binding list from user config. Falls back to
/// the legacy single-hotkey field (and to the CLI/env override) so older
/// configs keep working.
func loadHotkeyBindings(legacyFallback: Hotkey) -> [HotkeyBinding] {
    var out: [HotkeyBinding] = []
    let sections = readUserConfigSections()

    // Pull every [hotkeys.<action>] section.
    var found = false
    for (name, kv) in sections where name.hasPrefix("hotkeys.") {
        found = true
        let action = String(name.dropFirst("hotkeys.".count))
        guard let key = kv["key"], !key.isEmpty,
              let trig = parseHotkeyTrigger(key) else { continue }
        out.append(HotkeyBinding(action: action, rawKey: key, trigger: trig))
    }
    if !found {
        let dictateKey: String
        if let kv = sections["hotkey"], let k = kv["key"], !k.isEmpty {
            dictateKey = k
        } else {
            dictateKey = legacyFallback.rawValue
        }
        if let trig = parseHotkeyTrigger(dictateKey) {
            out.append(HotkeyBinding(
                action: "dictate", rawKey: dictateKey, trigger: trig
            ))
        }
        let chord = "right_cmd+right_option"
        if let trig = parseHotkeyTrigger(chord) {
            out.append(HotkeyBinding(
                action: "command", rawKey: chord, trigger: trig
            ))
        }
    }
    return out
}

// MARK: - Command Mode result panel

/// Small modal panel shown after Command Mode finishes a transformation.
/// Buttons: Copy (always), Replace Selection (only if the user had a real
/// AX selection at trigger time), Dismiss. Replace re-targets the original
/// app via the cached PID so the alert stealing focus doesn't matter.
enum CommandResultPanel {
    static var lastSourcePID: pid_t = 0

    static func show(instruction: String, result: String, hadSelection: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Command: \(instruction)"
        // NSAlert truncates long bodies; cap so the panel stays usable.
        let preview = result.count > 1500
            ? String(result.prefix(1500)) + "\n…"
            : result
        alert.informativeText = preview
        alert.addButton(withTitle: "Copy")
        if hadSelection {
            alert.addButton(withTitle: "Replace Selection")
        }
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result, forType: .string)
        } else if hadSelection && response == .alertSecondButtonReturn {
            replaceSelection(with: result)
        }
    }

    /// Activate the source app and write the result back. Tries the AX
    /// `kAXSelectedTextAttribute` setter first (works in Xcode, Notes,
    /// Mail, most native text fields), falls back to clipboard + ⌘V.
    private static func replaceSelection(with text: String) {
        if lastSourcePID != 0,
           let app = NSRunningApplication(processIdentifier: lastSourcePID) {
            app.activate(options: .activateIgnoringOtherApps)
            // Give the activation ~150ms to land before we touch AX/paste.
            Thread.sleep(forTimeInterval: 0.15)
            let axApp = AXUIElementCreateApplication(lastSourcePID)
            var focused: AnyObject?
            if AXUIElementCopyAttributeValue(
                axApp,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success, let el = focused {
                let setResult = AXUIElementSetAttributeValue(
                    el as! AXUIElement,
                    kAXSelectedTextAttribute as CFString,
                    text as CFString
                )
                if setResult == .success { return }
            }
        }
        Inserter.paste(text: text)
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
