import Foundation

struct Transcript: Sendable {
    let rawText: String
}

struct CleanedTranscript: Codable, Sendable {
    let cleanText: String
    let confidence: Confidence
    let needsReview: Bool

    enum Confidence: String, Codable, Sendable {
        case high
        case medium
        case low
    }

    enum CodingKeys: String, CodingKey {
        case cleanText = "clean_text"
        case confidence
        case needsReview = "needs_review"
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

/// Transcribes, normalizes, and rewrites. Insertion now lives in the controller so
/// it can be clipboard-first and drive the typed state machine.
final class DictationPipeline: Sendable {
    private let transcriber: SpeechTranscriber
    private let normalizer: TranscriptNormalizer
    private let rewriter: TranscriptRewriter

    init(
        transcriber: SpeechTranscriber,
        normalizer: TranscriptNormalizer,
        rewriter: TranscriptRewriter
    ) {
        self.transcriber = transcriber
        self.normalizer = normalizer
        self.rewriter = rewriter
    }

    func run(
        audioClip: AudioClip,
        context: PipelineContext,
        onStage: @Sendable (PipelineStage) -> Void = { _ in }
    ) async throws -> CleanedTranscript {
        onStage(.transcribing)
        let transcript = try await transcriber.transcribe(audioClip: audioClip, context: context)
        let normalized = normalizer.normalize(transcript.rawText, vocabulary: context.vocabulary)
        onStage(.rewriting)
        return try await rewriter.rewrite(transcript: normalized, context: context)
    }
}

enum InkfallError: LocalizedError {
    case missingWhisperConfiguration
    case missingAudio
    case commandFailed(String)
    case invalidRewriteOutput

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
        }
    }
}
