import Foundation

/// A course's path: the best way to learn the subject at university level, laid out as units of numbered topics. It
/// comes from the course builder (Claude, or free AI for a basic version), or, with no AI at all, from the course's
/// own lectures (a skeleton).
public struct CoursePath: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    /// `skeleton` (no AI: one topic per lecture), `basic` (free AI) or `full` (the course builder).
    public var tier: String
    /// Which engine built it, for the header ("Built with Claude Code").
    public var builtWith: String?
    /// How to learn this subject: the strategy behind the order.
    public var approachMd: String?
    /// What this course emphasises and how it grades: its angles.
    public var anglesMd: String?
    public var resources: [String]
    public var version: Int
    public var signalsHash: String?
    /// New course files arrived since the path was built.
    public var stale: Bool
    public var updatedAt: Date

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); tier = r.string("tier") ?? "skeleton"; builtWith = r.string("built_with")
        approachMd = r.string("approach_md"); anglesMd = r.string("angles_md"); resources = JSON.stringArray(r.string("resources_json"))
        version = r.int("version") ?? 1; signalsHash = r.string("signals_hash"); stale = r.bool("stale")
        updatedAt = ISO.parse(r.str("updated_at")) ?? Date()
    }

    public var tierLabel: String {
        switch tier {
        case "full": return "Built by the course builder"
        case "basic": return "Basic version, built with free AI"
        default: return "Outline from your lectures"
        }
    }
}

public struct PathUnit: Identifiable, Hashable {
    public var id: Int
    public var pathId: Int
    public var ordinal: Int
    public var title: String
    public var summary: String?
    init(row r: Row) {
        id = r.i("id"); pathId = r.i("path_id"); ordinal = r.i("ordinal"); title = r.str("title"); summary = r.string("summary")
    }
}

/// How well a topic is known, from the student's own ratings only.
public enum Mastery: String, CaseIterable, Codable, Sendable {
    /// Not started.
    case new
    /// Its notebook page is written: the words and pictures are familiar.
    case familiar
    /// The lesson is done, or practice has started.
    case learning
    /// Practised with success.
    case practiced
    /// Practised on different days and explained well; its cards are holding.
    case solid
    /// Was practised or solid, but it's fading: time for a refresh.
    case refresh

    public var label: String {
        switch self {
        case .new: return "Not started"
        case .familiar: return "In your notebook"
        case .learning: return "Learning"
        case .practiced: return "Practised"
        case .solid: return "Solid"
        case .refresh: return "Needs a refresh"
        }
    }

    /// Done enough that the path moves on (prerequisites count as met).
    public var isUnderstood: Bool { self == .practiced || self == .solid || self == .refresh }
}

public struct PathTopic: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var unitId: Int?
    public var ordinal: Int
    /// A stable key from the title, so a rebuilt path keeps the same topics.
    public var key: String
    public var title: String
    public var summary: String?
    public var objectives: [String]
    public var prereqIds: [Int]
    public var estMinutes: Int
    /// 0 light, 1 normal, 2 stressed in class, 3 exam-critical.
    public var emphasis: Int
    /// Good to know but not something this course examines.
    public var beyondCourse: Bool
    /// No longer part of the path (kept, never deleted).
    public var retired: Bool
    /// `known` (the student already knows it) or `hidden`.
    public var userState: String?
    public var mastery: Mastery
    public var masteryAt: Date?
    public var lastStudiedAt: Date?
    public var notebookWrittenAt: Date?
    /// The page in the student's notebook ("14" or "14–15").
    public var notebookPage: String?
    public var createdBy: String

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); unitId = r.int("unit_id"); ordinal = r.i("ordinal"); key = r.str("key")
        title = r.str("title"); summary = r.string("summary"); objectives = JSON.stringArray(r.string("objectives_json"))
        prereqIds = JSON.intArray(r.string("prereq_ids_json")); estMinutes = r.int("est_minutes") ?? 25; emphasis = r.int("emphasis") ?? 1
        beyondCourse = r.bool("beyond_course"); retired = r.bool("retired"); userState = r.string("user_state")
        mastery = Mastery(rawValue: r.str("mastery")) ?? .new; masteryAt = r.string("mastery_at").flatMap { ISO.parse($0) }
        lastStudiedAt = r.string("last_studied_at").flatMap { ISO.parse($0) }
        notebookWrittenAt = r.string("notebook_written_at").flatMap { ISO.parse($0) }; notebookPage = r.string("notebook_page")
        createdBy = r.str("created_by")
    }

    public var isSkipped: Bool { userState == "known" || userState == "hidden" }
    public var inNotebook: Bool { notebookWrittenAt != nil }
}

// MARK: Notebook guide

/// A word to write in the notebook, with what it means. `courseWording` is how the course itself defines it, when its
/// files do (with the slides it comes from).
public struct NotebookTerm: Codable, Hashable, Sendable {
    public var term: String
    public var definition: String
    public var courseWording: String?
    public var sourceChunkIds: [Int]
    public var locator: String?
    public init(term: String, definition: String, courseWording: String? = nil, sourceChunkIds: [Int] = [], locator: String? = nil) {
        self.term = term; self.definition = definition; self.courseWording = courseWording; self.sourceChunkIds = sourceChunkIds; self.locator = locator
    }
    enum CodingKeys: String, CodingKey { case term, definition, courseWording = "course_wording", sourceChunkIds = "source_chunk_ids", locator }
}

/// A picture to draw: what to draw and label, and a reference drawing to check against. Graphs and processes come as
/// data the app draws (`diagram`); anything else (a labelled structure, a cycle of parts) as a simple SVG.
public struct NotebookDiagram: Codable, Hashable, Sendable {
    public var title: String
    public var draw: String
    public var labels: [String]
    /// A graph or a flow, drawn by the app in the theme's colours.
    public var diagram: Diagram?
    /// Sanitised SVG, drawn in the theme's text colour. Only when `diagram` can't show the picture.
    public var svg: String?
    public init(title: String, draw: String, labels: [String] = [], diagram: Diagram? = nil, svg: String? = nil) {
        self.title = title; self.draw = draw; self.labels = labels; self.diagram = diagram; self.svg = svg
    }

    /// Whether there's a reference drawing to show.
    public var hasDrawing: Bool { diagram != nil || svg != nil }
}

public struct NotebookFormula: Codable, Hashable, Sendable {
    /// LaTeX, without the surrounding dollars.
    public var latex: String
    public var meaning: String
    public init(latex: String, meaning: String) { self.latex = latex; self.meaning = meaning }
}

/// One topic's page in the handwritten notebook: the words, the pictures and the formulas, written early (reading
/// notes) so the whole course is familiar before the deep learning starts. Used again for exam prep.
public struct TopicNotebook: Hashable {
    public var topicId: Int
    public var terms: [NotebookTerm]
    public var diagrams: [NotebookDiagram]
    public var formulas: [NotebookFormula]
    /// Topics this one builds on ("← 2.1 Second law").
    public var links: [String]
    public var tier: String
    public var generatedBy: String
    public var stale: Bool
    public var version: Int

    init(row r: Row) {
        topicId = r.i("topic_id")
        terms = JSON.decode([NotebookTerm].self, r.string("terms_json")) ?? []
        diagrams = JSON.decode([NotebookDiagram].self, r.string("diagrams_json")) ?? []
        formulas = JSON.decode([NotebookFormula].self, r.string("formulas_json")) ?? []
        links = JSON.stringArray(r.string("links_json")); tier = r.string("tier") ?? "basic"; generatedBy = r.str("generated_by")
        stale = r.bool("stale"); version = r.int("version") ?? 1
    }

    /// Minutes to write the page by hand: about a minute per word, three per picture, half a minute per formula.
    public var writingMinutes: Int { max(3, terms.count + diagrams.count * 3 + (formulas.count + 1) / 2) }
}

// MARK: Lessons

public struct LessonSection: Codable, Hashable, Sendable {
    /// idea, example, course_angle, mistakes or summary.
    public var kind: String
    public var title: String
    public var bodyMd: String
    /// Course chunks behind a course-angle section; general sections have none.
    public var sourceChunkIds: [Int]
    public init(kind: String, title: String, bodyMd: String, sourceChunkIds: [Int] = []) {
        self.kind = kind; self.title = title; self.bodyMd = bodyMd; self.sourceChunkIds = sourceChunkIds
    }
    enum CodingKeys: String, CodingKey { case kind, title, bodyMd = "body_md", sourceChunkIds = "source_chunk_ids" }

    public static let kinds = ["idea", "example", "course_angle", "mistakes", "summary"]
}

public struct CheckQuestion: Codable, Hashable, Sendable {
    public var prompt: String
    public var answer: String
    public init(prompt: String, answer: String) { self.prompt = prompt; self.answer = answer }
}

public struct LessonCard: Codable, Hashable, Sendable {
    public var front: String
    public var back: String
    public init(front: String, back: String) { self.front = front; self.back = back }
}

/// A topic's lesson: a question to think about before reading, the idea, worked examples, the course's angle, common
/// mistakes, quick checks, the cards to keep and what to explain back.
public struct TopicLesson: Hashable {
    public var topicId: Int
    public var tier: String
    public var preQuestion: String?
    public var sections: [LessonSection]
    public var checks: [CheckQuestion]
    public var cards: [LessonCard]
    public var explainPrompt: String?
    public var estMinutes: Int?
    public var generatedBy: String
    public var stale: Bool
    public var version: Int

    init(row r: Row) {
        topicId = r.i("topic_id"); tier = r.string("tier") ?? "basic"; preQuestion = r.string("pre_question")
        sections = JSON.decode([LessonSection].self, r.string("sections_json")) ?? []
        checks = JSON.decode([CheckQuestion].self, r.string("checks_json")) ?? []
        cards = JSON.decode([LessonCard].self, r.string("cards_json")) ?? []
        explainPrompt = r.string("explain_prompt"); estMinutes = r.int("est_minutes"); generatedBy = r.str("generated_by")
        stale = r.bool("stale"); version = r.int("version") ?? 1
    }
}

/// Which course files teach a topic, and where.
public struct TopicCoverage: Hashable {
    public var topicId: Int
    public var materialId: Int
    public var chunkIds: [Int]
    public var emphasis: Int
    public var source: String
    init(row r: Row) {
        topicId = r.i("topic_id"); materialId = r.i("material_id"); chunkIds = JSON.intArray(r.string("chunk_ids_json"))
        emphasis = r.int("emphasis") ?? 1; source = r.str("source")
    }
}
