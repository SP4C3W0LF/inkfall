import AppKit
import ApplicationServices

enum InsertionOutcome {
    case inserted            // placed into the focused field
    case copiedNoField       // trusted, but no editable field was focused; on clipboard
    case needsAccessibility  // Accessibility isn't granted; text on clipboard
    case failed              // insertion failed; text on clipboard
}

@MainActor
final class TextInserter {
    /// Clipboard-first: the transcript is on the pasteboard BEFORE any insertion
    /// attempt, so a failure degrades to "Copied — paste with ⌘V" and the words are
    /// never lost. Primary insertion sets the focused element's accessibility value;
    /// a synthesized ⌘V is only a fallback when that fails.
    func insert(_ text: String) -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let preserved = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownChangeCount = pasteboard.changeCount

        switch attemptAccessibilityInsert(text) {
        case .inserted:
            restore(preserved, after: 0.4, ifChangeCountIs: ownChangeCount)
            return .inserted
        case .notTrusted:
            return .needsAccessibility
        case let axResult:
            // Trusted, but the accessibility set-value couldn't run — either AX exposed
            // no readable focused field (.noField), or setting the value failed
            // (.failed). A synthesized ⌘V still lands in whatever app is focused, so try
            // that before giving up.
            if sendPasteKeystroke() {
                restore(preserved, after: 0.6, ifChangeCountIs: ownChangeCount)
                return .inserted
            }
            return axResult == .noField ? .copiedNoField : .failed
        }
    }

    private enum AXResult { case inserted, noField, notTrusted, failed }

    private func attemptAccessibilityInsert(_ text: String) -> AXResult {
        guard AXIsProcessTrusted() else { return .notTrusted }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else {
            return .noField
        }

        // kAXFocusedUIElementAttribute always yields an AXUIElement on success;
        // use a checked cast anyway so a contract violation fails safe, not crashes.
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return .noField }
        let element = focusedElement as! AXUIElement

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let current = value as? String else {
            return .noField
        }

        var selectedRangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
           let rangeValue = selectedRangeValue,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                let nsRange = NSRange(location: range.location, length: range.length)
                if let swiftRange = Range(nsRange, in: current) {
                    let updated = current.replacingCharacters(in: swiftRange, with: text)
                    let ok = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString) == .success
                    return ok ? .inserted : .failed
                }
            }
        }

        let updated = current + text
        let ok = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString) == .success
        return ok ? .inserted : .failed
    }

    /// A restorable copy of the current pasteboard. `NSPasteboardItem` is NOT
    /// `NSCopying`, so calling `.copy()` on one throws "unrecognized selector
    /// copyWithZone:". Rebuild fresh items carrying the same per-type data instead.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], after delay: TimeInterval, ifChangeCountIs expected: Int) {
        guard !items.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            // Don't clobber something the user copied during the insertion window.
            guard pasteboard.changeCount == expected else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
    }

    @discardableResult
    private func sendPasteKeystroke() -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
