import AppKit
import SwiftUI

/// One shape and one text control remain on the line throughout expansion.
enum NoteExpansionLayout {
    static func expandedSize(collapsed: CGSize, availableHeight: CGFloat) -> CGSize {
        CGSize(width: min(280, collapsed.width * 1.35),
               height: min(560, max(collapsed.height, availableHeight - 100)))
    }

    static func fontSize(scale: CGFloat) -> CGFloat { 11.5 * scale }
    static let footerHeight: CGFloat = 30
}

/// The same paragraph style is used on the card, while editing and in flight.
enum NoteTypography {
    static func paragraph(fontSize: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.32
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

class FrostedNoteSurface: NSVisualEffectView {
    private let tint = NSView()
    func setTint(_ color: NSColor?) { tint.layer?.backgroundColor = color?.withAlphaComponent(0.45).cgColor ?? NSColor.clear.cgColor }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        // The SwiftUI card owns the one border; a second bright native border
        // used to leave white seams around the lower corners.
        layer?.borderWidth = 0
        tint.wantsLayer = true
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct FrostedNoteBackground: NSViewRepresentable {
    var tint: NSColor? = nil
    func makeNSView(context: Context) -> FrostedNoteSurface {
        let view = FrostedNoteSurface(frame: .zero)
        view.setTint(tint)
        return view
    }
    func updateNSView(_ nsView: FrostedNoteSurface, context: Context) { nsView.setTint(tint) }
}

@MainActor
enum TextNoteEditor {
    private static weak var active: InlineNoteBody?
    static var isOpen: Bool { active?.isExpanded == true }
    static var activeURL: URL? { active?.url }

    static func activate(_ view: InlineNoteBody) { active = view }
    static func deactivate(_ view: InlineNoteBody) { if active === view { active = nil } }
    static func flush() { _ = active?.saveNow() }

    /// Card rectangles and the point are in the panel's flipped coordinates.
    /// A missing layout must not dismiss an editor which has just opened.
    @discardableResult
    static func collapseIfOutside(_ point: CGPoint, cardRect: CGRect?, menuIsTracking: Bool = false) -> Bool {
        guard isOpen, !menuIsTracking, let cardRect, !cardRect.isNull, !cardRect.isEmpty,
              !cardRect.insetBy(dx: -4, dy: -4).contains(point) else { return false }
        return collapseActive()
    }

    @discardableResult
    static func collapseActive(animated: Bool = true) -> Bool {
        guard let active else { return true }
        guard active.saveNow() else { NSSound.beep(); return false }
        active.onCollapse?()
        return true
    }
}

struct InlineNoteEditor: NSViewRepresentable {
    let url: URL
    let expanded: Bool
    let fontSize: CGFloat
    var remarkRequest: Int = 0
    var kind: NoteKind = .excerpt
    var showKindMark = true
    let onSaved: () -> Void
    let onCollapse: () -> Void

    func makeNSView(context: Context) -> InlineNoteBody {
        let view = InlineNoteBody(url: url, text: TextNote.read(url) ?? "", fontSize: fontSize, kind: kind)
        view.setKindMarkVisible(showKindMark)
        view.onSaved = onSaved
        view.onCollapse = onCollapse
        view.setExpanded(expanded)
        view.requestRemark(remarkRequest)
        return view
    }

    func updateNSView(_ view: InlineNoteBody, context: Context) {
        view.onSaved = onSaved
        view.onCollapse = onCollapse
        view.setFontSize(fontSize)
        view.setKindMarkVisible(showKindMark)
        view.setExpanded(expanded)
        view.requestRemark(remarkRequest)
        view.refreshIfNotEditing()
    }

    static func dismantleNSView(_ view: InlineNoteBody, coordinator: ()) {
        _ = view.saveNow()
        TextNoteEditor.deactivate(view)
    }
}

final class ExpandedNoteTextView: NSTextView {
    var onAsk: (() -> Void)?
    var onCollapse: (() -> Void)?
    var placeholder: String?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder {
            (placeholder as NSString).draw(in: NSRect(x: textContainerInset.width + 5, y: textContainerInset.height,
                width: max(1, bounds.width - 26), height: 40), withAttributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 0.65)])
        }
    }
    override func cancelOperation(_ sender: Any?) { onCollapse?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Ask GPT")) { [weak self] in self?.onAsk?() })
        menu.addItem(ClosureMenuItem(L("Collapse note")) { [weak self] in self?.onCollapse?() })
        return menu
    }
}

/// A flipped document keeps the excerpt, separator and remark in one scroll
/// flow. The original text control survives every expansion and collapse.
private final class NoteFlowView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class InlineNoteBody: NSView, NSTextViewDelegate {
    let url: URL
    let scrollView = NSScrollView()
    let textView = ExpandedNoteTextView()
    let remarkView = ExpandedNoteTextView()
    let divider = NSView()
    let kindMark = NSImageView(image: NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)!)
    private var showKindMark = true
    private let document = NoteFlowView()
    private let excerptClip = NoteFlowView()
    private let remarkClip = NoteFlowView()
    let collapseButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!, target: nil, action: nil)
    private(set) var isExpanded = false
    private(set) var isAddingRemark = false
    private var saved: NoteDocument
    private var saveTimer: Timer?
    private var colorObserver: NSObjectProtocol?
    private var currentFontSize: CGFloat
    private var lastRemarkRequest = 0
    private var wantsRemarkFocus = false
    var onSaved: (() -> Void)?
    var onCollapse: (() -> Void)?

    init(url: URL, text: String, fontSize: CGFloat, remark: String? = nil, kind: NoteKind? = nil) {
        self.url = url
        let stored = remark == nil || kind == nil ? try? NoteDocument.read(url) : nil
        let remark = remark ?? stored?.remark ?? ""
        saved = NoteDocument(text: text, remark: remark, kind: kind ?? stored?.kind ?? .excerpt,
                             colorHex: stored?.colorHex ?? NoteDocument.colorHex(from: url))
        currentFontSize = fontSize
        super.init(frame: NSRect(x: 0, y: 0, width: 136, height: 91))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .aqua)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        for clip in [excerptClip, remarkClip] {
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
        }
        configure(textView, text: text, label: L("Note text"))
        configure(remarkView, text: remark, label: L("Note remark"))
        remarkView.placeholder = L("Write a remark…")
        updateRemarkColor()
        colorObserver = NotificationCenter.default.addObserver(forName: RemarkAppearance.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRemarkColor() }
        }
        excerptClip.addSubview(textView)
        remarkClip.addSubview(remarkView)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 0.16).cgColor
        document.addSubview(excerptClip)
        document.addSubview(divider)
        document.addSubview(remarkClip)
        scrollView.documentView = document
        addSubview(scrollView)
        collapseButton.target = self
        collapseButton.action = #selector(collapseNote)
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.setAccessibilityLabel(L("Collapse note"))
        collapseButton.toolTip = L("Collapse note · Esc")
        collapseButton.isHidden = true
        addSubview(collapseButton)
        kindMark.contentTintColor = NSColor(srgbRed: 0.68, green: 0.43, blue: 0.12, alpha: 0.85)
        kindMark.setAccessibilityLabel(L("Idea"))
        addSubview(kindMark)
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        saveTimer?.invalidate()
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
    }

    private func configure(_ view: ExpandedNoteTextView, text: String, label: String) {
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: currentFontSize)
        view.textColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        view.insertionPointColor = .darkGray
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = NSSize(width: 8, height: 9)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 120, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.string = text
        applyParagraphStyle(to: view)
        view.isEditable = false
        view.isSelectable = false
        view.delegate = self
        view.setAccessibilityLabel(label)
        view.onCollapse = { [weak self] in
            guard let self, self.saveNow() else { return }
            self.onCollapse?()
        }
        view.onAsk = { [weak self] in
            guard let self, self.saveNow() else { return }
            GPTDraftLink.open(self.textView.string)
        }
    }

    private func applyParagraphStyle(to view: NSTextView) {
        let style = NoteTypography.paragraph(fontSize: currentFontSize)
        view.defaultParagraphStyle = style
        view.typingAttributes[.paragraphStyle] = style
        view.textStorage?.addAttribute(.paragraphStyle, value: style,
                                      range: NSRange(location: 0, length: view.string.utf16.count))
    }

    private func updateRemarkColor() {
        remarkView.textColor = RemarkAppearance.color()
        remarkView.insertionPointColor = RemarkAppearance.color()
        remarkView.typingAttributes[.foregroundColor] = RemarkAppearance.color()
    }

    func setKindMarkVisible(_ visible: Bool) { showKindMark = visible; needsLayout = true }

    func setFontSize(_ size: CGFloat) {
        guard size != currentFontSize else { return }
        currentFontSize = size
        textView.font = .systemFont(ofSize: size)
        remarkView.font = .systemFont(ofSize: size)
        applyParagraphStyle(to: textView)
        applyParagraphStyle(to: remarkView)
        needsLayout = true
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        if !expanded { _ = saveNow() }
        isExpanded = expanded
        for view in [textView, remarkView] { view.isEditable = expanded; view.isSelectable = expanded }
        scrollView.hasVerticalScroller = expanded
        collapseButton.isHidden = !expanded
        if expanded {
            TextNoteEditor.activate(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.isExpanded, !self.wantsRemarkFocus, let window = self.window else { return }
                window.makeKey()
                if window.firstResponder !== self.textView && window.firstResponder !== self.remarkView {
                    window.makeFirstResponder(self.textView)
                }
            }
        } else {
            isAddingRemark = false
            wantsRemarkFocus = false
            TextNoteEditor.deactivate(self)
            if window?.firstResponder === textView || window?.firstResponder === remarkView { window?.makeFirstResponder(nil) }
            scrollView.contentView.scroll(to: .zero)
        }
        needsLayout = true
    }

    func requestRemark(_ request: Int) {
        guard isExpanded, request > 0, request != lastRemarkRequest else { return }
        lastRemarkRequest = request
        beginRemark()
    }

    func beginRemark() {
        guard isExpanded else { return }
        isAddingRemark = true
        wantsRemarkFocus = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isExpanded, self.wantsRemarkFocus, let window = self.window else { return }
            self.layoutSubtreeIfNeeded()
            window.makeKey()
            window.makeFirstResponder(self.remarkView)
            self.remarkView.setSelectedRange(NSRange(location: self.remarkView.string.utf16.count, length: 0))
            self.remarkView.scrollRangeToVisible(self.remarkView.selectedRange())
            self.wantsRemarkFocus = false
        }
    }

    func refreshIfNotEditing() {
        guard !isExpanded, let updated = try? NoteDocument.read(url), updated != saved else { return }
        saved = updated
        textView.string = updated.text
        remarkView.string = updated.remark
        applyParagraphStyle(to: textView)
        applyParagraphStyle(to: remarkView)
        updateRemarkColor()
        needsLayout = true
    }

    func textDidChange(_ notification: Notification) {
        needsLayout = true
        remarkView.needsDisplay = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.saveNow() }
        }
    }

    @discardableResult
    func saveNow() -> Bool {
        saveTimer?.invalidate()
        let remark = remarkView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : remarkView.string
        let updated = NoteDocument(text: textView.string, remark: remark, kind: saved.kind, colorHex: saved.colorHex)
        guard updated != saved else { return true }
        do {
            try updated.write(to: url)
            saved = updated
            onSaved?()
            textView.toolTip = nil
            remarkView.toolTip = nil
            return true
        } catch {
            textView.toolTip = L("Could not save note")
            remarkView.toolTip = L("Could not save note")
            NSSound.beep()
            return false
        }
    }

    private func textHeight(_ view: NSTextView, width: CGFloat) -> CGFloat {
        view.setFrameSize(NSSize(width: width, height: max(1, view.frame.height)))
        view.textContainer?.containerSize = NSSize(width: max(1, width - view.textContainerInset.width * 2),
                                                  height: CGFloat.greatestFiniteMagnitude)
        guard let container = view.textContainer, let manager = view.layoutManager else { return 40 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + view.textContainerInset.height * 2
    }

    override func layout() {
        super.layout()
        // Reserve only the bottom edge for controls. The top text position
        // never changes, so expansion needs no separate text translation.
        let footer = isExpanded ? NoteExpansionLayout.footerHeight : 0
        let header: CGFloat = saved.kind == .idea ? 20 : 0
        kindMark.isHidden = saved.kind != .idea || !showKindMark
        kindMark.frame = NSRect(x: 11, y: bounds.height - 18, width: 12, height: 12)
        scrollView.frame = NSRect(x: 0, y: footer, width: bounds.width, height: max(1, bounds.height - footer - header))
        scrollView.tile()
        let width = scrollView.contentSize.width
        let viewport = scrollView.contentSize.height
        let hasRemark = !remarkView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isExpanded && isAddingRemark)
        let sourceHeight = textHeight(textView, width: width)
        let quoteHeight = isExpanded ? max(sourceHeight, hasRemark ? 36 : viewport) : (hasRemark ? floor(viewport * 0.57) : viewport)
        excerptClip.frame = NSRect(x: 0, y: 0, width: width, height: quoteHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(sourceHeight, quoteHeight))
        divider.isHidden = !hasRemark
        remarkClip.isHidden = !hasRemark
        var documentHeight = quoteHeight
        if hasRemark {
            divider.frame = NSRect(x: 10, y: quoteHeight + 2, width: max(1, width - 20), height: 0.5)
            let remarkTop = quoteHeight + 6
            let height = textHeight(remarkView, width: width)
            let visibleHeight = isExpanded ? max(80, height) : max(1, viewport - remarkTop)
            remarkClip.frame = NSRect(x: 0, y: remarkTop, width: width, height: visibleHeight)
            remarkView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, visibleHeight))
            documentHeight = remarkTop + visibleHeight + (isExpanded ? 24 : 0)
        }
        document.setFrameSize(NSSize(width: width, height: max(viewport, documentHeight)))
        collapseButton.frame = NSRect(x: 7, y: 3, width: 23, height: 23)
    }

    @objc private func collapseNote() {
        guard saveNow() else { return }
        onCollapse?()
    }
}
