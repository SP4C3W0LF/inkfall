import Foundation

enum DictationMode: String, Codable, Sendable, CaseIterable {
    case tap    // tap to toggle
    case hold   // hold to talk

    var displayName: String {
        switch self {
        case .tap: return "Tap the shortcut"
        case .hold: return "Hold left Option"
        }
    }
}

enum SpeechEngine: String, Codable, Sendable {
    case whisperKit   // on-device CoreML (Apple Neural Engine) — no external tools
    case cli          // external whisper.cpp CLI + ggml model file
}

enum RewriteEngine: String, Codable, Sendable {
    case apple   // Apple's on-device foundation model (Apple Intelligence) — zero install
    case llama   // external llama.cpp CLI + GGUF model
    case off     // rule-based normalization only (no LLM rewrite)
}

/// Where the dictation HUD anchors on the active screen.
enum HUDPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    enum Horizontal { case leading, center, trailing }
    enum Vertical { case top, bottom }

    var horizontal: Horizontal {
        switch self {
        case .topLeft, .bottomLeft: return .leading
        case .topCenter, .bottomCenter: return .center
        case .topRight, .bottomRight: return .trailing
        }
    }

    var vertical: Vertical {
        switch self {
        case .topLeft, .topCenter, .topRight: return .top
        case .bottomLeft, .bottomCenter, .bottomRight: return .bottom
        }
    }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }
}

struct InkfallConfig: Codable, Sendable {
    /// One line saying why the settings file could not be read at launch, or nil.
    /// Set by `load`; Settings shows it in its footer. Written on the main thread at launch.
    nonisolated(unsafe) static var loadProblem: String?

    var whisperBinaryPath: String?
    var whisperModelPath: String?
    var whisperModelDirectory: String?
    var whisperModelURL: String?
    var llamaBinaryPath: String?
    var llamaModelPath: String?
    var llamaModelDirectory: String?
    var llamaModelURL: String?
    var customVocabulary: [String]
    var whisperLanguage: String

    // Redesign additions. Optional so an older config.json still decodes cleanly.
    var dictationModeRaw: String?
    var launchAtLogin: Bool?
    var reduceHUD: Bool?
    var onboardingCompleted: Bool?
    var hotKeyCode: Int?
    var hotKeyModifiers: Int?
    var hotKeyDisplay: String?
    var speechEngineRaw: String?
    var whisperKitModel: String?
    var rewriteEngineRaw: String?
    var hudPositionRaw: String?

    var speechEngine: SpeechEngine { SpeechEngine(rawValue: speechEngineRaw ?? "") ?? .whisperKit }
    // Default to Apple's on-device model: zero-install rewrite that silently falls
    // back to rule-based cleanup when Apple Intelligence isn't available.
    var rewriteEngine: RewriteEngine { RewriteEngine(rawValue: rewriteEngineRaw ?? "") ?? .apple }
    // Default matches the historical fixed position: top-center of the active screen.
    var hudPosition: HUDPosition { HUDPosition(rawValue: hudPositionRaw ?? "") ?? .topCenter }

    /// Whether the pipeline runs an LLM rewrite pass (used to show "Polishing…").
    var rewriteEnabled: Bool {
        switch rewriteEngine {
        case .off: return false
        case .apple: return true   // availability is checked at runtime; falls back silently
        case .llama: return hasLlamaConfiguration
        }
    }
    /// The model name as Settings stores and shows it (the friendly one).
    var whisperKitModelDisplayName: String {
        guard let name = whisperKitModel, !name.isEmpty else { return "base.en" }
        return name
    }
    /// The model name the speech library understands. Everything that hands a model
    /// to the engine goes through this, never the stored string.
    var whisperKitModelName: String {
        WhisperModelNames.libraryName(for: whisperKitModelDisplayName)
    }

    var mode: DictationMode { DictationMode(rawValue: dictationModeRaw ?? "") ?? .tap }
    var hasCompletedOnboarding: Bool { onboardingCompleted ?? false }

    var hotKey: KeyCombo {
        // A hand-edited file can hold anything; out-of-range values fall back to the default.
        guard let code = hotKeyCode, let mods = hotKeyModifiers, let display = hotKeyDisplay,
              let combo = KeyCombo.validated(code: code, modifiers: mods, display: display) else {
            return .defaultCombo
        }
        return combo
    }

    static let `default` = InkfallConfig(
        whisperBinaryPath: nil,
        whisperModelPath: nil,
        whisperModelDirectory: nil,
        whisperModelURL: nil,
        llamaBinaryPath: nil,
        llamaModelPath: nil,
        llamaModelDirectory: nil,
        llamaModelURL: nil,
        customVocabulary: [],
        whisperLanguage: "en",
        dictationModeRaw: nil,
        launchAtLogin: nil,
        reduceHUD: nil,
        onboardingCompleted: nil,
        hotKeyCode: nil,
        hotKeyModifiers: nil,
        hotKeyDisplay: nil,
        speechEngineRaw: nil,
        whisperKitModel: nil,
        rewriteEngineRaw: nil,
        hudPositionRaw: nil
    )

    var hasWhisperConfiguration: Bool {
        switch speechEngine {
        case .whisperKit:
            return true   // WhisperKit downloads and manages its own model
        case .cli:
            return hasValue(whisperBinaryPath) && hasValue(whisperModelPath)
        }
    }

    var hasLlamaConfiguration: Bool {
        hasValue(llamaBinaryPath) && hasValue(llamaModelPath)
    }

    /// The INKFALL_* variables that override a plain string setting.
    static func environmentStringKeys() -> [(name: String, path: WritableKeyPath<InkfallConfig, String?>)] {
        [
            ("INKFALL_WHISPER_BIN", \.whisperBinaryPath),
            ("INKFALL_WHISPER_MODEL", \.whisperModelPath),
            ("INKFALL_WHISPER_MODEL_DIR", \.whisperModelDirectory),
            ("INKFALL_WHISPER_MODEL_URL", \.whisperModelURL),
            ("INKFALL_LLAMA_BIN", \.llamaBinaryPath),
            ("INKFALL_LLAMA_MODEL", \.llamaModelPath),
            ("INKFALL_LLAMA_MODEL_DIR", \.llamaModelDirectory),
            ("INKFALL_LLAMA_MODEL_URL", \.llamaModelURL)
        ]
    }

    func applyingEnvironment(_ environment: [String: String]) -> InkfallConfig {
        var config = self
        for (name, path) in Self.environmentStringKeys() {
            config[keyPath: path] = environment[name] ?? config[keyPath: path]
        }
        if let vocabulary = environment["INKFALL_VOCABULARY"] {
            config.customVocabulary = vocabulary
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return config
    }

    /// Loads the settings file and applies the INKFALL_* overrides. A file that cannot
    /// be read is copied aside, defaults are used, and `loadProblem` says so.
    static func load(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        now: Date = Date()
    ) -> InkfallConfig {
        let url = fileURL ?? (try? configURL(fileManager: fileManager))
        var loaded: InkfallConfig?
        var problem: String?
        if let url {
            let result = loadFile(at: url, fileManager: fileManager, now: now)
            loaded = result.config
            problem = result.problem
        }
        loadProblem = problem
        return (loaded ?? .default).applyingEnvironment(environment)
    }

    /// Reads one settings file. Missing file: (nil, nil). Unreadable or undecodable
    /// file: the bytes are copied to `config.json.bad-<yyyyMMdd-HHmmss>` (never over an
    /// existing copy) and the problem line says where.
    static func loadFile(
        at url: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> (config: InkfallConfig?, problem: String?) {
        guard fileManager.fileExists(atPath: url.path) else { return (nil, nil) }
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (nil, "\(name) couldn't be read, so defaults are in use.")
        }
        do {
            return (try JSONDecoder().decode(InkfallConfig.self, from: data), nil)
        } catch {
            if let copy = badCopyURL(for: url, fileManager: fileManager, now: now),
               (try? data.write(to: copy, options: .atomic)) != nil {
                return (nil, "\(name) couldn't be read, so defaults are in use. A copy is saved as \(copy.lastPathComponent).")
            }
            return (nil, "\(name) couldn't be read, so defaults are in use. A copy couldn't be saved.")
        }
    }

    /// `config.json.bad-yyyyMMdd-HHmmss`, with `-2`, `-3`... if that name is taken.
    static func badCopyURL(for url: URL, fileManager: FileManager = .default, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let base = url.lastPathComponent + ".bad-" + stamp
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(base)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            if n > 99 { return nil }
            candidate = folder.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    /// The file's own settings, no environment, no side effects. Nil if absent or unreadable.
    static func readOnDisk(fileManager: FileManager = .default, fileURL: URL? = nil) -> InkfallConfig? {
        guard let url = fileURL ?? (try? configURL(fileManager: fileManager)),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InkfallConfig.self, from: data)
    }

    /// What to write when this config came from `loaded`: a value that came from an
    /// INKFALL_* variable and was not edited keeps what the file had.
    func forSaving(loaded: InkfallConfig, onDisk: InkfallConfig, environment: [String: String]) -> InkfallConfig {
        var out = self
        for (name, path) in Self.environmentStringKeys() where environment[name] != nil {
            if out[keyPath: path] == loaded[keyPath: path] {
                out[keyPath: path] = onDisk[keyPath: path]
            }
        }
        if environment["INKFALL_VOCABULARY"] != nil, out.customVocabulary == loaded.customVocabulary {
            out.customVocabulary = onDisk.customVocabulary
        }
        return out
    }

    /// Saves without writing environment-supplied values into config.json.
    func saveKeepingEnvironmentValues(
        loaded: InkfallConfig,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws {
        let onDisk = Self.readOnDisk(fileManager: fileManager, fileURL: fileURL) ?? .default
        try forSaving(loaded: loaded, onDisk: onDisk, environment: environment)
            .save(fileManager: fileManager, fileURL: fileURL)
    }

    func save(fileManager: FileManager = .default, fileURL: URL? = nil) throws {
        let url = try fileURL ?? Self.configURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.pretty.encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func configURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ConfigError.missingApplicationSupportDirectory
        }
        return appSupport.appendingPathComponent("Inkfall/config.json")
    }

    private func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PipelineContext: Sendable {
    let vocabulary: [String]
    let targetAppName: String?
}

enum ConfigError: LocalizedError {
    case missingApplicationSupportDirectory

    var errorDescription: String? {
        "Could not locate Application Support"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - Settings form logic (pure, tested without a window)

/// Model-name rules.
enum WhisperModelNames {
    /// Settings shows `large-v3-turbo`; the model repository's folder is
    /// `openai_whisper-large-v3_turbo`, so the library needs the underscore.
    /// Unknown names pass through unchanged.
    static func libraryName(for stored: String) -> String {
        stored == "large-v3-turbo" ? "large-v3_turbo" : stored
    }

    /// `.en` models only understand English.
    static func isEnglishOnly(_ model: String) -> Bool {
        model.hasSuffix(".en")
    }
}

enum PopupChoices {
    /// The popup's list, plus the current value when the list does not hold it, so
    /// Save keeps a value Settings has no entry for.
    static func items(base: [String], current: String?) -> [String] {
        guard let current, !current.isEmpty, !base.contains(current) else { return base }
        return base + [current]
    }
}

enum UnsavedChoice: Sendable { case save, discard, cancel }

enum UnsavedChanges {
    /// Whether the window may close after the user's answer. A failed save keeps it open.
    static func mayClose(choice: UnsavedChoice, saveSucceeded: Bool) -> Bool {
        switch choice {
        case .save: return saveSucceeded
        case .discard: return true
        case .cancel: return false
        }
    }
}

/// Everything the Settings form holds, as plain values. `applied(to:)` is what Save
/// writes; comparing two forms is what "unsaved changes" means.
struct SettingsForm: Equatable, Sendable {
    var whisperBinaryPath = ""
    var whisperModelPath = ""
    var whisperModelDirectory = ""
    var whisperModelURL = ""
    var llamaBinaryPath = ""
    var llamaModelPath = ""
    var llamaModelDirectory = ""
    var llamaModelURL = ""
    var language = "en"
    var vocabulary = ""
    var hotKey = KeyCombo.defaultCombo
    var speechEngine = SpeechEngine.whisperKit
    var rewriteEngine = RewriteEngine.apple
    var hudPosition = HUDPosition.topCenter
    var mode = DictationMode.tap
    /// nil when the model popup has not been built yet: the config's model stays.
    var whisperKitModel: String?

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func applied(to config: InkfallConfig) -> InkfallConfig {
        var updated = config
        updated.whisperBinaryPath = Self.clean(whisperBinaryPath)
        updated.whisperModelPath = Self.clean(whisperModelPath)
        updated.whisperModelDirectory = Self.clean(whisperModelDirectory)
        updated.whisperModelURL = Self.clean(whisperModelURL)
        updated.llamaBinaryPath = Self.clean(llamaBinaryPath)
        updated.llamaModelPath = Self.clean(llamaModelPath)
        updated.llamaModelDirectory = Self.clean(llamaModelDirectory)
        updated.llamaModelURL = Self.clean(llamaModelURL)
        if let model = whisperKitModel, !model.isEmpty { updated.whisperKitModel = model }
        updated.whisperLanguage = Self.effectiveLanguage(
            engine: speechEngine, model: updated.whisperKitModelDisplayName, chosen: language)
        updated.customVocabulary = vocabulary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.hotKeyCode = Int(hotKey.keyCode)
        updated.hotKeyModifiers = Int(hotKey.carbonModifiers)
        updated.hotKeyDisplay = hotKey.display
        updated.speechEngineRaw = speechEngine.rawValue
        updated.rewriteEngineRaw = rewriteEngine.rawValue
        updated.hudPositionRaw = hudPosition.rawValue
        updated.dictationModeRaw = mode.rawValue
        return updated
    }

    /// An English-only WhisperKit model always runs in English.
    static func effectiveLanguage(engine: SpeechEngine, model: String, chosen: String) -> String {
        if engine == .whisperKit && WhisperModelNames.isEnglishOnly(model) { return "en" }
        return chosen.isEmpty ? "en" : chosen
    }
}
