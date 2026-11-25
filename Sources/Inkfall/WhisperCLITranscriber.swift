import Foundation

/// The WAV files handed to a whisper.cpp CLI. They live in their own folder so that
/// leftovers (the app quit or crashed mid-transcription) can be found and removed
/// without touching anything else in the temp directory.
enum TemporaryRecordings {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkfall-recordings", isDirectory: true)
    }

    static func newFileURL(in folder: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("inkfall-\(UUID().uuidString).wav")
    }

    /// Removes files older than `maxAge` seconds. Safe to call at any time; wave 2 calls
    /// it at launch. Returns how many files it removed.
    @discardableResult
    static func sweep(in folder: URL = directory, olderThan maxAge: TimeInterval = 600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}

struct WhisperCLITranscriber: SpeechTranscriber {
    let config: InkfallConfig

    func transcribe(audioClip: AudioClip, context: PipelineContext) async throws -> Transcript {
        guard
            let binary = config.whisperBinaryPath,
            let model = config.whisperModelPath,
            !binary.isEmpty,
            !model.isEmpty
        else {
            throw InkfallError.missingWhisperConfiguration
        }

        // Anything a crash or kill left behind goes first.
        TemporaryRecordings.sweep()
        let tempURL = try TemporaryRecordings.newFileURL()
        try WavFileWriter.write(audioClip: audioClip, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var arguments = [
            "-m", model,
            "-f", tempURL.path,
            "-nt",
            "-l", config.whisperLanguage
        ]

        if !context.vocabulary.isEmpty {
            arguments.append(contentsOf: ["--prompt", context.vocabulary.joined(separator: ", ")])
        }

        let output = try await CommandRunner.run(binary, arguments: arguments, timeout: 60)
        let text = parseWhisperOutput(output)

        guard !text.isEmpty else {
            throw InkfallError.commandFailed("Whisper returned an empty transcript")
        }

        return Transcript(rawText: text)
    }

    private func parseWhisperOutput(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\s*\[[^\]]+\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
