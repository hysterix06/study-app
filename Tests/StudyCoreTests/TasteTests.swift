import XCTest
@testable import StudyCore
@testable import StudyAI

/// Phase 0 of the book rebuild: real chapters in the real page, to judge the voice and the look before the rest is
/// built. Both tests are opt-in and write to dist/taste/.
///
/// - `STUDY_TASTE=1 swift test --filter TasteTests/testRender` renders the sample chapter and every chapter saved in
///   dist/taste/ into an HTML page that opens in Safari. Free, so CSS changes can be checked as often as needed.
/// - `STUDY_TASTE=1 STUDY_TASTE_LIVE=1 swift test --filter TasteTests/testWrite` asks Claude Code for one course's
///   table of contents and one chapter: two requests on the student's Claude plan. It reads a *copy* of the app's
///   database. STUDY_TASTE_COURSE picks the course (default 8), STUDY_TASTE_CHAPTER the chapter (default 3) and
///   STUDY_TASTE_MODEL the model (default sonnet). A saved table of contents is reused, so a second chapter costs one
///   request.
final class TasteTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let out = repo.appendingPathComponent("dist/taste")
    let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipUnless(env["STUDY_TASTE"] == "1", "Set STUDY_TASTE=1 to render or write taste-test chapters.")
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    // MARK: Render (free)

    func testRender() throws {
        var pages = [try renderPage(markdown: fixtureText("chapter-sample.md"), name: "sample", kicker: "Revenue Management", number: 2)]
        let saved = (try? FileManager.default.contentsOfDirectory(at: Self.out, includingPropertiesForKeys: nil)) ?? []
        for md in saved where md.pathExtension == "md" {
            let meta = (try? Data(contentsOf: md.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            pages.append(try renderPage(markdown: String(contentsOf: md, encoding: .utf8), name: md.deletingPathExtension().lastPathComponent,
                                        kicker: meta["kicker"] as? String, number: meta["number"] as? Int, language: meta["language"] as? String ?? "en"))
        }
        for p in pages { print("open \(p.path)") }
    }

    @discardableResult
    func renderPage(markdown: String, name: String, kicker: String?, number: Int?, language: String = "en") throws -> URL {
        let doc = ChapterDoc.parse(markdown)
        let payload = doc.payload(kicker: kicker, number: number, language: language, accent: ("#b4532a", "#e48b5c"), chrome: true)
        let json = JSON.string(payload).replacingOccurrences(of: "</", with: "<\\/")
        let template = try String(contentsOf: Self.repo.appendingPathComponent("Resources/Book/preview.html"), encoding: .utf8)
        let html = template
            .replacingOccurrences(of: "{{BASE}}", with: Self.repo.appendingPathComponent("Resources/Book/").absoluteString)
            .replacingOccurrences(of: "{{TITLE}}", with: doc.title.replacingOccurrences(of: "<", with: "&lt;"))
            .replacingOccurrences(of: "{{PAYLOAD}}", with: json)
        let url = Self.out.appendingPathComponent("\(name).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        print("\(name): \(doc.words) words, \(doc.sections.filter { $0.title != nil }.count) sections, \(doc.cards.count) cards",
              doc.problems.isEmpty ? "" : "· problems: \(doc.problems.joined(separator: "; "))",
              doc.warnings.isEmpty ? "" : "· warnings: \(doc.warnings.joined(separator: "; "))")
        return url
    }

    // MARK: Write (two Claude Code requests)

    func testWrite() async throws {
        try XCTSkipUnless(env["STUDY_TASTE_LIVE"] == "1", "Set STUDY_TASTE_LIVE=1 too: this spends the Claude plan.")
        let claude = try XCTUnwrap(CLIRunner.findClaude(), "Claude Code isn't installed")
        let courseId = Int(env["STUDY_TASTE_COURSE"] ?? "") ?? 8
        let number = Int(env["STUDY_TASTE_CHAPTER"] ?? "") ?? 3
        let model = env["STUDY_TASTE_MODEL"] ?? "sonnet"

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("st-taste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StudyTracker")
        for suffix in ["", "-wal", "-shm"] {
            let from = source.appendingPathComponent("study.db\(suffix)")
            if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: work.appendingPathComponent("study.db\(suffix)")) }
        }
        let db = try Database(path: work.appendingPathComponent("study.db").path)
        let (course, syllabus, files) = try readCourse(db, courseId: courseId)
        let slug = course.name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        print("course \(courseId): \(course.label) · syllabus \(syllabus.count) chars · \(files.count) files")

        let provider = ClaudeCodeProvider(cli: claude, workingDirectory: work, timeout: 15 * 60, effort: nil)
        let tocURL = Self.out.appendingPathComponent("\(slug)-toc.json")
        let planJSON: Any
        if let saved = try? Data(contentsOf: tocURL), let any = try? JSONSerialization.jsonObject(with: saved) {
            planJSON = (any as? [String: Any])?["plan"] ?? any
            print("table of contents: reusing \(tocURL.lastPathComponent)")
        } else {
            let start = Date()
            let r = try await provider.send(ChatRequest(model: model, messages: [.system(BookPrompts.tocSystem),
                                                                                 .user(BookPrompts.tocUser(course: course, syllabus: syllabus, files: files))],
                                                        responseSchema: ResponseSchema(name: "book_plan", schema: JSONValue(any: BookPrompts.tocSchema)),
                                                        maxOutputTokens: BookPrompts.tocMaxOutputTokens))
            planJSON = try SchemaPrompt.extractJSON(r.text).any
            let record: [String: Any] = ["plan": planJSON, "model": model, "seconds": Int(Date().timeIntervalSince(start)),
                                         "tokens_in": r.usage.inputTokens, "tokens_out": r.usage.outputTokens]
            try Data(JSON.string(record, pretty: true).utf8).write(to: tocURL)
            print("table of contents: \(r.usage.inputTokens) in, \(r.usage.outputTokens) out, \(Int(Date().timeIntervalSince(start))) s")
        }
        let (planOrNil, warnings) = BookPlan.parse(planJSON, knownFiles: Set(files.map(\.id)))
        let plan = try XCTUnwrap(planOrNil, "the table of contents was unusable: \(warnings)")
        for (i, c) in plan.chapters.enumerated() { print("  \(i + 1). \(c.title) [\(c.syllabusRef ?? "-")] files \(c.files)") }
        for w in warnings { print("  warning: \(w)") }
        XCTAssertTrue(plan.chapters.indices.contains(number - 1), "no chapter \(number)")

        let chapter = plan.chapters[number - 1]
        let chapterFiles = files.filter { chapter.files.contains($0.id) }
        let user = BookPrompts.chapterCourseBlock(course: course, plan: plan, syllabus: syllabus) + "\n\n" + BookPrompts.chapterBlock(number: number, chapter: chapter, files: chapterFiles)
        try user.write(to: Self.out.appendingPathComponent("\(slug)-\(number)-prompt.txt"), atomically: true, encoding: .utf8)
        let start = Date()
        let r = try await provider.send(ChatRequest(model: model, messages: [.system(BookPrompts.chapterSystem), .user(user)],
                                                    maxOutputTokens: BookPrompts.chapterMaxOutputTokens))
        let seconds = Int(Date().timeIntervalSince(start))
        let name = "\(slug)-\(number)"
        try r.text.write(to: Self.out.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["kicker": plan.title, "number": number, "language": plan.language, "model": model, "seconds": seconds,
                                   "tokens_in": r.usage.inputTokens, "tokens_out": r.usage.outputTokens, "prompt_chars": user.count]
        try Data(JSON.string(meta, pretty: true).utf8).write(to: Self.out.appendingPathComponent("\(name).json"))
        print("chapter \(number): \(r.usage.inputTokens) in, \(r.usage.outputTokens) out, \(seconds) s")
        let page = try renderPage(markdown: r.text, name: name, kicker: plan.title, number: number, language: plan.language)
        print("open \(page.path)")
    }

    /// The course, its syllabus text and its teaching files, from the old database: Moodle module names as titles,
    /// slides condensed the way the app condenses them before any AI reads them.
    func readCourse(_ db: Database, courseId: Int) throws -> (BookPrompts.Course, String, [BookPrompts.File]) {
        let c = try XCTUnwrap(try db.first("SELECT code, name FROM courses WHERE id = ?", [courseId]), "no course \(courseId)")
        let course = BookPrompts.Course(name: c.str("name").trimmingCharacters(in: .whitespacesAndNewlines), code: c.string("code"))
        func chunks(_ materialId: Int) throws -> [Chunk] {
            try db.query("SELECT * FROM chunks WHERE material_id = ? ORDER BY ordinal", [materialId]).map(Chunk.init(row:))
        }
        func label(_ r: Row) -> String {
            let module = r.string("module_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (module.isEmpty ? r.str("title") : module).replacingOccurrences(of: "&amp;", with: "&")
        }
        var syllabus: [String] = []
        for m in try db.query("SELECT id, title, module_name FROM materials WHERE course_id = ? AND role = 'syllabus' AND excluded = 0 ORDER BY id", [courseId]) {
            let text = try chunks(m.i("id")).map { [$0.heading, $0.textMd].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n")
            syllabus.append("[\(label(m))]\n\(text)")
        }
        var files: [BookPrompts.File] = []
        for m in try db.query("SELECT id, title, module_name, section_name FROM materials WHERE course_id = ? AND role IN ('lecture', 'reading') AND excluded = 0 ORDER BY id", [courseId]) {
            let condensed = MaterialCondenser.condense(try chunks(m.i("id"))).chunks
            var headings: [String] = []
            for h in condensed.compactMap(\.heading) where !h.isEmpty && !headings.contains(h) { headings.append(h) }
            let text = condensed.map { ch in [ch.heading.map { "## \($0)" }, ch.textMd.isEmpty ? nil : ch.textMd].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n")
            files.append(BookPrompts.File(id: m.i("id"), title: label(m), section: m.string("section_name")?.replacingOccurrences(of: "&amp;", with: "&"),
                                          headings: Array(headings.prefix(8)), text: text))
        }
        return (course, syllabus.joined(separator: "\n\n"), files)
    }
}
