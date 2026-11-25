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
            ? InkfallPalette.emberDark.nsColor // #F2A84B
            : InkfallPalette.emberLight.nsColor // #E0912F
    }

    /// Ember as TEXT. The fill ember is only about 2.3:1 on a light window, so light mode
    /// gets a darker amber; dark mode keeps the bright one (about 7:1 on dark).
    static let emberText = adaptive(light: InkfallPalette.emberTextLight, dark: InkfallPalette.emberDark, name: "InkfallEmberText")

    /// Status text (chips and the Settings footer): readable on the tinted chip in both appearances.
    static let statusGreenText = adaptive(light: InkfallPalette.greenTextLight, dark: InkfallPalette.greenTextDark, name: "InkfallStatusGreen")
    static let statusAmberText = adaptive(light: InkfallPalette.amberTextLight, dark: InkfallPalette.amberTextDark, name: "InkfallStatusAmber")
    static let statusRedText = adaptive(light: InkfallPalette.redTextLight, dark: InkfallPalette.redTextDark, name: "InkfallStatusRed")

    private static func adaptive(light: RGB, dark: RGB, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor
        }
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

// MARK: - Literal colours and contrast
//
// Every literal text colour lives here as plain numbers so a test can measure it.

struct RGB: Equatable, Sendable {
    let red: Double, green: Double, blue: Double
    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

enum Contrast {
    /// WCAG relative luminance.
    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    /// WCAG contrast ratio, 1...21, the same whichever colour is passed first.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` at `alpha` laid over `bg` (a tinted chip background).
    static func composite(_ fg: RGB, over bg: RGB, alpha: Double) -> RGB {
        RGB(red: fg.red * alpha + bg.red * (1 - alpha),
            green: fg.green * alpha + bg.green * (1 - alpha),
            blue: fg.blue * alpha + bg.blue * (1 - alpha))
    }
}

enum InkfallPalette {
    static let emberLight = RGB(hex: 0xE0912F)
    static let emberDark = RGB(hex: 0xF2A84B)
    static let emberTextLight = RGB(hex: 0x8A5200)

    static let greenTextLight = RGB(hex: 0x0A6A1F)
    static let greenTextDark = RGB(hex: 0x32D74B)
    static let amberTextLight = RGB(hex: 0x7A4A00)
    static let amberTextDark = RGB(hex: 0xFF9F0A)
    static let redTextLight = RGB(hex: 0xB0221A)
    static let redTextDark = RGB(hex: 0xFF8F87)

    // The tints behind status chips (macOS system colours, approximate sRGB).
    static let greenTintLight = RGB(hex: 0x28CD41), greenTintDark = RGB(hex: 0x32D74B)
    static let amberTintLight = RGB(hex: 0xFF9500), amberTintDark = RGB(hex: 0xFF9F0A)
    static let redTintLight = RGB(hex: 0xFF3B30), redTintDark = RGB(hex: 0xFF453A)
    static let chipTintAlpha = 0.14

    // Backgrounds the text can land on (approximate: the system picks the exact values).
    static let lightBackgrounds = [RGB(hex: 0xFFFFFF), RGB(hex: 0xECECEC)]
    static let darkBackgrounds = [RGB(hex: 0x1E1E1E), RGB(hex: 0x2C2C2C)]
}

// MARK: - Motion tokens

enum InkfallMotion {
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
