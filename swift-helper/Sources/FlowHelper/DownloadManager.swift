// In-app model download manager.
//
// Spawns `hf download <repo>` as a child process and streams progress by
// polling the HuggingFace cache directory size. We chose directory-size
// polling over stdout parsing because hf_transfer's tqdm output changes
// shape between versions — directory size is authoritative and robust.

import Combine
import Foundation

struct DownloadState: Equatable {
    var modelId: String
    var bytesDownloaded: Int64 = 0
    var bytesExpected: Int64 = 0
    var isRunning: Bool = false
    var error: String? = nil

    var progress: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(bytesExpected))
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var state: [String: DownloadState] = [:]

    private var processes: [String: Process] = [:]
    private var timers: [String: Timer] = [:]

    func start(modelId: String, expectedBytes: Int64) {
        if let existing = state[modelId], existing.isRunning { return }

        state[modelId] = DownloadState(
            modelId: modelId,
            bytesDownloaded: currentCacheSize(for: modelId),
            bytesExpected: expectedBytes,
            isRunning: true,
            error: nil
        )

        let p = Process()
        p.launchPath = "/bin/zsh"
        // Try common install locations for the hf CLI. Fall back to PATH.
        let script = """
        export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
        if command -v hf >/dev/null 2>&1; then
            hf download \(modelId)
        else
            python -m pip install -q 'huggingface_hub[cli]' >/dev/null 2>&1 && \
            hf download \(modelId)
        fi
        """
        p.arguments = ["-lc", script]

        // Discard child stdout/stderr — we're polling the FS for progress.
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        if let devNull = devNull {
            p.standardOutput = devNull
            p.standardError = devNull
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                self.timers[modelId]?.invalidate()
                self.timers.removeValue(forKey: modelId)
                self.processes.removeValue(forKey: modelId)
                var s = self.state[modelId] ?? DownloadState(modelId: modelId)
                s.isRunning = false
                s.bytesDownloaded = self.currentCacheSize(for: modelId)
                if proc.terminationStatus != 0 && !ModelStatus.isDownloaded(modelId) {
                    s.error = "hf download exited \(proc.terminationStatus)"
                } else {
                    s.bytesExpected = max(s.bytesExpected, s.bytesDownloaded)
                }
                self.state[modelId] = s
            }
        }

        do {
            try p.run()
            processes[modelId] = p
        } catch {
            var s = state[modelId] ?? DownloadState(modelId: modelId)
            s.isRunning = false
            s.error = "failed to launch hf: \(error.localizedDescription)"
            state[modelId] = s
            return
        }

        // Poll cache dir size every 500 ms.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard var s = self.state[modelId], s.isRunning else { return }
                s.bytesDownloaded = self.currentCacheSize(for: modelId)
                // If the folder already exceeds our estimate, grow the estimate
                // so the bar still makes sense.
                if s.bytesDownloaded > s.bytesExpected {
                    s.bytesExpected = s.bytesDownloaded + 100_000_000
                }
                self.state[modelId] = s
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[modelId] = timer
    }

    func cancel(modelId: String) {
        if let p = processes[modelId] {
            p.terminate()
        }
        timers[modelId]?.invalidate()
        timers.removeValue(forKey: modelId)
        processes.removeValue(forKey: modelId)
        var s = state[modelId] ?? DownloadState(modelId: modelId)
        s.isRunning = false
        s.error = "cancelled"
        state[modelId] = s
    }

    // Sum of file sizes under the HF cache's snapshot directories for this repo.
    nonisolated func currentCacheSize(for modelId: String) -> Int64 {
        let safe = modelId.replacingOccurrences(of: "/", with: "--")
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(safe)")
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey, .isRegularFileKey
                ])
                if values?.isRegularFile == true, let sz = values?.totalFileAllocatedSize {
                    total += Int64(sz)
                }
            }
        }
        return total
    }
}
