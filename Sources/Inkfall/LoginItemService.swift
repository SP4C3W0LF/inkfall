import Foundation
import ServiceManagement

/// Registers Inkfall to launch at login via `SMAppService` (macOS 13+).
///
/// For a non-sandboxed app, `SMAppService.mainApp` registers the app bundle itself
/// as a login item — no helper target, plist, or entitlement required. The one
/// caveat: a login item points at a fixed bundle path, so an ad-hoc-signed build run
/// from Xcode/DerivedData registers *that* transient path. Once the app lives in
/// /Applications the registration is stable. Failures surface to the caller so the
/// UI can explain rather than silently drop the setting.
@MainActor
enum LoginItemService {
    /// Whether Inkfall is currently registered and enabled as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS is holding the item for user approval in System Settings
    /// ▸ General ▸ Login Items (the user disabled it there, or it needs a first OK).
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Reconcile the OS login-item registration with the desired state.
    /// Returns `nil` on success, or a user-facing message describing the failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return nil }
                try service.register()
            } else {
                guard service.status == .enabled else { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
