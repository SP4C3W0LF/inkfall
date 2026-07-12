import Carbon
import Foundation

final class HotKeyService {
    private var keyCode: UInt32
    private var modifiers: UInt32
    private let handler: @Sendable () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @Sendable () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
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
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                service.handler()
                return noErr
            },
            1,
            &eventType,
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
