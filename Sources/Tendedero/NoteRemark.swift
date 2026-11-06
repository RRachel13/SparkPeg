import AppKit
import Darwin

enum NoteKind: String {
    case excerpt, idea
    static func read(_ url: URL) -> NoteKind {
        guard TextNote.isNote(url), let data = try? NoteFileAttribute.read("app.sideline.kind", from: url),
              let value = String(data: data, encoding: .utf8) else { return .excerpt }
        return NoteKind(rawValue: value) ?? .excerpt
    }
}

enum NoteFileAttribute {
    static func read(_ name: String, from url: URL) throws -> Data? {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            let size = getxattr(path, name, nil, 0, 0, 0)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            guard count == size else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }
    static func write(_ data: Data?, name: String, to url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            let result: Int32
            if let data { result = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) } }
            else {
                result = removexattr(path, name, 0)
                if result < 0 && errno == ENOATTR { return }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}

/// UTF-8 excerpt/idea, remark and origin stay together through file moves.
struct NoteDocument: Equatable {
    var text: String
    var remark: String = ""
    var kind: NoteKind = .excerpt
    var colorHex: String? = nil

    static func colorHex(from url: URL) -> String? {
        guard TextNote.isNote(url), let data = try? NoteFileAttribute.read("app.sideline.color", from: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return IdeaPalette.normalize(value)
    }

    static func ensureIdeaColor(_ url: URL) -> String? {
        guard NoteKind.read(url) == .idea else { return nil }
        if let hex = colorHex(from: url) { return hex }
        do {
            var document = try read(url)
            document.colorHex = IdeaPalette.random()
            try document.write(to: url)
            return document.colorHex
        } catch { return IdeaPalette.fallback(for: url) }
    }

    static func read(_ url: URL) throws -> NoteDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        let data = try NoteFileAttribute.read("app.sideline.remark", from: url)
        guard data == nil || String(data: data!, encoding: .utf8) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return NoteDocument(text: text, remark: data.flatMap { String(data: $0, encoding: .utf8) } ?? "", kind: NoteKind.read(url), colorHex: colorHex(from: url))
    }

    func write(to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".sideline-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary)
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        let remarkData = remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Data(remark.utf8)
        try NoteFileAttribute.write(remarkData, name: "app.sideline.remark", to: temporary)
        try NoteFileAttribute.write(kind == .idea ? Data(kind.rawValue.utf8) : nil, name: "app.sideline.kind", to: temporary)
        let colorData = kind == .idea ? colorHex.flatMap(IdeaPalette.normalize).map { Data($0.utf8) } : nil
        try NoteFileAttribute.write(colorData, name: "app.sideline.color", to: temporary)
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in rename(source!, destination!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum RemarkAppearance {
    static let changed = Notification.Name("SideLineRemarkColorChanged")
    static let key = "noteRemarkColorRGBA"
    static var defaultColor: NSColor { NSColor(calibratedWhite: 0.44, alpha: 0.9) }

    static func color(defaults: UserDefaults = .standard) -> NSColor {
        guard let rgba = defaults.object(forKey: key) as? [Double], rgba.count == 4,
              rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return defaultColor }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    static func save(_ color: NSColor, defaults: UserDefaults = .standard) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        defaults.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)], forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

@MainActor
final class NoteSettings: NSObject {
    static let shared = NoteSettings()
    private(set) var window: NSWindow?
    private var colorWell: NSColorWell?
    private let paletteEditor = NSTextView()
    private let swatches = NSView()
    private let paletteStatus = NSTextField(wrappingLabelWithString: "")

    func show(orderFront: Bool = true) {
        if let window {
            if !window.isVisible { loadPalette(); paletteStatus.stringValue = "" }
            if orderFront { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 416),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("SideLine Settings")
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        func label(_ key: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, heading: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: L(key))
            field.font = heading ? .systemFont(ofSize: 14, weight: .semibold) : .systemFont(ofSize: 12)
            field.textColor = heading ? .labelColor : .secondaryLabelColor
            field.frame = NSRect(x: x, y: y, width: width, height: height)
            content.addSubview(field)
        }
        func button(_ key: String, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
            let button = NSButton(title: L(key), target: self, action: action)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: x, y: y, width: width, height: 30)
            content.addSubview(button)
        }
        label("Remark text color", x: 26, y: 367, width: 280, height: 22, heading: true)
        let well = NSColorWell(frame: NSRect(x: 376, y: 363, width: 58, height: 30))
        well.color = RemarkAppearance.color()
        well.target = self
        well.action = #selector(changeColor)
        well.setAccessibilityLabel(L("Remark text color"))
        content.addSubview(well)
        colorWell = well
        label("Applies to remarks on every note. The excerpt keeps its original color.", x: 26, y: 321, width: 408, height: 34)
        button("Restore default color", action: #selector(resetColor), x: 24, y: 288, width: 164)
        let separator = NSBox(frame: NSRect(x: 26, y: 275, width: 408, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)
        label("Idea note palette", x: 26, y: 235, width: 408, height: 24, heading: true)
        label("New idea notes pick a color at random. Existing notes keep their colors.", x: 26, y: 196, width: 408, height: 35)
        label("Six-digit hex colors, separated by commas or spaces", x: 26, y: 174, width: 408, height: 18)
        let scroll = NSScrollView(frame: NSRect(x: 26, y: 102, width: 408, height: 66))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        paletteEditor.isRichText = false
        paletteEditor.allowsUndo = true
        paletteEditor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        paletteEditor.textContainerInset = NSSize(width: 8, height: 8)
        paletteEditor.isVerticallyResizable = true
        paletteEditor.isHorizontallyResizable = false
        paletteEditor.autoresizingMask = [.width]
        paletteEditor.textContainer?.widthTracksTextView = true
        paletteEditor.textContainer?.heightTracksTextView = false
        paletteEditor.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        paletteEditor.setFrameSize(scroll.contentSize)
        paletteEditor.setAccessibilityLabel(L("Idea note palette"))
        scroll.documentView = paletteEditor
        content.addSubview(scroll)
        swatches.frame = NSRect(x: 26, y: 76, width: 408, height: 19)
        content.addSubview(swatches)
        paletteStatus.frame = NSRect(x: 26, y: 45, width: 408, height: 27)
        paletteStatus.font = .systemFont(ofSize: 11)
        content.addSubview(paletteStatus)
        button("Restore default palette", action: #selector(resetPalette), x: 24, y: 13, width: 166)
        button("Save palette", action: #selector(savePalette), x: 321, y: 13, width: 116)
        self.window = window
        loadPalette()
        window.center()
        if orderFront {
            window.makeKeyAndOrderFront(nil)
            NSColorPanel.shared.showsAlpha = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func loadPalette() {
        let colors = IdeaPalette.colors()
        paletteEditor.string = colors.map { "#" + $0 }.joined(separator: ", ")
        swatches.subviews.forEach { $0.removeFromSuperview() }
        for (i, hex) in colors.prefix(13).enumerated() {
            let swatch = NSView(frame: NSRect(x: i * 26, y: 0, width: 19, height: 19))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 4
            swatch.layer?.backgroundColor = IdeaPalette.color(hex)?.cgColor
            swatch.toolTip = "#" + hex
            swatches.addSubview(swatch)
        }
    }

    @objc private func changeColor(_ sender: NSColorWell) { RemarkAppearance.save(sender.color) }
    @objc private func resetColor() { RemarkAppearance.reset(); colorWell?.color = RemarkAppearance.color() }
    @objc private func savePalette() {
        do {
            try IdeaPalette.save(paletteEditor.string)
            loadPalette()
            paletteStatus.textColor = .secondaryLabelColor
            paletteStatus.stringValue = L("Palette saved")
        } catch { paletteStatus.textColor = .systemRed; paletteStatus.stringValue = error.localizedDescription }
    }
    @objc private func resetPalette() {
        IdeaPalette.reset()
        loadPalette()
        paletteStatus.textColor = .secondaryLabelColor
        paletteStatus.stringValue = L("Default palette restored")
    }
}
