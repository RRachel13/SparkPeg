import Foundation
import CoreGraphics

struct TextGlyph {
    let id: Int
    let line: Int
    let text: String
    let rect: CGRect
}

/// All coordinates are in the overlay's bottom-left coordinate system.
/// Shift preserves the old selection and adds another independent range.
struct TextSelection {
    let glyphs: [TextGlyph]
    private(set) var selected: Set<Int> = []
    private var base: Set<Int> = []
    private var anchor: Int?

    init(glyphs: [TextGlyph]) { self.glyphs = glyphs }

    func nearest(to point: CGPoint) -> Int? {
        guard let glyph = glyphs.min(by: { distance(point, $0.rect) < distance(point, $1.rect) }),
              distance(point, glyph.rect) <= 32 else { return nil }
        return glyph.id
    }

    mutating func begin(at point: CGPoint, additive: Bool) {
        base = additive ? selected : []
        anchor = nearest(to: point)
        selected = base
        if let anchor { selected.insert(anchor) }
    }

    mutating func extend(to point: CGPoint) {
        guard let anchor, let end = nearest(to: point),
              let startIndex = glyphs.firstIndex(where: { $0.id == anchor }),
              let endIndex = glyphs.firstIndex(where: { $0.id == end }) else { return }
        selected = base.union(glyphs[min(startIndex, endIndex)...max(startIndex, endIndex)].map(\.id))
    }

    mutating func clear() { selected = []; base = []; anchor = nil }
    mutating func selectAll() { selected = Set(glyphs.map(\.id)) }

    var selectedGlyphs: [TextGlyph] { glyphs.filter { selected.contains($0.id) } }

    var text: String {
        var result = ""
        var previous: (index: Int, line: Int)?
        for (index, glyph) in glyphs.enumerated() where selected.contains(glyph.id) {
            if let previous {
                if previous.line != glyph.line { result += "\n" }
                else if index > previous.index + 1 { result += " " }
            }
            result += glyph.text
            previous = (index, glyph.line)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
