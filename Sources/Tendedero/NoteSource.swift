import AppKit
import ApplicationServices
import Carbon

/// The original search text is independent of edits to the note itself.
struct NoteSource: Codable, Equatable {
    private static let attribute = "app.sideline.source"
    static let codexID = "com.openai.codex"
    static let browserIDs: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                                         "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser"]

    let url: URL
    let excerpt: String
    let browserID: String?

    init?(url: URL, text: String, browserID: String? = nil) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let line = lines.first(where: { $0.count >= 12 }) ?? lines.max(by: { $0.count < $1.count }),
              !line.isEmpty else { return nil }
        self.url = url
        self.excerpt = String(line.prefix(180))
        self.browserID = browserID
        guard destination != nil else { return nil }
    }

    static func isChatLink(_ url: URL) -> Bool {
        guard url.scheme == "codex", url.host == "threads", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2, url.pathComponents[1] != "new" else { return false }
        return url.pathComponents[1].range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    var destination: URL? {
        guard !excerpt.isEmpty, excerpt.count <= 180 else { return nil }
        guard let browserID else { return Self.isChatLink(url) ? url : nil }
        guard Self.browserIDs.contains(browserID), Self.isWebPage(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let anchor = parts.percentEncodedFragment?.components(separatedBy: ":~:").first ?? ""
        // Comma and hyphen delimit fields in the text directive, including in
        // phrases that contain Markdown, code or punctuation.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~")
        guard let text = excerpt.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        parts.percentEncodedFragment = anchor + ":~:text=" + text
        return parts.url
    }

    static func read(from note: URL) -> NoteSource? {
        guard TextNote.isNote(note), let data = try? NoteFileAttribute.read(attribute, from: note),
              let source = try? JSONDecoder().decode(Self.self, from: data),
              source.destination != nil else { return nil }
        return source
    }

    func write(to note: URL) throws {
        try NoteFileAttribute.write(JSONEncoder().encode(self), name: Self.attribute, to: note)
    }
}

@MainActor
final class NoteSourceNavigation {
    private let input = NativeSelectionInput()
    private let pasteboard = NSPasteboard.general
    private var restoreClipboard: (() -> Void)?

    func prepareForTermination() {
        restoreClipboard?()
        restoreClipboard = nil
    }

    func capture(text: String, from app: NSRunningApplication?) async -> NoteSource? {
        guard let app, let id = app.bundleIdentifier, input.frontmostPID == app.processIdentifier else { return nil }
        let pid = app.processIdentifier
        if id == NoteSource.codexID {
            guard await waitForModifiers(pid), let url = await copyChatLink(pid) else { return nil }
            return NoteSource(url: url, text: text)
        }
        guard NoteSource.browserIDs.contains(id) else { return nil }
        let url = await Self.accessibilityProbe(pid) { app in
            (id == "com.apple.Safari" ? Self.safariAddress(app) : nil) ?? Self.pageURL(app)
        }
        guard input.frontmostPID == pid, !Task.isCancelled else { return nil }
        if let url { return NoteSource(url: url, text: text, browserID: id) }
        guard await waitForModifiers(pid), let url = await addressBarURL(pid) else { return nil }
        return NoteSource(url: url, text: text, browserID: id)
    }

    func open(_ source: NoteSource) async throws {
        guard let url = source.destination else { throw CocoaError(.fileReadCorruptFile) }
        let workspace = NSWorkspace.shared
        let appID = source.browserID ?? NoteSource.codexID
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: appID) else {
            if source.browserID != nil, workspace.open(url) { return }
            throw CocoaError(.fileNoSuchFile)
        }
        let app = try await workspace.open([url], withApplicationAt: appURL, configuration: .init())
        guard source.browserID == nil, input.hasAccess else { return }
        let pid = app.processIdentifier
        // Opening an existing instance can return before its chat changes.
        // Read its current chat link before sending anything to Find.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(140))
            guard input.frontmostPID == pid else { continue }
            guard await waitForModifiers(pid), await copyChatLink(pid) == url else { continue }
            do { try await find(source.excerpt, pid: pid) }
            catch is CancellationError { throw CancellationError() }
            catch { log.notice("Could not fill the Codex chat search field") }
            return
        }
        log.notice("Opened Codex link without confirming its active chat for Find")
    }

    private func waitForModifiers(_ pid: pid_t) async -> Bool {
        for _ in 0..<10 {
            guard input.frontmostPID == pid, !Task.isCancelled else { return false }
            if !input.modifiersHeld { return true }
            try? await input.pause()
        }
        return false
    }

    private func copyChatLink(_ pid: pid_t) async -> URL? {
        guard !Task.isCancelled, let previous = try? SelectionClipboard(pasteboard) else { return nil }
        defer { prepareForTermination() }
        let key = Shortcut.keyCode(typing: "l") ?? kVK_ANSI_L
        do { try input.postKey(key, flags: [.maskCommand, .maskAlternate], pid: pid) }
        catch { return nil }
        for _ in 0..<10 {
            try? await input.pause()
            let count = pasteboard.changeCount
            guard input.frontmostPID == pid else { return nil }
            if count != previous.changeCount {
                guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      NoteSource.isChatLink(url), pasteboard.changeCount == count else { return nil }
                restoreClipboard = { [pasteboard] in previous.restore(pasteboard, ifUnchanged: count) }
                return url
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private func find(_ text: String, pid: pid_t) async throws {
        let findKey = Shortcut.keyCode(typing: "f") ?? kVK_ANSI_F
        try input.postKey(findKey, flags: .maskCommand, pid: pid)
        for _ in 0..<10 {
            try await input.pause()
            guard input.frontmostPID == pid else { return }
            let searchIsFocused = await Self.accessibilityProbe(pid) { app in
                guard let focused = Self.element(app, kAXFocusedUIElementAttribute),
                      Self.value(focused, kAXRoleAttribute) as? String == kAXTextFieldRole else { return false }
                let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                return labels.contains {
                    guard let label = Self.value(focused, $0) as? String else { return false }
                    return ["在聊天中查找", "Find in chat", "在聊天中尋找", "在對話中尋找"]
                        .contains { label.localizedCaseInsensitiveContains($0) }
                }
            }
            if searchIsFocused, input.frontmostPID == pid {
                try Task.checkCancellation()
                let previous = try SelectionClipboard(pasteboard)
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setString("", forType: .init("org.nspasteboard.TransientType"))
                pasteboard.clearContents()
                let wrote = pasteboard.writeObjects([item])
                let count = pasteboard.changeCount
                restoreClipboard = { [pasteboard] in previous.restore(pasteboard, ifUnchanged: count) }
                defer { prepareForTermination() }
                guard wrote else { return }
                let selectAllKey = Shortcut.keyCode(typing: "a") ?? kVK_ANSI_A
                try input.postKey(selectAllKey, flags: .maskCommand, pid: pid)
                let pasteKey = Shortcut.keyCode(typing: "v") ?? kVK_ANSI_V
                try input.postKey(pasteKey, flags: .maskCommand, pid: pid)
                try await Task.sleep(for: .milliseconds(220))
                return
            }
        }
        log.notice("Codex Find opened without an identifiable chat search field")
    }

    private func addressBarURL(_ pid: pid_t) async -> URL? {
        let key = Shortcut.keyCode(typing: "l") ?? kVK_ANSI_L
        do { try input.postKey(key, flags: .maskCommand, pid: pid) }
        catch { return nil }
        try? await Task.sleep(for: .milliseconds(85))
        let url = await Self.accessibilityProbe(pid) { app -> URL? in
            guard let field = Self.element(app, kAXFocusedUIElementAttribute),
                  Self.value(field, kAXRoleAttribute) as? String == kAXTextFieldRole else { return nil }
            var parent = Self.element(field, kAXParentAttribute)
            for _ in 0..<8 {
                guard let element = parent else { break }
                let role = Self.value(element, kAXRoleAttribute) as? String
                if role == "AXWebArea" { return nil }
                if role == kAXToolbarRole {
                    return Self.webURL(Self.value(field, kAXSelectedTextAttribute))
                        ?? Self.webURL(Self.value(field, kAXValueAttribute))
                }
                parent = Self.element(element, kAXParentAttribute)
            }
            return nil
        }
        guard input.frontmostPID == pid else { return nil }
        try? input.postKey(kVK_Escape, flags: [], pid: pid)
        return url
    }

    nonisolated private static func safariAddress(_ app: AXUIElement) -> URL? {
        guard let window = element(app, kAXFocusedWindowAttribute),
              let toolbar = children(window).first(where: { value($0, kAXRoleAttribute) as? String == kAXToolbarRole }) else { return nil }
        for group in children(toolbar) {
            for field in [group] + children(group) {
                if value(field, kAXIdentifierAttribute) as? String == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" {
                    return webURL(value(field, kAXValueAttribute))
                }
            }
        }
        return nil
    }

    nonisolated private static func pageURL(_ app: AXUIElement) -> URL? {
        var node = element(app, kAXFocusedUIElementAttribute)
        var page: URL?
        for _ in 0..<24 {
            guard let current = node else { break }
            if value(current, kAXRoleAttribute) as? String == "AXWebArea",
               let url = webURL(value(current, kAXURLAttribute)) { page = url }
            node = element(current, kAXParentAttribute)
        }
        if let page { return page }
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        return webURL(value(window, kAXDocumentAttribute))
    }

    nonisolated private static func webURL(_ value: CFTypeRef?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
        guard let url, NoteSource.isWebPage(url) else { return nil }
        return url
    }

    nonisolated private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    nonisolated private static func accessibilityProbe<T>(
        _ pid: pid_t, _ read: @escaping (AXUIElement) -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.12)
                continuation.resume(returning: read(app))
            }
        }
    }
}
