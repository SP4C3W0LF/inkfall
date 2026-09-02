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

    /// How long Option must be held before capture starts. Option is tapped and
    /// half-pressed constantly in normal typing; without a delay, every brush of
    /// it would open the mic and file a fragment of room noise. The cost is the
    /// first fifth of a second, which is the time you spend drawing breath.
    private static let armDelay: TimeInterval = 0.2

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var armTimer: Timer?
    private var isHolding = false

    private let onBegin: () -> Void
    private let onEnd: () -> Void

    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        // BOTH monitors. The global one is blind to events delivered to Inkfall's
        // own windows, so with only that, hold-to-talk would die whenever Settings
        // or the onboarding window had focus. The local one returns the event
        // unchanged — observing, not intercepting.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelArm()
        // Releasing the caller mid-hold would leave the mic open forever, so a
        // stop while held ends the hold rather than abandoning it.
        if isHolding {
            isHolding = false
            onEnd()
        }
    }

    private func handle(_ event: NSEvent) {
        let raw = event.modifierFlags.rawValue
        let leftOptionDown = (raw & Self.leftOptionMask) == Self.leftOptionMask
        let hasOtherModifier = !event.modifierFlags
            .intersection(Self.disqualifying)
            .isEmpty

        // Read the FLAGS, not the key code. A flagsChanged event carries the whole
        // current modifier state, so this stays correct when a second modifier goes
        // down mid-hold or when the release arrives on a different key's event —
        // the cases a keyCode == 58 test gets wrong.
        if leftOptionDown && !hasOtherModifier {
            beginArming()
        } else {
            endHold()
        }
    }

    private func beginArming() {
        guard !isHolding, armTimer == nil else { return }
        let timer = Timer(timeInterval: Self.armDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.armTimer = nil
                self.isHolding = true
                self.onBegin()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    private func endHold() {
        cancelArm()
        guard isHolding else { return }   // a tap that never armed: nothing to end
        isHolding = false
        onEnd()
    }

    private func cancelArm() {
        armTimer?.invalidate()
        armTimer = nil
    }

    deinit {
        // `stop()` is MainActor-isolated and deinit is not; remove the monitors
        // directly. By this point nothing is listening for onEnd anyway.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
