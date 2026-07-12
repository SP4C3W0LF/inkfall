import AppKit

// MARK: - Palette
//
// Inkfall design system. Functional state hues map to semantic system colors so
// they track dark mode, the user's accent, and Increase Contrast for free.
// Ember is the ONE bespoke brand color, spent only at trust moments.

enum InkfallDesign {
    /// The one bespoke brand color. Trust moments only. Adapts light/dark.
    static let ember = NSColor(name: NSColor.Name("InkfallEmber")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.949, green: 0.659, blue: 0.294, alpha: 1) // #F2A84B
            : NSColor(srgbRed: 0.878, green: 0.569, blue: 0.184, alpha: 1) // #E0912F
    }

    /// Fixed near-black ink used on top of ember fills (>= 4.8:1 in both appearances).
    static let emberInk = NSColor(srgbRed: 0.102, green: 0.071, blue: 0.020, alpha: 1) // #1A1205

    // Functional state hues — semantic system colors.
    static let blue = NSColor.systemBlue      // recording
    static let purple = NSColor.systemPurple  // transcribing / polishing
    static let green = NSColor.systemGreen    // success
    static let amber = NSColor.systemOrange   // caution / no-speech
    static let red = NSColor.systemRed        // failure
}

// MARK: - Motion tokens

enum InkfallMotion {
    static let fadeIn: TimeInterval = 0.20
    static let fadeOut: TimeInterval = 0.25
    static let settle: TimeInterval = 0.30
    static let dwell: TimeInterval = 1.8
}

// MARK: - Symbols

extension NSImage {
    /// An SF Symbol configured at a point size and weight. Falls back gracefully.
    static func flowSymbol(_ name: String, pointSize: CGFloat = 15, weight: NSFont.Weight = .semibold) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return image.withSymbolConfiguration(config) ?? image
    }
}

// MARK: - Accessibility state
//
// One observed object that gates the waveform, springs, scale-inhale, and the
// vibrancy fallback in a single place. Live-updates on system changes.

@MainActor
final class AccessibilityState {
    static let shared = AccessibilityState()

    private(set) var reduceMotion: Bool
    private(set) var reduceTransparency: Bool

    private init() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(optionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func optionsChanged() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
    }
}

// MARK: - Layout helpers

extension NSView {
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

// MARK: - Card
//
// A rounded, appearance-adaptive container. Used instead of NSBox, whose
// `contentView` replacement makes pinning to it self-referential (and collapses).

final class CardView: NSView {
    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
