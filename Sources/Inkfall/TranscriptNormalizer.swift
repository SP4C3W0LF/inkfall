import Foundation

struct TranscriptNormalizer: Sendable {
    private let fillerPatterns = [
        "\\bum+\\b",
        "\\buh+\\b",
        "\\berm+\\b",
        "\\byou know\\b",
        "\\bi mean\\b"
    ]

    func normalize(_ input: String, vocabulary: [String]) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = applyCorrectionCommands(text)
        text = applyFormattingCommands(text)
        text = removeFillers(text)
        text = applyVocabulary(text, vocabulary: vocabulary)
        text = collapseWhitespace(text)
        return text
    }

    func finalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = collapseWhitespace(text)
        text = capitalizeSentenceStarts(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    private func applyCorrectionCommands(_ input: String) -> String {
        var text = input

        if let range = text.range(of: #"(?i)\b(scratch that|delete that|never mind)\b"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
        }

        text = text.replacingOccurrences(
            of: #"(?i)\bno actually\b"#,
            with: "actually",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"(?i)\bmake that\b"#,
            with: "actually",
            options: .regularExpression
        )

        if let range = text.range(of: #"(?i)\bactually\b"#, options: .regularExpression) {
            let before = text[..<range.lowerBound]
            let after = text[range.upperBound...]
            if before.count < 80 {
                text = String(after)
            }
        }

        return text
    }

    private func applyFormattingCommands(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: #"(?i)\bnew paragraph\b"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bnew line\b"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bbullet list\b"#, with: "\n- ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bnext bullet\b"#, with: "\n- ", options: .regularExpression)
        return text
    }

    private func removeFillers(_ input: String) -> String {
        fillerPatterns.reduce(input) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
    }

    private func applyVocabulary(_ input: String, vocabulary: [String]) -> String {
        vocabulary.reduce(input) { partial, term in
            guard !term.isEmpty else { return partial }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
            return partial.replacingOccurrences(of: pattern, with: term, options: [.regularExpression, .caseInsensitive])
        }
    }

    private func collapseWhitespace(_ input: String) -> String {
        input
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentenceStarts(_ input: String) -> String {
        var output = ""
        var shouldCapitalize = true

        for scalar in input.unicodeScalars {
            let character = Character(scalar)
            if shouldCapitalize, CharacterSet.letters.contains(scalar) {
                output.append(String(character).uppercased())
                shouldCapitalize = false
            } else {
                output.append(character)
            }

            if ".!?\n".unicodeScalars.contains(scalar) {
                shouldCapitalize = true
            }
        }

        return output
    }

    private func ensureTerminalPunctuation(_ input: String) -> String {
        guard let last = input.last else { return input }
        if ".!?".contains(last) { return input }
        if input.contains("\n- ") { return input }
        return input + "."
    }
}
