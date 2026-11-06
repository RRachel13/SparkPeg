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
    static let ideaHeader: CGFloat = 20
    static let collapsedBottom: CGFloat = 10
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

final class ExpandedNoteTextView: LiveMarkdownTextView {
    var onAsk: (() -> Void)?
    var onCollapse: (() -> Void)?
    var placeholder: String?
    var onReadMenu: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        onReadMenu != nil || super.acceptsFirstMouse(for: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let onReadMenu { onReadMenu(event) }
        else { super.rightMouseDown(with: event) }
    }
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
        guard isEditable else { return super.menu(for: event) }
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
    private let excerptMore = NSTextField(labelWithString: "…")
    private let remarkMore = NSTextField(labelWithString: "…")
    private let readingOnly: Bool
    private let noteColor: NSColor
    private var rendersMarkdown: Bool { !isExpanded }
    private var scrolls: Bool { isExpanded || readingOnly }
    var isTruncated: Bool { !excerptMore.isHidden || !remarkMore.isHidden }
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

    init(url: URL, text: String, fontSize: CGFloat, remark: String? = nil, kind: NoteKind? = nil,
         readingOnly: Bool = false, followsAppearance: Bool = false) {
        self.url = url
        self.readingOnly = readingOnly
        noteColor = followsAppearance ? .labelColor : NSColor(calibratedWhite: 0.14, alpha: 1)
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
        if !followsAppearance { appearance = NSAppearance(named: .aqua) }
        scrollView.hasVerticalScroller = readingOnly
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
        configure(textView, label: L("Note text"))
        configure(remarkView, label: L("Note remark"))
        remarkView.placeholder = L("Write a remark…")
        displaySavedContent()
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
        for label in [excerptMore, remarkMore] {
            label.isHidden = true
            label.alignment = .left
            label.setAccessibilityLabel(L("More text"))
            document.addSubview(label)
        }
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

    private func configure(_ view: ExpandedNoteTextView, label: String) {
        view.onLiveLayoutChange = { [weak self] in self?.needsLayout = true }
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: currentFontSize)
        view.textColor = noteColor
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
        view.isEditable = false
        view.isSelectable = readingOnly
        view.delegate = self
        view.setAccessibilityLabel(label)
        view.onCollapse = { [weak self] in
            guard let self, self.saveNow() else { return }
            self.onCollapse?()
        }
        view.onAsk = { [weak self] in
            guard let self, self.saveNow() else { return }
            GPTDraftLink.open(self.saved.text)
        }
    }

    private func display(_ source: String, in view: ExpandedNoteTextView, color: NSColor) {
        view.disableLiveMarkdown()
        view.font = .systemFont(ofSize: currentFontSize)
        view.defaultParagraphStyle = NoteTypography.paragraph(fontSize: currentFontSize)
        view.textColor = color
        if rendersMarkdown {
            view.textStorage?.setAttributedString(NoteMarkdown.render(source, size: currentFontSize, color: color))
        } else {
            view.string = source
            view.enableLiveMarkdown(size: currentFontSize, color: color)
        }
    }

    private func displaySavedContent() {
        display(saved.text, in: textView, color: noteColor)
        display(saved.remark, in: remarkView, color: RemarkAppearance.color())
        remarkView.insertionPointColor = RemarkAppearance.color()
        needsLayout = true
    }

    private func updateRemarkColor() {
        let color = RemarkAppearance.color()
        if rendersMarkdown {
            display(saved.remark, in: remarkView, color: color)
        } else {
            remarkView.enableLiveMarkdown(size: currentFontSize, color: color)
        }
        remarkView.insertionPointColor = color
    }

    func setKindMarkVisible(_ visible: Bool) { showKindMark = visible; needsLayout = true }

    func setFontSize(_ size: CGFloat) {
        guard size != currentFontSize else { return }
        currentFontSize = size
        display(rendersMarkdown ? saved.text : textView.string, in: textView, color: noteColor)
        updateRemarkColor()
        needsLayout = true
    }

    func setExpanded(_ expanded: Bool) {
        guard !readingOnly, expanded != isExpanded else { return }
        if !expanded && !saveNow() { return }
        isExpanded = expanded
        for view in [textView, remarkView] {
            view.isEditable = expanded
            view.isSelectable = expanded || readingOnly
        }
        displaySavedContent()
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
        displaySavedContent()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        (notification.object as? LiveMarkdownTextView)?.liveSelectionChanged()
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
        guard !rendersMarkdown else { return true }
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

    private var header: CGFloat { saved.kind == .idea ? NoteExpansionLayout.ideaHeader : 0 }
    private var hasRemark: Bool {
        !(rendersMarkdown ? saved.remark : remarkView.string).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (isExpanded && isAddingRemark)
    }

    /// Size the folded card from the same text layout used when it draws.
    func preferredHeight(width: CGFloat) -> CGFloat {
        var height = textHeight(textView, width: width) + header
        if hasRemark { height += 6 + textHeight(remarkView, width: width) }
        return height + (scrolls ? 0 : NoteExpansionLayout.collapsedBottom)
    }

    /// End the preview at a complete glyph line and mark the hidden remainder.
    private func previewHeight(_ view: NSTextView, natural: CGFloat, budget: CGFloat,
                               marker: NSTextField, y: CGFloat, width: CGFloat) -> CGFloat {
        marker.isHidden = natural <= budget
        guard natural > budget, let manager = view.layoutManager, let container = view.textContainer else {
            return min(natural, budget)
        }
        let markerHeight = ceil(currentFontSize * 1.15)
        let top = view.textContainerInset.height
        var last: CGFloat = 0
        let limit = max(0, budget - top - markerHeight)
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, stop in
            if used.maxY > limit { stop.pointee = true }
            else { last = used.maxY }
        }
        marker.font = .systemFont(ofSize: currentFontSize)
        marker.textColor = view === remarkView ? RemarkAppearance.color() : noteColor.withAlphaComponent(0.65)
        marker.frame = NSRect(x: view.textContainerInset.width + 5, y: y + top + last,
                              width: max(1, width - 26), height: markerHeight)
        return min(budget, top + last + markerHeight)
    }

    override func layout() {
        super.layout()
        let footer = isExpanded ? NoteExpansionLayout.footerHeight : 0
        let bottom = scrolls ? 0 : NoteExpansionLayout.collapsedBottom
        kindMark.isHidden = saved.kind != .idea || !showKindMark
        kindMark.frame = NSRect(x: 11, y: bounds.height - 18, width: 12, height: 12)
        scrollView.frame = NSRect(x: 0, y: footer + bottom, width: bounds.width,
                                  height: max(1, bounds.height - footer - bottom - header))
        scrollView.tile()
        let width = scrollView.contentSize.width
        let viewport = scrollView.contentSize.height
        let sourceHeight = textHeight(textView, width: width)
        let hasRemark = self.hasRemark
        let remarkHeight = hasRemark ? textHeight(remarkView, width: width) : 0
        let quoteHeight: CGFloat
        excerptMore.isHidden = true
        remarkMore.isHidden = true
        if scrolls {
            quoteHeight = max(sourceHeight, hasRemark ? 36 : viewport)
        } else {
            let reserved = hasRemark ? 6 + min(remarkHeight, currentFontSize * 3 + 18) : 0
            let budget = max(1, viewport - reserved)
            quoteHeight = sourceHeight > budget
                ? previewHeight(textView, natural: sourceHeight, budget: budget, marker: excerptMore, y: 0, width: width)
                : (hasRemark ? sourceHeight : viewport)
        }
        let quoteClipHeight = excerptMore.isHidden ? quoteHeight : excerptMore.frame.minY
        excerptClip.frame = NSRect(x: 0, y: 0, width: width, height: quoteClipHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(sourceHeight, quoteHeight))
        divider.isHidden = !hasRemark
        remarkClip.isHidden = !hasRemark
        var documentHeight = quoteHeight
        if hasRemark {
            divider.frame = NSRect(x: 10, y: quoteHeight + 2, width: max(1, width - 20), height: 0.5)
            let remarkTop = quoteHeight + 6
            let visibleHeight = scrolls ? max(isExpanded ? 80 : 0, remarkHeight)
                : previewHeight(remarkView, natural: remarkHeight, budget: max(1, viewport - remarkTop),
                                marker: remarkMore, y: remarkTop, width: width)
            let clipHeight = remarkMore.isHidden ? visibleHeight : remarkMore.frame.minY - remarkTop
            remarkClip.frame = NSRect(x: 0, y: remarkTop, width: width, height: clipHeight)
            remarkView.frame = NSRect(x: 0, y: 0, width: width, height: max(remarkHeight, visibleHeight))
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
