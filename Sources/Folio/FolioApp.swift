import SwiftUI
import UniformTypeIdentifiers

@main
struct FolioApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    @State private var app = AppModel.shared

    var body: some Scene {
        #if os(macOS)
        Window("Folio", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { menus }
        #else
        WindowGroup {
            RootView()
                .environment(app)
        }
        .commands { menus }
        #endif
    }

    @CommandsBuilder private var menus: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { app.presentOpenPanel() }.keyboardShortcut("o")
                Button("Add YouTube Video…") {
                    app.closeBook()
                    app.showAddVideo = true
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Show Library") { app.closeBook() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(app.reader == nil)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in Book…") { app.reader?.beginSearch() }
                    .keyboardShortcut("f")
                    .disabled(app.reader == nil)
                Button("Find Next") { app.reader?.findNext() }
                    .keyboardShortcut("g")
                    .disabled(app.reader?.search.isActive != true)
                Button("Find Previous") { app.reader?.findNext(false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(app.reader?.search.isActive != true)
            }
            CommandMenu("Study") {
                ForEach(Array(StudyTab.allCases.enumerated()), id: \.element) { i, tab in
                    Button(tab.rawValue) { app.reader?.study.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                        .disabled(app.reader == nil)
                }
                Button("Back to Text") { app.reader?.study.tab = nil }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(app.reader?.study.tab == nil)
                Divider()
                Button("Make Flashcard from Selection") { app.reader?.cardFromSelection() }
                    .disabled(app.reader == nil)
                Divider()
                Button("Review Due Cards") { app.showHub(.review) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Word List") { app.showHub(.words) }
                Button("Ask Your Library") { app.showHub(.ask) }
                Button("Knowledge Map") { app.showHub(.map) }
            }
            CommandMenu("Reader") {
                Button("Next Chapter") { app.reader?.next() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(app.reader == nil)
                Button("Previous Chapter") { app.reader?.previous() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(app.reader == nil)
                Divider()
                Button("Highlight Selection") { app.reader?.highlightSelection(.yellow) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(app.reader == nil)
                Button("Ask Claude About Selection") { app.reader?.askAboutSelection() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(app.reader == nil)
                Divider()
                Button("Ask Claude…") {
                    app.reader?.showChat = true
                    app.reader?.chat.focusToken += 1
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(app.reader == nil)
                Button("Toggle Claude Chat") { withAnimation { app.reader?.showChat.toggle() } }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(app.reader == nil)
                Button("Show Highlights") { app.reader?.sidebarTab = .highlights }
                    .disabled(app.reader == nil)
                Button("Show Note") { app.reader?.sidebarTab = .notes }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(app.reader == nil)
                Divider()
                Button("Zoom In") { app.zoom(.in) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { app.zoom(.out) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { app.zoom(.reset) }
                    .keyboardShortcut("0", modifiers: .command)
            }
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { MainActor.assumeIsolated { AppModel.shared.open(url) } }
    }

    /// "+" is a shifted key on most layouts, so plain ⌘= also zooms in (the menu item covers ⌘⇧=).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            MainActor.assumeIsolated { AppModel.shared.zoom(.in) }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

enum ZoomStep { case `in`, out, reset }

extension AppModel {
    /// PDFs scale the page; everything else scales the reading text.
    func zoom(_ step: ZoomStep) {
        if let reader, reader.kind == .pdf, let pdf = reader.pdfView {
            switch step {
            case .in: pdf.zoomIn(nil)
            case .out: pdf.zoomOut(nil)
            case .reset: pdf.autoScales = true
            }
            return
        }
        let settings = ReaderSettings.shared
        switch step {
        case .in: settings.fontSize = min(30, settings.fontSize + 1)
        case .out: settings.fontSize = max(14, settings.fontSize - 1)
        case .reset: settings.fontSize = 19
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let reader = app.reader {
                ReaderView(reader: reader).id(reader.bookID)
                    .transition(.opacity)
            } else {
                #if os(macOS)
                HubView()
                    .transition(.opacity)
                #else
                // The tab picker lives in the navigation bar, which iPad only draws inside a stack.
                NavigationStack {
                    HubView().navigationBarTitleDisplayMode(.inline)
                }
                .transition(.opacity)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.reader?.bookID)
        .task {
            // `-openBook <id>` on the command line opens straight into a book from the shelf.
            guard let id = UserDefaults.standard.string(forKey: "openBook") else { return }
            let shelf = LibraryStore.reconcile(app.library, open: nil)
            if let item = shelf.first(where: { $0.id == id }) { app.open(item.url) }
        }
        .overlay {
            if app.isLoading {
                ProgressView().controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Couldn't open book", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    #if os(macOS)
    /// Runs before the stores below read anything, so they start from the migrated data.
    @ObservationIgnored private let migrated: Void = CloudStore.migrateData()
    #endif
    var library: [LibraryItem] = LibraryStore.load()
    var reader: ReaderModel?
    let hub = StudyHub()
    let words = WordStore()
    /// `-hubTab Review` on the command line opens straight to a tab.
    var hubTab: HubTab = UserDefaults.standard.string(forKey: "hubTab").flatMap(HubTab.init(rawValue:)) ?? .library
    var showAddVideo = false
    var isLoading = false
    var errorMessage: String?

    static let bookTypes: [UTType] = [UTType(filenameExtension: "epub") ?? .data, .pdf]
    /// Presents the system file picker on iPad.
    var showImporter = false

    func presentOpenPanel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.bookTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB or PDF to read"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
        #else
        closeBook()
        showImporter = true
        #endif
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.open(url) } }
        }
        return true
    }

    func showHub(_ tab: HubTab) {
        closeBook()
        hubTab = tab
    }

    /// Opens a book, optionally at a section saved by `ReaderModel.sectionKey`.
    func open(_ url: URL, section: String? = nil) {
        // Files picked on iPad sit outside the sandbox and can only be seen while access is open.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard CloudStore.isPresent(url) else {
            errorMessage = "The file at \(url.path) no longer exists."
            library.removeAll { $0.path == url.path }
            LibraryStore.save(library)
            return
        }
        reader?.flush()
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    // With a managed folder the book is copied into it once and read from there on every device.
                    let file = try CloudStore.importBook(url)
                    try await CloudStore.ensureDownloaded(file)
                    return try BookLoader.load(url: file)
                }.value
                let model = ReaderModel(loaded)
                model.announce()
                model.onProgress = { [weak self] id, p in self?.updateProgress(id, p) }
                if let section { model.jump(toSectionKey: section) }
                reader = model
                library.removeAll { $0.id == loaded.bookID || $0.path == url.path }
                library.insert(LibraryItem(id: loaded.bookID, path: loaded.url.path, title: loaded.title, author: loaded.author,
                                           kind: loaded.kind, lastOpened: Date(), progress: model.record.progress), at: 0)
                LibraryStore.save(library)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeBook() {
        guard reader != nil else { return }
        reader?.flush()
        reader?.chat.stop()
        reader = nil
        hub.reload()
    }

    /// Removes a book from every device's shelf (its highlights and study data are kept).
    func remove(_ item: LibraryItem) {
        library.removeAll { $0.id == item.id }
        LibraryStore.save(library)
        CloudStore.removeBookFile(id: item.id, kind: item.kind)
    }

    /// Picks up books added or removed on another device, and (once, on the Mac) moves earlier data into iCloud.
    func syncLibrary() {
        let current = library, open = reader?.bookID
        Task {
            let updated = await Task.detached(priority: .utility) { () -> [LibraryItem] in
                #if os(macOS)
                CloudStore.migrateBooks(current)
                #endif
                return LibraryStore.reconcile(current, open: open)
            }.value
            // Keep anything opened while the scan ran.
            let added = library.filter { item in !current.contains { $0.id == item.id } }
            let merged = added + updated.filter { item in !added.contains { $0.id == item.id } }
            if merged != library {
                library = merged
                LibraryStore.save(library)
            }
            hub.reload()
        }
    }

    private var progressSaveTask: Task<Void, Never>?
    private func updateProgress(_ id: String, _ p: Double) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        library[i].progress = p
        progressSaveTask?.cancel()
        progressSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            LibraryStore.save(library)
        }
    }
}
