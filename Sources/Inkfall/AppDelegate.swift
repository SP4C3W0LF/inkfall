import AppKit
import ApplicationServices
import AVFoundation
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyService: HotKeyService?
    /// Only running in hold mode — see `applyTriggerForMode`.
    private var holdMonitor: ModifierHoldMonitor?
    private var controller: DictationController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var hudWindowController: DictationHUDWindowController?
    /// Nil in a copy that cannot update itself (a development build).
    private var updateService: UpdateService?
    private let normalizer = TranscriptNormalizer()
    private var currentConfig = InkfallConfig.default
    /// What the system said when the shortcut was last registered as the active trigger.
    private var hotKeyStatus: OSStatus = noErr
    /// Runs only while Accessibility is not granted, to notice the grant without a relaunch.
    private var accessibilityWatchTimer: Timer?
    /// The state before the one being rendered, for the VoiceOver announcement.
    private var previousState: DictationState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Recordings a crash or a kill left in the temporary folder.
        TemporaryRecordings.sweep()

        let config = InkfallConfig.load()
        currentConfig = config
        let pipeline = Self.makePipeline(config: config, normalizer: normalizer)

        let controller = DictationController(
            config: config,
            audioCapture: AudioCaptureService(vad: EnergyVoiceActivityDetector()),
            pipeline: pipeline
        )
        controller.onConfigurationNeeded = { [weak self] in self?.showModelSetup() }
        controller.onStateChange = { [weak self] state in self?.render(state) }
        self.controller = controller

        let hud = DictationHUDWindowController()
        hud.audioLevelProvider = controller.audioLevelProvider
        hud.anchor = config.hudPosition
        hud.onAction = { [weak self] action in self?.handle(action) }
        hud.onHidden = { [weak self] in self?.controller?.hudDidHide() }
        hudWindowController = hud

        settingsWindowController = SettingsWindowController(
            config: config,
            onSave: { [weak self] updated in self?.applyConfig(updated) },
            onHotkeyRecording: { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.hotKeyService?.suspend()
                    // The recorder wants the user to press modifiers. Without this,
                    // reaching for ⌥ while choosing a shortcut would open the mic.
                    self.holdMonitor?.stop()
                } else {
                    self.hotKeyStatus = self.hotKeyService?.resume() ?? noErr
                    self.applyTriggerForMode(self.currentConfig)
                    self.updateStatusGlyph()
                }
            }
        )
        // Updates: a menu item and one switch in Settings. Nothing is asked of the network
        // until the user asks, or turns the switch on.
        updateService = UpdateService()
        updateService?.onMenuStateChange = { [weak self] in self?.rebuildMenu() }
        settingsWindowController?.updatePreferences = updateService
        // Live preview: flash the HUD where the user is pointing while they choose.
        settingsWindowController?.onPreviewHUDPosition = { [weak self] position in
            self?.hudWindowController?.preview(at: position)
        }

        configureStatusItem()

        let combo = config.hotKey
        HotkeyDisplay.current = combo.display
        // Both handlers are installed once and branch on the CURRENT mode, rather
        // than the service being rebuilt when the user switches modes in Settings.
        // `applyConfig` only calls `update(keyCode:modifiers:)`, which deliberately
        // keeps the installed event handler alive — swapping closures there would
        // mean tearing that down and is a second way for the hotkey to end up
        // unregistered.
        hotKeyService = HotKeyService(
            keyCode: combo.keyCode,
            modifiers: combo.carbonModifiers,
            handler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.currentConfig.mode {
                    case .tap:  await self.controller?.toggleRecording()
                    case .hold: await self.controller?.beginHold()
                    }
                }
            },
            releaseHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.currentConfig.mode == .hold else { return }
                    await self.controller?.endHold()
                }
            }
        )
        hotKeyStatus = hotKeyService?.register() ?? noErr
        applyTriggerForMode(config)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        startAccessibilityWatchIfNeeded()

        render(controller.state)
        prewarmSpeechEngine(config)

        if !config.hasCompletedOnboarding {
            showOnboarding()
        } else if !config.hasWhisperConfiguration {
            showModelSetup()
        }
    }

    // MARK: Pipeline

    private static func makePipeline(config: InkfallConfig, normalizer: TranscriptNormalizer) -> DictationPipeline {
        let transcriber: SpeechTranscriber
        switch config.speechEngine {
        case .whisperKit:
            transcriber = WhisperKitTranscriber(model: config.whisperKitModelName, language: config.whisperLanguage)
        case .cli:
            transcriber = WhisperCLITranscriber(config: config)
        }
        // Rewrite engine: Apple's on-device model by default (zero install), the
        // llama.cpp CLI for power users, or none. Every engine falls back to the
        // rule-based normalizer so the user always gets clean text.
        let ruleBased = RuleBasedRewriter(normalizer: normalizer)
        let rewriter: TranscriptRewriter
        switch config.rewriteEngine {
        case .off:
            rewriter = ruleBased
        case .llama:
            rewriter = CompositeRewriter(primary: LlamaCLIRewriter(config: config), fallback: ruleBased)
        case .apple:
            rewriter = CompositeRewriter(primary: AppleFoundationRewriter(), fallback: ruleBased)
        }
        return DictationPipeline(transcriber: transcriber, normalizer: normalizer, rewriter: rewriter)
    }

    /// Which input actually starts a dictation, decided by mode. The two triggers
    /// are mutually exclusive on purpose: ⌥Space begins by holding Option, so
    /// running both would mean reaching for the shortcut trips the bare-modifier
    /// hold first and the shortcut never resolves.
    private func applyTriggerForMode(_ config: InkfallConfig) {
        // Whatever branch runs, the wording follows what is actually listening.
        defer { TriggerWording.current = .resolve(mode: config.mode, holdMonitorActive: holdMonitor != nil) }
        switch config.mode {
        case .tap:
            holdMonitor?.stop()
            holdMonitor = nil
            hotKeyStatus = hotKeyService?.resume() ?? noErr

        case .hold:
            // A global NSEvent monitor without Accessibility receives NOTHING and
            // reports no error — hold-to-talk would simply appear dead, which is the
            // failure mode this app refuses everywhere else. Fall back to holding the
            // regular shortcut, which is Carbon and needs no grant, while the menu
            // goes on saying Accessibility is missing.
            guard AXIsProcessTrusted() else {
                holdMonitor?.stop()
                holdMonitor = nil
                hotKeyStatus = hotKeyService?.resume() ?? noErr
                return
            }
            hotKeyService?.suspend()
            hotKeyStatus = noErr   // not the trigger while the Option key is
            if holdMonitor == nil {
                holdMonitor = ModifierHoldMonitor(
                    onBegin: { [weak self] in
                        Task { @MainActor in await self?.controller?.beginHold() }
                    },
                    onEnd: { [weak self] in
                        Task { @MainActor in await self?.controller?.endHold() }
                    },
                    onDiscard: { [weak self] in
                        Task { @MainActor in self?.controller?.discardHold() }
                    }
                )
            }
            holdMonitor?.start()
        }
    }

    /// Load the WhisperKit model in the background so the first dictation is fast. Only
    /// from disk: a missing model is downloaded in view, by the controller.
    private func prewarmSpeechEngine(_ config: InkfallConfig) {
        guard config.speechEngine == .whisperKit else { return }
        let model = config.whisperKitModelName
        Task.detached { await WhisperKitEngine.shared.prewarm(model: model) }
    }

    private func applyConfig(_ config: InkfallConfig) {
        let previous = currentConfig
        currentConfig = config
        let combo = config.hotKey
        HotkeyDisplay.current = combo.display
        hotKeyStatus = hotKeyService?.update(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) ?? noErr
        applyTriggerForMode(config)
        settingsWindowController?.update(config: config)
        onboardingWindowController?.update(config: config)
        controller?.update(config: config, pipeline: Self.makePipeline(config: config, normalizer: normalizer))
        hudWindowController?.anchor = config.hudPosition
        updateStatusGlyph()

        // The user just asked for a model that is not on disk: download it now, in view.
        let startsDownload = ModelDownloadPolicy.shouldStartOnSave(
            oldEngine: previous.speechEngine, oldModel: previous.whisperKitModelName,
            newEngine: config.speechEngine, newModel: config.whisperKitModelName,
            isOnDisk: WhisperKitEngine.shared.isModelOnDisk(config.whisperKitModelName),
            onboardingOpen: onboardingWindowController?.window?.isVisible == true
        )
        if startsDownload {
            Task { @MainActor in await self.controller?.startModelDownload() }
        } else {
            prewarmSpeechEngine(config)
        }
    }

    // MARK: Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = templateGlyph(DictationState.idleMenuGlyph)
        item.button?.toolTip = "Inkfall"
        statusItem = item
        rebuildMenu()
    }

    private func templateGlyph(_ name: String) -> NSImage? {
        let image: NSImage?
        if name == DictationState.idleMenuGlyph {
            // Custom glyph from the asset catalog; `swift run` builds do not bundle it, so fall back.
            image = NSImage(named: name)
                ?? NSImage.flowSymbol("waveform", pointSize: 16, weight: .regular)
        } else {
            image = NSImage.flowSymbol(name, pointSize: 16, weight: .regular)
        }
        image?.isTemplate = true
        return image
    }

    private func render(_ state: DictationState) {
        let before = previousState
        previousState = state
        hudWindowController?.render(state: state, workIsSlow: controller?.workIsSlow ?? false)
        updateStatusGlyph()
        if let text = Announcement.text(from: before, to: state) { announce(text) }
    }

    /// Not verified: needs the running app and VoiceOver.
    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func updateStatusGlyph() {
        guard let controller else { return }
        let state = controller.menuState
        statusItem?.button?.image = templateGlyph(state.menuGlyph)
        statusItem?.button?.setAccessibilityLabel("Inkfall, \(state.statusLine)")
        rebuildMenu()
    }

    // MARK: Menu
    //
    // Built imperatively and re-assigned on state/readiness changes. We deliberately
    // do NOT use NSMenuDelegate: on macOS's out-of-process (scene-based) status item,
    // AppKit populates the delegate through a dispatch callout the Swift runtime can't
    // verify as the MainActor executor, which crashes under Swift 6 strict concurrency.

    private func rebuildMenu() {
        guard let controller else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let plan = StatusMenuPlan.entries(StatusMenuInput(
            state: controller.menuState,
            canCancel: controller.canCancel,
            hasLastResult: controller.lastResultText != nil,
            hasOriginalTranscript: controller.originalTranscriptText != nil,
            trigger: TriggerWording.current,
            shortcut: HotkeyDisplay.current,
            shortcutProblem: ShortcutProblem.line(status: hotKeyStatus, shortcut: HotkeyDisplay.current),
            secureInputOn: TextInserter.isSecureInputActive,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityTrusted: AXIsProcessTrusted(),
            hasSpeechModel: currentConfig.hasWhisperConfiguration,
            settingsProblem: InkfallConfig.loadProblem,
            updates: updateService?.menuState ?? .unavailable
        ))

        for entry in plan {
            switch entry {
            case .cancel:
                menu.addItem(fixItem("Cancel", #selector(cancelWork)))
            case let .toggle(title):
                menu.addItem(fixItem(title, #selector(toggleDictation)))
            case let .info(text):
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            case let .copyLast(enabled):
                let item = fixItem("Copy last result", #selector(copyLastResult))
                item.isEnabled = enabled
                menu.addItem(item)
            case let .copyOriginal(enabled):
                let item = fixItem("Copy original transcript", #selector(copyOriginalTranscript))
                item.isEnabled = enabled
                menu.addItem(item)
            case .chooseShortcut:
                menu.addItem(fixItem("Choose another shortcut…", #selector(showSettingsMenuItem)))
            case let .fix(kind):
                let selector: Selector
                switch kind {
                case .grantMicrophone: selector = #selector(grantMicrophone)
                case .openAccessibility: selector = #selector(openAccessibilityMenuItem)
                case .setUpModel: selector = #selector(showModelSetupMenuItem)
                }
                menu.addItem(fixItem(StatusMenuPlan.title(for: kind), selector))
            case let .updates(title):
                menu.addItem(fixItem(title, #selector(checkForUpdatesMenuItem)))
            case .settings:
                let item = fixItem("Settings…", #selector(showSettingsMenuItem))
                item.keyEquivalent = ","
                menu.addItem(item)
            case .quit:
                let item = fixItem("Quit Inkfall", #selector(quit))
                item.keyEquivalent = "q"
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }

        statusItem?.menu = menu
    }

    private func fixItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: HUD action routing

    private func handle(_ action: HUDAction) {
        switch action {
        case .grantMicrophone:
            requestMicrophone()
            controller?.dismiss()
        case .openAccessibility:
            openAccessibilitySettings()
            controller?.dismiss()
        case .setUpModel:
            showModelSetup()
            controller?.dismiss()
        case .openSoundSettings:
            openURL("x-apple.systempreferences:com.apple.preference.sound")
            controller?.dismiss()
        case .copyAgain:
            controller?.copyLastResultToClipboard()
            controller?.dismiss()
        case .retry:
            Task { @MainActor in await controller?.retry() }
        case .cancelDownload, .cancelWork:
            controller?.cancel()
        case .dismiss:
            controller?.dismiss()
        }
    }

    // MARK: Actions

    // These are targets for the scene-based status-item menu and app notifications.
    // AppKit invokes them through a board-services callout that Swift 6's strict
    // executor check can't verify as the MainActor, which crashes on entry to a
    // @MainActor method. Keep them `nonisolated` (no isolation preamble) and hop to
    // the main actor explicitly instead.
    @objc nonisolated private func toggleDictation() {
        Task { @MainActor in await self.controller?.toggleRecording() }
    }

    @objc nonisolated private func copyLastResult() {
        Task { @MainActor in self.controller?.copyLastResultToClipboard() }
    }

    @objc nonisolated private func copyOriginalTranscript() {
        Task { @MainActor in self.controller?.copyOriginalTranscriptToClipboard() }
    }

    @objc nonisolated private func cancelWork() {
        Task { @MainActor in self.controller?.cancel() }
    }

    @objc nonisolated private func showSettingsMenuItem() {
        Task { @MainActor in self.showSettings() }
    }

    @objc nonisolated private func checkForUpdatesMenuItem() {
        Task { @MainActor in self.updateService?.checkForUpdates() }
    }

    @objc nonisolated private func showModelSetupMenuItem() {
        Task { @MainActor in self.showModelSetup() }
    }

    @objc nonisolated private func grantMicrophone() {
        Task { @MainActor in self.requestMicrophone() }
    }

    @objc nonisolated private func openAccessibilityMenuItem() {
        Task { @MainActor in self.openAccessibilitySettings() }
    }

    @objc nonisolated private func quit() {
        Task { @MainActor in NSApp.terminate(nil) }
    }

    @objc nonisolated private func appDidBecomeActive() {
        Task { @MainActor in self.accessibilityMayHaveChanged() }
    }

    /// Reduce Transparency was switched on or off in System Settings.
    @objc nonisolated private func accessibilityDisplayChanged() {
        Task { @MainActor in self.hudWindowController?.refreshAppearance() }
    }

    /// Accessibility may have just been granted in System Settings: on the way back
    /// to the app, or, via the watch timer, while the user is still there. Re-deciding
    /// the trigger is what upgrades hold mode from the ⌥Space fallback to left Option
    /// without a relaunch.
    private func accessibilityMayHaveChanged() {
        controller?.refreshReadiness()
        applyTriggerForMode(currentConfig)
        rebuildMenu()
        startAccessibilityWatchIfNeeded()
    }

    /// A 2-second timer, running only while Accessibility is missing. Written like the
    /// silence timer in `DictationController`.
    private func startAccessibilityWatchIfNeeded() {
        guard accessibilityWatchTimer == nil,
              AccessibilityGrantWatch.shouldWatch(trusted: AXIsProcessTrusted()) else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickAccessibilityWatch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatchTimer = timer
    }

    private func tickAccessibilityWatch() {
        switch AccessibilityGrantWatch.step(trusted: AXIsProcessTrusted()) {
        case .keepWatching:
            break
        case .granted:
            accessibilityWatchTimer?.invalidate()
            accessibilityWatchTimer = nil
            accessibilityMayHaveChanged()
        }
    }

    // MARK: Quit and reopen

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        holdMonitor?.stop()
        hotKeyService?.suspend()
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Nothing is in flight any more: take every temporary recording with us.
        TemporaryRecordings.sweep(olderThan: 0)
    }

    /// Clicking the app again (Finder, Spotlight) has no window to show, so show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only when nothing of ours is on screen: onboarding or Settings already open stays put.
        if !flag { showSettings() }
        return true
    }

    // MARK: Windows

    private func showSettings() {
        settingsWindowController?.show()
    }

    private func showModelSetup() {
        settingsWindowController?.show(tab: .speech)
    }

    private func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(
                config: currentConfig,
                onSave: { [weak self] updated in self?.applyConfig(updated) },
                onFinished: { [weak self] in self?.controller?.refreshReadiness() }
            )
        }
        onboardingWindowController?.show()
    }

    // MARK: Permissions

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.controller?.refreshReadiness() }
            }
        default:
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
