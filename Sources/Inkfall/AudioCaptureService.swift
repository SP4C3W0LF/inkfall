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

final class AudioCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "Inkfall.AudioCapture")
    private let vad: VoiceActivityDetector
    private let targetSampleRate = 16_000.0
    private var state = CaptureState()

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

    // Observer token for the engine's configuration-change notification. The
    // service lives as long as the app, so it is never removed (and a nonisolated
    // deinit could not touch it anyway).
    private var configurationObserver: NSObjectProtocol?

    init(vad: VoiceActivityDetector) {
        self.vad = vad
        // The block runs on whatever thread AVFoundation posts from, so it touches
        // nothing but the service's own serial queue, exactly like the tap callback.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// The input device changed (headphones, a different default mic, a sample-rate
    /// switch, a Bluetooth headset changing profile). The engine has stopped and the
    /// tap's format is stale, so drop the tap. Not recording: the next start installs
    /// one for the new device. Recording: keep what was captured and try to carry on
    /// with a fresh tap (its rate is read again from the new format); only if that
    /// fails, or the changes keep coming, stop and hand back what was captured.
    private func handleConfigurationChange() {
        queue.async {
            let change = self.state.configurationChanged(at: ProcessInfo.processInfo.systemUptime)
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            switch change {
            case .ignored:
                self.setLevel(0)
            case .resume:
                do {
                    try self.installTapIfNeeded()
                    try self.engine.start()
                } catch {
                    if self.state.tapInstalled { self.engine.inputNode.removeTap(onBus: 0) }
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

    func start() throws {
        try queue.sync {
            // Reset only the per-recording fields. `tapInstalled` MUST persist: the tap
            // lives on the input node across recordings, and installing a second one
            // throws "required condition is false: nullptr == Tap()".
            guard state.begin() else { return }
            do {
                try installTapIfNeeded()
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                // Leave nothing half-done: a stuck isRecording would make every later
                // start() a silent no-op, and a half-installed tap would make the
                // next install throw.
                if state.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
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

    private func installTapIfNeeded() throws {
        guard !state.tapInstalled else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let inputRate = inputFormat.sampleRate
        if #available(macOS 27.0, *) {
            // macOS 27 deprecated installTap(onBus:…block:) in favor of the throwing
            // installAudioTap, whose block hands back a Sendable read-only buffer.
            try input.installAudioTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                self?.append(buffer: buffer, inputRate: inputRate)
            }
        } else {
            // macOS 26 (Tahoe): the classic tap. Its buffer isn't Sendable, so the
            // callback copies channel 0 into a [Float] before anything escapes.
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                self?.append(buffer: buffer, inputRate: inputRate)
            }
        }

        state.tapInstalled = true
    }

    @available(macOS 27.0, *)
    private func append(buffer: AVReadOnlyAudioPCMBuffer, inputRate: Double) {
        guard case .float(let span) = buffer.channelData(0) else { return }
        let frameCount = min(buffer.frameLength, span.count)
        guard frameCount > 0 else { return }

        // Downsample channel 0 to the target rate, reading directly from the
        // borrowed span (never escapes: only the resulting [Float] leaves scope).
        var samples: [Float] = []
        if abs(inputRate - targetSampleRate) < 1 {
            samples.reserveCapacity(frameCount)
            for index in 0..<frameCount { samples.append(span[index]) }
        } else {
            let ratio = inputRate / targetSampleRate
            let outputCount = Int(Double(frameCount) / ratio)
            guard outputCount > 0 else { return }
            samples.reserveCapacity(outputCount)
            for index in 0..<outputCount {
                let sourceIndex = min(frameCount - 1, Int(Double(index) * ratio))
                samples.append(span[sourceIndex])
            }
        }

        // Snapshot to an immutable value before it crosses into the audio queue,
        // so Swift 6 concurrency checking is satisfied (no captured `var`).
        let downsampled = samples
        publishLevel(for: downsampled)

        queue.async {
            guard self.state.isRecording else { return }
            self.state.recordedSamples.append(contentsOf: downsampled)
        }
    }

    /// Tahoe fallback: same downsampling as the macOS 27 path, reading the classic
    /// buffer's float channel pointer (valid only inside the tap callback; only the
    /// resulting [Float] leaves scope).
    private func append(buffer: AVAudioPCMBuffer, inputRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var samples: [Float] = []
        if abs(inputRate - targetSampleRate) < 1 {
            samples.reserveCapacity(frameCount)
            for index in 0..<frameCount { samples.append(channel[index]) }
        } else {
            let ratio = inputRate / targetSampleRate
            let outputCount = Int(Double(frameCount) / ratio)
            guard outputCount > 0 else { return }
            samples.reserveCapacity(outputCount)
            for index in 0..<outputCount {
                let sourceIndex = min(frameCount - 1, Int(Double(index) * ratio))
                samples.append(channel[sourceIndex])
            }
        }

        let downsampled = samples
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
