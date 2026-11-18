import SwiftUI
import UniformTypeIdentifiers

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        Window("Folio", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
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
                Button("Bigger Text") { ReaderSettings.shared.fontSize = min(30, ReaderSettings.shared.fontSize + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { ReaderSettings.shared.fontSize = max(14, ReaderSettings.shared.fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { MainActor.assumeIsolated { AppModel.shared.open(url) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
                HubView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.reader?.bookID)
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

    var library: [LibraryItem] = LibraryStore.load()
    var reader: ReaderModel?
    let hub = StudyHub()
    /// `-hubTab Review` on the command line opens straight to a tab.
    var hubTab: HubTab = UserDefaults.standard.string(forKey: "hubTab").flatMap(HubTab.init(rawValue:)) ?? .library
    var showAddVideo = false
    var isLoading = false
    var errorMessage: String?

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an EPUB or PDF to read"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
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
        guard FileManager.default.fileExists(atPath: url.path) else {
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
                let loaded = try await Task.detached(priority: .userInitiated) { try BookLoader.load(url: url) }.value
                let model = ReaderModel(loaded)
                model.onProgress = { [weak self] id, p in self?.updateProgress(id, p) }
                if let section { model.jump(toSectionKey: section) }
                reader = model
                library.removeAll { $0.id == loaded.bookID || $0.path == url.path }
                library.insert(LibraryItem(id: loaded.bookID, path: url.path, title: loaded.title, author: loaded.author,
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

    func remove(_ item: LibraryItem) {
        library.removeAll { $0.id == item.id }
        LibraryStore.save(library)
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
