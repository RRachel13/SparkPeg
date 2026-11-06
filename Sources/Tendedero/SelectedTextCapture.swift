import AppKit
import ApplicationServices
import Carbon

@MainActor
protocol SelectionInput {
    var hasAccess: Bool { get }
    var frontmostPID: pid_t? { get }
    var modifiersHeld: Bool { get }
    var hasKnownSelection: Bool { get }
    func accessibilityText(pid: pid_t) async -> String?
    func sendCopy(pid: pid_t) throws
    func pause() async throws
}

extension SelectionInput { var hasKnownSelection: Bool { false } }

enum SelectionCaptureError: LocalizedError {
    case permissionRequired, noSelection, targetChanged, releaseKeys, clipboardUnavailable, busy
    var errorDescription: String? {
        switch self {
        case .permissionRequired: L("Allow SideLine in System Settings → Privacy & Security → Accessibility, then select the text again and press Command-E.")
        case .noSelection: L("No selected text was received. Select text that can be copied and try again, or use Command-Shift-E for screen text.")
        case .targetChanged: L("The active app changed. Select the text again and retry.")
        case .releaseKeys: L("Release the shortcut keys and try again.")
        case .clipboardUnavailable: L("The clipboard could not be preserved. Please try again.")
        case .busy: L("A text capture is already in progress.")
        }
    }
}

/// Materialize every format before asking another app to copy. Restoration is
/// conditional so a newer clipboard change is never overwritten by this snapshot.
struct SelectionClipboard {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) throws {
        changeCount = pasteboard.changeCount
        items = try (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw SelectionCaptureError.clipboardUnavailable }
                values[type] = data
            }
            return values
        }
        guard pasteboard.changeCount == changeCount else { throw SelectionCaptureError.clipboardUnavailable }
    }

    @discardableResult
    func restore(_ pasteboard: NSPasteboard, ifUnchanged expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

@MainActor
final class SelectedTextCapture {
    private let input: SelectionInput
    private let pasteboard: NSPasteboard
    private(set) var isBusy = false
    var onCopyActivity: ((Bool) -> Void)?
    private var restorePending: (() -> Void)?

    func prepareForTermination() { restorePending?(); restorePending = nil }

    init(input: SelectionInput? = nil, pasteboard: NSPasteboard = .general) {
        self.input = input ?? NativeSelectionInput()
        self.pasteboard = pasteboard
    }

    func capture() async throws -> String {
        guard !isBusy else { throw SelectionCaptureError.busy }
        isBusy = true
        defer { isBusy = false }
        guard input.hasAccess else { throw SelectionCaptureError.permissionRequired }
        guard let pid = input.frontmostPID else { throw SelectionCaptureError.noSelection }
        let direct = await input.accessibilityText(pid: pid)
        try Task.checkCancellation()
        guard input.frontmostPID == pid else { throw SelectionCaptureError.targetChanged }
        if let direct, !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.debug("Selected text read through accessibility")
            return direct
        }

        // An explicitly empty AX selection is a reliable blank-input state.
        if direct != nil { throw SelectionCaptureError.noSelection }

        // Carbon fires on key-down. Do not accidentally send Shift-Command-C
        // while the user is still physically holding the new shortcut.
        for _ in 0..<60 {
            guard input.frontmostPID == pid else { throw SelectionCaptureError.targetChanged }
            if !input.modifiersHeld { break }
            try await input.pause()
        }
        guard !input.modifiersHeld else { throw SelectionCaptureError.releaseKeys }
        try Task.checkCancellation()
        let previous = try SelectionClipboard(pasteboard)
        var observedCount: Int?
        onCopyActivity?(true)
        restorePending = { [weak self] in
            guard let self, let observedCount, self.input.frontmostPID == pid else { return }
            previous.restore(self.pasteboard, ifUnchanged: observedCount)
        }
        defer {
            restorePending?()
            restorePending = nil
            onCopyActivity?(false)
        }
        try input.sendCopy(pid: pid)
        if pasteboard.changeCount != previous.changeCount { observedCount = pasteboard.changeCount }
        // Read only a *new* copy. An unchanged clipboard is never a selection.
        // Two stable observations allow apps which publish formats in stages.
        var stableText: String?
        for attempt in 1...45 {
            try await input.pause()
            try Task.checkCancellation()
            guard input.frontmostPID == pid else { throw SelectionCaptureError.targetChanged }
            let count = pasteboard.changeCount
            // A blank selection typically doesn't publish anything. If the
            // selection is known or publishing has begun, keep the full budget.
            if attempt >= 8, count == previous.changeCount, !input.hasKnownSelection {
                throw SelectionCaptureError.noSelection
            }
            if count != previous.changeCount {
                let lastCount = observedCount
                observedCount = count
                if pasteboard.availableType(from: [.fileURL]) != nil { throw SelectionCaptureError.noSelection }
                if let text = try? TextPinService.selectedText(from: pasteboard), pasteboard.changeCount == count {
                    if lastCount == count && text == stableText {
                        log.debug("Selected text read through copy fallback")
                        return text
                    }
                    stableText = text
                } else { stableText = nil }
            }
        }
        throw SelectionCaptureError.noSelection
    }
}

@MainActor
final class NativeSelectionInput: SelectionInput {
    var hasAccess: Bool { AXIsProcessTrusted() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var modifiersHeld: Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty
    }

    private(set) var hasKnownSelection = false

    func accessibilityText(pid: pid_t) async -> String? {
        let probe: (String?, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.12)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    continuation.resume(returning: (nil, false)); return
                }
                let focused = value as! AXUIElement
                AXUIElementSetMessagingTimeout(focused, 0.12)
                var selected: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selected) == .success,
                   let string = selected as? String {
                    continuation.resume(returning: (string, !string.isEmpty)); return
                }
                var rangeValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
                   let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 {
                        continuation.resume(returning: (range.length == 0 ? "" : nil, range.length > 0)); return
                    }
                }
                continuation.resume(returning: (nil, false))
            }
        }
        hasKnownSelection = probe.1
        return probe.0
    }

    func sendCopy(pid: pid_t) throws {
        try postKey(Shortcut.keyCode(typing: "c") ?? kVK_ANSI_C, flags: .maskCommand, pid: pid)
    }

    func postKey(_ keyCode: Int, flags: CGEventFlags, pid: pid_t) throws {
        guard CGPreflightPostEventAccess() else { throw SelectionCaptureError.permissionRequired }
        guard frontmostPID == pid else { throw SelectionCaptureError.targetChanged }
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(keyCode)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw SelectionCaptureError.noSelection
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    func pause() async throws { try await Task.sleep(for: .milliseconds(40)) }
}
