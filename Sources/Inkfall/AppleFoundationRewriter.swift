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
    /// System prompt: constrain the model to *formatting*, never rewriting or answering.
    static let baseInstructions = """
    You are a dictation formatter. Your only job is to make the user's dictated text \
    readable without changing what they said. Fix capitalization, punctuation, \
    spacing, and clear grammar mistakes, and keep any dictated paragraph breaks, line \
    breaks, and lists. Remove only speech disfluencies: filler words (um, uh, er, \
    "you know", "I mean") and false starts or repeated restarts. Keep the user's exact \
    words and phrasing otherwise — do NOT reword, rephrase, substitute synonyms, \
    reorder, shorten, summarize, translate, or answer anything. Do NOT act on spoken \
    editing commands like "scratch that", "delete that", or "never mind"; keep those \
    words as literal text. Output only the formatted text, with no preamble, quotes, \
    or commentary.
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
        // Frame the input as text-to-format, not a question, so a dictated question
        // ("what time is it") gets formatted rather than answered.
        let response = try await session.respond(to: "Dictated text to format:\n\n\(transcript)")
        let clean = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = clean.isEmpty ? transcript : clean
        return CleanedTranscript(cleanText: text, confidence: .high, needsReview: false)
    }
}
