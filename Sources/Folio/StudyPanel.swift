import SwiftUI

/// Covers the text while studying: primer, concept map, explain-back and flashcards for the open section.
struct StudyPanel: View {
    let reader: ReaderModel
    @Bindable var study: StudyModel

    private var key: String { reader.sectionKey }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                switch study.tab ?? .map {
                case .primer: PrimerTab(reader: reader, study: study, sectionKey: key)
                case .map: MapTab(reader: reader, study: study, sectionKey: key)
                case .explain: ExplainTab(reader: reader, study: study, sectionKey: key)
                case .cards: CardsTab(reader: reader, study: study, sectionKey: key)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { study.tab ?? .map }, set: { study.tab = $0 })) {
                ForEach(StudyTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(reader.currentChapterTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { study.tab = nil } label: {
                Label("Back to Text", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the text (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

// MARK: - Shared pieces

/// Empty state with one action that asks Claude to build something.
private struct GeneratePrompt: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let busyLabel: String
    let isBusy: Bool
    let error: String?
    let run: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 20, weight: .semibold, design: .serif))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busyLabel).font(.callout).foregroundStyle(.secondary)
                    Button("Cancel", action: cancel).controlSize(.small)
                }
                .padding(.top, 4)
            } else {
                Button(action: run) { Text(action).padding(.horizontal, 6) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            if let error { ErrorLine(text: error) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: 460)
    }
}

private struct SectionHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Primer

private struct PrimerTab: View {
    let reader: ReaderModel
    let study: StudyModel
    let sectionKey: String

    var body: some View {
        if let primer = study.primer(for: sectionKey) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let overview = primer.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 16, design: .serif))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    if let questions = primer.questions, !questions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeading(text: "Read to answer")
                            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 14)
                                    Text(q).font(.system(size: 14)).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button("Discuss") {
                                        reader.showChat = true
                                        reader.chat.send("Help me think through this question about the section, without just giving me the answer: \(q)")
                                    }
                                    .controlSize(.small)
                                    .disabled(reader.chat.isRunning)
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                            }
                        }
                    }
                    if let pre = primer.prerequisites, !pre.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeading(text: "Assumes you know")
                            ForEach(pre, id: \.self) { p in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(p).font(.system(size: 13)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let terms = primer.terms, !terms.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeading(text: "Key terms")
                            ForEach(terms, id: \.self) { t in
                                (Text(t.term).fontWeight(.semibold) + Text(t.meaning.map { " — \($0)" } ?? ""))
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    HStack {
                        Button("Start Reading") { study.tab = nil }.buttonStyle(.borderedProminent)
                        Button(study.isBusy(.primer) ? "Rewriting…" : "Rewrite") { study.generatePrimer() }
                            .disabled(study.isBusy(.primer))
                    }
                    if let error = study.errors[.primer] { ErrorLine(text: error) }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            GeneratePrompt(icon: "signpost.right", title: "Read with a purpose",
                           detail: "Before you start, Claude sets up what this section is about, the questions to read for, and what it assumes you already know.",
                           action: "Prepare Me for This Section", busyLabel: "Reading ahead…",
                           isBusy: study.isBusy(.primer), error: study.errors[.primer],
                           run: { study.generatePrimer() }, cancel: { study.cancel(.primer) })
        }
    }
}

// MARK: - Concept map

private struct MapTab: View {
    let reader: ReaderModel
    @Bindable var study: StudyModel
    let sectionKey: String

    private static let kinds = ["concept", "claim", "example", "person", "term", "method"]

    var body: some View {
        if let map = study.map(for: sectionKey) {
            let present = Set(map.nodes.map { ($0.kind ?? "concept").lowercased() })
            VStack(spacing: 0) {
                GraphView(nodes: map.nodes.map { GraphNode(id: $0.id, label: $0.label, color: .conceptKind($0.kind)) },
                          edges: (map.edges ?? []).map { GraphEdge(from: $0.from, to: $0.to, label: $0.label) },
                          selection: $study.selectedNode)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 12) {
                            ForEach(Self.kinds.filter(present.contains), id: \.self) { kind in
                                HStack(spacing: 5) {
                                    Circle().fill(Color.conceptKind(kind)).frame(width: 7, height: 7)
                                    Text(kind.capitalized).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button(study.isBusy(.map) ? "Redrawing…" : "Redraw") { study.generateMap() }
                            .controlSize(.small)
                            .disabled(study.isBusy(.map))
                            .padding(10)
                    }
                Divider().opacity(0.5)
                detail(map)
            }
        } else {
            GeneratePrompt(icon: "point.3.connected.trianglepath.dotted", title: "See how the ideas connect",
                           detail: "Claude reads this section and draws its concepts and the relationships between them. Click a concept to see what the text says about it and jump to where it appears.",
                           action: "Map This Section", busyLabel: "Mapping the ideas…",
                           isBusy: study.isBusy(.map), error: study.errors[.map],
                           run: { study.generateMap() }, cancel: { study.cancel(.map) })
        }
    }

    @ViewBuilder private func detail(_ map: ConceptMap) -> some View {
        if let node = map.nodes.first(where: { $0.id == study.selectedNode }) {
            let labels = Dictionary(map.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
            let relations = (map.edges ?? []).compactMap { e -> String? in
                if e.from == node.id, let other = labels[e.to] { return "\(e.label ?? "→") **\(other)**" }
                if e.to == node.id, let other = labels[e.from] { return "**\(other)** \(e.label ?? "→") this" }
                return nil
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Color.conceptKind(node.kind)).frame(width: 9, height: 9)
                    Text(node.label).font(.system(size: 15, weight: .semibold, design: .serif))
                    Text((node.kind ?? "concept").capitalized).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    if let quote = node.quote, !quote.isEmpty {
                        Button("Show in Text") { reader.showPassage(quote) }.controlSize(.small)
                    }
                    Button("Ask Claude") {
                        reader.showChat = true
                        reader.chat.send("Explain \"\(node.label)\" as this section uses it, and how it relates to the ideas around it.")
                    }
                    .controlSize(.small)
                    .disabled(reader.chat.isRunning)
                }
                if let summary = node.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !relations.isEmpty {
                    Text(.init(relations.joined(separator: "  ·  ")))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text("\(map.nodes.count) concepts · click one for details · drag to rearrange · pinch to zoom")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error = study.errors[.map] { ErrorLine(text: error) }
            }
            .padding(12)
        }
    }
}

// MARK: - Explain back

private struct ExplainTab: View {
    let reader: ReaderModel
    @Bindable var study: StudyModel
    let sectionKey: String
    @State private var showEditor = false

    var body: some View {
        let attempts = study.attempts(for: sectionKey)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let latest = attempts.last, !showEditor {
                    result(latest, previous: attempts.dropLast().last)
                    HStack {
                        Button("Try Again") { showEditor = true }.buttonStyle(.borderedProminent)
                        if !study.cards(for: sectionKey).isEmpty {
                            Button("Drill the Gaps") { study.tab = .cards }
                        }
                    }
                    if attempts.count > 1 { history(attempts) }
                } else {
                    editor(hasAttempts: !attempts.isEmpty)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: attempts.count) { _, _ in showEditor = false }
    }

    private func editor(hasAttempts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explain it back").font(.system(size: 22, weight: .semibold, design: .serif))
            Text("Without looking at the text, write what this section said, as if teaching someone else. Claude checks it against the text and shows you what you got, what you missed and what you got wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $study.explainDraft)
                .font(.system(size: 14, design: .serif))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                .disabled(study.isBusy(.explain))
            HStack(spacing: 10) {
                if study.isBusy(.explain) {
                    ProgressView().controlSize(.small)
                    Text("Checking against the text…").font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") { study.cancel(.explain) }.controlSize(.small)
                } else {
                    Button("Check My Understanding") { study.gradeExplanation() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    if hasAttempts { Button("Cancel") { showEditor = false } }
                }
            }
            if let error = study.errors[.explain] { ErrorLine(text: error) }
        }
    }

    private func result(_ a: ExplainAttempt, previous: ExplainAttempt?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ScoreRing(score: a.score)
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.score >= 85 ? "You've got this section." : a.score >= 60 ? "Solid, with gaps." : "Worth another pass.")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                    HStack(spacing: 6) {
                        Text(a.date.formatted(.relative(presentation: .named)))
                        if let previous {
                            let delta = a.score - previous.score
                            Text("·")
                            Text(delta == 0 ? "same as last time" : "\(delta > 0 ? "+" : "")\(delta) since last time")
                                .foregroundStyle(delta > 0 ? .green : (delta < 0 ? .orange : .secondary))
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            if let feedback = a.feedback, !feedback.isEmpty {
                Text(feedback).font(.system(size: 14, design: .serif)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            points("Missed", a.missed, icon: "circle.dashed", color: .orange)
            points("Got wrong", a.misconceptions, icon: "xmark.circle.fill", color: .red)
            points("Got right", a.got, icon: "checkmark.circle.fill", color: .green)
        }
    }

    @ViewBuilder private func points(_ title: String, _ items: [String]?, icon: String, color: Color) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(text: title)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
                        Text(item).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func history(_ attempts: [ExplainAttempt]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(text: "Attempts")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(attempts) { a in
                    VStack(spacing: 3) {
                        Text("\(a.score)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(a.id == attempts.last?.id ? 0.9 : 0.4))
                            .frame(width: 22, height: max(4, CGFloat(a.score) * 0.5))
                    }
                    .help(a.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 64

    private var color: Color { score >= 85 ? .green : (score >= 60 ? .orange : .red) }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.1)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: size * 0.33, weight: .semibold)).monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Cards

private struct CardsTab: View {
    let reader: ReaderModel
    @Bindable var study: StudyModel
    let sectionKey: String

    var body: some View {
        let cards = study.cards(for: sectionKey)
        if let quiz = study.quiz {
            ReviewSessionView(items: quiz, title: "Quiz · \(reader.currentChapterTitle)",
                              onGrade: { item, grade in study.grade(item.card.id, grade) },
                              onDone: { study.quiz = nil })
        } else if cards.isEmpty {
            GeneratePrompt(icon: "rectangle.on.rectangle.angled", title: "Turn this section into questions",
                           detail: "Claude writes flashcards from the text, starting with what you highlighted. Cards come back for review on a spaced schedule so they stick.",
                           action: "Make Flashcards", busyLabel: "Writing cards…",
                           isBusy: study.isBusy(.cards), error: study.errors[.cards],
                           run: { study.generateCards() }, cancel: { study.cancel(.cards) })
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    let due = cards.filter { $0.isDue() }.count
                    Text("\(cards.count) card\(cards.count == 1 ? "" : "s") · \(due) due")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if study.isBusy(.cards) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { study.cancel(.cards) }.controlSize(.small)
                    } else {
                        Button("Add More") { study.generateCards(count: 5) }
                    }
                    Button("Quiz Me") { study.startQuiz(cards) }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if let error = study.errors[.cards] { ErrorLine(text: error).padding(.bottom, 8) }
                Divider().opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(cards) { card in
                            CardRow(card: card)
                                .contextMenu {
                                    if let quote = card.quote, !quote.isEmpty {
                                        Button("Show in Text") { reader.showPassage(quote) }
                                    }
                                    Button("Delete Card", role: .destructive) { study.deleteCard(card.id) }
                                }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct CardRow: View {
    let card: Flashcard
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.front).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(status).font(.system(size: 10.5)).foregroundStyle(card.isDue() ? Color.accentColor : .secondary)
            }
            if revealed {
                Text(card.back).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { revealed.toggle() } }
    }

    private var status: String {
        if card.isNew { return "New" }
        if card.isDue() { return "Due" }
        return "In " + Flashcard.intervalLabel(card.due.timeIntervalSinceNow / 86_400)
    }
}

// MARK: - Review session (used for chapter quizzes and the library-wide queue)

struct ReviewSessionView: View {
    let title: String
    let onGrade: (ReviewItem, ReviewGrade) -> Void
    let onDone: () -> Void

    @State private var queue: [ReviewItem]
    @State private var revealed = false
    @State private var done = 0
    @State private var again = 0
    private let total: Int

    init(items: [ReviewItem], title: String, onGrade: @escaping (ReviewItem, ReviewGrade) -> Void, onDone: @escaping () -> Void) {
        self.title = title
        self.onGrade = onGrade
        self.onDone = onDone
        _queue = State(initialValue: items)
        total = items.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 220)
                Text("\(done)/\(total)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("End") { onDone() }.controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider().opacity(0.5)
            if let item = queue.first {
                card(item)
            } else {
                finished
            }
        }
    }

    private func card(_ item: ReviewItem) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 18) {
                if !item.source.isEmpty {
                    Text(item.source).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(item.card.front)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if revealed {
                    Divider()
                    Text(item.card.back)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let quote = item.card.quote, !quote.isEmpty {
                        Text("“\(quote)”").font(.system(size: 12, design: .serif)).italic().foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)

            if revealed {
                HStack(spacing: 10) {
                    ForEach(ReviewGrade.allCases) { grade in
                        Button { answer(item, grade) } label: {
                            VStack(spacing: 2) {
                                Text(grade.label).font(.system(size: 13, weight: .medium))
                                Text(Flashcard.intervalLabel(item.card.nextInterval(grade)))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            .frame(width: 86)
                            .padding(.vertical, 4)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(grade.rawValue)")), modifiers: [])
                    }
                }
                .controlSize(.large)
                Text("Press 1–4").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { revealed = true } } label: {
                    Text("Show Answer").padding(.horizontal, 18)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                Text("Answer in your head first, then press Space").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finished: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.green)
            Text("Session complete").font(.system(size: 22, weight: .semibold, design: .serif))
            Text(again == 0 ? "\(total) card\(total == 1 ? "" : "s"), all recalled."
                 : "\(total) card\(total == 1 ? "" : "s") · \(again) needed another look and will come back soon.")
                .foregroundStyle(.secondary)
            Button("Done") { onDone() }.controlSize(.large).buttonStyle(.borderedProminent).padding(.top, 6)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func answer(_ item: ReviewItem, _ grade: ReviewGrade) {
        onGrade(item, grade)
        revealed = false
        queue.removeFirst()
        if grade == .again {
            // Missed cards come round again before the session ends.
            var retry = item
            retry.card.apply(.again)
            queue.append(retry)
            again += 1
        } else {
            done += 1
        }
    }
}
