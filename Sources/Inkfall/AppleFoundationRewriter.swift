import Foundation
import FoundationModels

/// Rewrites a raw dictation transcript into clean, ready-to-send text using Apple's
/// on-device foundation model — the same Apple Intelligence system LLM the OS ships.
///
/// Zero-install: no model download, no external CLI, nothing leaves the Mac. Needs
/// Apple Intelligence enabled on a supported (Apple silicon) Mac. When the model is
/// unavailable it throws, so `CompositeRewriter` falls back to the rule-based
/// normalizer and the user still gets clean text.
struct AppleFoundationRewriter: TranscriptRewriter {
    /// System prompt: constrain the model to *editing*, never *answering*.
    static let baseInstructions = """
    You are a dictation cleanup engine. Rewrite the user's dictated text as clean, \
    ready-to-send writing. Fix capitalization, punctuation, and obvious grammar. \
    Remove filler words (um, uh, like, you know) and resolve false starts and \
    self-corrections. Preserve the original meaning, wording, and tone exactly — do \
    not summarize, translate, answer questions, or add anything that was not said. \
    Output only the cleaned text, with no preamble, quotes, or commentary.
    """

    /// Whether the on-device model can be used right now: supported device + Apple
    /// Intelligence enabled + model downloaded. Cheap to poll (used by Settings).
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// A human-readable reason the model can't be used, or nil when it's available.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "The model is still downloading. Try again shortly."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    func rewrite(transcript: String, context: PipelineContext) async throws -> CleanedTranscript {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw InkfallError.commandFailed("Apple Intelligence model unavailable (\(reason))")
        }

        // Fold custom vocabulary into the instructions so proper nouns survive.
        let instructions: String
        if context.vocabulary.isEmpty {
            instructions = Self.baseInstructions
        } else {
            instructions = Self.baseInstructions
                + "\n\nKeep the exact spelling of these terms: "
                + context.vocabulary.joined(separator: ", ") + "."
        }

        let session = LanguageModelSession(instructions: instructions)
        // Frame the input as text-to-edit, not a question, so a dictated question
        // ("what time is it") gets cleaned up rather than answered.
        let response = try await session.respond(to: "Dictated text to clean up:\n\n\(transcript)")
        let clean = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = clean.isEmpty ? transcript : clean
        return CleanedTranscript(cleanText: text, confidence: .high, needsReview: false)
    }
}
