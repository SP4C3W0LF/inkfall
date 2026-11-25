import AVFoundation
import Foundation

struct AudioClip: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

protocol VoiceActivityDetector: Sendable {
    func containsSpeech(samples: ArraySlice<Float>) -> Bool
    func trimSilence(samples: [Float], sampleRate: Double) -> [Float]
}

struct EnergyVoiceActivityDetector: VoiceActivityDetector {
    private let threshold: Float = 0.012
    private let trimWindowSamples = 1_600

    func containsSpeech(samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        let rms = sqrt(samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count))
        return rms >= threshold
    }

    func trimSilence(samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let window = max(400, min(trimWindowSamples, Int(sampleRate / 10)))
        var start = 0
        while start + window < samples.count {
            if containsSpeech(samples: samples[start..<(start + window)]) { break }
            start += window
        }

        var end = samples.count
        while end - window > start {
            if containsSpeech(samples: samples[(end - window)..<end]) { break }
            end -= window
        }

        return Array(samples[start..<end])
    }
}

/// What the input node reports right now, as plain numbers. A rate or channel
/// count of 0 means the route is not ready yet (seen for a moment at launch and
/// while a Bluetooth headset switches its microphone on).
struct CaptureInputFormat: Equatable, Sendable {
    var sampleRate: Double
    var channels: Int
    var isValid: Bool { sampleRate > 0 && channels > 0 }
}

/// The few engine operations the capture service needs, so the retry and
/// device-change logic can be tested with a fake and no microphone.
protocol CaptureEngine: AnyObject {
    /// Identity of the underlying engine, to match configuration-change notifications.
    var engineID: ObjectIdentifier { get }
    var isRunning: Bool { get }
    /// The input node's format right now (read at the moment of use, never cached).
    func inputFormat() -> CaptureInputFormat
    /// Installs the tap on the input node. The handler gets channel 0 and the rate
    /// of the buffer it came from. It runs on the audio thread.
    func installTap(_ handler: @escaping @Sendable ([Float], Double) -> Void) throws
    func removeTap()
    func start() throws
    func pause()
    func stop()
}

/// The real engine. Kept thin on purpose: everything with a decision in it is in the service.
final class LiveCaptureEngine: CaptureEngine {
    private let engine = AVAudioEngine()

    var engineID: ObjectIdentifier { ObjectIdentifier(engine) }
    var isRunning: Bool { engine.isRunning }

    func inputFormat() -> CaptureInputFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return CaptureInputFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    func installTap(_ handler: @escaping @Sendable ([Float], Double) -> Void) throws {
        let input = engine.inputNode
        // A nil format makes the node use its own current format, so the tap never
        // carries a stale one; the rate comes from each buffer.
        if #available(macOS 27.0, *) {
            // macOS 27 deprecated installTap(onBus:…block:) in favor of the throwing
            // installAudioTap, whose block hands back a Sendable read-only buffer.
            try input.installAudioTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
                guard case .float(let span) = buffer.channelData(0) else { return }
                let frameCount = min(buffer.frameLength, span.count)
                guard frameCount > 0 else { return }
                var samples: [Float] = []
                samples.reserveCapacity(frameCount)
                for index in 0..<frameCount { samples.append(span[index]) }
                handler(samples, buffer.format.sampleRate)
            }
        } else {
            // macOS 26 (Tahoe): the classic tap. Its buffer isn't Sendable, so the
            // callback copies channel 0 into a [Float] before anything escapes.
            input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
                handler(samples, buffer.format.sampleRate)
            }
        }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func start() throws { try engine.start() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }
}

/// Thrown when the input reports no usable format yet.
struct CaptureInputNotReady: LocalizedError {
    var errorDescription: String? { "the input isn't ready" }
}

/// What the HUD shows when every attempt to start failed. Short, and it carries the
/// CoreAudio code so a bug report can name it.
func captureStartFailureMessage(for error: Error) -> String {
    let ns = error as NSError
    let detail: String
    if ns.domain == "com.apple.coreaudio.avfaudio" {
        detail = "error \(ns.code)"
    } else {
        detail = error.localizedDescription
    }
    return "Couldn't start the microphone (\(detail)). Try again or pick another input."
}

struct CaptureStartError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { captureStartFailureMessage(for: underlying) }
}

final class AudioCaptureService: @unchecked Sendable {
    /// Replaced, never reused after the input may have changed: an engine keeps the
    /// old device's format, and every tap installed on it fails the same way (-10877).
    private var engine: CaptureEngine
    private let makeEngine: () -> CaptureEngine
    private let sleep: (TimeInterval) -> Void
    private let queue = DispatchQueue(label: "Inkfall.AudioCapture")
    private let vad: VoiceActivityDetector
    private let targetSampleRate = 16_000.0
    private var state = CaptureState()

    /// Waits before attempts 2, 3 and 4 (a Bluetooth headset needs a moment to
    /// switch its microphone on). Four attempts in all, about a second at worst.
    static let retryDelays: [TimeInterval] = [0.15, 0.3, 0.6]

    // Live input level (RMS, ~0...1 scaled), read from the main thread by the HUD
    // waveform. Written on the audio thread; guarded by a lock.
    private let levelLock = NSLock()
    private var _level: Float = 0

    /// Latest microphone level. Thread-safe; safe to call from any thread.
    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _level
    }

    /// Called (on the capture queue) when the audio device changed during a
    /// recording and the recording could not be continued. The recording has been
    /// stopped but its samples are KEPT: the owner calls `stop()` to collect them.
    /// Set once, before the first start().
    var onInterrupted: (@Sendable (String) -> Void)?

    // Observer token for the engines' configuration-change notification. The
    // service lives as long as the app, so it is never removed (and a nonisolated
    // deinit could not touch it anyway). It watches every engine and ignores the
    // ones that are not the current one.
    private var configurationObserver: NSObjectProtocol?

    init(
        vad: VoiceActivityDetector,
        makeEngine: @escaping () -> CaptureEngine = { LiveCaptureEngine() },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.vad = vad
        self.makeEngine = makeEngine
        self.sleep = sleep
        self.engine = makeEngine()
        // The block runs on whatever thread AVFoundation posts from, so it touches
        // nothing but the service's own serial queue, exactly like the tap callback.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let object = note.object else { return }
            self?.handleConfigurationChange(from: ObjectIdentifier(object as AnyObject))
        }
    }

    /// The input device changed (headphones, a different default mic, a sample-rate
    /// switch, a Bluetooth headset changing profile). The engine has stopped and its
    /// format is stale, so it is dropped for a fresh one. Not recording: the next
    /// start uses the fresh engine. Recording: keep what was captured and carry on
    /// with a fresh engine and tap (with the same retries as a start); only if that
    /// fails, or the changes keep coming, stop and hand back what was captured.
    func handleConfigurationChange(from id: ObjectIdentifier) {
        queue.async {
            // A notification from an engine that was already replaced is old news.
            guard id == self.engine.engineID else { return }
            let change = self.state.configurationChanged(at: ProcessInfo.processInfo.systemUptime)
            self.replaceEngine()
            switch change {
            case .ignored:
                self.setLevel(0)
            case .resume:
                do {
                    try self.bringUp()
                } catch {
                    self.state.resumeFailed()
                    self.setLevel(0)
                    self.onInterrupted?("The audio device changed. Try again.")
                }
            case .stopKeepingSamples:
                self.setLevel(0)
                self.onInterrupted?("The audio device changed. Try again.")
            }
        }
    }

    /// Waits for everything queued so far (tests only).
    func waitUntilIdle() { queue.sync {} }

    func start() throws {
        try queue.sync {
            // Reset only the per-recording fields. `tapInstalled` MUST persist: the tap
            // lives on the input node across recordings, and installing a second one
            // throws "required condition is false: nullptr == Tap()".
            guard state.begin() else { return }
            do {
                try bringUp()
            } catch {
                // Leave nothing half-done: a stuck isRecording would make every later
                // start() a silent no-op, and a half-installed tap would make the
                // next install throw. bringUp already dropped the engine and its tap.
                state.startFailed()
                throw error
            }
        }
        setLevel(0)
    }

    func stop() -> AudioClip {
        setLevel(0)
        return queue.sync {
            state.isRecording = false
            // Pause so the mic is released and no per-buffer work runs while idle;
            // start() resumes via `if !engine.isRunning`. The tap stays installed.
            engine.pause()
            let samples = vad.trimSilence(samples: state.recordedSamples, sampleRate: targetSampleRate)
            return AudioClip(samples: samples, sampleRate: targetSampleRate)
        }
    }

    // MARK: - Engine lifecycle (all on `queue`)

    /// Drops the current engine (tap off, stopped) and builds a fresh one.
    private func replaceEngine() {
        engine.removeTap()
        engine.stop()
        engine = makeEngine()
        state.tapInstalled = false
    }

    /// Starts the current engine, and on failure swaps in a fresh one and tries
    /// again after a short wait: up to 4 attempts. Throws a readable error when
    /// every attempt failed; the engine left behind is fresh and untapped.
    private func bringUp() throws {
        var lastError: Error = CaptureInputNotReady()
        for attempt in 0...Self.retryDelays.count {
            do {
                try startCurrentEngine()
                return
            } catch {
                lastError = error
                replaceEngine()
                if attempt < Self.retryDelays.count { sleep(Self.retryDelays[attempt]) }
            }
        }
        throw CaptureStartError(underlying: lastError)
    }

    private func startCurrentEngine() throws {
        // Read now, never cached; an input that is not ready is a failed attempt.
        guard engine.inputFormat().isValid else { throw CaptureInputNotReady() }
        if !state.tapInstalled {
            try engine.installTap { [weak self] samples, inputRate in
                self?.append(samples: samples, inputRate: inputRate)
            }
            state.tapInstalled = true
        }
        if !engine.isRunning {
            try engine.start()
        }
    }

    // MARK: - Tap callback (audio thread: no main-actor state, no new locks)

    /// Down-samples channel 0 to the target rate by picking samples.
    static func downsample(_ input: [Float], from inputRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if abs(inputRate - targetRate) < 1 { return input }
        let ratio = inputRate / targetRate
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            samples.append(input[min(input.count - 1, Int(Double(index) * ratio))])
        }
        return samples
    }

    func append(samples input: [Float], inputRate: Double) {
        let downsampled = Self.downsample(input, from: inputRate, to: targetSampleRate)
        guard !downsampled.isEmpty else { return }
        publishLevel(for: downsampled)

        queue.async {
            guard self.state.isRecording else { return }
            self.state.recordedSamples.append(contentsOf: downsampled)
        }
    }

    private func publishLevel(for samples: [Float]) {
        guard !samples.isEmpty else { return }
        let sumOfSquares = samples.reduce(Float.zero) { $0 + ($1 * $1) }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        // Scale so ordinary speech fills most of the bar height; clamp to 0...1.
        let scaled = min(1, rms * 12)
        setLevel(scaled)
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        _level = value
        levelLock.unlock()
    }

}

/// The capture service's bookkeeping as plain values, so the transitions around
/// start failures and device changes can be tested without audio hardware.
struct CaptureState {
    var isRecording = false
    var tapInstalled = false
    var recordedSamples: [Float] = []

    enum ConfigurationChange: Equatable {
        case ignored             // not recording: only the tap is dropped
        case resume              // recording: reinstall the tap and carry on, keeping the samples
        case stopKeepingSamples  // too many changes at once: stop, keep the samples
    }

    /// More than this many changes inside the window during one recording is a storm.
    static let stormLimit = 3
    static let stormWindow: TimeInterval = 2

    /// When the changes during this recording arrived (only the recent ones are kept).
    private(set) var changeTimes: [TimeInterval] = []

    /// Starts a recording. False when one is already running.
    mutating func begin() -> Bool {
        guard !isRecording else { return false }
        isRecording = true
        recordedSamples = []
        changeTimes = []
        return true
    }

    /// The tap or engine failed to start and the tap has been removed.
    mutating func startFailed() {
        isRecording = false
        tapInstalled = false
        recordedSamples = []
    }

    /// The input device changed: the installed tap's format is stale either way.
    /// While recording the samples are never dropped here.
    mutating func configurationChanged(at time: TimeInterval) -> ConfigurationChange {
        tapInstalled = false
        guard isRecording else { return .ignored }
        changeTimes = changeTimes.filter { time - $0 <= Self.stormWindow } + [time]
        if changeTimes.count > Self.stormLimit {
            isRecording = false
            return .stopKeepingSamples
        }
        return .resume
    }

    /// Resuming after a device change failed: stop recording but KEEP the samples.
    mutating func resumeFailed() {
        isRecording = false
        tapInstalled = false
    }
}
