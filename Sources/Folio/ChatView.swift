import SwiftUI

/// The words around a chat: what it's about and what to suggest.
struct ChatChrome {
    var title = "Ask Claude"
    var subtitle: String
    var emptyTitle: String
    var emptyDetail: String
    var placeholder: String
    var suggestions: [String]
    var maxWidth: CGFloat? = nil

    @MainActor static func reader(_ reader: ReaderModel) -> ChatChrome {
        let unit = reader.kind == .pdf ? "section" : (reader.videoID != nil ? "part" : "chapter")
        return ChatChrome(
            subtitle: reader.currentChapterTitle,
            emptyTitle: "Ask anything about what you're \(reader.videoID != nil ? "watching" : "reading").",
            emptyDetail: "Claude reads the current \(unit) along with your question. Select a passage and choose **Ask Claude** to ask about it specifically.",
            placeholder: "Ask about this \(unit)…",
            suggestions: ["Summarize this \(unit)", "Explain anything tricky in this part", "Who are the important people or concepts?"])
    }
}

struct ChatView: View {
    @Bindable var chat: ChatModel
    let chrome: ChatChrome
    @FocusState private var inputFocused: Bool

    private var suggestions: [String] { [chat.mode.starter] + chrome.suggestions }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { m in
                            MessageRow(message: m).id(m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                    .frame(maxWidth: chrome.maxWidth)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
                .frame(maxWidth: chrome.maxWidth)
                .frame(maxWidth: .infinity)
        }
        .background(.background)
        .onChange(of: chat.focusToken) { _, _ in inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.mode.icon)
                .font(.scaled(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(LinearGradient(colors: [Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.75, green: 0.36, blue: 0.27)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 1) {
                Text(chrome.title).font(.scaled(size: 13, weight: .semibold))
                Text(chrome.subtitle)
                    .font(.scaled(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Mode", selection: $chat.mode) {
                    ForEach(TutorMode.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(chat.mode.label).font(.scaled(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(chat.mode.blurb)
            if !chat.messages.isEmpty {
                Button { chat.reset() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New conversation")
                    .accessibilityLabel("New conversation")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chrome.emptyTitle)
                .font(.scaled(size: 20, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text(.init(chrome.emptyDetail))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("**\(chat.mode.label):** \(chat.mode.blurb)")
                .font(.scaled(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { chat.send(s) } label: {
                        HStack {
                            Text(s).font(.scaled(size: 12.5)).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.scaled(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 18)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = chat.quote {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.folioAccent).frame(width: 3)
                    Text(quote)
                        .font(.scaled(size: 12, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button { chat.quote = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove quoted passage")
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.quote == nil ? chrome.placeholder : "Ask about this passage…",
                          text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.scaled(size: 13))
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit { chat.send() }
                    .padding(.vertical, 4)
                if chat.isRunning {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.scaled(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    Button { chat.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.scaled(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.folioAccent))
                    .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(inputFocused ? Color.folioAccent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .padding(12)
        .animation(.easeOut(duration: 0.18), value: chat.quote)
    }
}

private struct MessageRow: View {
    let message: ChatModel.Message

    var body: some View {
        switch message.role {
        case .note:
            HStack(spacing: 8) {
                line
                Label(message.text, systemImage: "book.pages")
                    .font(.scaled(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                line
            }
            .padding(.vertical, 2)
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let q = message.quote {
                        Text("“\(q)”")
                            .font(.scaled(size: 11.5, design: .serif))
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(message.text)
                        .font(.scaled(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.folioAccent.opacity(0.14)))
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && message.isStreaming {
                    TypingIndicator().padding(.vertical, 6)
                } else if message.isError {
                    Label(message.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.scaled(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    MarkdownText(text: message.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var line: some View {
        Rectangle().fill(.quaternary).frame(height: 1)
    }
}

private struct TypingIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(.secondary).frame(width: 6, height: 6)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: phase)
            }
            Text("Reading…").font(.scaled(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4)
        }
        .onAppear { phase = true }
    }
}

/// Lightweight block-level Markdown: headings, bullets, numbered lists, code fences, quotes.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(String, Int)
        case bullet(String, String)
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para.removeAll() }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let m = line.firstMatch(of: #/^(#{1,4})\s+(.*)$/#) {
                flush(); out.append(.heading(String(m.2), m.1.count))
            } else if let m = line.firstMatch(of: #/^[-*•]\s+(.*)$/#) {
                flush(); out.append(.bullet("•", String(m.1)))
            } else if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush(); out.append(.bullet("\(m.1).", String(m.2)))
            } else if let m = line.firstMatch(of: #/^>\s?(.*)$/#) {
                flush(); out.append(.quote(String(m.1)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s, let level):
                    Text(inline(s)).font(.scaled(size: level <= 2 ? 15 : 13.5, weight: .semibold)).padding(.top, 4)
                case .bullet(let marker, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 10, alignment: .trailing)
                        Text(inline(s))
                    }
                case .quote(let s):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                        Text(inline(s)).italic().foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    Text(s).font(.scaled(size: 11.5, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                case .paragraph(let s):
                    Text(inline(s))
                }
            }
        }
        .font(.scaled(size: 13))
        .lineSpacing(2.5)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
