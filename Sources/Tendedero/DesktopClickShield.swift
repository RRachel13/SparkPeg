import AppKit

/// Lives below ordinary application windows and above the wallpaper, only
/// while a note is expanded. A desktop click closes the note without ever
/// reaching Finder/Dock's click-to-reveal-desktop gesture.
@MainActor
final class DesktopClickShield {
    private(set) var panels: [DesktopClickPanel] = []
    private(set) var isEnabled = false
    private var pressedButtons = Set<Int>()
    private var hideAfterRelease = false
    var onDismiss: (() -> Bool)?

    func show(in frames: [NSRect] = NSScreen.screens.map(\.visibleFrame), orderFront: Bool = true) {
        let frames = frames.filter { !$0.isEmpty }
        if isEnabled, panels.map(\.frame) == frames {
            if orderFront { panels.forEach { $0.orderFrontRegardless() } }
            return
        }
        hide(force: true)
        isEnabled = true
        for frame in frames {
            let panel = DesktopClickPanel(frame: frame)
            let surface = DesktopClickSurface(frame: NSRect(origin: .zero, size: frame.size))
            surface.onPress = { [weak self] button in self?.press(button: button) }
            surface.onRelease = { [weak self] button in self?.release(button: button) }
            panel.contentView = surface
            panels.append(panel)
            if orderFront { panel.orderFrontRegardless() }
        }
    }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.contains { $0 === window }
    }

    func hide(force: Bool = false) {
        isEnabled = false
        // Keep the original mouse-up on the same surface. Removing it on
        // mouse-down alone would let half of a click reach the wallpaper.
        if !force, !pressedButtons.isEmpty { hideAfterRelease = true; return }
        pressedButtons.removeAll()
        hideAfterRelease = false
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
    }

    func press(button: Int) {
        pressedButtons.insert(button)
        guard isEnabled else { return }
        if onDismiss?() == true { hide() }
    }

    func release(button: Int) {
        pressedButtons.remove(button)
        if hideAfterRelease && pressedButtons.isEmpty { hide() }
    }
}

final class DesktopClickPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        // A tiny nonzero backing alpha is needed for WindowServer hit testing;
        // an entirely clear surface can pass the click through to the desktop.
        backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.01)
        hasShadow = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DesktopClickSurface: NSView {
    var onPress: ((Int) -> Void)?
    var onRelease: ((Int) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?(event.buttonNumber) }
    override func mouseUp(with event: NSEvent) { onRelease?(event.buttonNumber) }
    override func rightMouseDown(with event: NSEvent) { onPress?(event.buttonNumber) }
    override func rightMouseUp(with event: NSEvent) { onRelease?(event.buttonNumber) }
    override func otherMouseDown(with event: NSEvent) { onPress?(event.buttonNumber) }
    override func otherMouseUp(with event: NSEvent) { onRelease?(event.buttonNumber) }
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
}
