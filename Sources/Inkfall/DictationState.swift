import AppKit

// MARK: - The single source of truth
//
// One typed state machine drives the HUD, the menu-bar glyph, the menu status
// line, and Settings. Nothing derives UI by string-matching user-facing text.

enum DictationState: Equatable {
    case idle
    case needsMicrophone
    case needsAccessibility
    /// Resting state: dictation works, but without Accessibility results land on
    /// the clipboard instead of being typed into the active app.
    case readyNoAccessibility
    case needsModel
    case downloading(progress: Double, detail: String)
    case listening
    case silence
    case transcribing
    case polishing
    case inserting
    /// `copiedOnly` means there was no editable field — text is safe on the clipboard.
    case success(peek: String, copiedOnly: Bool)
    case noSpeech
    case micError(String)
    case transcribeError(String)
    case insertionFailed(peek: String)
    case downloadFailed(String)

    var isRecording: Bool {
        self == .listening || self == .silence
    }
}

// MARK: - HUD presentation

enum HUDAccessory: Equatable {
    case none
    case waveform(flat: Bool)
    case ellipsis
    case progress(Double)
}

enum HUDAction: Equatable {
    case grantMicrophone
    case openAccessibility
    case setUpModel
    case openSoundSettings
    case retry
    case copyAgain
    case cancelDownload
}

struct HUDModel {
    var symbol: String
    var tint: NSColor
    var title: String
    var detail: String
    var isPeek: Bool = false
    var accessory: HUDAccessory = .none
    var showsLocalPill: Bool = false
    var actionLabel: String?
    var action: HUDAction?
    var emberAction: Bool = false
    var persistent: Bool = false
    /// Informational states ignore mouse events so they never steal the paste target.
    var informational: Bool = false
}

extension DictationState {
    /// The HUD model for this state, or nil when no overlay should show.
    var hud: HUDModel? {
        switch self {
        case .idle, .readyNoAccessibility:
            return nil

        case .needsMicrophone:
            return HUDModel(
                symbol: "mic.badge.xmark", tint: InkfallDesign.ember,
                title: "Microphone access needed",
                detail: "I need the mic to hear you — the audio never leaves your Mac.",
                actionLabel: "Grant Access", action: .grantMicrophone,
                emberAction: true, persistent: true)

        case .needsAccessibility:
            return HUDModel(
                symbol: "hand.raised.fill", tint: InkfallDesign.ember,
                title: "One more permission to type",
                detail: "Your words are on the clipboard — paste with ⌘V. Accessibility lets me type them in next time.",
                actionLabel: "Open Accessibility Settings", action: .openAccessibility,
                emberAction: true, persistent: true)

        case .needsModel:
            return HUDModel(
                symbol: "arrow.down.circle", tint: InkfallDesign.ember,
                title: "Let's finish setting up",
                detail: "Add a speech model and we're ready to go.",
                actionLabel: "Set Up Speech Model", action: .setUpModel,
                emberAction: true, persistent: true)

        case let .downloading(progress, detail):
            return HUDModel(
                symbol: "arrow.down.circle", tint: InkfallDesign.ember,
                title: "Downloading speech model", detail: detail,
                accessory: .progress(progress),
                actionLabel: "Cancel", action: .cancelDownload, persistent: true)

        case .listening:
            return HUDModel(
                symbol: "mic.fill", tint: InkfallDesign.blue,
                title: "Listening…", detail: "\(HotkeyDisplay.current) to stop",
                accessory: .waveform(flat: false), showsLocalPill: true, informational: true)

        case .silence:
            return HUDModel(
                symbol: "mic.fill", tint: InkfallDesign.blue,
                title: "Listening…", detail: "Not hearing you — is the right mic selected?",
                accessory: .waveform(flat: true), showsLocalPill: true, informational: true)

        case .transcribing:
            return HUDModel(
                symbol: "waveform", tint: InkfallDesign.purple,
                title: "Transcribing…", detail: "Turning your words into text, right here.",
                accessory: .ellipsis, informational: true)

        case .polishing:
            return HUDModel(
                symbol: "sparkles", tint: InkfallDesign.purple,
                title: "Polishing…", detail: "Tidying grammar and dropping filler.",
                accessory: .ellipsis, informational: true)

        case .inserting:
            return HUDModel(
                symbol: "text.cursor", tint: InkfallDesign.purple,
                title: "Placing it in…", detail: "", informational: true)

        case let .success(peek, copiedOnly):
            if copiedOnly {
                return HUDModel(
                    symbol: "doc.on.clipboard", tint: InkfallDesign.green,
                    title: "Copied it for you",
                    detail: "No text field was focused — paste with ⌘V.",
                    actionLabel: "Copy again", action: .copyAgain)
            }
            return HUDModel(
                symbol: "checkmark.circle.fill", tint: InkfallDesign.green,
                title: "Inserted", detail: "“\(peek)”", isPeek: true, showsLocalPill: true)

        case .noSpeech:
            return HUDModel(
                symbol: "ear.badge.waveform", tint: InkfallDesign.amber,
                title: "Didn't catch that", detail: "Press \(HotkeyDisplay.current) to try again.")

        case let .micError(message):
            return HUDModel(
                symbol: "mic.slash.fill", tint: InkfallDesign.red,
                title: "Microphone unavailable", detail: message,
                actionLabel: "Open Sound Settings", action: .openSoundSettings, persistent: true)

        case let .transcribeError(message):
            return HUDModel(
                symbol: "exclamationmark.circle.fill", tint: InkfallDesign.red,
                title: "Couldn't transcribe that", detail: message,
                actionLabel: "Retry", action: .retry, persistent: true)

        case .insertionFailed:
            // The transcript is already on the clipboard (clipboard-first), so this
            // is a reassurance, not data loss.
            return HUDModel(
                symbol: "doc.on.clipboard", tint: InkfallDesign.red,
                title: "Couldn't type it in", detail: "Copied to clipboard — paste with ⌘V.",
                actionLabel: "Copy again", action: .copyAgain, persistent: true)

        case let .downloadFailed(message):
            return HUDModel(
                symbol: "arrow.down.circle", tint: InkfallDesign.ember,
                title: "Download didn't finish", detail: message,
                actionLabel: "Retry", action: .retry, persistent: true)
        }
    }

    // MARK: Menu presentation

    /// Monochrome template SF Symbol for the menu bar. State by symbol swap.
    var menuGlyph: String {
        switch self {
        case .listening, .silence:
            return "mic.fill"
        case .transcribing, .polishing, .inserting:
            return "ellipsis"
        case .needsMicrophone, .needsAccessibility, .readyNoAccessibility, .needsModel, .downloadFailed:
            return "waveform.badge.exclamationmark"
        default:
            return "waveform"
        }
    }

    /// The one authoritative status line, in plain words, for the menu.
    var statusLine: String {
        switch self {
        case .idle: return "Ready"
        case .needsMicrophone: return "Microphone access needed"
        case .needsAccessibility: return "Accessibility access needed"
        case .readyNoAccessibility: return "Ready — grant Accessibility to type into apps"
        case .needsModel: return "Add a speech model to start"
        case .downloading: return "Downloading speech model…"
        case .listening, .silence: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        case .inserting: return "Placing it in…"
        case let .success(peek, copiedOnly):
            return copiedOnly ? "Copied to clipboard" : "Inserted “\(peek.prefix(28))”"
        case .noSpeech: return "Didn't catch that"
        case .micError: return "Microphone unavailable"
        case .transcribeError: return "Couldn't transcribe that"
        case .insertionFailed: return "Copied to clipboard — paste with ⌘V"
        case .downloadFailed: return "Download didn't finish"
        }
    }
}
