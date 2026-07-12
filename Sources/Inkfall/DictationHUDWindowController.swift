import AppKit

// A nonactivating panel that must NEVER become key/main, or it would change which
// app receives the pasted text.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DictationHUDWindowController: NSWindowController {
    var audioLevelProvider: (() -> Float)?
    var onAction: ((HUDAction) -> Void)?
    var onHidden: (() -> Void)?

    /// Where the HUD anchors on the active screen. Set from config.
    var anchor: HUDPosition = .topCenter

    private let card = HUDCardView()
    private var hideWorkItem: DispatchWorkItem?
    /// True while a real dictation HUD is on screen, so a Settings position preview
    /// knows to stand down rather than clobber (and silently dismiss) it.
    private var showingRealHUD = false

    init() {
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 78),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = card

        super.init(window: panel)

        card.onAction = { [weak self] action in self?.onAction?(action) }
        card.levelProvider = { [weak self] in self?.audioLevelProvider?() ?? 0 }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(state: DictationState) {
        guard let model = state.hud else { hide(); return }
        hideWorkItem?.cancel()

        card.apply(model)
        showingRealHUD = true
        let size = NSSize(width: model.width, height: 78)
        position(for: size, anchor: anchor)
        window?.orderFrontRegardless()
        window?.ignoresMouseEvents = model.informational

        if shouldAutoHide(model) {
            scheduleHide()
        }
    }

    func hide(notify: Bool = false) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        showingRealHUD = false
        card.teardown()
        window?.orderOut(nil)
        if notify { onHidden?() }
    }

    // MARK: Auto-hide + hover-to-persist

    private func shouldAutoHide(_ model: HUDModel) -> Bool {
        !model.persistent && !model.informational
    }

    private func scheduleHide() {
        let item = DispatchWorkItem { [weak self] in self?.hide(notify: true) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + InkfallMotion.dwell, execute: item)
    }

    private func position(for size: NSSize, anchor: HUDPosition) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen, let window else { return }
        let frame = screen.visibleFrame
        let side: CGFloat = 12
        let topGap: CGFloat = 34
        let bottomGap: CGFloat = 24

        let x: CGFloat
        switch anchor.horizontal {
        case .leading: x = frame.minX + side
        case .center: x = frame.midX - size.width / 2
        case .trailing: x = frame.maxX - size.width - side
        }
        let clampedX = min(max(x, frame.minX + side), frame.maxX - size.width - side)

        let y: CGFloat
        switch anchor.vertical {
        case .top: y = frame.maxY - size.height - topGap
        case .bottom: y = frame.minY + bottomGap
        }
        window.setFrame(NSRect(x: clampedX, y: y, width: size.width, height: size.height), display: true)
    }

    /// Flash a sample card at `position` so the user sees where it lands while picking
    /// in Settings. Positional only — it does NOT change the saved `anchor`, so an
    /// unsaved preview never leaks into the next real dictation. Auto-hides.
    func preview(at newAnchor: HUDPosition) {
        // Never disturb a live dictation / error / permission HUD — the preview is a
        // convenience for an idle moment, not something worth dismissing real UI for.
        guard !showingRealHUD else { return }
        hideWorkItem?.cancel()
        let model = HUDModel(
            symbol: "viewfinder",
            tint: InkfallDesign.ember,
            title: "Indicator",
            detail: "Appears here while you dictate",
            informational: true
        )
        card.apply(model)
        position(for: NSSize(width: model.width, height: 78), anchor: newAnchor)
        window?.orderFrontRegardless()
        window?.ignoresMouseEvents = true
        let item = DispatchWorkItem { [weak self] in self?.hide(notify: false) }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }
}

private extension HUDModel {
    var width: CGFloat {
        if isPeek { return 540 }
        if action != nil { return 524 }
        return 460
    }
}

@MainActor
private protocol HUDAnimating: AnyObject {
    func start()
    func stop()
}

// MARK: - Card

private final class HUDCardView: NSVisualEffectView {
    var onAction: ((HUDAction) -> Void)?
    var levelProvider: (() -> Float)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let rightCluster = NSStackView()
    private var currentAction: HUDAction?
    private var animating: HUDAnimating?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        build()
        applyTransparencyFallback()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        rightCluster.orientation = .horizontal
        rightCluster.alignment = .centerY
        rightCluster.spacing = 10

        let row = NSStackView(views: [iconView, textStack, NSView.spacer(), rightCluster])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    func apply(_ model: HUDModel) {
        iconView.image = symbolImage(model.symbol, tint: model.tint, title: model.title)

        titleLabel.stringValue = model.title
        detailLabel.stringValue = model.detail
        detailLabel.isHidden = model.detail.isEmpty
        detailLabel.font = model.isPeek
            ? NSFont.systemFont(ofSize: 13).withItalic()
            : NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = model.isPeek ? .labelColor : .secondaryLabelColor

        rebuildRightCluster(model)
    }

    func teardown() {
        animating?.stop()
        animating = nil
    }

    private func rebuildRightCluster(_ model: HUDModel) {
        animating?.stop()
        animating = nil
        rightCluster.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch model.accessory {
        case .none:
            break
        case let .waveform(flat):
            let view = HUDWaveformView()
            view.tintColor = model.tint
            view.flat = flat
            view.levelProvider = levelProvider
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 92).isActive = true
            view.heightAnchor.constraint(equalToConstant: 28).isActive = true
            rightCluster.addArrangedSubview(view)
            view.start()
            animating = view
        case .ellipsis:
            let view = HUDEllipsisView()
            view.tintColor = model.tint
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 34).isActive = true
            view.heightAnchor.constraint(equalToConstant: 28).isActive = true
            rightCluster.addArrangedSubview(view)
            view.start()
            animating = view
        case let .progress(fraction):
            let bar = HUDProgressBar()
            bar.fraction = CGFloat(fraction)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 118).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            rightCluster.addArrangedSubview(bar)
        }

        if let label = model.actionLabel, let action = model.action {
            currentAction = action
            let button = NSButton(title: label, target: self, action: #selector(actionTapped))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            if model.emberAction {
                button.bezelColor = InkfallDesign.ember
                button.attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [
                        .foregroundColor: InkfallDesign.emberInk,
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                    ]
                )
            }
            rightCluster.addArrangedSubview(button)
        } else {
            currentAction = nil
        }

        if model.showsLocalPill {
            rightCluster.addArrangedSubview(LocalPillView())
        }
    }

    @objc private func actionTapped() {
        guard let action = currentAction else { return }
        onAction?(action)
    }

    private func symbolImage(_ name: String, tint: NSColor, title: String) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let config = base.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        return NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
    }

    private func applyTransparencyFallback() {
        if AccessibilityState.shared.reduceTransparency {
            material = .windowBackground
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

// MARK: - Local pill

private final class LocalPillView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = InkfallDesign.ember.cgColor

        let icon = NSImageView()
        icon.image = NSImage.flowSymbol("lock.fill", pointSize: 9, weight: .bold)
        icon.contentTintColor = InkfallDesign.emberInk
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "LOCAL")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = InkfallDesign.emberInk

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 10),
            icon.heightAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = InkfallDesign.ember.cgColor
    }
}

// MARK: - Waveform

private final class HUDWaveformView: NSView, HUDAnimating {
    var tintColor: NSColor = InkfallDesign.blue { didSet { needsDisplay = true } }
    var flat = false
    var levelProvider: (() -> Float)?

    private var levels: [CGFloat]
    private var timer: Timer?
    private let barCount = 13

    override init(frame frameRect: NSRect) {
        levels = Array(repeating: 0.08, count: 13)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        guard timer == nil else { return }
        if AccessibilityState.shared.reduceMotion {
            needsDisplay = true
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let raw = flat ? 0.05 : CGFloat(levelProvider?() ?? 0)
        levels.removeFirst()
        let shimmer = flat ? 0 : CGFloat.random(in: 0...0.08)
        levels.append(min(1, max(0.05, raw + shimmer)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if AccessibilityState.shared.reduceMotion {
            let radius: CGFloat = 5
            let dot = NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
            tintColor.withAlphaComponent(flat ? 0.3 : 0.85).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return
        }

        let gap: CGFloat = 4
        let width = (bounds.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount)
        for index in 0..<barCount {
            let amp = levels[index]
            let height = max(3, amp * bounds.height)
            let rect = NSRect(
                x: CGFloat(index) * (width + gap),
                y: bounds.midY - height / 2,
                width: max(2, width),
                height: height
            )
            tintColor.withAlphaComponent(0.28 + 0.68 * amp).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - Ellipsis pulse (honest "working" indicator)

private final class HUDEllipsisView: NSView, HUDAnimating {
    var tintColor: NSColor = InkfallDesign.purple { didSet { needsDisplay = true } }
    private var phase = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        guard timer == nil else { return }
        if AccessibilityState.shared.reduceMotion { needsDisplay = true; return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.phase += 1
                self?.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = 3
        let radius: CGFloat = 3
        let gap: CGFloat = 6
        let totalWidth = CGFloat(count) * radius * 2 + CGFloat(count - 1) * gap
        var x = bounds.midX - totalWidth / 2
        let reduce = AccessibilityState.shared.reduceMotion
        for index in 0..<count {
            let alpha: CGFloat = reduce ? 0.6 : (0.25 + 0.6 * pulse(for: index))
            tintColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - radius, width: radius * 2, height: radius * 2)).fill()
            x += radius * 2 + gap
        }
    }

    private func pulse(for index: Int) -> CGFloat {
        let value = sin(Double(phase - index) * 0.9)
        return CGFloat(max(0, value))
    }
}

// MARK: - Progress bar

private final class HUDProgressBar: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.18).setFill()
        track.fill()

        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        InkfallDesign.ember.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

private extension NSFont {
    func withItalic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
