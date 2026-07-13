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

    init(vad: VoiceActivityDetector) {
        self.vad = vad
    }

    func start() throws {
        try queue.sync {
            guard !state.isRecording else { return }
            // Reset only the per-recording fields. `tapInstalled` MUST persist: the tap
            // lives on the input node across recordings, and installing a second one
            // throws "required condition is false: nullptr == Tap()".
            state.isRecording = true
            state.recordedSamples = []
            try installTapIfNeeded()
            if !engine.isRunning {
                try engine.start()
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

private struct CaptureState {
    var isRecording = false
    var tapInstalled = false
    var recordedSamples: [Float] = []
}
