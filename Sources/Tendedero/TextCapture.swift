import AppKit
import ScreenCaptureKit
import QuartzCore

@MainActor
final class TextCapture {
    static let shared = TextCapture()
    private(set) var isActive = false
    private var generation = UUID()
    private var pages: [TextCapturePage] = []
    private var previousApp: NSRunningApplication?
    private var completion: ((String, NSScreen) -> Void)?
    private var explainedPermissionFailure = false

    func start(completion: @escaping (String, NSScreen) -> Void) {
        guard !isActive else { return }
        // ScreenCaptureKit is the authority. A CoreGraphics preflight can
        // disagree with the system's visible toggle after a local rebuild;
        // do not block a working capture behind that separate check.
        isActive = true
        generation = UUID()
        let token = generation
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        let started = ProcessInfo.processInfo.systemUptime
        Task {
            do {
                let activeScreen = LinePanel.screenUnderPointer()
                let screens = NSScreen.screens.sorted { $0 == activeScreen && $1 != activeScreen }
                for screen in screens {
                    let image = try await ScreenCapturePipeline.capture(screen)
                    explainedPermissionFailure = false
                    guard isActive, token == generation else { return }
                    // Show the active screen as soon as its frame arrives;
                    // do not hold it back for other displays or for OCR.
                    let page = show(screen: screen, image: image)
                    let dimMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    log.debug("Text capture overlay visible after \(dimMilliseconds, privacy: .public) ms")
                    let size = page.screen.frame.size
                    Task {
                        do {
                            let glyphs = try await Task.detached(priority: .userInitiated) {
                                try ScreenTextRecognition.recognize(image, size: size)
                            }.value
                            guard isActive, token == generation else { return }
                            page.view.install(glyphs)
                            let readyMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                            log.debug("Text selection ready after \(readyMilliseconds, privacy: .public) ms")
                        } catch {
                            guard isActive, token == generation else { return }
                            page.view.showRecognitionError()
                        }
                    }
                }
            } catch {
                guard token == generation else { return }
                cancel()
                let failure = error as NSError
                log.error("Screen capture failed: \(failure.domain, privacy: .public), code \(failure.code, privacy: .public)")
                if CapturePermissionFailure.isDenied(error) {
                    explainPermissionFailure()
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("Could not recognize screen text")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func explainPermissionFailure() {
        guard !explainedPermissionFailure else { NSSound.beep(); return }
        explainedPermissionFailure = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Screen capture was denied by macOS")
        alert.informativeText = L("If SideLine is already enabled, its permission may still belong to an older local build. Remove the old entry, add this SideLine.app, then quit and reopen it. The app will retry capture directly instead of repeatedly asking you to authorize.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Show this app in Finder"))
        alert.addButton(withTitle: L("Cancel"))
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else if result == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    private func show(screen: NSScreen, image: CGImage) -> TextCapturePage {
            let page = TextCapturePage(screen: screen, image: image)
            page.view.onSelectionStart = { [weak self, weak page] additive in
                guard !additive else { return }
                for other in self?.pages ?? [] where other !== page { other.view.clearSelection() }
            }
            page.view.onConfirm = { [weak self] in self?.finish() }
            page.view.onCancel = { [weak self] in self?.cancel() }
            pages.append(page)
            page.view.layoutSubtreeIfNeeded()
            page.window.orderFrontRegardless()
            if pages.count == 1 {
                page.window.makeKeyAndOrderFront(nil)
                page.window.makeFirstResponder(page.view)
            }
            return page
    }

    func finish() {
        let selected = pages.filter { !$0.view.selection.text.isEmpty }.sorted {
            if $0.screen.frame.maxY != $1.screen.frame.maxY { return $0.screen.frame.maxY > $1.screen.frame.maxY }
            return $0.screen.frame.minX < $1.screen.frame.minX
        }
        guard let first = selected.first else {
            NSSound.beep()
            return
        }
        let text = selected.map { $0.view.selection.text }.joined(separator: "\n")
        let callback = completion
        let screen = first.screen
        close()
        if let previousApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
        callback?(text, screen)
    }

    func cancel() {
        close()
        if let previousApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    private func close() {
        generation = UUID()
        for page in pages { page.window.orderOut(nil); page.window.close() }
        pages = []
        completion = nil
        isActive = false
    }
}

enum CapturePermissionFailure {
    static func isDenied(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == SCStreamErrorDomain && failure.code == -3801
    }
}

@MainActor
private enum ScreenCapturePipeline {
    static func capture(_ screen: NSScreen) async throws -> CGImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CocoaError(.fileReadUnknown) }
        if #available(macOS 26.0, *) {
            // No per-keystroke SCShareableContent/window enumeration. Keep
            // Retina resolution and request only the SDR frame in memory.
            let configuration = SCScreenshotConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.dynamicRange = .sdr
            configuration.fileURL = nil
            let output = try await SCScreenshotManager.captureScreenshot(rect: CGDisplayBounds(number), configuration: configuration)
            guard let image = output.sdrImage else { throw CocoaError(.fileReadUnknown) }
            return image
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number })
        else { throw CocoaError(.fileReadUnknown) }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
    }
}

@MainActor
private final class TextCapturePage {
    let screen: NSScreen
    let image: CGImage
    let view: TextCaptureView
    let window: TextCaptureWindow

    init(screen: NSScreen, image: CGImage) {
        self.screen = screen
        self.image = image
        view = TextCaptureView(image: image, size: screen.frame.size)
        window = TextCaptureWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = view
    }
}

private final class TextCaptureWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TextCaptureView: NSView {
    private let snapshot = CALayer()
    private let dimming = CALayer()
    private let restored = CALayer()
    private let restoredMask = CAShapeLayer()
    private let outline = CAShapeLayer()
    private(set) var selection = TextSelection(glyphs: [])
    private var ready = false
    private let status = NSTextField(labelWithString: L("Recognizing screen text…"))
    private let confirm = NSButton(title: L("Hang note ↵"), target: nil, action: nil)
    private let cancel = NSButton(title: L("Cancel Esc"), target: nil, action: nil)
    private let hud = NSVisualEffectView()
    var onSelectionStart: ((Bool) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    init(image: CGImage, size: CGSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let noActions: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(),
                                           "contents": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        layer?.actions = noActions
        layer?.contentsScale = CGFloat(image.width) / max(1, size.width)
        snapshot.contents = image
        snapshot.contentsGravity = .resize
        dimming.backgroundColor = NSColor.black.cgColor
        dimming.opacity = 0.58
        restored.contents = image
        restored.contentsGravity = .resize
        restoredMask.fillColor = NSColor.white.cgColor
        restored.mask = restoredMask
        outline.fillColor = nil
        outline.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        outline.lineWidth = 0.5
        for item in [snapshot, dimming, restored, outline] {
            item.actions = noActions
            item.contentsScale = CGFloat(image.width) / max(1, size.width)
            layer?.addSublayer(item)
        }
        restoredMask.actions = noActions
        CATransaction.commit()
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 14
        hud.layer?.masksToBounds = true
        addSubview(hud)
        status.font = .systemFont(ofSize: 14, weight: .medium)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        hud.addSubview(status)
        confirm.target = self
        confirm.action = #selector(confirmSelection)
        confirm.bezelStyle = .rounded
        hud.addSubview(confirm)
        cancel.target = self
        cancel.action = #selector(cancelSelection)
        cancel.bezelStyle = .rounded
        hud.addSubview(cancel)
        setAccessibilityLabel(L("Screen text selection"))
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [snapshot, dimming, restored, outline] { item.frame = bounds }
        restoredMask.frame = bounds
        CATransaction.commit()
        let width = min(bounds.width - 32, 850)
        hud.frame = NSRect(x: (bounds.width - width) / 2, y: 28, width: width, height: 66)
        status.frame = NSRect(x: 18, y: 22, width: max(0, width - 270), height: 24)
        confirm.frame = NSRect(x: width - 242, y: 17, width: 138, height: 32)
        cancel.frame = NSRect(x: width - 102, y: 17, width: 90, height: 32)
    }

    func install(_ glyphs: [TextGlyph]) {
        selection = TextSelection(glyphs: glyphs)
        ready = true
        updateStatus()
        updateSelectionAppearance()
    }

    func showRecognitionError() {
        status.stringValue = L("Could not recognize screen text")
        ready = false
    }

    func clearSelection() {
        selection.clear()
        updateStatus()
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        let path = CGMutablePath()
        for glyph in selection.selectedGlyphs { path.addRect(glyph.rect.insetBy(dx: -1, dy: -2)) }
        // Retain the original frame as a GPU texture. Selection changes only
        // a vector mask, instead of re-drawing millions of screen pixels.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        restoredMask.path = path
        outline.path = path
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        guard ready else { return }
        window?.makeFirstResponder(self)
        let additive = event.modifierFlags.contains(.shift)
        onSelectionStart?(additive)
        selection.begin(at: convert(event.locationInWindow, from: nil), additive: additive)
        updateStatus()
        updateSelectionAppearance()
    }

    override func mouseDragged(with event: NSEvent) {
        guard ready else { return }
        selection.extend(to: convert(event.locationInWindow, from: nil))
        updateStatus()
        updateSelectionAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        guard ready else { return }
        selection.extend(to: convert(event.locationInWindow, from: nil))
        updateStatus()
        updateSelectionAppearance()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onConfirm?()
        case 0 where event.modifierFlags.contains(.command):
            selection.selectAll()
            updateStatus()
            updateSelectionAppearance()
        default: break
        }
    }

    private func updateStatus() {
        confirm.isEnabled = !selection.text.isEmpty
        if !ready { status.stringValue = L("Recognizing screen text…") }
        else if selection.glyphs.isEmpty { status.stringValue = L("No text found. Press Esc to cancel.") }
        else if selection.selected.isEmpty { status.stringValue = L("Drag to select · Shift adds ranges · Enter hangs · Esc cancels") }
        else { status.stringValue = String(format: L("%d characters selected · Shift adds ranges · Enter hangs"), selection.text.count) }
    }

    @objc private func confirmSelection() { onConfirm?() }
    @objc private func cancelSelection() { onCancel?() }
}
