import Foundation
import WhisperKit

/// Shared, cached WhisperKit engine so rebuilding the pipeline on a config change
/// doesn't reload the CoreML model. The model is downloaded + loaded on first use
/// (or via `prewarm`) and reused until the selected model changes.
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var isLoading = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Load (downloading if needed) the model ahead of the first dictation.
    @discardableResult
    func prewarm(model: String) async -> Bool {
        do {
            _ = try await pipe(for: model)
            return true
        } catch {
            return false
        }
    }

    func transcribe(
        samples: [Float],
        model: String,
        language: String?,
        vocabulary: [String]
    ) async throws -> String {
        let kit = try await pipe(for: model)
        var options: DecodingOptions
        if let language {
            options = DecodingOptions(language: language)
        } else {
            options = DecodingOptions(detectLanguage: true)
        }
        if let prompt = Self.promptTokens(for: vocabulary, tokenizer: kit.tokenizer) {
            options.promptTokens = prompt
            options.usePrefillPrompt = true
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
    }

    /// Condition the decoder on the user's custom vocabulary so Whisper HEARS the
    /// word, instead of mishearing it and having the normalizer patch the spelling
    /// afterwards. String replacement can only fix a term the model got nearly
    /// right; it cannot recover "cobble mon" → "Cobblemon" reliably, and it never
    /// helps the rewrite pass, which is reasoning over already-wrong text.
    ///
    /// `promptTokens`, NOT `prefixTokens`. Both bias the decoder, but prefix tokens
    /// land AFTER `<|startoftranscript|>` and are therefore inside the slice
    /// WhisperKit decodes into the returned text — using them would paste the
    /// glossary itself into the user's document. Prompt tokens sit before that
    /// marker and are cut off. This is the single detail that makes the feature
    /// safe rather than embarrassing.
    ///
    /// Two behaviours worth knowing: the leading space is load-bearing (BPE
    /// tokenizes a word differently at a word boundary), and WhisperKit trims an
    /// over-long prompt with `.suffix(111)` — it drops the EARLIEST terms, so the
    /// end of the list is the part that survives.
    private static func promptTokens(for vocabulary: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer else { return nil }
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        let tokens = tokenizer
            .encode(text: " " + terms.joined(separator: ", "))
            // Special tokens in a prompt corrupt the decoder's control sequence.
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// Loads (downloading if needed) and caches the model. Concurrent callers —
    /// e.g. the onboarding prewarm and the first dictation — are coalesced onto a
    /// SINGLE load rather than each starting its own model download/compile, which
    /// would race on the same files and can crash.
    private func pipe(for model: String) async throws -> WhisperKit {
        if let pipe, loadedModel == model { return pipe }

        while isLoading {
            await withCheckedContinuation { waiters.append($0) }
            if let pipe, loadedModel == model { return pipe }
        }

        isLoading = true
        defer {
            isLoading = false
            let resume = waiters
            waiters.removeAll()
            resume.forEach { $0.resume() }
        }

        // Download models into Application Support (not ~/Documents, WhisperKit's
        // default) so the app never triggers the "access your Documents" prompt.
        let base = InkfallDefaults.whisperKitBaseDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // `load: true` is required — WhisperKit does not load models by default
        // unless a modelFolder is supplied.
        let kit = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, load: true))
        pipe = kit
        loadedModel = model
        return kit
    }
}

/// On-device transcription via WhisperKit (Apple Neural Engine). The default engine
/// — no external CLI or model files required. Custom vocabulary now conditions the
/// decoder here as well as being enforced by the downstream normalizer: biasing
/// first and correcting second beats correcting alone.
struct WhisperKitTranscriber: SpeechTranscriber {
    let model: String
    let language: String

    func transcribe(audioClip: AudioClip, context: PipelineContext) async throws -> Transcript {
        let requested = (language == "auto") ? nil : language
        let raw = try await WhisperKitEngine.shared.transcribe(
            samples: audioClip.samples,
            model: model,
            language: requested,
            vocabulary: context.vocabulary
        )
        let cleaned = raw
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw InkfallError.commandFailed("No speech detected")
        }
        return Transcript(rawText: cleaned)
    }
}
