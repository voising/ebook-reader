import SwiftUI

struct GraphNode: Identifiable, Hashable {
    let id: String
    var label: String
    var color: Color
}

struct GraphEdge: Hashable {
    let from: String
    let to: String
    var label: String?
    var dashed = false
}

/// Force-directed layout (Fruchterman–Reingold). Deterministic: the same graph always lays out the same way.
enum GraphLayout {
    static func compute(ids: [String], edges: [(String, String)], aspect: Double) -> [String: CGPoint] {
        let n = ids.count
        guard n > 0 else { return [:] }
        if n == 1 { return [ids[0]: CGPoint(x: 0.5, y: 0.5)] }
        let w = max(0.6, aspect), h = 1.0
        let k = (w * h / Double(n)).squareRoot()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }

        // Start on a circle, most-connected nodes spread evenly.
        var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let angle = 2 * Double.pi * Double(i) / Double(n)
            x[i] = w / 2 + cos(angle) * w * 0.3
            y[i] = h / 2 + sin(angle) * h * 0.3
        }

        var temperature = w / 6
        for _ in 0..<320 {
            var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) {
                    var vx = x[i] - x[j], vy = y[i] - y[j]
                    // Labels are wider than tall: push apart harder horizontally.
                    vx *= 0.75
                    var dist = (vx * vx + vy * vy).squareRoot()
                    if dist < 0.0001 { vx = 0.01 * Double(i - j); vy = 0.01; dist = 0.015 }
                    let force = k * k / dist
                    dx[i] += vx / dist * force; dy[i] += vy / dist * force
                    dx[j] -= vx / dist * force; dy[j] -= vy / dist * force
                }
            }
            for (a, b) in links {
                let vx = x[a] - x[b], vy = y[a] - y[b]
                let dist = max(0.0001, (vx * vx + vy * vy).squareRoot())
                let force = dist * dist / k
                dx[a] -= vx / dist * force; dy[a] -= vy / dist * force
                dx[b] += vx / dist * force; dy[b] += vy / dist * force
            }
            for i in 0..<n {
                // Gentle pull to the centre keeps unconnected groups from drifting away.
                dx[i] += (w / 2 - x[i]) * 0.35
                dy[i] += (h / 2 - y[i]) * 0.35
                let len = max(0.0001, (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot())
                let step = min(len, temperature)
                x[i] += dx[i] / len * step
                y[i] += dy[i] / len * step
            }
            temperature = max(0.002, temperature * 0.985)
        }

        let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
        let spanX = max(0.0001, maxX - minX), spanY = max(0.0001, maxY - minY)
        var out: [String: CGPoint] = [:]
        for i in 0..<n {
            out[ids[i]] = CGPoint(x: (x[i] - minX) / spanX, y: (y[i] - minY) / spanY)
        }
        return out
    }
}

/// Draws a node-and-edge diagram natively. Drag nodes to rearrange, drag the background to pan, pinch to zoom.
struct GraphView: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    @Binding var selection: String?

    @State private var positions: [String: CGPoint] = [:]
    @State private var layoutKey = ""
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var panDrag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var dragOrigin: CGPoint?

    private static let chipWidth: CGFloat = 128
    private static let chipFont = PlatformFont.systemFont(ofSize: 11.5, weight: .semibold)

    /// Chips are sized from the label up front, so edges can stop exactly at their borders.
    static func chipSize(_ label: String) -> CGSize {
        let bounds = (label as NSString).boundingRect(with: CGSize(width: chipWidth - 22, height: 60),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: [.font: chipFont], context: nil)
        return CGSize(width: min(chipWidth, ceil(bounds.width) + 22), height: min(60, ceil(bounds.height)) + 13)
    }

    private var graphKey: String {
        nodes.map(\.id).joined(separator: "|") + "#" + edges.map { "\($0.from)>\($0.to)" }.joined(separator: "|")
    }

    private var neighbours: Set<String> {
        guard let selection else { return [] }
        var out: Set<String> = [selection]
        for e in edges {
            if e.from == selection { out.insert(e.to) }
            if e.to == selection { out.insert(e.from) }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let near = neighbours
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil }
                    .gesture(DragGesture()
                        .updating($panDrag) { v, state, _ in state = v.translation }
                        .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })

                Canvas { ctx, _ in
                    let sizes = Dictionary(nodes.map { ($0.id, Self.chipSize($0.label)) }, uniquingKeysWith: { a, _ in a })
                    for edge in edges {
                        guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                        let p1 = point(a, size), p2 = point(b, size)
                        let lit = selection == nil || edge.from == selection || edge.to == selection
                        drawEdge(edge, from: p1, to: p2, target: sizes[edge.to] ?? CGSize(width: 100, height: 28),
                                 lit: lit, focused: selection != nil && lit, in: &ctx)
                    }
                }
                .allowsHitTesting(false)

                ForEach(nodes) { node in
                    if let p = positions[node.id] {
                        chip(node, dimmed: selection != nil && !near.contains(node.id))
                            .position(point(p, size))
                            .onTapGesture { selection = selection == node.id ? nil : node.id }
                            .gesture(DragGesture(minimumDistance: 4)
                                .onChanged { v in
                                    let origin = dragOrigin ?? p
                                    if dragOrigin == nil { dragOrigin = origin }
                                    let inner = innerSize(size)
                                    positions[node.id] = CGPoint(x: origin.x + v.translation.width / (inner.width * zoom),
                                                                 y: origin.y + v.translation.height / (inner.height * zoom))
                                }
                                .onEnded { _ in dragOrigin = nil })
                    }
                }
            }
            .clipped()
            .gesture(MagnificationGesture()
                .updating($pinch) { v, state, _ in state = v }
                .onEnded { v in zoom = min(3, max(0.5, zoom * v)) })
            .overlay(alignment: .bottomTrailing) { controls }
            .onAppear { layout(size) }
            .onChange(of: graphKey) { _, _ in layout(size) }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = max(0.5, zoom / 1.25) } } label: { Image(systemName: "minus") }
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit")
            Button { withAnimation(.easeOut(duration: 0.2)) { zoom = min(3, zoom * 1.25) } } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func layout(_ size: CGSize) {
        let key = graphKey
        guard key != layoutKey || positions.isEmpty else { return }
        layoutKey = key
        let inner = innerSize(size)
        positions = GraphLayout.compute(ids: nodes.map(\.id), edges: edges.map { ($0.from, $0.to) },
                                        aspect: Double(inner.width / max(inner.height, 1)))
        zoom = 1
        pan = .zero
    }

    private func innerSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(120, size.width - Self.chipWidth - 40), height: max(120, size.height - 90))
    }

    private func point(_ unit: CGPoint, _ size: CGSize) -> CGPoint {
        let inner = innerSize(size)
        let z = zoom * pinch
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (unit.x - 0.5) * inner.width * z + pan.width + panDrag.width,
                       y: cy + (unit.y - 0.5) * inner.height * z + pan.height + panDrag.height)
    }

    private func chip(_ node: GraphNode, dimmed: Bool) -> some View {
        let selected = selection == node.id
        let size = Self.chipSize(node.label)
        return Text(node.label)
            .font(.system(size: 11.5, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(platform: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(node.color.opacity(selected ? 0.34 : 0.18)))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(node.color.opacity(selected ? 1 : 0.65), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(selected ? 0.18 : 0.06), radius: selected ? 7 : 2, y: 1)
            .opacity(dimmed ? 0.28 : 1)
            .contentShape(Rectangle())
    }

    private func drawEdge(_ edge: GraphEdge, from p1: CGPoint, to p2: CGPoint, target: CGSize, lit: Bool, focused: Bool,
                          in ctx: inout GraphicsContext) {
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        let ux = dx / len, uy = dy / len
        // Stop the line where it meets the target chip so the arrowhead shows.
        let halfW = target.width / 2 + 3, halfH = target.height / 2 + 3
        let tx = abs(ux) > 0.0001 ? halfW / abs(ux) : .greatestFiniteMagnitude
        let ty = abs(uy) > 0.0001 ? halfH / abs(uy) : .greatestFiniteMagnitude
        let inset = min(min(tx, ty), len * 0.45)
        let tip = CGPoint(x: p2.x - ux * inset, y: p2.y - uy * inset)

        let opacity: Double = lit ? (focused ? 0.75 : 0.38) : 0.08
        let stroke = GraphicsContext.Shading.color(.primary.opacity(opacity))
        var line = Path()
        line.move(to: p1)
        line.addLine(to: tip)
        ctx.stroke(line, with: stroke, style: StrokeStyle(lineWidth: focused ? 1.6 : 1, dash: edge.dashed ? [4, 4] : []))

        var head = Path()
        let a: CGFloat = 7, spread: CGFloat = 3.5
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - ux * a - uy * spread, y: tip.y - uy * a + ux * spread))
        head.addLine(to: CGPoint(x: tip.x - ux * a + uy * spread, y: tip.y - uy * a - ux * spread))
        head.closeSubpath()
        ctx.fill(head, with: stroke)

        guard let label = edge.label, !label.isEmpty, lit, len > 90 else { return }
        let text = ctx.resolve(Text(label).font(.system(size: 9.5, weight: focused ? .semibold : .regular))
            .foregroundStyle(.primary.opacity(focused ? 0.9 : 0.6)))
        let measured = text.measure(in: CGSize(width: 150, height: 40))
        let mid = CGPoint(x: (p1.x + tip.x) / 2, y: (p1.y + tip.y) / 2)
        let box = CGRect(x: mid.x - measured.width / 2 - 4, y: mid.y - measured.height / 2 - 1.5,
                         width: measured.width + 8, height: measured.height + 3)
        ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(platform: .windowBackgroundColor).opacity(0.92)))
        ctx.draw(text, in: CGRect(x: mid.x - measured.width / 2, y: mid.y - measured.height / 2, width: measured.width, height: measured.height))
    }
}

extension Color {
    /// Colour for a concept-map node kind.
    static func conceptKind(_ kind: String?) -> Color {
        switch (kind ?? "").lowercased() {
        case "claim": Color(red: 0.86, green: 0.47, blue: 0.30)
        case "example": Color(red: 0.36, green: 0.68, blue: 0.45)
        case "person": Color(red: 0.72, green: 0.45, blue: 0.86)
        case "term": Color(red: 0.55, green: 0.57, blue: 0.62)
        case "method": Color(red: 0.86, green: 0.67, blue: 0.20)
        default: Color(red: 0.30, green: 0.56, blue: 0.92)
        }
    }

    /// Stable colour per source in the library-wide map.
    static func source(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.30, green: 0.56, blue: 0.92), Color(red: 0.86, green: 0.47, blue: 0.30),
            Color(red: 0.36, green: 0.68, blue: 0.45), Color(red: 0.72, green: 0.45, blue: 0.86),
            Color(red: 0.86, green: 0.67, blue: 0.20), Color(red: 0.88, green: 0.42, blue: 0.60),
            Color(red: 0.25, green: 0.68, blue: 0.70), Color(red: 0.55, green: 0.57, blue: 0.62),
        ]
        return palette[index % palette.count]
    }
}
