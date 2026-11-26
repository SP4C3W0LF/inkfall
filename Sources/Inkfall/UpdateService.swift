import AppKit
import Sparkle

/// Whether this copy of Inkfall can update itself, decided apart from Sparkle so it can
/// be tested. Only the released app can: it is a real app bundle whose Info.plist names
/// the feed and the key its updates are signed with. A `swift run` build has neither.
enum UpdateSupport {
    static let feedKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    static func isAvailable(bundleURL: URL, info: [String: Any]) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        guard let feed = info[feedKey] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil else { return false }
        guard let key = info[publicKeyKey] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32 else { return false }
        return true
    }
}

/// What the status menu offers about updates.
enum UpdateMenuState: Equatable {
    /// This copy cannot update itself: no menu item.
    case unavailable
    case check
    /// A scheduled check found this version and is waiting for the user to look at it.
    case pending(version: String)

    var menuTitle: String? {
        switch self {
        case .unavailable: return nil
        case .check: return "Check for Updates…"
        case let .pending(version): return "Update to Inkfall \(version)…"
        }
    }
}

/// The one switch Settings shows. Separate from `UpdateService` so the window can be
/// tested without Sparkle.
@MainActor
protocol UpdatePreferences: AnyObject {
    /// Whether Inkfall looks for updates by itself, about once a day. Off until the user
    /// turns it on: Inkfall makes no network request nobody asked for.
    var checksAutomatically: Bool { get set }
}

/// Updates through Sparkle: "Check for Updates…" in the menu and, if the user turns it
/// on in Settings, a check about once a day. An update is downloaded from the GitHub
/// release, verified against the key in Info.plist and the app's Developer ID, installed,
/// and the app relaunched.
@MainActor
final class UpdateService: NSObject, UpdatePreferences, SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController?
    /// Called on the main actor when `menuState` changes.
    var onMenuStateChange: (() -> Void)?
    private(set) var menuState: UpdateMenuState = .check {
        didSet { if menuState != oldValue { onMenuStateChange?() } }
    }

    /// Nil when this copy cannot update itself (see `UpdateSupport`).
    init?(bundle: Bundle = .main) {
        guard UpdateSupport.isAvailable(bundleURL: bundle.bundleURL, info: bundle.infoDictionary ?? [:]) else {
            return nil
        }
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
        )
    }

    var checksAutomatically: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The menu item. Also brings an update a scheduled check already found into view.
    func checkForUpdates() {
        // Inkfall has no Dock icon: without this the update window opens behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate
    //
    // A menu-bar app must not throw a window in the user's face because a timer fired.
    // An update found by a scheduled check becomes a line in the status menu instead; the
    // window opens when the user picks it. A check the user started shows as usual.
    //
    // `nonisolated` with an explicit hop, like every other callback in this app (see the
    // note above the menu actions in AppDelegate).

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Right after launch the app is in front anyway: let Sparkle show it. Later, never.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.menuState = .pending(version: version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.menuState = .check }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.menuState = .check }
    }
}
