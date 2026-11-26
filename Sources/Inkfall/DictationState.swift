import AppKit
import Carbon

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
    /// A paste keystroke was sent but nothing could confirm it landed.
    case pasted(peek: String)
    /// The app in front changed after speaking; the text was left on the clipboard.
    case copiedAppChanged(peek: String)
    case noSpeech
    case micError(String)
    case transcribeError(String)
    case insertionFailed(peek: String)
    case downloadFailed(String)
    /// A model the user asked for (in Settings) finished downloading.
    case modelReady(name: String)

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
    /// Cancel while transcribing or polishing (offered once the wait gets long).
    case cancelWork
    /// The small close button on a message that stays up until dealt with.
    case dismiss
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

    /// A message that stays up gets a close button, unless it is a download: that one
    /// has Cancel, and two ways out of the same card would be confusing.
    var dismissible: Bool { persistent && action != .cancelDownload }
}

extension DictationState {
    /// The HUD model for this state, or nil when no overlay should show.
    var hud: HUDModel? { hud(workIsSlow: false) }

    /// `workIsSlow` is true once transcribing or polishing has gone on for a while: the
    /// card then says so and offers Cancel (until then it stays click-through).
    func hud(workIsSlow: Bool) -> HUDModel? {
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
                accessory: progress > 0 ? .progress(progress) : .ellipsis,
                actionLabel: "Cancel", action: .cancelDownload, persistent: true)

        case .listening:
            return HUDModel(
                symbol: "mic.fill", tint: InkfallDesign.blue,
                title: "Listening…",
                detail: TriggerWording.current.stopHint(shortcut: HotkeyDisplay.current),
                accessory: .waveform(flat: false), showsLocalPill: true, informational: true)

        case .silence:
            return HUDModel(
                symbol: "mic.fill", tint: InkfallDesign.blue,
                title: "Listening…", detail: "Not hearing you — is the right mic selected?",
                accessory: .waveform(flat: true), showsLocalPill: true, informational: true)

        case .transcribing:
            if workIsSlow {
                return HUDModel(
                    symbol: "waveform", tint: InkfallDesign.purple,
                    title: "Transcribing…", detail: "Taking longer than usual.",
                    accessory: .ellipsis, actionLabel: "Cancel", action: .cancelWork)
            }
            return HUDModel(
                symbol: "waveform", tint: InkfallDesign.purple,
                title: "Transcribing…", detail: "Turning your words into text, right here.",
                accessory: .ellipsis, informational: true)

        case .polishing:
            if workIsSlow {
                return HUDModel(
                    symbol: "sparkles", tint: InkfallDesign.purple,
                    title: "Polishing…", detail: "Taking longer than usual.",
                    accessory: .ellipsis, actionLabel: "Cancel", action: .cancelWork)
            }
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

        case let .pasted(peek):
            // The paste keystroke went out and nothing could confirm it. That is the
            // normal case in browsers and Electron apps, so the card shows the words
            // like "Inserted" does, under a different title, and offers the copy.
            return HUDModel(
                symbol: "doc.on.clipboard", tint: InkfallDesign.green,
                title: "Pasted", detail: "“\(peek)”", isPeek: true,
                actionLabel: "Copy again", action: .copyAgain)

        case .copiedAppChanged:
            return HUDModel(
                symbol: "doc.on.clipboard", tint: InkfallDesign.amber,
                title: "Copied it for you",
                detail: "You switched apps — paste with ⌘V where you want it.",
                actionLabel: "Copy again", action: .copyAgain)

        case .noSpeech:
            return HUDModel(
                symbol: "ear.badge.waveform", tint: InkfallDesign.amber,
                title: "Didn't catch that",
                detail: TriggerWording.current.retryHint(shortcut: HotkeyDisplay.current))

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

        case let .modelReady(name):
            return HUDModel(
                symbol: "checkmark.circle.fill", tint: InkfallDesign.green,
                title: "Speech model ready", detail: "\(name) is on your Mac.")
        }
    }

    // MARK: Menu presentation

    /// Name of the custom idle glyph (Resources/Assets.xcassets/MenuBarGlyph). The menu bar resolves
    /// it to the asset, or to the `waveform` SF Symbol when the catalog is not bundled (`swift run`).
    static let idleMenuGlyph = "MenuBarGlyph"

    /// Monochrome template image name for the menu bar. State by swap: the idle state is the Inkfall
    /// glyph, the transient and attention states stay SF Symbols.
    var menuGlyph: String {
        switch self {
        case .listening, .silence:
            return "mic.fill"
        case .transcribing, .polishing, .inserting:
            return "ellipsis"
        case .needsMicrophone, .needsAccessibility, .readyNoAccessibility, .needsModel, .downloadFailed:
            return "waveform.badge.exclamationmark"
        default:
            return DictationState.idleMenuGlyph
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
        case let .pasted(peek): return "Pasted “\(peek.prefix(28))”"
        case .copiedAppChanged: return "Copied to clipboard — you switched apps"
        case .noSpeech: return "Didn't catch that"
        case .micError: return "Microphone unavailable"
        case .transcribeError: return "Couldn't transcribe that"
        case .insertionFailed: return "Copied to clipboard — paste with ⌘V"
        case .downloadFailed: return "Download didn't finish"
        case .modelReady: return "Speech model ready"
        }
    }
}

// MARK: - Wording that depends on how dictation is started

/// How the user starts a dictation right now, so the menu, the HUD and the "didn't
/// catch that" text name the real trigger. Set by the app delegate whenever the mode,
/// the shortcut or the Accessibility grant changes; read on the main thread only.
enum TriggerWording: Equatable, Sendable {
    /// Press the shortcut to start and again to stop.
    case tap
    /// Hold mode with Accessibility: the left Option key alone.
    case holdOption
    /// Hold mode without Accessibility: hold the regular shortcut.
    case holdShortcut

    nonisolated(unsafe) static var current: TriggerWording = .tap

    static func resolve(mode: DictationMode, holdMonitorActive: Bool) -> TriggerWording {
        switch mode {
        case .tap: return .tap
        case .hold: return holdMonitorActive ? .holdOption : .holdShortcut
        }
    }

    func menuLine(shortcut: String) -> String {
        switch self {
        case .tap: return "Shortcut: \(shortcut)"
        case .holdOption: return "Shortcut: hold left Option"
        case .holdShortcut: return "Shortcut: hold \(shortcut)"
        }
    }

    func stopHint(shortcut: String) -> String {
        switch self {
        case .tap: return "\(shortcut) to stop"
        case .holdOption: return "Release Option to stop"
        case .holdShortcut: return "Release \(shortcut) to stop"
        }
    }

    func retryHint(shortcut: String) -> String {
        switch self {
        case .tap: return "Press \(shortcut) to try again."
        case .holdOption: return "Hold Option to try again."
        case .holdShortcut: return "Hold \(shortcut) to try again."
        }
    }
}

// MARK: - Download wording

enum DownloadText {
    /// The detail line while a model downloads. `fraction` is the library's progress
    /// for the model files (0...1) or nil before the first report. Reaching 1.0 is not
    /// the end: the tokenizer is fetched and the model loaded after it, so the card
    /// stays up and says what is left.
    static func detail(fraction: Double?) -> String {
        guard let fraction else { return "Starting the download…" }
        if fraction >= 1 { return "Getting it ready…" }
        return "Downloading… \(percent(fraction))%"
    }

    static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }
}

// MARK: - Shortcut registration

enum ShortcutProblem {
    /// The menu line for a shortcut the system would not register, or nil when it did.
    static func line(status: OSStatus, shortcut: String) -> String? {
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return "Shortcut \(shortcut) is in use by another app"
        default: return "Shortcut \(shortcut) isn't working"
        }
    }
}

// MARK: - VoiceOver

enum Announcement {
    /// What to say aloud when the state changes, or nil to stay quiet: states with no
    /// HUD say nothing, and so does a change that keeps the same card (listening to
    /// silence, a download's progress ticking). A message the user has to act on is
    /// read with its detail; the user's own words are never read out.
    static func text(from old: DictationState, to new: DictationState) -> String? {
        guard let model = new.hud else { return nil }
        if old.isRecording && new.isRecording { return nil }
        if old.hud?.title == model.title { return nil }
        if model.isPeek || model.informational || model.detail.isEmpty { return model.title }
        return "\(model.title). \(model.detail)"
    }
}

// MARK: - Accessibility grant watch

/// The 2-second timer in the app delegate runs only while Accessibility is missing.
/// This is its decision: what to do with the answer it just got.
struct AccessibilityGrantWatch: Equatable {
    enum Step: Equatable {
        case keepWatching
        /// Just granted: re-check everything and stop the timer.
        case granted
    }

    static func step(trusted: Bool) -> Step { trusted ? .granted : .keepWatching }
    static func shouldWatch(trusted: Bool) -> Bool { !trusted }
}

// MARK: - Model download decisions

enum ModelDownloadPolicy {
    /// Settings just saved a configuration. Start the visible download when the user
    /// asked for a WhisperKit model that is not on disk: a different model or engine
    /// than before (a save that changes something else does not restart it), and not
    /// while onboarding is open, which downloads on its own screen.
    static func shouldStartOnSave(
        oldEngine: SpeechEngine, oldModel: String,
        newEngine: SpeechEngine, newModel: String,
        isOnDisk: Bool, onboardingOpen: Bool
    ) -> Bool {
        guard newEngine == .whisperKit, !isOnDisk, !onboardingOpen else { return false }
        return oldEngine != .whisperKit || oldModel != newModel
    }
}

// MARK: - Status menu

enum MenuFix: Equatable {
    case grantMicrophone
    case openAccessibility
    case setUpModel
}

enum StatusMenuEntry: Equatable {
    case cancel
    case toggle(title: String)
    /// A disabled line of plain text.
    case info(String)
    case copyLast(enabled: Bool)
    case copyOriginal(enabled: Bool)
    case chooseShortcut
    case fix(MenuFix)
    /// "Check for Updates…", or the update a scheduled check found.
    case updates(title: String)
    case settings
    case quit
    case separator
}

struct StatusMenuInput {
    var state: DictationState
    var canCancel: Bool
    var hasLastResult: Bool
    var hasOriginalTranscript: Bool
    var trigger: TriggerWording
    var shortcut: String
    var shortcutProblem: String?
    var secureInputOn: Bool
    var microphoneAuthorized: Bool
    var accessibilityTrusted: Bool
    var hasSpeechModel: Bool
    /// The settings file could not be read at launch (see `InkfallConfig.loadProblem`).
    var settingsProblem: String? = nil
    /// See `UpdateService`. A copy that cannot update itself shows no update item.
    var updates: UpdateMenuState = .unavailable
}

enum StatusMenuPlan {
    static let secureInputLine = "Secure input is on: the shortcut may not respond"

    /// What the status menu holds, in order. The app delegate turns each entry into a
    /// menu item; the choices live here so they can be tested.
    static func entries(_ input: StatusMenuInput) -> [StatusMenuEntry] {
        var items: [StatusMenuEntry] = []
        if input.canCancel { items.append(.cancel) }
        items.append(.toggle(title: input.state.isRecording ? "Stop Dictation" : "Start Dictation"))
        items.append(.info(input.state.statusLine))
        items.append(.info(input.shortcutProblem ?? input.trigger.menuLine(shortcut: input.shortcut)))
        if input.secureInputOn { items.append(.info(secureInputLine)) }
        if let problem = input.settingsProblem { items.append(.info(problem)) }
        items.append(.separator)
        items.append(.copyLast(enabled: input.hasLastResult))
        items.append(.copyOriginal(enabled: input.hasOriginalTranscript))

        var fixes: [StatusMenuEntry] = []
        if input.shortcutProblem != nil { fixes.append(.chooseShortcut) }
        if !input.microphoneAuthorized { fixes.append(.fix(.grantMicrophone)) }
        if !input.accessibilityTrusted { fixes.append(.fix(.openAccessibility)) }
        if !input.hasSpeechModel { fixes.append(.fix(.setUpModel)) }
        if !fixes.isEmpty {
            items.append(.separator)
            items.append(contentsOf: fixes)
        }
        items.append(.separator)
        if let title = input.updates.menuTitle { items.append(.updates(title: title)) }
        items.append(.settings)
        items.append(.quit)
        return items
    }

    static func title(for fix: MenuFix) -> String {
        switch fix {
        case .grantMicrophone: return "Grant Microphone…"
        case .openAccessibility: return "Open Accessibility Settings"
        case .setUpModel: return "Set Up Speech Model…"
        }
    }
}
