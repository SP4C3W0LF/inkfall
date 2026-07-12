import AppKit
import ApplicationServices
import AVFoundation
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyService: HotKeyService?
    private var controller: DictationController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var hudWindowController: DictationHUDWindowController?
    private let normalizer = TranscriptNormalizer()
    private var currentConfig = InkfallConfig.default

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
                if recording { self?.hotKeyService?.suspend() } else { self?.hotKeyService?.resume() }
            }
        )
        // Live preview: flash the HUD where the user is pointing while they choose.
        settingsWindowController?.onPreviewHUDPosition = { [weak self] position in
            self?.hudWindowController?.preview(at: position)
        }

        configureStatusItem()

        let combo = config.hotKey
        HotkeyDisplay.current = combo.display
        hotKeyService = HotKeyService(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            Task { @MainActor in await self?.controller?.toggleRecording() }
        }
        hotKeyService?.register()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

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

    /// Load the WhisperKit model in the background so the first dictation is fast.
    private func prewarmSpeechEngine(_ config: InkfallConfig) {
        guard config.speechEngine == .whisperKit else { return }
        let model = config.whisperKitModelName
        Task.detached { await WhisperKitEngine.shared.prewarm(model: model) }
    }

    private func applyConfig(_ config: InkfallConfig) {
        currentConfig = config
        let combo = config.hotKey
        HotkeyDisplay.current = combo.display
        hotKeyService?.update(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
        settingsWindowController?.update(config: config)
        onboardingWindowController?.update(config: config)
        controller?.update(config: config, pipeline: Self.makePipeline(config: config, normalizer: normalizer))
        hudWindowController?.anchor = config.hudPosition
        updateStatusGlyph()
        prewarmSpeechEngine(config)
    }

    // MARK: Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = templateGlyph("waveform")
        item.button?.toolTip = "Inkfall"
        statusItem = item
        rebuildMenu()
    }

    private func templateGlyph(_ name: String) -> NSImage? {
        let image = NSImage.flowSymbol(name, pointSize: 16, weight: .regular)
        image?.isTemplate = true
        return image
    }

    private func render(_ state: DictationState) {
        hudWindowController?.render(state: state)
        updateStatusGlyph()
    }

    private func updateStatusGlyph() {
        guard let controller else { return }
        statusItem?.button?.image = templateGlyph(controller.menuState.menuGlyph)
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
        let state = controller.menuState

        let toggle = NSMenuItem(
            title: state.isRecording ? "Stop Dictation" : "Start Dictation",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let status = NSMenuItem(title: state.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let shortcut = NSMenuItem(title: "Shortcut: \(HotkeyDisplay.current)", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)

        menu.addItem(.separator())

        let copyLast = NSMenuItem(title: "Copy last result", action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = controller.lastResultText != nil
        menu.addItem(copyLast)

        let fixItems = contextualFixItems()
        if !fixItems.isEmpty {
            menu.addItem(.separator())
            fixItems.forEach { menu.addItem($0) }
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsMenuItem), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Inkfall", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func contextualFixItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            items.append(fixItem("Grant Microphone…", #selector(grantMicrophone)))
        }
        if !AXIsProcessTrusted() {
            items.append(fixItem("Open Accessibility Settings", #selector(openAccessibilityMenuItem)))
        }
        if !currentConfig.hasWhisperConfiguration {
            items.append(fixItem("Set Up Speech Model…", #selector(showModelSetupMenuItem)))
        }
        return items
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
        case .cancelDownload:
            break
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

    @objc nonisolated private func showSettingsMenuItem() {
        Task { @MainActor in self.showSettings() }
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
        Task { @MainActor in
            self.controller?.refreshReadiness()
            self.rebuildMenu()
        }
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
