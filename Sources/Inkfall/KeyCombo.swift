import AppKit
import Carbon.HIToolbox

/// The current global shortcut's display string, read by the HUD, menu, and
/// onboarding copy so they all show whatever the user has bound. Mutated only on
/// the main thread when the configuration changes.
enum HotkeyDisplay {
    nonisolated(unsafe) static var current: String = KeyCombo.defaultCombo.display
}

/// A global hotkey combination: a virtual key code plus Carbon modifier flags,
/// with a cached display string (⌥Space, ⌘⇧D, …).
struct KeyCombo: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let defaultCombo = KeyCombo(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        display: "⌥Space"
    )

    /// Builds a combo from a recorded key event. Returns nil unless a command,
    /// option, or control modifier is held — a bare key is a poor global hotkey.
    @MainActor
    static func from(event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasPrimaryModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        guard hasPrimaryModifier else { return nil }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        let display = modifierSymbols(flags) + keyName(for: event)
        return KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: display)
    }

    /// True if this combo matches an *enabled* macOS system shortcut (Spotlight,
    /// screenshots, Mission Control, …), which the OS would intercept first.
    static func isSystemReserved(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let targetMods = carbonModifiers & mask

        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else {
                continue
            }
            if UInt32(truncatingIfNeeded: code) == keyCode,
               (UInt32(truncatingIfNeeded: mods) & mask) == targetMods {
                return true
            }
        }
        return false
    }

    private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        if let chars = event.charactersIgnoringModifiers, let first = chars.first, !first.isWhitespace {
            return String(first).uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_ANSI_KeypadEnter: "Enter",
        kVK_Tab: "Tab",
        kVK_Escape: "Esc",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
}

/// A click-to-record shortcut field. Click it, press a modifier + key, and it
/// captures the combo. Esc cancels. Requires a command/option/control modifier.
@MainActor
final class KeyRecorderField: NSView {
    var onChange: ((KeyCombo) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var combo: KeyCombo
    private let label = NSTextField(labelWithString: "")
    private var recording = false {
        didSet {
            updateAppearance()
            onRecordingChange?(recording)
        }
    }

    /// Set by the owner to flag a system-shortcut conflict (amber border).
    var hasWarning = false { didSet { updateAppearance() } }

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCombo(_ combo: KeyCombo) {
        self.combo = combo
        updateAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    /// Records a captured event. Returns true if it was consumed.
    private func capture(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_Escape {
            endRecording()
            return true
        }
        if let combo = KeyCombo.from(event: event) {
            self.combo = combo
            onChange?(combo)
            endRecording()
            return true
        }
        return false
    }

    private func endRecording() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        // Swallow even an invalid (modifier-less) press so there's no system beep.
        _ = capture(event)
    }

    // ⌘-based combos arrive as key equivalents *before* keyDown. The key window's
    // view hierarchy is offered performKeyEquivalent before the main menu, so
    // intercepting here lets shortcuts like ⌘Q be recorded instead of quitting.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        _ = capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }

    private func updateAppearance() {
        label.stringValue = recording ? "Type a shortcut…" : combo.display
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        let border: NSColor = recording
            ? InkfallDesign.ember
            : (hasWarning ? InkfallDesign.amber : NSColor.separatorColor)
        layer?.borderColor = border.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
