import AppKit
import QuartzCore

struct IdeaDraftStore {
    let directory: URL
    init(directory: URL = TextNote.folder) { self.directory = directory }
    var url: URL { directory.appendingPathComponent(".sideline-idea-draft.txt") }
    func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func save(_ text: String) throws {
        if text.isEmpty { try clear(); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

final class IdeaInputView: LiveMarkdownTextView {
    var onDismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (L("Write down an idea…") as NSString).draw(in: NSRect(x: 17, y: 12, width: max(1, bounds.width - 34), height: 40),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }
}

final class IdeaComposerPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 300, height: 240)
        animationBehavior = .none
        title = L("Idea")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IdeaComposer: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let draft: IdeaDraftStore
    let textView = IdeaInputView()
    let scrollView = NSScrollView()
    let submitButton = NSButton(title: L("Hang idea"), target: nil, action: nil)
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: L("Idea"))
    private let symbol = NSImageView(image: NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)!)
    private let hint = NSTextField(labelWithString: L("⌘↩ Hang · Esc Save draft"))
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var panel: IdeaComposerPanel?
    private(set) var isOpen = false
    private var saveTimer: Timer?
    var onCommit: ((String) throws -> Void)?
    var onDidClose: (() -> Void)?

    init(draft: IdeaDraftStore = IdeaDraftStore()) { self.draft = draft; super.init() }

    func owns(_ window: NSWindow?) -> Bool { panel != nil && panel === window }

    static func centeredFrame(in area: NSRect) -> NSRect {
        let size = NSSize(width: min(460, max(1, area.width - 60)), height: min(360, max(1, area.height - 80)))
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    func prepare() { if panel == nil { buildPanel() } }

    static func openingTransform(scale: CGFloat, size: CGSize, anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: size.width * (0.5 - anchor.x) * (1 - scale),
            ty: size.height * (0.5 - anchor.y) * (1 - scale))
    }

    private func animateOpening() {
        guard let view = panel?.contentView, let layer = view.layer else { return }
        layer.removeAnimation(forKey: "ideaOpening")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.20
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.duration = 0.34
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            group.duration = fade.duration
            group.animations = [fade]
        } else {
            let scale = CAKeyframeAnimation(keyPath: "transform")
            scale.values = [CGFloat(0.84), 1.015, 1].map {
                NSValue(caTransform3D: CATransform3DMakeAffineTransform(Self.openingTransform(scale: $0, size: view.bounds.size, anchor: layer.anchorPoint)))
            }
            scale.keyTimes = [0, 0.78, 1]
            scale.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.27, 1), CAMediaTimingFunction(name: .easeInEaseOut)]
            scale.duration = group.duration
            group.animations = [scale, fade]
        }
        layer.add(group, forKey: "ideaOpening")
    }

    func show(on screen: NSScreen? = nil, orderFront: Bool = true) {
        if isOpen { focus(); return }
        prepare()
        guard let panel else { return }
        let area = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel.setFrame(Self.centeredFrame(in: area), display: false)
        textView.disableLiveMarkdown()
        textView.string = draft.read()
        textView.enableLiveMarkdown(size: 17, color: NSColor(calibratedWhite: 0.16, alpha: 1))
        errorLabel.stringValue = ""
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        panel.contentView?.layoutSubtreeIfNeeded()
        layoutText()
        updateSubmit()
        isOpen = true
        if orderFront {
            animateOpening()
            panel.orderFrontRegardless()
            focus()
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    func focus() { panel?.makeKey(); panel?.makeFirstResponder(textView) }

    @discardableResult
    func saveDraft() -> Bool {
        saveTimer?.invalidate()
        do { try draft.save(textView.string); return true }
        catch { errorLabel.stringValue = L("Could not save draft"); return false }
    }

    @discardableResult
    func dismiss() -> Bool {
        guard isOpen else { return true }
        guard saveDraft() else { focus(); return false }
        closePanel()
        return true
    }

    @discardableResult
    func submit() -> Bool {
        guard !textView.hasMarkedText(), !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard saveDraft(), let onCommit else { return false }
        do { try onCommit(textView.string) }
        catch { errorLabel.stringValue = error.localizedDescription; return false }
        // The note now exists. Keep a cleanup error from causing a second
        // submission of the same idea; a later save will replace the draft.
        try? draft.clear()
        textView.string = ""
        closePanel()
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.liveSelectionChanged()
    }

    func textDidChange(_ notification: Notification) {
        textView.needsDisplay = true
        layoutText()
        updateSubmit()
        errorLabel.stringValue = ""
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.saveDraft() }
        }
    }

    private func layoutText() {
        scrollView.tile()
        let width = max(1, scrollView.contentSize.width)
        let viewport = max(1, scrollView.contentSize.height)
        textView.setFrameSize(NSSize(width: width, height: max(viewport, textView.frame.height)))
        textView.minSize = NSSize(width: 0, height: viewport)
        textView.textContainer?.containerSize = NSSize(width: max(1, width - 24), height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            textView.setFrameSize(NSSize(width: width, height: max(viewport, ceil(manager.usedRect(for: container).height) + 24)))
        }
    }

    func windowDidResize(_ notification: Notification) { panel?.contentView?.layoutSubtreeIfNeeded(); layoutText() }

    func windowDidResignKey(_ notification: Notification) {
        // Let input-method candidates finish their focus/marked-text update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen, self.panel?.isKeyWindow == false,
                  !self.textView.hasMarkedText() else { return }
            _ = self.dismiss()
        }
    }

    private func closePanel() {
        saveTimer?.invalidate()
        isOpen = false
        panel?.orderOut(nil)
        panel?.contentView?.layer?.removeAnimation(forKey: "ideaOpening")
        onDidClose?()
    }

    private func updateSubmit() { submitButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func buildPanel() {
        let panel = IdeaComposerPanel()
        panel.delegate = self
        // Clip the entire content subtree, including the material and its
        // edge pixels. The window itself stays clear and has no resize trim.
        let clip = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.clear.cgColor
        clip.layer?.cornerRadius = 24
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0
        let surface = FrostedNoteSurface(frame: clip.bounds)
        surface.setTint(nil)
        surface.layer?.cornerRadius = 0
        surface.autoresizingMask = [.width, .height]
        clip.addSubview(surface)
        panel.contentView = clip
        for view in [symbol, titleLabel, closeButton, scrollView, hint, errorLabel, submitButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        symbol.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        closeButton.setAccessibilityLabel(L("Save draft and close"))
        submitButton.bezelStyle = .rounded
        submitButton.target = self
        submitButton.action = #selector(submitAction)
        submitButton.keyEquivalent = "\r"
        submitButton.keyEquivalentModifierMask = .command
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        textView.insertionPointColor = .darkGray
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.onLiveLayoutChange = { [weak self] in self?.layoutText() }
        textView.setAccessibilityLabel(L("Idea text"))
        textView.onDismiss = { [weak self] in _ = self?.dismiss() }
        scrollView.documentView = textView
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            symbol.topAnchor.constraint(equalTo: surface.topAnchor, constant: 22),
            symbol.widthAnchor.constraint(equalToConstant: 16), symbol.heightAnchor.constraint(equalToConstant: 19),
            titleLabel.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8), titleLabel.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18), closeButton.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24), closeButton.heightAnchor.constraint(equalToConstant: 24),
            scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18), scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: surface.topAnchor, constant: 57), scrollView.bottomAnchor.constraint(equalTo: submitButton.topAnchor, constant: -16),
            submitButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24), submitButton.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -21),
            submitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88), submitButton.heightAnchor.constraint(equalToConstant: 30),
            hint.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 28), hint.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor), errorLabel.bottomAnchor.constraint(equalTo: submitButton.topAnchor, constant: -2),
        ])
        self.panel = panel
    }

    @objc private func closeAction() { _ = dismiss() }
    @objc private func submitAction() { _ = submit() }
}
