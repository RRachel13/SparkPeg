import AppKit

enum IdeaPalette {
    static let defaults = ["F83778", "4CC1D5", "C5EE74", "FF6B2B", "96D1F7"]
    static let key = "ideaColorPalette"

    static func normalize(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.unicodeScalars.allSatisfy({ "0123456789ABCDEF".unicodeScalars.contains($0) }) else { return nil }
        return hex
    }
    static func colors(in store: UserDefaults = .standard) -> [String] {
        guard let saved = store.object(forKey: key) as? [String] else { return defaults }
        var result: [String] = []
        for value in saved { if let hex = normalize(value), !result.contains(hex) { result.append(hex) } }
        return result.isEmpty ? defaults : result
    }
    static func save(_ source: String, in store: UserDefaults = .standard) throws {
        let values = source.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；"))).filter { !$0.isEmpty }
        guard !values.isEmpty else { throw paletteError() }
        var valid: [String] = []
        for value in values {
            guard let hex = normalize(value) else { throw paletteError() }
            if !valid.contains(hex) { valid.append(hex) }
        }
        store.set(valid, forKey: key)
    }
    static func reset(in store: UserDefaults = .standard) { store.removeObject(forKey: key) }
    static func random(in store: UserDefaults = .standard) -> String { colors(in: store).randomElement()! }
    static func color(_ hex: String?) -> NSColor? {
        guard let hex, let valid = normalize(hex), let value = UInt32(valid, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func fallback(for url: URL) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in url.lastPathComponent.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let palette = colors()
        return palette[Int(hash % UInt64(palette.count))]
    }
    private static func paletteError() -> NSError {
        NSError(domain: "SideLine.Palette", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Enter at least one six-digit hex color, separated by commas or spaces.")])
    }
}
