import Foundation
import StudyCore

enum ToolOutput {
    case json(Any)
    case content([[String: Any]])
}

struct Tool {
    let name: String
    let title: String
    let description: String
    let schema: [String: Any]
    let write: Bool
    let handler: (Args, StudyStore) throws -> ToolOutput

    var definition: [String: Any] {
        [
            "name": name, "title": title, "description": description, "inputSchema": schema,
            "annotations": ["title": title, "readOnlyHint": !write, "destructiveHint": false, "idempotentHint": !write, "openWorldHint": false],
        ]
    }
}

enum ToolCatalog {
    // MARK: Helpers

    static func tzString(_ d: Date?, _ store: StudyStore) -> Any { d.map { ISO.instant($0, in: store.timezone) } ?? NSNull() }

    static func assignmentJSON(_ a: Assignment, _ store: StudyStore, courses: [Int: Course]) -> [String: Any] {
        var d: [String: Any] = [
            "id": a.id, "title": a.title, "kind": a.kind.rawValue, "status": a.status.rawValue, "due_at": tzString(a.dueAt, store),
            "confirmed": a.confirmed, "source": a.source,
        ]
        if let c = a.courseId { d["course_id"] = c; d["course"] = courses[c]?.displayName ?? "" }
        if let v = a.weightPct { d["weight_pct"] = v }
        if let v = a.estHours { d["est_hours"] = v }
        if let v = a.score { d["score"] = v }
        if let v = a.maxScore { d["max_score"] = v }
        if let v = a.minPassPct { d["min_pass_pct"] = v }
        if let v = a.groupMembers { d["group_members"] = v }
        if let v = a.rubricMaterialId { d["rubric_material_id"] = v }
        if let v = a.sourceLocator { d["source_locator"] = v }
        if let v = a.description { d["description"] = String(v.prefix(600)) }
        return d
    }

    static func writeJSON(_ r: WriteResult) -> ToolOutput { .json(r.json) }

    // MARK: Catalog

    static func all() -> [Tool] { readTools + writeTools }

    static let readTools: [Tool] = [
        Tool(name: "get_overview", title: "Overview",
             description: "What's next and what's due: current time and zone, next class, today's schedule, work due in 7 days, cards due, unprocessed lectures, pending proposals and the app's one suggested action. Start here.",
             schema: Schema.object([:]), write: false) { _, store in
            let snap = store.todaySnapshot()
            let courses = store.courseMap()
            return .json([
                "now": ISO.instant(snap.now, in: store.timezone), "timezone": store.timezone.identifier,
                "next_class": snap.nextClass.map { $0.asJSON(tz: store.timezone, courses: courses) } as Any,
                "today": snap.today.map { $0.asJSON(tz: store.timezone, courses: courses) },
                "due_next_7_days": snap.dueSoon.map { a -> [String: Any] in
                    ["id": a.id, "title": a.title, "course": a.courseId.flatMap { courses[$0]?.displayName } ?? "", "due_at": tzString(a.dueAt, store),
                     "kind": a.kind.rawValue, "status": a.status.rawValue, "weight_pct": a.weightPct as Any, "overdue": a.isOverdue(now: snap.now)]
                },
                "cards_due": snap.cardsDue,
                "unprocessed_materials": snap.unprocessed.map { ["id": $0.id, "title": $0.title, "course": $0.courseId.flatMap { courses[$0]?.displayName } ?? ""] },
                "proposed_pending": snap.proposedPending,
                "suggested_action": snap.suggested.title,
            ])
        },
        Tool(name: "list_courses", title: "List courses",
             description: "Courses with code, name, short name, instructor, term, grading scale, target grade and pass mark.",
             schema: Schema.object(["include_archived": Schema.bool("Include archived courses (default false)")]), write: false) { a, store in
            let terms = Dictionary(uniqueKeysWithValues: store.terms().map { ($0.id, $0.name) })
            return .json(store.courses(includeArchived: try a.bool("include_archived", default: false)).map { c in
                ["id": c.id, "code": c.code as Any, "name": c.name, "short_name": c.shortName as Any, "instructor": c.instructor as Any, "term": terms[c.termId] ?? "",
                 "kind": c.kind, "grade_scale": c.gradeScale.rawValue, "target_grade": c.targetGrade as Any, "pass_mark": c.passMark as Any,
                 "archived": c.archived]
            })
        },
        Tool(name: "get_schedule", title: "Schedule",
             description: "Classes, events and busy time (for example work shifts) between two dates (inclusive, at most 62 days). Canceled classes are included only when asked.",
             schema: Schema.object(["from": Schema.string("Start date YYYY-MM-DD"), "to": Schema.string("End date YYYY-MM-DD"),
                                    "course_id": Schema.int("Only this course"), "include_canceled": Schema.bool("Include canceled classes")],
                                   required: ["from", "to"]), write: false) { a, store in
            guard let from = try a.date("from"), let to = try a.date("to") else { throw ToolError.invalid("from and to are required.") }
            guard from <= to, from.days(to: to) <= 62 else { throw ToolError.invalid("The range must be 0-62 days.", hint: "Ask for a shorter window.") }
            let cid = try a.optInt("course_id")
            let includeCanceled = try a.bool("include_canceled", default: false)
            let courses = store.courseMap()
            let occ = store.occurrences(from: from, to: to).filter { o in
                (includeCanceled || o.status != .canceled) && (cid == nil || o.courseId == cid)
            }
            return .json(occ.map { $0.asJSON(tz: store.timezone, courses: courses) })
        },
        Tool(name: "list_assignments", title: "List assignments",
             description: "Assignments, quizzes and exams with due dates, status, weight and grades. Proposed (unconfirmed) items are excluded unless include_proposed is true.",
             schema: Schema.object([
                "course_id": Schema.int("Only this course"),
                "status": Schema.array(Schema.enumString(AssignmentStatus.allCases.map(\.rawValue), "status"), "Filter by status"),
                "kind": Schema.array(Schema.enumString(AssignmentKind.allCases.map(\.rawValue), "kind"), "Filter by kind"),
                "due_from": Schema.string("ISO date or date-time"), "due_to": Schema.string("ISO date or date-time"),
                "include_proposed": Schema.bool("Include proposals awaiting the student's confirmation (default false)"),
             ]), write: false) { a, store in
            var f = AssignmentFilter()
            f.courseId = try a.optInt("course_id")
            f.statuses = try a.stringArray("status").map { s in
                guard let v = AssignmentStatus(rawValue: s) else { throw ToolError.invalid("Unknown status \(s).") }
                return v
            }
            f.kinds = try a.stringArray("kind").map { s in
                guard let v = AssignmentKind(rawValue: s) else { throw ToolError.invalid("Unknown kind \(s).") }
                return v
            }
            f.dueFrom = try a.optString("due_from", max: 40).flatMap { ISO.parse($0, tz: store.timezone) }
            f.dueTo = try a.optString("due_to", max: 40).map { s -> Date in
                if let d = LocalDate(s), s.count <= 10 { return d.at(LocalTime(hour: 23, minute: 59), tz: store.timezone) }
                return ISO.parse(s, tz: store.timezone) ?? Date.distantFuture
            }
            f.includeProposed = try a.bool("include_proposed", default: false)
            let courses = store.courseMap()
            return .json(store.assignments(f).map { assignmentJSON($0, store, courses: courses) })
        },
        Tool(name: "get_grade_summary", title: "Grade summary",
             description: "Grade math for one course: points earned, current average, what is needed on the remaining work to reach the target, component minimums and warnings.",
             schema: Schema.object(["course_id": Schema.int("Course id")], required: ["course_id"]), write: false) { a, store in
            do { return .json(try store.gradeSummary(courseId: try a.int("course_id")).asJSON()) }
            catch GradeError.zeroMaxScore(let id) { throw ToolError.invalid("Assignment \(id) has a max score of 0; ask the student to fix it.") }
        },
        Tool(name: "list_materials", title: "List materials",
             description: "Course materials (lectures, readings, syllabi, rubrics, briefs, past exams) with status, chunk and concept counts, and whether they have been processed.",
             schema: Schema.object([
                "course_id": Schema.int("Only this course"), "processed": Schema.bool("true: processed only; false: unprocessed only"),
                "status": Schema.enumString(["inbox", "ready", "needs_ocr", "failed"], "Filter by status"),
                "role": Schema.enumString(MaterialRole.allCases.map(\.rawValue), "Filter by role"),
             ]), write: false) { a, store in
            let status = try a.oneOf("status", ["inbox", "ready", "needs_ocr", "failed"])
            let role = try a.oneOf("role", MaterialRole.allCases.map(\.rawValue)).flatMap(MaterialRole.init)
            let processed: Bool? = a.has("processed") ? try a.bool("processed", default: false) : nil
            let list = store.materials(courseId: try a.optInt("course_id"), statuses: status.map { [$0] }, processed: processed, role: role)
            return .json(list.map { m -> [String: Any] in
                let chunks = store.chunks(materialId: m.id)
                return ["id": m.id, "course_id": m.courseId as Any, "title": m.title, "kind": m.kind, "role": m.role.rawValue, "status": m.status,
                        "page_count": m.pageCount as Any, "chunk_count": chunks.count, "processed_at": tzString(m.processedAt, store),
                        "concept_count": store.concepts(materialId: m.id).count, "chunks_with_images": chunks.filter { !$0.images.isEmpty }.count]
            })
        },
        Tool(name: "get_material", title: "Material index",
             description: "One material's metadata and chunk index (ids, locators, headings, token estimates, image counts). Use the chunk ids when citing sources.",
             schema: Schema.object(["material_id": Schema.int("Material id")], required: ["material_id"]), write: false) { a, store in
            let id = try a.int("material_id")
            guard let m = store.material(id) else { throw ToolError.notFound("Material \(id) does not exist.", hint: "Call list_materials.") }
            let chunks = store.chunks(materialId: id)
            return .json([
                "id": m.id, "course_id": m.courseId as Any, "title": m.title, "kind": m.kind, "role": m.role.rawValue, "status": m.status,
                "status_detail": m.statusDetail as Any, "processed_at": tzString(m.processedAt, store),
                "total_tokens": chunks.reduce(0) { $0 + $1.tokenEstimate },
                "chunk_index": chunks.map { ["id": $0.id, "ordinal": $0.ordinal, "locator": $0.locator, "heading": $0.heading as Any,
                                             "token_estimate": $0.tokenEstimate, "image_count": $0.imageCount, "has_images": !$0.images.isEmpty] },
            ])
        },
        Tool(name: "get_chunks", title: "Read chunks",
             description: "Source text of a material, one chunk per slide, page or section, with speaker notes, tables, chart data and text found in pictures. Pages by token budget: follow next_ordinal until truncated is false.",
             schema: Schema.object([
                "material_id": Schema.int("Material id"), "from_ordinal": Schema.int("First ordinal (default 1)"),
                "to_ordinal": Schema.int("Last ordinal"), "max_tokens": Schema.int("Budget, default 12000, max 30000", min: 500, max: 30000),
             ], required: ["material_id"]), write: false) { a, store in
            let id = try a.int("material_id")
            guard store.material(id) != nil else { throw ToolError.notFound("Material \(id) does not exist.") }
            let budget = min(max(try a.optInt("max_tokens") ?? 12000, 500), 30000)
            let all = store.chunks(materialId: id, fromOrdinal: try a.optInt("from_ordinal"), toOrdinal: try a.optInt("to_ordinal"))
            var out: [[String: Any]] = []
            var used = 0
            var next: Int?
            for c in all {
                if !out.isEmpty && used + c.tokenEstimate > budget { next = c.ordinal; break }
                used += c.tokenEstimate
                var d: [String: Any] = ["id": c.id, "ordinal": c.ordinal, "locator": c.locator, "heading": c.heading as Any, "text_md": c.textMd,
                                        "image_count": c.imageCount, "has_images": !c.images.isEmpty]
                if let n = c.notesMd { d["notes_md"] = n }
                if let e = c.extraMd { d["extra_md"] = e }
                if c.ocr { d["text_recognized_from_image"] = true }
                out.append(d)
            }
            var result: [String: Any] = ["chunks": out, "truncated": next != nil]
            if let next { result["next_ordinal"] = next }
            return .json(result)
        },
        Tool(name: "get_slide_images", title: "Look at slides",
             description: "Pictures from slides or pages (charts, diagrams, photos, scanned pages) as images you can see. Up to 6 ordinals per call; use for chunks where has_images is true.",
             schema: Schema.object(["material_id": Schema.int("Material id"),
                                    "ordinals": Schema.array(["type": "integer"], "Chunk ordinals (e.g. slide numbers)", max: 6, min: 1)],
                                   required: ["material_id", "ordinals"]), write: false) { a, store in
            let id = try a.int("material_id")
            guard let m = store.material(id) else { throw ToolError.notFound("Material \(id) does not exist.") }
            let ordinals = try a.intArray("ordinals", max: 6)
            guard !ordinals.isEmpty else { throw ToolError.invalid("ordinals must list 1-6 chunk ordinals.") }
            var content: [[String: Any]] = []
            var described: [String] = []
            var budget = 8
            for o in ordinals {
                guard let c = store.chunks(materialId: id, fromOrdinal: o, toOrdinal: o).first else {
                    throw ToolError.reference("Material \(id) has no chunk with ordinal \(o).", hint: "Call get_material for valid ordinals.")
                }
                let urls = store.imageURLs(for: c, material: m)
                if urls.isEmpty { described.append("\(c.locator): no pictures stored"); continue }
                for u in urls where budget > 0 {
                    guard let img = Imaging.loadImage(u, maxPixel: 1280), let jpeg = Imaging.jpegData(img, quality: 0.72) else { continue }
                    content.append(["type": "text", "text": "\(c.locator) (chunk \(c.id))"])
                    content.append(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
                    budget -= 1
                }
                described.append("\(c.locator): \(urls.count) picture\(urls.count == 1 ? "" : "s")")
            }
            content.insert(["type": "text", "text": "Pictures for material \(id): " + described.joined(separator: "; ")], at: 0)
            return .content(content)
        },
        Tool(name: "get_concepts", title: "Concepts",
             description: "Concepts for a course or one material, with definitions, importance, source locators and links. Concepts are shared across a course's lectures.",
             schema: Schema.object(["course_id": Schema.int("Course id"), "material_id": Schema.int("Material id")]), write: false) { a, store in
            let cid = try a.optInt("course_id"), mid = try a.optInt("material_id")
            guard cid != nil || mid != nil else { throw ToolError.invalid("Provide course_id or material_id.") }
            let list = store.concepts(courseId: cid, materialId: mid)
            let courseIds = Set(list.map(\.courseId))
            var names: [Int: String] = [:]
            var links: [(Int, Int, String)] = []
            for c in courseIds {
                for k in store.concepts(courseId: c) { names[k.id] = k.name }
                links += store.conceptLinks(courseId: c).map { ($0.from, $0.to, $0.relation) }
            }
            return .json(list.map { k -> [String: Any] in
                let src = store.conceptSources(k.id)
                return ["id": k.id, "course_id": k.courseId, "name": k.name, "definition": k.definition, "importance": k.importance,
                        "created_by": k.createdBy,
                        "source_locators": src.map { mid == nil ? "\($0.materialTitle): \($0.locator)" : $0.locator },
                        "source_chunk_ids": src.map(\.chunkId),
                        "links": links.filter { $0.0 == k.id }.compactMap { l in names[l.1].map { ["to": $0, "relation": l.2] } }]
            })
        },
        Tool(name: "get_questions", title: "Questions",
             description: "Practice questions with answer keys, source locators and difficulty. card_id is set when the question has a flashcard.",
             schema: Schema.object(["material_id": Schema.int("Material id"), "concept_id": Schema.int("Concept id"), "course_id": Schema.int("Course id"),
                                    "kind": Schema.enumString(["recall", "explain", "apply", "compare", "calculate"], "Kind")]), write: false) { a, store in
            let qs = store.questions(materialId: try a.optInt("material_id"), conceptId: try a.optInt("concept_id"),
                                     courseId: try a.optInt("course_id"), kind: try a.oneOf("kind", ["recall", "explain", "apply", "compare", "calculate"]))
            let conceptNames = Dictionary(uniqueKeysWithValues: store.concepts().map { ($0.id, $0.name) })
            let cardsByQ = Dictionary(store.cards(status: "active").compactMap { c in c.questionId.map { ($0, c.id) } }, uniquingKeysWith: { a, _ in a })
            return .json(qs.map { q -> [String: Any] in
                ["id": q.id, "material_id": q.materialId, "kind": q.kind, "prompt": q.prompt, "answer_key": q.answerKey,
                 "concept": q.conceptId.flatMap { conceptNames[$0] } as Any, "source_locators": store.chunks(ids: q.sourceChunkIds).map(\.locator),
                 "difficulty": q.difficulty, "card_id": cardsByQ[q.id] as Any]
            })
        },
        Tool(name: "get_review_queue", title: "Review queue",
             description: "Flashcards due now, interleaved across lectures. Ratings for these cards must come from the student.",
             schema: Schema.object(["course_id": Schema.int("Course id"), "limit": Schema.int("Default 20, max 50", min: 1, max: 50)]), write: false) { a, store in
            let limit = min(max(try a.optInt("limit") ?? 20, 1), 50)
            let conceptNames = Dictionary(uniqueKeysWithValues: store.concepts().map { ($0.id, $0.name) })
            return .json(store.reviewQueue(courseId: try a.optInt("course_id"), limit: limit).map { c -> [String: Any] in
                ["card_id": c.id, "front": c.front, "back": c.back, "concept": c.conceptId.flatMap { conceptNames[$0] } as Any,
                 "state": CardState(rawValue: c.state)?.label ?? "New", "due": tzString(c.due, store), "source_locators": c.sourceLocators as Any]
            })
        },
        Tool(name: "get_notes", title: "Notes",
             description: "Cornell sheets, gap reports, summaries, rubric checks and the student's own notes.",
             schema: Schema.object(["course_id": Schema.int("Course id"), "material_id": Schema.int("Material id"),
                                    "kind": Schema.string("Note kind")]), write: false) { a, store in
            .json(store.notes(courseId: try a.optInt("course_id"), materialId: try a.optInt("material_id"), kind: try a.optString("kind", max: 40)).map {
                ["id": $0.id, "kind": $0.kind, "title": $0.title, "content_md": String($0.contentMd.prefix(20000)), "created_by": $0.createdBy,
                 "material_id": $0.materialId as Any, "updated_at": tzString($0.updatedAt, store)]
            })
        },
        Tool(name: "get_handwriting_captures", title: "Handwritten sheets",
             description: "Photos of the student's handwritten notes for a material: text recognized on their Mac and a quick local check of which concepts appear.",
             schema: Schema.object(["material_id": Schema.int("Material id")], required: ["material_id"]), write: false) { a, store in
            .json(store.handwritingCaptures(materialId: try a.int("material_id")).map {
                ["id": $0.id, "created_at": tzString($0.createdAt, store), "recognized_text": $0.ocrText, "local_check": JSON.parse($0.coverageJson) as Any]
            })
        },
        Tool(name: "get_outcomes", title: "Outcomes",
             description: "Whether studying is working: missed deadlines, on-time rate, 30-day card retention, recall within 48 hours of processing, study minutes per week, grades versus targets, and concepts flagged weak most often.",
             schema: Schema.object([:]), write: false) { _, store in
            .json(store.outcomes().asJSON())
        },
    ]

    static let writeTools: [Tool] = [
        Tool(name: "save_concepts", title: "Save concepts",
             description: """
             Save concepts for a material (max 30 per call). Concepts are shared across the course: reuse an existing name to add this lecture as a source. \
             Every concept needs source_chunk_ids from this material. Never overwrites concepts the student wrote.
             """,
             schema: Schema.object([
                "material_id": Schema.int("Material id"),
                "concepts": Schema.array(Schema.object([
                    "name": Schema.string("Concept name", max: 80),
                    "definition": Schema.string("One plain-language sentence", max: 400),
                    "importance": Schema.int("1 core, 2 supporting, 3 detail", min: 1, max: 3),
                    "source_chunk_ids": Schema.intArray("Chunk ids from this material", min: 1),
                    "links": Schema.array(Schema.object(["to_name": Schema.string("Other concept name"),
                                                         "relation": Schema.enumString(["part_of", "causes", "contrasts", "example_of", "prerequisite"], "Relation")],
                                                        required: ["to_name", "relation"]), "Links to other concepts in the course"),
                ], required: ["name", "definition", "importance", "source_chunk_ids"]), "Concepts", max: 30, min: 1),
             ], required: ["material_id", "concepts"]), write: true) { a, store in
            let items = try a.objects("concepts", max: 30).map { c in
                StudyStore.ConceptInput(name: try c.string("name", max: 80), definition: try c.string("definition", max: 400),
                                        importance: try c.int("importance"), sourceChunkIds: try c.intArray("source_chunk_ids"),
                                        links: try c.objects("links", max: 20, required: false).map { (try $0.string("to_name", max: 80), try $0.string("relation", max: 20)) })
            }
            return writeJSON(try store.saveConcepts(materialId: try a.int("material_id"), items))
        },
        Tool(name: "save_questions", title: "Save questions",
             description: "Save practice questions with answer keys for a material (max 40 per call). Each needs source_chunk_ids. Exact duplicate prompts are skipped. create_cards makes proposed flashcards the student approves.",
             schema: Schema.object([
                "material_id": Schema.int("Material id"),
                "questions": Schema.array(Schema.object([
                    "kind": Schema.enumString(["recall", "explain", "apply", "compare", "calculate"], "Question kind"),
                    "prompt": Schema.string("The question", max: 400), "answer_key": Schema.string("Model answer", max: 800),
                    "concept_name": Schema.string("Related concept", max: 80), "source_chunk_ids": Schema.intArray("Chunk ids", min: 1),
                    "difficulty": Schema.int("1-3", min: 1, max: 3),
                ], required: ["kind", "prompt", "answer_key", "source_chunk_ids"]), "Questions", max: 40, min: 1),
                "create_cards": Schema.bool("Also propose one flashcard per new question (default false)"),
             ], required: ["material_id", "questions"]), write: true) { a, store in
            let items = try a.objects("questions", max: 40).map { q in
                StudyStore.QuestionInput(kind: try q.string("kind", max: 20), prompt: try q.string("prompt", max: 400),
                                         answerKey: try q.string("answer_key", max: 800), conceptName: try q.optString("concept_name", max: 80),
                                         sourceChunkIds: try q.intArray("source_chunk_ids"), difficulty: try q.optInt("difficulty") ?? 2)
            }
            return writeJSON(try store.saveQuestions(materialId: try a.int("material_id"), items, createCards: try a.bool("create_cards", default: false)))
        },
        Tool(name: "propose_cards", title: "Propose flashcards",
             description: "Propose short flashcards (front ≤ 200, back ≤ 300 characters; one idea per card). They wait in the app until the student approves or rewrites them.",
             schema: Schema.object([
                "material_id": Schema.int("Material id"),
                "cards": Schema.array(Schema.object([
                    "front": Schema.string("Question side", max: 200), "back": Schema.string("Answer side", max: 300),
                    "concept_name": Schema.string("Related concept", max: 80), "source_chunk_ids": Schema.intArray("Chunk ids", min: 1),
                ], required: ["front", "back", "source_chunk_ids"]), "Cards", max: 40, min: 1),
             ], required: ["material_id", "cards"]), write: true) { a, store in
            let items = try a.objects("cards", max: 40).map { c in
                StudyStore.CardInput(front: try c.string("front", max: 200), back: try c.string("back", max: 300),
                                     conceptName: try c.optString("concept_name", max: 80), sourceChunkIds: try c.intArray("source_chunk_ids"))
            }
            return writeJSON(try store.proposeCards(materialId: try a.int("material_id"), items))
        },
        Tool(name: "save_cornell_sheet", title: "Save Cornell sheet",
             description: "Save a handwriting-ready Cornell sheet: 8-20 cues (questions or bare terms, NO answers), one summary prompt the student answers in their own words, and chunks with pictures they should look at themselves. Replaces an earlier Claude sheet with the same title.",
             schema: Schema.object([
                "material_id": Schema.int("Material id"), "title": Schema.string("Sheet title", max: 120),
                "cues": Schema.array(Schema.object([
                    "text": Schema.string("Cue (no answer)", max: 200), "kind": Schema.enumString(["question", "term"], "Cue kind"),
                    "source_chunk_ids": Schema.intArray("Chunk ids", min: 1),
                ], required: ["text", "kind", "source_chunk_ids"]), "8-20 cues", max: 20, min: 8),
                "summary_prompt": Schema.string("One line the student answers in their own words", max: 300),
                "look_yourself_chunk_ids": Schema.intArray("Chunks whose pictures the student should study"),
             ], required: ["material_id", "title", "cues", "summary_prompt"]), write: true) { a, store in
            let cues = try a.objects("cues", max: 20).map { c in
                StudyStore.CueInput(text: try c.string("text", max: 200), kind: try c.string("kind", max: 10), sourceChunkIds: try c.intArray("source_chunk_ids"))
            }
            return writeJSON(try store.saveCornellSheet(materialId: try a.int("material_id"), title: try a.string("title", max: 120), cues: cues,
                                                        summaryPrompt: try a.string("summary_prompt", max: 300),
                                                        lookYourselfChunkIds: try a.intArray("look_yourself_chunk_ids")))
        },
        Tool(name: "save_note", title: "Save note",
             description: "Save a gap report, summary, session log, handwriting review, rubric check, practice set or exam-pattern analysis. Upserts by title over Claude's own notes; never touches the student's notes.",
             schema: Schema.object([
                "material_id": Schema.int("Material id"), "course_id": Schema.int("Course id"), "assignment_id": Schema.int("Assignment id (for rubric checks)"),
                "kind": Schema.enumString(["gap_report", "summary", "session_log", "handwriting_review", "rubric_check", "practice_set", "exam_patterns"], "Kind"),
                "title": Schema.string("Title", max: 160), "content_md": Schema.string("Markdown", max: 20000),
             ], required: ["kind", "title", "content_md"]), write: true) { a, store in
            writeJSON(try store.saveNoteChecked(materialId: try a.optInt("material_id"), courseId: try a.optInt("course_id"),
                                                assignmentId: try a.optInt("assignment_id"), kind: try a.string("kind", max: 40),
                                                title: try a.string("title", max: 160), content: try a.string("content_md", max: 20000)))
        },
        Tool(name: "propose_assignments", title: "Propose assignments",
             description: "Propose graded items found in a syllabus or brief (max 30). They wait in the Inbox for the student to confirm. If a date, time or weight is unclear in the source, omit it. Do not guess.",
             schema: Schema.object([
                "items": Schema.array(Schema.object([
                    "course_id": Schema.int("Course id"), "title": Schema.string("Title", max: 200),
                    "kind": Schema.enumString(AssignmentKind.allCases.map(\.rawValue), "Kind"),
                    "due_at": Schema.string("ISO 8601 with offset, e.g. 2026-10-06T23:59:00+02:00"),
                    "weight_pct": Schema.number("Share of the final grade, 0-100"), "est_hours": Schema.number("Estimated hours"),
                    "min_pass_pct": Schema.number("Minimum percentage required on this component, if the syllabus says so"),
                    "group_members": Schema.string("Group members for group work", max: 300),
                    "description": Schema.string("Short description", max: 2000), "source_material_id": Schema.int("Where it was found"),
                    "source_locator": Schema.string("Locator, e.g. p. 4", max: 80),
                ], required: ["course_id", "title"]), "Items", max: 30, min: 1),
             ], required: ["items"]), write: true) { a, store in
            let items = try a.objects("items", max: 30).map { i in
                StudyStore.AssignmentProposal(courseId: try i.int("course_id"), title: try i.string("title", max: 200), kind: try i.optString("kind", max: 20),
                                              dueAt: try i.optString("due_at", max: 40), weightPct: try i.optDouble("weight_pct"),
                                              estHours: try i.optDouble("est_hours"), description: try i.optString("description", max: 2000),
                                              sourceMaterialId: try i.optInt("source_material_id"), sourceLocator: try i.optString("source_locator", max: 80),
                                              minPassPct: try i.optDouble("min_pass_pct"), groupMembers: try i.optString("group_members", max: 300))
            }
            return writeJSON(try store.proposeAssignments(items))
        },
        Tool(name: "propose_study_blocks", title: "Propose study blocks",
             description: "Propose study blocks (10-180 minutes). They appear as ghost blocks in the calendar until the student accepts. Returns warnings for overlaps with classes or busy time and blocks in the past.",
             schema: Schema.object([
                "blocks": Schema.array(Schema.object([
                    "course_id": Schema.int("Course id"), "assignment_id": Schema.int("Assignment id"),
                    "planned_start": Schema.string("ISO 8601 date-time"), "planned_minutes": Schema.int("10-180", min: 10, max: 180),
                    "focus": Schema.string("What to work on", max: 200),
                ], required: ["planned_start", "planned_minutes"]), "Blocks", max: 40, min: 1),
             ], required: ["blocks"]), write: true) { a, store in
            let items = try a.objects("blocks", max: 40).map { b in
                StudyStore.BlockProposal(courseId: try b.optInt("course_id"), assignmentId: try b.optInt("assignment_id"),
                                         plannedStart: try b.string("planned_start", max: 40), plannedMinutes: try b.int("planned_minutes"),
                                         focus: try b.optString("focus", max: 200))
            }
            return writeJSON(try store.proposeStudyBlocks(items))
        },
        Tool(name: "mark_material_processed", title: "Mark processed",
             description: "Mark a material as processed. Requires at least one saved concept for it.",
             schema: Schema.object(["material_id": Schema.int("Material id")], required: ["material_id"]), write: true) { a, store in
            let id = try a.int("material_id")
            try store.markMaterialProcessedChecked(id)
            return .json(["material_id": id, "processed": true])
        },
        Tool(name: "record_session", title: "Record session",
             description: "Record a study session with a specific summary (what was solid, what wasn't) and the concepts that were weak.",
             schema: Schema.object([
                "kind": Schema.enumString(["process", "recall", "feynman", "quiz", "review", "handwriting"], "Session kind"),
                "material_id": Schema.int("Material id"), "course_id": Schema.int("Course id"), "assignment_id": Schema.int("Assignment id"),
                "started_at": Schema.string("ISO 8601 date-time"), "summary": Schema.string("Specific summary", max: 1500),
                "weak_concept_names": Schema.array(["type": "string"], "Concepts that need work"),
                "items_total": Schema.int("Questions or concepts covered"), "items_correct": Schema.int("How many were right"),
             ], required: ["kind", "summary"]), write: true) { a, store in
            let r = try store.recordClaudeSession(kind: try a.string("kind", max: 20), courseId: try a.optInt("course_id"),
                                                  materialId: try a.optInt("material_id"), assignmentId: try a.optInt("assignment_id"),
                                                  startedAt: try a.optString("started_at", max: 40).flatMap { ISO.parse($0, tz: store.timezone) },
                                                  summary: try a.string("summary", max: 1500), weakConceptNames: try a.stringArray("weak_concept_names", max: 40, itemMax: 80),
                                                  itemsTotal: try a.optInt("items_total"), itemsCorrect: try a.optInt("items_correct"))
            var out: [String: Any] = ["id": r.id]
            if !r.unmatched.isEmpty { out["unmatched_concepts"] = r.unmatched }
            return .json(out)
        },
        Tool(name: "log_review", title: "Log card review",
             description: "Apply the student's OWN self-rating to a flashcard (1 Again, 2 Hard, 3 Good, 4 Easy). Never choose or infer the rating yourself: ask the student and pass their answer.",
             schema: Schema.object(["card_id": Schema.int("Card id"), "rating": Schema.int("The student's rating 1-4", min: 1, max: 4)],
                                   required: ["card_id", "rating"]), write: true) { a, store in
            guard let rating = Rating(rawValue: try a.int("rating")) else { throw ToolError.invalid("rating must be 1, 2, 3 or 4.") }
            let r = try store.logReview(cardId: try a.int("card_id"), rating: rating)
            return .json(["card_id": try a.int("card_id"), "next_due": ISO.instant(r.due, in: store.timezone), "interval": FSRS.formatInterval(r.interval)])
        },
    ]
}
