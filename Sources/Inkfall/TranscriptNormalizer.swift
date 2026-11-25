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
    // The engine writes these as "new line", "newline" or "new-line"; "next line" is the
    // same command. The gap is a run of blanks or one hyphen.
    private static let formattingCommands: [(NSRegularExpression, String)] = [
        (#"new(?:[ \t]+|-)?paragraph"#, "\n\n"),
        (#"(?:new(?:[ \t]+|-)?|next(?:[ \t]+|-))line"#, "\n"),
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

    private static let spokenMarkPhrase = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’])(?<!\p{L}-)(?:question(?:[ \t]+|-)mark|exclamation(?:[ \t]+|-)(?:mark|point)|full(?:[ \t]+|-)stop|semi(?:[ \t]+|-)?colon|colon|comma|period)(?![\p{L}\p{N}'’]|-\p{L})"#,
        options: [.caseInsensitive]
    )
    /// Extra "talked about" words after a spoken mark: "the comma key", "comma separated values".
    private static let spokenTalkedAboutAfter: Set<String> = [
        "key", "keys", "symbol", "symbols", "sign", "signs", "separated"
    ]

    func normalize(_ input: String, vocabulary: [String]) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = applyCorrectionCommands(text)
        text = applyFormattingCommands(text)
        text = applySpokenPunctuation(text)
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

    /// "question mark", "comma", "full stop" and the rest become the mark itself, attached to
    /// the word before it, replacing any mark the engine put there. Left to right, so a
    /// mark produced here is final and a second one right after it can build on it ("?!").
    private func applySpokenPunctuation(_ input: String) -> String {
        guard Self.spokenMarkPhrase.firstMatch(
            in: input, range: NSRange(location: 0, length: (input as NSString).length)) != nil
        else { return input }

        let text = NSMutableString(string: input)
        var from = 0
        var lastMark: Int?
        while from < text.length {
            guard let match = Self.spokenMarkPhrase.firstMatch(
                in: text as String, options: [.withTransparentBounds],
                range: NSRange(location: from, length: text.length - from)) else { break }
            let range = match.range
            let end = range.location + range.length
            let spoken = text.substring(with: range).lowercased()

            let previous = wordEnding(at: range.location, in: text)
            let next = wordStarting(at: end, in: text)
            var talkedAbout = false
            if let previous, Self.talkedAboutBefore.contains(previous) { talkedAbout = true }
            if let next, Self.talkedAboutAfter.contains(next) || Self.spokenTalkedAboutAfter.contains(next) {
                talkedAbout = true
            }
            // "a difficult period" is speech: the word only counts as a mark on its own.
            if spoken == "period", !isStandalone(range, in: text) { talkedAbout = true }
            if talkedAbout { from = end; continue }

            let mark = spokenMark(for: spoken)

            // What the mark attaches to: back over blanks, the engine's own marks, blanks.
            var lead = range.location
            while lead > 0, isBlank(text.character(at: lead - 1)) { lead -= 1 }
            if let last = lastMark, lead == last + 1, "?!".contains(mark), "?!".contains(spokenMarkChar(at: last, in: text)) {
                // "question mark exclamation mark": keep the first, add the second.
            } else {
                while lead > 0, isSpokenMarkPunctuation(text.character(at: lead - 1)) { lead -= 1 }
                while lead > 0, isBlank(text.character(at: lead - 1)) { lead -= 1 }
            }

            // Marks the engine put after the phrase belong to it too.
            var tail = end
            while tail < text.length, isBlank(text.character(at: tail)) { tail += 1 }
            while tail < text.length, isSpokenMarkPunctuation(text.character(at: tail)) { tail += 1 }
            while tail < text.length, isBlank(text.character(at: tail)) { tail += 1 }

            // Nothing to attach to (start of the text or of a line, or an opening bracket).
            let opens = lead == 0 || text.character(at: lead - 1) == 10
                || "([{\u{201C}\u{2018}".utf16.contains(text.character(at: lead - 1))
            if opens {
                text.replaceCharacters(in: NSRange(location: range.location, length: tail - range.location), with: "")
                from = range.location
                lastMark = nil
                continue
            }

            var gap = " "
            if tail >= text.length { gap = "" } else {
                let following = text.character(at: tail)
                if following == 10 || ")]}\u{201D}\u{2019}".utf16.contains(following) { gap = "" }
                // A straight quote closes when an odd number of them came before.
                if following == 34, text.substring(to: lead).filter({ $0 == "\"" }).count % 2 == 1 { gap = "" }
            }
            text.replaceCharacters(in: NSRange(location: lead, length: tail - lead), with: mark + gap)
            lastMark = lead
            from = lead + 1
        }
        return text as String
    }

    private func spokenMark(for phrase: String) -> String {
        if phrase.hasPrefix("question") { return "?" }
        if phrase.hasPrefix("exclamation") { return "!" }
        if phrase.hasPrefix("semi") { return ";" }
        if phrase == "colon" { return ":" }
        if phrase == "comma" { return "," }
        return "."  // full stop, period
    }

    private func spokenMarkChar(at index: Int, in text: NSString) -> String {
        text.substring(with: NSRange(location: index, length: 1))
    }

    /// The marks an engine puts around a spoken one. Dashes are left alone.
    private func isSpokenMarkPunctuation(_ unit: unichar) -> Bool {
        ".,!?;:\u{2026}".utf16.contains(unit)
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
        // Before a mark ("send it um."): the blank before it goes too.
        text = replace(#"(?i)[ \t]+"# + word + #"(?=[ \t]*[.!?;:…])"#, in: text, with: "")
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
        // A sentence can end on a spoken comma, colon or semicolon ("Dear Sam:").
        if ".!?,:;".contains(last) { return input }
        if input.contains("\n- ") { return input }
        return input + "."
    }
}
