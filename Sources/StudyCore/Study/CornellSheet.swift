import Foundation
import CoreGraphics
import CoreText

public struct CornellSheet: Equatable {
    public struct Cue: Equatable { public var text: String; public var kind: String; public var sourceLocators: [String] }
    public var title: String
    public var courseCode: String
    public var materialTitle: String
    public var date: String
    public var cues: [Cue]
    public var summaryPrompt: String
    public var lookYourself: [String]

    public init(title: String, courseCode: String, materialTitle: String, date: String, cues: [Cue], summaryPrompt: String, lookYourself: [String]) {
        self.title = title; self.courseCode = courseCode; self.materialTitle = materialTitle; self.date = date
        self.cues = cues; self.summaryPrompt = summaryPrompt; self.lookYourself = lookYourself
    }

    public var json: String {
        JSON.string([
            "title": title, "courseCode": courseCode, "materialTitle": materialTitle, "date": date,
            "cues": cues.map { ["text": $0.text, "kind": $0.kind, "sourceLocators": $0.sourceLocators] },
            "summaryPrompt": summaryPrompt, "lookYourself": lookYourself,
        ])
    }

    public static func decode(_ s: String?) -> CornellSheet? {
        guard let d = JSON.parse(s) as? [String: Any] else { return nil }
        let cues = (d["cues"] as? [[String: Any]] ?? []).map {
            Cue(text: $0["text"] as? String ?? "", kind: $0["kind"] as? String ?? "question", sourceLocators: $0["sourceLocators"] as? [String] ?? [])
        }
        return CornellSheet(title: d["title"] as? String ?? "", courseCode: d["courseCode"] as? String ?? "",
                            materialTitle: d["materialTitle"] as? String ?? "", date: d["date"] as? String ?? "", cues: cues,
                            summaryPrompt: d["summaryPrompt"] as? String ?? "", lookYourself: d["lookYourself"] as? [String] ?? [])
    }

    public var markdown: String {
        var md = "# \(title)\n\n\(courseCode) · \(materialTitle) · \(date)\n\n## Cues\n\n"
        for (i, c) in cues.enumerated() {
            md += "\(i + 1). \(c.text)" + (c.sourceLocators.isEmpty ? "" : " _(\(c.sourceLocators.joined(separator: ", ")))_") + "\n"
        }
        md += "\n## Summary\n\n\(summaryPrompt)\n"
        if !lookYourself.isEmpty { md += "\n## Look at these yourself\n\n" + lookYourself.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return md
    }

    /// Obsidian-friendly Markdown with YAML frontmatter (§9.3).
    public var obsidianMarkdown: String {
        "---\ncourse: \"\(courseCode)\"\nmaterial: \"\(materialTitle.replacingOccurrences(of: "\"", with: "'"))\"\ntype: cornell_sheet\ndate: \(date)\n---\n\n" + markdown
    }
}

public extension StudyStore {
    struct CueInput {
        public var text: String; public var kind: String; public var sourceChunkIds: [Int]
        public init(text: String, kind: String, sourceChunkIds: [Int]) { self.text = text; self.kind = kind; self.sourceChunkIds = sourceChunkIds }
    }

    func saveCornellSheet(materialId: Int, title: String, cues: [CueInput], summaryPrompt: String, lookYourselfChunkIds: [Int]) throws -> WriteResult {
        let (m, courseId) = try requireMaterialWithCourse(materialId)
        guard (8...20).contains(cues.count) else { throw ToolError.invalid("A Cornell sheet needs 8-20 cues (got \(cues.count)).") }
        guard !title.isEmpty, title.count <= 120 else { throw ToolError.invalid("title must be 1-120 characters.") }
        guard !summaryPrompt.isEmpty, summaryPrompt.count <= 300 else { throw ToolError.invalid("summary_prompt must be 1-300 characters.") }
        var out: [CornellSheet.Cue] = []
        for c in cues {
            guard !c.text.isEmpty, c.text.count <= 200 else { throw ToolError.invalid("Each cue must be 1-200 characters.") }
            guard c.kind == "question" || c.kind == "term" else { throw ToolError.invalid("Cue kind must be question or term.") }
            if Self.cueLooksLikeAnswer(c) {
                throw ToolError.invalid("Cue \"\(c.text.prefix(60))\" seems to contain its answer.",
                                        hint: "Cues must contain no answers: use a bare term or a question.")
            }
            out.append(.init(text: c.text, kind: c.kind, sourceLocators: try validateChunks(c.sourceChunkIds, materialId: materialId)))
        }
        let look = lookYourselfChunkIds.isEmpty ? [] : try validateChunks(lookYourselfChunkIds, materialId: materialId, field: "look_yourself_chunk_ids")
        let course = self.course(courseId)
        let sheet = CornellSheet(title: title, courseCode: course?.shortName ?? "", materialTitle: m.title,
                                 date: LocalDate.today(tz: timezone).string, cues: out, summaryPrompt: summaryPrompt, lookYourself: look)
        return try saveClaudeNote(courseId: courseId, materialId: materialId, kind: "cornell_sheet", title: title,
                                  content: sheet.markdown, dataJson: sheet.json)
    }

    /// Heuristic guard for "Cues must contain no answers": a term followed by a definition.
    static func cueLooksLikeAnswer(_ c: CueInput) -> Bool {
        let t = c.text
        for sep in [": ", " – ", " — ", " = ", " - "] {
            if let r = t.range(of: sep) {
                let after = t[r.upperBound...].split(separator: " ").count
                if after >= 5 { return true }
            }
        }
        if c.kind == "term" && t.split(separator: " ").count > 10 { return true }
        return false
    }
}

public enum PaperSize: String, CaseIterable { case a4, letter
    public var size: CGSize { self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792) }
    public var label: String { self == .a4 ? "A4" : "US Letter" }
}

/// Draws the handwriting-ready sheet: cues on the left (~30%), ruled writing space on the right, rows never split,
/// summary box and "look at these yourself" at the end.
public enum CornellRenderer {
    public static func pdf(_ sheet: CornellSheet, paper: PaperSize = .a4) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle as String: sheet.title] as CFDictionary) else { return Data() }
        let margin: CGFloat = 42.52 // 15 mm
        let width = paper.size.width - 2 * margin
        let cueW = width * 0.30
        let lineGap: CGFloat = 22.7 // 8 mm ruling
        let ink = CGColor(gray: 0.1, alpha: 1)
        let muted = CGColor(gray: 0.45, alpha: 1)
        let rule = CGColor(gray: 0.78, alpha: 1)

        func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return base
        }
        func attributed(_ s: String, _ f: CTFont, _ color: CGColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        }
        func height(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
            let fs = CTFramesetterCreateWithAttributedString(a)
            let s = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: a.length), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            return ceil(s.height)
        }
        // Draw with a top-left origin coordinate `top` measured from the top of the page.
        func draw(_ a: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
            let h = height(a, width: width)
            let rect = CGRect(x: x, y: paper.size.height - top - h, width: width, height: h + 1)
            let fs = CTFramesetterCreateWithAttributedString(a)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: a.length), CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            return h
        }
        func hline(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: CGColor, width w: CGFloat = 0.5) {
            ctx.setStrokeColor(color); ctx.setLineWidth(w)
            ctx.move(to: CGPoint(x: x0, y: paper.size.height - y)); ctx.addLine(to: CGPoint(x: x1, y: paper.size.height - y)); ctx.strokePath()
        }

        var page = 0
        var y: CGFloat = 0
        func beginPage() {
            if page > 0 { ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            page += 1
            y = margin
            let prefix = sheet.courseCode.isEmpty || sheet.materialTitle.localizedCaseInsensitiveContains(sheet.courseCode) ? "" : sheet.courseCode + "  ·  "
            let header = attributed(prefix + sheet.materialTitle, font(14, bold: true), ink)
            y += draw(header, x: margin, top: y, width: width - 90)
            _ = draw(attributed(sheet.date + (page > 1 ? "  ·  p. \(page)" : ""), font(9), muted), x: margin + width - 90, top: margin + 3, width: 90)
            y += 4
            if page == 1 && sheet.title.caseInsensitiveCompare(sheet.materialTitle) != .orderedSame {
                y += draw(attributed(sheet.title, font(10), muted), x: margin, top: y, width: width)
                y += 2
            }
            hline(y + 4, from: margin, to: margin + width, color: ink, width: 1)
            y += 12
        }
        beginPage()
        let bottom = paper.size.height - margin
        for (i, cue) in sheet.cues.enumerated() {
            let cueText = attributed("\(i + 1). \(cue.text)", font(10.5, bold: cue.kind == "term"), ink)
            let loc = attributed(cue.sourceLocators.joined(separator: ", "), font(7.5), muted)
            let textH = height(cueText, width: cueW - 10) + (cue.sourceLocators.isEmpty ? 0 : height(loc, width: cueW - 10) + 3)
            let lines = max(5, Int(ceil((textH + 8) / lineGap)))
            let rowH = CGFloat(lines) * lineGap
            if y + rowH > bottom { beginPage() }
            let top = y
            let h1 = draw(cueText, x: margin, top: top + 4, width: cueW - 10)
            if !cue.sourceLocators.isEmpty { _ = draw(loc, x: margin, top: top + 6 + h1, width: cueW - 10) }
            for l in 1...lines { hline(top + CGFloat(l) * lineGap, from: margin + cueW, to: margin + width, color: rule) }
            // Column divider.
            ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: margin + cueW - 4, y: paper.size.height - top)); ctx.addLine(to: CGPoint(x: margin + cueW - 4, y: paper.size.height - top - rowH)); ctx.strokePath()
            hline(top + rowH, from: margin, to: margin + cueW - 4, color: CGColor(gray: 0.88, alpha: 1))
            y += rowH
        }
        // Summary box and "look at these yourself".
        let prompt = attributed(sheet.summaryPrompt, font(10.5), ink)
        let look = sheet.lookYourself.isEmpty ? nil : attributed("Look at these yourself: " + sheet.lookYourself.joined(separator: ", "), font(9), muted)
        let boxH = 22 + height(prompt, width: width - 16) + 6 * lineGap + 10
        let lookH = look.map { height($0, width: width) + 10 } ?? 0
        if y + 12 + boxH + lookH > bottom { beginPage() }
        y += 12
        let boxTop = y
        ctx.setStrokeColor(ink); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: margin, y: paper.size.height - boxTop - boxH, width: width, height: boxH))
        var by = boxTop + 6
        by += draw(attributed("Summary", font(11, bold: true), ink), x: margin + 8, top: by, width: width - 16) + 2
        by += draw(prompt, x: margin + 8, top: by, width: width - 16) + 4
        for l in 1...6 { hline(by + CGFloat(l) * lineGap, from: margin + 8, to: margin + width - 8, color: rule) }
        y = boxTop + boxH + 10
        if let look { _ = draw(look, x: margin, top: y, width: width) }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
