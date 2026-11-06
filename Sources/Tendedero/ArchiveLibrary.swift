import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveStore {
    static let folderName = "SideLine Archive"
    let folder: URL

    struct Entry: Identifiable {
        let url: URL
        let date: Date?
        var id: URL { url }
    }

    func prepare() throws {
        // The parent was picked by the user. If a drive is disconnected or a
        // folder moved, report the failure instead of recreating its path.
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
           try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func entries() throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .creationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles])
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  TextNote.isNote(url) || isRecording(url) || values.contentType?.conforms(to: .image) == true else { return nil }
            return Entry(url: url, date: values.creationDate)
        }.sorted {
            let first = $0.date ?? .distantPast, second = $1.date ?? .distantPast
            if first != second { return first > second }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

@MainActor
final class ArchiveLibrary: ObservableObject {
    @Published private(set) var entries: [ArchiveStore.Entry] = []
    @Published private(set) var store: ArchiveStore
    @Published private(set) var loadError: String?
    @Published var selection: URL?
    var onLocateOriginal: ((NoteSource) -> Void)?

    private let defaults: UserDefaults
    private let folderKey = "archiveParent"
    private var window: NSWindow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let defaultParent = Bundle.main.object(forInfoDictionaryKey: "SideLineWorkspacePath") as? String
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let parent = URL(fileURLWithPath: defaults.string(forKey: folderKey) ?? defaultParent, isDirectory: true)
        store = ArchiveStore(folder: parent.appendingPathComponent(ArchiveStore.folderName, isDirectory: true))
    }

    func show() {
        if window == nil {
            let archive = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                   backing: .buffered, defer: false)
            archive.title = L("Archive Library")
            archive.minSize = NSSize(width: 560, height: 330)
            archive.isReleasedWhenClosed = false
            archive.contentViewController = NSHostingController(rootView: ArchiveView(library: self))
            archive.center()
            window = archive
        }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible() {
        if window?.isVisible == true { reload() }
    }

    func reload() {
        do {
            try store.prepare()
            entries = try store.entries()
            loadError = nil
        } catch {
            entries = []
            loadError = error.localizedDescription
        }
        if !entries.contains(where: { $0.url == selection }) { selection = entries.first?.url }
    }

    func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.folder.deletingLastPathComponent()
        panel.prompt = L("Choose folder")
        panel.message = String(format: L("Archives will be stored in the %@ folder at this location. Existing archives stay in their current folder."),
                               ArchiveStore.folderName)
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let parent = panel.url, let self else { return }
            let parentURL = parent.standardizedFileURL
            let folder = parentURL.lastPathComponent == ArchiveStore.folderName ? parentURL
                : parentURL.appendingPathComponent(ArchiveStore.folderName, isDirectory: true)
            let chosen = ArchiveStore(folder: folder)
            do {
                try chosen.prepare()
                self.defaults.set(folder.deletingLastPathComponent().path, forKey: self.folderKey)
                self.store = chosen
                self.reload()
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }
}

private struct ArchiveView: View {
    @ObservedObject var library: ArchiveLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(library.store.folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(library.store.folder.path)
                Spacer()
                Button(L("Choose archive folder…")) { library.chooseFolder() }
                Button(L("Open folder")) { NSWorkspace.shared.open(library.store.folder) }
                    .disabled(library.loadError != nil)
                Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Refresh archive"))
            }
            .padding(12)
            Divider()
            if let error = library.loadError {
                ContentUnavailableView(L("Could not read the archive"), systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if library.entries.isEmpty {
                ContentUnavailableView(L("The archive is empty"), systemImage: "archivebox",
                                       description: Text(L("Archive a card from its menu to see it here.")))
            } else {
                HSplitView {
                    List(library.entries, selection: $library.selection) { entry in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.url.lastPathComponent).lineLimit(1)
                                if let date = entry.date {
                                    Text(date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: TextNote.isNote(entry.url) ? "text.alignleft" : "photo")
                        }
                        .tag(entry.url)
                    }
                    .frame(minWidth: 185, idealWidth: 245)
                    if let selected = library.selection {
                        ArchivePreview(url: selected, onLocateOriginal: library.onLocateOriginal)
                            .id(selected)
                            .frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArchivePreview: View {
    let url: URL
    let onLocateOriginal: ((NoteSource) -> Void)?
    @State private var note: NoteDocument?
    @State private var image: NSImage?
    @State private var source: NoteSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(L("Open")) { NSWorkspace.shared.open(url) }
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let source { Button(L("Locate original")) { onLocateOriginal?(source) } }
            }
            if let note {
                ArchivedNoteBody(url: url, note: note)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .task {
            if TextNote.isNote(url) {
                note = try? NoteDocument.read(url)
                source = NoteSource.read(from: url)
            } else {
                image = makeThumbnail(url, maxPixels: 1600)
            }
        }
    }
}


private struct ArchivedNoteBody: NSViewRepresentable {
    let url: URL
    let note: NoteDocument

    func makeNSView(context: Context) -> InlineNoteBody {
        InlineNoteBody(url: url, text: note.text, fontSize: 13, remark: note.remark, kind: note.kind,
                       readingOnly: true, followsAppearance: true)
    }

    func updateNSView(_ nsView: InlineNoteBody, context: Context) {}
}
