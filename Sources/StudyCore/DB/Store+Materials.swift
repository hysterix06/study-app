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

    /// Hash → dedupe → parse → sort → file under Library → insert rows in one transaction, then file it under its course
    /// when that's clear. Never throws: failures become a `failed` material with a readable reason so the queue keeps
    /// moving. A `role` passed in is the student's choice; otherwise the sorting rules decide.
    @discardableResult
    func importMaterial(from url: URL, courseId: Int? = nil, role: MaterialRole? = nil, externalUid: String? = nil,
                        hints: ImportHints = .none, removeOriginal: Bool = false, ocr: Bool = true) -> ImportOutcome {
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

        let firstText = parsed?.chunks.prefix(3).map { [$0.heading, $0.textMd].compactMap { $0 }.joined(separator: "\n") }
            .joined(separator: "\n") ?? ""
        let kind = parsed?.kind ?? Self.kind(forExtension: url.pathExtension)
        let sort = FileSorter.sort(.init(filename: filename, title: parsed?.title ?? "", text: firstText,
                                         sectionName: hints.sectionName, moduleName: hints.moduleName, kind: kind))
        let suggested = courseId == nil ? suggestCourse(for: [filename, hints.moduleName, parsed?.title, String(firstText.prefix(600))], courses: courses) : nil
        let status: String
        if parsed == nil { status = "failed" }
        else if parsed!.status == "needs_ocr" { status = "needs_ocr" }
        else { status = courseId != nil ? "ready" : "inbox" }
        let hasAssets = (try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path).isEmpty == false) ?? false
        if !hasAssets { try? FileManager.default.removeItem(at: assetsDir) }

        do {
            let id: Int = try db.transaction {
                let id = try db.execute("""
                    INSERT INTO materials(course_id, suggested_course_id, title, kind, role, role_source, role_confidence, sort_reason,
                      section_name, module_name, original_filename, stored_path, assets_path, content_hash, status, status_detail,
                      page_count, external_uid)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [courseId, suggested, parsed?.title ?? url.deletingPathExtension().lastPathComponent, kind,
                          (role ?? sort.role).rawValue, role != nil ? "user" : sort.source, role != nil ? nil : sort.confidence,
                          role != nil ? nil : sort.reason, hints.sectionName?.nilIfEmpty, hints.moduleName?.nilIfEmpty,
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
            // The course is clear (its code or name, or the only course this term): file it without asking.
            if courseId == nil, let suggested { try? confirmMaterial(id, courseId: suggested) }
            refreshTaughtDate(id)
            pairSolutions(id)
            splitPractice(materialId: id)
            // Filed straight into its course (a Moodle sync, a drop on the course): confirmMaterial didn't run.
            if courseId != nil { fileJoinedPath(id) }
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
        let movedFrom = m.courseId.flatMap { $0 == courseId ? nil : $0 }
        try db.execute("""
            UPDATE materials SET course_id = ?, status = ?, stored_path = ?, assets_path = ?, role = COALESCE(?, role),
              role_source = CASE WHEN ? IS NOT NULL AND ? != role THEN 'user' ELSE role_source END,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, [courseId, status, stored, assets, role?.rawValue, role?.rawValue, role?.rawValue, id])
        try db.execute("UPDATE practice_items SET course_id = ? WHERE material_id = ?", [courseId, id])
        if let movedFrom {
            // Its problems, cards and slides pointed at the old course's topics: they're linked again to this one's.
            try db.execute("UPDATE practice_items SET topic_id = NULL WHERE material_id = ?", [id])
            try db.execute("UPDATE cards SET course_id = ?, topic_id = NULL WHERE material_id = ?", [courseId, id])
            try db.execute("DELETE FROM topic_coverage WHERE material_id = ?", [id])
            markPathStale(courseId: movedFrom)
        }
        audit("confirm_material", entity: "material", id: id)
        refreshTaughtDate(id)
        pairSolutions(id)
        splitPractice(materialId: id)
        fileJoinedPath(id)
        if movedFrom != nil { linkPracticeAndCards(courseId: courseId) }
    }

    /// A lecture, reading, class example, syllabus or past exam reshapes its course's path: the path is rebuilt once
    /// the files settle, and meanwhile the file is linked to the topics it teaches.
    func fileJoinedPath(_ id: Int) {
        guard let m = material(id), let courseId = m.courseId, !m.excluded,
              [.lecture, .reading, .example, .syllabus, .pastExam].contains(m.role) else { return }
        markPathStale(courseId: courseId)
        linkCoverageByWords(materialId: id)
    }

    /// A role the student picked. It is never changed by anything automatic afterwards.
    func updateMaterial(_ id: Int, title: String? = nil, role: MaterialRole? = nil) throws {
        if let title { try db.execute("UPDATE materials SET title = ? WHERE id = ?", [title, id]) }
        if let role {
            try db.execute("""
                UPDATE materials SET role = ?, role_source = 'user', role_confidence = NULL, sort_reason = NULL,
                  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
                """, [role.rawValue, id])
        }
    }

    func deleteMaterial(_ id: Int, removeFiles: Bool = true) throws {
        guard let m = material(id) else { return }
        try db.transaction {
            try db.execute("DELETE FROM materials WHERE id = ?", [id])
            audit("delete_material", entity: "material", id: id, detail: m.title)
        }
        if removeFiles {
            if let sp = m.storedPath { try? FileManager.default.trashItem(at: paths.absolute(sp), resultingItemURL: nil) }
            if let ap = m.assetsPath { try? FileManager.default.removeItem(at: paths.absolute(ap)) }
        }
    }

    func markProcessed(_ id: Int) throws {
        try db.execute("UPDATE materials SET processed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [id])
    }

    // MARK: Not used

    /// Filed materials waiting to be processed, minus any set aside.
    func unprocessedMaterials() -> [Material] {
        materials(statuses: ["ready"], processed: false).filter { !$0.excluded }
    }

    /// Sets a file aside ("Not used"): it stays in its course, kept for reference, and is never used. This is the
    /// student's choice, so nothing automatic undoes it.
    func skipMaterial(_ id: Int) {
        setExcluded(id, true)
    }

    func setExcluded(_ id: Int, _ excluded: Bool) {
        _ = try? db.execute("""
            UPDATE materials SET excluded = ?, role_source = 'user',
              read_state = CASE WHEN ? = 1 THEN 'skipped' WHEN read_state = 'skipped' THEN 'pending' ELSE read_state END,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, [excluded, excluded, id])
        audit(excluded ? "exclude_material" : "include_material", entity: "material", id: id)
    }

    func skippedMaterialIds() -> Set<Int> {
        Set(((try? db.query("SELECT id FROM materials WHERE excluded = 1")) ?? []).map { $0.i("id") })
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
}
