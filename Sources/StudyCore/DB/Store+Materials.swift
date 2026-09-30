import Foundation
import CryptoKit

public enum ImportOutcome: Equatable {
    case imported(id: Int, title: String)
    case duplicate(existingId: Int, title: String)
    case failed(message: String)
}

public extension StudyStore {
    // MARK: Queries

    func materials(courseId: Int? = nil, statuses: [String]? = nil, processed: Bool? = nil, role: MaterialRole? = nil) -> [Material] {
        var sql = "SELECT * FROM materials WHERE 1=1"
        var params: [Any?] = []
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let statuses, !statuses.isEmpty { sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; params += statuses }
        if let processed { sql += processed ? " AND processed_at IS NOT NULL" : " AND processed_at IS NULL" }
        if let role { sql += " AND role = ?"; params.append(role.rawValue) }
        sql += " ORDER BY imported_at DESC, id DESC"
        return ((try? db.query(sql, params)) ?? []).map(Material.init)
    }

    func material(_ id: Int) -> Material? {
        (try? db.first("SELECT * FROM materials WHERE id = ?", [id])).map(Material.init)
    }

    func chunks(materialId: Int, fromOrdinal: Int? = nil, toOrdinal: Int? = nil) -> [Chunk] {
        var sql = "SELECT * FROM chunks WHERE material_id = ?"
        var params: [Any?] = [materialId]
        if let f = fromOrdinal { sql += " AND ordinal >= ?"; params.append(f) }
        if let t = toOrdinal { sql += " AND ordinal <= ?"; params.append(t) }
        sql += " ORDER BY ordinal"
        return ((try? db.query(sql, params)) ?? []).map(Chunk.init)
    }

    func chunks(ids: [Int]) -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        return ((try? db.query("SELECT * FROM chunks WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ","))) ORDER BY material_id, ordinal", ids)) ?? []).map(Chunk.init)
    }

    func assetsURL(for m: Material) -> URL? { m.assetsPath.map { paths.absolute($0) } }

    func imageURLs(for chunk: Chunk, material: Material) -> [URL] {
        guard let dir = assetsURL(for: material) else { return [] }
        return chunk.images.map { dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Import pipeline (§6.3)

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Hash → dedupe → parse → file under Library → insert rows in one transaction. Never throws: failures become a
    /// `failed` material with a readable reason so the queue keeps moving.
    @discardableResult
    func importMaterial(from url: URL, courseId: Int? = nil, role: MaterialRole? = nil, externalUid: String? = nil,
                        removeOriginal: Bool = false, ocr: Bool = true) -> ImportOutcome {
        guard let data = try? Data(contentsOf: url) else { return .failed(message: "Could not read \(url.lastPathComponent).") }
        let hash = Self.sha256(data)
        if let dup = try? db.first("SELECT id, title FROM materials WHERE content_hash = ?", [hash]) {
            if removeOriginal { try? FileManager.default.removeItem(at: url) }
            return .duplicate(existingId: dup.i("id"), title: dup.str("title"))
        }
        let filename = url.lastPathComponent
        let courses = self.courses()
        let term = currentTerm()
        let folderCourse = courseId.flatMap { id in courses.first { $0.id == id } }
        let dir = libraryFolder(term: term, course: folderCourse)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = Slug.make(url.deletingPathExtension().lastPathComponent, max: 50)
        let assetsDir = dir.appendingPathComponent("\(stem)-\(hash.prefix(8))_assets")

        let parsed: ParsedMaterial?
        var failure: String?
        do {
            parsed = try MaterialParser.parse(url, options: .init(assetsDir: assetsDir, ocrScannedPages: ocr, renderPDFPages: true))
        } catch {
            parsed = nil
            failure = error is CocoaError ? error.localizedDescription : "\(error)"
        }

        // File the original.
        var dest = dir.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n)).\(url.pathExtension)"); n += 1
        }
        do { try data.write(to: dest) } catch { return .failed(message: "Could not file \(filename): \(error.localizedDescription)") }
        if removeOriginal { try? FileManager.default.removeItem(at: url) }

        let firstText = parsed?.chunks.prefix(2).map { $0.textMd }.joined(separator: " ") ?? ""
        let suggested = courseId == nil ? CourseMatcher.best(filename + " " + (parsed?.title ?? "") + " " + String(firstText.prefix(600)), courses: courses)?.id : nil
        let guessedRole = role ?? Self.guessRole(filename: filename, title: parsed?.title ?? "", text: firstText)
        let kind = parsed?.kind ?? Self.kind(forExtension: url.pathExtension)
        let status: String
        if parsed == nil { status = "failed" }
        else if parsed!.status == "needs_ocr" { status = "needs_ocr" }
        else { status = courseId != nil ? "ready" : "inbox" }
        let hasAssets = (try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path).isEmpty == false) ?? false
        if !hasAssets { try? FileManager.default.removeItem(at: assetsDir) }

        do {
            let id: Int = try db.transaction {
                let id = try db.execute("""
                    INSERT INTO materials(course_id, suggested_course_id, title, kind, role, original_filename, stored_path, assets_path,
                      content_hash, status, status_detail, page_count, external_uid)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [courseId, suggested, parsed?.title ?? url.deletingPathExtension().lastPathComponent, kind, guessedRole.rawValue,
                          filename, paths.relative(dest), hasAssets ? paths.relative(assetsDir) : nil, hash, status,
                          failure ?? parsed?.statusDetail, parsed?.pageCount, externalUid]).lastInsertId
                for (i, c) in (parsed?.chunks ?? []).enumerated() {
                    try db.execute("""
                        INSERT INTO chunks(material_id, ordinal, locator, heading, text_md, notes_md, extra_md, image_count, images, ocr, token_estimate)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, [id, i + 1, c.locator, c.heading, c.textMd, c.notesMd, c.extraMd, c.imageCount,
                              c.images.isEmpty ? nil : JSON.string(c.images), c.ocr, c.tokenEstimate])
                }
                audit("import_material", entity: "material", id: id, detail: filename)
                return id
            }
            if let failure { return .failed(message: "\(filename): \(failure)") }
            return .imported(id: id, title: parsed?.title ?? filename)
        } catch {
            return .failed(message: "Could not save \(filename): \(error)")
        }
    }

    static func kind(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pptx": return "slides"
        case "pdf": return "pdf"
        case "docx": return "doc"
        case "png", "jpg", "jpeg", "heic", "tiff": return "image"
        default: return "text"
        }
    }

    static func guessRole(filename: String, title: String, text: String) -> MaterialRole {
        let s = (filename + " " + title).lowercased()
        let t = text.prefix(1500).lowercased()
        if s.contains("syllabus") || s.contains("course outline") || s.contains("module guide") || s.contains("course guide") || s.contains("handbook") { return .syllabus }
        if s.contains("rubric") || s.contains("marking") || s.contains("criteria") || s.contains("grading") { return .rubric }
        if s.contains("past paper") || s.contains("past exam") || s.contains("mock exam") || s.contains("sample exam") || s.contains("exam 20") || s.contains("resit") { return .pastExam }
        if s.contains("brief") || s.contains("assignment") || s.contains("assessment") || s.contains("coursework") { return .brief }
        if s.contains("reading") || s.contains("chapter") || s.contains("article") || s.contains("case study") { return .reading }
        if t.contains("learning outcomes") && t.contains("assessment") && (t.contains("weight") || t.contains("%")) { return .syllabus }
        return .lecture
    }

    func libraryFolder(term: Term?, course: Course?) -> URL {
        let termName = Slug.make(term?.name ?? "General", max: 40)
        let courseName = course.map { Slug.make($0.codeOrName, max: 40) } ?? "_unfiled"
        return paths.library.appendingPathComponent(termName).appendingPathComponent(courseName)
    }

    /// One-tap confirm from the Inbox: sets the course and files the original into the course folder.
    func confirmMaterial(_ id: Int, courseId: Int, role: MaterialRole? = nil) throws {
        guard let m = material(id), let course = course(courseId) else { throw StoreError.notFound("Material or course not found.") }
        let dir = libraryFolder(term: currentTerm(), course: course)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stored = m.storedPath
        var assets = m.assetsPath
        let fm = FileManager.default
        if let sp = m.storedPath {
            let src = paths.absolute(sp)
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if src.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL, !fm.fileExists(atPath: dst.path),
               (try? fm.moveItem(at: src, to: dst)) != nil { stored = paths.relative(dst) }
        }
        if let ap = m.assetsPath {
            let src = paths.absolute(ap)
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if src.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL, !fm.fileExists(atPath: dst.path),
               (try? fm.moveItem(at: src, to: dst)) != nil { assets = paths.relative(dst) }
        }
        let status = (m.status == "inbox") ? "ready" : m.status
        try db.execute("""
            UPDATE materials SET course_id = ?, status = ?, stored_path = ?, assets_path = ?, role = COALESCE(?, role),
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, [courseId, status, stored, assets, role?.rawValue, id])
        audit("confirm_material", entity: "material", id: id)
    }

    func updateMaterial(_ id: Int, title: String? = nil, role: MaterialRole? = nil) throws {
        if let title { try db.execute("UPDATE materials SET title = ? WHERE id = ?", [title, id]) }
        if let role { try db.execute("UPDATE materials SET role = ? WHERE id = ?", [role.rawValue, id]) }
    }

    func deleteMaterial(_ id: Int, removeFiles: Bool = true) throws {
        guard let m = material(id) else { return }
        try db.transaction {
            try db.execute("DELETE FROM materials WHERE id = ?", [id])
            audit("delete_material", entity: "material", id: id, detail: m.title)
        }
        // SQLite can reuse the id, so a stale skip must not hide the next import.
        let skipped = skippedMaterialIds()
        if skipped.contains(id) { setSkippedMaterialIds(skipped.subtracting([id])) }
        if removeFiles {
            if let sp = m.storedPath { try? FileManager.default.trashItem(at: paths.absolute(sp), resultingItemURL: nil) }
            if let ap = m.assetsPath { try? FileManager.default.removeItem(at: paths.absolute(ap)) }
        }
    }

    func markProcessed(_ id: Int) throws {
        try db.execute("UPDATE materials SET processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [id])
    }

    // MARK: Inbox skips

    /// Filed materials waiting to be processed, minus any the student skipped.
    func unprocessedMaterials() -> [Material] {
        let skipped = skippedMaterialIds()
        return materials(statuses: ["ready"], processed: false).filter { !skipped.contains($0.id) }
    }

    /// Takes a filed material out of the Inbox without processing it (which would skew Insights and prompt a recall)
    /// or deleting it. It stays in its course and in Study, where it can still be processed.
    func skipMaterial(_ id: Int) {
        setSkippedMaterialIds(skippedMaterialIds().union([id]))
        audit("skip_material", entity: "material", id: id)
    }

    func skippedMaterialIds() -> Set<Int> { Set(JSON.intArray(setting("inbox_skipped_materials"))) }

    func setSkippedMaterialIds(_ ids: Set<Int>) {
        setSetting("inbox_skipped_materials", ids.isEmpty ? nil : JSON.string(ids.sorted()))
    }

    /// Adds on-device OCR of pictures inside slides and documents, so text in screenshots and diagrams reaches Claude.
    /// Idempotent; returns the number of chunks enriched.
    @discardableResult
    func enrichImageText(materialId: Int) -> Int {
        guard let m = material(materialId), m.kind == "slides" || m.kind == "doc", let dir = assetsURL(for: m) else { return 0 }
        var n = 0
        for c in chunks(materialId: materialId) where !c.images.isEmpty && !(c.extraMd ?? "").contains("Text in pictures:") {
            var found: [String] = []
            for file in c.images {
                let t = Imaging.recognizeText(url: dir.appendingPathComponent(file)).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 12 { found.append(t.replacingOccurrences(of: "\n", with: " · ")) }
            }
            let marker = found.isEmpty ? "Text in pictures: (none)" : "Text in pictures:\n" + found.map { "- " + $0 }.joined(separator: "\n")
            let extra = [c.extraMd, marker].compactMap { $0 }.joined(separator: "\n\n")
            let tokens = Int((Double(c.textMd.count + (c.notesMd?.count ?? 0) + extra.count) / 4).rounded(.up))
            _ = try? db.execute("UPDATE chunks SET extra_md = ?, token_estimate = ? WHERE id = ?", [extra, tokens, c.id])
            n += 1
        }
        return n
    }

    func materialsNeedingImageText() -> [Int] {
        let rows = (try? db.query("""
            SELECT DISTINCT m.id FROM materials m JOIN chunks c ON c.material_id = m.id
            WHERE m.kind IN ('slides','doc') AND c.images IS NOT NULL AND (c.extra_md IS NULL OR c.extra_md NOT LIKE '%Text in pictures:%')
            """)) ?? []
        return rows.map { $0.i("id") }
    }

    // MARK: Handwriting capture (photo of the student's own sheet)

    func handwritingCaptures(materialId: Int? = nil) -> [HandwritingCapture] {
        let rows = materialId.map { (try? db.query("SELECT * FROM handwriting_captures WHERE material_id = ? ORDER BY id DESC", [$0])) ?? [] }
            ?? ((try? db.query("SELECT * FROM handwriting_captures ORDER BY id DESC LIMIT 50")) ?? [])
        return rows.map(HandwritingCapture.init)
    }

    /// Copies the photo, reads the handwriting on device, and runs a quick local coverage check against the lecture's concepts.
    @discardableResult
    func addHandwritingCapture(materialId: Int, imageURL: URL) throws -> HandwritingCapture {
        guard let img = Imaging.loadImage(imageURL, maxPixel: 3000) else { throw StoreError.invalid("That image could not be opened.") }
        let text = Imaging.recognizeText(img)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = paths.captures.appendingPathComponent("m\(materialId)-\(f.string(from: Date())).jpg")
        try FileManager.default.createDirectory(at: paths.captures, withIntermediateDirectories: true)
        if let small = Imaging.loadImage(imageURL, maxPixel: 2400), let jpeg = Imaging.jpegData(small) { try jpeg.write(to: dest) }
        let coverage = Self.coverage(text: text, concepts: concepts(materialId: materialId))
        let id = try db.execute("INSERT INTO handwriting_captures(material_id, image_path, ocr_text, coverage_json) VALUES(?,?,?,?)",
                                [materialId, paths.relative(dest), text, JSON.string(coverage)]).lastInsertId
        let courseId = material(materialId)?.courseId
        try db.execute("""
            INSERT INTO study_sessions(course_id, material_id, kind, started_at, ended_at, summary, items_total, items_correct, created_by)
            VALUES(?,?,'handwriting',?,?,?,?,?,'user')
            """, [courseId, materialId, ISO.instant(Date()), ISO.instant(Date()),
                  "Handwritten sheet captured. Local check covered \((coverage["covered"] as? [String])?.count ?? 0) of \(coverage["total"] as? Int ?? 0) concepts.",
                  coverage["total"] as? Int, (coverage["covered"] as? [String])?.count])
        audit("handwriting_capture", entity: "material", id: materialId)
        return HandwritingCapture(row: try db.first("SELECT * FROM handwriting_captures WHERE id = ?", [id])!)
    }

    /// Deterministic keyword coverage: a concept counts as mentioned when most of its significant name words appear.
    static func coverage(text: String, concepts: [Concept]) -> [String: Any] {
        let norm = " " + CourseMatcher.normalize(text).replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression) + " "
        var covered: [String] = [], missing: [String] = []
        for c in concepts {
            let words = CourseMatcher.normalize(c.name).replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
                .split(separator: " ").map(String.init).filter { $0.count >= 3 && !["the", "and", "for", "with", "of"].contains($0) }
            if words.isEmpty { continue }
            let hits = words.filter { w in norm.contains(" " + String(w.prefix(max(4, w.count - 2)))) }.count
            if Double(hits) / Double(words.count) >= 0.6 { covered.append(c.name) } else { missing.append(c.name) }
        }
        let total = covered.count + missing.count
        return ["covered": covered, "missing": missing, "total": total,
                "coverage_pct": total == 0 ? 0 : Int((Double(covered.count) / Double(total) * 100).rounded())]
    }
}
