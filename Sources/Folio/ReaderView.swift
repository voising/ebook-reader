import SwiftUI

struct ReaderView: View {
    @Bindable var reader: ReaderModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var settings = ReaderSettings.shared
    @State private var showAppearance = false
    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    private var theme: ThemeSnapshot { settings.snapshot(scheme) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(reader: reader)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
        } detail: {
            VStack(spacing: 0) {
                if let videoID = reader.videoID, reader.showVideo {
                    VideoPlayerView(videoID: videoID, seek: reader.videoSeek)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxHeight: 340)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                }
                ZStack {
                    content
                    if reader.study.tab != nil {
                        StudyPanel(reader: reader, study: reader.study)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: reader.study.tab != nil)
                footer
            }
            .background(Color(nsColor: theme.theme.background))
            .inspector(isPresented: $reader.showChat) {
                ChatView(chat: reader.chat, chrome: .reader(reader))
                    .inspectorColumnWidth(min: 300, ideal: 370, max: 560)
            }
        }
        .navigationTitle(reader.title)
        .navigationSubtitle(reader.currentChapterTitle)
        .toolbar { toolbar }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reader.reloadFromCloud()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            reader.flush()
        }
        .onDisappear { reader.flush() }
        .onChange(of: reader.search.focusToken) { if columns == .detailOnly { withAnimation { columns = .all } } }
    }

    @ViewBuilder private var content: some View {
        if reader.epub != nil {
            EPUBReaderView(reader: reader, chapterIndex: reader.chapterIndex, anchorToken: reader.anchorToken, theme: theme)
        } else if let pdf = reader.pdf {
            PDFReaderView(reader: reader, document: pdf, theme: theme)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(reader.positionLabel)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: theme.theme.foreground).opacity(0.1))
                    Capsule().fill(Color(nsColor: theme.theme.link).opacity(0.7))
                        .frame(width: max(3, geo.size.width * reader.progress))
                }
            }
            .frame(height: 3)
            Text("\(Int((reader.progress * 100).rounded()))%").monospacedDigit()
            if reader.saveBlocked || reader.study.saveBlocked {
                Label("Synced \(reader.saveBlocked ? "highlights" : "study data") couldn't be read — changes aren't being saved", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .help("Folio found saved data for this book but couldn't read it, so it is leaving that file untouched. It retries when you switch back to the app.")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Color(nsColor: theme.theme.foreground).opacity(0.45))
        .padding(.horizontal, 18)
        .frame(height: 28)
        .animation(.easeOut(duration: 0.3), value: reader.progress)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.closeBook() } label: { Label("Library", systemImage: "books.vertical") }
                .help("Back to Library")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { reader.previous() } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(!reader.canGoPrevious)
                    .help(reader.kind == .epub ? "Previous chapter" : "Previous page")
                Button { reader.next() } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(!reader.canGoNext)
                    .help(reader.kind == .epub ? "Next chapter" : "Next page")
            }
            Menu {
                ForEach(HighlightColor.allCases) { c in
                    Button { reader.highlightSelection(c) } label: {
                        Label(c.label, systemImage: "circle.fill")
                    }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            } primaryAction: {
                reader.highlightSelection(.yellow)
            }
            .help("Highlight selection (⇧⌘H)")
            Menu {
                ForEach(StudyTab.allCases) { tab in
                    Button { reader.study.tab = tab } label: { Label(tab.rawValue, systemImage: tab.icon) }
                }
                if reader.study.tab != nil {
                    Divider()
                    Button("Back to Text") { reader.study.tab = nil }
                }
            } label: {
                Label("Study", systemImage: reader.study.tab == nil ? "graduationcap" : "graduationcap.fill")
            } primaryAction: {
                reader.study.tab = reader.study.tab == nil ? .map : nil
            }
            .help("Study this section: primer, concept map, explain-back, flashcards")
            if reader.videoID != nil {
                Button { withAnimation { reader.toggleVideo() } } label: {
                    Label("Video", systemImage: reader.showVideo ? "play.rectangle.fill" : "play.rectangle")
                }
                .help("Show or hide the video")
            }
            Button { showAppearance.toggle() } label: { Label("Appearance", systemImage: "textformat.size") }
                .help("Appearance")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    AppearancePopover(settings: settings, isPDF: reader.kind == .pdf)
                }
            Button { withAnimation { reader.showChat.toggle() } } label: {
                Label("Ask Claude", systemImage: reader.showChat ? "bubble.right.fill" : "bubble.right")
            }
            .help("Toggle Claude chat (⌥⌘C)")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var reader: ReaderModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $reader.sidebarTab) {
                ForEach(ReaderModel.SidebarTab.allCases, id: \.self) { tab in
                    Group {
                        if tab == .search { Image(systemName: "magnifyingglass") }
                        else { Text(tab == .highlights ? "Highlights (\(reader.highlights.count))" : tab.rawValue) }
                    }
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            switch reader.sidebarTab {
            case .contents: contents
            case .highlights: highlights
            case .notes: NoteEditor(reader: reader)
            case .search: SearchPanel(reader: reader, search: reader.search)
            }
        }
    }

    private var contents: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(reader.toc) { entry in
                    let current = reader.isCurrent(entry)
                    Button { reader.go(to: entry) } label: {
                        Text(entry.title)
                            .font(.system(size: entry.level == 0 ? 12.5 : 12, weight: current ? .semibold : .regular))
                            .foregroundStyle(entry.target == nil ? .tertiary : (current ? .primary : .secondary))
                            .lineLimit(2)
                            .padding(.leading, CGFloat(entry.level) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(current ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)).padding(.horizontal, 6) : nil)
                    .id(entry.id)
                }
                if reader.toc.isEmpty {
                    Text("This document has no table of contents.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                if let cur = reader.toc.first(where: reader.isCurrent) { proxy.scrollTo(cur.id, anchor: .center) }
            }
        }
    }

    private var highlights: some View {
        VStack(spacing: 0) {
            if reader.highlights.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No highlights yet").font(.headline)
                    Text("Select text while reading and pick a color.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(reader.sortedHighlights) { h in
                        HighlightRow(highlight: h)
                            .contentShape(Rectangle())
                            .onTapGesture { reader.reveal(h) }
                            .contextMenu {
                                Button("Go to Highlight") { reader.reveal(h) }
                                Button("Ask Claude About This") { reader.ask(about: h.text) }
                                Button("Add to Note") { reader.appendToNote(h) }
                                Button("Make Flashcard") { reader.makeCard(from: h) }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(h.text, forType: .string)
                                }
                                Menu("Color") {
                                    ForEach(HighlightColor.allCases) { c in
                                        Button(c.label) { reader.recolor(h.id, to: c) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { reader.removeHighlight(h.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Label(CloudStore.isUsingICloud ? "Synced with iCloud" : "Saved locally",
                          systemImage: CloudStore.isUsingICloud ? "icloud" : "internaldrive")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reader.markdownExport(), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.small)
                }
                .padding(10)
            }
        }
    }
}

private struct NoteEditor: View {
    @Bindable var reader: ReaderModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if reader.note.isEmpty {
                    Text("Write your thoughts on this book…\n\nRight-click a highlight and choose Add to Note to quote it here.")
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reader.note)
                    .font(.system(size: 13.5, design: .serif))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Label(CloudStore.isUsingICloud ? "Synced with iCloud" : "Saved locally",
                      systemImage: CloudStore.isUsingICloud ? "icloud" : "internaldrive")
                Spacer()
                if let date = reader.noteUpdatedAt {
                    Text("Edited \(date.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .onAppear { focused = reader.note.isEmpty }
    }
}

private struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(highlight.color.color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.text)
                    .font(.system(size: 12.5, design: .serif))
                    .lineLimit(5)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let t = highlight.chapterTitle { Text(t).lineLimit(1) }
                    if let p = highlight.page { Text("· p. \(p + 1)") }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Appearance

struct AppearancePopover: View {
    @Bindable var settings: ReaderSettings
    let isPDF: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(ReaderTheme.allCases) { t in
                    Button { settings.theme = t } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                if t == .auto {
                                    Circle().fill(LinearGradient(colors: [Color(nsColor: ReaderTheme.paper.background), Color(nsColor: ReaderTheme.night.background)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                } else {
                                    Circle().fill(Color(nsColor: t.background))
                                }
                                Text("Aa").font(.system(size: 13, weight: .medium, design: .serif))
                                    .foregroundStyle(Color(nsColor: t == .auto ? ReaderTheme.sepia.foreground : t.foreground))
                            }
                            .frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(settings.theme == t ? Color.accentColor : Color.primary.opacity(0.15),
                                                           lineWidth: settings.theme == t ? 2.5 : 1))
                            Text(t.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if !isPDF {
                Picker("Font", selection: $settings.font) {
                    ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $settings.fontSize, in: 14...30, step: 1)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(.secondary)
                    Slider(value: $settings.lineHeight, in: 1.3...2.1)
                    Image(systemName: "text.line.last.and.arrowtriangle.forward").foregroundStyle(.secondary)
                }
                Picker("Width", selection: $settings.width) {
                    ForEach(ReaderWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(18)
        .frame(width: 270)
    }
}
