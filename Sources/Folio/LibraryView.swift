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
                    ForEach(HubTab.allCases) { tab in
                        Text(tab == .review && !app.hub.due.isEmpty ? "Review (\(app.hub.due.count))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .sheet(isPresented: $app.showAddVideo) { AddVideoSheet().environment(app) }
        .onAppear { app.hub.reload(); app.syncLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: Platform.didBecomeActive)) { _ in
            if app.hub.session == nil { app.hub.reload() }
            app.syncLibrary()
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 32, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library")
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                        Text(app.library.isEmpty ? "Your books will appear here." :
                             "\(app.library.count) book\(app.library.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { app.showAddVideo = true } label: {
                        Label("Add Video…", systemImage: "play.rectangle").padding(.horizontal, 4)
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                        ForEach(app.library) { item in
                            BookCard(item: item)
                                .onTapGesture { app.open(item.url) }
                                .contextMenu {
                                    Button("Open") { app.open(item.url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    Divider()
                                    Button("Remove from Library", role: .destructive) { app.remove(item) }
                                }
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
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.06)))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            app.handleDrop(providers)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop an EPUB or PDF here")
                .font(.system(size: 20, weight: .medium, design: .serif))
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
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .lineLimit(2)
                if !item.author.isEmpty {
                    Text(item.author).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: max(2, g.size.width * item.progress))
                        }
                    }
                    .frame(height: 3)
                    Text(item.progress >= 0.995 ? "Done" : "\(Int(item.progress * 100))%")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.tertiary)
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
        if let image = NSImage(contentsOf: AppPaths.cover(for: item.id)) {
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
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                Rectangle().fill(.white.opacity(0.5)).frame(width: 24, height: 1)
                Text(item.author)
                    .font(.system(size: 10, weight: .medium))
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
