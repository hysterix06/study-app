import SwiftUI
import AppKit
import StudyCore

/// Draws a `Diagram` from the shared layout (the same one the SVG export uses), in the current theme and appearance.
struct DiagramView: View {
    let diagram: Diagram
    var width: CGFloat = 480
    @Environment(\.self) private var environment

    /// Curves take the muted course colors, so graphs match the rest of the app in light and dark themes.
    static let series = ["ocean", "clay", "sage", "plum", "rose", "moss"]
    static let areas = ["sand", "plum", "rose", "slate"]

    var body: some View {
        let height = CGFloat(DiagramLayout.height(diagram, width: Double(width)))
        Canvas { context, size in draw(in: &context, size: size) }
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel(diagram.summary)
            .contextMenu {
                Button("Copy as SVG") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagramSVG.render(diagram, width: Double(width)), forType: .string)
                }
            }
    }

    private func color(_ c: ThemeColor) -> Color { c.resolve(in: environment) }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let ink = color(Theme.textSecondary)
        let text = color(Theme.textPrimary)
        let halo = color(Theme.surface)
        func cg(_ p: DPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        for shape in DiagramLayout.shapes(diagram, width: Double(size.width), height: Double(size.height)) {
            switch shape {
            case let .line(start, points, curves, stroke):
                var path = Path()
                path.move(to: cg(start))
                if let curves {
                    for c in curves { path.addCurve(to: cg(c.end), control1: cg(c.c1), control2: cg(c.c2)) }
                } else {
                    for p in points { path.addLine(to: cg(p)) }
                }
                let shading: Color
                var style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                switch stroke {
                case .axis, .arrow, .box: shading = ink
                case .guide: shading = ink.opacity(0.7); style.lineWidth = 1; style.dash = [3, 3]
                case .curve(let i, let dashed):
                    shading = color(Theme.course(Self.series[i % Self.series.count]))
                    style.lineWidth = 2.25
                    if dashed { style.dash = [6, 4] }
                }
                context.stroke(path, with: .color(shading), style: style)
            case let .fill(points, tone):
                var path = Path()
                path.addLines(points.map(cg))
                path.closeSubpath()
                context.fill(path, with: .color(color(Theme.course(Self.areas[tone % Self.areas.count])).opacity(0.28)))
            case let .dot(p, _):
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(text))
            case let .arrowHead(tip, from):
                let (a, b) = DiagramSVG.arrowWings(tip: tip, from: from)
                var path = Path()
                path.move(to: cg(a)); path.addLine(to: cg(tip)); path.addLine(to: cg(b))
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            case let .box(o, w, h):
                let rect = CGRect(x: o.x, y: o.y, width: w, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(color(Theme.fillSubtle)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(ink.opacity(0.6)), lineWidth: 1)
            case let .text(string, at, anchor, role, _):
                let font: Font
                switch role {
                case .title: font = .system(size: 13, weight: .semibold)
                case .tick: font = .system(size: 11)
                case .label: font = .system(size: 12, weight: .semibold)
                case .axis, .step: font = .system(size: 12)
                }
                let resolved = context.resolve(Text(string).font(font).foregroundColor(role == .axis || role == .tick ? ink : text))
                // Layout points are baselines (as in SVG); the bottom of the text box sits a little below.
                let unit: UnitPoint = anchor == .start ? .bottomLeading : anchor == .middle ? .bottom : .bottomTrailing
                let point = CGPoint(x: at.x, y: at.y + 3)
                if role == .label || role == .tick {
                    // A soft backing keeps labels readable where they cross a line.
                    let m = resolved.measure(in: size)
                    let x = anchor == .start ? point.x : anchor == .middle ? point.x - m.width / 2 : point.x - m.width
                    let backing = CGRect(x: x - 2, y: point.y - m.height, width: m.width + 4, height: m.height)
                    context.fill(Path(roundedRect: backing, cornerRadius: 3), with: .color(halo.opacity(0.85)))
                }
                context.draw(resolved, at: point, anchor: unit)
            }
        }
    }
}

/// A lecture's study notes: overview, sections with their points and diagrams, takeaways and key terms.
struct StudyNotesView: View {
    let notes: StudyNotes
    var showTerms = true
    @State private var termsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !notes.overview.isEmpty {
                Text(notes.overview).font(.stBody).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title).font(.stBodyStrong)
                    ForEach(Array(section.points.enumerated()), id: \.offset) { _, p in NotePointRow(point: p) }
                    if let d = section.diagram {
                        DiagramView(diagram: d)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(Theme.canvas))
                            .padding(.top, 4)
                    }
                }
            }
            if !notes.takeaways.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Takeaways").font(.stBodyStrong)
                    ForEach(Array(notes.takeaways.enumerated()), id: \.offset) { _, t in
                        Label { Text(t).font(.stBody).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.success)
                        }
                    }
                }
            }
            if showTerms && !notes.terms.isEmpty {
                DisclosureGroup(isExpanded: $termsOpen) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(notes.terms.enumerated()), id: \.offset) { _, t in
                            (Text(t.term).bold() + Text(": " + t.definition)).font(.stBody).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 4)
                } label: { Text("Key terms · \(notes.terms.count)").font(.stBodyStrong) }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotePointRow: View {
    let point: StudyNotes.Point

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if point.kind == .point {
                Text("•").font(.stBody).foregroundStyle(Theme.textTertiary)
            } else {
                Text(point.kind.label).font(.stSmallStrong)
                    .foregroundStyle(point.kind == .caution ? Theme.attention : Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fillSubtle))
            }
            Group {
                if point.kind == .formula {
                    Text(point.text).font(.system(size: Theme.Size.s, design: .monospaced))
                } else {
                    Text(ChatPanel.markdown(point.text)).font(.stBody)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !point.sources.isEmpty {
                Text(point.sources.prefix(2).joined(separator: ", ")).font(.stSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }
}

/// An AI chat reply with any ```diagram blocks drawn in place.
struct ReplyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(DiagramBlocks.split(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let t):
                    Text(ChatPanel.markdown(t)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                case .diagram(let d):
                    DiagramView(diagram: d, width: 420)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(Theme.canvas))
                case .pending:
                    Label("Drawing a diagram…", systemImage: "chart.xyaxis.line").font(.stSmall).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}
