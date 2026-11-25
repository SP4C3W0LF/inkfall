import Foundation

struct TranscriptNormalizer: Sendable {
    /// Punctuation a speech engine puts around a spoken command.
    private static let commandPunctuation = CharacterSet(charactersIn: ".,!?;:…—–")
    /// Where a sentence ends, for "scratch that" to know how far back to remove.
    private static let sentenceEnds = CharacterSet(charactersIn: ".!?\n")

    private static let correctionPhrase = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’])(?:scratch that|delete that|never mind)(?![\p{L}\p{N}'’])"#,
        options: [.caseInsensitive]
    )
    private static let fillerWord = #"(?<![\p{L}\p{N}'’-])(?:um+|uh+|erm+)(?![\p{L}\p{N}'’-])"#
    private static let formattingCommands: [(NSRegularExpression, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("bullet list", "\n- "),
        ("next bullet", "\n- ")
    ].map { phrase, replacement in
        (try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}'’])"# + phrase + #"(?![\p{L}\p{N}'’])"#,
            options: [.caseInsensitive]
        ), replacement)
    }
    /// A formatting phrase is being talked about, not obeyed, when one of these words is next to it.
    private static let talkedAboutBefore: Set<String> = [
        "a", "an", "the", "this", "that", "each", "every", "another", "one", "per",
        "my", "your", "our", "its", "his", "her", "their"
    ]
    private static let talkedAboutAfter: Set<String> = [
        "is", "are", "was", "were", "of", "character", "characters", "break", "breaks"
    ]

    func normalize(_ input: String, vocabulary: [String]) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = applyCorrectionCommands(text)
        text = applyFormattingCommands(text)
        text = removeFillers(text)
        text = applyVocabulary(text, vocabulary: vocabulary)
        text = collapseWhitespace(text)
        // Only punctuation left ("um." with the filler gone): there is nothing to insert.
        if text.rangeOfCharacter(from: .alphanumerics) == nil { return "" }
        return text
    }

    func finalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = collapseWhitespace(text)
        text = capitalizeSentenceStarts(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    /// "scratch that", "delete that" and "never mind" are commands only when they stand
    /// alone: punctuation (or the start) before, punctuation (or the end) after. Then the
    /// phrase and the sentence before it go; everything earlier stays.
    private func applyCorrectionCommands(_ input: String) -> String {
        var text = input
        // Each pass removes one command, so a repeated command removes one more sentence.
        for _ in 0..<200 {
            let ns = text as NSString
            let matches = Self.correctionPhrase.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard let match = matches.first(where: { match in
                // "never mind" is ordinary speech far more often than the other two
                // ("I told her, never mind, it's fine"), so it must open its own sentence.
                let phrase = ns.substring(with: match.range).lowercased()
                return isStandalone(match.range, in: ns, mustOpenSentence: phrase == "never mind")
            }) else { break }

            // The phrase plus the punctuation and spaces that close it.
            var end = match.range.location + match.range.length
            while end < ns.length, isBlank(ns.character(at: end)) { end += 1 }
            while end < ns.length, isCommandPunctuation(ns.character(at: end)) { end += 1 }
            while end < ns.length, isBlank(ns.character(at: end)) { end += 1 }

            let before = ns.substring(to: match.range.location)
            text = keepingBeforeLastSentence(before) + ns.substring(from: end)
        }
        return text
    }

    private func isStandalone(_ range: NSRange, in ns: NSString, mustOpenSentence: Bool = false) -> Bool {
        var i = range.location - 1
        while i >= 0, isBlank(ns.character(at: i)) { i -= 1 }
        let startsClean: Bool
        if i < 0 || ns.character(at: i) == 10 {
            startsClean = true
        } else if mustOpenSentence {
            startsClean = isSentenceEnd(ns.character(at: i))
        } else {
            startsClean = isCommandPunctuation(ns.character(at: i))
        }
        var j = range.location + range.length
        while j < ns.length, isBlank(ns.character(at: j)) { j += 1 }
        let endsClean = j >= ns.length || isCommandPunctuation(ns.character(at: j)) || ns.character(at: j) == 10
        return startsClean && endsClean
    }

    /// `before` with its last sentence removed (back to the previous . ! ? or line break).
    private func keepingBeforeLastSentence(_ before: String) -> String {
        var scalars = Array(before.unicodeScalars)
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { scalars.removeLast() }
        // The sentence's own closing marks ("...") are not the boundary before it.
        while let last = scalars.last, ".!?…".unicodeScalars.contains(last) { scalars.removeLast() }
        guard let boundary = scalars.lastIndex(where: { Self.sentenceEnds.contains($0) }) else { return "" }
        var kept = String(String.UnicodeScalarView(scalars[...boundary]))
        if !kept.hasSuffix("\n") { kept += " " }
        return kept
    }

    private func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    private func isSentenceEnd(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return ".!?…".unicodeScalars.contains(scalar)
    }

    private func isCommandPunctuation(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return Self.commandPunctuation.contains(scalar)
    }

    /// "new line" and friends are formatting, unless the words around them show they are
    /// being talked about ("a new line", "new line is a command").
    private func applyFormattingCommands(_ input: String) -> String {
        var text = input
        for (regex, replacement) in Self.formattingCommands {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            // Right to left, so earlier ranges stay valid.
            for match in matches.reversed() {
                let range = match.range
                let previous = wordEnding(at: range.location, in: ns)
                let next = wordStarting(at: range.location + range.length, in: ns)
                if let previous, Self.talkedAboutBefore.contains(previous) { continue }
                if let next, Self.talkedAboutAfter.contains(next) { continue }

                // Swallow the comma or full stop the engine puts beside the command.
                var start = range.location
                var probe = start
                while probe > 0, isBlank(ns.character(at: probe - 1)) { probe -= 1 }
                if probe > 0, ns.character(at: probe - 1) == 44 { start = probe - 1 }
                var end = range.location + range.length
                if end < ns.length, ns.character(at: end) == 44 || ns.character(at: end) == 46 { end += 1 }

                text = (text as NSString).replacingCharacters(
                    in: NSRange(location: start, length: end - start), with: replacement)
            }
        }
        return text
    }

    private func wordEnding(at index: Int, in ns: NSString) -> String? {
        var end = index
        while end > 0, isBlank(ns.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0, isWordUnit(ns.character(at: start - 1)) { start -= 1 }
        guard start < end else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    private func wordStarting(at index: Int, in ns: NSString) -> String? {
        var start = index
        while start < ns.length, isBlank(ns.character(at: start)) { start += 1 }
        var end = start
        while end < ns.length, isWordUnit(ns.character(at: end)) { end += 1 }
        guard start < end else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    private func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "\u{2019}"
    }

    /// "um", "uh", "erm" go anywhere, with one adjoining comma. "you know" and "I mean" go
    /// only when set off as an aside, so "I mean it" and "you know the fix" keep every word.
    private func removeFillers(_ input: String) -> String {
        var text = input
        let word = Self.fillerWord
        // A comma after the filler goes with it; failing that, a comma before it.
        text = replace(#"(?i)"# + word + #"[ \t]*,"#, in: text, with: "")
        text = replace(#"(?i),[ \t]*"# + word, in: text, with: "")
        text = replace(#"(?i)"# + word, in: text, with: "")
        // An aside between two commas: it takes the comma after it.
        text = replace(#"(?i),[ \t]*(?:you know|i mean)[ \t]*,"#, in: text, with: ",")
        // Or at the start of a sentence, followed by a comma.
        text = replace(#"(?i)(^[ \t]*|[.!?\n][ \t]*)(?:you know|i mean)[ \t]*,"#, in: text, with: "$1")
        return text
    }

    private func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
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

    /// Capitalises the first letter of the text, of each line, and after . ! ? followed by
    /// white space. Never inside a token: web addresses, prices and times keep their case.
    private func capitalizeSentenceStarts(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        var shouldCapitalize = true
        let openers = CharacterSet(charactersIn: "-*•\"'“‘([")

        for (index, scalar) in scalars.enumerated() {
            if shouldCapitalize {
                if CharacterSet.letters.contains(scalar) {
                    output.append(contentsOf: String(Character(scalar)).uppercased().unicodeScalars)
                    shouldCapitalize = false
                } else {
                    output.append(scalar)
                    // A bullet marker, quote or bracket does not use up the capital.
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar), !openers.contains(scalar) {
                        shouldCapitalize = false
                    }
                }
            } else {
                output.append(scalar)
            }

            if scalar == "\n" {
                shouldCapitalize = true
            } else if ".!?".unicodeScalars.contains(scalar),
                      index + 1 < scalars.count,
                      CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1]),
                      !endsWithAbbreviation(scalars, before: index) {
                shouldCapitalize = true
            }
        }

        return String(output)
    }

    /// "e.g.", "i.e." and "vs." are followed by a lower-case word.
    private func endsWithAbbreviation(_ scalars: [Unicode.Scalar], before index: Int) -> Bool {
        guard scalars[index] == "." else { return false }
        var start = index
        while start > 0, CharacterSet.letters.contains(scalars[start - 1]) || scalars[start - 1] == "." { start -= 1 }
        let token = String(String.UnicodeScalarView(scalars[start..<index])).lowercased()
        return ["e.g", "i.e", "vs"].contains(token)
    }

    private func ensureTerminalPunctuation(_ input: String) -> String {
        guard let last = input.last else { return input }
        if ".!?".contains(last) { return input }
        if input.contains("\n- ") { return input }
        return input + "."
    }
}
