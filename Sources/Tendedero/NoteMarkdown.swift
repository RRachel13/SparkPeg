import AppKit

/// Foundation parses the Markdown; AppKit draws it with the note's typography.
enum NoteMarkdown {
    static func render(_ source: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
            .paragraphStyle: NoteTypography.paragraph(fontSize: size)
        ]
        guard let parsed = try? AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true)),
              !parsed.characters.isEmpty else { return NSAttributedString(string: source, attributes: base) }

        let result = NSMutableAttributedString()
        var previousBlock: Int?
        var previousLine: Int?
        var shownItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let position = run.markdownSourcePosition
            if result.length > 0 && block != previousBlock {
                let gap = min(2, max(1, (position?.startLine ?? 0) - (previousLine ?? 0)))
                let hasNewline = result.mutableString.character(at: result.length - 1) == 10
                result.append(NSAttributedString(string: String(repeating: "\n", count: gap - (hasNewline ? 1 : 0)),
                                                 attributes: base))
            }
            previousBlock = block
            if let position { previousLine = position.endLine }

            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.softBreak) || intent.contains(.lineBreak) {
                result.append(NSAttributedString(string: "\n", attributes: base))
                continue
            }

            let style = NoteTypography.paragraph(fontSize: size).mutableCopy() as! NSMutableParagraphStyle
            var pointSize = size
            var heading = false
            var code = intent.contains(.code)
            var quote = false
            var marker = ""
            var nesting = 0
            var listItem: (id: Int, ordinal: Int)?
            for component in components {
                switch component.kind {
                case .header(let level):
                    heading = true
                    pointSize *= level == 1 ? 1.4 : level == 2 ? 1.25 : 1.12
                case .codeBlock: code = true
                case .blockQuote: quote = true
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                case .unorderedList, .orderedList:
                    nesting += 1
                    if nesting == 1, let item = listItem, shownItems.insert(item.id).inserted {
                        if case .orderedList = component.kind { marker = "\(item.ordinal). " }
                        else { marker = "• " }
                    }
                    listItem = nil
                default: break
                }
            }
            if nesting > 0 {
                style.firstLineHeadIndent = CGFloat(nesting - 1) * size
                style.headIndent = CGFloat(nesting) * size
            }
            if quote {
                style.firstLineHeadIndent += size * 0.65
                style.headIndent += size * 0.65
            }

            var attributes = base
            attributes[.paragraphStyle] = style
            let weight: NSFont.Weight = heading || intent.contains(.stronglyEmphasized) ? .semibold : .regular
            let font = code ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
                : NSFont.systemFont(ofSize: pointSize, weight: weight)
            // CJK system fonts may not have an italic face.
            if intent.contains(.emphasized) { attributes[.obliqueness] = 0.18 }
            attributes[.font] = font
            if code { attributes[.backgroundColor] = color.withAlphaComponent(0.07) }
            if quote { attributes[.foregroundColor] = color.withAlphaComponent(color.alphaComponent * 0.78) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
            }
            result.append(NSAttributedString(string: marker + String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
