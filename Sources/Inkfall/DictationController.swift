import AppKit
import ApplicationServices
import AVFoundation
import Foundation

@MainActor
final class DictationController {
    private var config: InkfallConfig
    private let audioCapture: AudioCaptureService
    private var pipeline: DictationPipeline
    private let inserter = TextInserter()

    private(set) var state: DictationState = .idle
    private var lastResult: String?
    private var retainedClip: AudioClip?
    private var silenceTimer: Timer?
    private var lastLoudAt: Date = .distantPast

    var onStateChange: ((DictationState) -> Void)?
    var onConfigurationNeeded: (() -> Void)?

    init(config: InkfallConfig, audioCapture: AudioCaptureService, pipeline: DictationPipeline) {
        self.config = config
        self.audioCapture = audioCapture
        self.pipeline = pipeline
    }

    // MARK: Derived readiness

    /// Menu-bar glyph + status line read from here: the transient state while
    /// active, otherwise the resting readiness (Ready / needs model / needs mic).
    var menuState: DictationState { state == .idle ? readiness : state }

    var lastResultText: String? { lastResult }

    /// Thread-safe closure the HUD waveform polls for the live mic level.
    var audioLevelProvider: () -> Float {
        let capture = audioCapture
        return { capture.currentLevel }
    }

    private var readiness: DictationState {
        if !config.hasWhisperConfiguration { return .needsModel }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { return .needsMicrophone }
        return .idle
    }

    private var isBusy: Bool {
        switch state {
        case .transcribing, .polishing, .inserting, .downloading:
            return true
        default:
            return false
        }
    }

    func update(config: InkfallConfig, pipeline: DictationPipeline) {
        self.config = config
        self.pipeline = pipeline
        if state == .idle { onStateChange?(.idle) } // readiness may have changed
    }

    // MARK: Recording loop

    func toggleRecording() async {
        if state.isRecording {
            await stopRecording()
        } else if isBusy {
            return
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard config.hasWhisperConfiguration else {
            update(.needsModel)
            onConfigurationNeeded?()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { update(.needsMicrophone); return }
        default:
            update(.needsMicrophone)
            return
        }

        do {
            try audioCapture.start()
            lastLoudAt = Date()
            update(.listening)
            startSilenceWatch()
        } catch {
            update(.micError(error.localizedDescription))
        }
    }

    private func stopRecording() async {
        stopSilenceWatch()
        let clip = audioCapture.stop()
        guard clip.duration > 0.15 else {
            update(.noSpeech)
            return
        }
        retainedClip = clip
        await process(clip)
    }

    private func process(_ clip: AudioClip) async {
        update(.transcribing)
        let context = PipelineContext(
            vocabulary: config.customVocabulary,
            targetAppName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
        let showsPolishing = config.rewriteEnabled

        do {
            let cleaned = try await pipeline.run(audioClip: clip, context: context) { [weak self] stage in
                guard stage == .rewriting, showsPolishing else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if case .transcribing = self.state { self.update(.polishing) }
                }
            }

            let text = cleaned.cleanText
            lastResult = text
            update(.inserting)

            switch inserter.insert(text) {
            case .inserted:
                update(.success(peek: peek(text), copiedOnly: false))
            case .copiedNoField:
                update(.success(peek: peek(text), copiedOnly: true))
            case .needsAccessibility:
                // Text is safe on the clipboard; prompt to grant so it can auto-type.
                update(.needsAccessibility)
            case .failed:
                update(.insertionFailed(peek: peek(text)))
            }
        } catch {
            update(.transcribeError(error.localizedDescription))
        }
    }

    // MARK: HUD / menu actions

    func retry() async {
        guard let clip = retainedClip else { return }
        await process(clip)
    }

    func copyLastResultToClipboard() {
        guard let text = lastResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func dismiss() {
        retainedClip = nil
        update(.idle)
    }

    /// Called by the HUD when it finishes an auto-hide (dwell elapsed, not hovered),
    /// so the resting menu glyph + status line return to "Ready". The HUD owns the
    /// only dismissal timer, so hover-to-persist genuinely holds the overlay.
    func hudDidHide() {
        switch state {
        case .success, .noSpeech:
            retainedClip = nil   // these never retry; free the recorded PCM buffer
            update(.idle)
        default:
            break
        }
    }

    /// Re-checks permissions/model (e.g. on app activation) and clears a resolved
    /// not-ready state, or refreshes the menu glyph if resting readiness changed.
    func refreshReadiness() {
        switch state {
        case .needsMicrophone where AVCaptureDevice.authorizationStatus(for: .audio) == .authorized:
            update(.idle)
        case .needsModel where config.hasWhisperConfiguration:
            update(.idle)
        case .needsAccessibility where AXIsProcessTrusted():
            update(.idle)
        case .idle:
            onStateChange?(.idle)
        default:
            break
        }
    }

    // MARK: Silence watch

    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSilence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func tickSilence() {
        guard state.isRecording else { return }
        let level = audioCapture.currentLevel
        if level > 0.06 {
            lastLoudAt = Date()
            if state == .silence { update(.listening) }
        } else if Date().timeIntervalSince(lastLoudAt) > 2.5, state == .listening {
            update(.silence)
        }
    }

    // MARK: Helpers

    private func peek(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 52 { return trimmed }
        return String(trimmed.prefix(52)) + "…"
    }

    private func update(_ newState: DictationState) {
        state = newState
        onStateChange?(newState)
    }
}
