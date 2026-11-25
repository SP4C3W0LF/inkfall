import AppKit
import ApplicationServices
import Carbon

/// What actually happened to the words. The HUD says only as much as is known:
/// "inserted" means the app confirmed the text is in the field, "pasted" means a
/// paste keystroke was sent and nothing could confirm it, and the "copied" cases
/// mean nothing was sent at all.
enum InsertionOutcome: Equatable {
    case inserted            // confirmed in the focused field (Accessibility)
    case pasted              // a paste keystroke was sent; not confirmable
    case copiedNoField       // a field is plainly not focused; text left on the clipboard
    case needsAccessibility  // Accessibility isn't granted; text left on the clipboard
    case copiedAppChanged    // the app in front is not the one spoken into; text left on the clipboard
    case nothingToInsert     // the cleaned text was empty
    case failed              // a paste keystroke could not even be created; text left on the clipboard
}

/// What could be read from the focused element at one moment.
struct FieldSnapshot: Equatable {
    var value: String?
    var selectedLocation: Int?
    var selectedLength: Int?

    /// With neither a value nor a caret there is nothing to compare afterwards.
    var isReadable: Bool { value != nil || selectedLocation != nil }
}

enum FocusedField: Equatable {
    case none                       // Accessibility exposed no focused element
    case element(role: String?)
}

/// Every decision the inserter makes, as plain values in and a verdict out. The
/// Accessibility and keystroke calls around it cannot run in a test; this can.
enum InsertionPolicy {
    enum Gate: Equatable {
        case proceed
        case nothing
        case copyAppChanged
        case needsAccessibility
    }

    /// Checked in this order: no words, a different app in front (never paste into
    /// the wrong place), no grant. Secure keyboard input is deliberately NOT a gate:
    /// it is global (Terminal's "Secure Keyboard Entry", or any app that left it
    /// on) and says nothing about the field being typed into.
    static func gate(
        text: String,
        accessibilityTrusted: Bool,
        expectedPID: pid_t?,
        frontmostPID: pid_t?
    ) -> Gate {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nothing }
        if let expectedPID, let frontmostPID, expectedPID != frontmostPID { return .copyAppChanged }
        if !accessibilityTrusted { return .needsAccessibility }
        return .proceed
    }

    /// A direct write is confirmed only when the field visibly took it: its value
    /// changed, or (value unchanged or unreadable) the caret sits right after the text.
    static func confirmsDirectInsert(before: FieldSnapshot?, after: FieldSnapshot?, text: String) -> Bool {
        guard let before, let after else { return false }
        if let oldValue = before.value, let newValue = after.value, oldValue != newValue {
            return true
        }
        guard let start = before.selectedLocation,
              let landed = after.selectedLocation,
              let afterLength = after.selectedLength else { return false }
        return landed == start + text.utf16.count && afterLength == 0
    }

    /// A paste keystroke is upgraded to "inserted" only when the value can be read
    /// before and after and it changed.
    static func confirmsPaste(before: FieldSnapshot?, after: FieldSnapshot?) -> Bool {
        guard let oldValue = before?.value, let newValue = after?.value else { return false }
        return oldValue != newValue
    }

    /// Roles that are plainly not somewhere text goes. Short on purpose: an
    /// unknown role is still tried, because web views and Electron apps report
    /// odd roles for perfectly good text fields.
    static func isClearlyNotEditable(role: String?) -> Bool {
        guard let role else { return false }
        return [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton",
            "AXMenuBarItem", "AXImage", "AXToolbar", "AXTabGroup", "AXSlider"
        ].contains(role)
    }
}

/// The system calls the inserter needs, behind a seam so the sequence around
/// them can be tested with a fake. The real one needs the running app.
@MainActor
protocol InsertionEnvironment {
    var isAccessibilityTrusted: Bool { get }
    var frontmostPID: pid_t? { get }
    func focusedField() -> FocusedField
    func snapshot() -> FieldSnapshot?
    /// Replaces the selection (or inserts at the caret) in the focused element.
    /// False when the attribute is not settable or the write was refused.
    func setSelectedText(_ text: String) -> Bool
    func sendPasteKeystroke() -> Bool
    func sleep(_ seconds: TimeInterval) async
}

@MainActor
final class TextInserter {
    /// Clipboard managers that follow nspasteboard.org skip items carrying these.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Whether any app currently holds secure keyboard input. Global, so it is only
    /// a hint (for a menu note), never a reason to refuse to insert.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    private let pasteboard: NSPasteboard
    private let environment: InsertionEnvironment

    init(pasteboard: NSPasteboard = .general, environment: InsertionEnvironment = SystemInsertionEnvironment()) {
        self.pasteboard = pasteboard
        self.environment = environment
    }

    /// `expectedAppPID` is the app that was in front when the user stopped
    /// speaking; if a different one is in front now the text is left on the
    /// clipboard instead of being pasted into the wrong place.
    func insert(_ text: String, expectedAppPID: pid_t? = nil) async -> InsertionOutcome {
        let gate = InsertionPolicy.gate(
            text: text,
            accessibilityTrusted: environment.isAccessibilityTrusted,
            expectedPID: expectedAppPID,
            frontmostPID: environment.frontmostPID
        )
        switch gate {
        case .nothing:
            return .nothingToInsert
        case .copyAppChanged:
            leaveOnClipboard(text)
            return .copiedAppChanged
        case .needsAccessibility:
            leaveOnClipboard(text)
            return .needsAccessibility
        case .proceed:
            break
        }

        let field = environment.focusedField()
        if case let .element(role) = field, InsertionPolicy.isClearlyNotEditable(role: role) {
            leaveOnClipboard(text)
            return .copiedNoField
        }

        // Preferred: write at the caret through Accessibility, which touches
        // neither the rest of the field nor the clipboard.
        if case .element = field, await insertDirectly(text) {
            return .inserted
        }

        // Fallback: ⌘V. The earlier clipboard is put back afterwards.
        let preserved = Self.snapshot(pasteboard)
        let ownChangeCount = putOnClipboardForPaste(text)
        let before = environment.snapshot()
        guard environment.sendPasteKeystroke() else {
            leaveOnClipboard(text)          // the words must stay reachable
            return field == .none ? .copiedNoField : .failed
        }
        await environment.sleep(Self.pasteSettle)
        let confirmed = InsertionPolicy.confirmsPaste(before: before, after: environment.snapshot())
        scheduleRestore(preserved, after: Self.restoreDelay - Self.pasteSettle, ifChangeCountIs: ownChangeCount)
        return confirmed ? .inserted : .pasted
    }

    private static let pasteSettle: TimeInterval = 0.15
    private static let restoreDelay: TimeInterval = 0.6

    private func insertDirectly(_ text: String) async -> Bool {
        let before = environment.snapshot()
        // With nothing readable a write could never be confirmed, and a write that
        // took effect unconfirmed would be pasted a second time. Paste instead.
        guard let before, before.isReadable else { return false }
        guard environment.setSelectedText(text) else { return false }
        // Some apps apply the write a moment later.
        for delay in [0.0, 0.05, 0.1] {
            if delay > 0 { await environment.sleep(delay) }
            if InsertionPolicy.confirmsDirectInsert(before: before, after: environment.snapshot(), text: text) {
                return true
            }
        }
        return false
    }

    // MARK: Clipboard

    /// Text left for the user to paste: plain, no markers, never restored over.
    private func leaveOnClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Text that exists on the clipboard only for the length of a paste: kept on
    /// this Mac and flagged so clipboard managers skip it.
    private func putOnClipboardForPaste(_ text: String) -> Int {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        pasteboard.setData(Data(), forType: Self.concealedType)
        return pasteboard.changeCount
    }

    /// A restorable copy of the current pasteboard. `NSPasteboardItem` is NOT
    /// `NSCopying`, so calling `.copy()` on one throws "unrecognized selector
    /// copyWithZone:". Rebuild fresh items carrying the same per-type data instead.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
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

    /// Puts the earlier contents back unless something else was copied since.
    /// Returns whether it restored.
    @discardableResult
    static func restore(_ items: [NSPasteboardItem], into pasteboard: NSPasteboard, ifChangeCountIs expected: Int) -> Bool {
        guard !items.isEmpty else { return false }
        // Don't clobber something the user copied during the insertion window.
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return true
    }

    private func scheduleRestore(_ items: [NSPasteboardItem], after delay: TimeInterval, ifChangeCountIs expected: Int) {
        guard !items.isEmpty else { return }
        let target = pasteboard
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            Self.restore(items, into: target, ifChangeCountIs: expected)
        }
    }
}

/// The real thing: Accessibility, Carbon's secure-input flag, posted key events.
/// Not verified by tests: needs the running app.
@MainActor
struct SystemInsertionEnvironment: InsertionEnvironment {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else {
            return nil
        }
        // kAXFocusedUIElementAttribute always yields an AXUIElement on success;
        // use a checked cast anyway so a contract violation fails safe, not crashes.
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        return (focusedElement as! AXUIElement)
    }

    func focusedField() -> FocusedField {
        guard let element = focusedElement() else { return .none }
        var role: CFTypeRef?
        let text = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            ? role as? String : nil
        return .element(role: text)
    }

    func snapshot() -> FieldSnapshot? {
        guard let element = focusedElement() else { return nil }
        var snapshot = FieldSnapshot()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            snapshot.value = value as? String
        }
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) {
                snapshot.selectedLocation = range.location
                snapshot.selectedLength = range.length
            }
        }
        return snapshot
    }

    func setSelectedText(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func sendPasteKeystroke() -> Bool {
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

    func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
