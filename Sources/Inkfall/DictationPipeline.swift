import Foundation

struct Transcript: Sendable {
    let rawText: String
}

struct CleanedTranscript: Codable, Sendable {
    let cleanText: String
    /// The transcript exactly as the engine returned it, before any rule ran. Set by the
    /// pipeline; not part of the JSON a rewrite model returns.
    var rawText: String = ""

    enum CodingKeys: String, CodingKey {
        case cleanText = "clean_text"
    }
}

protocol SpeechTranscriber: Sendable {
    func transcribe(audioClip: AudioClip, context: PipelineContext) async throws -> Transcript
}

protocol TranscriptRewriter: Sendable {
    func rewrite(transcript: String, context: PipelineContext) async throws -> CleanedTranscript
}

/// The stages the pipeline passes through, reported so the controller can narrate
/// honest progress (Transcribing… then Polishing…) instead of a fake waveform.
enum PipelineStage: Sendable {
    case transcribing
    case rewriting
}

/// How long each stage may take before the pipeline gives up on it.
struct PipelineLimits: Sendable {
    /// Transcription gets the larger of `transcriptionFloor` and `transcriptionPerClipSecond`
    /// times the length of the clip.
    var transcriptionFloor: TimeInterval = 120
    var transcriptionPerClipSecond: TimeInterval = 6
    /// A rewrite that is not done by now is dropped for the rule-based result.
    var rewrite: TimeInterval = 20

    static let standard = PipelineLimits()

    func transcription(forClipSeconds seconds: TimeInterval) -> TimeInterval {
        max(transcriptionFloor, transcriptionPerClipSecond * seconds)
    }
}

/// Transcribes, normalizes, and rewrites. Insertion now lives in the controller so
/// it can be clipboard-first and drive the typed state machine.
final class DictationPipeline: Sendable {
    private let transcriber: SpeechTranscriber
    private let normalizer: TranscriptNormalizer
    private let rewriter: TranscriptRewriter
    private let limits: PipelineLimits

    init(
        transcriber: SpeechTranscriber,
        normalizer: TranscriptNormalizer,
        rewriter: TranscriptRewriter,
        limits: PipelineLimits = .standard
    ) {
        self.transcriber = transcriber
        self.normalizer = normalizer
        self.rewriter = rewriter
        self.limits = limits
    }

    func run(
        audioClip: AudioClip,
        context: PipelineContext,
        onStage: @Sendable (PipelineStage) -> Void = { _ in }
    ) async throws -> CleanedTranscript {
        try Task.checkCancellation()
        onStage(.transcribing)
        let transcriber = self.transcriber
        let transcript = try await withDeadline(seconds: limits.transcription(forClipSeconds: audioClip.duration)) {
            try await transcriber.transcribe(audioClip: audioClip, context: context)
        }
        guard let transcript else { throw InkfallError.transcriptionTimedOut }

        try Task.checkCancellation()
        let normalized = normalizer.normalize(transcript.rawText, vocabulary: context.vocabulary)
        onStage(.rewriting)
        let rewriter = self.rewriter
        let rewritten = try await withDeadline(seconds: limits.rewrite) {
            try await rewriter.rewrite(transcript: normalized, context: context)
        }
        // A rewrite that takes too long is not an error: the rule-based text is still good.
        var result = rewritten ?? CleanedTranscript(cleanText: normalizer.finalize(normalized))
        result.rawText = transcript.rawText
        return result
    }
}

/// Decides whether a model's rewrite still looks like what was dictated. A model that
/// answers the question, summarises or expands is not editing, and its output is dropped.
enum RewriteGuard {
    static func accepts(input: String, output: String) -> Bool {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        let inputLength = Double(input.trimmingCharacters(in: .whitespacesAndNewlines).count)
        let outputLength = Double(cleaned.count)
        guard outputLength >= inputLength * 0.5 - 20, outputLength <= inputLength * 1.5 + 20 else { return false }

        let outputWords = words(in: cleaned)
        guard !outputWords.isEmpty else { return false }
        let inputWords = Set(words(in: input))
        let shared = outputWords.filter { inputWords.contains($0) }.count
        return Double(shared) >= Double(outputWords.count) * 0.6
    }

    private static func words(in text: String) -> [String] {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’"))
        return text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: keep.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Runs `operation` and returns its value, or nil if `seconds` pass first. It returns at
/// the deadline even when the operation never finishes and ignores cancellation: the work
/// runs in an unstructured task that is cancelled and abandoned, and a continuation is
/// resumed exactly once by whichever of the work and the timer finishes first. (A task
/// group would wait for the slow child, which is the bug this avoids.) If the caller is
/// cancelled, this throws CancellationError at once.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            race.start(continuation: continuation, seconds: seconds, operation: operation)
        }
    } onCancel: {
        race.cancel()
    }
}

private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?
    private var finished = false
    private var cancelled = false
    private var tasks: [Task<Void, Never>] = []

    func start(
        continuation: CheckedContinuation<T?, Error>,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let work = Task { [self] in
            do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
        }
        let timer = Task { [self] in
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            finish(.success(nil))
        }

        lock.lock()
        let alreadyDone = finished
        if !alreadyDone { tasks = [work, timer] }
        lock.unlock()
        if alreadyDone {
            work.cancel()
            timer.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<T?, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let toCancel = tasks
        tasks = []
        lock.unlock()

        toCancel.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

enum InkfallError: LocalizedError {
    case missingWhisperConfiguration
    case missingAudio
    case commandFailed(String)
    case invalidRewriteOutput
    case transcriptionTimedOut
    case rewriteRejected

    var errorDescription: String? {
        switch self {
        case .missingWhisperConfiguration:
            return "Configure INKFALL_WHISPER_BIN and INKFALL_WHISPER_MODEL"
        case .missingAudio:
            return "No speech audio was captured"
        case .commandFailed(let message):
            return message
        case .invalidRewriteOutput:
            return "The local rewrite model returned invalid output"
        case .transcriptionTimedOut:
            return "Transcription took too long"
        case .rewriteRejected:
            return "The rewrite did not match what was said"
        }
    }
}
