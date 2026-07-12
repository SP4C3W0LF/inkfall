import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private enum Step: Int, CaseIterable {
        case welcome, why, permissions, speech, rewrite, tryIt, ready

        var railTitle: String {
            switch self {
            case .welcome: return "Welcome"
            case .why: return "Why local"
            case .permissions: return "Permissions"
            case .speech: return "Speech model"
            case .rewrite: return "Rewrite"
            case .tryIt: return "Try it"
            case .ready: return "Ready"
            }
        }
    }

    private var config: InkfallConfig
    private let onSave: (InkfallConfig) -> Void
    private let onFinished: () -> Void

    private var step: Step = .welcome
    private let rail = NSStackView()
    private let contentContainer = NSView()
    private let backButton = NSButton()
    private let continueButton = NSButton()

    private let whisperProgress = SettingsControls.progressBar()
    private let whisperProgressLabel = SettingsControls.captionLabel("")

    private let micStatus = StatusChip()
    private let accessibilityStatus = StatusChip()
    private var pollTimer: Timer?
    private var didAutoDownloadModel = false
    private var didPromptPermissions = false
    /// Last observed (microphone, accessibility) grant pair, for re-rendering
    /// the Ready page's note the moment a grant flips.
    private var lastKnownGrants: (Bool, Bool)?
    private var tryItField: NSTextField?

    init(config: InkfallConfig, onSave: @escaping (InkfallConfig) -> Void, onFinished: @escaping () -> Void) {
        self.config = config
        self.onSave = onSave
        self.onFinished = onFinished

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Inkfall"
        // Lock the size so the window doesn't change dimensions between steps.
        window.contentMinSize = NSSize(width: 660, height: 520)
        window.contentMaxSize = NSSize(width: 660, height: 520)
        window.center()

        super.init(window: window)
        window.delegate = self
        buildChrome()
        renderStep()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    func update(config: InkfallConfig) {
        self.config = config
    }

    // MARK: Chrome

    private func buildChrome() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let railHolder = NSView()
        railHolder.wantsLayer = true
        railHolder.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        railHolder.translatesAutoresizingMaskIntoConstraints = false

        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 4
        rail.translatesAutoresizingMaskIntoConstraints = false
        railHolder.addSubview(rail)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(back)

        continueButton.title = "Get started"
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(advance)

        let footer = NSStackView(views: [backButton, NSView.spacer(), continueButton])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(railHolder)
        content.addSubview(contentContainer)
        content.addSubview(footer)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        NSLayoutConstraint.activate([
            railHolder.topAnchor.constraint(equalTo: content.topAnchor),
            railHolder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            railHolder.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            railHolder.widthAnchor.constraint(equalToConstant: 190),

            rail.topAnchor.constraint(equalTo: railHolder.topAnchor, constant: 24),
            rail.leadingAnchor.constraint(equalTo: railHolder.leadingAnchor, constant: 18),
            rail.trailingAnchor.constraint(equalTo: railHolder.trailingAnchor, constant: -12),

            divider.leadingAnchor.constraint(equalTo: railHolder.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 30),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),

            footer.topAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 30),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func renderStep() {
        buildRail()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let view = contentView(for: step)
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        ])

        backButton.isHidden = step == .welcome
        continueButton.title = continueTitle
        if step == .permissions {
            refreshPermissions()
            promptForPermissions()
        }
        if step == .speech { maybeAutoDownloadModel() }
        if step == .tryIt {
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.tryItField else { return }
                self.window?.makeFirstResponder(field)
            }
        }
    }

    /// "Comes with a default model": on first arrival at the Speech step, load the
    /// on-device WhisperKit model in the background (downloading it the first time)
    /// so the very first dictation is fast.
    private func maybeAutoDownloadModel() {
        guard !didAutoDownloadModel else { return }
        didAutoDownloadModel = true

        whisperProgress.isHidden = false
        whisperProgress.isIndeterminate = true
        whisperProgress.startAnimation(nil)
        whisperProgressLabel.stringValue = "Preparing your on-device model…"

        let model = config.whisperKitModelName
        Task { @MainActor [weak self] in
            let ok = await WhisperKitEngine.shared.prewarm(model: model)
            guard let self else { return }
            self.whisperProgress.stopAnimation(nil)
            self.whisperProgress.isHidden = true
            self.whisperProgressLabel.stringValue = ok
                ? "On-device model ready."
                : "The model will download on your first dictation."
        }
    }

    private var continueTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .ready: return "Finish"
        default: return "Continue"
        }
    }

    private func buildRail() {
        rail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for candidate in Step.allCases {
            rail.addArrangedSubview(railItem(candidate))
        }
    }

    private func railItem(_ candidate: Step) -> NSView {
        let done = candidate.rawValue < step.rawValue
        let active = candidate == step

        let disc = NSView()
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 8
        disc.layer?.borderWidth = 1.5
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.widthAnchor.constraint(equalToConstant: 16).isActive = true
        disc.heightAnchor.constraint(equalToConstant: 16).isActive = true
        if done {
            disc.layer?.backgroundColor = InkfallDesign.ember.cgColor
            disc.layer?.borderColor = InkfallDesign.ember.cgColor
            let check = NSImageView()
            check.image = NSImage.flowSymbol("checkmark", pointSize: 8, weight: .bold)
            check.contentTintColor = InkfallDesign.emberInk
            check.translatesAutoresizingMaskIntoConstraints = false
            disc.addSubview(check)
            check.centerXAnchor.constraint(equalTo: disc.centerXAnchor).isActive = true
            check.centerYAnchor.constraint(equalTo: disc.centerYAnchor).isActive = true
        } else {
            disc.layer?.backgroundColor = NSColor.clear.cgColor
            disc.layer?.borderColor = (active ? InkfallDesign.ember : NSColor.tertiaryLabelColor).cgColor
        }

        let label = NSTextField(labelWithString: candidate.railTitle)
        label.font = .systemFont(ofSize: 12.5, weight: active ? .semibold : .regular)
        label.textColor = active ? .labelColor : .secondaryLabelColor

        let row = NSStackView(views: [disc, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        return row
    }

    // MARK: Step content

    private func contentView(for step: Step) -> NSView {
        switch step {
        case .welcome: return welcomeContent()
        case .why: return whyContent()
        case .permissions: return permissionsContent()
        case .speech: return speechContent()
        case .rewrite: return rewriteContent()
        case .tryIt: return tryItContent()
        case .ready: return readyContent()
        }
    }

    private func welcomeContent() -> NSView {
        column([
            eyebrow("no cloud · no account · no telemetry"),
            title("Speak anywhere on your Mac, and your words become clean text."),
            subtitle("Right here, on this machine. Setup takes two permissions and one download."),
            SettingsControls.bodyLabel("Inkfall lives in your menu bar. Press \(HotkeyDisplay.current), talk, and the cleaned text lands in whatever app you're using.")
        ])
    }

    private func whyContent() -> NSView {
        column([
            eyebrow("why local"),
            title("Your voice never leaves this Mac."),
            trustCard("On this Mac", "Transcribed locally by Whisper — audio is never uploaded."),
            trustCard("No account", "Nothing to sign into. Nothing tracked."),
            trustCard("One network act", "A single on-device model download, handled automatically.")
        ])
    }

    private func permissionsContent() -> NSView {
        column([
            eyebrow("step 3"),
            title("Two quick permissions."),
            subtitle("Inkfall needs both to work — and both stay entirely on this Mac."),
            permissionRow(
                "Microphone", micStatus,
                detail: "So I can hear you. Audio never leaves your Mac.",
                button: "Grant", action: #selector(grantMicrophone)
            ),
            permissionRow(
                "Accessibility", accessibilityStatus,
                detail: "So I can type the text into whatever app you're using.",
                button: "Open Settings", action: #selector(openAccessibility)
            ),
            SettingsControls.captionLabel("This page updates the moment you grant each one.")
        ])
    }

    private func permissionRow(_ name: String, _ chip: StatusChip, detail: String, button: String, action: Selector) -> NSView {
        let card = CardView(cornerRadius: 10)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let actionButton = NSButton(title: button, target: self, action: action)
        actionButton.bezelStyle = .rounded

        let topRow = NSStackView(views: [nameLabel, chip, NSView.spacer(), actionButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let detailLabel = SettingsControls.captionLabel(detail)
        detailLabel.preferredMaxLayoutWidth = 372

        let stack = NSStackView(views: [topRow, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: 400),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return card
    }

    private func speechContent() -> NSView {
        column([
            eyebrow("step 4"),
            title("Your on-device speech model."),
            subtitle("Inkfall transcribes entirely on this Mac with WhisperKit (Apple Neural Engine) — nothing to install. The model is downloading now; you can change it anytime in Settings."),
            horizontal([whisperProgress, whisperProgressLabel]),
            SettingsControls.captionLabel("Prefer an external whisper.cpp engine? Set it up later in Settings › Speech.")
        ])
    }

    private func rewriteContent() -> NSView {
        column([
            eyebrow("step 5 · automatic"),
            title("Cleaned up as you speak."),
            subtitle("Inkfall turns your spoken words into polished text — grammar fixed, punctuation added, filler words dropped."),
            SettingsControls.bodyLabel("This runs on Apple's on-device model: nothing to install, nothing leaves your Mac. It needs Apple Intelligence turned on in System Settings ▸ Apple Intelligence & Siri. Without it, Inkfall still tidies spacing and punctuation on its own — and you can switch engines or turn rewrite off anytime in Settings ▸ Rewrite.")
        ])
    }

    private func tryItContent() -> NSView {
        let field = NSTextField()
        field.placeholderString = "Your dictated words will appear here…"
        field.font = .systemFont(ofSize: 14)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        tryItField = field

        return column([
            eyebrow("step 6"),
            title("Try it now."),
            subtitle("Press \(HotkeyDisplay.current), say a sentence, then press it again — your words land right here in the box."),
            field,
            SettingsControls.captionLabel("You'll see the HUD at the top of the screen: Listening → Transcribing → Inserted.")
        ])
    }

    private func readyContent() -> NSView {
        var views: [NSView] = [
            eyebrow("all set"),
            title("You're ready to go."),
            subtitle("Inkfall lives in your menu bar. Press \(HotkeyDisplay.current) anywhere to dictate.")
        ]
        if let note = pendingPermissionsNote() {
            views.append(permissionsNote(note))
        }
        views.append(SettingsControls.bodyLabel("Reopen Settings any time with ⌘, from the menu bar. \u{201C}Copy last result\u{201D} lives there too. Enjoy dictating — privately."))
        return column(views)
    }

    /// One calm sentence on the Ready page when something is still ungranted —
    /// finishing is never blocked, but "ready" must not overpromise.
    private func pendingPermissionsNote() -> String? {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()
        switch (micOK, axOK) {
        case (true, true):
            return nil
        case (false, true):
            return "The microphone is still off — I'll ask again the moment you start dictating."
        case (true, false):
            return "Accessibility is still off — your words will land on the clipboard until you grant it."
        case (false, false):
            return "Microphone and Accessibility are still off — grant them from the menu bar whenever you're ready."
        }
    }

    private func permissionsNote(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = InkfallDesign.ember
        label.preferredMaxLayoutWidth = 400
        return label
    }

    // MARK: Content helpers

    private func column(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func horizontal(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func eyebrow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = InkfallDesign.ember
        return label
    }

    private func title(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func subtitle(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func trustCard(_ heading: String, _ body: String) -> NSView {
        let card = CardView(cornerRadius: 10)

        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let bodyLabel = SettingsControls.bodyLabel(body)
        bodyLabel.preferredMaxLayoutWidth = 360

        let stack = NSStackView(views: [headingLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            card.widthAnchor.constraint(equalToConstant: 400)
        ])
        return card
    }

    // MARK: Navigation

    @objc private func advance() {
        if step == .ready {
            finish()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
            renderStep()
        }
    }

    @objc private func back() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
            renderStep()
        }
    }

    private func finish() {
        var updated = config
        updated.onboardingCompleted = true

        try? updated.save()
        config = updated
        onSave(updated)
        onFinished()
        stopPolling()
        window?.close()
    }

    // MARK: Actions

    @objc private func grantMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refreshPermissions() }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Permissions polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshPermissions() {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micStatus.set(micOK ? "Granted" : "Not granted", tone: micOK ? .ok : .warning)
        let axOK = AXIsProcessTrusted()
        accessibilityStatus.set(axOK ? "Granted" : "Not granted", tone: axOK ? .ok : .warning)

        // The Ready page shows a note about ungranted permissions; re-render it
        // if a grant flips while the user is looking at it.
        if step == .ready, let last = lastKnownGrants, last != (micOK, axOK) {
            renderStep()
        }
        lastKnownGrants = (micOK, axOK)
    }

    /// Proactively fire the OS permission prompts once when the permissions page
    /// first appears, so the user is actually asked for everything the app needs
    /// (mic access in-app; Accessibility opens the system prompt to grant).
    private func promptForPermissions() {
        guard !didPromptPermissions else { return }
        didPromptPermissions = true

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refreshPermissions() }
            }
        }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

}
