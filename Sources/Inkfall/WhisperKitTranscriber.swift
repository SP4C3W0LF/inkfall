import Foundation
import WhisperKit

/// Where WhisperKit keeps a model under a base folder, read from the library source
/// (1.1.1) and checked against a real download. Pure file lookups: no network, no
/// WhisperKit, so it can be tested with a temporary folder.
///
/// Layout: `<base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<name>/` holds the
/// three compiled models and config; the tokenizer lives apart, in
/// `<base>/models/openai/whisper-<variant>/tokenizer.json`.
struct WhisperKitModelStore: Sendable {
    let base: URL

    private var modelsRoot: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// The tokenizer repo the library picks for a model name. It is chosen from the
    /// loaded model's size, not its name: the turbo model uses the large-v3 tokenizer.
    static func tokenizerVariant(for model: String) -> String {
        for suffix in ["-turbo", "_turbo"] where model.hasSuffix(suffix) {
            return String(model.dropLast(suffix.count))
        }
        return model
    }

    var tokenizerRoot: URL { base }

    func tokenizerFolder(for model: String) -> URL {
        base.appendingPathComponent("models/openai/whisper-\(Self.tokenizerVariant(for: model))", isDirectory: true)
    }

    /// The folder of a fully downloaded model, or nil. The library's own name match
    /// is "any folder ending in the model name", so an exact folder wins and a single
    /// folder with that ending is accepted; anything ambiguous is treated as absent.
    func modelFolder(for model: String) -> URL? {
        let fm = FileManager.default
        let exact = modelsRoot.appendingPathComponent("openai_whisper-\(model)", isDirectory: true)
        var candidate: URL?
        if fm.fileExists(atPath: exact.path) {
            candidate = exact
        } else if let names = try? fm.contentsOfDirectory(atPath: modelsRoot.path) {
            let matches = names.filter { $0.hasSuffix("-\(model)") || $0.hasSuffix("_\(model)") }
            if matches.count == 1 {
                candidate = modelsRoot.appendingPathComponent(matches[0], isDirectory: true)
            }
        }
        guard let folder = candidate, isComplete(folder) else { return nil }
        return folder
    }

    /// True when the model is complete on disk and its tokenizer is known to be there:
    /// either at the path we predict from the name, or because an earlier load of this
    /// model succeeded (the marker) and the folder it recorded still exists. The marker
    /// covers a tokenizer the library stores under a name we did not predict.
    func isOnDisk(_ model: String) -> Bool {
        guard modelFolder(for: model) != nil else { return false }
        let predicted = tokenizerFolder(for: model).appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: predicted.path) || hasValidMarker(for: model)
    }

    // MARK: Ready markers

    private struct Marker: Codable {
        let folder: String
    }

    func markerURL(for model: String) -> URL {
        let safe = model.replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("inkfall-ready/\(safe).json")
    }

    /// Written after every successful load. Best effort: failing to write it only
    /// means the name rule decides next time.
    func recordLoaded(model: String, folder: URL) {
        let url = markerURL(for: model)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Marker(folder: folder.path)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// A readable marker whose recorded folder still exists. A corrupt file counts as none.
    func hasValidMarker(for model: String) -> Bool {
        guard let data = try? Data(contentsOf: markerURL(for: model)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: marker.folder, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for name in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
            let bundle = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            guard fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path),
                  fm.fileExists(atPath: bundle.appendingPathComponent("weights").path) else { return false }
        }
        // An interrupted download leaves `.incomplete` markers in the library's cache.
        let cache = modelsRoot.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        if let enumerator = fm.enumerator(at: cache, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "incomplete" { return false }
        }
        return fm.fileExists(atPath: folder.appendingPathComponent("config.json").path)
    }
}

enum SpeechModelError: LocalizedError {
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            return "The speech model is not downloaded yet"
        }
    }
}

/// WhisperKit is not Sendable. The engine actor is its only user, but the compiler
/// cannot see that once `transcribe` runs off the actor, so the hand-off is explicit.
private struct KitBox: @unchecked Sendable {
    let kit: WhisperKit
}

/// Shared, cached WhisperKit engine so rebuilding the pipeline on a config change
/// doesn't reload the CoreML model. A model already on disk is loaded from there with
/// no network at all; a download happens only when the caller allows it.
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    private let store: WhisperKitModelStore
    private var pipe: KitBox?
    private var loadedModel: String?
    private var isLoading = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `baseDirectory` is injectable so tests never touch Application Support.
    init(baseDirectory: URL = InkfallDefaults.whisperKitBaseDirectory) {
        store = WhisperKitModelStore(base: baseDirectory)
    }

    /// Whether the model and its tokenizer are on disk, so a load needs no network.
    nonisolated func isModelOnDisk(_ model: String) -> Bool {
        store.isOnDisk(model)
    }

    /// Load the model ahead of the first dictation. Never downloads unless
    /// `allowDownload` is true (onboarding). `progress` reports 0...1 while a
    /// download runs; it is not called for a local load.
    @discardableResult
    func prewarm(
        model: String,
        allowDownload: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> Bool {
        do {
            _ = try await load(model: model, allowDownload: allowDownload, progress: progress)
            return true
        } catch {
            return false
        }
    }

    /// Loads the model, from disk when it is there. Throws
    /// `SpeechModelError.notDownloaded` when it is missing and downloads are not allowed.
    func load(
        model: String,
        allowDownload: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await pipe(for: model, allowDownload: allowDownload, progress: progress)
    }

    func transcribe(
        samples: [Float],
        model: String,
        language: String?,
        vocabulary: [String]
    ) async throws -> String {
        // Never downloads: a missing model is fetched earlier, in view, by the controller
        // (a silent download inside "Transcribing…" is what this used to do).
        let box = try await pipe(for: model, allowDownload: false, progress: nil)
        let kit = box.kit
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
        let results = try await box.kit.transcribe(audioArray: samples, decodeOptions: options)
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

    /// Loads and caches the model. Concurrent callers (e.g. the onboarding prewarm and
    /// the first dictation) are coalesced onto a SINGLE load rather than each starting
    /// its own model download/compile, which would race on the same files.
    private func pipe(
        for model: String,
        allowDownload: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> KitBox {
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

        // Models live in Application Support (not ~/Documents, WhisperKit's default) so
        // the app never triggers the "access your Documents" prompt.
        let base = store.base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var folder = store.modelFolder(for: model)
        // Model present but tokenizer missing: the library fetches just the tokenizer.
        if !store.isOnDisk(model) {
            guard allowDownload else { throw SpeechModelError.notDownloaded }
            // The library's own download, with its progress callback. It lists the repo
            // first, so it needs the network; the local path below never does.
            if folder == nil {
                folder = try await WhisperKit.download(
                    variant: model,
                    downloadBase: base,
                    progressCallback: progress.map { report in { @Sendable p in report(p.fractionCompleted) } }
                )
            }
        }
        guard let folder else { throw SpeechModelError.notDownloaded }

        // `modelFolder` + `download: false` skips the library's repo lookup (the 29
        // requests an online load used to make). `tokenizerFolder` points at the base
        // so the tokenizer is found on disk too; it is fetched only if still missing
        // after a download the caller allowed.
        let kit = try await WhisperKit(WhisperKitConfig(
            downloadBase: base,
            modelFolder: folder.path,
            tokenizerFolder: store.tokenizerRoot,
            load: true,
            download: false
        ))
        store.recordLoaded(model: model, folder: folder)
        let box = KitBox(kit: kit)
        pipe = box
        loadedModel = model
        return box
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
