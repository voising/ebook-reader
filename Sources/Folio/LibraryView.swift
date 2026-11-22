import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the bookshelf plus the library-wide study tools.
struct HubView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.hubTab {
            case .library: LibraryView()
            case .review: ReviewHubView(hub: app.hub)
            case .words: WordsHubView(store: app.words)
            case .ask: AskHubView(hub: app.hub)
            case .map: MapHubView(hub: app.hub)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(platform: .windowBackgroundColor))
        .navigationTitle("Folio")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $app.hubTab) {
                    ForEach(HubTab.allCases.filter { Platform.hasClaude || $0 != .ask }) { tab in
                        Text(tab == .review && !app.hub.due.isEmpty ? "Review (\(app.hub.due.count))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .sheet(isPresented: $app.showAddLink) { AddLinkSheet().environment(app) }
        .fileImporter(isPresented: $app.showImporter, allowedContentTypes: AppModel.bookTypes) { result in
            if case .success(let url) = result { app.open(url) }
        }
        .onAppear { app.hub.reload(); app.syncLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: Platform.didBecomeActive)) { _ in
            if app.hub.session == nil { app.hub.reload() }
            app.syncLibrary()
        }
    }
}

/// How the shelf is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently Opened", title = "Title", author = "Author", progress = "Progress"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false
    @State private var removing: LibraryItem?
    @State private var query = ""
    @AppStorage("librarySort") private var sort = LibrarySort.recent

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 32, alignment: .top)]

    /// The shelf as shown: filtered by the search field, in the chosen order.
    private var shelf: [LibraryItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let found = needle.isEmpty ? app.library : app.library.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.author.localizedCaseInsensitiveContains(needle)
        }
        switch sort {
        case .recent: return found.sorted { $0.lastOpened > $1.lastOpened }
        case .title: return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return found.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .progress: return found.sorted { $0.progress > $1.progress }
        }
    }

    /// The unfinished item opened last, offered on its own once there is more than one thing to pick from.
    private var current: LibraryItem? {
        guard app.library.count > 1, query.isEmpty else { return nil }
        return app.library.filter { $0.progress < 0.995 }.max { $0.lastOpened < $1.lastOpened }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library")
                            .font(.scaled(size: 34, weight: .semibold, design: .serif))
                        // Videos and articles sit on the shelf too, so they aren't all "books".
                        Text(app.library.isEmpty ? "Your books will appear here." :
                             "\(app.library.count) item\(app.library.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.library.count > 1 {
                        searchField
                        Picker("Sort", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.large)
                        .help("Sort the library")
                    }
                    Button { app.showAddLink = true } label: {
                        Label("Add Link…", systemImage: "link").padding(.horizontal, 4)
                    }
                    .controlSize(.large)
                    Button { app.presentOpenPanel() } label: {
                        Label("Open Book…", systemImage: "plus")
                            .padding(.horizontal, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o")
                }

                if app.library.isEmpty {
                    emptyState
                } else {
                    if let current { ContinueCard(item: current) { app.open(current.url) } }
                    let shelf = shelf
                    if shelf.isEmpty {
                        Text("Nothing in your library matches “\(query)”.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                        ForEach(shelf) { item in
                            Button { app.open(item.url) } label: { BookCard(item: item) }
                                .buttonStyle(PressableCardStyle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.author.isEmpty ? item.title : "\(item.title), \(item.author)")
                                .accessibilityValue(item.progress >= 0.995 ? "Finished" : "\(Int(item.progress * 100)) percent read")
                                .accessibilityAddTraits(.isButton)
                                .contextMenu { actions(for: item) }
                                #if os(iOS)
                                // A long press isn't discoverable, so the same actions sit on the cover.
                                .overlay(alignment: .topTrailing) {
                                    Menu { actions(for: item) } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.scaled(size: 13, weight: .semibold))
                                            .frame(width: 30, height: 30)
                                            .background(.regularMaterial, in: Circle())
                                            .padding(6)
                                    }
                                    .foregroundStyle(.primary)
                                    .accessibilityLabel("Actions for \(item.title)")
                                }
                                #endif
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color(platform: .windowBackgroundColor), Color(platform: .underPageBackgroundColor).opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.folioAccent, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.folioAccent.opacity(0.06)))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            app.handleDrop(providers)
        }
        .confirmationDialog("Remove “\(removing?.title ?? "")” from your library?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from All Devices", role: .destructive) {
                if let item = removing { app.remove(item) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The book's file is deleted from iCloud on all your devices. Your highlights, notes and study data are kept.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    @ViewBuilder private func actions(for item: LibraryItem) -> some View {
        Button("Open") { app.open(item.url) }
        #if os(macOS)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        #endif
        Divider()
        Button("Remove from Library", role: .destructive) {
            // A managed book is deleted on every device, so that one asks first. Otherwise the file
            // stays where it is and the removal can simply be undone.
            if CloudStore.filesDir != nil {
                removing = item
            } else {
                let index = app.library.firstIndex { $0.id == item.id } ?? 0
                app.remove(item)
                app.offerUndo("Removed “\(item.title)”") { app.restore(item, at: index) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.scaled(size: 54, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop an EPUB or PDF here")
                .font(.scaled(size: 20, weight: .medium, design: .serif))
            Text("Add books or YouTube videos. Claude maps the ideas, quizzes you, and brings back what you're about to forget.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Choose a File…") { app.presentOpenPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}

/// Gives a card the pressed look a plain tap gesture never shows.
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The book being read, one click from where it was left.
private struct ContinueCard: View {
    let item: LibraryItem
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                Color.clear
                    .frame(width: 46, height: 69)
                    .overlay { BookCover(item: item) }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONTINUE READING")
                        .font(.scaled(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(item.title).font(.scaled(size: 17, weight: .semibold, design: .serif)).lineLimit(1)
                    HStack(spacing: 8) {
                        if !item.author.isEmpty { Text(item.author).lineLimit(1) }
                        Text("\(Int(item.progress * 100))% read").monospacedDigit()
                    }
                    .font(.scaled(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Label("Resume", systemImage: "play.fill")
                    .font(.scaled(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.folioAccent, in: Capsule())
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continue reading \(item.title), \(Int(item.progress * 100)) percent read")
        .accessibilityAddTraits(.isButton)
    }
}

private struct BookCard: View {
    let item: LibraryItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The cover fills a fixed 2:3 slot as an overlay so wide art (video thumbnails) can't widen the card.
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { BookCover(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 16 : 8, y: hovering ? 10 : 5)
                .scaleEffect(hovering ? 1.025 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.scaled(size: 13, weight: .semibold, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !item.author.isEmpty {
                    Text(item.author).font(.scaled(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Color.folioAccent.opacity(0.8)).frame(width: max(2, g.size.width * item.progress))
                        }
                    }
                    .frame(height: 3)
                    Text(item.progress >= 0.995 ? "Done" : "\(Int(item.progress * 100))%")
                        .font(.scaled(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct BookCover: View {
    let item: LibraryItem

    var body: some View {
        if let image = PlatformImage.load(AppPaths.cover(for: item.id)) {
            Image(platform: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        let hue = Double(item.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.55), Color(hue: hue, saturation: 0.45, brightness: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Text(item.title)
                    .font(.scaled(size: 15, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                Rectangle().fill(.white.opacity(0.5)).frame(width: 24, height: 1)
                Text(item.author)
                    .font(.scaled(size: 10, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(1)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }
}
