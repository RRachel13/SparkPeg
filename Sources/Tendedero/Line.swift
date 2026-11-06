import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "app.tendedero.Tendedero", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    var noteKind: NoteKind = .excerpt
    var ideaColorHex: String? = nil
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Pinned, left of the knot: it stays until you take it down.
    var kept = false
    /// Taken off the line to hold in front of you. Its clip waits empty
    /// until it comes back.
    var held = false
    /// Hung from another app with Hang on Tendedero, rather than pinned
    /// from the photos that came and went. Always pinned.
    var byHand = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Tendedero.isRecording(url) }
    var isTextNote: Bool { TextNote.isNote(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.kept == b.kept && a.byHand == b.byHand && a.held == b.held && a.thumb === b.thumb && a.noteKind == b.noteKind && a.ideaColorHex == b.ideaColorHex
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    @Published var expandedNoteID: UUID?
    @Published var expandedNoteSize: CGSize = .zero
    @Published var remarkEditingID: UUID?
    @Published var remarkRequestSerial = 0
    var onEditRemark: ((UUID) -> Void)?
    var onExpandNote: ((UUID) -> Void)?
    var onOpenNoteSource: ((NoteSource) -> Void)?
    var onArchive: (([UUID]) -> Void)?
    var onDiscard: ((UUID) -> Void)?
    var onCollapseNote: (() -> Void)?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    /// How many cards fit across the screen, independent of how many are kept.
    @Published var visibleCount = 8 {
        didSet { scroll = min(scroll, maximumScroll) }
    }
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    var canScroll: Bool { liveCount > visibleCount }
    private var maximumScroll: CGFloat { CGFloat(max(0, liveCount - visibleCount)) * Layout.spacing }

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    /// Photos hung by hand. They hang together at the left end of the line,
    /// before the knot, and never fall to make room.
    var keptCount: Int { items.filter { !$0.falling && $0.kept }.count }

    /// How many photos at the start of the line are pinned, the empty
    /// places of pinned ones that just came down included.
    var pinnedLead: Int { items.prefix { $0.kept }.count }

    private let storeKey = "pegged"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb, noteKind: NoteKind.read(url), ideaColorHex: NoteDocument.ensureIdeaColor(url))
        item.flying = flying
        // The line moves anyway for a new photo, so the gaps close with it.
        sweepFallen()
        items.append(item)
        scroll = 0
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// Both OCR capture and native Services create the same kind of card.
    @discardableResult
    func hangText(_ text: String, in directory: URL = TextNote.folder,
                  trimEdges: Bool = true, flying: Bool = false, kind: NoteKind = .excerpt,
                  source: NoteSource? = nil) throws -> UUID {
        let url = try TextNote.save(text, in: directory, trimEdges: trimEdges, kind: kind)
        if let source, kind == .excerpt {
            do { try source.write(to: url) }
            catch { log.error("Could not attach the source to a text note") }
        }
        guard let id = hang(url, flying: flying) else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileReadUnknown)
        }
        return id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    /// Hold, from a photo's menu: the app takes it off the line.
    var onHold: ((UUID) -> Void)?
    /// A click on a held photo's faded trace: it comes back.
    var onHangBack: ((UUID) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        scroll = min(scroll, maximumScroll)
        save()
        if !quietly { play("Pop", volume: 0.25) }
        lastFall = Date()
    }

    /// When the last photo started falling. A fallen photo keeps its empty
    /// place while the pointer stays on the line, so the next cross stays
    /// under it while discarding several in a row.
    private var lastFall = Date.distantPast

    /// The pointer left the line: the gaps close, once the last photo has
    /// finished falling.
    func closeGaps() {
        guard items.contains(where: { $0.falling }),
              Date().timeIntervalSince(lastFall) >= 0.6 else { return }
        sweepFallen()
    }

    /// The fallen photos leave their places and the rest close up.
    private func sweepFallen() {
        items.removeAll { $0.falling }
    }

    /// Bulk archive leaves pinned and held cards on the line.
    func clear() {
        onArchive?(items.filter { !$0.falling && !$0.kept && !$0.held }.map(\.id))
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return (toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])).filter { !$0.kept && !$0.held }
    }

    func takeDown(_ id: UUID, toTheLeft: Bool) {
        onArchive?(neighbours(of: id, toTheLeft: toTheLeft).map(\.id))
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let text = TextNote.read(item.url) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            onClipboard = nil
        } else {
            putOnClipboard(item.url)
        }

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// The file last put on the clipboard, and the clipboard's change count
    /// right after. While the count is the same, nothing else has been copied.
    private var onClipboard: (url: URL, change: Int)?

    private func putOnClipboard(_ url: URL) {
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !isRecording(url), let png = pngData(url) { entry.setData(png, forType: .png) }
        entry.setString(url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        onClipboard = (url, pb.changeCount)
    }

    /// Apps like Finder or a chat window paste the copied file rather than the
    /// picture. When the file moves after a copy, to the Trash or the Desktop,
    /// the clipboard follows it, or those apps would find nothing to paste.
    private func clipboardFollows(_ url: URL, to moved: URL) {
        guard let onClipboard, onClipboard.url == url,
              onClipboard.change == NSPasteboard.general.changeCount else { return }
        putOnClipboard(moved)
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isTextNote { onExpandNote?(id) }
        else { NSWorkspace.shared.open(item.url) }
    }

    func askGPT(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let text = TextNote.read(item.url) else { return }
        GPTDraftLink.open(text)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it, so SideLine
    /// still moves the file and records it for Put Back.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false, step: UUID? = UUID()) -> Bool {
        guard let item = items.first(where: { $0.id == id && !$0.falling }),
              let index = liveIndex(of: id) else { return false }
        do {
            let url = URL(fileURLWithPath: item.url.path)
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true || properties.isSymbolicLink == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            if let trashed { clipboardFollows(item.url, to: trashed as URL) }
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            if let step {
                remember(TakenDown(url: item.url, index: index, relocated: trashed as URL?, kept: item.kept, byHand: item.byHand), in: step)
            }
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    func pressCorner(_ id: UUID) {
        onArchive?([id])
    }

    func archive(_ id: UUID, in store: ArchiveStore, quietly: Bool = false, step: UUID = UUID()) throws {
        guard let item = items.first(where: { $0.id == id && !$0.falling }), let index = liveIndex(of: id) else { return }
        let properties = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        try store.prepare()
        var relocated: URL?
        if item.url.deletingLastPathComponent().resolvingSymlinksInPath() != store.folder.resolvingSymlinksInPath() {
            let target = uniqueURL(in: store.folder, for: item.url.lastPathComponent)
            try FileManager.default.moveItem(at: item.url, to: target)
            clipboardFollows(item.url, to: target)
            relocated = target
        }
        drop(id, quietly: quietly)
        remember(TakenDown(url: item.url, index: index, relocated: relocated, kept: item.kept, byHand: item.byHand), in: step)
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        guard canScroll, expandedNoteID == nil else { return }
        let next = min(maximumScroll, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            clipboardFollows(item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isTextNote {
            onExpandNote?(id)
        } else if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Putting back

    /// A photo taken down by hand: its file, where it hung among the photos
    /// still on the line, and where the file went if moved.
    private struct TakenDown {
        let url: URL
        let index: Int
        let relocated: URL?
        var kept = false
        var byHand = false
    }

    /// What was taken down, the latest last. A step holds everything one
    /// action took down. Only kept while the app runs.
    private var steps: [(id: UUID, photos: [TakenDown])] = []
    private static let maxSteps = 20

    var canPutBack: Bool { !steps.isEmpty }

    private func remember(_ photo: TakenDown, in step: UUID) {
        if let i = steps.lastIndex(where: { $0.id == step }) {
            steps[i].photos.append(photo)
        } else {
            steps.append((step, [photo]))
            if steps.count > Self.maxSteps { steps.removeFirst() }
        }
    }

    /// Put back, or ⌘Z over the line: what was taken down last hangs again
    /// where it was, including moving files back from the archive or Trash.
    func putBack() {
        guard let step = steps.popLast() else { return }
        var back: Set<UUID> = []
        // The last one taken down goes back first, so each finds its place.
        for photo in step.photos.reversed() {
            guard let url = restore(photo), !items.contains(where: { $0.url == url && !$0.falling }),
                  let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb, noteKind: NoteKind.read(url), ideaColorHex: NoteDocument.ensureIdeaColor(url))
            item.kept = photo.kept
            item.byHand = photo.byHand
            let live = items.filter { !$0.falling }
            if let gap = items.firstIndex(where: { $0.falling && $0.url == photo.url }) {
                // Its empty place is still on the line: it hangs back there.
                items[gap] = item
            } else if photo.index < live.count, let i = items.firstIndex(where: { $0.id == live[photo.index].id }) {
                items.insert(item, at: i)
            } else {
                items.append(item)
            }
            back.insert(item.id)
        }
        guard !back.isEmpty else {
            NSSound.beep()
            return
        }
        keepKeptFirst()
        save()
        play("Tink", volume: 0.35)
    }

    /// Move the original file back, or leave it in the archive on failure.
    private func restore(_ photo: TakenDown) -> URL? {
        guard let relocated = photo.relocated else {
            return FileManager.default.fileExists(atPath: photo.url.path) ? photo.url : nil
        }
        let url = uniqueURL(in: photo.url.deletingLastPathComponent(), for: photo.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: relocated, to: url)
            clipboardFollows(relocated, to: url)
            log.notice("Put back \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            log.error("Could not put back \(relocated.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Where a photo hangs, counting only the photos still on the line.
    private func liveIndex(of id: UUID) -> Int? {
        items.filter { !$0.falling }.firstIndex { $0.id == id }
    }

    // MARK: Hanging by hand

    /// Kept photos hang left of the knot, the rest after it, each side in
    /// its own order.
    private func keepKeptFirst() {
        let kept = items.filter { $0.kept && !$0.falling }
        if items.prefix(kept.count).map(\.id) != kept.map(\.id) {
            items = kept + items.filter { !($0.kept && !$0.falling) }
        }
    }

    /// Pin: the photo joins the kept ones at the left end of the line.
    func pin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.kept }) else { return }
        var item = items.remove(at: i)
        item.kept = true
        items.insert(item, at: keptCount)
        save()
        play("Tink", volume: 0.35)
    }

    /// Unpin: it hangs loose again, first past the kept ones, so it is the
    /// next to fall from a full line.
    func unpin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && $0.kept && !$0.byHand }) else { return }
        var item = items.remove(at: i)
        item.kept = false
        items.insert(item, at: keptCount)
        save()
    }

    /// An image hung from another app, with Hang on Tendedero. Like a
    /// photo from a watched folder, the line only shows the file where it
    /// is: taking it down leaves the file alone. What you hang yourself is
    /// pinned.
    @discardableResult
    func hangKept(_ url: URL) -> Bool {
        // Already on the line: it is pinned where it is.
        if let hanging = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }) {
            pin(hanging.id)
            return true
        }
        guard let id = hang(url),
              let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items.remove(at: i)
        item.kept = true
        item.byHand = true
        items.insert(item, at: keptCount)
        save()
        return true
    }

    // MARK: Holding

    /// Off the line and into your hand, or back onto its clip.
    func setHeld(_ id: UUID, _ held: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling }) else { return }
        items[i].held = held
        if !held { items[i].flying = true }
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private let keptKey = "kept"
    private let byHandKey = "byHand"

    private func save() {
        let live = items.filter { !$0.falling }
        defaults.set(live.map(\.url.path), forKey: storeKey)
        defaults.set(live.filter(\.kept).map(\.url.path), forKey: keptKey)
        defaults.set(live.filter(\.byHand).map(\.url.path), forKey: byHandKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        let kept = Set(defaults.stringArray(forKey: keptKey) ?? [])
        let byHand = Set(defaults.stringArray(forKey: byHandKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb, noteKind: NoteKind.read(url), ideaColorHex: NoteDocument.ensureIdeaColor(url))
            item.byHand = byHand.contains(path)
            item.kept = kept.contains(path) || item.byHand
            items.append(item)
        }
        keepKeptFirst()
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
@MainActor
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if let text = TextNote.read(url) {
        return TextNote.preview(text, maxPixels: maxPixels, remark: (try? NoteDocument.read(url))?.remark ?? "", kind: NoteKind.read(url))
    }
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
