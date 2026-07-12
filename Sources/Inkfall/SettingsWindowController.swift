import AppKit
import ApplicationServices
import AVFoundation

enum SettingsTab: Int, CaseIterable {
    case general, speech, rewrite, permissions

    var title: String {
        switch self {
        case .general: return "General"
        case .speech: return "Speech"
        case .rewrite: return "Rewrite"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .speech: return "waveform"
        case .rewrite: return "sparkles"
        case .permissions: return "checkmark.shield"
        }
    }

    var itemID: NSToolbarItem.Identifier { NSToolbarItem.Identifier("settings.\(rawValue)") }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private var config: InkfallConfig
    private let onSave: (InkfallConfig) -> Void
    private let onHotkeyRecording: (Bool) -> Void
    private var pendingHotKey = KeyCombo.defaultCombo
    private var hotkeyField: KeyRecorderField?

    // Speech
    private let whisperBinaryField = SettingsControls.pathField(placeholder: "/path/to/whisper-cli")
    private let whisperModelField = SettingsControls.pathField(placeholder: "/path/to/ggml-model.bin")
    private let whisperFolderField = SettingsControls.pathField(placeholder: "~/Models/Inkfall")
    private let whisperURLField = SettingsControls.pathField(placeholder: "https://…/model.bin")
    private let whisperBinaryStatus = StatusChip()
    private let whisperModelStatus = StatusChip()
    private let whisperProgress = SettingsControls.progressBar()
    private let whisperProgressLabel = SettingsControls.captionLabel("")
    private var whisperDownload: ModelDownloadJob?
    private let enginePopup = NSPopUpButton()
    private let whisperKitModelPopup = NSPopUpButton()

    // Rewrite
    private let llamaBinaryField = SettingsControls.pathField(placeholder: "/path/to/llama-cli")
    private let llamaModelField = SettingsControls.pathField(placeholder: "/path/to/model.gguf")
    private let llamaFolderField = SettingsControls.pathField(placeholder: "~/Models/Inkfall")
    private let llamaURLField = SettingsControls.pathField(placeholder: "https://…/model.gguf")
    private let llamaBinaryStatus = StatusChip()
    private let llamaModelStatus = StatusChip()
    private let llamaProgress = SettingsControls.progressBar()
    private let llamaProgressLabel = SettingsControls.captionLabel("")
    private var llamaDownload: ModelDownloadJob?
    private let rewriteEnginePopup = NSPopUpButton()
    private let appleRewriteStatus = StatusChip()
    private let appleRewriteHint = SettingsControls.captionLabel("")
    private let languagePopup = NSPopUpButton()
    private let vocabularyField = SettingsControls.plainField(placeholder: "Inkfall, WhisperKit, Qwen")

    // General
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Inkfall at login", target: nil, action: nil)
    private let hudPositionPopup = NSPopUpButton()
    /// Called when the user changes the HUD-position picker, so the app can flash a
    /// live preview of the indicator at that spot.
    var onPreviewHUDPosition: ((HUDPosition) -> Void)?

    // Permissions
    private let micStatus = StatusChip()
    private let accessibilityStatus = StatusChip()

    private let scrollView = NSScrollView()
    private let footerStatus = SettingsControls.captionLabel("")
    private var panes: [SettingsTab: NSView] = [:]
    private var permissionsTimer: Timer?
    // Collapsible "Advanced" bodies, keyed by their toggle's tag.
    private var disclosureBodies: [Int: NSView] = [:]
    private var nextDisclosureTag = 1
    // The whisper.cpp Advanced disclosure, so we can auto-open it for the CLI engine.
    private weak var whisperAdvancedToggle: NSButton?
    private weak var whisperAdvancedCard: NSView?

    init(
        config: InkfallConfig,
        onSave: @escaping (InkfallConfig) -> Void,
        onHotkeyRecording: @escaping (Bool) -> Void
    ) {
        self.config = config
        self.onSave = onSave
        self.onHotkeyRecording = onHotkeyRecording
        self.pendingHotKey = config.hotKey

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.contentMinSize = NSSize(width: 520, height: 380)
        window.center()

        super.init(window: window)
        window.delegate = self

        buildChrome()
        loadConfigIntoFields()
        select(.general)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Public

    func show() { show(tab: config.hasWhisperConfiguration ? .general : .speech) }

    func show(tab: SettingsTab) {
        loadConfigIntoFields()
        select(tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissionStatuses()
        startPermissionsTimer()
    }

    func update(config: InkfallConfig) {
        self.config = config
        loadConfigIntoFields()
    }

    // MARK: Chrome

    private func buildChrome() {
        guard let window else { return }

        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = SettingsTab.general.itemID
        window.toolbar = toolbar

        let content = NSView()
        window.contentView = content

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let footerBar = NSStackView(views: [
            footerStatus,
            NSView.spacer(),
            makeButton("Save", #selector(save), primary: true)
        ])
        footerBar.orientation = .horizontal
        footerBar.alignment = .centerY
        footerBar.spacing = 10
        footerBar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(footerBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            footerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footerBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footerBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private func select(_ tab: SettingsTab) {
        let pane = paneFor(tab)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            pane.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            pane.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            pane.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        window?.toolbar?.selectedItemIdentifier = tab.itemID
        window?.title = tab.title
        if tab == .permissions { refreshPermissionStatuses() }
        updateValidation()
    }

    private func paneFor(_ tab: SettingsTab) -> NSView {
        if let pane = panes[tab] { return pane }
        let pane: NSView
        switch tab {
        case .general: pane = generalPane()
        case .speech: pane = speechPane()
        case .rewrite: pane = rewritePane()
        case .permissions: pane = permissionsPane()
        }
        panes[tab] = pane
        return pane
    }

    // MARK: Panes

    private func generalPane() -> NSView {
        let recorder = KeyRecorderField(combo: pendingHotKey)
        recorder.onChange = { [weak self] combo in
            guard let self else { return }
            self.pendingHotKey = combo
            self.updateHotkeyWarning()
        }
        recorder.onRecordingChange = { [weak self] recording in self?.onHotkeyRecording(recording) }
        hotkeyField = recorder

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged(_:))

        hudPositionPopup.removeAllItems()
        hudPositionPopup.addItems(withTitles: HUDPosition.allCases.map(\.displayName))
        hudPositionPopup.target = self
        hudPositionPopup.action = #selector(hudPositionChanged)
        hudPositionPopup.selectItem(at: HUDPosition.allCases.firstIndex(of: config.hudPosition) ?? 1)

        let privacy = SettingsControls.bodyLabel("Everything runs on this Mac. Audio, transcripts, and cleanup never leave the device — the only network use is a model download you start yourself.")

        return section("General", rows: [
            row("Shortcut", recorder, hint: "Click, then press a modifier + key. Save to apply."),
            row("Start up", launchAtLoginCheckbox, hint: "Open Inkfall automatically when you log in."),
            row("Indicator", hudPositionPopup, hint: "Where the status bubble appears while you dictate."),
            SettingsControls.divider(),
            privacy
        ])
    }

    private func selectedHUDPosition() -> HUDPosition {
        let index = hudPositionPopup.indexOfSelectedItem
        let all = HUDPosition.allCases
        guard index >= 0, index < all.count else { return config.hudPosition }
        return all[index]
    }

    @objc private func hudPositionChanged() {
        onPreviewHUDPosition?(selectedHUDPosition())
    }

    private func speechPane() -> NSView {
        enginePopup.removeAllItems()
        enginePopup.addItems(withTitles: ["On-device · WhisperKit", "whisper.cpp · CLI"])
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.selectItem(at: config.speechEngine == .cli ? 1 : 0)

        whisperKitModelPopup.removeAllItems()
        whisperKitModelPopup.addItems(withTitles: ["tiny.en", "base.en", "small.en", "large-v3-turbo"])
        whisperKitModelPopup.selectItem(withTitle: config.whisperKitModelName)

        // Transcription language + vocabulary live here: both shape what words come
        // out of the recognizer, not the rewrite step.
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ["en", "auto", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"])
        languagePopup.selectItem(withTitle: config.whisperLanguage)
        languagePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let recommendRow = row("", stack([
            makeButton("Download recommended model", #selector(downloadRecommended)),
            SettingsControls.captionLabel(InkfallDefaults.recommendedWhisper.size)
        ]))
        let progressRow = row("", stack([whisperProgress, whisperProgressLabel]))
        let cliRow = pathRow("Engine (CLI)", field: whisperBinaryField, status: whisperBinaryStatus, choose: #selector(chooseWhisperBinary))
        let modelRow = pathRow("Model", field: whisperModelField, status: whisperModelStatus, choose: #selector(chooseWhisperModel))
        let folderRow = row("Download to", stack([whisperFolderField, makeButton("Folder", #selector(chooseWhisperFolder))]))
        let urlRow = row("From URL", stack([whisperURLField, makeButton("Download", #selector(downloadWhisper))]))

        let main = section("Speech — on-device", rows: [
            SettingsControls.bodyLabel("Inkfall transcribes entirely on this Mac. WhisperKit (Apple Neural Engine) is the default — nothing to install; the model downloads automatically the first time."),
            row("Engine", enginePopup),
            row("Model", whisperKitModelPopup, hint: "Larger models are more accurate but slower."),
            row("Language", languagePopup, hint: "The language you'll speak."),
            row("Vocabulary", vocabularyField, hint: "Names, acronyms, and product terms. Comma separated.")
        ])
        let advanced = disclosureSection(
            "Advanced — whisper.cpp",
            initiallyExpanded: config.speechEngine == .cli,
            rows: [
                SettingsControls.captionLabel("Use an external whisper.cpp CLI + ggml model instead of WhisperKit."),
                cliRow, modelRow, recommendRow, progressRow,
                SettingsControls.captionLabel("Or download from a custom URL:"),
                folderRow, urlRow
            ],
            onBuild: { [weak self] toggle, card in
                self?.whisperAdvancedToggle = toggle
                self?.whisperAdvancedCard = card
            }
        )
        return paneStack([main, advanced])
    }

    private func selectedEngine() -> SpeechEngine {
        guard enginePopup.numberOfItems > 0 else { return config.speechEngine }
        return enginePopup.indexOfSelectedItem == 1 ? .cli : .whisperKit
    }

    @objc private func engineChanged() {
        expandWhisperAdvancedIfCLI()
        updateValidation()
    }

    private func rewritePane() -> NSView {
        rewriteEnginePopup.removeAllItems()
        rewriteEnginePopup.addItems(withTitles: ["Apple · on-device", "llama.cpp · CLI", "Off · raw words"])
        rewriteEnginePopup.target = self
        rewriteEnginePopup.action = #selector(rewriteEngineChanged)
        rewriteEnginePopup.selectItem(at: rewriteEngineIndex(config.rewriteEngine))
        refreshAppleRewriteStatus()

        let cliRow = pathRow("Engine (CLI)", field: llamaBinaryField, status: llamaBinaryStatus, choose: #selector(chooseLlamaBinary))
        let modelRow = pathRow("Model", field: llamaModelField, status: llamaModelStatus, choose: #selector(chooseLlamaModel))
        let folderRow = row("Download to", stack([llamaFolderField, makeButton("Folder", #selector(chooseLlamaFolder))]))
        let urlRow = row("From URL", stack([llamaURLField, makeButton("Download", #selector(downloadLlama))]))
        let progressRow = row("", stack([llamaProgress, llamaProgressLabel]))

        let main = section("Rewrite", rows: [
            SettingsControls.bodyLabel("Turn spoken words into clean writing — grammar fixed, punctuation added, filler removed. Apple's on-device model does this with nothing to install; your text never leaves this Mac."),
            row("Engine", rewriteEnginePopup),
            row("Apple Intelligence", appleRewriteStatus),
            appleRewriteHint
        ])
        let advanced = disclosureSection("Advanced — llama.cpp", rows: [
            SettingsControls.captionLabel("Use an external llama.cpp CLI + GGUF model instead of Apple's model."),
            cliRow, modelRow,
            SettingsControls.captionLabel("Download a model, or point at one you already have."),
            folderRow, urlRow, progressRow
        ])
        return paneStack([main, advanced])
    }

    private func rewriteEngineIndex(_ engine: RewriteEngine) -> Int {
        switch engine {
        case .apple: return 0
        case .llama: return 1
        case .off: return 2
        }
    }

    private func selectedRewriteEngine() -> RewriteEngine {
        switch rewriteEnginePopup.indexOfSelectedItem {
        case 1: return .llama
        case 2: return .off
        default: return .apple
        }
    }

    @objc private func rewriteEngineChanged() {
        refreshAppleRewriteStatus()
        updateValidation()
    }

    /// Reflect whether Apple's on-device model is usable right now, and how to fix it.
    private func refreshAppleRewriteStatus() {
        let available = AppleFoundationRewriter.isAvailable
        let reason = AppleFoundationRewriter.unavailableReason
        appleRewriteStatus.set(available ? "Ready" : "Not ready", tone: available ? .ok : .warning)
        appleRewriteHint.stringValue = available
            ? "On-device · nothing to install."
            : (reason ?? "Apple Intelligence is unavailable.")
    }

    private func permissionsPane() -> NSView {
        let micRow = row("Microphone", stack([micStatus, makeButton("Grant", #selector(grantMicrophone))]), hint: "Audio never leaves this Mac.")
        let axRow = row("Accessibility", stack([accessibilityStatus, makeButton("Open Settings", #selector(openAccessibility))]), hint: "Lets Inkfall place text into your app.")
        return section("Permissions", rows: [
            SettingsControls.bodyLabel("Inkfall needs two permissions: the microphone to hear you, and Accessibility to type the result into your app."),
            micRow, axRow,
            SettingsControls.captionLabel("Re-checked each time Inkfall becomes active.")
        ])
    }

    // MARK: Builders

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor

        let card = CardView(cornerRadius: 12)
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        let outer = NSStackView(views: [header, card])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        card.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        return outer
    }

    private func row(_ label: String, _ control: NSView, hint: String? = nil) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 108).isActive = true

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controlRow = NSStackView(views: [labelField, control])
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.spacing = 12

        guard let hint else { return controlRow }
        let hintLabel = SettingsControls.captionLabel(hint)
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let hintRow = NSStackView(views: [spacer, hintLabel])
        hintRow.orientation = .horizontal
        hintRow.spacing = 0

        let vertical = NSStackView(views: [controlRow, hintRow])
        vertical.orientation = .vertical
        vertical.alignment = .leading
        vertical.spacing = 3
        return vertical
    }

    private func pathRow(_ label: String, field: NSTextField, status: StatusChip, choose: Selector) -> NSView {
        row(label, stack([field, status, makeButton("Choose", choose)]))
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeButton(_ title: String, _ selector: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        if primary { button.keyEquivalent = "\r" }
        return button
    }

    /// Vertically stacks a pane's sections, keeping them the same width.
    private func paneStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A titled card that collapses/expands when its disclosure triangle is clicked.
    /// Starts collapsed so advanced options stay out of the way — unless
    /// `initiallyExpanded` (e.g. the CLI engine is active, so its setup fields must
    /// be visible). `onBuild` hands the toggle + card back so callers can drive the
    /// state later (e.g. expand when the engine switches to CLI).
    private func disclosureSection(
        _ title: String,
        initiallyExpanded: Bool = false,
        rows: [NSView],
        onBuild: ((NSButton, NSView) -> Void)? = nil
    ) -> NSView {
        let tag = nextDisclosureTag
        nextDisclosureTag += 1

        let toggle = NSButton()
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.pushOnPushOff)
        toggle.title = ""
        toggle.state = initiallyExpanded ? .on : .off
        toggle.tag = tag
        toggle.target = self
        toggle.action = #selector(toggleDisclosure(_:))

        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [toggle, label])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let card = CardView(cornerRadius: 12)
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        card.isHidden = !initiallyExpanded
        disclosureBodies[tag] = card

        let outer = NSStackView(views: [header, card])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        card.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        onBuild?(toggle, card)
        return outer
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        guard let body = disclosureBodies[sender.tag] else { return }
        body.isHidden = sender.state != .on
    }

    /// Expand (never force-collapse) the whisper.cpp Advanced disclosure so the CLI
    /// engine's required binary/model fields are reachable when that engine is active.
    private func expandWhisperAdvancedIfCLI() {
        guard selectedEngine() == .cli else { return }
        whisperAdvancedToggle?.state = .on
        whisperAdvancedCard?.isHidden = false
    }

    // MARK: Launch at login

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let want = sender.state == .on
        if let error = LoginItemService.setEnabled(want) {
            setFooter("Couldn't update Login Items: \(error)", tone: .warning)
        } else {
            // Mirror intent into the persisted config; the OS remains authoritative.
            var updated = config
            updated.launchAtLogin = want
            try? updated.save()
            config = updated
            setFooter(want ? "Inkfall will launch at login." : "Inkfall won't launch at login.", tone: .ok)
        }
        refreshLaunchAtLoginCheckbox()
    }

    /// Drive the checkbox from the live OS registration, never a cached Bool, so it
    /// stays honest even if the user flips it in System Settings behind our back.
    private func refreshLaunchAtLoginCheckbox() {
        launchAtLoginCheckbox.state = LoginItemService.isEnabled ? .on : .off
        if LoginItemService.needsApproval {
            setFooter("Enable Inkfall in System Settings ▸ General ▸ Login Items.", tone: .warning)
        }
    }

    // MARK: Toolbar delegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { $0.itemID == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage.flowSymbol(tab.symbol, pointSize: 18, weight: .regular)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        item.tag = tab.rawValue
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.itemID)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.itemID)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.itemID)
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.tag) else { return }
        select(tab)
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        stopPermissionsTimer()
        // Guarantee the global hotkey is re-armed even if the window closed mid-record.
        onHotkeyRecording(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The user may have flipped the login item or a permission in System Settings
        // while the window was open; re-read the ground truth on return.
        refreshLaunchAtLoginCheckbox()
        refreshPermissionStatuses()
    }

    // MARK: Config <-> fields

    private func loadConfigIntoFields() {
        whisperBinaryField.stringValue = config.whisperBinaryPath ?? ""
        whisperModelField.stringValue = config.whisperModelPath ?? ""
        whisperFolderField.stringValue = config.whisperModelDirectory ?? ""
        whisperURLField.stringValue = config.whisperModelURL ?? ""
        llamaBinaryField.stringValue = config.llamaBinaryPath ?? ""
        llamaModelField.stringValue = config.llamaModelPath ?? ""
        llamaFolderField.stringValue = config.llamaModelDirectory ?? ""
        llamaURLField.stringValue = config.llamaModelURL ?? ""
        languagePopup.selectItem(withTitle: config.whisperLanguage)
        vocabularyField.stringValue = config.customVocabulary.joined(separator: ", ")
        // Zero-config: auto-detect an installed engine and default the model folder.
        if whisperBinaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let detected = InkfallDefaults.detectWhisperCLI() {
            whisperBinaryField.stringValue = detected
        }
        if whisperFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whisperFolderField.stringValue = InkfallDefaults.modelsDirectory.path
        }
        if enginePopup.numberOfItems > 0 {
            enginePopup.selectItem(at: config.speechEngine == .cli ? 1 : 0)
            expandWhisperAdvancedIfCLI()
        }
        if whisperKitModelPopup.numberOfItems > 0 {
            whisperKitModelPopup.selectItem(withTitle: config.whisperKitModelName)
        }
        if rewriteEnginePopup.numberOfItems > 0 {
            rewriteEnginePopup.selectItem(at: rewriteEngineIndex(config.rewriteEngine))
            refreshAppleRewriteStatus()
        }
        refreshLaunchAtLoginCheckbox()
        if hudPositionPopup.numberOfItems > 0 {
            hudPositionPopup.selectItem(at: HUDPosition.allCases.firstIndex(of: config.hudPosition) ?? 1)
        }
        pendingHotKey = config.hotKey
        hotkeyField?.setCombo(pendingHotKey)
        hotkeyField?.hasWarning = false
        updateValidation()
    }

    private func updateHotkeyWarning() {
        let conflict = KeyCombo.isSystemReserved(
            keyCode: pendingHotKey.keyCode,
            carbonModifiers: pendingHotKey.carbonModifiers
        )
        hotkeyField?.hasWarning = conflict
        if conflict {
            setFooter("\(pendingHotKey.display) is a macOS system shortcut — it may not work.", tone: .warning)
        } else {
            updateValidation()
        }
    }

    @objc private func save() {
        var updated = config
        updated.whisperBinaryPath = clean(whisperBinaryField.stringValue)
        updated.whisperModelPath = clean(whisperModelField.stringValue)
        updated.whisperModelDirectory = clean(whisperFolderField.stringValue)
        updated.whisperModelURL = clean(whisperURLField.stringValue)
        updated.llamaBinaryPath = clean(llamaBinaryField.stringValue)
        updated.llamaModelPath = clean(llamaModelField.stringValue)
        updated.llamaModelDirectory = clean(llamaFolderField.stringValue)
        updated.llamaModelURL = clean(llamaURLField.stringValue)
        updated.whisperLanguage = languagePopup.titleOfSelectedItem ?? "en"
        updated.customVocabulary = vocabularyField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.hotKeyCode = Int(pendingHotKey.keyCode)
        updated.hotKeyModifiers = Int(pendingHotKey.carbonModifiers)
        updated.hotKeyDisplay = pendingHotKey.display
        updated.speechEngineRaw = selectedEngine().rawValue
        updated.rewriteEngineRaw = selectedRewriteEngine().rawValue
        updated.hudPositionRaw = selectedHUDPosition().rawValue
        if whisperKitModelPopup.numberOfItems > 0, let model = whisperKitModelPopup.titleOfSelectedItem {
            updated.whisperKitModel = model
        }

        do {
            try updated.save()
            config = updated
            onSave(updated)
            updateValidation(saved: true)
        } catch {
            setFooter("Save failed: \(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: File pickers

    @objc private func chooseWhisperBinary() { chooseFile { self.whisperBinaryField.stringValue = $0 } }
    @objc private func chooseWhisperModel() { chooseFile { self.whisperModelField.stringValue = $0 } }
    @objc private func chooseWhisperFolder() { chooseFolder { self.whisperFolderField.stringValue = $0 } }
    @objc private func chooseLlamaBinary() { chooseFile { self.llamaBinaryField.stringValue = $0 } }
    @objc private func chooseLlamaModel() { chooseFile { self.llamaModelField.stringValue = $0 } }
    @objc private func chooseLlamaFolder() { chooseFolder { self.llamaFolderField.stringValue = $0 } }

    private func chooseFile(_ assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            assign(url.path)
            updateValidation()
        }
    }

    private func chooseFolder(_ assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            assign(url.path)
        }
    }

    // MARK: Downloads

    private enum DownloadTarget { case whisper, llama }

    @objc private func downloadWhisper() { startDownload(target: .whisper) }
    @objc private func downloadLlama() { startDownload(target: .llama) }

    @objc private func downloadRecommended() {
        whisperURLField.stringValue = InkfallDefaults.recommendedWhisper.urlString
        whisperFolderField.stringValue = InkfallDefaults.modelsDirectory.path
        startDownload(target: .whisper)
    }

    private func startDownload(target: DownloadTarget) {
        let urlField = target == .whisper ? whisperURLField : llamaURLField
        let folderField = target == .whisper ? whisperFolderField : llamaFolderField
        let progress = target == .whisper ? whisperProgress : llamaProgress
        let label = target == .whisper ? whisperProgressLabel : llamaProgressLabel

        guard let cleanURL = clean(urlField.stringValue), let cleanFolder = clean(folderField.stringValue) else {
            setFooter("Choose a download folder and paste a direct model URL.", tone: .warning)
            return
        }

        progress.isHidden = false
        progress.doubleValue = 0
        label.stringValue = "Starting…"

        let job = ModelDownloadJob(
            directory: cleanFolder,
            onProgress: { fraction, received, total in
                Task { @MainActor in
                    progress.doubleValue = fraction
                    label.stringValue = Self.progressText(received: received, total: total)
                }
            },
            onFinished: { [weak self] result in
                Task { @MainActor in self?.finishDownload(target: target, result: result) }
            }
        )
        switch target {
        case .whisper: whisperDownload = job
        case .llama: llamaDownload = job
        }
        // The recommended model has a known digest, so verify it. Arbitrary user URLs
        // have no known hash and fall back to the status/size/name checks.
        let expectedSHA = cleanURL == InkfallDefaults.recommendedWhisper.urlString
            ? InkfallDefaults.recommendedWhisper.sha256
            : nil
        job.start(urlString: cleanURL, expectedSHA256: expectedSHA)
    }

    private func finishDownload(target: DownloadTarget, result: Result<ModelDownloadResult, Error>) {
        let progress = target == .whisper ? whisperProgress : llamaProgress
        let label = target == .whisper ? whisperProgressLabel : llamaProgressLabel
        let modelField = target == .whisper ? whisperModelField : llamaModelField

        switch result {
        case .success(let downloaded):
            modelField.stringValue = downloaded.filePath
            progress.doubleValue = 1
            label.stringValue = "Downloaded."
            updateValidation()
        case .failure(let error):
            label.stringValue = "Failed: \(error.localizedDescription)"
        }

        switch target {
        case .whisper: whisperDownload = nil
        case .llama: llamaDownload = nil
        }
    }

    private static func progressText(received: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if total > 0 {
            return "\(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: total))"
        }
        return formatter.string(fromByteCount: received)
    }

    // MARK: Permissions

    @objc private func grantMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refreshPermissionStatuses() }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func startPermissionsTimer() {
        stopPermissionsTimer()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionStatuses() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionsTimer = timer
    }

    private func stopPermissionsTimer() {
        permissionsTimer?.invalidate()
        permissionsTimer = nil
    }

    private func refreshPermissionStatuses() {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micStatus.set(micOK ? "Granted" : "Not granted", tone: micOK ? .ok : .warning)
        let axOK = AXIsProcessTrusted()
        accessibilityStatus.set(axOK ? "Granted" : "Not granted", tone: axOK ? .ok : .warning)
    }

    // MARK: Validation

    private func updateValidation(saved: Bool = false) {
        let cliRequired = selectedEngine() == .cli
        setPathStatus(whisperBinaryStatus, path: whisperBinaryField.stringValue, required: cliRequired, executable: true)
        setPathStatus(whisperModelStatus, path: whisperModelField.stringValue, required: cliRequired, executable: false)
        setPathStatus(llamaBinaryStatus, path: llamaBinaryField.stringValue, required: false, executable: true)
        setPathStatus(llamaModelStatus, path: llamaModelField.stringValue, required: false, executable: false)

        if selectedEngine() == .whisperKit {
            setFooter(saved ? "Saved. On-device transcription is ready." : "On-device transcription is ready — Rewrite is optional.", tone: .ok)
        } else {
            let speechReady = fileExists(whisperBinaryField.stringValue) && fileExists(whisperModelField.stringValue)
            setFooter(
                speechReady
                    ? (saved ? "Saved. Speech ready — Rewrite is optional." : "Speech ready — Rewrite is optional.")
                    : "Connect the whisper.cpp CLI and model to enable dictation.",
                tone: speechReady ? .ok : .warning
            )
        }
    }

    private func setPathStatus(_ chip: StatusChip, path: String, required: Bool, executable: Bool) {
        guard let clean = clean(path) else {
            chip.set(required ? "Missing" : "Optional", tone: required ? .warning : .neutral)
            return
        }
        if !FileManager.default.fileExists(atPath: clean) {
            chip.set("Not found", tone: required ? .error : .warning)
        } else if executable && !FileManager.default.isExecutableFile(atPath: clean) {
            chip.set("Not executable", tone: .warning)
        } else {
            chip.set(executable ? "Executable" : "Found", tone: .ok)
        }
    }

    private func fileExists(_ path: String) -> Bool {
        guard let clean = clean(path) else { return false }
        return FileManager.default.fileExists(atPath: clean)
    }

    private func setFooter(_ text: String, tone: StatusChip.Tone) {
        footerStatus.stringValue = text
        footerStatus.textColor = tone.color
    }

    private func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Reusable controls

@MainActor
enum SettingsControls {
    static func pathField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return field
    }

    static func plainField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return field
    }

    static func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        return label
    }

    static func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return line
    }

    static func progressBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        bar.isHidden = true
        bar.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return bar
    }
}

// MARK: - Status chip

/// Flipped so scroll-view content lays out from the top down, not the bottom up.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class StatusChip: NSView {
    enum Tone {
        case ok, warning, error, neutral
        var color: NSColor {
            switch self {
            case .ok: return InkfallDesign.green
            case .warning: return InkfallDesign.amber
            case .error: return InkfallDesign.red
            case .neutral: return .tertiaryLabelColor
            }
        }
    }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        set("—", tone: .neutral)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(_ text: String, tone: Tone) {
        label.stringValue = text
        label.textColor = tone.color
        layer?.backgroundColor = tone.color.withAlphaComponent(0.14).cgColor
    }
}
