import Carbon
import Foundation

final class HotKeyService {
    private var keyCode: UInt32
    private var modifiers: UInt32
    private let handler: @Sendable () -> Void
    /// Set only for hold-to-talk. Carbon delivers `kEventHotKeyReleased` as a
    /// first-class event — Apple's own UIElementInspector sample registers for the
    /// release ALONE — so push-to-talk needs no event tap and no Accessibility
    /// grant, which matters here: Inkfall must still work when the user has only
    /// granted the microphone.
    private let releaseHandler: (@Sendable () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @Sendable () -> Void,
        releaseHandler: (@Sendable () -> Void)? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        self.releaseHandler = releaseHandler
    }

    func register() {
        installEventHandlerIfNeeded()
        registerHotKey()
    }

    /// Rebind to a new key combination without tearing down the event handler.
    func update(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        registerHotKey()
    }

    /// Temporarily stop responding (e.g. while the user records a new shortcut).
    func suspend() {
        unregisterHotKey()
    }

    func resume() {
        registerHotKey()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        // Register for BOTH kinds unconditionally, and decide in the callback. The
        // alternative — installing the release spec only when a releaseHandler
        // exists — would need the handler torn down and rebuilt whenever the user
        // switches dictation mode in Settings, and this service deliberately
        // survives rebinds (see `update`).
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    service.releaseHandler?()
                } else {
                    service.handler()
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPointer,
            &eventHandler
        )
    }

    private func registerHotKey() {
        unregisterHotKey()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C464C57), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
