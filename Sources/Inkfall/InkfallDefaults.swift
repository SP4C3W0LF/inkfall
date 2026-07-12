import Foundation

/// Zero-config defaults so the user doesn't have to hunt for a CLI or paste model
/// URLs: an app-managed models folder, a recommended model, and best-effort
/// detection of an already-installed Whisper engine (e.g. via Homebrew).
enum InkfallDefaults {
    private static var applicationSupport: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// App-managed folder for downloaded models — created on demand, never picked.
    static var modelsDirectory: URL {
        applicationSupport.appendingPathComponent("Inkfall/models", isDirectory: true)
    }

    /// Where WhisperKit downloads its CoreML models. Kept inside Application Support
    /// (NOT ~/Documents, WhisperKit's default) so the app never needs — or triggers —
    /// the macOS "access your Documents folder" permission prompt.
    static var whisperKitBaseDirectory: URL {
        applicationSupport.appendingPathComponent("Inkfall/WhisperKit", isDirectory: true)
    }

    struct RecommendedModel {
        let name: String
        let size: String
        let urlString: String
        let filename: String
        let sha256: String
    }

    /// Whisper base.en — a good speed/quality default for English dictation.
    static let recommendedWhisper = RecommendedModel(
        name: "Whisper base.en",
        size: "~142 MB",
        urlString: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
        filename: "ggml-base.en.bin",
        // Authoritative git-LFS digest from the whisper.cpp HuggingFace repo.
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
    )

    /// Common install locations for a whisper.cpp CLI (Homebrew, /usr/local).
    private static let whisperCLICandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp"
    ]

    /// The path to an installed whisper CLI, if one is found.
    static func detectWhisperCLI() -> String? {
        whisperCLICandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
