import Foundation

/// Whether dictated text starts with a capital follows the Mac's own typing setting:
/// System Settings > Keyboard > Text Input > "Capitalize words automatically". On (the
/// default), text arrives as the engine and the clean-up produced it. Off, the first
/// letter of the text and of every line after a dictated line break is lowered, the way
/// the Mac leaves it when you type.
enum FirstLetterPolicy {
    /// The global preference behind that switch. Missing means on, as on a new Mac.
    static let systemKey = "NSAutomaticCapitalizationEnabled"

    static func systemCapitalizes() -> Bool {
        capitalizes(storedValue: UserDefaults.standard.object(forKey: systemKey))
    }

    /// The decision apart from where the value is stored, so it can be tested without
    /// touching anyone's preferences.
    static func capitalizes(storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? true
    }

    /// `capitalize` true: the text is returned as it is. False: the first letter of each
    /// line is lowered, unless lowering it would be wrong whatever the setting says:
    /// the word "I" (and "I'm", "I'll"...), a word with another capital in it (NASA,
    /// McDonald), or a word from the custom vocabulary, which keeps the spelling given.
    /// A capital after a full stop inside a line is left alone.
    static func apply(_ text: String, capitalize: Bool, vocabulary: [String] = []) -> String {
        guard !capitalize else { return text }
        return text.components(separatedBy: "\n")
            .map { loweringFirstLetter(of: $0, vocabulary: vocabulary) }
            .joined(separator: "\n")
    }

    private static func loweringFirstLetter(of text: String, vocabulary: [String]) -> String {
        guard let first = text.firstIndex(where: { $0.isLetter }) else { return text }
        // Only when the letter opens the line: digits or other words before it mean
        // this is not the first letter.
        let lead = text[text.startIndex..<first]
        guard lead.allSatisfy({ $0.isWhitespace || $0.isPunctuation || $0.isSymbol }) else { return text }
        guard text[first].isUppercase else { return text }

        let rest = text[first...]
        let word = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" }))
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return text }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return text }
        let lowered = word.lowercased()
        if vocabulary.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowered }) {
            return text
        }

        var out = text
        out.replaceSubrange(first...first, with: String(text[first]).lowercased())
        return out
    }
}
