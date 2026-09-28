import Foundation
import CoreGraphics
import PDFKit

public struct ParsedChunk: Equatable {
    public var locator: String
    public var heading: String?
    public var textMd: String
    public var notesMd: String?
    public var extraMd: String?
    public var imageCount: Int = 0
    /// Asset file names (relative to the material's assets folder).
    public var images: [String] = []
    public var ocr: Bool = false

    public var tokenEstimate: Int {
        let chars = textMd.count + (notesMd?.count ?? 0) + (extraMd?.count ?? 0)
        return Int((Double(chars) / 4).rounded(.up))
    }
}

public struct ParsedMaterial {
    public var kind: String           // slides | pdf | doc | text | image
    public var title: String
    public var pageCount: Int?
    public var chunks: [ParsedChunk]
    public var status: String = "ready" // ready | needs_ocr
    public var statusDetail: String?
}

public enum ParseError: Error, CustomStringConvertible {
    case unsupported(String), unreadable(String), tooLarge(Int)
    public var description: String {
        switch self {
        case .unsupported(let ext): return "Files of type .\(ext) are not supported. Use PowerPoint, PDF, Word, Markdown, text or an image."
        case .unreadable(let m): return m
        case .tooLarge(let mb): return "The file is \(mb) MB, over the 100 MB limit."
        }
    }
}

/// Parses course materials into chunks, all locally (§6.3). Pictures are extracted to `assetsDir`
/// so Claude can look at them; text inside scanned pages is recognized on device.
public enum MaterialParser {
    public static let supportedExtensions: Set<String> = ["pptx", "pdf", "docx", "md", "markdown", "txt", "png", "jpg", "jpeg", "heic", "tiff"]
    public static let maxBytes = 100 * 1024 * 1024

    public struct Options {
        public var assetsDir: URL?
        public var ocrScannedPages = true
        public var renderPDFPages = true
        public init(assetsDir: URL? = nil, ocrScannedPages: Bool = true, renderPDFPages: Bool = true) {
            self.assetsDir = assetsDir; self.ocrScannedPages = ocrScannedPages; self.renderPDFPages = renderPDFPages
        }
    }

    public static func parse(_ url: URL, options: Options = Options()) throws -> ParsedMaterial {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ParseError.unsupported(ext) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { throw ParseError.tooLarge(size / 1_048_576) }
        let fallbackTitle = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        if let dir = options.assetsDir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        switch ext {
        case "pptx": return try PPTXParser.parse(url, fallbackTitle: fallbackTitle, assetsDir: options.assetsDir)
        case "docx": return try DOCXParser.parse(url, fallbackTitle: fallbackTitle, assetsDir: options.assetsDir)
        case "pdf": return try PDFParser.parse(url, fallbackTitle: fallbackTitle, options: options)
        case "md", "markdown", "txt":
            guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
                throw ParseError.unreadable("The text file could not be read.")
            }
            return TextParser.parse(text, title: fallbackTitle)
        default:
            return try ImageParser.parse(url, fallbackTitle: fallbackTitle, assetsDir: options.assetsDir)
        }
    }

    static func goodTitle(_ meta: String?, fallback: String) -> String {
        guard let t = meta?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return fallback }
        let generic = ["powerpoint presentation", "presentation", "untitled", "slide 1", "document", "microsoft word", "title"]
        if generic.contains(where: { t.lowercased().hasPrefix($0) }) { return fallback }
        return t
    }

    /// Writes an extracted image as a size-capped JPEG (or keeps small PNG/JPEG as-is). Returns the file name.
    static func saveImage(_ data: Data, name: String, to dir: URL?) -> String? {
        guard let dir else { return nil }
        guard let img = Imaging.loadImage(data: data, maxPixel: 1600) else { return nil }
        // Skip tiny decorations (bullets, logos).
        if img.width < 64 || img.height < 64 { return nil }
        guard let jpeg = Imaging.jpegData(img) else { return nil }
        let file = name + ".jpg"
        do { try jpeg.write(to: dir.appendingPathComponent(file)) } catch { return nil }
        return file
    }
}

// MARK: - PowerPoint

enum PPTXParser {
    struct Shape { var y: Int; var x: Int; var kind: String; var node: XNode; var isTitle: Bool }

    static func parse(_ url: URL, fallbackTitle: String, assetsDir: URL?) throws -> ParsedMaterial {
        let data = try Data(contentsOf: url)
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw ParseError.unreadable("\(error)") }
        guard let presData = try zip.read("ppt/presentation.xml"), let pres = XMLTree.parse(presData) else {
            throw ParseError.unreadable("This PowerPoint file has no slides part.")
        }
        let presRels = XMLTree.relationships(try zip.read("ppt/_rels/presentation.xml.rels"))
        var slidePaths: [String] = []
        for s in pres.all("p:sldId") {
            if let rid = s["r:id"], let rel = presRels[rid] { slidePaths.append(resolvePartPath(base: "ppt/presentation.xml", target: rel.target)) }
        }
        if slidePaths.isEmpty {
            slidePaths = zip.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { (Int($0.filter(\.isNumber)) ?? 0) < (Int($1.filter(\.isNumber)) ?? 0) }
        }

        var metaTitle: String?
        if let core = try? zip.read("docProps/core.xml"), let root = XMLTree.parse(core) { metaTitle = root.first("dc:title")?.text }

        var chunks: [ParsedChunk] = []
        var firstSlideTitle: String?
        for (i, path) in slidePaths.enumerated() {
            let n = i + 1
            guard let sd = try zip.read(path), let slide = XMLTree.parse(sd) else {
                chunks.append(ParsedChunk(locator: "slide \(n)", heading: nil, textMd: "", notesMd: nil)); continue
            }
            let rels = XMLTree.relationships(try? zip.read(relsPath(for: path)))
            var shapes: [Shape] = []
            if let tree = slide.first("p:spTree") { collectShapes(tree, into: &shapes) }
            shapes.sort { abs($0.y - $1.y) > 150_000 ? $0.y < $1.y : $0.x < $1.x }

            var title: String?
            var lines: [String] = []
            var extra: [String] = []
            var imageCount = 0
            var images: [String] = []
            for s in shapes {
                switch s.kind {
                case "sp":
                    let text = paragraphs(s.node)
                    if s.isTitle {
                        let t = text.map(\.1).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { title = title.map { "\($0) \(t)" } ?? t }
                    } else {
                        for (lvl, line) in text where !line.isEmpty {
                            lines.append(String(repeating: "  ", count: lvl) + "- " + line)
                        }
                    }
                case "pic":
                    imageCount += 1
                    if let rid = s.node.first("a:blip")?["r:embed"], let rel = rels[rid] {
                        let media = resolvePartPath(base: path, target: rel.target)
                        if let md = try? zip.read(media),
                           let saved = MaterialParser.saveImage(md, name: String(format: "s%03d-%02d", n, images.count + 1), to: assetsDir) {
                            images.append(saved)
                        }
                    }
                case "table":
                    extra.append(markdownTable(s.node))
                case "chart":
                    if let rid = s.node.first("c:chart")?["r:id"], let rel = rels[rid],
                       let cd = try? zip.read(resolvePartPath(base: path, target: rel.target)), let chart = XMLTree.parse(cd) {
                        extra.append(chartSummary(chart))
                        imageCount += 1
                    }
                case "diagram":
                    imageCount += 1
                    let t = s.node.texts("a:t")
                    if !t.isEmpty { extra.append("Diagram text: " + t) }
                default: break
                }
            }
            // SmartArt text lives in a separate part.
            for (_, rel) in rels where rel.type.hasSuffix("/diagramData") {
                if let dd = try? zip.read(resolvePartPath(base: path, target: rel.target)), let root = XMLTree.parse(dd) {
                    let items = root.all("a:p").map { $0.texts("a:t") }.filter { !$0.isEmpty }
                    if !items.isEmpty { extra.append("Diagram: " + items.joined(separator: " · ")) }
                }
            }
            var notes: String?
            if let noteRel = rels.values.first(where: { $0.type.hasSuffix("/notesSlide") }),
               let nd = try? zip.read(resolvePartPath(base: path, target: noteRel.target)), let nroot = XMLTree.parse(nd) {
                var noteLines: [String] = []
                for sp in nroot.all("p:sp") {
                    let ph = sp.first("p:ph")?["type"]
                    if ph == "sldImg" || ph == "sldNum" || ph == "hdr" || ph == "ftr" || ph == "dt" { continue }
                    noteLines += paragraphs(sp).map(\.1).filter { !$0.isEmpty }
                }
                let joined = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { notes = joined }
            }
            if i == 0 { firstSlideTitle = title }
            var body = lines.joined(separator: "\n")
            if let title { body = "## \(title)\n" + body }
            chunks.append(ParsedChunk(locator: "slide \(n)", heading: title, textMd: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                      notesMd: notes, extraMd: extra.isEmpty ? nil : extra.joined(separator: "\n\n"),
                                      imageCount: imageCount, images: images))
        }
        guard !chunks.isEmpty else { throw ParseError.unreadable("This PowerPoint file has no slides.") }
        let title = MaterialParser.goodTitle(metaTitle, fallback: MaterialParser.goodTitle(firstSlideTitle, fallback: fallbackTitle))
        return ParsedMaterial(kind: "slides", title: title, pageCount: chunks.count, chunks: chunks)
    }

    static func collectShapes(_ tree: XNode, into out: inout [Shape]) {
        for c in tree.children {
            let off = c.first("a:off")
            let y = Int(off?["y"] ?? "") ?? Int.max / 2
            let x = Int(off?["x"] ?? "") ?? 0
            switch c.name {
            case "p:sp":
                let ph = c.first("p:ph")?["type"]
                if ph == "sldNum" || ph == "dt" || ph == "ftr" { continue }
                out.append(Shape(y: y, x: x, kind: "sp", node: c, isTitle: ph == "title" || ph == "ctrTitle"))
            case "p:pic": out.append(Shape(y: y, x: x, kind: "pic", node: c, isTitle: false))
            case "p:graphicFrame":
                if c.first("a:tbl") != nil { out.append(Shape(y: y, x: x, kind: "table", node: c, isTitle: false)) }
                else if c.first("c:chart") != nil { out.append(Shape(y: y, x: x, kind: "chart", node: c, isTitle: false)) }
                else if c.first("dgm:relIds") != nil { out.append(Shape(y: y, x: x, kind: "diagram", node: c, isTitle: false)) }
            case "p:grpSp": collectShapes(c, into: &out)
            default: break
            }
        }
    }

    /// (indent level, text) per paragraph.
    static func paragraphs(_ node: XNode) -> [(Int, String)] {
        node.all("a:p").map { p in
            let lvl = Int(p.child("a:pPr")?["lvl"] ?? "0") ?? 0
            var s = ""
            for c in p.children {
                switch c.name {
                case "a:r", "a:fld": s += c.texts("a:t")
                case "a:br": s += " "
                default: break
                }
            }
            return (lvl, s.trimmingCharacters(in: .whitespaces))
        }
    }

    static func markdownTable(_ node: XNode) -> String {
        let rows = node.all("a:tr").map { tr in
            tr.childrenNamed("a:tc").map { $0.all("a:p").map { $0.texts("a:t") }.joined(separator: " ").replacingOccurrences(of: "|", with: "/") }
        }
        guard let header = rows.first, !header.isEmpty else { return "" }
        var md = "| " + header.joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: header.count)
        for r in rows.dropFirst() { md += "\n| " + r.joined(separator: " | ") + " |" }
        return "Table:\n" + md
    }

    static func chartSummary(_ chart: XNode) -> String {
        let title = chart.first("c:title").map { $0.texts("a:t") } ?? ""
        let series = chart.all("c:ser")
        var categories: [String] = []
        var cols: [(String, [String])] = []
        for (i, s) in series.enumerated() {
            let name = s.child("c:tx")?.first("c:v")?.text ?? "Series \(i + 1)"
            if categories.isEmpty, let cat = s.child("c:cat") {
                categories = cat.all("c:pt").sorted { (Int($0["idx"] ?? "0") ?? 0) < (Int($1["idx"] ?? "0") ?? 0) }.map { $0.first("c:v")?.text ?? "" }
            }
            let vals = s.child("c:val")?.all("c:pt").sorted { (Int($0["idx"] ?? "0") ?? 0) < (Int($1["idx"] ?? "0") ?? 0) }.map { $0.first("c:v")?.text ?? "" } ?? []
            cols.append((name, vals))
        }
        var md = "Chart" + (title.isEmpty ? "" : " \"\(title)\"") + ":\n"
        guard !cols.isEmpty else { return md + "(no data)" }
        md += "| Category | " + cols.map(\.0).joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: cols.count + 1)
        let n = max(categories.count, cols.map(\.1.count).max() ?? 0)
        for r in 0..<min(n, 60) {
            let cat = r < categories.count ? categories[r] : "\(r + 1)"
            md += "\n| \(cat) | " + cols.map { r < $0.1.count ? $0.1[r] : "" }.joined(separator: " | ") + " |"
        }
        return md
    }
}

// MARK: - Word

enum DOCXParser {
    static func parse(_ url: URL, fallbackTitle: String, assetsDir: URL?) throws -> ParsedMaterial {
        let data = try Data(contentsOf: url)
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw ParseError.unreadable("\(error)") }
        guard let docData = try zip.read("word/document.xml"), let doc = XMLTree.parse(docData), let body = doc.first("w:body") else {
            throw ParseError.unreadable("This Word file has no document body.")
        }
        let rels = XMLTree.relationships(try? zip.read("word/_rels/document.xml.rels"))
        var metaTitle: String?
        if let core = try? zip.read("docProps/core.xml"), let root = XMLTree.parse(core) { metaTitle = root.first("dc:title")?.text }

        struct Section { var heading: String?; var lines: [String] = []; var images: [String] = []; var imageCount = 0 }
        var sections: [Section] = [Section(heading: nil)]
        var imageIndex = 0
        var docTitle: String?

        func handleImages(_ node: XNode) {
            for blip in node.all("a:blip") {
                sections[sections.count - 1].imageCount += 1
                if let rid = blip["r:embed"], let rel = rels[rid],
                   let md = try? zip.read(resolvePartPath(base: "word/document.xml", target: rel.target)) {
                    imageIndex += 1
                    if let saved = MaterialParser.saveImage(md, name: String(format: "img%03d", imageIndex), to: assetsDir) {
                        sections[sections.count - 1].images.append(saved)
                    }
                }
            }
        }

        for el in body.children {
            if el.name == "w:tbl" {
                let rows = el.all("w:tr").map { $0.childrenNamed("w:tc").map { $0.texts("w:t").replacingOccurrences(of: "|", with: "/") } }
                if let header = rows.first, !header.isEmpty {
                    var md = "| " + header.joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: header.count)
                    for r in rows.dropFirst() { md += "\n| " + r.joined(separator: " | ") + " |" }
                    sections[sections.count - 1].lines.append(md)
                }
                handleImages(el)
                continue
            }
            guard el.name == "w:p" else { continue }
            let style = el.child("w:pPr")?.child("w:pStyle")?["w:val"] ?? ""
            let outline = el.child("w:pPr")?.child("w:outlineLvl")?["w:val"].flatMap(Int.init)
            var text = ""
            for r in el.all("w:r") {
                for c in r.children {
                    switch c.name {
                    case "w:t": text += c.text
                    case "w:tab": text += " "
                    case "w:br": text += "\n"
                    default: break
                    }
                }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            handleImages(el)
            let headingLevel: Int? = {
                if style.lowercased() == "title" { return 0 }
                if let r = style.range(of: #"(?i)(heading|berschrift|titre|kop|titolo|encabezado)\s?(\d)"#, options: .regularExpression) {
                    return Int(style[r].filter(\.isNumber))
                }
                return outline.map { $0 + 1 }
            }()
            if let lvl = headingLevel, !text.isEmpty {
                if lvl == 0 { docTitle = docTitle ?? text; continue }
                if lvl <= 2 {
                    sections.append(Section(heading: text))
                } else {
                    sections[sections.count - 1].lines.append(String(repeating: "#", count: min(lvl + 1, 6)) + " " + text)
                }
                continue
            }
            if text.isEmpty { continue }
            let isList = el.child("w:pPr")?.child("w:numPr") != nil
            sections[sections.count - 1].lines.append(isList ? "- " + text : text)
        }

        var chunks: [ParsedChunk] = []
        let hasHeadings = sections.contains { $0.heading != nil }
        if hasHeadings {
            for s in sections where !(s.lines.isEmpty && s.heading == nil && s.images.isEmpty) {
                let heading = s.heading ?? "Introduction"
                chunks.append(ParsedChunk(locator: "section \"\(heading)\"", heading: heading,
                                          textMd: (["## \(heading)"] + s.lines).joined(separator: "\n\n"),
                                          imageCount: s.imageCount, images: s.images))
            }
        } else {
            let all = sections.flatMap(\.lines).joined(separator: "\n\n")
            chunks = TextParser.windows(all).enumerated().map { i, t in ParsedChunk(locator: "part \(i + 1)", heading: nil, textMd: t) }
            if let first = sections.first, !chunks.isEmpty { chunks[0].images = first.images; chunks[0].imageCount = first.imageCount }
        }
        if chunks.isEmpty { throw ParseError.unreadable("This Word file has no text.") }
        let title = MaterialParser.goodTitle(docTitle ?? metaTitle, fallback: fallbackTitle)
        return ParsedMaterial(kind: "doc", title: title, pageCount: nil, chunks: chunks)
    }
}

// MARK: - PDF

enum PDFParser {
    static func parse(_ url: URL, fallbackTitle: String, options: MaterialParser.Options) throws -> ParsedMaterial {
        guard let doc = PDFDocument(url: url), let cgDoc = CGPDFDocument(url as CFURL) else {
            throw ParseError.unreadable("The PDF could not be opened. It may be damaged or password-protected.")
        }
        if doc.isLocked { throw ParseError.unreadable("The PDF is password-protected.") }
        let count = doc.pageCount
        guard count > 0 else { throw ParseError.unreadable("The PDF has no pages.") }
        var texts: [String] = []
        for i in 0..<count { texts.append(doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
        let totalText = texts.reduce(0) { $0 + $1.count }
        let scanned = totalText < 30 * max(1, count / 4) && texts.allSatisfy { $0.count < 30 }

        var chunks: [ParsedChunk] = []
        var ocrPages = 0
        for i in 0..<count {
            guard let page = cgDoc.page(at: i + 1) else { continue }
            var text = texts[i]
            var ocr = false
            let imgCount = Imaging.imageCount(page: page)
            var images: [String] = []
            let isVisual = imgCount > 0 || text.count < 30
            if isVisual, options.renderPDFPages, let dir = options.assetsDir, i < 300,
               let img = Imaging.render(page: page, width: 1400), let jpeg = Imaging.jpegData(img) {
                let file = String(format: "p%03d.jpg", i + 1)
                if (try? jpeg.write(to: dir.appendingPathComponent(file))) != nil { images.append(file) }
            }
            if text.count < 30 && options.ocrScannedPages, i < 300, let img = Imaging.render(page: page, width: 2000) {
                let recognized = Imaging.recognizeText(img)
                if recognized.count > text.count { text = recognized; ocr = true; ocrPages += 1 }
            }
            let heading = text.split(separator: "\n").first.map { String($0.prefix(90)) }
            chunks.append(ParsedChunk(locator: "p. \(i + 1)", heading: heading, textMd: text, imageCount: imgCount,
                                      images: images, ocr: ocr))
        }
        let title = MaterialParser.goodTitle(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, fallback: fallbackTitle)
        var result = ParsedMaterial(kind: "pdf", title: title, pageCount: count, chunks: chunks)
        let recognized = chunks.reduce(0) { $0 + $1.textMd.count }
        if scanned && recognized < 30 {
            result.status = "needs_ocr"
            result.statusDetail = "No text could be read from this PDF, even with on-device text recognition. Claude can still look at the page images."
        } else if ocrPages > 0 {
            result.statusDetail = "Text on \(ocrPages) scanned page\(ocrPages == 1 ? "" : "s") was recognized on this Mac."
        }
        return result
    }
}

// MARK: - Text and Markdown

enum TextParser {
    static func parse(_ text: String, title: String) -> ParsedMaterial {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [(String?, [String])] = [(nil, [])]
        for line in lines {
            if line.range(of: #"^#{1,3}\s+\S"#, options: .regularExpression) != nil {
                sections.append((line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), [line]))
            } else {
                sections[sections.count - 1].1.append(line)
            }
        }
        var chunks: [ParsedChunk] = []
        if sections.count > 1 {
            for (h, body) in sections {
                let t = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                let heading = h ?? "Introduction"
                // Very long sections are windowed so no chunk is huge.
                let parts = windows(t)
                for (i, p) in parts.enumerated() {
                    let loc = parts.count > 1 ? "section \"\(heading)\" (\(i + 1))" : "section \"\(heading)\""
                    chunks.append(ParsedChunk(locator: loc, heading: heading, textMd: p))
                }
            }
        } else {
            chunks = windows(text).enumerated().map { ParsedChunk(locator: "part \($0.offset + 1)", heading: nil, textMd: $0.element) }
        }
        if chunks.isEmpty { chunks = [ParsedChunk(locator: "part 1", heading: nil, textMd: "")] }
        var docTitle = title
        if let first = lines.first(where: { $0.hasPrefix("# ") }) { docTitle = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return ParsedMaterial(kind: "text", title: docTitle, pageCount: nil, chunks: chunks)
    }

    /// ~600-word windows that break on paragraph boundaries where possible.
    static func windows(_ text: String, words: Int = 600) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [String] = []
        var current: [String] = []
        var count = 0
        for p in paragraphs {
            let n = p.split(whereSeparator: { $0.isWhitespace }).count
            if count + n > words && !current.isEmpty {
                out.append(current.joined(separator: "\n\n")); current = []; count = 0
            }
            if n > words {
                let ws = p.split(whereSeparator: { $0.isWhitespace })
                var i = 0
                while i < ws.count {
                    out.append(ws[i..<min(i + words, ws.count)].joined(separator: " ")); i += words
                }
                continue
            }
            current.append(p); count += n
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n\n")) }
        return out
    }
}

// MARK: - Images (photos of whiteboards, handouts)

enum ImageParser {
    static func parse(_ url: URL, fallbackTitle: String, assetsDir: URL?) throws -> ParsedMaterial {
        guard let img = Imaging.loadImage(url, maxPixel: 3000) else { throw ParseError.unreadable("The image could not be opened.") }
        let text = Imaging.recognizeText(img)
        var images: [String] = []
        if let dir = assetsDir, let small = Imaging.loadImage(url, maxPixel: 1600), let jpeg = Imaging.jpegData(small) {
            if (try? jpeg.write(to: dir.appendingPathComponent("image.jpg"))) != nil { images.append("image.jpg") }
        }
        let chunk = ParsedChunk(locator: "image", heading: text.split(separator: "\n").first.map(String.init), textMd: text,
                                imageCount: 1, images: images, ocr: true)
        return ParsedMaterial(kind: "image", title: fallbackTitle, pageCount: 1, chunks: [chunk])
    }
}
