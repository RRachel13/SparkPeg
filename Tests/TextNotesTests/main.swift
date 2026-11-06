import AppKit
import ScreenCaptureKit
import ObjectiveC

private var checks = 0
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else { fatalError(message) }
}

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(isolated: Bool) { super.init(suiteName: "SideLine-Memory-Tests-\(UUID().uuidString)")! }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

@MainActor
private func runTests() throws {
    // No app, permission prompt, synthetic key event, global clipboard write or GPT
    // request is made by these tests. Storage is confined to the workspace.
    UserDefaults.standard.register(defaults: ["soundOff": true])
    var glyphs: [TextGlyph] = []
    for (line, text) in ["第一行", "第二行", "第三行"].enumerated() {
        for (column, character) in text.enumerated() {
            glyphs.append(TextGlyph(id: glyphs.count, line: line, text: String(character),
                rect: CGRect(x: 20 + column * 20, y: 300 - line * 40, width: 18, height: 22)))
        }
    }
    func point(_ index: Int) -> CGPoint { CGPoint(x: glyphs[index].rect.midX, y: glyphs[index].rect.midY) }
    var selection = TextSelection(glyphs: glyphs)
    selection.begin(at: point(0), additive: false)
    selection.extend(to: point(8))
    expect(selection.text == "第一行\n第二行\n第三行", "Normal drag must preserve reading order and line breaks")
    selection.begin(at: point(8), additive: false)
    selection.extend(to: point(0))
    expect(selection.text == "第一行\n第二行\n第三行", "Dragging backwards must produce the same reading order")
    selection.begin(at: point(0), additive: false)
    selection.extend(to: point(2))
    selection.begin(at: point(6), additive: true)
    selection.extend(to: point(8))
    expect(selection.text == "第一行\n第三行", "Shift must select discontiguous lines without including the skipped line")
    expect(selection.selected.count == 6, "Adding a range must not duplicate selected glyphs")
    selection.begin(at: point(3), additive: false)
    expect(selection.text == "第", "A normal click must replace the old selection")
    selection.begin(at: CGPoint(x: 1000, y: 1000), additive: false)
    expect(selection.text.isEmpty, "Clicking far from text must clear selection instead of guessing words")
    selection.selectAll()
    expect(selection.selectedGlyphs.map(\.id) == glyphs.map(\.id), "Select All must include every recognized glyph in reading order")
    selection.clear()
    expect(selection.selectedGlyphs.isEmpty, "Cancelling selection must clear the selection highlight")

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let directory = root.appendingPathComponent("work/text-note-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = "灵感：把 A+B、a&b、100% 和 #标题 放在一起。\n第二行保留 \"引号\" 与 emoji 👩🏽‍💻。"
    let url = try TextNote.save(text, in: directory)
    expect(TextNote.read(url) == text, "UTF-8 storage must preserve Unicode, punctuation and line breaks")
    let other = try TextNote.save(text, in: directory)
    expect(other != url, "Rapid repeated captures must never overwrite a previous note")
    do {
        _ = try TextNote.save(" \n\t", in: directory)
        fatalError("An empty note must not be saved")
    } catch { checks += 1 }

    // Native Services receives a dedicated selection pasteboard, which must
    // neither be rewritten nor replaced with the user's global clipboard.
    let serviceBoard = NSPasteboard.withUniqueName()
    defer { serviceBoard.releaseGlobally() }
    let service = TextPinService()
    let serviceLine = Line(defaults: MemoryDefaults(isolated: true))
    service.onPin = { selection in try serviceLine.hangText(selection, in: directory, trimEdges: false) }
    let selected = "    保留缩进 A+B & 100%\n第二行 💡\n"
    serviceBoard.setString(selected, forType: .string)
    let serviceChange = serviceBoard.changeCount
    var serviceError: NSString? = "old error"
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceError == nil && serviceLine.liveCount == 1,
           "The real service method must create exactly one hanging note and clear stale errors")
    let selectedURL = serviceLine.items.last!.url
    expect(TextNote.read(selectedURL) == selected,
           "Pin must preserve exact selected Unicode, indentation and trailing line breaks")
    expect(serviceBoard.changeCount == serviceChange && serviceBoard.string(forType: .string) == selected,
           "A read-only service must not mutate the originating selection pasteboard")
    expect(try NoteDocument.read(selectedURL).remark.isEmpty,
           "Service-created notes must support the same independent remark format")
    expect(service.responds(to: NSSelectorFromString("pinSelectedText:userData:error:"))
        && class_getInstanceMethod(AppDelegate.self, NSSelectorFromString("pinSelectedText:userData:error:")) != nil,
           "Both the service handler and registered app provider must expose the exact Objective-C selector")
    expect(class_getInstanceMethod(AppDelegate.self, NSSelectorFromString("hangOnLine:userData:error:")) != nil,
           "Adding text Pin must preserve the existing image Service selector")
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceLine.liveCount == 2 && serviceLine.items.last!.url != selectedURL,
           "Repeated Pin requests must create separate notes rather than overwrite a previous selection")
    let richText = "来自富文本的摘录\n第二行 emoji 💡"
    let rich = NSAttributedString(string: richText, attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.red])
    let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    serviceBoard.clearContents()
    serviceBoard.setData(rtf, forType: .rtf)
    expect(try TextPinService.selectedText(from: serviceBoard) == richText,
           "Rich-text-only selections must import the characters without their source styling")
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceError == nil && TextNote.read(serviceLine.items.last!.url) == richText,
           "RTF selections must become the same plain-text note type")
    serviceBoard.clearContents()
    serviceBoard.setString("传统文字格式", forType: NSPasteboard.PasteboardType("NSStringPboardType"))
    expect(try TextPinService.selectedText(from: serviceBoard) == "传统文字格式",
           "Legacy Cocoa string service requests must remain compatible")
    let validCount = serviceLine.liveCount
    serviceBoard.clearContents()
    serviceBoard.setString(" \n\t", forType: .string)
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceError != nil && serviceLine.liveCount == validCount,
           "Whitespace selections must report an error instead of creating empty cards")
    serviceBoard.clearContents()
    serviceBoard.setData(Data([1, 2, 3]), forType: .png)
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceError != nil && serviceLine.liveCount == validCount,
           "Image-only requests must not turn a filename or unrelated clipboard content into a text note")
    serviceBoard.clearContents()
    serviceBoard.setString("文字", forType: .string)
    service.onPin = { _ in throw NSError(domain: "SideLine.Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "模拟保存失败"]) }
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect((serviceError as String?)?.contains("模拟保存失败") == true,
           "Storage failures must be returned to the Services caller rather than silently losing the request")
    service.onPin = nil
    service.pinSelectedText(serviceBoard, userData: nil, error: &serviceError)
    expect(serviceError != nil, "An unready provider must return a service error")
    let defaultTrim = try TextNote.save("  常规捕获  ", in: directory)
    expect(TextNote.read(defaultTrim) == "常规捕获", "Existing OCR capture trimming must remain unchanged")

    let link = GPTDraftLink.url(for: text)!
    let parts = URLComponents(url: link, resolvingAgainstBaseURL: false)!
    expect(parts.scheme == "codex" && parts.host == "new", "Ask GPT must target the installed desktop app draft route")
    expect(parts.queryItems?.first(where: { $0.name == "prompt" })?.value == text,
           "The app draft must receive the exact note, including symbols and newlines")
    expect(!parts.percentEncodedQuery!.contains("+"), "Math/code plus signs must be escaped for URLSearchParams")
    expect(parts.queryItems?.count == 1, "Draft links must not contain a send/execute instruction")

    let page = URL(string: "https://example.org/article?lang=zh#section:~:text=old")!
    let quote = "原文 A-B, C+D & #标题 100% 👩🏽‍💻"
    let source = NoteSource(url: page, text: quote, browserID: "com.apple.Safari")!
    let destination = URLComponents(url: source.destination!, resolvingAgainstBaseURL: false)!
    expect(destination.query == "lang=zh" && destination.fragment == "section:~:text=" + quote,
           "Web destinations must preserve the query and anchor and replace previous text directives")
    expect(destination.percentEncodedFragment?.contains("A%2DB%2C%20C%2BD") == true,
           "Text directive syntax must escape delimiter characters inside the excerpt")
    let sourcedLine = Line(defaults: MemoryDefaults(isolated: true))
    _ = try sourcedLine.hangText(quote, in: directory, source: source)
    let sourcedURL = sourcedLine.items.last!.url
    var edited = try NoteDocument.read(sourcedURL)
    edited.text = "编辑后的便签"
    edited.remark = "备注"
    try edited.write(to: sourcedURL)
    let moved = directory.appendingPathComponent("Moved note.txt")
    try FileManager.default.moveItem(at: sourcedURL, to: moved)
    expect(NoteSource.read(from: moved) == source && TextNote.read(moved) == edited.text,
           "Editing and moving a note must preserve the original quote and URL")
    expect(NoteSource.read(from: url) == nil, "Old notes must remain readable without source metadata")
    let chatURL = URL(string: "codex://threads/00000000-0000-4000-8000-000000000001")!
    expect(NoteSource(url: chatURL, text: quote)?.destination == chatURL,
           "Returning to Codex must use the saved existing chat link")
    expect(NoteSource(url: URL(string: "codex://threads/new")!, text: quote) == nil &&
           NoteSource(url: URL(string: "codex://threads/example?prompt=x")!, text: quote) == nil,
           "A source can never open a new Codex chat or submit URL parameters")

    guard let preview = makeThumbnail(url, maxPixels: 800),
          let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("A text note must render in the same thumbnail pipeline as screenshots")
    }
    expect(image.width > 0 && image.height > 0, "Text previews must have usable image dimensions")
    let previewBitmap = NSBitmapImageRep(cgImage: image)
    expect((previewBitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01,
           "Note previews must leave the desktop material visible instead of painting opaque yellow")
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("work/text-note-preview.png"))

    // A flight bitmap must land on exactly the native font and text origin.
    // Measure actual rendered ink, so a separately scaled 30pt preview cannot
    // pass merely by reporting a matching font-size constant.
    let landingSize = PeggedView.photoSize(for: NSSize(width: 420, height: 280))
    let landing = InlineNoteBody(url: url, text: "H", fontSize: NoteExpansionLayout.fontSize(scale: Layout.size.scale), remark: "")
    landing.frame = NSRect(origin: .zero, size: landingSize)
    landing.layoutSubtreeIfNeeded()
    let nativeBitmap = landing.bitmapImageRepForCachingDisplay(in: landing.bounds)!
    landing.cacheDisplay(in: landing.bounds, to: nativeBitmap)
    func inkRect(_ bitmap: NSBitmapImageRep) -> CGRect {
        var rect = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.25,
                      max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 else { continue }
                rect = rect.union(CGRect(x: CGFloat(x) * landingSize.width / CGFloat(bitmap.pixelsWide),
                    y: CGFloat(y) * landingSize.height / CGFloat(bitmap.pixelsHigh),
                    width: landingSize.width / CGFloat(bitmap.pixelsWide), height: landingSize.height / CGFloat(bitmap.pixelsHigh)))
            }
        }
        return rect
    }
    let nativeInk = inkRect(nativeBitmap)
    expect(!nativeInk.isNull && nativeInk.height > 4, "The reference editor must actually paint the font used at landing")
    for resolution in [320, 800] {
        let raster = TextNote.preview("H", maxPixels: resolution)!
        let bitmap = NSBitmapImageRep(cgImage: raster.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let flightInk = inkRect(bitmap)
        expect(!flightInk.isNull && abs(flightInk.height - nativeInk.height) < 0.8,
               "Both flight resolutions must render the same apparent font size as the native landing card")
        expect(abs(flightInk.minX - nativeInk.minX) < 0.8 && abs(flightInk.minY - nativeInk.minY) < 0.8,
               "Flight and native text must share their first-glyph position, without a handoff jump")
        expect(raster.size == landingSize && abs(bitmap.pixelsWide - resolution) <= 1,
               "Sharper previews must retain the native card geometry while increasing raster resolution")
    }

    let memory = MemoryDefaults(isolated: true)
    let line = Line(defaults: memory)
    let id = line.hang(url)!
    expect(line.items.first?.isTextNote == true, "Text notes must use the real hanging-card model")
    var openedNote: UUID?
    line.onExpandNote = { openedNote = $0 }
    line.open(id)
    expect(openedNote == id, "Double-click must expand a note inline, not open an external app")
    line.pin(id)
    let restored = Line(defaults: memory)
    expect(restored.items.count == 1 && restored.items[0].kept,
           "Restart restoration must retain text notes and their pinned status")
    expect(TextNote.read(restored.items[0].url) == text, "Restoration must preserve the full text, not the preview")
    let archive = ArchiveStore(folder: directory.appendingPathComponent("SideLine Archive"))
    try line.archive(id, in: archive)
    let archived = try archive.entries().first!.url
    expect(line.liveCount == 0 && !FileManager.default.fileExists(atPath: url.path)
           && TextNote.read(archived) == text,
           "Archiving must move the only file out of its original folder and off the line")
    line.putBack()
    expect(line.liveCount == 1 && TextNote.read(line.items.first(where: { !$0.falling })!.url) == text
           && !FileManager.default.fileExists(atPath: archived.path),
           "Undo must restore the original note without leaving a duplicate")

    let existing = archive.folder.appendingPathComponent(moved.lastPathComponent)
    try "别覆盖我".write(to: existing, atomically: true, encoding: .utf8)
    let archivedSourceID = sourcedLine.hang(moved)!
    try sourcedLine.archive(archivedSourceID, in: archive)
    let savedSource = try archive.entries().first { $0.url != existing }!.url
    let savedRemark = try NoteDocument.read(savedSource).remark
    expect(TextNote.read(existing) == "别覆盖我" && NoteSource.read(from: savedSource) == source
           && savedRemark == "备注",
           "A collision must preserve both files and the archived note's remark and source")

    let discardText = "Send this isolated test note to the Trash"
    let temporary = try TextNote.save(discardText, in: directory)
    let deleteLine = Line(defaults: MemoryDefaults(isolated: true))
    let deleteID = deleteLine.hang(temporary)!
    let missingParent = directory.appendingPathComponent("missing-parent/Archive")
    do {
        try deleteLine.archive(deleteID, in: ArchiveStore(folder: missingParent))
        fatalError("Archiving into an unavailable location must fail")
    } catch {
        expect(deleteLine.liveCount == 1 && TextNote.read(temporary) != nil,
               "A failed archive must leave the original and its card in place")
    }
    expect(deleteLine.trash(deleteID) && deleteLine.liveCount == 0
           && !FileManager.default.fileExists(atPath: temporary.path) && deleteLine.canPutBack,
           "Discard must move the original to the Trash and remove its card")
    deleteLine.putBack()
    expect(TextNote.read(temporary) == discardText && deleteLine.liveCount == 1,
           "The discarded original must be recoverable with its contents intact")

    let fixture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 500,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: fixture)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1100, height: 500).fill()
    for (offset, string) in ["SideLine capture test", "Hello OCR 123", "中文便签测试"].enumerated() {
        (string as NSString).draw(at: NSPoint(x: 80, y: 360 - offset * 100), withAttributes: [
            .font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black,
        ])
    }
    NSGraphicsContext.restoreGraphicsState()
    let png = fixture.representation(using: .png, properties: [:])!
    try png.write(to: root.appendingPathComponent("work/text-capture-fixture.png"))
    let external = directory.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let originalImage = external.appendingPathComponent("Image.png")
    try png.write(to: originalImage)
    let imageLine = Line(defaults: MemoryDefaults(isolated: true))
    let imageID = imageLine.hang(originalImage)!
    try imageLine.archive(imageID, in: archive)
    let archivedImage = try archive.entries().first { $0.url.lastPathComponent == originalImage.lastPathComponent }!.url
    let archivedBytes = try Data(contentsOf: archivedImage)
    expect(archivedBytes == png && !FileManager.default.fileExists(atPath: originalImage.path),
           "A photo hung from an external folder must be moved intact and found in the archive")
    let recognized = try ScreenTextRecognition.recognize(fixture.cgImage!, size: CGSize(width: 1100, height: 500))
    var all = TextSelection(glyphs: recognized)
    all.selectAll()
    expect(all.text.contains("SideLine capture test"), "Local OCR must recognize the English fixture")
    expect(all.text.contains("Hello OCR 123"), "Local OCR must retain digits")
    expect(all.text.contains("中文便签测试"), "Local OCR must recognize the Chinese fixture")
    expect(Set(recognized.prefix(8).map { Int($0.rect.minX) }).count >= 7,
           "Word-level OCR boxes must split into separately selectable character positions")
    expect(recognized.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= 500 },
           "OCR highlights must use overlay coordinates without a vertical flip")

    let collapsedSize = CGSize(width: 144, height: 99)
    let expanded = NoteExpansionLayout.expandedSize(collapsed: collapsedSize, availableHeight: 883)
    expect(expanded.width > collapsedSize.width && expanded.width <= collapsedSize.width * 1.4,
           "Expansion may widen modestly but must not become an unrelated large panel")
    expect(expanded.height > collapsedSize.height && expanded.height <= 560,
           "The inline expanded note must grow down while leaving room on screen")
    let small = NoteExpansionLayout.expandedSize(collapsed: collapsedSize, availableHeight: 320)
    expect(small.height <= 220, "Expansion on a short display must remain within the available height")
    let longText = String(repeating: "这是一段可滚动编辑的长便签。 A+B & 100%\n", count: 140)
    let editor = InlineNoteBody(url: url, text: longText, fontSize: NoteExpansionLayout.fontSize(scale: 1))
    editor.frame = NSRect(x: 0, y: 0, width: 136, height: 91)
    editor.layout()
    let originalTextControl = editor.textView
    let originalFontSize = editor.textView.font!.pointSize
    expect(!editor.textView.isEditable, "The collapsed note must retain click-to-copy behavior")
    editor.setExpanded(true)
    editor.frame.size = CGSize(width: expanded.width - 8, height: expanded.height - 8)
    editor.layout()
    expect(editor.textView === originalTextControl, "Expansion must retain the same text control instead of swapping a new editor")
    expect(editor.textView.font!.pointSize == originalFontSize,
           "Text must not change font size while the card straightens and expands")
    expect(editor.textView.string == longText && editor.textView.isEditable,
           "The expanded card must expose all original text for direct editing")
    expect(editor.textView.frame.height > editor.scrollView.contentSize.height * 2,
           "Long note layout must produce a scrollable document instead of clipping the first page")
    let bottom = max(0, editor.textView.frame.height - editor.scrollView.contentSize.height)
    editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
    editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
    expect(editor.scrollView.documentVisibleRect.minY > 0,
           "The scroll view must reach beyond the first page")
    expect(editor.textView.frame.width <= editor.scrollView.contentSize.width + 1,
           "The narrow expanded card must wrap text instead of growing horizontally")
    expect(!editor.scrollView.drawsBackground && !editor.scrollView.contentView.drawsBackground
           && !editor.textView.drawsBackground,
           "The editor and scroll viewport must not paint white corners over the glass")
    let editedText = longText + "\n追加内容 + & 👩🏽‍💻"
    editor.textView.string = editedText
    expect(editor.saveNow() && TextNote.read(url) == editedText,
           "Direct inline edits must save the complete document without losing long text")
    editor.setExpanded(false)
    expect(editor.textView === originalTextControl && editor.textView.font!.pointSize == originalFontSize,
           "Collapsing must retain the same text control and font too")
    expect(!TextNoteEditor.isOpen, "The inline editor must release editing mode when collapsed")
    // Annotation data remains independent of the excerpt and follows the file.
    let annotatedURL = try TextNote.save("摘录原文 + & 👩🏽‍💻", in: directory)
    expect(try NoteDocument.read(annotatedURL).remark.isEmpty, "Old plain notes must open with no remark")
    let annotated = NoteDocument(text: "摘录原文 + & 👩🏽‍💻", remark: "我的备注：第二个角度\n保留换行与 emoji 💡")
    try annotated.write(to: annotatedURL)
    expect(try NoteDocument.read(annotatedURL) == annotated, "Both sections must round-trip exactly")
    expect(TextNote.read(annotatedURL) == annotated.text, "Existing copy and GPT paths must still read only the excerpt")
    let movedURL = directory.appendingPathComponent("moved-note.txt")
    try FileManager.default.moveItem(at: annotatedURL, to: movedURL)
    expect(try NoteDocument.read(movedURL) == annotated, "A moved file must retain its own remark")
    let copiedURL = directory.appendingPathComponent("copied-note.txt")
    try FileManager.default.copyItem(at: movedURL, to: copiedURL)
    expect(try NoteDocument.read(copiedURL) == annotated, "Finder-style file copies must preserve remarks")
    let remarked = InlineNoteBody(url: movedURL, text: annotated.text, fontSize: originalFontSize)
    remarked.layout()
    expect(!remarked.divider.isHidden && !remarked.remarkView.superview!.isHidden,
           "Collapsed annotated cards must preview a separated remark")
    expect(remarked.remarkView.textColor != remarked.textView.textColor, "The default remark color must differ from the excerpt")
    remarked.setExpanded(true)
    remarked.beginRemark()
    remarked.frame.size = CGSize(width: 190, height: 300)
    remarked.layout()
    expect(remarked.isAddingRemark && remarked.remarkView.isEditable, "The remark action must expose an editable field in the same card")
    expect(remarked.remarkView.superview!.frame.minY > remarked.textView.frame.maxY,
           "The remark must flow below the entire expanded excerpt")
    let longRemark = String(repeating: "很长的备注也需要滚动查看。\n", count: 100)
    remarked.remarkView.string = longRemark
    remarked.layout()
    expect(remarked.scrollView.documentView!.frame.height > 600, "Both sections must share a scrollable document")
    expect(try remarked.saveNow() && NoteDocument.read(movedURL).remark == longRemark,
           "Auto-saving must retain long Unicode remarks without replacing the excerpt")
    remarked.textView.string += "\n编辑摘录"
    expect(try remarked.saveNow() && NoteDocument.read(movedURL).remark == longRemark,
           "Editing the excerpt must preserve an existing remark")
    remarked.setExpanded(false)
    remarked.setExpanded(true)
    remarked.remarkView.string = " \n"
    expect(try remarked.saveNow() && NoteDocument.read(movedURL).remark.isEmpty,
           "Deleting a remark must remove its saved metadata")
    remarked.setExpanded(false)
    remarked.layout()
    expect(remarked.divider.isHidden && remarked.remarkView.superview!.isHidden,
           "Empty remarks must leave neither a divider nor an empty field when collapsed")
    expect(remarked.textView.frame.height >= remarked.scrollView.contentSize.height,
           "An unannotated card must recover its original full excerpt area")
    let visual = InlineNoteBody(url: copiedURL, text: annotated.text, fontSize: originalFontSize)
    visual.setExpanded(true)
    visual.frame.size = CGSize(width: 190, height: 300)
    visual.layout()
    if let bitmap = visual.bitmapImageRepForCachingDisplay(in: visual.bounds) {
        visual.cacheDisplay(in: visual.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("work/remark-inline-preview.png"))
    }
    visual.setExpanded(false)
    let clean = InlineNoteBody(url: other, text: text, fontSize: originalFontSize)
    clean.layout()
    expect(clean.divider.isHidden, "Existing notes must not acquire a visible empty remark section")
    clean.setExpanded(true)
    clean.requestRemark(1)
    clean.layout()
    expect(!clean.divider.isHidden, "The add button must reveal a new empty remark field")
    clean.setExpanded(false)
    clean.layout()
    expect(clean.divider.isHidden, "Opening then cancelling an empty remark must restore the original card")
    let appearanceDefaults = MemoryDefaults(isolated: true)
    let custom = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.75)
    RemarkAppearance.save(custom, defaults: appearanceDefaults)
    let loaded = RemarkAppearance.color(defaults: appearanceDefaults).usingColorSpace(.sRGB)!
    expect(abs(loaded.blueComponent - 0.6) < 0.001 && abs(loaded.alphaComponent - 0.75) < 0.001,
           "The global custom remark color must persist its RGBA components")
    RemarkAppearance.reset(defaults: appearanceDefaults)
    expect(appearanceDefaults.object(forKey: RemarkAppearance.key) == nil,
           "Reset must actually remove a saved custom color")
    appearanceDefaults.set([Double.nan, 0, 0, 1], forKey: RemarkAppearance.key)
    expect(RemarkAppearance.color(defaults: appearanceDefaults) == RemarkAppearance.defaultColor,
           "Corrupt color settings must recover a usable default")
    RemarkAppearance.reset(defaults: appearanceDefaults)
    expect(RemarkAppearance.color(defaults: appearanceDefaults) == RemarkAppearance.defaultColor,
           "Reset must restore the default lighter remark color")
    let beforeColor = remarked.textView.textColor
    NotificationCenter.default.post(name: RemarkAppearance.changed, object: nil)
    expect(remarked.textView.textColor == beforeColor, "Changing remark appearance must never recolor the excerpt")
    let annotatedPreview = TextNote.preview(annotated.text, maxPixels: 800, remark: annotated.remark)!
    let previewCG = annotatedPreview.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    expect(annotatedPreview.size.width == preview.size.width, "Remarks must grow a preview vertically without changing its width")
    try NSBitmapImageRep(cgImage: previewCG).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("work/remark-preview.png"))

    // Folded cards grow to the text and stop at a visual height limit.
    let compact = TextNote.preview("短便签", maxPixels: 320)!
    let mediumText = (1...7).map { "完整显示第 \($0) 行" }.joined(separator: "\n")
    let mediumPreview = TextNote.preview(mediumText, maxPixels: 320)!
    let veryLong = (1...60).map { "这是第 \($0) 行便签文字" }.joined(separator: "\n")
    let longPreview = TextNote.preview(veryLong, maxPixels: 320)!
    expect(compact.size.width == longPreview.size.width && compact.size.height < mediumPreview.size.height
           && mediumPreview.size.height < longPreview.size.height && longPreview.size.height == Layout.noteMaxHeight,
           "Folded notes must grow vertically until the height cap")
    let folded = InlineNoteBody(url: other, text: mediumText, fontSize: originalFontSize, remark: "")
    folded.frame.size = mediumPreview.size
    folded.layout()
    expect(!folded.isTruncated && folded.textView.string.contains("完整显示第 7 行"),
           "A note that fits the height limit must show all its text")
    let clipped = InlineNoteBody(url: other, text: veryLong, fontSize: originalFontSize, remark: longRemark)
    clipped.frame.size = longPreview.size
    clipped.layout()
    expect(clipped.isTruncated && !clipped.divider.isHidden,
           "Very long notes should indicate truncation while leaving room for a remark preview")

    let markdown = """
    # 标题
    同一段 **加粗** 和 *斜体*
    下一行 [链接](https://example.com)

    - 第一项
    - 第二项

    > 引用

    ```swift
    let sum = 1 + 2
    ```
    """
    let markdownURL = try TextNote.save(markdown, in: directory)
    try NoteDocument(text: markdown, remark: "**备注**\n末行").write(to: markdownURL)
    let heldReader = InlineNoteBody(url: markdownURL, text: markdown, fontSize: originalFontSize, readingOnly: true)
    heldReader.frame.size = CGSize(width: 300, height: 90)
    heldReader.layout()
    let visible = heldReader.textView.attributedString()
    let content = visible.string as NSString
    func markdownFont(_ phrase: String) -> NSFont {
        visible.attribute(.font, at: content.range(of: phrase).location, effectiveRange: nil) as! NSFont
    }
    expect(content.hasPrefix("标题\n同一段 加粗 和 斜体\n下一行 链接") && content.contains("• 第一项\n• 第二项")
           && content.contains("引用") && content.contains("let sum = 1 + 2"),
           "Markdown should render familiar blocks without dropping the note's line breaks")
    expect(markdownFont("标题").pointSize > originalFontSize
           && NSFontManager.shared.traits(of: markdownFont("加粗")).contains(.boldFontMask)
           && (visible.attribute(.obliqueness, at: content.range(of: "斜体").location, effectiveRange: nil) as? Double ?? 0) > 0
           && markdownFont("let sum").isFixedPitch,
           "Markdown heading, emphasis and code must appear with distinct native fonts")
    expect((visible.attribute(.link, at: content.range(of: "链接").location, effectiveRange: nil) as? URL)?.host == "example.com",
           "A normal Markdown web link must remain available in the reading view")
    expect(!heldReader.textView.isEditable && !heldReader.isTruncated && heldReader.remarkView.string == "备注\n末行",
           "The held view must render the complete read-only note and remark")
    heldReader.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
    expect(heldReader.scrollView.documentVisibleRect.maxY >= heldReader.remarkView.superview!.frame.maxY - 1,
           "The held reader must be able to scroll all the way to the last remark")
    let markdownEditor = InlineNoteBody(url: markdownURL, text: markdown, fontSize: originalFontSize)
    markdownEditor.setExpanded(true)
    expect(markdownEditor.textView.string == markdown && markdownEditor.textView.isEditable,
           "Double-click editing must retain literal Markdown syntax")
    let live = markdownEditor.textView
    func glyph(in view: NSTextView, at index: Int) -> CGGlyph {
        let manager = view.layoutManager!
        manager.ensureLayout(for: view.textContainer!)
        return manager.cgGlyph(at: manager.glyphIndexForCharacter(at: index))
    }
    func hidden(in view: NSTextView, at index: Int) -> Bool {
        let manager = view.layoutManager!
        manager.ensureLayout(for: view.textContainer!)
        return manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null)
    }
    func moveCaret(_ view: LiveMarkdownTextView, to index: Int) {
        view.setSelectedRange(NSRange(location: index, length: 0))
        view.liveSelectionChanged()
    }
    let marker = (markdown as NSString).range(of: "- 第一项").location
    let bullet = glyph(in: live, at: marker)
    expect(hidden(in: live, at: 0) && bullet != 0,
           "The expanded editor should draw Markdown rather than showing the original syntax everywhere")
    expect(live.becomeFirstResponder(), "The expanded note must accept editing focus")
    moveCaret(live, to: marker + 3)
    expect(glyph(in: live, at: marker) != bullet && hidden(in: live, at: 0),
           "Moving the caret to a list line must reveal its hyphen and leave other lines formatted")
    moveCaret(live, to: 1)
    expect(!hidden(in: live, at: 0) && glyph(in: live, at: marker) == bullet,
           "Leaving a list line must restore its bullet and reveal syntax on the newly focused line")
    let end = live.string.utf16.count
    moveCaret(live, to: end)
    live.insertText("\n\n-", replacementRange: live.selectedRange())
    let newMarker = live.string.utf16.count - 1
    let hyphen = glyph(in: live, at: newMarker)
    live.insertText(" ", replacementRange: live.selectedRange())
    expect(glyph(in: live, at: newMarker) == bullet && hyphen != bullet && live.string.hasSuffix("- "),
           "Typing a space after a hyphen must render a bullet immediately without replacing the source")
    live.insertText("你好 👩🏽‍💻", replacementRange: live.selectedRange())
    expect(glyph(in: live, at: newMarker) == bullet,
           "The bullet should stay formatted while typing on the new list row")
    moveCaret(live, to: newMarker + 2)
    expect(glyph(in: live, at: newMarker) == hyphen,
           "Returning to the newly authored row must make its hyphen editable")
    let editedMarkdown = markdown + "\n\n- 你好 👩🏽‍💻"
    expect(markdownEditor.saveNow() && TextNote.read(markdownURL) == editedMarkdown,
           "Saving while using live Markdown must keep exact source, including Unicode")
    let remarkLive = markdownEditor.remarkView
    expect(hidden(in: remarkLive, at: 0), "Unfocused Markdown remarks should remain formatted")
    _ = live.resignFirstResponder()
    _ = remarkLive.becomeFirstResponder()
    moveCaret(remarkLive, to: 2)
    expect(!hidden(in: remarkLive, at: 0) && glyph(in: live, at: newMarker) == bullet,
           "Switching to the remark must render the body again and reveal the selected remark row")
    _ = remarkLive.resignFirstResponder()
    markdownEditor.setExpanded(false)
    expect(markdownEditor.saveNow() && TextNote.read(markdownURL) == editedMarkdown,
           "Folding a rendered note must never replace Markdown source on disk")
    markdownEditor.setExpanded(true)
    expect(markdownEditor.textView.string == editedMarkdown, "Reopening the editor must restore all Markdown markers")
    markdownEditor.setExpanded(false)

    // Real native layout: looser line spacing and a footer which never covers
    // a scrolled line of text, without moving the top text origin on expansion.
    let readingURL = try TextNote.save("第一行\n第二行\n第三行", in: directory)
    let reading = InlineNoteBody(url: readingURL, text: TextNote.read(readingURL)!, fontSize: originalFontSize)
    reading.frame.size = CGSize(width: 190, height: 300)
    reading.layout()
    let collapsedTopInset = reading.bounds.maxY - reading.scrollView.frame.maxY
    reading.setExpanded(true)
    reading.layout()
    let paragraph = reading.textView.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
    expect(paragraph.lineSpacing >= 3 && paragraph.lineSpacing <= 5,
           "Normal-size note text must get a modest extra line gap")
    expect(reading.remarkView.defaultParagraphStyle?.lineSpacing == paragraph.lineSpacing,
           "Excerpt and remark must use the same increased line spacing")
    expect(reading.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle == paragraph,
           "Typing new lines must retain the same paragraph style")
    let tight = NSTextView(frame: NSRect(x: 0, y: 0, width: 190, height: 300))
    tight.font = .systemFont(ofSize: originalFontSize)
    tight.textContainerInset = reading.textView.textContainerInset
    tight.string = reading.textView.string
    tight.layoutManager!.ensureLayout(for: tight.textContainer!)
    let tightHeight = tight.layoutManager!.usedRect(for: tight.textContainer!).height
    expect(reading.textView.layoutManager!.usedRect(for: reading.textView.textContainer!).height > tightHeight + 5,
           "The native text layout must visibly grow its line gaps")
    expect(!reading.collapseButton.frame.intersects(reading.scrollView.frame),
           "The bottom-left collapse button must sit outside the text viewport")
    expect(reading.scrollView.frame.minY >= reading.collapseButton.frame.maxY + 3,
           "The control needs a gap from the nearest visible text")
    expect(reading.bounds.maxY - reading.scrollView.frame.maxY == collapsedTopInset,
           "Reserving a footer must not shift the top text origin")
    reading.setFontSize(NoteExpansionLayout.fontSize(scale: 1.35))
    expect(reading.textView.defaultParagraphStyle!.lineSpacing > paragraph.lineSpacing,
           "Line gaps must scale with the existing card-size setting")
    reading.setExpanded(false)
    reading.layout()
    expect(reading.scrollView.frame.minY == NoteExpansionLayout.collapsedBottom
           && reading.scrollView.frame.maxY == reading.bounds.maxY && reading.collapseButton.isHidden,
           "The collapsed card must remove the editing footer and leave only clearance for the remark button")
    reading.setExpanded(true)
    let hit = CGRect(x: -400, y: 80, width: 194, height: 300)
    var didCollapse = false
    var savedBeforeCollapse = false
    reading.onCollapse = {
        didCollapse = true
        savedBeforeCollapse = TextNote.read(readingURL) == reading.textView.string
            && (try? NoteDocument.read(readingURL).remark) == reading.remarkView.string
        reading.setExpanded(false)
    }
    expect(!TextNoteEditor.collapseIfOutside(CGPoint(x: -300, y: 100), cardRect: hit) && !didCollapse,
           "Clicks in the active card must keep editing, including on displays with negative origins")
    expect(!TextNoteEditor.collapseIfOutside(CGPoint(x: -402, y: 100), cardRect: hit),
           "The same narrow border tolerance as mouse pass-through must remain inside")
    expect(!TextNoteEditor.collapseIfOutside(CGPoint(x: 20, y: 900), cardRect: nil),
           "Opening before layout arrives must not immediately dismiss the note")
    expect(!TextNoteEditor.collapseIfOutside(CGPoint(x: 20, y: 900), cardRect: hit, menuIsTracking: true),
           "A context menu outside the card must keep its text selection and responder")
    reading.textView.string += "\n点外面前的修改"
    reading.remarkView.string = "尚未等到自动保存的备注"
    expect(TextNoteEditor.collapseIfOutside(CGPoint(x: 20, y: 900), cardRect: hit)
           && didCollapse && savedBeforeCollapse && !reading.isExpanded,
           "An outside click must save both sections before triggering collapse")
    expect(!TextNoteEditor.collapseIfOutside(CGPoint(x: 20, y: 900), cardRect: hit),
           "Later outside clicks must do nothing once the editor is closed")

    // A desktop-only surface stays below ordinary apps, and consumes the
    // complete down/up pair. Tests create its real panels without ordering
    // them onto the user's desktop or synthesizing system input events.
    let desktopClicks = DesktopClickShield()
    let displays = [NSRect(x: 0, y: 0, width: 1280, height: 800),
                    NSRect(x: -1440, y: 150, width: 1440, height: 900)]
    desktopClicks.show(in: displays, orderFront: false)
    expect(desktopClicks.panels.map(\.frame) == displays,
           "Desktop click handling must cover each display, including negative screen origins")
    expect(desktopClicks.panels.allSatisfy { $0.level.rawValue < NSWindow.Level.normal.rawValue
        && $0.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)) },
           "The desktop surface must stay above wallpaper/icons but below normal application windows")
    expect(desktopClicks.panels.allSatisfy { !$0.canBecomeKey && !$0.canBecomeMain
        && $0.styleMask.contains(.nonactivatingPanel) },
           "Desktop-only click handling must never activate the app or take keyboard focus")
    expect(desktopClicks.panels.allSatisfy { !$0.isVisible && !$0.ignoresMouseEvents
        && $0.contentView!.acceptsFirstMouse(for: nil) },
           "The surface must accept its first desktop click without a preliminary activation click")
    let desktopPanel = desktopClicks.panels[0]
    expect(desktopClicks.owns(desktopPanel) && !desktopClicks.owns(nil),
           "The ordinary outside-click monitor must distinguish shield events from other app windows")
    desktopClicks.show(in: displays, orderFront: false)
    expect(desktopClicks.panels.first === desktopPanel,
           "Repeated requests while a note stays open must not recreate desktop surfaces")
    var desktopDismissals = 0
    reading.setExpanded(true)
    reading.textView.string += "\n桌面点击前的编辑"
    reading.remarkView.string = "桌面点击时一起保存的备注"
    reading.onCollapse = { reading.setExpanded(false); desktopClicks.hide() }
    desktopClicks.onDismiss = { desktopDismissals += 1; return TextNoteEditor.collapseActive() }
    desktopClicks.press(button: 0)
    expect(desktopDismissals == 1 && !reading.isExpanded && !desktopClicks.isEnabled,
           "A desktop press must save and collapse the note immediately")
    expect(try TextNote.read(readingURL) == reading.textView.string
        && NoteDocument.read(readingURL).remark == reading.remarkView.string,
           "Desktop dismissal must preserve unsaved excerpt and remark changes")
    expect(desktopClicks.panels.count == 2 && desktopClicks.owns(desktopPanel),
           "A collapsed note must retain the catcher until mouse-up so wallpaper never sees half a click")
    desktopClicks.release(button: 0)
    expect(desktopClicks.panels.isEmpty,
           "After mouse-up the desktop must regain its ordinary click behavior")
    desktopClicks.show(in: displays, orderFront: false)
    desktopClicks.onDismiss = { false }
    desktopClicks.press(button: 0)
    desktopClicks.release(button: 0)
    expect(desktopClicks.isEnabled && desktopClicks.panels.count == 2,
           "If a save fails the note's desktop handling must remain available rather than pretending it closed")
    desktopClicks.hide()
    expect(desktopClicks.panels.isEmpty && !desktopClicks.isEnabled,
           "Closing a note with its arrow must also remove every desktop surface")
    desktopClicks.show(in: displays, orderFront: false)
    desktopClicks.onDismiss = { true }
    desktopClicks.press(button: 0)
    desktopClicks.press(button: 1)
    desktopClicks.release(button: 0)
    expect(!desktopClicks.panels.isEmpty,
           "Simultaneous mouse buttons must remain captured until both buttons are released")
    desktopClicks.release(button: 1)
    expect(desktopClicks.panels.isEmpty, "The last button release must restore desktop input")
    desktopClicks.show(in: displays, orderFront: false)
    desktopClicks.press(button: 0)
    desktopClicks.hide(force: true)
    expect(desktopClicks.panels.isEmpty, "App shutdown must remove the catcher even during a press")

    // Authored ideas retain their origin through edits, remarks and file moves.
    let ideaURL = try TextNote.save("手写灵感\n第二行", in: directory, kind: .idea)
    expect(NoteKind.read(ideaURL) == .idea && NoteKind.read(other) == .excerpt,
           "Authored ideas need durable metadata, while older notes remain excerpts")
    let ideaHex = NoteDocument.colorHex(from: ideaURL)
    expect(ideaHex.map { IdeaPalette.colors().contains($0) } == true && NoteDocument.colorHex(from: other) == nil,
           "New ideas must store one palette color without changing excerpts")
    let paletteDefaults = MemoryDefaults(isolated: true)
    expect(IdeaPalette.colors(in: paletteDefaults) == ["F83778", "4CC1D5", "C5EE74", "FF6B2B", "96D1F7"],
           "The default palette must match all five exact user-provided hex codes")
    try IdeaPalette.save("#f83778，4cc1d5\n#C5EE74 F83778", in: paletteDefaults)
    expect(IdeaPalette.colors(in: paletteDefaults) == ["F83778", "4CC1D5", "C5EE74"],
           "User palette input must accept common separators and normalize duplicates")
    for invalid in ["", "#ABC", "F8#3778", "96D1F7, nonsense"] {
        do { try IdeaPalette.save(invalid, in: paletteDefaults); fatalError("Invalid palette replaced the current colors") }
        catch { checks += 1 }
    }
    expect(IdeaPalette.colors(in: paletteDefaults) == ["F83778", "4CC1D5", "C5EE74"],
           "Invalid inputs must preserve the last saved library")
    try IdeaPalette.save("102030", in: paletteDefaults)
    expect(IdeaPalette.random(in: paletteDefaults) == "102030", "A one-color custom palette must always select that color")
    let colorSample = IdeaPalette.color("F83778")!
    expect(abs(colorSample.redComponent - 248.0 / 255.0) < 0.0001 && abs(colorSample.greenComponent - 55.0 / 255.0) < 0.0001,
           "Swatches and tint must be based on the exact hex color")
    IdeaPalette.reset(in: paletteDefaults)
    expect(IdeaPalette.colors(in: paletteDefaults) == IdeaPalette.defaults, "Restore defaults must restore all five colors")
    let legacyIdea = try TextNote.save("旧灵感", in: directory)
    try NoteDocument(text: "旧灵感", remark: "保留备注", kind: .idea).write(to: legacyIdea)
    expect(NoteDocument.colorHex(from: legacyIdea) == nil, "Fixture must represent a warm idea saved before the palette")
    let migratedHex = NoteDocument.ensureIdeaColor(legacyIdea)
    expect(try migratedHex != nil && NoteDocument.colorHex(from: legacyIdea) == migratedHex
        && NoteDocument.read(legacyIdea).remark == "保留备注",
           "Existing authored notes should adopt a palette color once without losing their remarks")
    expect(NoteDocument.ensureIdeaColor(legacyIdea) == migratedHex, "Reloading an older idea must never re-roll its migrated color")
    let ideaEditor = InlineNoteBody(url: ideaURL, text: TextNote.read(ideaURL)!, fontSize: originalFontSize)
    ideaEditor.layoutSubtreeIfNeeded()
    expect(!ideaEditor.kindMark.isHidden && ideaEditor.scrollView.frame.maxY <= ideaEditor.bounds.maxY - 20,
           "Idea cards must reserve a real header for their lightbulb without covering text")
    ideaEditor.setKindMarkVisible(false)
    ideaEditor.layoutSubtreeIfNeeded()
    expect(ideaEditor.kindMark.isHidden, "The hover close control must not overlap an idea's lightbulb")
    ideaEditor.setExpanded(true)
    ideaEditor.textView.string += "\n编辑后的灵感"
    ideaEditor.remarkView.string = "额外备注"
    expect(ideaEditor.saveNow() && NoteKind.read(ideaURL) == .idea && NoteDocument.colorHex(from: ideaURL) == ideaHex,
           "Editing either region must preserve both the origin and assigned color")
    ideaEditor.setExpanded(false)
    let movedIdea = directory.appendingPathComponent("moved-idea.txt")
    try FileManager.default.moveItem(at: ideaURL, to: movedIdea)
    expect(try NoteDocument.read(movedIdea).kind == .idea && NoteDocument.read(movedIdea).remark == "额外备注",
           "Moving an idea must preserve both origin and remark")
    let ideaDefaults = MemoryDefaults(isolated: true)
    let ideaLine = Line(defaults: ideaDefaults)
    let originalIdeaID = ideaLine.hang(movedIdea)!
    expect(ideaLine.items.first?.noteKind == .idea, "The real line model must know which cards are authored ideas")
    let restoredIdeas = Line(defaults: ideaDefaults)
    expect(restoredIdeas.items.first?.noteKind == .idea && restoredIdeas.items.first?.ideaColorHex == ideaHex,
           "Restart restoration must retain the originally assigned palette color")
    try ideaLine.archive(originalIdeaID, in: archive)
    ideaLine.putBack()
    expect(ideaLine.items.contains { !$0.falling && $0.noteKind == .idea && $0.ideaColorHex == ideaHex },
           "Undo must retain the idea's lightbulb and original tint")
    let draftStore = IdeaDraftStore(directory: directory.appendingPathComponent("drafts"))
    let rawIdea = "    一个新的灵感 💡\n保留缩进和换行\n"
    try draftStore.save(rawIdea)
    expect(draftStore.read() == rawIdea, "Drafts must preserve exact Unicode, indentation and line breaks")
    let composer = IdeaComposer(draft: draftStore)
    var closedComposers = 0
    composer.onDidClose = { closedComposers += 1 }
    composer.show(orderFront: false)
    expect(composer.isOpen && composer.textView.string == rawIdea && composer.panel?.isVisible == false,
           "Opening the composer must recover the draft without ordering a test window on the user's desktop")
    expect(composer.textView.isEditable && !composer.textView.isRichText && !composer.scrollView.drawsBackground,
           "The central composer must be directly editable over transparent glass")
    expect(composer.submitButton.keyEquivalent == "\r" && composer.submitButton.keyEquivalentModifierMask == .command,
           "Command-Return should submit, leaving ordinary Return for writing multiple lines")
    expect(composer.textView.frame.height >= composer.scrollView.contentSize.height - 1,
           "The empty/short editor must fill the visible input area and accept clicks")
    let ideaInput = composer.textView
    expect(composer.panel!.makeFirstResponder(ideaInput), "The idea composer must accept editing focus")
    let draftStart = ideaInput.string.utf16.count
    moveCaret(ideaInput, to: draftStart)
    ideaInput.insertText("##", replacementRange: ideaInput.selectedRange())
    let beforeSpace = ideaInput.firstRect(forCharacterRange: ideaInput.selectedRange(), actualRange: nil)
    ideaInput.insertText(" ", replacementRange: ideaInput.selectedRange())
    let afterSpace = ideaInput.firstRect(forCharacterRange: ideaInput.selectedRange(), actualRange: nil)
    expect(beforeSpace.height > 0 && afterSpace.height > 0 && abs(beforeSpace.midY - afterSpace.midY) < 2
           && ideaInput.selectedRange().location == draftStart + 3 && !hidden(in: ideaInput, at: draftStart),
           "A second-level heading with no content must keep its caret on the current line")
    ideaInput.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                            replacementRange: ideaInput.selectedRange())
    expect(ideaInput.hasMarkedText() && ideaInput.string.hasSuffix("## zhong"),
           "Live rendering must leave marked input and its source range intact")
    ideaInput.insertText("中", replacementRange: ideaInput.markedRange())
    expect(!ideaInput.hasMarkedText() && ideaInput.string.hasSuffix("## 中") && hidden(in: ideaInput, at: draftStart),
           "Committing marked input must retain both the original heading marker and the composed character")
    _ = composer.panel!.makeFirstResponder(nil)
    let longDraft = String(repeating: "长灵感可以继续写，超出一页可以滚动。\n", count: 100)
    composer.textView.string = longDraft
    composer.textDidChange(Notification(name: NSText.didChangeNotification))
    expect(composer.textView.frame.height > composer.scrollView.contentSize.height * 2,
           "Long ideas must create a real scrollable document")
    expect(composer.dismiss() && draftStore.read() == longDraft && closedComposers == 1,
           "Escape/outside dismissal must save the draft before closing")
    composer.show(orderFront: false)
    expect(composer.textView.string == longDraft, "A dismissed draft must return on the next empty-selection shortcut")
    composer.textView.string = " \n"
    expect(!composer.submit(), "Blank ideas must not create hanging records")
    composer.textView.string = rawIdea
    composer.onCommit = { _ in throw CocoaError(.fileWriteNoPermission) }
    expect(!composer.submit() && composer.isOpen && draftStore.read() == rawIdea,
           "A failed submit must keep both the visible idea and its saved draft")
    let countBeforeIdea = ideaLine.liveCount
    composer.onCommit = { text in try ideaLine.hangText(text, in: directory, trimEdges: false, kind: .idea) }
    expect(composer.submit() && !composer.isOpen && ideaLine.liveCount == countBeforeIdea + 1,
           "Submitting must create one real idea card and close the central composer")
    expect(draftStore.read().isEmpty && TextNote.read(ideaLine.items.last!.url) == rawIdea && ideaLine.items.last?.noteKind == .idea,
           "Only a successful hang may clear the draft, preserving full content and authored style")
    for area in [NSRect(x: 0, y: 0, width: 1400, height: 900), NSRect(x: -1440, y: 120, width: 1440, height: 800)] {
        let centered = IdeaComposer.centeredFrame(in: area)
        expect(centered.midX == area.midX && centered.midY == area.midY && area.contains(centered),
               "The composer must center inside the active display, including a negative screen origin")
    }
    let ideaLanding = InlineNoteBody(url: movedIdea, text: "H", fontSize: NoteExpansionLayout.fontSize(scale: Layout.size.scale), remark: "", kind: .idea)
    ideaLanding.frame = NSRect(origin: .zero, size: landingSize)
    ideaLanding.layoutSubtreeIfNeeded()
    let ideaNative = ideaLanding.bitmapImageRepForCachingDisplay(in: ideaLanding.bounds)!
    ideaLanding.cacheDisplay(in: ideaLanding.bounds, to: ideaNative)
    let ideaInk = inkRect(ideaNative)
    for resolution in [320, 800] {
        let raster = TextNote.preview("H", maxPixels: resolution, kind: .idea)!
        let bitmap = NSBitmapImageRep(cgImage: raster.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let rasterInk = inkRect(bitmap)
        expect(!rasterInk.isNull && abs(rasterInk.height - ideaInk.height) < 0.8 && abs(rasterInk.minY - ideaInk.minY) < 0.8,
               "Authored ideas must keep the same font and header spacing when flight previews land")
    }
    let ideaPreview = TextNote.preview("手写灵感\n与摘录不同", maxPixels: 800, kind: .idea)!
    let ideaCG = ideaPreview.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    expect(ideaPreview.size.width == preview.size.width && ideaPreview.size.height >= landingSize.height,
           "The idea header should fit in a preview with the same width as an excerpt")
    try NSBitmapImageRep(cgImage: ideaCG).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("work/idea-note-preview.png"))
    for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0.2)] {
        let size = CGSize(width: 460, height: 360)
        let center = CGPoint(x: size.width * (0.5 - anchor.x), y: size.height * (0.5 - anchor.y))
        for scale: CGFloat in [0.84, 1.015, 1] {
            let point = center.applying(IdeaComposer.openingTransform(scale: scale, size: size, anchor: anchor))
            expect(hypot(point.x - center.x, point.y - center.y) < 0.01,
                   "The visual center must stay fixed through all popup scaling phases")
        }
    }
    let nextComposer = IdeaComposer(draft: draftStore)
    nextComposer.show(orderFront: false)
    if let content = nextComposer.panel?.contentView,
       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        expect(content.layer?.masksToBounds == true && content.layer?.borderWidth == 0,
               "The composer must clip the entire visual effect and own no outer stroke")
        let corners = [(0, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, 0), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
        expect(corners.allSatisfy { (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.03 },
               "All four compositor corners must be transparent in an actual render")
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("work/idea-composer-preview.png"))
    }
    _ = nextComposer.dismiss()
    let settingsPreview = NoteSettings()
    settingsPreview.show(orderFront: false)
    if let content = settingsPreview.window?.contentView,
       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("work/idea-palette-settings.png"))
    }

    let hostPanel = LinePanel(content: NSView())
    expect(!hostPanel.canBecomeKey, "The ordinary screenshot line must not steal keyboard focus")
    hostPanel.isEditingNote = true
    expect(hostPanel.canBecomeKey, "An inline note must be able to take keyboard input in its existing host")
    hostPanel.close()
    let overflowDefaults = MemoryDefaults(isolated: true)
    let editingLine = Line(defaults: overflowDefaults)
    editingLine.visibleCount = 2
    let activeID = editingLine.hang(url)!
    editingLine.expandedNoteID = activeID
    let olderID = editingLine.hang(other)!
    let freshURL = try TextNote.save("new capture", in: directory)
    let freshID = editingLine.hang(freshURL)!
    expect(editingLine.items.contains(where: { $0.id == activeID && !$0.falling })
           && editingLine.items.contains(where: { $0.id == freshID && !$0.falling }),
           "A new capture must not evict a note that is currently being edited")
    expect(editingLine.items.contains(where: { $0.id == olderID && !$0.falling })
           && editingLine.liveCount == 3,
           "Overflow must keep all of the cards on the line")
    editingLine.expandedNoteID = nil
    editingLine.scroll(by: .greatestFiniteMagnitude)
    expect(editingLine.scroll == Layout.spacing, "Scrolling must reach the oldest card and stop at the end")
    editingLine.setHeld(activeID, true)
    editingLine.scroll(by: -.greatestFiniteMagnitude)
    editingLine.setHeld(activeID, false)
    expect(editingLine.scroll == Layout.spacing && editingLine.items.first?.id == activeID
           && editingLine.items.first?.held == false && editingLine.items.first?.flying == false,
           "Returning an older note must reveal its original clip without starting a screenshot flight")
    expect(CapturePermissionFailure.isDenied(NSError(domain: SCStreamErrorDomain, code: -3801)),
           "Only a real capture permission denial should trigger the permission explanation")
    expect(!CapturePermissionFailure.isDenied(NSError(domain: SCStreamErrorDomain, code: -3802)),
           "An ordinary capture failure must not be mislabeled as a missing permission")
    let wideFixture = CGContext(data: nil, width: 3200, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let optimized = ScreenTextRecognition.recognitionImage(wideFixture)
    expect(optimized.width == 2400 && optimized.height == 1350,
           "Retina OCR downsampling must preserve the aspect ratio and avoid unnecessary full-resolution work")

}

@MainActor
private final class FakeSelectionInput: SelectionInput {
    var hasAccess = true
    var frontmostPID: pid_t? = 77
    var modifiersHeld = false
    var hasKnownSelection = false
    var direct: String?
    var copyCount = 0
    var ticks = 0
    var waitForAX = false
    var onAX: (() -> Void)?
    var onCopy: (() throws -> Void)?
    var onPause: ((Int) -> Void)?
    func accessibilityText(pid: pid_t) async -> String? {
        while waitForAX { await Task.yield() }
        onAX?()
        return direct
    }
    func sendCopy(pid: pid_t) throws { copyCount += 1; try onCopy?() }
    func pause() async throws { ticks += 1; onPause?(ticks); await Task.yield(); try Task.checkCancellation() }
}

@MainActor
private func runSelectionShortcutTests() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    func seed() {
        board.clearContents()
        let first = NSPasteboardItem()
        first.setString("原剪贴板", forType: .string)
        let rich = NSAttributedString(string: "原剪贴板")
        first.setData(try! rich.data(from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 255, 3]), forType: NSPasteboard.PasteboardType("app.sideline.test-binary"))
        second.setData(try! Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/text-note-preview.png")), forType: .png)
        board.writeObjects([first, second])
    }
    seed()
    let original = try SelectionClipboard(board)
    let raw = "    当前选区 A+B & 💡\n第二行\n"
    let direct = FakeSelectionInput()
    direct.direct = raw
    let fast = SelectedTextCapture(input: direct, pasteboard: board)
    var activity: [Bool] = []
    fast.onCopyActivity = { activity.append($0) }
    let directResult = try await fast.capture()
    expect(directResult == raw && direct.copyCount == 0 && activity.isEmpty,
           "An accessible selection must be captured exactly without simulating copy")
    expect(board.changeCount == original.changeCount, "Direct selection reads must never touch the clipboard")
    let explicitlyEmpty = FakeSelectionInput()
    explicitlyEmpty.direct = ""
    do { _ = try await SelectedTextCapture(input: explicitlyEmpty, pasteboard: board).capture(); fatalError("Empty AX selection was pinned") }
    catch SelectionCaptureError.noSelection { checks += 1 }
    expect(explicitlyEmpty.copyCount == 0 && board.changeCount == original.changeCount,
           "A definite empty selection must route immediately to the composer without copying old text")
    let fileSelection = FakeSelectionInput()
    fileSelection.onCopy = {
        board.clearContents()
        board.setString("file:///tmp/not-text.txt", forType: .fileURL)
        board.setString("/tmp/not-text.txt", forType: .string)
    }
    do { _ = try await SelectedTextCapture(input: fileSelection, pasteboard: board).capture(); fatalError("A selected file became text") }
    catch SelectionCaptureError.noSelection { checks += 1 }
    expect(try SelectionClipboard(board).items == original.items,
           "A file selection must not become a filename note, and its temporary copy must be restored")
    let fallback = FakeSelectionInput()
    fallback.onCopy = { board.clearContents(); board.setString(raw, forType: .string) }
    let capture = SelectedTextCapture(input: fallback, pasteboard: board)
    capture.onCopyActivity = { activity.append($0) }
    let copied = try await capture.capture()
    expect(copied == raw && fallback.copyCount == 1, "The fallback must copy the current selection once")
    expect(try SelectionClipboard(board).items == original.items,
           "Fallback completion must restore every item and every format, including binary and rich data")
    expect(activity == [true, false] && !capture.isBusy,
           "Temporary clipboard activity must pause and resume image watching exactly once")
    let stale = FakeSelectionInput()
    let oldCount = board.changeCount
    do { _ = try await SelectedTextCapture(input: stale, pasteboard: board).capture(); fatalError("Stale clipboard was captured") }
    catch SelectionCaptureError.noSelection { checks += 1 }
    expect(board.changeCount == oldCount && stale.ticks <= 8, "An unchanged clipboard must reach the blank composer without the long copy timeout")
    let slowSelection = FakeSelectionInput()
    slowSelection.hasKnownSelection = true
    slowSelection.onPause = { tick in
        if tick == 14 { board.clearContents(); board.setString(raw, forType: .string) }
    }
    let slowText = try await SelectedTextCapture(input: slowSelection, pasteboard: board).capture()
    expect(slowText == raw && slowSelection.ticks >= 14,
           "A confirmed selection must still allow a slower copy before opening an empty composer")
    let blank = FakeSelectionInput()
    blank.onCopy = { board.clearContents(); board.setString(" \n", forType: .string) }
    do { _ = try await SelectedTextCapture(input: blank, pasteboard: board).capture(); fatalError("Blank copy was captured") }
    catch SelectionCaptureError.noSelection { checks += 1 }
    expect(try SelectionClipboard(board).items == original.items, "An empty new copy must restore the prior multi-format clipboard")
    let changed = FakeSelectionInput()
    changed.direct = raw
    changed.onAX = { changed.frontmostPID = 88 }
    do { _ = try await SelectedTextCapture(input: changed, pasteboard: board).capture(); fatalError("Changed app was captured") }
    catch SelectionCaptureError.targetChanged { checks += 1 }
    expect(changed.copyCount == 0, "Switching apps must abort before any copy shortcut is posted")
    let held = FakeSelectionInput()
    held.modifiersHeld = true
    held.onPause = { tick in if tick == 3 { held.modifiersHeld = false } }
    held.onCopy = {
        expect(!held.modifiersHeld && held.ticks >= 3, "Copy must wait for physical shortcut modifiers to be released")
        board.clearContents(); board.setString(raw, forType: .string)
    }
    _ = try await SelectedTextCapture(input: held, pasteboard: board).capture()
    let neverReleased = FakeSelectionInput()
    neverReleased.modifiersHeld = true
    do { _ = try await SelectedTextCapture(input: neverReleased, pasteboard: board).capture(); fatalError("Held modifiers copied") }
    catch SelectionCaptureError.releaseKeys { checks += 1 }
    expect(neverReleased.copyCount == 0, "An unreleased shortcut must never become Command-Shift-C")
    let denied = FakeSelectionInput()
    denied.hasAccess = false
    do { _ = try await SelectedTextCapture(input: denied, pasteboard: board).capture(); fatalError("Untrusted access attempted") }
    catch SelectionCaptureError.permissionRequired { checks += 1 }
    expect(denied.copyCount == 0 && denied.ticks == 0, "Untrusted capture must stop before querying or copying text")
    let postDenied = FakeSelectionInput()
    postDenied.onCopy = { throw SelectionCaptureError.permissionRequired }
    activity = []
    let noPost = SelectedTextCapture(input: postDenied, pasteboard: board)
    noPost.onCopyActivity = { activity.append($0) }
    do { _ = try await noPost.capture(); fatalError("Denied event posting succeeded") }
    catch SelectionCaptureError.permissionRequired { checks += 1 }
    expect(activity == [true, false], "Copy permission failures must resume clipboard watching")
    let laterSnapshot = try SelectionClipboard(board)
    board.clearContents(); board.setString("临时复制", forType: .string)
    let temporaryCount = board.changeCount
    board.clearContents(); board.setString("用户新复制的内容", forType: .string)
    expect(!laterSnapshot.restore(board, ifUnchanged: temporaryCount)
        && board.string(forType: .string) == "用户新复制的内容", "A stale snapshot must never overwrite a newer clipboard change")
    seed()
    let missing = FakeSelectionInput()
    missing.frontmostPID = nil
    do { _ = try await SelectedTextCapture(input: missing, pasteboard: board).capture(); fatalError("Missing app was captured") }
    catch SelectionCaptureError.noSelection { checks += 1 }
    let emptyBoard = NSPasteboard.withUniqueName()
    defer { emptyBoard.releaseGlobally() }
    emptyBoard.clearContents()
    let empty = FakeSelectionInput()
    empty.onCopy = { emptyBoard.clearContents(); emptyBoard.setString(raw, forType: .string) }
    _ = try await SelectedTextCapture(input: empty, pasteboard: emptyBoard).capture()
    expect(emptyBoard.pasteboardItems?.isEmpty != false, "A previously empty clipboard must be restored to empty")
    let stages = FakeSelectionInput()
    stages.onCopy = { board.clearContents() }
    stages.onPause = { tick in if tick == 2 { board.setString(raw, forType: .string) } }
    let stagedText = try await SelectedTextCapture(input: stages, pasteboard: board).capture()
    expect(stagedText == raw && stages.ticks >= 3, "Delayed or staged clipboard data must be awaited until stable")
    let cancellation = FakeSelectionInput()
    cancellation.onCopy = { board.clearContents(); board.setString(raw, forType: .string) }
    let cancellable = SelectedTextCapture(input: cancellation, pasteboard: board)
    var cancelTask: Task<String, Error>!
    cancellation.onPause = { _ in cancelTask.cancel() }
    cancelTask = Task { try await cancellable.capture() }
    do { _ = try await cancelTask.value; fatalError("Cancelled capture returned text") }
    catch is CancellationError { checks += 1 }
    expect(try SelectionClipboard(board).items == original.items && !cancellable.isBusy,
           "Cancelling an in-progress copy must restore its clipboard and release busy state")
    let concurrentInput = FakeSelectionInput()
    concurrentInput.direct = raw
    concurrentInput.waitForAX = true
    let concurrent = SelectedTextCapture(input: concurrentInput, pasteboard: board)
    let first = Task { try await concurrent.capture() }
    while !concurrent.isBusy { await Task.yield() }
    do { _ = try await concurrent.capture(); fatalError("Concurrent captures overlapped") }
    catch SelectionCaptureError.busy { checks += 1 }
    concurrentInput.waitForAX = false
    let firstResult = try await first.value
    expect(firstResult == raw, "Rejecting a duplicate shortcut must not cancel the original capture")
    let exitInput = FakeSelectionInput()
    exitInput.onCopy = { board.clearContents(); board.setString(raw, forType: .string) }
    let exiting = SelectedTextCapture(input: exitInput, pasteboard: board)
    var exitTask: Task<String, Error>!
    exitInput.onPause = { _ in exiting.prepareForTermination(); exitTask.cancel() }
    exitTask = Task { try await exiting.capture() }
    do { _ = try await exitTask.value } catch is CancellationError {}
    expect(try SelectionClipboard(board).items == original.items,
           "Application termination must synchronously restore a pending temporary clipboard")
}

try MainActor.assumeIsolated { try runTests() }
Task { @MainActor in
    do {
        try await runSelectionShortcutTests()
        print("PASS: \(checks) note, selection shortcut, clipboard, storage, Services, UI layout and OCR checks")
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}
RunLoop.main.run()
