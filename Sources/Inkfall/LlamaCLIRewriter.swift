import Foundation

struct CompositeRewriter: TranscriptRewriter {
    let primary: TranscriptRewriter
    let fallback: TranscriptRewriter

    func rewrite(transcript: String, context: PipelineContext) async throws -> CleanedTranscript {
        do {
            return try await primary.rewrite(transcript: transcript, context: context)
        } catch {
            return try await fallback.rewrite(transcript: transcript, context: context)
        }
    }
}

struct RuleBasedRewriter: TranscriptRewriter {
    let normalizer: TranscriptNormalizer

    func rewrite(transcript: String, context: PipelineContext) async throws -> CleanedTranscript {
        let clean = normalizer.finalize(transcript)
        return CleanedTranscript(
            cleanText: clean,
            confidence: clean.isEmpty ? .low : .medium,
            needsReview: clean.isEmpty
        )
    }
}

struct LlamaCLIRewriter: TranscriptRewriter {
    let config: InkfallConfig

    func rewrite(transcript: String, context: PipelineContext) async throws -> CleanedTranscript {
        guard
            let binary = config.llamaBinaryPath,
            let model = config.llamaModelPath,
            !binary.isEmpty,
            !model.isEmpty
        else {
            throw InkfallError.invalidRewriteOutput
        }

        let prompt = """
        You are Inkfall, a private local dictation cleanup engine.
        Rewrite the transcript into ready-to-send text.
        Preserve the user's meaning exactly. Do not summarize. Do not invent details.
        Remove filler words and resolve self-corrections.
        Keep dictated formatting such as new paragraphs and bullet lists.
        Return only compact JSON with keys clean_text, confidence, needs_review.

        Custom vocabulary: \(context.vocabulary.joined(separator: ", "))
        Target app: \(context.targetAppName ?? "unknown")

        Transcript:
        \(transcript)
        """

        let output = try await CommandRunner.run(
            binary,
            arguments: [
                "-m", model,
                "-p", prompt,
                "--temp", "0.1",
                "-n", "256",
                "--no-display-prompt"
            ],
            timeout: 20
        )

        guard let data = extractJSONObject(from: output).data(using: .utf8) else {
            throw InkfallError.invalidRewriteOutput
        }

        return try JSONDecoder().decode(CleanedTranscript.self, from: data)
    }

    private func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            return output
        }
        return String(output[start...end])
    }
}
