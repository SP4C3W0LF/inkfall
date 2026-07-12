import Foundation

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

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-\(UUID().uuidString).wav")
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
