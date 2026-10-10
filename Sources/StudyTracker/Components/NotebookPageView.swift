import SwiftUI
import AppKit
import StudyCore
import SwiftMath

/// One topic's page of the handwritten notebook, drawn natively on dotted paper: the words (with the course's own
/// wording when its slides have it), the pictures (what to draw and label, with a reference drawing) and the formulas,
/// typeset. It's what the student copies from, so it's laid out the way the page should look when they've written it.
struct NotebookPageView: View {
    var topic: PathTopic
    var number: String
    var guide: TopicNotebook?
    /// "✓ Written · p. 14" beside the title.
    var showMark = true
    /// Mark written (or change it); nil hides the button.
    var onMark: ((PathTopic) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let g = guide, !(g.terms.isEmpty && g.diagrams.isEmpty && g.formulas.isEmpty) {
                if !g.terms.isEmpty { words(g.terms) }
                if !g.diagrams.isEmpty { pictures(g.diagrams) }
                if !g.formulas.isEmpty { formulas(g.formulas) }
                if !g.links.isEmpty {
                    Text(g.links.joined(separator: "    ")).font(.stSmall).foregroundStyle(Theme.textTertiary).padding(.top, 2)
                }
            } else {
                Text("This page's guide is still being written.").font(.stBody).italic().foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DottedPaper().background(Theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
        .textSelection(.enabled)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !number.isEmpty { Text(number).font(.stBody).monospacedDigit().foregroundStyle(Theme.textTertiary) }
            Text(topic.title).font(.stBodyStrong).fontWeight(.semibold)
            Spacer(minLength: 8)
            if showMark, topic.inNotebook {
                Text("✓ Written" + (topic.notebookPage.map { " · p. \($0)" } ?? "")).font(.stSmall).foregroundStyle(Theme.textSecondary)
            }
            if let onMark {
                Button(topic.inNotebook ? "Change" : "Mark written") { onMark(topic) }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.stSmallStrong).kerning(0.6).foregroundStyle(Theme.textTertiary).padding(.top, 4)
    }

    func words(_ terms: [NotebookTerm]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Words")
            ForEach(Array(terms.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 2) {
                    (Text(t.term).bold() + Text(t.definition.isEmpty ? "" : " — ") + Text(NotebookText.attributed(t.definition)))
                        .font(.stBody).fixedSize(horizontal: false, vertical: true)
                    if let w = t.courseWording {
                        (Text("Your course: “") + Text(NotebookText.attributed(w)) + Text("”")
                            + Text(t.locator.map { "  (\($0))" } ?? "").foregroundStyle(Theme.textTertiary))
                            .font(.stSmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    func pictures(_ diagrams: [NotebookDiagram]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Pictures")
            ForEach(Array(diagrams.enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 5) {
                    Text(d.title).font(.stBody).fontWeight(.semibold).foregroundStyle(Theme.course("ocean"))
                    if let diagram = d.diagram {
                        DiagramView(diagram: diagram, width: 360)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: Theme.corner(8)).fill(Theme.canvas))
                    } else if let svg = d.svg {
                        SVGDrawing(svg: svg, title: d.title)
                    }
                    if !d.draw.isEmpty {
                        (Text("Draw: ").foregroundStyle(Theme.textSecondary) + Text(NotebookText.attributed(d.draw)))
                            .font(.stBody).fixedSize(horizontal: false, vertical: true)
                    }
                    if !d.labels.isEmpty {
                        Text("Label: " + d.labels.joined(separator: ", ")).font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    func formulas(_ formulas: [NotebookFormula]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Formulas")
            ForEach(Array(formulas.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 3) {
                    FormulaView(latex: f.latex)
                    if !f.meaning.isEmpty {
                        Text(NotebookText.attributed(f.meaning, size: Theme.Size.xs)).font(.stSmall).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A unit's title between its pages, like a divider page in the notebook.
struct NotebookDivider: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.stSmallStrong).kerning(0.6).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    }
}

/// Dotted paper, in the theme's ink.
struct DottedPaper: View {
    var spacing: CGFloat = 16
    var body: some View {
        Canvas { ctx, size in
            var dots = Path()
            for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                }
            }
            ctx.fill(dots, with: .style(Theme.textPrimary.opacity(0.13)))
        }
        .accessibilityHidden(true)
    }
}

/// A formula, typeset by SwiftMath in the text colour. One SwiftMath can't read is shown as plain maths instead.
struct FormulaView: View {
    var latex: String
    var size: CGFloat = 17

    var body: some View {
        if let image = NotebookImages.formula(latex, size: size) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, alignment: .leading)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel(InlineMath.plain(latex))
        } else {
            Text(NotebookText.attributed("$\(latex)$", size: Theme.Size.m)).font(.system(size: Theme.Size.m))
        }
    }
}

/// A model's reference drawing (already sanitised: plain shapes in one colour), drawn by the system in the theme's
/// pictures colour.
struct SVGDrawing: View {
    var svg: String
    var title: String

    var body: some View {
        if let image = NotebookImages.drawing(svg) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 380, maxHeight: 260, alignment: .leading)
                .foregroundStyle(Theme.course("ocean"))
                .accessibilityLabel(title)
        }
    }
}

/// Typeset formulas and drawings are made once and kept: a course's notebook has a few hundred at most.
@MainActor
enum NotebookImages {
    private static let formulas = NSCache<NSString, NSImage>()
    private static let drawings = NSCache<NSString, NSImage>()
    private static var failed = Set<String>()

    static func formula(_ latex: String, size: CGFloat) -> NSImage? {
        let key = "\(size)|\(latex)"
        if let hit = formulas.object(forKey: key as NSString) { return hit }
        guard !failed.contains(key) else { return nil }
        var math = MathImage(latex: latex, fontSize: size, textColor: .black, labelMode: .display, textAlignment: .left)
        let (error, image, _) = math.asImage()
        guard error == nil, let image, image.size.width > 0 else { failed.insert(key); return nil }
        image.isTemplate = true
        formulas.setObject(image, forKey: key as NSString)
        return image
    }

    static func drawing(_ svg: String) -> NSImage? {
        if let hit = drawings.object(forKey: svg as NSString) { return hit }
        // The system draws SVG text in a serif face unless told otherwise; the app's labels are sans-serif.
        let styled = svg.replacingOccurrences(of: "<svg ", with: "<svg font-family=\"-apple-system, Helvetica Neue, Helvetica, sans-serif\" ",
                                              options: .anchored)
        guard !failed.contains(svg), let image = NSImage(data: Data(styled.utf8)), image.size.width > 0 else { failed.insert(svg); return nil }
        image.isTemplate = true
        drawings.setObject(image, forKey: svg as NSString)
        return image
    }
}

/// Words with short maths inside ("where $P^*$ is the price"): Markdown for the words, and the maths as italic Unicode
/// with real sub- and superscripts.
enum NotebookText {
    static func attributed(_ text: String, size: CGFloat = Theme.Size.s) -> AttributedString {
        var out = AttributedString()
        for run in InlineMath.runs(text) {
            var piece: AttributedString
            if run.math {
                piece = AttributedString(run.text)
                if run.text.contains(where: \.isLetter) { piece.inlinePresentationIntent = .emphasized }
            } else {
                piece = (try? AttributedString(markdown: run.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(run.text)
            }
            switch run.level {
            case .base: break
            case .sup: piece.font = .system(size: size * 0.72); piece.baselineOffset = size * 0.38
            case .sub: piece.font = .system(size: size * 0.72); piece.baselineOffset = -size * 0.18
            }
            out += piece
        }
        return out
    }
}
