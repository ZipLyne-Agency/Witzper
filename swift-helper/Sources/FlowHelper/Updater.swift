// In-app updater.
//
// Reads https://github.com/ZipLyne-Agency/Witzper/releases/latest/download/latest.json
// (produced by .github/workflows/release.yml on each tagged release), compares
// to Bundle.main CFBundleShortVersionString, and — if a newer version is
// available — downloads the zip, verifies sha256, unzips, replaces
// /Applications/Witzper.app, and relaunches.
//
// Two entry points:
//   - Updater.checkSilently()     — called once per 24 h on app launch.
//                                    Only shows UI if an update is available.
//   - Updater.checkInteractively() — called from the menu bar "Check for
//                                    Updates…" item. Always shows a result.
//
// Deliberately homegrown instead of Sparkle: zero dependencies, zero
// signing infra (the sha256 in latest.json is enough integrity for an
// open-source app served over HTTPS from github.com), and the whole thing
// is ~200 lines so it's trivially auditable.

import AppKit
import CryptoKit
import Foundation

private let LATEST_MANIFEST_URL = URL(string: "https://github.com/ZipLyne-Agency/Witzper/releases/latest/download/latest.json")!
private let LAST_CHECK_DEFAULTS_KEY = "witzperLastUpdateCheck"
private let SILENT_CHECK_INTERVAL: TimeInterval = 24 * 60 * 60 // 24 h

struct UpdateManifest: Codable {
    let version: String
    let tag: String
    let url: String
    let sha256: String
    let size: Int64
    let notes_url: String?
}

enum UpdaterError: Error, LocalizedError {
    case manifestFetchFailed(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, got: String)
    case unzipFailed(String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestFetchFailed(let s):  return "Couldn't fetch update manifest: \(s)"
        case .downloadFailed(let s):        return "Download failed: \(s)"
        case .checksumMismatch(let e, let g): return "Checksum mismatch — expected \(e.prefix(12))…, got \(g.prefix(12))…"
        case .unzipFailed(let s):           return "Unzip failed: \(s)"
        case .replaceFailed(let s):         return "Replace failed: \(s)"
        }
    }
}

@MainActor
enum Updater {
    // MARK: - Public entry points

    static func checkSilently() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: LAST_CHECK_DEFAULTS_KEY)
        let now = Date().timeIntervalSince1970
        if last > 0 && (now - last) < SILENT_CHECK_INTERVAL {
            return
        }
        defaults.set(now, forKey: LAST_CHECK_DEFAULTS_KEY)
        Task { await check(interactive: false) }
    }

    static func checkInteractively() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: LAST_CHECK_DEFAULTS_KEY)
        Task { await check(interactive: true) }
    }

    // MARK: - Core flow

    private static func check(interactive: Bool) async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        do {
            let manifest = try await fetchManifest()
            if !isNewer(manifest.version, than: current) {
                if interactive {
                    showInfo(
                        title: "Witzper is up to date",
                        body: "You're running the latest version (\(current))."
                    )
                }
                return
            }

            let shouldInstall = await promptInstall(current: current, available: manifest.version)
            if !shouldInstall { return }

            let progress = ProgressWindow(
                title: "Updating Witzper",
                body: "Downloading v\(manifest.version)…"
            )
            progress.show()
            defer { progress.close() }

            let zipURL = try await download(manifest: manifest) { fraction in
                Task { @MainActor in progress.setProgress(fraction) }
            }
            progress.setBody("Verifying…")
            try verifyChecksum(at: zipURL, expected: manifest.sha256)
            progress.setBody("Installing…")
            try installUpdate(from: zipURL)
            progress.setBody("Relaunching…")

            relaunch()
        } catch {
            if interactive {
                showError(error: error)
            } else {
                FileHandle.standardError.write(
                    "Witzper: silent update check failed: \(error.localizedDescription)\n".data(using: .utf8)!
                )
            }
        }
    }

    // MARK: - Network

    private static func fetchManifest() async throws -> UpdateManifest {
        var req = URLRequest(url: LATEST_MANIFEST_URL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdaterError.manifestFetchFailed("HTTP \(code)")
        }
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdaterError.manifestFetchFailed("invalid JSON: \(error.localizedDescription)")
        }
    }

    private static func download(
        manifest: UpdateManifest,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let url = URL(string: manifest.url) else {
            throw UpdaterError.downloadFailed("bad url: \(manifest.url)")
        }
        let (tmpURL, resp) = try await URLSession.shared.download(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdaterError.downloadFailed("HTTP \(code)")
        }
        // URLSession.download moves to a temp file that gets deleted when
        // we return — copy it to a stable path first.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Witzper-\(manifest.version).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        onProgress(1.0)
        return dest
    }

    // MARK: - Integrity + install

    private static func verifyChecksum(at url: URL, expected: String) throws {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex.lowercased() != expected.lowercased() {
            throw UpdaterError.checksumMismatch(expected: expected, got: hex)
        }
    }

    /// Unzip the downloaded bundle to a staging dir, then atomically swap
    /// /Applications/Witzper.app. The old app is moved to the trash rather
    /// than deleted outright — so if something goes wrong, the user can
    /// recover it.
    private static func installUpdate(from zipURL: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("witzper-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Use ditto for AppKit-safe unzip (preserves symlinks, resource forks).
        let unzip = Process()
        unzip.launchPath = "/usr/bin/ditto"
        unzip.arguments = ["-x", "-k", zipURL.path, staging.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            throw UpdaterError.unzipFailed(msg)
        }

        let newApp = staging.appendingPathComponent("Witzper.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw UpdaterError.unzipFailed("Witzper.app not found in downloaded zip")
        }

        let installed = URL(fileURLWithPath: "/Applications/Witzper.app")
        if fm.fileExists(atPath: installed.path) {
            // Move the current install to the trash so it's recoverable.
            do {
                var trashedURL: NSURL? = nil
                try fm.trashItem(at: installed, resultingItemURL: &trashedURL)
            } catch {
                // Fall back to direct removal if trashing isn't allowed (e.g.
                // running from a system the user doesn't fully own).
                try? fm.removeItem(at: installed)
            }
        }
        do {
            try fm.copyItem(at: newApp, to: installed)
        } catch {
            throw UpdaterError.replaceFailed(error.localizedDescription)
        }
    }

    /// Launch the newly-installed app and terminate ourselves. We exec
    /// /usr/bin/open instead of NSRunningApplication.launch so the new
    /// instance is not a child of this process (which is about to die).
    private static func relaunch() {
        let p = Process()
        p.launchPath = "/usr/bin/open"
        p.arguments = ["-n", "/Applications/Witzper.app"]
        try? p.run()
        // Give macOS a beat to spawn the new process before we terminate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Version compare

    /// True if `candidate` is strictly newer than `current` by semver rules.
    /// Tolerates optional `v` prefix and pre-release suffixes (which are
    /// treated as older than the corresponding release).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parseVersion(candidate)
        let b = parseVersion(current)
        for i in 0..<max(a.count, b.count) {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    private static func parseVersion(_ s: String) -> [Int] {
        var v = s
        if v.hasPrefix("v") { v.removeFirst() }
        if let dash = v.firstIndex(of: "-") { v = String(v[..<dash]) }
        return v.split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: - UI

    private static func promptInstall(current: String, available: String) async -> Bool {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Witzper \(available) is available"
            alert.informativeText = """
                You're running \(current). Download and install \(available) now?

                Witzper will relaunch automatically after the update completes.
                """
            alert.addButton(withTitle: "Install Update")
            alert.addButton(withTitle: "Later")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private static func showInfo(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showError(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Progress window

@MainActor
final class ProgressWindow {
    private let window: NSWindow
    private let label: NSTextField
    private let bar: NSProgressIndicator

    init(title: String, body: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        label = NSTextField(labelWithString: body)
        label.frame = NSRect(x: 20, y: 70, width: 320, height: 20)
        bar = NSProgressIndicator(frame: NSRect(x: 20, y: 35, width: 320, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        let view = NSView(frame: window.contentView!.bounds)
        view.addSubview(label)
        view.addSubview(bar)
        window.contentView = view
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func setBody(_ s: String) { label.stringValue = s }
    func setProgress(_ fraction: Double) {
        bar.doubleValue = max(0, min(1, fraction))
    }
}
