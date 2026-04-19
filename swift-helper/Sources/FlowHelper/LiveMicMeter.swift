// Live RMS meter — a tiny AVCaptureSession reader used during onboarding
// so users can confirm their selected microphone is actually picking up
// their voice before Witzper starts the main inference daemon.
//
// Deliberately lightweight: we reuse AVCaptureSession instead of pulling
// in PortAudio/sounddevice here because this is just a sanity bar, not
// the hot path. The real dictation audio pipeline still runs in Python.

@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class MicMeterDriver: ObservableObject {
    @Published var level: Float = 0  // 0..1
    @Published var peakHold: Float = 0

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let outputQueue = DispatchQueue(label: "witzper.mic.meter", qos: .userInitiated)
    private var decayTimer: Timer?
    private var processor: AudioLevelProcessor?

    func start(deviceName: String) {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let device = resolveDevice(named: deviceName)
        guard let dev = device, let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let processor = AudioLevelProcessor { [weak self] lvl in
            guard let self = self else { return }
            Task { @MainActor in
                let smoothed = 0.4 * lvl + 0.6 * self.level
                self.level = smoothed
                if lvl > self.peakHold { self.peakHold = lvl }
            }
        }
        self.processor = processor
        output.setSampleBufferDelegate(processor, queue: outputQueue)

        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        self.session = session
        self.audioOutput = output
        outputQueue.async { session.startRunning() }

        // Decay peak hold so the marker doesn't stick at 1.0 forever.
        decayTimer?.invalidate()
        decayTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.peakHold = max(0, self.peakHold - 0.01)
            }
        }
        RunLoop.main.add(decayTimer!, forMode: .common)
    }

    func stop() {
        decayTimer?.invalidate()
        decayTimer = nil
        if let s = session {
            outputQueue.async { s.stopRunning() }
        }
        session = nil
        audioOutput = nil
        processor = nil
        level = 0
        peakHold = 0
    }

    private func resolveDevice(named: String) -> AVCaptureDevice? {
        if named == "System Default" || named.isEmpty {
            return AVCaptureDevice.default(for: .audio)
        }
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        let devs = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .audio, position: .unspecified
        ).devices
        return devs.first(where: { $0.localizedName == named }) ?? AVCaptureDevice.default(for: .audio)
    }
}

/// Separate NSObject subclass so we can conform to the @objc sample buffer
/// delegate protocol without polluting the observable class.
private final class AudioLevelProcessor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onLevel: (Float) -> Void

    init(onLevel: @escaping (Float) -> Void) {
        self.onLevel = onLevel
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPtr
        ) == kCMBlockBufferNoErr, let samples = dataPtr else { return }

        // AVCapture delivers int16 LPCM by default. Compute RMS, map to 0..1
        // with a perceptual log scale (peak ~-3 dBFS → ~0.9).
        let count = totalLength / MemoryLayout<Int16>.size
        var sumSq: Double = 0
        samples.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
            for i in 0..<count {
                let v = Double(ptr[i]) / 32768.0
                sumSq += v * v
            }
        }
        let rms = sqrt(sumSq / Double(max(count, 1)))
        let db = 20 * log10(max(rms, 1e-6))
        let norm = Float(max(0, min(1, (db + 60) / 60)))  // -60..0 dBFS → 0..1
        onLevel(norm)
    }
}

struct LiveMicMeter: View {
    let deviceName: String
    @StateObject private var driver = MicMeterDriver()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TEST YOUR MIC — SPEAK NOW")
                .font(.bbSmall).foregroundColor(.bbDim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.08))
                    // Segmented bars like the dashboard meter for visual
                    // consistency.
                    HStack(spacing: 2) {
                        ForEach(0..<30, id: \.self) { i in
                            Rectangle()
                                .fill(barColor(i))
                                .frame(width: max(geo.size.width / 30 - 2, 1))
                        }
                    }
                    // Peak marker — last max level, decays slowly.
                    let peakX = geo.size.width * CGFloat(min(driver.peakHold, 1.0))
                    Rectangle()
                        .fill(Color.bbAmber)
                        .frame(width: 2)
                        .offset(x: peakX)
                }
            }
            .frame(height: 22)
        }
        .onAppear { driver.start(deviceName: deviceName) }
        .onChange(of: deviceName) { _, new in driver.start(deviceName: new) }
        .onDisappear { driver.stop() }
    }

    private func barColor(_ idx: Int) -> Color {
        let lit = Int(driver.level * 30)
        if idx >= lit { return Color(white: 0.11) }
        if idx < 18 { return .bbGreen }
        if idx < 25 { return .bbAmber }
        return .bbRed
    }
}
