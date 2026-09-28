import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import StudyCore

let madrid = TimeZone(identifier: "Europe/Madrid")!

func d(_ s: String) -> LocalDate { LocalDate(s)! }
func t(_ s: String) -> LocalTime { LocalTime(s)! }
func at(_ date: String, _ time: String, _ tz: TimeZone = madrid) -> Date { d(date).at(t(time), tz: tz) }

func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        ?? Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
}

func fixtureText(_ name: String) -> String { try! String(contentsOf: fixtureURL(name), encoding: .utf8) }

/// A store in a temporary folder with one term and a few courses.
func makeStore(file: Bool = false) throws -> StudyStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("st-tests-\(UUID().uuidString)")
    let store: StudyStore
    if file {
        let paths = AppPaths(database: root.appendingPathComponent("study.db"), root: root.appendingPathComponent("files"))
        store = try StudyStore.open(paths: paths)
    } else {
        store = try StudyStore.inMemory(root: root)
    }
    store.setSetting("default_timezone", "Europe/Madrid")
    return store
}

@discardableResult
func seedCourses(_ store: StudyStore) throws -> (term: Int, hm: Int, mkt: Int) {
    let term = try store.saveTerm(Term(name: "Fall 2026", startDate: d("2026-09-07"), endDate: d("2026-12-18"), isCurrent: true))
    let hm = try store.saveCourse(Course(termId: term, code: "HM210", name: "Revenue Management", color: "ocean", aliases: "revman"))
    let mkt = try store.saveCourse(Course(termId: term, code: "MKT201", name: "Hospitality Marketing", color: "clay"))
    return (term, hm, mkt)
}

enum FixtureFactory {
    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("st-fixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func zip(_ files: [String: Data], to out: URL) throws {
        let dir = tempDir().appendingPathComponent("pkg")
        for (path, data) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-r", "-X", out.path, "."]
        try p.run(); p.waitUntilExit()
    }

    /// A PNG with some text drawn on it, for OCR and slide-picture tests.
    static func png(text: String, width: Int = 900, height: Int = 300) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, in: ctx, rect: CGRect(x: 30, y: 30, width: width - 60, height: height - 60), size: 44)
        return Imaging.pngData(ctx.makeImage()!)!
    }

    static func drawText(_ s: String, in ctx: CGContext, rect: CGRect, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: attr.length), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    static func pptx(slides: [(title: String, bullets: [(Int, String)], notes: String?, picture: String?, table: [[String]]?, chart: Bool)],
                     title: String? = nil) throws -> URL {
        var files: [String: Data] = [:]
        func put(_ path: String, _ s: String) { files[path] = Data(s.utf8) }
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        put("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>"#)
        put("_rels/.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#)
        var ids = ""
        var rels = ""
        for i in slides.indices {
            ids += #"<p:sldId id="\#(256 + i)" r:id="rId\#(i + 10)"/>"#
            rels += #"<Relationship Id="rId\#(i + 10)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(i + 1).xml"/>"#
        }
        put("ppt/presentation.xml", #"<?xml version="1.0"?><p:presentation \#(ns)><p:sldIdLst>\#(ids)</p:sldIdLst></p:presentation>"#)
        put("ppt/_rels/presentation.xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)</Relationships>"#)
        if let title {
            put("docProps/core.xml", #"<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\#(title)</dc:title></cp:coreProperties>"#)
        }
        for (i, s) in slides.enumerated() {
            let n = i + 1
            var shapes = #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="100" y="100"/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:t>\#(s.title)</a:t></a:r></a:p></p:txBody></p:sp>"#
            if !s.bullets.isEmpty {
                let paras = s.bullets.map { #"<a:p><a:pPr lvl="\#($0.0)"/><a:r><a:t>\#($0.1)</a:t></a:r></a:p>"# }.joined()
                shapes += #"<p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="100" y="1500000"/></a:xfrm></p:spPr><p:txBody>\#(paras)</p:txBody></p:sp>"#
            }
            shapes += #"<p:sp><p:nvSpPr><p:cNvPr id="9" name="Num"/><p:cNvSpPr/><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\#(n)</a:t></a:r></a:p></p:txBody></p:sp>"#
            var srels = ""
            if let pic = s.picture {
                files["ppt/media/image\(n).png"] = png(text: pic)
                srels += #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\#(n).png"/>"#
                shapes += #"<p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/></p:blipFill><p:spPr><a:xfrm><a:off x="100" y="3000000"/></a:xfrm></p:spPr></p:pic>"#
            }
            if let table = s.table {
                let rows = table.map { r in "<a:tr>" + r.map { #"<a:tc><a:txBody><a:p><a:r><a:t>\#($0)</a:t></a:r></a:p></a:txBody></a:tc>"# }.joined() + "</a:tr>" }.joined()
                shapes += #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="5" name="Table"/></p:nvGraphicFramePr><p:xfrm><a:off x="100" y="4000000"/></p:xfrm><a:graphic><a:graphicData><a:tbl>\#(rows)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
            }
            if s.chart {
                srels += #"<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart\#(n).xml"/>"#
                shapes += #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="6" name="Chart"/></p:nvGraphicFramePr><p:xfrm><a:off x="100" y="5000000"/></p:xfrm><a:graphic><a:graphicData><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="rId4"/></a:graphicData></a:graphic></p:graphicFrame>"#
                put("ppt/charts/chart\(n).xml", #"<?xml version="1.0"?><c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>Occupancy by month</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:ser><c:tx><c:strRef><c:strCache><c:pt idx="0"><c:v>2026</c:v></c:pt></c:strCache></c:strRef></c:tx><c:cat><c:strRef><c:strCache><c:pt idx="0"><c:v>Jan</c:v></c:pt><c:pt idx="1"><c:v>Feb</c:v></c:pt></c:strCache></c:strRef></c:cat><c:val><c:numRef><c:numCache><c:pt idx="0"><c:v>0.62</c:v></c:pt><c:pt idx="1"><c:v>0.71</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart></c:plotArea></c:chart></c:chartSpace>"#)
            }
            if let notes = s.notes {
                srels += #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide\#(n).xml"/>"#
                put("ppt/notesSlides/notesSlide\(n).xml", #"<?xml version="1.0"?><p:notes \#(ns)><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image"/><p:cNvSpPr/><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\#(notes)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"#)
            }
            put("ppt/slides/slide\(n).xml", #"<?xml version="1.0"?><p:sld \#(ns)><p:cSld><p:spTree>\#(shapes)</p:spTree></p:cSld></p:sld>"#)
            if !srels.isEmpty {
                put("ppt/slides/_rels/slide\(n).xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(srels)</Relationships>"#)
            }
        }
        let out = tempDir().appendingPathComponent("HM210 Week 3 - Overbooking.pptx")
        try zip(files, to: out)
        return out
    }

    static func docx(sections: [(heading: String?, paragraphs: [String])], name: String = "Reading notes.docx") throws -> URL {
        var body = ""
        for s in sections {
            if let h = s.heading { body += #"<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>\#(h)</w:t></w:r></w:p>"# }
            for p in s.paragraphs { body += #"<w:p><w:r><w:t xml:space="preserve">\#(p)</w:t></w:r></w:p>"# }
        }
        body += #"<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Metric</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Formula</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>RevPAR</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>ADR x Occupancy</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"#
        let doc = #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\#(body)</w:body></w:document>"#
        let out = tempDir().appendingPathComponent(name)
        try zip(["word/document.xml": Data(doc.utf8), "[Content_Types].xml": Data("<Types/>".utf8)], to: out)
        return out
    }

    /// A PDF with a real text layer.
    static func textPDF(pages: [String], name: String = "Reading.pdf") -> URL {
        let out = tempDir().appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
        for p in pages {
            ctx.beginPDFPage(nil)
            drawText(p, in: ctx, rect: CGRect(x: 50, y: 50, width: 495, height: 742), size: 14)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out
    }

    /// A PDF whose only content is an image of text (like a scan), so there is no text layer.
    static func scannedPDF(text: String) -> URL {
        let out = tempDir().appendingPathComponent("Scanned handout.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
        let img = Imaging.loadImage(data: png(text: text, width: 1600, height: 500))!
        ctx.beginPDFPage(nil)
        ctx.draw(img, in: CGRect(x: 20, y: 500, width: 555, height: 173))
        ctx.endPDFPage()
        ctx.closePDF()
        return out
    }
}
