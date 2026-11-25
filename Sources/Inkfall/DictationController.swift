import AppKit
import ApplicationServices
import AVFoundation
import Foundation

// MARK: - Collaborators
//
// The controller reaches the outside world only through these, so a test can drive
// the whole state sequence with fakes (no microphone, no pasteboard, no network).
// The real ones are the defaults; `AppDelegate` builds the controller as before.

/// The microphone side of `AudioCaptureService`.
protocol DictationAudio: AnyObject {
    var currentLevel: Float { get }
    var onInterrupted: (@Sendable (String) -> Void)? { get set }
    func start() throws
    func stop() -> AudioClip
}

extension AudioCaptureService: DictationAudio {}

/// Puts text into the app in front. `TextInserter` is the real one.
@MainActor
protocol DictationInserting {
    func insert(_ text: String, expectedAppPID: pid_t?) async -> InsertionOutcome
}

extension TextInserter: DictationInserting {}

/// The speech model on disk, and the one call that may download it.
protocol SpeechModelProviding: Sendable {
    /// No network; a plain look at the disk.
    func isOnDisk(_ model: String) -> Bool
    /// Downloads when missing and loads the model. Returns only when the engine is
    /// ready to transcribe, not when the files have arrived. `progress` is 0...1 for
    /// the model files.
    func load(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws
}

struct WhisperKitModelProvider: SpeechModelProviding {
    func isOnDisk(_ model: String) -> Bool {
        WhisperKitEngine.shared.isModelOnDisk(model)
    }

    func load(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await WhisperKitEngine.shared.load(model: model, allowDownload: true, progress: progress)
    }
}

/// What the controller asks the Mac: permissions and which app is in front.
@MainActor
protocol DictationSystem {
    var microphoneStatus: AVAuthorizationStatus { get }
    func requestMicrophone() async -> Bool
    var isAccessibilityTrusted: Bool { get }
    var frontmostPID: pid_t? { get }
    var frontmostAppName: String? { get }
}

@MainActor
struct LiveDictationSystem: DictationSystem {
    var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var frontmostAppName: String? { NSWorkspace.shared.frontmostApplication?.localizedName }
}

@MainActor
final class DictationController {
    private var config: InkfallConfig
    private let audioCapture: DictationAudio
    private var pipeline: DictationPipeline
    private let inserter: DictationInserting
    private let models: SpeechModelProviding
    private let system: DictationSystem
    private let pasteboard: NSPasteboard
    /// How long transcribing or polishing runs before the HUD offers Cancel.
    private let slowWorkDelay: TimeInterval

    private(set) var state: DictationState = .idle
    private var lastResult: String?
    /// What the engine said before any rule ran, for the last dictation.
    private var lastRawText: String?
    private var retainedClip: AudioClip?
    private var silenceTimer: Timer?
    private var holdSafetyTimer: Timer?
    private var slowWorkTimer: Timer?
    private var lastLoudAt: Date = .distantPast

    /// Every piece of background work (transcribe, download) runs under a number. Cancel
    /// moves the number on, so a result that arrives afterwards finds it stale and is
    /// dropped, even from a library call that cannot be interrupted.
    private var workGeneration = 0
    private var workTask: Task<Void, Never>?
    /// True once the current transcribing/polishing has run longer than `slowWorkDelay`.
    private(set) var workIsSlow = false
    /// A failed download with no recording behind it (started from Settings): Retry
    /// repeats the download rather than a clip.
    private var retryIsDownloadOnly = false

    /// Hold mode: a begin is waiting on the first-run microphone prompt, and whether
    /// the key came up while it was.
    private var holdStartInFlight = false
    private var holdReleasedDuringStart = false

    var onStateChange: ((DictationState) -> Void)?
    var onConfigurationNeeded: (() -> Void)?

    init(
        config: InkfallConfig,
        audioCapture: DictationAudio,
        pipeline: DictationPipeline,
        inserter: DictationInserting = TextInserter(),
        models: SpeechModelProviding = WhisperKitModelProvider(),
        system: DictationSystem = LiveDictationSystem(),
        pasteboard: NSPasteboard = .general,
        slowWorkDelay: TimeInterval = 10
    ) {
        self.config = config
        self.audioCapture = audioCapture
        self.pipeline = pipeline
        self.inserter = inserter
        self.models = models
        self.system = system
        self.pasteboard = pasteboard
        self.slowWorkDelay = slowWorkDelay
        // Same hop as the menu actions in AppDelegate: the callback arrives on the
        // audio queue, so it only schedules work on the main actor.
        audioCapture.onInterrupted = { [weak self] message in
            Task { @MainActor in await self?.recordingInterrupted(message) }
        }
    }

    // MARK: Derived readiness

    /// Menu-bar glyph + status line read from here: the transient state while
    /// active, otherwise the resting readiness (Ready / needs model / needs mic).
    var menuState: DictationState { state == .idle ? readiness : state }

    var lastResultText: String? { lastResult }

    /// The engine's own words for the last dictation, when they differ from the
    /// cleaned result (a rule dropped or changed something). Nil when there is
    /// nothing more to offer.
    var originalTranscriptText: String? {
        guard let raw = lastRawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let cleaned = lastResult?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == cleaned ? nil : raw
    }

    /// Thread-safe closure the HUD waveform polls for the live mic level.
    var audioLevelProvider: () -> Float {
        let capture = audioCapture
        return { capture.currentLevel }
    }

    /// True while there is work Cancel can stop.
    var canCancel: Bool {
        switch state {
        case .transcribing, .polishing, .downloading: return true
        default: return false
        }
    }

    private var readiness: DictationState {
        if !config.hasWhisperConfiguration { return .needsModel }
        if system.microphoneStatus == .denied { return .needsMicrophone }
        // Not a blocker — dictation still works via the clipboard — but the menu
        // must not say plain "Ready" while typing into apps can't work.
        if !system.isAccessibilityTrusted { return .readyNoAccessibility }
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

    // MARK: Hold to talk

    /// Hotkey went DOWN in hold mode. Idempotent — Carbon repeats a held hotkey's
    /// pressed event on some layouts, and a second start would throw away the
    /// audio captured so far. The same goes for a repeat that arrives while the
    /// first-run microphone prompt is still up.
    func beginHold() async {
        guard !state.isRecording, !isBusy, !holdStartInFlight else { return }
        holdStartInFlight = true
        holdReleasedDuringStart = false
        defer { holdStartInFlight = false }
        await startRecording(fromHold: true)
        guard state.isRecording else { return }   // start can fail on permissions
        startHoldSafetyTimer()
    }

    /// Hotkey came UP in hold mode. Also idempotent: a release with nothing
    /// recording is the normal case after the safety timer has already fired.
    func endHold() async {
        if holdStartInFlight { holdReleasedDuringStart = true }
        stopHoldSafetyTimer()
        guard state.isRecording else { return }
        await stopRecording()
    }

    /// The hold was abandoned (released too soon, or another key, a mouse click or
    /// a second modifier joined it): stop the capture and drop the audio, with no
    /// transcription and no insertion. Idempotent.
    func discardHold() {
        if holdStartInFlight { holdReleasedDuringStart = true }
        stopHoldSafetyTimer()
        guard state.isRecording else { return }
        stopSilenceWatch()
        _ = audioCapture.stop()
        update(.idle)
    }

    /// The audio device changed under a live recording and it could not carry on.
    /// The capture service has stopped itself but kept what it heard: transcribe
    /// that, unless it is too short to use, and only then say why.
    private func recordingInterrupted(_ message: String) async {
        guard state.isRecording else { return }
        stopHoldSafetyTimer()
        stopSilenceWatch()
        let targetPID = system.frontmostPID
        let clip = audioCapture.stop()
        guard clip.duration > 0.15 else {
            update(.micError(message))
            return
        }
        retainedClip = clip
        await process(clip, targetPID: targetPID)
    }

    /// The one failure mode hold-to-talk adds: a release event that never arrives
    /// (the key held across a focus change, the hotkey rebound mid-press) would
    /// otherwise record until the disk filled. Nothing else in this controller
    /// stops a recording on its own — `tickSilence` only changes what the HUD
    /// says, it has never auto-stopped — so this timer is the only backstop.
    ///
    /// It STOPS AND TRANSCRIBES rather than discarding. Inkfall's rule is that the
    /// user's words are never lost; a stuck key should cost a clumsy transcript,
    /// not silence.
    private func startHoldSafetyTimer() {
        stopHoldSafetyTimer()
        let timer = Timer(timeInterval: Self.holdSafetyLimit, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isRecording else { return }
                await self.stopRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdSafetyTimer = timer
    }

    private func stopHoldSafetyTimer() {
        holdSafetyTimer?.invalidate()
        holdSafetyTimer = nil
    }

    /// Two minutes. Long enough that nobody dictating a real paragraph ever meets
    /// it, short enough that a stuck key is noticed in the same sitting.
    private static let holdSafetyLimit: TimeInterval = 120

    private func startRecording(fromHold: Bool = false) async {
        guard config.hasWhisperConfiguration else {
            update(.needsModel)
            onConfigurationNeeded?()
            return
        }

        switch system.microphoneStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await system.requestMicrophone()
            if !granted { update(.needsMicrophone); return }
            // The key came up while the prompt was open: the user is no longer
            // speaking, so a recording started now would run with nobody holding it.
            if fromHold, holdReleasedDuringStart { return }
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
        // The app the words were spoken into; text is only pasted if it is still in front.
        let targetPID = system.frontmostPID
        let clip = audioCapture.stop()
        guard clip.duration > 0.15 else {
            update(.noSpeech)
            return
        }
        retainedClip = clip
        await process(clip, targetPID: targetPID)
    }

    // MARK: Background work

    private func isCurrent(_ id: Int) -> Bool { id == workGeneration }

    /// Runs `body` as the one piece of cancellable work. It waits for it, so callers
    /// still see the whole dictation as one `await`.
    private func runWork(_ body: @escaping @MainActor (Int) async -> Void) async {
        workGeneration += 1
        let id = workGeneration
        workIsSlow = false
        let task = Task { @MainActor in await body(id) }
        workTask = task
        await task.value
        if isCurrent(id) {
            workTask = nil
            stopSlowWorkTimer()
            workIsSlow = false
        }
    }

    /// Stops whatever is transcribing, polishing or downloading. Nothing from it is
    /// inserted afterwards, even if the library call underneath cannot be interrupted
    /// and finishes later. Back to idle; the recording is dropped.
    func cancel() {
        guard canCancel else { return }
        abandonWork()
        retainedClip = nil
        retryIsDownloadOnly = false
        update(.idle)
    }

    private func abandonWork() {
        workGeneration += 1
        workTask?.cancel()
        workTask = nil
        stopSlowWorkTimer()
        workIsSlow = false
    }

    /// Quitting: drop a recording in progress, stop any work and every timer.
    func shutdown() {
        stopHoldSafetyTimer()
        stopSilenceWatch()
        if state.isRecording { _ = audioCapture.stop() }
        abandonWork()
        retainedClip = nil
        update(.idle)
    }

    /// After 10 s in transcribing or polishing the HUD offers Cancel. Timer written
    /// like `startHoldSafetyTimer`.
    private func startSlowWorkTimer(_ id: Int) {
        stopSlowWorkTimer()
        workIsSlow = false
        let timer = Timer(timeInterval: slowWorkDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(id) else { return }
                self.workIsSlow = true
                if self.state == .transcribing || self.state == .polishing {
                    self.onStateChange?(self.state)   // same state, now with Cancel
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slowWorkTimer = timer
    }

    private func stopSlowWorkTimer() {
        slowWorkTimer?.invalidate()
        slowWorkTimer = nil
    }

    // MARK: Model download

    /// The model to download before transcribing, or nil when none is needed (the
    /// command-line engine, or a WhisperKit model already on disk).
    private func modelNeedingDownload() -> String? {
        guard config.speechEngine == .whisperKit else { return nil }
        let model = config.whisperKitModelName
        return models.isOnDisk(model) ? nil : model
    }

    /// Shows the download and waits for the engine's load to return (progress reaching
    /// 1.0 is not the end: the tokenizer comes after it). False when it failed or the
    /// work was cancelled meanwhile.
    private func downloadModel(_ model: String, id: Int) async -> Bool {
        update(.downloading(progress: 0, detail: DownloadText.detail(fraction: nil)))
        do {
            try await models.load(model) { [weak self] fraction in
                Task { @MainActor in self?.downloadProgressed(fraction, id: id) }
            }
        } catch {
            guard isCurrent(id) else { return false }
            update(.downloadFailed(error.localizedDescription))
            return false
        }
        return isCurrent(id)
    }

    private func downloadProgressed(_ fraction: Double, id: Int) {
        guard isCurrent(id), case let .downloading(shown, _) = state else { return }
        let clamped = min(1, max(0, fraction))
        // Whole percents only: the card is rebuilt on every change.
        guard clamped >= 1 || clamped - shown >= 0.01 else { return }
        update(.downloading(progress: clamped, detail: DownloadText.detail(fraction: clamped)))
    }

    /// The user just picked a WhisperKit model that is not on disk (Settings): show
    /// the same visible download a first dictation would, and finish with a short
    /// "ready". Does nothing while something else is going on.
    func startModelDownload() async {
        guard !isBusy, !state.isRecording, modelNeedingDownload() != nil else { return }
        retainedClip = nil
        retryIsDownloadOnly = true
        await runWork { [self] id in
            guard let model = self.modelNeedingDownload() else { return }
            guard await self.downloadModel(model, id: id) else { return }
            self.retryIsDownloadOnly = false
            self.update(.modelReady(name: model))
        }
    }

    // MARK: Transcribe and insert

    private func process(_ clip: AudioClip, targetPID: pid_t? = nil) async {
        // A retry has no recording moment: the app in front now is the target.
        let insertionTarget = targetPID ?? system.frontmostPID
        retryIsDownloadOnly = false
        await runWork { [self] id in
            await self.transcribeAndInsert(clip, insertionTarget: insertionTarget, id: id)
        }
    }

    private func transcribeAndInsert(_ clip: AudioClip, insertionTarget: pid_t?, id: Int) async {
        // A model that is not on disk is fetched here, on screen with a Cancel button,
        // never inside "Transcribing…". The clip waits and is transcribed afterwards.
        if let model = modelNeedingDownload() {
            guard await downloadModel(model, id: id) else { return }
        }

        update(.transcribing)
        startSlowWorkTimer(id)
        let context = PipelineContext(
            vocabulary: config.customVocabulary,
            targetAppName: system.frontmostAppName
        )
        let showsPolishing = config.rewriteEnabled

        do {
            let cleaned = try await pipeline.run(audioClip: clip, context: context) { [weak self] stage in
                guard stage == .rewriting, showsPolishing else { return }
                Task { @MainActor in
                    guard let self, self.isCurrent(id) else { return }
                    if case .transcribing = self.state { self.update(.polishing) }
                }
            }
            // Cancelled while it ran: the result is not wanted, whatever it says.
            guard isCurrent(id) else { return }

            lastRawText = cleaned.rawText
            let text = cleaned.cleanText
            // Nothing survived cleaning: say so, and touch neither the field nor the
            // clipboard (and keep the last real result).
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                update(.noSpeech)
                return
            }
            lastResult = text
            update(.inserting)

            switch await inserter.insert(text, expectedAppPID: insertionTarget) {
            case .inserted:
                update(.success(peek: peek(text), copiedOnly: false))
            case .pasted:
                update(.pasted(peek: peek(text)))
            case .copiedNoField:
                update(.success(peek: peek(text), copiedOnly: true))
            case .copiedAppChanged:
                update(.copiedAppChanged(peek: peek(text)))
            case .nothingToInsert:
                update(.noSpeech)
            case .needsAccessibility:
                // Text is safe on the clipboard; prompt to grant so it can auto-type.
                update(.needsAccessibility)
            case .failed:
                update(.insertionFailed(peek: peek(text)))
            }
        } catch {
            guard isCurrent(id) else { return }
            update(.transcribeError(error.localizedDescription))
        }
    }

    // MARK: HUD / menu actions

    /// Retry after a failed transcription or download: the download first if the model
    /// is still missing, then the clip that was recorded.
    func retry() async {
        guard !isBusy, !state.isRecording else { return }
        if let clip = retainedClip {
            await process(clip)
        } else if retryIsDownloadOnly {
            await startModelDownload()
        }
    }

    func copyLastResultToClipboard() {
        guard let text = lastResult else { return }
        copyToClipboard(text)
    }

    /// The transcript exactly as the engine returned it, before any rule changed it.
    func copyOriginalTranscriptToClipboard() {
        guard let text = originalTranscriptText else { return }
        copyToClipboard(text)
    }

    private func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func dismiss() {
        retainedClip = nil
        retryIsDownloadOnly = false
        update(.idle)
    }

    /// Called by the HUD when it finishes an auto-hide (the dwell elapsed), so the
    /// resting menu glyph + status line return to "Ready". The HUD owns the only
    /// dismissal timer.
    func hudDidHide() {
        switch state {
        case .success, .pasted, .copiedAppChanged, .noSpeech, .modelReady:
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
        case .needsMicrophone where system.microphoneStatus == .authorized:
            update(.idle)
        case .needsModel where config.hasWhisperConfiguration:
            update(.idle)
        case .needsAccessibility where system.isAccessibilityTrusted:
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
