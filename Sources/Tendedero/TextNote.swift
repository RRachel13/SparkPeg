import AppKit

/// Notes remain UTF-8 text files. Only their on-line preview is rendered;
/// copying, dragging, opening and asking GPT use the original text.
enum TextNote {
    static func isNote(_ url: URL) -> Bool { url.pathExtension.lowercased() == "txt" }

    static func read(_ url: URL) -> String? {
        guard isNote(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static var folder: URL {
        if let root = Bundle.main.object(forInfoDictionaryKey: "SideLineWorkspacePath") as? String {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Notes", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideLine/Notes", isDirectory: true)
    }

    @discardableResult
    static func save(_ text: String, in directory: URL = folder, trimEdges: Bool = true, kind: NoteKind = .excerpt) throws -> URL {
        let text = trimEdges ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "便签 \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).txt"
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if kind == .idea {
            do { try NoteDocument(text: text, kind: kind, colorHex: IdeaPalette.random()).write(to: url) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
        }
        return url
    }

    /// Held cards and the flight must use the very same text layout as the
    /// collapsed editable card. A separate 30-point/420px layout used to land
    /// at a smaller font and visibly jump when the native editor faded in.
    @MainActor
    static func preview(_ text: String, maxPixels: Int, remark: String = "", kind: NoteKind = .excerpt) -> NSImage? {
        let canvas = NSSize(width: 420, height: 280)
        let card = PeggedView.photoSize(for: canvas)
        let view = InlineNoteBody(url: URL(fileURLWithPath: "/.sideline-preview-only"),
            text: String(text.prefix(6000)), fontSize: NoteExpansionLayout.fontSize(scale: Layout.size.scale),
            remark: String(remark.prefix(6000)), kind: kind)
        view.frame = NSRect(origin: .zero, size: card)
        view.layoutSubtreeIfNeeded()
        let pixels = max(1, maxPixels)
        let pixelHeight = max(1, Int(ceil(CGFloat(pixels) * card.height / card.width)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = card
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Keep the existing image geometry; only its rasterization changes.
        bitmap.size = canvas
        let image = NSImage(size: canvas)
        image.addRepresentation(bitmap)
        return image
    }
}

/// The official app deep link pre-fills a draft; it never sends the text.
enum GPTDraftLink {
    static func url(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [URLQueryItem(name: "prompt", value: text)]
        // URLSearchParams treats a literal + as a space. Preserve code/math.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    @MainActor
    static func open(_ text: String) {
        guard let url = url(for: text), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = L("Could not open GPT")
            alert.informativeText = L("Check that the app handling codex links is installed.")
            alert.runModal()
            return
        }
    }
}
