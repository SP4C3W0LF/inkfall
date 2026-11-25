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

    /// Builds a combo from values read out of the settings file. Nil when a value is
    /// out of range (a negative or huge number typed by hand), so the caller can use
    /// the default instead of trapping on a conversion.
    static func validated(code: Int, modifiers: Int, display: String) -> KeyCombo? {
        let allowedModifiers = cmdKey | optionKey | controlKey | shiftKey
        guard (0...255).contains(code),
              modifiers > 0, modifiers & ~allowedModifiers == 0,
              !display.isEmpty else { return nil }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers), display: display)
    }

    /// Why a recorded combo is a bad global shortcut, or nil if it is fine. Option plus
    /// a character key alone would stop that key typing its character in every app
    /// (⌥Space and function keys are allowed).
    static func riskReason(keyCode: UInt32, carbonModifiers: UInt32) -> String? {
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let mods = carbonModifiers & mask
        guard mods == UInt32(optionKey) else { return nil }
        if keyCode == UInt32(kVK_Space) || functionKeyCodes.contains(Int(keyCode)) { return nil }
        if nonCharacterKeyCodes.contains(Int(keyCode)) { return nil }
        return "Option with a character key would stop that key typing. Add ⌘ or ⌃."
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]
    /// Keys that type nothing visible, so Option on them costs the user nothing.
    private static let nonCharacterKeyCodes: Set<Int> = [
        kVK_Return, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
        kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
    ]

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

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
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
        guard recording else {
            // Keyboard-only users start recording with Space or Return (a click did it before).
            let code = Int(event.keyCode)
            if code == kVK_Space || code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                recording = true
                return
            }
            super.keyDown(with: event)
            return
        }
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

    // Switching to another app (or anything else that makes the window lose key)
    // does NOT resign the first responder, so without this the field would keep
    // saying "Type a shortcut…" and the global hotkey would stay suspended while
    // the user works elsewhere. Closing the window is already covered by
    // SettingsWindowController.windowWillClose.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    // Notification target: nonisolated + an explicit hop, like the actions in AppDelegate.
    @objc nonisolated private func windowDidResignKey() {
        Task { @MainActor in
            if self.recording { self.recording = false }
        }
    }

    private func updateAppearance() {
        label.stringValue = recording ? "Type a shortcut…" : combo.display
        setAccessibilityLabel(recording
            ? "Shortcut, recording. Press the new shortcut, or Escape to cancel."
            : "Shortcut, \(combo.display). Press Space to record a new one.")
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        let border: NSColor = recording
            ? InkfallDesign.ember
            : (hasWarning ? InkfallDesign.amber : NSColor.separatorColor)
        layer?.borderColor = border.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
