import Foundation

/// One chapter of a course's book, read from the Markdown a model wrote (the conventions are in
/// `BookPrompts.chapterSystem`): a `#` title, an italic standfirst, `##` sections (each one a slide in Present),
/// `:::course`, `:::example Title` and `:::check` boxes, ```diagram and ```svg figures, and a ```cards block of
/// flashcards. Reading never fails: anything unreadable is dropped with a warning, and `problems` says whether the
/// chapter is good enough to keep.
public struct ChapterDoc: Equatable {
    public struct QA: Equatable {
        public var q: String
        public var a: String
        public init(q: String, a: String) { self.q = q; self.a = a }
    }

    public enum Block: Equatable {
        case markdown(String)
        /// `kind` is course, example, note, tip or warning; `slide` is a section's summary, shown only in Present.
        case box(kind: String, title: String?, markdown: String)
        case check([QA])
        /// `svg` is safe to insert as HTML: drawn by `DiagramSVG` or passed through `SVGSanitizer`.
        case figure(svg: String, caption: String?)
    }

    public struct Section: Equatable {
        /// Nil for the opening paragraphs before the first `##`.
        public var title: String?
        public var blocks: [Block]
        public init(title: String?, blocks: [Block]) { self.title = title; self.blocks = blocks }
    }

    public var title: String
    public var standfirst: String?
    public var sections: [Section]
    public var cards: [QA]
    public var warnings: [String]

    // MARK: Limits

    public static let minSections = 4, minWords = 1_200
    public static let maxCards = 15, maxChecks = 8, maxFigures = 4, maxSVG = 20_000
    static let maxFront = 300, maxBack = 600

    static let boxKinds: Set<String> = ["course", "example", "note", "tip", "warning", "slide"]
    static let checkKinds: Set<String> = ["check", "quiz", "questions"]

    // MARK: Quality

    /// Words a reader reads (the flashcards don't count).
    public var words: Int {
        var n = Self.count(title) + Self.count(standfirst ?? "")
        for s in sections {
            n += Self.count(s.title ?? "")
            for b in s.blocks {
                switch b {
                case .markdown(let m): n += Self.count(m)
                case .box("slide", _, _): break
                case .box(_, let t, let m): n += Self.count(t ?? "") + Self.count(m)
                case .check(let qa): n += qa.reduce(0) { $0 + Self.count($1.q) + Self.count($1.a) }
                case .figure: break
                }
            }
        }
        return n
    }

    /// Why this chapter isn't good enough to keep; empty when it is.
    public var problems: [String] {
        var out: [String] = []
        if title.isEmpty { out.append("it has no title") }
        let titled = sections.filter { $0.title != nil }.count
        if titled < Self.minSections { out.append("it has \(titled) sections, fewer than \(Self.minSections)") }
        let w = words
        if w < Self.minWords { out.append("it has \(w) words, fewer than \(Self.minWords)") }
        let hasCheck = sections.contains { $0.blocks.contains { if case .check = $0 { return true }; return false } }
        if !hasCheck { out.append("it has no Check yourself questions") }
        return out
    }

    static func count(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    // MARK: Reading

    public static func parse(_ raw: String) -> ChapterDoc {
        var doc = ChapterDoc(title: "", standfirst: nil, sections: [], cards: [], warnings: [])
        let lines = unwrapped(raw.replacingOccurrences(of: "\r\n", with: "\n")).components(separatedBy: "\n")
        var i = 0
        func skipBlank() { while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 } }

        skipBlank()
        if i < lines.count, let t = heading(lines[i], level: 1) {
            // The page shows the number itself: "Chapter 3: Knowing your market" → "Knowing your market".
            let bare = t.replacingOccurrences(of: #"^(?i:chapter|ch\.?)\s*\d+\s*[:.\-–—]\s*"#, with: "", options: .regularExpression)
            doc.title = bare.isEmpty ? t : bare
            i += 1
        } else {
            doc.warnings.append("The chapter has no # title line.")
        }
        skipBlank()
        if i < lines.count, let s = italicLine(lines[i]) { doc.standfirst = s; i += 1 }

        var current = Section(title: nil, blocks: [])
        var prose: [String] = []
        var figures = 0
        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { current.blocks.append(.markdown(text)) }
            prose = []
        }
        func flushSection() {
            flushProse()
            if current.title != nil || !current.blocks.isEmpty { doc.sections.append(current) }
        }
        func addFigure(info: String, body: [String]) {
            guard figures < maxFigures else { doc.warnings.append("A figure past the first \(maxFigures) was left out."); return }
            if let f = figure(info: info, body: body, warnings: &doc.warnings) { current.blocks.append(f); figures += 1 }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = Fence(opening: trimmed) {
                var body: [String] = []
                i += 1
                while i < lines.count, !fence.closes(lines[i]) { body.append(lines[i]); i += 1 }
                i += 1
                switch fence.info {
                case "diagram", "svg": flushProse(); addFigure(info: fence.info, body: body)
                case "cards", "flashcards": doc.cards += qaPairs(body)
                default: prose.append(line); prose += body; prose.append(fence.marker)
                }
                continue
            }
            if let (kind, boxTitle) = containerOpening(trimmed) {
                var body: [String] = []
                var inner: Fence?
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    let lt = l.trimmingCharacters(in: .whitespaces)
                    if let f = inner {
                        if f.closes(l) { inner = nil }
                    } else if lt == ":::" || lt == "::::" {
                        break
                    } else if let f = Fence(opening: lt) {
                        inner = f
                    }
                    body.append(l)
                    i += 1
                }
                i += 1
                flushProse()
                if checkKinds.contains(kind) {
                    let qa = qaPairs(body)
                    if qa.isEmpty { prose += body } else { current.blocks.append(.check(Array(qa.prefix(maxChecks)))) }
                    continue
                }
                // Figures inside a box are drawn just after it.
                var text: [String] = []
                var hoisted: [(String, [String])] = []
                var j = 0
                while j < body.count {
                    if let f = Fence(opening: body[j].trimmingCharacters(in: .whitespaces)), f.info == "diagram" || f.info == "svg" {
                        var fb: [String] = []
                        j += 1
                        while j < body.count, !f.closes(body[j]) { fb.append(body[j]); j += 1 }
                        j += 1
                        hoisted.append((f.info, fb))
                    } else {
                        text.append(body[j]); j += 1
                    }
                }
                let markdown = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !markdown.isEmpty { current.blocks.append(.box(kind: boxKinds.contains(kind) ? kind : "note", title: boxTitle, markdown: markdown)) }
                for (info, fb) in hoisted { addFigure(info: info, body: fb) }
                continue
            }
            if let h = heading(line, level: 2) ?? (doc.title.isEmpty ? nil : heading(line, level: 1)) {
                flushSection()
                current = Section(title: h, blocks: [])
                i += 1
                continue
            }
            // A box closed twice.
            if trimmed == ":::" { i += 1; continue }
            prose.append(line)
            i += 1
        }
        flushSection()

        // Questions written as plain Q:/A: lines under a "Check yourself" heading still become a check.
        for k in doc.sections.indices where isCheckTitle(doc.sections[k].title) {
            let hasCheck = doc.sections[k].blocks.contains { if case .check = $0 { return true }; return false }
            guard !hasCheck else { continue }
            var blocks: [Block] = []
            for b in doc.sections[k].blocks {
                if case .markdown(let m) = b, case let qa = qaPairs(m.components(separatedBy: "\n")), qa.count >= 2 {
                    blocks.append(.check(Array(qa.prefix(maxChecks))))
                } else {
                    blocks.append(b)
                }
            }
            doc.sections[k].blocks = blocks
        }
        if doc.cards.count > maxCards {
            doc.warnings.append("Kept the first \(maxCards) of \(doc.cards.count) flashcards.")
            doc.cards = Array(doc.cards.prefix(maxCards))
        }
        return doc
    }

    static func isCheckTitle(_ t: String?) -> Bool {
        guard let t = t?.lowercased() else { return false }
        return t.contains("check yourself") || t.contains("test yourself") || t.contains("self-check") || t.contains("review questions")
    }

    /// A reply wrapped whole in a ```markdown fence.
    static func unwrapped(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), let nl = t.firstIndex(of: "\n") else { return s }
        let info = t[t.index(t.startIndex, offsetBy: 3)..<nl].trimmingCharacters(in: .whitespaces).lowercased()
        guard info.isEmpty || info == "markdown" || info == "md" else { return s }
        let inner = t[t.index(after: nl)...].dropLast(3)
        return String(inner)
    }

    /// `# Title` (level 1) or `## Heading` (level 2), with any closing hashes removed.
    static func heading(_ line: String, level: Int) -> String? {
        let hashes = String(repeating: "#", count: level)
        guard line.hasPrefix(hashes + " ") || line.hasPrefix(hashes + "\t") else { return nil }
        var t = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("#") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// `*One sentence.*` or `_One sentence._`, without the markers.
    static func italicLine(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for m in ["*", "_"] where t.count > 2 && t.hasPrefix(m) && t.hasSuffix(m) && !t.hasPrefix(m + m) {
            let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : inner
        }
        return nil
    }

    /// `:::kind` or `:::kind Title`.
    static func containerOpening(_ line: String) -> (String, String?)? {
        guard line.hasPrefix(":::"), line.count > 3 else { return nil }
        let rest = line.drop(while: { $0 == ":" }).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: " ", maxSplits: 1)
        let kind = parts[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        guard !kind.isEmpty, kind.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (kind, title.isEmpty ? nil : title)
    }

    struct Fence {
        var marker: String
        var info: String
        init?(opening line: String) {
            guard let ch = line.first, ch == "`" || ch == "~" else { return nil }
            let run = line.prefix { $0 == ch }
            guard run.count >= 3 else { return nil }
            marker = String(run)
            info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.lowercased() } ?? ""
            if ch == "`", info.contains("`") { return nil }
        }
        func closes(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let ch = marker.first, t.hasPrefix(marker) else { return false }
            return t.allSatisfy { $0 == ch }
        }
    }

    // MARK: Questions and flashcards

    static let qPattern = try! NSRegularExpression(pattern: #"^(?:[-*+]\s+|\d+[.)]\s+)?(?:\*\*|__)?\s*(?:q|question|front)\s*\d*\s*[:.)](?:\*\*|__)?\s*"#, options: .caseInsensitive)
    static let aPattern = try! NSRegularExpression(pattern: #"^(?:[-*+]\s+)?(?:\*\*|__)?\s*(?:a|answer|back)\s*\d*\s*[:.)](?:\*\*|__)?\s*"#, options: .caseInsensitive)

    /// Q:/A: pairs; an answer runs on until the next question.
    static func qaPairs(_ lines: [String]) -> [QA] {
        var out: [QA] = []
        var q: String?
        var a: [String] = []
        var inAnswer = false
        func flush() {
            if let question = q?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
                let answer = a.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { out.append(QA(q: clip(question, maxFront), a: clip(answer, maxBack))) }
            }
            q = nil; a = []; inAnswer = false
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let rest = strip(qPattern, t) {
                flush(); q = rest
            } else if let rest = strip(aPattern, t), q != nil {
                inAnswer = true; a = [rest]
            } else if inAnswer {
                a.append(line)
            } else if q != nil, !t.isEmpty {
                q! += " " + t
            }
        }
        flush()
        return out
    }

    static func strip(_ re: NSRegularExpression, _ s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return nil }
        var rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix("**") && !rest.dropLast(2).contains("**") { rest = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        return rest
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    // MARK: Figures

    static func figure(info: String, body: [String], warnings: inout [String]) -> Block? {
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if info == "diagram" {
            let json = JSON.parse(text)
            // A drawing sent as {"kind": "svg", "svg": "<svg…>"} is still a drawing.
            if let o = json as? [String: Any], (o["kind"] as? String)?.lowercased() == "svg", let svg = o["svg"] as? String {
                return figure(info: "svg", body: [svg], warnings: &warnings).map { f in
                    if case let .figure(drawn, caption) = f { return .figure(svg: drawn, caption: caption ?? (o["title"] as? String)) }
                    return f
                }
            }
            guard let d = Diagram.parse(json).diagram else { warnings.append("A diagram couldn't be read and was left out."); return nil }
            var drawn = d
            drawn.title = nil
            return .figure(svg: DiagramSVG.render(drawn, themed: true), caption: d.title)
        }
        guard text.count <= maxSVG, let svg = SVGSanitizer.sanitize(text) else { warnings.append("A drawing couldn't be used and was left out."); return nil }
        return .figure(svg: svg, caption: svgTitle(text))
    }

    static func svgTitle(_ svg: String) -> String? {
        guard let open = svg.range(of: "<title>"), let close = svg.range(of: "</title>", range: open.upperBound..<svg.endIndex) else { return nil }
        let t = svg[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: For the page

    /// What `Book.render` in book.js draws. `accent` is the course colour as CSS, for light and dark.
    public func payload(kicker: String?, number: Int?, language: String, accent: (light: String, dark: String)? = nil,
                        restore: (section: Int, fraction: Double)? = nil, chrome: Bool = false) -> [String: Any] {
        var p: [String: Any] = [
            "lang": language,
            "title": title,
            "sections": sections.map { s -> [String: Any] in
                ["title": s.title ?? NSNull(), "blocks": s.blocks.map(Self.blockPayload)]
            },
            "chrome": chrome,
            "cards": cards.count,
        ]
        if let kicker { p["kicker"] = kicker }
        if let number { p["number"] = number }
        if let standfirst { p["standfirst"] = standfirst }
        if let accent { p["accent"] = ["light": accent.light, "dark": accent.dark] }
        if let restore { p["restore"] = ["section": restore.section, "fraction": restore.fraction] }
        return p
    }

    static func blockPayload(_ b: Block) -> [String: Any] {
        switch b {
        case .markdown(let m): return ["type": "md", "md": m]
        case let .box(kind, title, m): return ["type": "box", "kind": kind, "title": title ?? NSNull(), "md": m]
        case .check(let qa): return ["type": "check", "items": qa.map { ["q": $0.q, "a": $0.a] }]
        case let .figure(svg, caption): return ["type": "figure", "svg": svg, "caption": caption ?? NSNull()]
        }
    }
}
