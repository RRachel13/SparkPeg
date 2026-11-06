import AppKit
import ApplicationServices
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private let archiveLibrary = ArchiveLibrary()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var textCaptureKey: HotKey?
    private var selectedTextKey: HotKey?
    private let selectedTextCapture = SelectedTextCapture()
    private let noteSourceNavigation = NoteSourceNavigation()
    private var noteActionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var menuTrackingDepth = 0
    private let desktopClicks = DesktopClickShield()
    private let textPinService = TextPinService()
    private let ideaComposer = IdeaComposer()
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        registerShortcut()
        textCaptureKey = HotKey(Shortcut(keyCode: kVK_ANSI_E, modifiers: [.command, .shift], key: "e")) { [weak self] in
            self?.captureTextNote()
        }
        if textCaptureKey == nil { log.error("Could not register Command-Shift-E for text capture") }
        else { log.notice("Command-Shift-E screen text shortcut registered") }

        selectedTextKey = HotKey(Shortcut(keyCode: kVK_ANSI_E, modifiers: .command, key: "e")) { [weak self] in
            self?.pinCurrentSelection()
        }
        if selectedTextKey == nil { log.error("Could not register Command-E for selected text") }
        else { log.notice("Command-E selected text shortcut registered") }
        selectedTextCapture.onCopyActivity = { [weak self] copying in
            guard let self else { return }
            if copying { self.clipboardWatcher.stop() }
            else if ClipboardWatcher.isEnabled { self.clipboardWatcher.start() }
        }
        setUpStatusItem()
        watchPointerClicks()

        textPinService.onPin = { [weak self] text in
            guard let self else { throw CocoaError(.featureUnsupported) }
            guard TextNoteEditor.collapseActive() else { throw CocoaError(.fileWriteUnknown) }
            self.clearExpandedNote()
            self.comeDown(on: nil)
            try self.line.hangText(text, trimEdges: false)
        }
        // Image hanging and selected-text Pin share the same Services provider.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Share.shared.clearAll()
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : -event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 42)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onHold = { [weak self] id in self?.hold(id) }
        line.onHangBack = { id in Held.hangBack(id) }
        line.onExpandNote = { [weak self] id in self?.expandNote(id) }
        line.onOpenNoteSource = { [weak self] source in self?.openNoteSource(source) }
        archiveLibrary.onLocateOriginal = { [weak self] source in self?.openNoteSource(source) }
        line.onArchive = { [weak self] ids in self?.archiveCards(ids) }
        line.onDiscard = { [weak self] id in
            guard let self, TextNoteEditor.collapseActive() else { return }
            if self.line.trash(id) { self.archiveLibrary.refreshIfVisible() }
        }
        line.onEditRemark = { [weak self] id in
            guard let self else { return }
            self.expandNote(id)
            guard self.line.expandedNoteID == id else { return }
            self.line.remarkEditingID = id
            self.line.remarkRequestSerial += 1
        }
        line.onCollapseNote = { [weak self] in self?.clearExpandedNote() }
        ideaComposer.onCommit = { [weak self] text in
            guard let self else { throw CocoaError(.featureUnsupported) }
            self.comeDown(on: nil)
            try self.line.hangText(text, trimEdges: false, kind: .idea)
        }
        DispatchQueue.main.async { [weak self] in self?.ideaComposer.prepare() }
        ideaComposer.onDidClose = { [weak self] in self?.desktopClicks.hide() }
        desktopClicks.onDismiss = { [weak self] in
            if let self, self.ideaComposer.isOpen { return self.ideaComposer.dismiss() }
            guard TextNoteEditor.isOpen else { return false }
            return TextNoteEditor.collapseActive()
        }

        NotificationCenter.default.publisher(for: RemarkAppearance.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.line.reloadThumbnails() }
            .store(in: &cancellables)
        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
                if let self, self.isRevealed, self.line.expandedNoteID != nil { self.desktopClicks.show() }
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }

        // Hover must be available after a normal launch even with no saved
        // photos. There may be no item or workspace event to start tracking.
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        noteActionTask?.cancel()
        selectedTextCapture.prepareForTermination()
        noteSourceNavigation.prepareForTermination()
        if ideaComposer.isOpen { _ = ideaComposer.saveDraft() }
        TextNoteEditor.flush()
        desktopClicks.hide(force: true)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        if Inbox.isEnabled { Inbox.restore() }
        Share.shared.clearAll()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                self.noteActionTask?.cancel()
                self.selectedTextCapture.prepareForTermination()
                self.noteSourceNavigation.prepareForTermination()
                if self.ideaComposer.isOpen { _ = self.ideaComposer.saveDraft() }
                TextNoteEditor.flush()
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        if let expanded = line.expandedNoteID,
           !line.items.contains(where: { $0.id == expanded && !$0.falling }) { clearExpandedNote() }
        Held.forget(except: Set(line.items.filter { !$0.falling && $0.held }.map(\.id)))
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent != ArchiveStore.folderName else { return }
        // Already hanging: a photo put back with ⌘Z comes out of the Trash
        // into the folder, and the watcher sees it arrive. It must not pull
        // the line over to the screen it was first taken on.
        guard !line.items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling })
        else { return }
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down on the screen it was taken on.
        comeDown(on: screen)
        // A screenshot macOS took already played its shutter, so it hangs
        // without a chime of its own. Copied images and watched folders,
        // which come with no sound, keep it.
        guard let id = line.hang(url, quietly: from != nil, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, !Self.reducesMotion, CaptureFlight.flightsInProgress < 2,
              let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    /// Reduce motion in Accessibility settings: photos land and leave
    /// without flying across the screen or falling down it.
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), pinned: item.kept, on: screen, ideaColor: IdeaPalette.color(item.ideaColorHex))
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index])
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // Hover is also an entry point to an empty line. Keep watching while
        // it is enabled, even when there is no content and no visible panel.
        if wanted || Self.opensFromMenuBar { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.isEditingNote = old.isEditingNote
        fresh.expandedHeight = old.expandedHeight
        fresh.becomesKeyOnlyIfNeeded = old.becomesKeyOnlyIfNeeded
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        if on, line.expandedNoteID != nil { desktopClicks.show() }
        if !on { desktopClicks.hide() }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() {
        if isRevealed {
            guard TextNoteEditor.collapseActive(animated: false) else { return }
            clearExpandedNote()
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        log.debug("Hover tracking started; records=\(self.line.liveCount, privacy: .public)")
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
        holdPutBackKey(false)
        holdPhotoKeys(over: nil)
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    static let centerWidthChoices = [320, 400, 480, 640]

    static var centerExclusionWidth: CGFloat {
        get {
            let saved = UserDefaults.standard.integer(forKey: "centerExclusionWidth")
            return centerWidthChoices.contains(saved) ? CGFloat(saved) : HoverRevealRegion.defaultCenterWidth
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "centerExclusionWidth") }
    }

    /// Keep a configurable central area clear for Dynamic Island extensions.
    /// The camera housing, when present, always gets an additional margin.
    static func centerExclusionBand(of screen: NSScreen) -> NSRect {
        let bar = menuBarBand(of: screen)
        let gap: NSRect?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            gap = NSRect(x: left.maxX, y: bar.minY,
                         width: right.minX - left.maxX, height: bar.height)
        } else {
            gap = nil
        }
        return HoverRevealRegion.centerBand(in: bar, cameraGap: gap,
                                             preferredWidth: centerExclusionWidth)
    }

    /// Observe both our transparent panel and other apps, without swallowing
    /// the click: outside clicks save/collapse an editor, then reach their target.
    /// Menu-bar clicks keep the original behavior of putting the whole line away.
    private func watchPointerClicks() {
        // A context menu may extend beyond the card. Let its selection finish
        // without dropping the editor's first responder or text selection.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification { self.menuTrackingDepth += 1 }
                    else { self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1) }
                }
                .store(in: &cancellables)
        }
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // This surface owns the complete desktop click. Its mouse-down
                // handler marks the press before saving and collapsing.
                if self.desktopClicks.owns(event.window) { return }
                if self.ideaComposer.isOpen, !self.ideaComposer.owns(event.window), self.menuTrackingDepth == 0,
                   !self.ideaComposer.textView.hasMarkedText() {
                    _ = self.ideaComposer.dismiss()
                }
                let p = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if self.isRevealed, let id = self.line.expandedNoteID {
                    let local = self.panel.convertPoint(fromScreen: p)
                    let flipped = CGPoint(x: local.x, y: self.panel.frame.height - local.y)
                    _ = TextNoteEditor.collapseIfOutside(flipped, cardRect: self.line.hitRects[id],
                        menuIsTracking: self.menuTrackingDepth > 0 || GrabView.isShowingMenu)
                }
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        guard !TextCapture.shared.isActive, !ideaComposer.isOpen else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }
        let inRevealBand = screenUnderPointer.map {
            HoverRevealRegion.canReveal(at: mouse, menuBar: Self.menuBarBand(of: $0),
                                        centerBand: Self.centerExclusionBand(of: $0))
        } ?? false
        let inCenterBand = screenUnderPointer.map {
            HoverRevealRegion.isInCenter(mouse, menuBar: Self.menuBarBand(of: $0),
                                         centerBand: Self.centerExclusionBand(of: $0))
        } ?? false

        guard isRevealed else {
            holdPutBackKey(false)
            holdPhotoKeys(over: nil)
            line.closeGaps()
            // Resting at either side of the menu bar brings the line down on
            // that screen. The central area is reserved for Dynamic Island.
            // Pushing against the top edge is part of it, and it
            // also works when another display sits above and the pointer
            // never stops.
            if Self.opensFromMenuBar, let screen = screenUnderPointer,
               inRevealBand, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    keepOpen = line.liveCount == 0
                    wanted = true
                    refresh()
                    reveal()
                    log.debug("Side hover revealed the line; records=\(self.line.liveCount, privacy: .public)")
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        // Yield to Dynamic Island when a hover-opened line crosses into the
        // central strip. Explicit shortcut/menu opens and active interactions
        // keep their existing behavior.
        if inCenterBand, !openedOnPurpose, line.expandedNoteID == nil, !GrabView.isDragging, !GrabView.isShowingMenu,
           !Share.shared.isOpen, line.pressedID == nil {
            hotZoneSince = nil
            setRevealed(false)
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }
        holdPutBackKey(inside && line.expandedNoteID == nil)
        holdPhotoKeys(over: inside && line.expandedNoteID == nil ? photo(under: mouse) : nil)
        // Gaps left by discarded photos close once the pointer moves away.
        if !inside { line.closeGaps() }

        let busy = pinned || line.expandedNoteID != nil || GrabView.isDragging || GrabView.isShowingMenu || Share.shared.isOpen
            || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.expandedNoteID == nil, line.canScroll {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Holding

    /// Takes a photo off the line to hold in front of you. The line goes
    /// up, so it is out of the way of the photo you are looking at.
    private func hold(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.held }) else { return }
        if Held.show(id, url: item.url, line: line, onHangBack: { [weak self] id, frame in
            self?.hangBack(id, from: frame)
        }) { line.setHeld(id, true) }
    }

    /// Text notes drop onto their clip just like a newly pinned note.
    /// Photos still fly from the floating window.
    private func hangBack(_ id: UUID, from frame: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
        if line.items.first(where: { $0.id == id })?.isTextNote == true {
            comeDown(on: screen)
            line.setHeld(id, false)
            return
        }
        line.setHeld(id, false)
        comeDown(on: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: frame)
        }
    }

    // MARK: Services

    @objc func pinSelectedText(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        textPinService.pinSelectedText(pasteboard, userData: userData, error: error)
    }

    /// The service macOS lists for images in Finder and elsewhere. What
    /// you hang yourself is pinned, and the line comes down to show it.
    @objc func hangOnLine(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        comeDown(on: nil)
        var any = false
        for url in urls where line.hangKept(url) { any = true }
        if !any { NSSound.beep() }
    }

    // MARK: Keys over a photo

    /// Delete and Space while the pointer rests on a photo: Delete does what
    /// its corner button does, Space takes a quick look, as in Finder. Like
    /// ⌘Z, they are borrowed as hot keys only then, so every other app keeps
    /// them.
    private var photoKeys: [HotKey] = []
    private var photoKeysFor: UUID?

    private func holdPhotoKeys(over id: UUID?) {
        let id = id.flatMap { id in line.items.first { $0.id == id && !$0.falling && !$0.held }?.id }
        guard id != photoKeysFor else { return }
        photoKeysFor = id
        photoKeys = []
        guard let id else { return }
        photoKeys = [
            HotKey(Shortcut(keyCode: kVK_Delete, modifiers: [], key: "\u{8}")) { [weak self] in
                self?.line.pressCorner(id)
            },
            HotKey(Shortcut(keyCode: kVK_Space, modifiers: [], key: " ")) { [weak self] in
                self?.quickLookToggle(id)
            },
        ].compactMap { $0 }
    }

    /// The photo whose card is under the pointer, if any.
    private func photo(under mouse: NSPoint) -> UUID? {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.contains(flipped) }?.key
    }

    /// Space opens Quick Look, and closes it again if it is already open.
    private func quickLookToggle(_ id: UUID) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            line.quickLook(id)
        }
    }

    // MARK: Putting back

    /// ⌘Z while the pointer is on the line. The line never takes the
    /// keyboard, so it only borrows ⌘Z then, as a hot key. Everywhere else
    /// ⌘Z stays the undo of the app you are in.
    private var putBackKey: HotKey?

    /// Set when another app holds ⌘Z, so it is not asked for again on every
    /// tick, only the next time the pointer comes to the line.
    private var putBackKeyRefused = false

    private func holdPutBackKey(_ hold: Bool) {
        guard hold && line.canPutBack else {
            putBackKey = nil
            putBackKeyRefused = false
            return
        }
        guard putBackKey == nil, !putBackKeyRefused else { return }
        putBackKey = HotKey(Shortcut.putBack) { [weak self] in self?.putBack() }
        putBackKeyRefused = putBackKey == nil
    }

    /// From the menu the line is usually up, so it comes down for a moment
    /// to show the photos going back.
    private func putBack() {
        if !isRevealed {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        }
        line.putBack()
        archiveLibrary.refreshIfVisible()
    }

    private func archiveCards(_ ids: [UUID]) {
        guard !ids.isEmpty, TextNoteEditor.collapseActive() else { return }
        clearExpandedNote()
        let step = UUID()
        var failure: Error?
        for (index, id) in ids.enumerated() {
            do { try line.archive(id, in: archiveLibrary.store, quietly: index > 0, step: step) }
            catch { if failure == nil { failure = error } }
        }
        archiveLibrary.refreshIfVisible()
        if let failure {
            DispatchQueue.main.async { self.showFileActionError("Could not archive", error: failure) }
        }
    }

    private func showFileActionError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = L(title)
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Shortcut

    private func expandNote(_ id: UUID) {
        if line.expandedNoteID == id { return }
        guard let item = line.items.first(where: { $0.id == id && !$0.falling }),
              item.isTextNote, let screen = panel.screen else { return }
        guard TextNoteEditor.collapseActive(animated: false) else { return }
        let collapsed = PeggedView.cardSize(for: item)
        let size = NoteExpansionLayout.expandedSize(collapsed: collapsed, availableHeight: screen.visibleFrame.height)
        line.expandedNoteSize = size
        panel.expandedHeight = size.height + 106
        panel.isEditingNote = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.placeOnScreen(screen)
        line.expandedNoteID = id
        holdPhotoKeys(over: nil)
        holdPutBackKey(false)
        reveal(pinned: true)
        desktopClicks.show()
    }

    private func clearExpandedNote() {
        desktopClicks.hide()
        line.remarkEditingID = nil
        line.expandedNoteID = nil
        panel.resignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.expandedNoteID == nil else { return }
            self.panel.isEditingNote = false
            self.panel.becomesKeyOnlyIfNeeded = true
            self.panel.expandedHeight = 0
            self.panel.placeOnScreen(self.panel.screen)
        }
    }

    private func showIdeaComposer() {
        guard TextNoteEditor.collapseActive() else { return }
        clearExpandedNote()
        holdPhotoKeys(over: nil)
        holdPutBackKey(false)
        setRevealed(false)
        ideaComposer.show()
        desktopClicks.show()
    }

    private func pinCurrentSelection() {
        if ideaComposer.isOpen { ideaComposer.focus(); return }
        guard !TextCapture.shared.isActive, noteActionTask == nil, !selectedTextCapture.isBusy else { return }
        let origin = NSWorkspace.shared.frontmostApplication
        let started = ProcessInfo.processInfo.systemUptime
        noteActionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.noteActionTask = nil }
            do {
                let text = try await self.selectedTextCapture.capture()
                let source = await self.noteSourceNavigation.capture(text: text, from: origin)
                try Task.checkCancellation()
                guard TextNoteEditor.collapseActive() else { return }
                self.clearExpandedNote()
                self.comeDown(on: nil)
                try self.line.hangText(text, trimEdges: false, source: source)
            } catch is CancellationError {
                return
            } catch {
                if let selectionError = error as? SelectionCaptureError,
                   case .noSelection = selectionError {
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    log.notice("Opening idea composer after empty selection check (\(milliseconds, privacy: .public) ms)")
                    self.showIdeaComposer()
                } else if let selectionError = error as? SelectionCaptureError,
                   case .permissionRequired = selectionError {
                    // Let macOS present its own consent prompt. Access is
                    // enabled by the user, never by editing system settings.
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    if AXIsProcessTrusted() { _ = CGRequestPostEventAccess() }
                    else { _ = AXIsProcessTrustedWithOptions(options) }
                } else {
                    let alert = NSAlert()
                    alert.messageText = L("Could not pin selected text")
                    alert.informativeText = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                        origin?.activate()
                    }
                }
            }
        }
    }

    private func openNoteSource(_ source: NoteSource) {
        guard noteActionTask == nil, !TextCapture.shared.isActive, !ideaComposer.isOpen,
              TextNoteEditor.collapseActive() else { return }
        clearExpandedNote()
        noteActionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.noteActionTask = nil }
            do {
                try await self.noteSourceNavigation.open(source)
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = L("Could not open the original")
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func captureTextNote() {
        guard !TextCapture.shared.isActive, noteActionTask == nil, !selectedTextCapture.isBusy else { return }
        if ideaComposer.isOpen, !ideaComposer.dismiss() { return }
        guard TextNoteEditor.collapseActive(animated: false) else { return }
        clearExpandedNote()
        holdPhotoKeys(over: nil)
        holdPutBackKey(false)
        setRevealed(false)
        // Capture now uses a much faster path; remove the old strip before
        // taking the frame instead of waiting for its retract animation.
        panel.orderOut(nil)
        TextCapture.shared.start { [weak self] text, screen in
            guard let self else { return }
            do {
                self.comeDown(on: screen)
                try self.line.hangText(text)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("Could not save note")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
        }
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        let description = on ? L("Tendedero, hanging copied images") : L("Tendedero")
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = count == 0
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let newIdea = ClosureMenuItem(L("New idea note…")) { [weak self] in
            DispatchQueue.main.async { self?.showIdeaComposer() }
        }
        newIdea.isEnabled = !TextCapture.shared.isActive && noteActionTask == nil && !selectedTextCapture.isBusy
        menu.addItem(newIdea)

        let pinText = ClosureMenuItem(L("Pin selected text"), key: "e") { [weak self] in
            self?.pinCurrentSelection()
        }
        pinText.keyEquivalentModifierMask = .command
        pinText.isEnabled = !TextCapture.shared.isActive && !selectedTextCapture.isBusy
        menu.addItem(pinText)

        let captureText = ClosureMenuItem(L("Select text and add note"), key: "e") { [weak self] in
            self?.captureTextNote()
        }
        captureText.keyEquivalentModifierMask = [.command, .shift]
        captureText.isEnabled = !TextCapture.shared.isActive && !selectedTextCapture.isBusy
        menu.addItem(captureText)

        menu.addItem(ClosureMenuItem(L("Archive Library…")) { [weak self] in
            DispatchQueue.main.async { self?.archiveLibrary.show() }
        })
        let clearItem = ClosureMenuItem(L("Archive all unpinned cards")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.items.contains { !$0.falling && !$0.kept && !$0.held }
        menu.addItem(clearItem)

        let putBackItem = ClosureMenuItem(L("Put back"), key: "z") { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = line.canPutBack
        menu.addItem(putBackItem)

        if !Held.heldIDs.isEmpty {
            menu.addItem(ClosureMenuItem(L("Hang everything back")) { Held.hangEverythingBack() })
        }

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests at either side of the menu bar")) { [weak self] in
            AppDelegate.opensFromMenuBar.toggle()
            self?.refresh()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let centerWidth = NSMenuItem(title: L("Center area to avoid"), action: nil, keyEquivalent: "")
        let widths = NSMenu()
        for width in Self.centerWidthChoices {
            let choice = ClosureMenuItem(String(format: L("%d pt wide"), width)) {
                AppDelegate.centerExclusionWidth = CGFloat(width)
            }
            choice.state = Self.centerExclusionWidth == CGFloat(width) ? .on : .off
            widths.addItem(choice)
        }
        centerWidth.submenu = widths
        options.addItem(centerWidth)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") { NoteSettings.shared.show() })

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// tendedero.app with the running version, and the menus' language when
    /// the website has it too, so the page answers in the same words.
    private static var updatesURL: URL {
        var components = URLComponents(string: "https://tendedero.app/")!
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var query = [URLQueryItem(name: "update", value: version)]
        if let language = Bundle.main.preferredLocalizations.first, ["en", "es", "gl", "fr", "pt-BR", "ja", "ko", "zh-Hans"].contains(language) {
            query.append(URLQueryItem(name: "lang", value: language))
        }
        components.queryItems = query
        return components.url!
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
