import AppKit

/// Hold-to-talk on a BARE MODIFIER — hold left Option, speak, let go.
///
/// Carbon's `RegisterEventHotKey` cannot express this: it demands a virtual key
/// code, so the closest it gets is ⌥Space. A modifier alone has to be read from
/// the event stream instead, which is what `NSEvent`'s `.flagsChanged` monitors
/// do. That needs the Accessibility grant — already required here, since typing
/// dictated text into another app is the whole point of `TextInserter`.
///
/// Passive by design: a global `NSEvent` monitor observes, it cannot consume. So
/// Option still reaches the frontmost app. That is the right trade — swallowing
/// it would need a `CGEventTap`, and an app that eats a modifier system-wide is a
/// much bigger promise than one that listens for it.
/// The rules of a hold, as events in and a decision out, so they can be tested
/// without a keyboard. Option first ARMS (nothing starts, so a tap or an ⌥-click
/// never opens the mic); if it is still down alone when the arm delay passes the
/// recording begins; after that the hold is either confirmed (Option released
/// after a real hold) or abandoned (the recording is thrown away) when Option
/// turns out to be part of something else.
struct HoldMachine {
    enum Input: Equatable {
        /// Left Option / other-modifier state at a flagsChanged event.
        case modifiers(leftOption: Bool, otherModifier: Bool, at: TimeInterval)
        case keyDown
        case mouseDown
        /// The monitor's arm timer fired.
        case armElapsed
    }

    enum Decision: Equatable {
        case none
        case startArmTimer  // the monitor starts its arm-delay timer
        case begin          // start recording now
        case end            // a real hold finished: transcribe
        case discard        // abandoned after recording began: drop it, transcribe nothing
    }

    /// How long Option must be held alone before capture starts.
    static let armDelay: TimeInterval = 0.2
    /// A release sooner than this (measured from Option going down) was a tap, not a hold.
    static let minimumHold: TimeInterval = 0.25

    private enum Phase: Equatable {
        case idle
        case arming(since: TimeInterval)
        case holding(since: TimeInterval)
        /// Option is down as part of something else; ignore everything until it is released.
        case blocked
    }

    private var phase: Phase = .idle

    var isArming: Bool {
        if case .arming = phase { return true }
        return false
    }

    var isHolding: Bool {
        if case .holding = phase { return true }
        return false
    }

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case let .modifiers(leftOption, otherModifier, time):
            switch phase {
            case .idle:
                guard leftOption else { return .none }
                if otherModifier {
                    // ⌥⌘ anything: a shortcut, not a hold. Stay out even if ⌘ is let go first.
                    phase = .blocked
                    return .none
                }
                phase = .arming(since: time)
                return .startArmTimer
            case .arming:
                // Nothing has started, so there is nothing to discard.
                if !leftOption { phase = .idle }
                else if otherModifier { phase = .blocked }
                return .none
            case let .holding(since):
                if !leftOption {
                    phase = .idle
                    return time - since < Self.minimumHold ? .discard : .end
                }
                if otherModifier {
                    phase = .blocked
                    return .discard
                }
                return .none
            case .blocked:
                if !leftOption { phase = .idle }
                return .none
            }
        case .keyDown, .mouseDown:
            switch phase {
            case .arming:
                phase = .blocked
                return .none
            case .holding:
                phase = .blocked
                return .discard
            case .idle, .blocked:
                return .none
            }
        case .armElapsed:
            // A stale timer in any other phase does nothing.
            guard case let .arming(since) = phase else { return .none }
            phase = .holding(since: since)
            return .begin
        }
    }

    /// The monitor is being stopped. A hold in progress ends (is transcribed)
    /// rather than leaving the mic open; an arm in progress just ends.
    mutating func stop() -> Decision {
        let wasHolding = isHolding
        phase = .idle
        return wasHolding ? .end : .none
    }
}

@MainActor
final class ModifierHoldMonitor {
    /// Left Option specifically, so the right one stays free for typing accented
    /// characters. These are the device-DEPENDENT masks: `NSEvent.ModifierFlags`
    /// only tells you "some Option key", and `.deviceIndependentFlagsMask`
    /// deliberately throws the side away.
    private static let leftOptionMask: UInt = 0x0000_0020    // NX_DEVICELALTKEYMASK

    /// Modifiers that mean this is a shortcut, not a hold. Without this, reaching
    /// for ⌥⌘ anything would start dictating on the way.
    private static let disqualifying: NSEvent.ModifierFlags = [.command, .control, .shift]

    /// Everything that can turn a hold into something else: keys, clicks, and the
    /// modifier changes themselves.
    private static let watched: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var machine = HoldMachine()
    private var armTimer: Timer?

    private let onBegin: () -> Void
    private let onEnd: () -> Void
    private let onDiscard: () -> Void

    /// `onDiscard` fires when a hold that already started recording is abandoned
    /// (released too soon, or Option turned out to be part of a shortcut, a typed
    /// accent or a click): the recording is to be dropped, not transcribed.
    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void, onDiscard: @escaping () -> Void = {}) {
        self.onBegin = onBegin
        self.onEnd = onEnd
        self.onDiscard = onDiscard
    }

    func start() {
        guard globalMonitor == nil else { return }
        // BOTH monitors. The global one is blind to events delivered to Inkfall's
        // own windows, so with only that, hold-to-talk would die whenever Settings
        // or the onboarding window had focus. The local one returns the event
        // unchanged — observing, not intercepting.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watched) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watched) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        // Releasing the caller mid-hold would leave the mic open forever, so a
        // stop while held ends the hold rather than abandoning it.
        let decision = machine.stop()
        cancelArm()
        apply(decision)
    }

    private func handle(_ event: NSEvent) {
        let input: HoldMachine.Input
        switch event.type {
        case .flagsChanged:
            // Read the FLAGS, not the key code. A flagsChanged event carries the whole
            // current modifier state, so this stays correct when a second modifier goes
            // down mid-hold or when the release arrives on a different key's event —
            // the cases a keyCode == 58 test gets wrong.
            let leftOptionDown = (event.modifierFlags.rawValue & Self.leftOptionMask) == Self.leftOptionMask
            let hasOtherModifier = !event.modifierFlags.intersection(Self.disqualifying).isEmpty
            input = .modifiers(leftOption: leftOptionDown, otherModifier: hasOtherModifier, at: event.timestamp)
        case .keyDown:
            input = .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .mouseDown
        default:
            return
        }
        process(input)
    }

    private func process(_ input: HoldMachine.Input) {
        apply(machine.handle(input))
        if !machine.isArming { cancelArm() }
    }

    private func beginArming() {
        guard armTimer == nil else { return }
        let timer = Timer(timeInterval: HoldMachine.armDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.armTimer = nil
                self.process(.armElapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    private func cancelArm() {
        armTimer?.invalidate()
        armTimer = nil
    }

    private func apply(_ decision: HoldMachine.Decision) {
        switch decision {
        case .none: break
        case .startArmTimer: beginArming()
        case .begin: onBegin()
        case .end: onEnd()
        case .discard: onDiscard()
        }
    }

    // NO deinit. There was one, as a safety net that removed the monitors if this
    // object were dropped while running, and Swift 6 rejects it: deinit is
    // nonisolated, `NSEvent.addGlobalMonitorForEvents` returns `Any?`, and a
    // nonisolated deinit may not touch a non-Sendable stored property of an
    // actor-isolated type. Neither `@MainActor` on the deinit nor casting the
    // token escapes that — the type genuinely is `Any?`.
    //
    // So teardown is an INVARIANT the owner keeps instead: `AppDelegate` calls
    // `stop()` before it releases or replaces the monitor, in both places that
    // happens (`applyTriggerForMode`'s .tap branch, and the shortcut recorder
    // callback). Break that invariant and two NSEvent monitors leak for the life
    // of the process — hence this comment where the guard used to be, rather than
    // silently nothing.
}
