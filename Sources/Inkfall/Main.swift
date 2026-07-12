import AppKit
import Foundation

@main
enum InkfallMain {
    static func main() {
        // macOS's out-of-process (scene-based) status item invokes our @MainActor
        // AppKit callbacks through a board-services dispatch callout that Swift 6.2's
        // strict executor check can't verify as the main executor — turning routine
        // main-thread calls into fatal "unexpected executor" crashes. Fall back to the
        // legacy (non-fatal) check. Must be set before the runtime reads it.
        setenv("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE", "legacy", 1)

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}
