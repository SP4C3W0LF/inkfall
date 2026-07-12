import Foundation

enum DictationMode: String, Codable, Sendable {
    case tap    // tap to toggle
    case hold   // hold to talk
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
    var whisperKitModelName: String {
        guard let name = whisperKitModel, !name.isEmpty else { return "base.en" }
        return name
    }

    var mode: DictationMode { DictationMode(rawValue: dictationModeRaw ?? "") ?? .tap }
    var isLaunchAtLogin: Bool { launchAtLogin ?? false }
    var isReduceHUD: Bool { reduceHUD ?? false }
    var hasCompletedOnboarding: Bool { onboardingCompleted ?? false }

    var hotKey: KeyCombo {
        guard let code = hotKeyCode, let mods = hotKeyModifiers, let display = hotKeyDisplay else {
            return .defaultCombo
        }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods), display: display)
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

    static func load(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> InkfallConfig {
        var config = loadFromDisk(fileManager: fileManager) ?? .default

        config.whisperBinaryPath = environment["INKFALL_WHISPER_BIN"] ?? config.whisperBinaryPath
        config.whisperModelPath = environment["INKFALL_WHISPER_MODEL"] ?? config.whisperModelPath
        config.whisperModelDirectory = environment["INKFALL_WHISPER_MODEL_DIR"] ?? config.whisperModelDirectory
        config.whisperModelURL = environment["INKFALL_WHISPER_MODEL_URL"] ?? config.whisperModelURL
        config.llamaBinaryPath = environment["INKFALL_LLAMA_BIN"] ?? config.llamaBinaryPath
        config.llamaModelPath = environment["INKFALL_LLAMA_MODEL"] ?? config.llamaModelPath
        config.llamaModelDirectory = environment["INKFALL_LLAMA_MODEL_DIR"] ?? config.llamaModelDirectory
        config.llamaModelURL = environment["INKFALL_LLAMA_MODEL_URL"] ?? config.llamaModelURL

        if let vocabulary = environment["INKFALL_VOCABULARY"] {
            config.customVocabulary = vocabulary
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return config
    }

    func save(fileManager: FileManager = .default) throws {
        let url = try Self.configURL(fileManager: fileManager)
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

    private static func loadFromDisk(fileManager: FileManager) -> InkfallConfig? {
        guard let url = try? configURL(fileManager: fileManager) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InkfallConfig.self, from: data)
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
