import Foundation
import StudyCore

/// The course builder's tools: read what shapes a course, then save its path, its notebook guide and its lessons.
extension ToolCatalog {
    /// Who is writing. A course-building job says whether it's the full or the basic version; an AI app the student
    /// asked directly writes the full version.
    static func authorship(_ a: Args, _ store: StudyStore) -> (tier: String, by: String) {
        if let id = a.jobId, let job = store.job(id), let tier = job.task.builderTier {
            return (tier, ClaudeJob.authorName(engine: job.engine))
        }
        return ("full", a.client ?? "an AI app")
    }

    static func courseId(_ a: Args, _ store: StudyStore) throws -> Int {
        let id = try a.int("course_id")
        guard store.course(id) != nil else { throw ToolError.notFound("Course \(id) does not exist.", hint: "Call list_courses.") }
        return id
    }

    static func toolError(_ e: StoreError) -> ToolError {
        switch e {
        case .inUse(let m): return ToolError("CONFLICT", m)
        case .notFound(let m): return ToolError.notFound(m)
        case .invalid(let m): return ToolError.invalid(m)
        }
    }

    static func pathJSON(courseId: Int, unit: Int?, _ store: StudyStore) -> [String: Any] {
        guard let p = store.path(courseId: courseId) else { return ["course_id": courseId, "path": NSNull(), "hint": "This course has no path yet."] }
        let numbers = store.topicNumbers(courseId: courseId)
        let topics = store.topics(courseId: courseId)
        let pages = store.notebooks(courseId: courseId)
        let titles = Dictionary(uniqueKeysWithValues: store.materials(courseId: courseId).map { ($0.id, $0.title) })
        var units: [[String: Any]] = []
        for (i, u) in store.units(courseId: courseId).enumerated() where unit == nil || unit == i + 1 {
            units.append(["number": i + 1, "title": u.title, "summary": u.summary as Any, "topics": topics.filter { $0.unitId == u.id }.map { t -> [String: Any] in
                var d: [String: Any] = ["id": t.id, "number": numbers[t.id] ?? "", "key": t.key, "title": t.title, "objectives": t.objectives,
                                        "est_minutes": t.estMinutes, "emphasis": t.emphasis, "mastery": t.mastery.rawValue]
                if let s = t.summary { d["summary"] = s }
                if !t.prereqIds.isEmpty { d["prereq_ids"] = t.prereqIds }
                if t.beyondCourse { d["beyond_course"] = true }
                if let s = t.userState { d["student_marked"] = s }
                if t.inNotebook { d["in_notebook"] = t.notebookPage.map { "page \($0)" } ?? "written" }
                d["notebook_page_guide"] = pages[t.id].map { "\($0.tier) (\($0.terms.count) terms, \($0.diagrams.count) pictures)" } ?? "not written"
                d["lesson"] = store.lesson(topicId: t.id).map { "\($0.tier) (\($0.sections.count) sections)" } ?? "not written"
                let sources = store.coverage(topicId: t.id).map { c -> [String: Any] in
                    ["material_id": c.materialId, "title": titles[c.materialId] ?? "", "chunk_ids": c.chunkIds]
                }
                if !sources.isEmpty { d["sources"] = sources }
                return d
            }])
        }
        var out: [String: Any] = ["course_id": courseId, "tier": p.tier, "built_with": p.builtWith as Any, "version": p.version, "units": units]
        if let a = p.approachMd { out["approach_md"] = a }
        if let a = p.anglesMd { out["angles_md"] = a }
        if !p.resources.isEmpty { out["resources"] = p.resources }
        if p.stale { out["stale"] = "New course files arrived since this path was laid out." }
        return out
    }

    static let courseReadTools: [Tool] = [
        Tool(name: "get_course_signals", title: "Course signals",
             description: """
             Everything that shapes a course's path, in one call: its syllabus (learning outcomes, weekly plan, how it's \
             graded), an outline of every lecture, reading and class example in teaching order (chunk ids to cite; ⚑ marks \
             where the lecturer stresses something), its practice problems and past exams (marks per topic), its deadlines, \
             the current path (topic ids to keep) and the files the student set aside. Call this first to build a course.
             """,
             schema: Schema.object(["course_id": Schema.int("Course id"),
                                    "max_chars": Schema.int("Size of the lecture outlines, default 60000", min: 5_000, max: 150_000)],
                                   required: ["course_id"]), write: false) { a, store in
            let id = try courseId(a, store)
            return .json(store.courseSignals(courseId: id, budget: min(max(try a.optInt("max_chars") ?? 60_000, 5_000), 150_000)))
        },
        Tool(name: "get_path", title: "Course path",
             description: """
             A course's path: units of numbered topics in learning order, with each topic's id, objectives, prerequisites, \
             emphasis, the files that teach it, whether its notebook page guide and lesson are written, and the student's \
             progress (theirs to change, not yours).
             """,
             schema: Schema.object(["course_id": Schema.int("Course id"), "unit": Schema.int("Only this unit (1 is the first)", min: 1)],
                                   required: ["course_id"]), write: false) { a, store in
            .json(pathJSON(courseId: try courseId(a, store), unit: try a.optInt("unit"), store))
        },
        Tool(name: "get_topic", title: "Topic",
             description: """
             One topic in full: its place in the path, objectives, the course's own text where it's taught (chunk ids to \
             cite for course wording and the course's angle), its notebook page guide and lesson if written, and its \
             practice problems.
             """,
             schema: Schema.object(["topic_id": Schema.int("Topic id from get_path"),
                                    "max_chars": Schema.int("Size of the course text, default 12000", min: 2_000, max: 40_000)],
                                   required: ["topic_id"]), write: false) { a, store in
            let id = try a.int("topic_id")
            guard let t = store.topic(id) else { throw ToolError.notFound("Topic \(id) does not exist.", hint: "Call get_path.") }
            let numbers = store.topicNumbers(courseId: t.courseId)
            let titles = Dictionary(uniqueKeysWithValues: store.materials(courseId: t.courseId).map { ($0.id, $0.title) })
            var d: [String: Any] = ["id": t.id, "course_id": t.courseId, "number": numbers[t.id] ?? "", "title": t.title, "objectives": t.objectives,
                                    "emphasis": t.emphasis, "est_minutes": t.estMinutes, "mastery": t.mastery.rawValue]
            if let s = t.summary { d["summary"] = s }
            if t.retired { d["retired"] = true }
            let pre = t.prereqIds.compactMap { store.topic($0) }
            if !pre.isEmpty { d["builds_on"] = pre.map { ["id": $0.id, "number": numbers[$0.id] ?? "", "title": $0.title] } }
            let budget = min(max(try a.optInt("max_chars") ?? 12_000, 2_000), 40_000)
            d["course_text"] = store.topicCourseChunks(topicId: id, budget: budget).map { c -> [String: Any] in
                var x: [String: Any] = ["chunk_id": c.id, "material": titles[c.materialId] ?? "", "locator": c.locator, "text_md": c.textMd]
                if let h = c.heading { x["heading"] = h }
                if let n = c.notesMd, !n.isEmpty { x["notes_md"] = n }
                if c.imageCount > 0 { x["has_images"] = true; x["material_id"] = c.materialId; x["ordinal"] = c.ordinal }
                return x
            }
            if let page = store.notebook(topicId: id) {
                d["notebook_page_guide"] = ["tier": page.tier, "terms": page.terms.map { ["term": $0.term, "definition": $0.definition, "course_wording": $0.courseWording as Any] },
                                            "diagrams": page.diagrams.map { ["title": $0.title, "draw": $0.draw, "has_drawing": $0.svg != nil] },
                                            "formulas": page.formulas.map { ["latex": $0.latex, "meaning": $0.meaning] }]
            }
            if let lesson = store.lesson(topicId: id) {
                d["lesson"] = ["tier": lesson.tier, "sections": lesson.sections.map { ["kind": $0.kind, "title": $0.title] }, "cards": lesson.cards.count]
            }
            let practice = store.practiceItems(topicId: id).prefix(12)
            if !practice.isEmpty {
                d["practice"] = practice.map { i -> [String: Any] in
                    var x: [String: Any] = ["id": i.id, "kind": i.kind, "prompt_md": String(i.promptMd.prefix(500)), "has_solution": i.solutionMd != nil, "source": i.source]
                    if let m = i.materialId { x["from"] = titles[m] ?? "" }
                    if let n = i.number { x["number"] = n }
                    if i.examStyle { x["exam_style"] = true }
                    return x
                }
            }
            return .json(d)
        },
    ]

    static let courseWriteTools: [Tool] = [
        Tool(name: "save_path", title: "Save the course path",
             description: """
             Lay out a course as units of numbered topics in the best order to learn it. Pass a topic's id when it stays \
             (renamed or moved too) so the student's progress stays with it; topics the student started are never lost. \
             1-16 units, 1-80 topics; prerequisites must not loop.
             """,
             schema: Schema.object([
                "course_id": Schema.int("Course id"),
                "approach_md": Schema.string("How to learn this subject, for the student: 3-6 short Markdown bullets", max: 8_000),
                "angles_md": Schema.string("What this course emphasises and how it grades, citing locators (Markdown)", max: 8_000),
                "resources": Schema.array(["type": "string", "maxLength": 200], "Up to 12 good outside resources", max: 12),
                "units": Schema.array(Schema.object([
                    "title": Schema.string("Unit title", max: 120), "summary": Schema.string("One sentence", max: 600),
                    "topics": Schema.array(Schema.object([
                        "id": Schema.int("The topic's id from get_path or get_course_signals, when it stays"),
                        "key": Schema.string("Short stable key; defaults to the title", max: 60),
                        "title": Schema.string("2-8 words", max: 160),
                        "summary": Schema.string("One or two sentences", max: 800),
                        "objectives": Schema.array(["type": "string", "maxLength": 240], "What the student can do after it (2-5)", max: 8),
                        "prereqs": Schema.array(["type": ["integer", "string"]], "Topics it builds on: ids, keys or titles", max: 8),
                        "est_minutes": Schema.int("Minutes to learn it", min: 5, max: 240),
                        "emphasis": Schema.int("0 light, 1 normal, 2 stressed in class, 3 exam-critical", min: 0, max: 3),
                        "beyond_course": Schema.bool("Background the rest needs but this course doesn't examine"),
                        "sources": Schema.array(Schema.object(["material_id": Schema.int("A lecture, reading or class example"),
                                                               "chunk_ids": Schema.intArray("Where in it")], required: ["material_id"]),
                                                "Where the course teaches it", max: 8),
                    ], required: ["title"]), "Topics in learning order", max: 40, min: 1),
                ], required: ["title", "topics"]), "Units in learning order", max: 16, min: 1),
                "assessments": Schema.array(Schema.object(["assignment_id": Schema.int("A deadline or exam"),
                                                           "topics": Schema.array(["type": ["integer", "string"]], "Topics it covers: ids, keys or titles")],
                                                          required: ["assignment_id", "topics"]), "What each exam or graded assignment covers", max: 30),
             ], required: ["course_id", "units"]), write: true) { a, store in
            let cid = try courseId(a, store)
            let units = try a.objects("units", max: 16).map { u in
                PathInput.Unit(title: try u.string("title", max: 120), summary: try u.optString("summary", max: 600), topics: try u.objects("topics", max: 40).map { t in
                    PathInput.Topic(id: try t.optInt("id"), key: try t.optString("key", max: 60), title: try t.string("title", max: 160),
                                    summary: try t.optString("summary", max: 800), objectives: try t.stringArray("objectives", max: 8, itemMax: 240),
                                    prereqs: try t.refArray("prereqs", max: 8), estMinutes: try t.optInt("est_minutes"), emphasis: try t.optInt("emphasis"),
                                    beyondCourse: try t.bool("beyond_course", default: false),
                                    sources: try t.objects("sources", max: 8, required: false).map { s in
                                        PathInput.Source(materialId: try s.int("material_id"), chunkIds: try s.intArray("chunk_ids", max: 60))
                                    })
                })
            }
            let assessments = try a.objects("assessments", max: 30, required: false).map { x in
                PathInput.Assessment(assignmentId: try x.int("assignment_id"), topics: try x.refArray("topics", max: 80))
            }
            let input = PathInput(units: units, approachMd: try a.optString("approach_md", max: 8_000), anglesMd: try a.optString("angles_md", max: 8_000),
                                  resources: try a.stringArray("resources", max: 12, itemMax: 200), assessments: assessments)
            let who = authorship(a, store)
            let r: PathSaveResult
            do { r = try store.savePath(courseId: cid, input, tier: who.tier, builtWith: who.by, createdBy: "claude") }
            catch let e as StoreError { throw toolError(e) }
            var out = r.json
            let numbers = store.topicNumbers(courseId: cid)
            out["topics"] = store.topics(courseId: cid).map { ["id": $0.id, "number": numbers[$0.id] ?? "", "title": $0.title] }
            return .json(out)
        },
        Tool(name: "save_notebook", title: "Save notebook pages",
             description: """
             Save the notebook page guide for up to 12 topics: the words (term and definition, plus the course's own wording \
             with the chunks it comes from), the pictures (what to draw and label, and a reference drawing: diagram data \
             the app draws for a graph or a process, otherwise a simple SVG) and the formulas. The student copies each page \
             by hand; aim for about 5 minutes per page. Never changes what the student marked as written.
             """,
             schema: Schema.object([
                "course_id": Schema.int("Course id"),
                "pages": Schema.array(Schema.object([
                    "topic_id": Schema.int("Topic id from get_path"),
                    "terms": Schema.array(Schema.object([
                        "term": Schema.string("The word or phrase", max: 80),
                        "definition": Schema.string("A clear university-level definition, one or two sentences", max: 400),
                        "course_wording": Schema.string("How this course words it, close to its text. Only with source_chunk_ids", max: 400),
                        "source_chunk_ids": Schema.intArray("Chunks the course wording comes from"),
                     ], required: ["term", "definition"]), "2-8 words to know", max: 8, min: 1),
                    "diagrams": Schema.array(Schema.object([
                        "title": Schema.string("What the picture shows", max: 120),
                        "draw": Schema.string("How to draw it by hand, in one or two sentences", max: 400),
                        "labels": Schema.array(["type": "string", "maxLength": 60], "What to label", max: 12),
                        "diagram": Diagram.jsonSchema,
                        "svg": Schema.string("Only when diagram can't show it (a labelled structure): plain SVG with a viewBox (lines, paths, shapes, short text), no colours, images or scripts", max: 20_000),
                     ], required: ["title", "draw"]), "0-3 pictures", max: 3),
                    "formulas": Schema.array(Schema.object(["latex": Schema.string("LaTeX, without $", max: 300),
                                                            "meaning": Schema.string("What it says and what each symbol is", max: 300)],
                                                           required: ["latex", "meaning"]), "0-6 formulas", max: 6),
                    "links": Schema.array(["type": "string", "maxLength": 120], "Earlier topics it builds on, e.g. \"← 1.2 Demand curves\"", max: 6),
                ], required: ["topic_id", "terms"]), "One page per topic", max: 12, min: 1),
             ], required: ["course_id", "pages"]), write: true) { a, store in
            let cid = try courseId(a, store)
            var warnings: [String] = []
            let pages = try a.objects("pages", max: 12).map { p in
                StudyStore.NotebookInput(
                    topicId: try p.int("topic_id"),
                    terms: try p.objects("terms", max: 8).map { t in
                        NotebookTerm(term: try t.string("term", max: 80), definition: try t.optString("definition", max: 400) ?? "",
                                     courseWording: try t.optString("course_wording", max: 400), sourceChunkIds: try t.intArray("source_chunk_ids", max: 12))
                    },
                    diagrams: try p.objects("diagrams", max: 3, required: false).map { d in
                        let (diagram, w) = Diagram.parse(d.raw["diagram"])
                        warnings += w
                        return NotebookDiagram(title: try d.optString("title", max: 120) ?? "", draw: try d.optString("draw", max: 400) ?? "",
                                               labels: try d.stringArray("labels", max: 12, itemMax: 60), diagram: diagram,
                                               svg: try d.optString("svg", max: 20_000))
                    },
                    formulas: try p.objects("formulas", max: 6, required: false).map { f in
                        NotebookFormula(latex: try f.string("latex", max: 300), meaning: try f.optString("meaning", max: 300) ?? "")
                    },
                    links: try p.stringArray("links", max: 6, itemMax: 120))
            }
            let who = authorship(a, store)
            do {
                var r = try store.saveNotebook(courseId: cid, pages, tier: who.tier, generatedBy: who.by)
                r.warnings += warnings
                return writeJSON(r)
            }
            catch let e as StoreError { throw toolError(e) }
        },
        Tool(name: "save_lessons", title: "Save lessons",
             description: """
             Save lessons for up to 5 topics. Sections, in order: idea (required; general knowledge, explained the way the \
             best university teacher would), example (worked step by step), course_angle (how THIS course frames it; must \
             cite source_chunk_ids, or leave it out), mistakes, summary. Maths in $...$.
             """,
             schema: Schema.object([
                "course_id": Schema.int("Course id"),
                "lessons": Schema.array(Schema.object([
                    "topic_id": Schema.int("Topic id from get_path"),
                    "pre_question": Schema.string("A question to think about before reading", max: 300),
                    "sections": Schema.array(Schema.object([
                        "kind": Schema.enumString(LessonSection.kinds, "Section kind"),
                        "title": Schema.string("Section title", max: 120),
                        "body_md": Schema.string("Markdown", max: 8_000),
                        "source_chunk_ids": Schema.intArray("For course_angle: the chunks it's based on"),
                    ], required: ["kind", "title", "body_md"]), "2-8 sections", max: 8, min: 1),
                    "checks": Schema.array(Schema.object(["prompt": Schema.string("A quick question", max: 300), "answer": Schema.string("Its short answer", max: 600)],
                                                         required: ["prompt", "answer"]), "2-3 quick checks", max: 5),
                    "cards": Schema.array(Schema.object(["front": Schema.string("Question side", max: 200), "back": Schema.string("Answer side", max: 300)],
                                                        required: ["front", "back"]), "3-6 flashcards for definitions, formulas and key facts", max: 8),
                    "explain_prompt": Schema.string("What to explain back in 2-3 sentences", max: 300),
                    "est_minutes": Schema.int("Minutes to read and work through it", min: 5, max: 120),
                ], required: ["topic_id", "sections"]), "Lessons", max: 5, min: 1),
             ], required: ["course_id", "lessons"]), write: true) { a, store in
            let cid = try courseId(a, store)
            let lessons = try a.objects("lessons", max: 5).map { l in
                StudyStore.LessonInput(
                    topicId: try l.int("topic_id"), preQuestion: try l.optString("pre_question", max: 300),
                    sections: try l.objects("sections", max: 8).map { s in
                        LessonSection(kind: try s.string("kind", max: 20), title: try s.optString("title", max: 120) ?? "",
                                      bodyMd: try s.string("body_md", max: 8_000), sourceChunkIds: try s.intArray("source_chunk_ids", max: 12))
                    },
                    checks: try l.objects("checks", max: 5, required: false).map { CheckQuestion(prompt: try $0.string("prompt", max: 300), answer: try $0.string("answer", max: 600)) },
                    cards: try l.objects("cards", max: 8, required: false).map { LessonCard(front: try $0.string("front", max: 200), back: try $0.string("back", max: 300)) },
                    explainPrompt: try l.optString("explain_prompt", max: 300), estMinutes: try l.optInt("est_minutes"))
            }
            let who = authorship(a, store)
            do { return writeJSON(try store.saveLessons(courseId: cid, lessons, tier: who.tier, generatedBy: who.by)) }
            catch let e as StoreError { throw toolError(e) }
        },
    ]
}
