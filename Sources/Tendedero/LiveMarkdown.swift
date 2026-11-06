import AppKit
import CoreText

private extension NSAttributedString.Key {
    static let markdownHidden = Self("SparkPegMarkdownHidden")
    static let markdownSymbol = Self("SparkPegMarkdownSymbol")
}

/// Decorates the existing source in place. No displayed marker becomes part
/// of the string, so selections, undo, the input method and saves use source offsets.
final class LiveMarkdownTextViewLayout: NSObject, NSLayoutManagerDelegate {
    private struct Row: Equatable {
        enum Mode: Equatable { case source, markdown, fence, code }
        let text: String
        let mode: Mode
        var length: Int { text.utf16.count }
    }

    private static let prefix = try! NSRegularExpression(pattern: #"^[ \t]*(#{1,6}|[-+*]|[0-9]{1,9}[.)]|>)[ \t]"#)
    private static let fence = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(`{3,}|~{3,})(.*)$"#)
    private static let inlineTokens = CharacterSet(charactersIn: "*_`~[\\&")
    private let base: [NSAttributedString.Key: Any]
    private let size: CGFloat
    private let color: NSColor
    private var rows: [Row] = []

    init(size: CGFloat, color: NSColor) {
        self.size = size
        self.color = color
        base = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
                .paragraphStyle: NoteTypography.paragraph(fontSize: size)]
    }

    static func startsBlock(_ text: String) -> Bool {
        let length = text.utf16.count
        return prefix.firstMatch(in: text, range: NSRange(location: 0, length: length))?.range.length == length
    }

    @MainActor
    func display(in view: NSTextView, showing selection: NSRange?, changedText: Bool = false) {
        guard let storage = view.textStorage, let manager = view.layoutManager else { return }
        let source = storage.string as NSString
        var next: [Row] = []
        var rowRanges: [NSRange] = []
        var codeFence: String?
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let text = source.substring(with: range)
            let line = text.trimmingCharacters(in: .newlines)
            let fenceMatch = Self.fence.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
            var mode = codeFence == nil ? Row.Mode.markdown : .code
            if let fenceMatch {
                let token = (line as NSString).substring(with: fenceMatch.range(at: 1))
                let tail = (line as NSString).substring(with: fenceMatch.range(at: 2))
                if let open = codeFence {
                    if token.first == open.first && token.count >= open.count && tail.trimmingCharacters(in: .whitespaces).isEmpty {
                        codeFence = nil
                        mode = .fence
                    }
                } else if token.first != "`" || !tail.contains("`") {
                    codeFence = token
                    mode = .fence
                }
            }
            if let selection {
                let caretInRow = selection.length == 0 && (NSLocationInRange(selection.location, range)
                    || (selection.location == NSMaxRange(range) && selection.location == source.length && !text.hasSuffix("\n") && !text.hasSuffix("\r")))
                if caretInRow || NSIntersectionRange(selection, range).length > 0 { mode = .source }
            }
            next.append(Row(text: text, mode: mode))
            rowRanges.append(range)
            offset = NSMaxRange(range)
        }

        // Repaint only the rows whose source or presentation changed.
        var leading = 0
        while leading < min(rows.count, next.count), rows[leading] == next[leading] { leading += 1 }
        var trailing = 0
        while trailing < min(rows.count, next.count) - leading,
              rows[rows.count - 1 - trailing] == next[next.count - 1 - trailing] { trailing += 1 }
        var dirty = IndexSet(integersIn: leading..<(next.count - trailing))
        if changedText, let index = rowRanges.lastIndex(where: { $0.location <= view.selectedRange().location }) {
            dirty.insert(index)
            // Splitting or joining a row can leave a neighbor with inherited attributes.
            if index > 0 { dirty.insert(index - 1) }
        }
        rows = next

        if !dirty.isEmpty {
            storage.beginEditing()
            for index in dirty { paint(next[index], in: storage, range: rowRanges[index]) }
            storage.endEditing()
            for indices in dirty.rangeView {
                let range = NSUnionRange(rowRanges[indices.lowerBound], rowRanges[indices.upperBound - 1])
                manager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            }
        }
        view.typingAttributes = base
    }

    private func paint(_ row: Row, in storage: NSTextStorage, range: NSRange) {
        storage.setAttributes(base, range: range)
        guard row.mode != .source else { return }
        let line = row.text.trimmingCharacters(in: .newlines)
        let length = line.utf16.count
        func hide(_ start: Int, _ end: Int) {
            guard start < end else { return }
            storage.addAttribute(.markdownHidden, value: true, range: NSRange(location: range.location + start, length: end - start))
        }
        if row.mode == .fence { hide(0, length); return }
        if row.mode == .code {
            storage.addAttributes(codeAttributes(size: size, weight: .regular),
                                  range: NSRange(location: range.location, length: length))
            return
        }

        var contentStart = 0
        var pointSize = size
        var heading = false
        if let match = Self.prefix.firstMatch(in: line, range: NSRange(location: 0, length: length)) {
            let tokenRange = match.range(at: 1)
            let token = (line as NSString).substring(with: tokenRange)
            contentStart = NSMaxRange(match.range)
            switch token.first {
            case "-","*","+":
                storage.addAttribute(.markdownSymbol, value: "•",
                                     range: NSRange(location: range.location + tokenRange.location, length: 1))
            case ">":
                storage.addAttribute(.markdownSymbol, value: "▏",
                                     range: NSRange(location: range.location + tokenRange.location, length: 1))
            case "#":
                // If all glyphs on an empty heading are hidden, TextKit
                // has no visible row on which to place the insertion caret.
                let title = (line as NSString).substring(from: contentStart)
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                heading = true
                pointSize *= token.count == 1 ? 1.4 : token.count == 2 ? 1.25 : 1.12
                hide(tokenRange.location, contentStart)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize, weight: .semibold), range: range)
            default: break
            }
        }
        let content = (line as NSString).substring(from: contentStart)
        guard content.rangeOfCharacter(from: Self.inlineTokens) != nil,
              let parsed = try? AttributedString(markdown: content, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)),
              !parsed.characters.isEmpty else { return }
        // Foundation's source columns are UTF-8 byte positions. Convert only
        // scalar boundaries to UTF-16 before handing ranges to AppKit.
        var columns = [0: 0]
        var bytes = 0
        var units = 0
        for scalar in content.unicodeScalars {
            bytes += scalar.utf8.count
            units += scalar.utf16.count
            columns[bytes] = units
        }
        let original = content as NSString
        var runs: [(NSRange, InlinePresentationIntent, Bool)] = []
        var previousEnd = 0
        for run in parsed.runs {
            guard let position = run.markdownSourcePosition,
                  let start = columns[position.startColumn - 1], let end = columns[position.endColumn],
                  previousEnd <= start, start < end else { return }
            let local = NSRange(location: start, length: end - start)
            // Keep escaped/entity text visible rather than guessing how to
            // align a run whose source is different from the parsed characters.
            let literal = original.substring(with: local)
            let rendered = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if literal != rendered && intent.contains(.code) { return }
            runs.append((local, intent, run.link != nil))
            previousEnd = end
        }
        previousEnd = 0
        for (local, intent, link) in runs {
            hide(contentStart + previousEnd, contentStart + local.location)
            let target = NSRange(location: range.location + contentStart + local.location, length: local.length)
            let weight: NSFont.Weight = heading || intent.contains(.stronglyEmphasized) ? .semibold : .regular
            if intent.contains(.code) { storage.addAttributes(codeAttributes(size: pointSize, weight: weight), range: target) }
            else if weight == .semibold { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize, weight: weight), range: target) }
            if intent.contains(.emphasized) { storage.addAttribute(.obliqueness, value: 0.18, range: target) }
            if intent.contains(.strikethrough) { storage.addAttribute(.strikethroughStyle, value: 1, range: target) }
            if link { storage.addAttribute(.underlineStyle, value: 1, range: target) }
            previousEnd = NSMaxRange(local)
        }
        hide(contentStart + previousEnd, length)
    }

    private func codeAttributes(size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .backgroundColor: color.withAlphaComponent(0.07)]
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var changedGlyphs: [CGGlyph]?
        var changedProperties: [NSLayoutManager.GlyphProperty]?
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard character < storage.length else { continue }
            if storage.attribute(.markdownHidden, at: character, effectiveRange: nil) != nil {
                if changedGlyphs == nil {
                    changedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
                    changedProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
                }
                changedGlyphs?[index] = 0
                changedProperties?[index] = .null
            } else if let symbol = storage.attribute(.markdownSymbol, at: character, effectiveRange: nil) as? String,
                      var code = symbol.utf16.first {
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &code, &glyph, 1) else { continue }
                if changedGlyphs == nil {
                    changedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
                    changedProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
                }
                changedGlyphs?[index] = glyph
            }
        }
        guard let changedGlyphs, let changedProperties else { return 0 }
        layoutManager.setGlyphs(changedGlyphs, properties: changedProperties, characterIndexes: characterIndexes,
                                font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }
}

class LiveMarkdownTextView: NSTextView {
    private var liveLayout: LiveMarkdownTextViewLayout?
    private var focused = false
    private var trackingMouse = false
    private var inserting = false
    private var autoFormatLine: Int?
    var onLiveLayoutChange: (() -> Void)?

    func enableLiveMarkdown(size: CGFloat, color: NSColor) {
        liveLayout = LiveMarkdownTextViewLayout(size: size, color: color)
        layoutManager?.delegate = liveLayout
        autoFormatLine = nil
        defaultParagraphStyle = NoteTypography.paragraph(fontSize: size)
        refreshLiveMarkdown(changedText: true)
    }

    func disableLiveMarkdown() {
        liveLayout = nil
        layoutManager?.delegate = nil
        autoFormatLine = nil
    }

    func liveSelectionChanged() {
        guard !inserting, !trackingMouse, !hasMarkedText() else { return }
        autoFormatLine = nil
        refreshLiveMarkdown()
    }

    private func refreshLiveMarkdown(changedText: Bool = false) {
        guard let liveLayout, !hasMarkedText() else { return }
        let selection = focused && autoFormatLine == nil ? selectedRange() : nil
        liveLayout.display(in: self, showing: selection, changedText: changedText)
        onLiveLayoutChange?()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focused = true
        if !trackingMouse { refreshLiveMarkdown() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focused = false
        autoFormatLine = nil
        refreshLiveMarkdown()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        trackingMouse = true
        super.mouseDown(with: event)
        trackingMouse = false
        liveSelectionChanged()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        inserting = true
        super.insertText(insertString, replacementRange: replacementRange)
        inserting = false
        guard liveLayout != nil else { return }
        let inserted = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        let source = string as NSString
        let caret = selectedRange().location
        guard caret <= source.length else { return }
        let row = source.lineRange(for: NSRange(location: caret, length: 0))
        if row.location != autoFormatLine { autoFormatLine = nil }
        if inserted == " ", caret > row.location {
            let before = source.substring(with: NSRange(location: row.location, length: caret - row.location))
            if LiveMarkdownTextViewLayout.startsBlock(before)
                || before.dropLast().last.map({ "*_`~)".contains($0) }) == true {
                autoFormatLine = row.location
            }
        }
        refreshLiveMarkdown(changedText: true)
    }

    override func didChangeText() {
        if !inserting { refreshLiveMarkdown(changedText: true) }
        super.didChangeText()
    }

    override func unmarkText() {
        super.unmarkText()
        if !inserting { refreshLiveMarkdown(changedText: true) }
    }
}
