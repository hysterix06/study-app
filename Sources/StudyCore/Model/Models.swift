import Foundation

public struct Term: Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var isCurrent: Bool
    public init(id: Int = 0, name: String, startDate: LocalDate, endDate: LocalDate, isCurrent: Bool) {
        self.id = id; self.name = name; self.startDate = startDate; self.endDate = endDate; self.isCurrent = isCurrent
    }
    init(row r: Row) {
        id = r.i("id"); name = r.str("name")
        startDate = LocalDate(r.str("start_date")) ?? LocalDate(year: 2026, month: 1, day: 1)
        endDate = LocalDate(r.str("end_date")) ?? LocalDate(year: 2026, month: 12, day: 31)
        isCurrent = r.bool("is_current")
    }
}

public struct TermBreak: Identifiable, Hashable {
    public var id: Int
    public var termId: Int
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var label: String?
    public init(id: Int = 0, termId: Int, startDate: LocalDate, endDate: LocalDate, label: String?) {
        self.id = id; self.termId = termId; self.startDate = startDate; self.endDate = endDate; self.label = label
    }
    init(row r: Row) {
        id = r.i("id"); termId = r.i("term_id")
        startDate = LocalDate(r.str("start_date"))!; endDate = LocalDate(r.str("end_date"))!
        label = r.string("label")
    }
    public func contains(_ d: LocalDate) -> Bool { d >= startDate && d <= endDate }
}

public enum GradeScale: String, CaseIterable, Identifiable {
    case percent, ten, twenty, swiss
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .percent: return "Percent (0–100)"
        case .ten: return "0–10"
        case .twenty: return "0–20"
        case .swiss: return "Swiss (1–6)"
        }
    }
    public var range: ClosedRange<Double> {
        switch self { case .percent: return 0...100; case .ten: return 0...10; case .twenty: return 0...20; case .swiss: return 1...6 }
    }
    /// Converts a percentage (0–100) to this scale.
    public func fromPercent(_ p: Double) -> Double {
        switch self {
        case .percent: return p
        case .ten: return p / 10
        case .twenty: return p / 5
        case .swiss: return 1 + 5 * p / 100
        }
    }
    public func toPercent(_ v: Double) -> Double {
        switch self {
        case .percent: return v
        case .ten: return v * 10
        case .twenty: return v * 5
        case .swiss: return (v - 1) / 5 * 100
        }
    }
    public func format(_ v: Double) -> String {
        switch self {
        case .percent: return String(format: "%.1f%%", v)
        case .ten, .twenty: return String(format: "%.1f", v)
        case .swiss: return String(format: "%.2f", v)
        }
    }
}

public struct Course: Identifiable, Hashable {
    public var id: Int
    public var termId: Int
    public var code: String?
    public var name: String
    /// What the student calls it day to day ("Accounting" for "Hospitality Financial Accounting").
    public var shortName: String?
    public var instructor: String?
    public var color: String
    public var aliases: String?
    public var kind: String
    public var gradeScale: GradeScale
    public var targetGrade: Double?
    public var passMark: Double?
    public var moodleId: Int?
    public var archived: Bool

    public init(id: Int = 0, termId: Int, code: String?, name: String, shortName: String? = nil, instructor: String? = nil, color: String = "slate",
                aliases: String? = nil, kind: String = "lecture", gradeScale: GradeScale = .percent,
                targetGrade: Double? = nil, passMark: Double? = nil, moodleId: Int? = nil, archived: Bool = false) {
        self.id = id; self.termId = termId; self.code = code; self.name = name; self.shortName = shortName; self.instructor = instructor
        self.color = color; self.aliases = aliases; self.kind = kind; self.gradeScale = gradeScale
        self.targetGrade = targetGrade; self.passMark = passMark; self.moodleId = moodleId; self.archived = archived
    }
    init(row r: Row) {
        id = r.i("id"); termId = r.i("term_id"); code = r.string("code"); name = r.str("name"); shortName = r.string("short_name")
        instructor = r.string("instructor"); color = r.string("color") ?? "slate"; aliases = r.string("aliases")
        kind = r.string("kind") ?? "lecture"; gradeScale = GradeScale(rawValue: r.str("grade_scale")) ?? .percent
        targetGrade = r.double("target_grade"); passMark = r.double("pass_mark"); moodleId = r.int("moodle_id")
        archived = r.bool("archived")
    }
    /// Short name, full name, code: the display priority, without blanks or repeats.
    public var names: [String] {
        [shortName, name, code].compactMap { $0?.nilIfEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    /// The label shown everywhere: short name, else full name, else code.
    public var displayName: String { names.first ?? "" }
    /// The next label after `displayName`, for a secondary line.
    public var secondaryName: String? { names.dropFirst().first }
    /// "MKT210" or the name when there is no code. Stable across short-name edits, so used for folders and tags.
    public var codeOrName: String { code?.nilIfEmpty ?? name }
    /// The short name plus the comma-separated aliases, for matching free text to this course.
    public var aliasList: [String] {
        ([shortName ?? ""] + (aliases ?? "").split(separator: ",").map(String.init)).compactMap(\.nilIfEmpty)
    }
}

public struct ClassPattern: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var weekday: Int
    public var startTime: LocalTime
    public var endTime: LocalTime
    public var location: String?
    public var validFrom: LocalDate
    public var validTo: LocalDate
    public var timezone: String
    public var externalUid: String?
    public var userModified: Bool

    public init(id: Int = 0, courseId: Int, weekday: Int, startTime: LocalTime, endTime: LocalTime, location: String? = nil,
                validFrom: LocalDate, validTo: LocalDate, timezone: String, externalUid: String? = nil, userModified: Bool = false) {
        self.id = id; self.courseId = courseId; self.weekday = weekday; self.startTime = startTime; self.endTime = endTime
        self.location = location; self.validFrom = validFrom; self.validTo = validTo; self.timezone = timezone
        self.externalUid = externalUid; self.userModified = userModified
    }
    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); weekday = r.i("weekday")
        startTime = LocalTime(r.str("start_time")) ?? LocalTime(hour: 9, minute: 0)
        endTime = LocalTime(r.str("end_time")) ?? LocalTime(hour: 10, minute: 0)
        location = r.string("location"); validFrom = LocalDate(r.str("valid_from"))!; validTo = LocalDate(r.str("valid_to"))!
        timezone = r.str("timezone"); externalUid = r.string("external_uid"); userModified = r.bool("user_modified")
    }
    public var tz: TimeZone { TimeZone(identifier: timezone) ?? .current }
}

public struct ClassException: Identifiable, Hashable {
    public enum Kind: String { case cancel, modify }
    public var id: Int
    public var patternId: Int
    public var originalDate: LocalDate
    public var kind: Kind
    public var newDate: LocalDate?
    public var newStartTime: LocalTime?
    public var newEndTime: LocalTime?
    public var newLocation: String?
    public var note: String?

    public init(id: Int = 0, patternId: Int, originalDate: LocalDate, kind: Kind, newDate: LocalDate? = nil,
                newStartTime: LocalTime? = nil, newEndTime: LocalTime? = nil, newLocation: String? = nil, note: String? = nil) {
        self.id = id; self.patternId = patternId; self.originalDate = originalDate; self.kind = kind; self.newDate = newDate
        self.newStartTime = newStartTime; self.newEndTime = newEndTime; self.newLocation = newLocation; self.note = note
    }
    init(row r: Row) {
        id = r.i("id"); patternId = r.i("pattern_id"); originalDate = LocalDate(r.str("original_date"))!
        kind = Kind(rawValue: r.str("kind")) ?? .modify
        newDate = r.string("new_date").flatMap(LocalDate.init); newStartTime = r.string("new_start_time").flatMap(LocalTime.init)
        newEndTime = r.string("new_end_time").flatMap(LocalTime.init); newLocation = r.string("new_location"); note = r.string("note")
    }
}

public struct Event: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int?
    public var title: String
    public var kind: String // class | event | busy
    public var start: Date
    public var end: Date?
    public var allDay: Bool
    public var location: String?
    public var notes: String?
    public var canceled: Bool
    public var source: String
    public var calendarSourceId: Int?
    public var externalUid: String?
    public var userModified: Bool

    public init(id: Int = 0, courseId: Int?, title: String, kind: String = "event", start: Date, end: Date?, allDay: Bool = false,
                location: String? = nil, notes: String? = nil, canceled: Bool = false, source: String = "manual",
                calendarSourceId: Int? = nil, externalUid: String? = nil, userModified: Bool = false) {
        self.id = id; self.courseId = courseId; self.title = title; self.kind = kind; self.start = start; self.end = end
        self.allDay = allDay; self.location = location; self.notes = notes; self.canceled = canceled; self.source = source
        self.calendarSourceId = calendarSourceId; self.externalUid = externalUid; self.userModified = userModified
    }
    init(row r: Row) {
        id = r.i("id"); courseId = r.int("course_id"); title = r.str("title"); kind = r.str("kind")
        start = ISO.parse(r.str("start_at")) ?? Date.distantPast
        end = r.string("end_at").flatMap { ISO.parse($0) }
        allDay = r.bool("all_day"); location = r.string("location"); notes = r.string("notes"); canceled = r.bool("canceled")
        source = r.str("source"); calendarSourceId = r.int("calendar_source_id"); externalUid = r.string("external_uid")
        userModified = r.bool("user_modified")
    }
}

public enum AssignmentKind: String, CaseIterable, Identifiable {
    case assignment, report, project, case_ = "case", presentation, quiz, exam, lab, reading, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .case_: return "Case study"
        case .lab: return "Lab / practical"
        default: return rawValue.capitalized
        }
    }
    /// Default hours when est_hours is empty (§9.5, a setting-backed guess).
    public var defaultHours: Double {
        switch self {
        case .exam: return 6
        case .project, .report: return 5
        case .case_, .presentation: return 4
        case .quiz: return 2
        case .reading: return 1.5
        default: return 3
        }
    }
}

public enum AssignmentStatus: String, CaseIterable, Identifiable {
    case notStarted = "not_started", inProgress = "in_progress", submitted, graded
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .submitted: return "Submitted"
        case .graded: return "Graded"
        }
    }
    public var isOpen: Bool { self == .notStarted || self == .inProgress }
}

public struct Assignment: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int?
    public var title: String
    public var description: String?
    public var kind: AssignmentKind
    public var dueAt: Date?
    public var status: AssignmentStatus
    public var weightPct: Double?
    public var estHours: Double?
    public var score: Double?
    public var maxScore: Double?
    public var minPassPct: Double?
    public var groupMembers: String?
    public var rubricMaterialId: Int?
    public var confirmed: Bool
    public var dismissed: Bool
    public var source: String
    public var sourceMaterialId: Int?
    public var sourceLocator: String?
    public var externalUid: String?
    public var url: String?
    public var submittedAt: Date?
    public var userModified: Bool

    public init(id: Int = 0, courseId: Int?, title: String, description: String? = nil, kind: AssignmentKind = .assignment,
                dueAt: Date? = nil, status: AssignmentStatus = .notStarted, weightPct: Double? = nil, estHours: Double? = nil,
                score: Double? = nil, maxScore: Double? = nil, minPassPct: Double? = nil, groupMembers: String? = nil,
                rubricMaterialId: Int? = nil, confirmed: Bool = true, dismissed: Bool = false, source: String = "manual",
                sourceMaterialId: Int? = nil, sourceLocator: String? = nil, externalUid: String? = nil, url: String? = nil,
                submittedAt: Date? = nil, userModified: Bool = false) {
        self.id = id; self.courseId = courseId; self.title = title; self.description = description; self.kind = kind
        self.dueAt = dueAt; self.status = status; self.weightPct = weightPct; self.estHours = estHours; self.score = score
        self.maxScore = maxScore; self.minPassPct = minPassPct; self.groupMembers = groupMembers
        self.rubricMaterialId = rubricMaterialId; self.confirmed = confirmed; self.dismissed = dismissed; self.source = source
        self.sourceMaterialId = sourceMaterialId; self.sourceLocator = sourceLocator; self.externalUid = externalUid
        self.url = url; self.submittedAt = submittedAt; self.userModified = userModified
    }
    init(row r: Row) {
        id = r.i("id"); courseId = r.int("course_id"); title = r.str("title"); description = r.string("description")
        kind = AssignmentKind(rawValue: r.str("kind")) ?? .other
        dueAt = r.string("due_at").flatMap { ISO.parse($0) }
        status = AssignmentStatus(rawValue: r.str("status")) ?? .notStarted
        weightPct = r.double("weight_pct"); estHours = r.double("est_hours"); score = r.double("score")
        maxScore = r.double("max_score"); minPassPct = r.double("min_pass_pct"); groupMembers = r.string("group_members")
        rubricMaterialId = r.int("rubric_material_id"); confirmed = r.bool("confirmed"); dismissed = r.bool("dismissed")
        source = r.str("source"); sourceMaterialId = r.int("source_material_id"); sourceLocator = r.string("source_locator")
        externalUid = r.string("external_uid"); url = r.string("url")
        submittedAt = r.string("submitted_at").flatMap { ISO.parse($0) }; userModified = r.bool("user_modified")
    }
    public var hoursNeeded: Double { estHours ?? kind.defaultHours }
    public var isOpen: Bool { status.isOpen }
    public func isOverdue(now: Date) -> Bool { isOpen && (dueAt.map { $0 < now } ?? false) }
    public var scorePct: Double? {
        guard let score, let maxScore, maxScore > 0 else { return nil }
        return score / maxScore * 100
    }
}

public enum MaterialRole: String, CaseIterable, Identifiable {
    case lecture, reading, syllabus, rubric, brief, pastExam = "past_exam", other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pastExam: return "Past exam"
        case .brief: return "Assignment brief"
        default: return rawValue.capitalized
        }
    }
}

public struct Material: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int?
    public var suggestedCourseId: Int?
    public var title: String
    public var kind: String
    public var role: MaterialRole
    public var originalFilename: String?
    public var storedPath: String?
    public var assetsPath: String?
    public var contentHash: String
    public var status: String
    public var statusDetail: String?
    public var pageCount: Int?
    public var processedAt: Date?
    public var externalUid: String?
    public var importedAt: Date

    init(row r: Row) {
        id = r.i("id"); courseId = r.int("course_id"); suggestedCourseId = r.int("suggested_course_id"); title = r.str("title")
        kind = r.str("kind"); role = MaterialRole(rawValue: r.str("role")) ?? .lecture
        originalFilename = r.string("original_filename"); storedPath = r.string("stored_path"); assetsPath = r.string("assets_path")
        contentHash = r.str("content_hash"); status = r.str("status"); statusDetail = r.string("status_detail")
        pageCount = r.int("page_count"); processedAt = r.string("processed_at").flatMap { ISO.parse($0) }
        externalUid = r.string("external_uid"); importedAt = ISO.parse(r.str("imported_at")) ?? Date()
    }
}

public struct Chunk: Identifiable, Hashable {
    public var id: Int
    public var materialId: Int
    public var ordinal: Int
    public var locator: String
    public var heading: String?
    public var textMd: String
    public var notesMd: String?
    public var extraMd: String?
    public var imageCount: Int
    public var images: [String]
    public var ocr: Bool
    public var tokenEstimate: Int

    init(row r: Row) {
        id = r.i("id"); materialId = r.i("material_id"); ordinal = r.i("ordinal"); locator = r.str("locator")
        heading = r.string("heading"); textMd = r.str("text_md"); notesMd = r.string("notes_md"); extraMd = r.string("extra_md")
        imageCount = r.i("image_count"); images = JSON.stringArray(r.string("images")); ocr = r.bool("ocr")
        tokenEstimate = r.i("token_estimate")
    }
}

public struct Concept: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var firstMaterialId: Int?
    public var name: String
    public var definition: String
    public var importance: Int
    public var createdBy: String
    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); firstMaterialId = r.int("first_material_id"); name = r.str("name")
        definition = r.str("definition"); importance = r.i("importance"); createdBy = r.str("created_by")
    }
}

public struct Question: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var materialId: Int
    public var conceptId: Int?
    public var kind: String
    public var prompt: String
    public var answerKey: String
    public var sourceChunkIds: [Int]
    public var difficulty: Int
    public var createdBy: String
    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); materialId = r.i("material_id"); conceptId = r.int("concept_id")
        kind = r.str("kind"); prompt = r.str("prompt"); answerKey = r.str("answer_key")
        sourceChunkIds = JSON.intArray(r.string("source_chunk_ids")); difficulty = r.i("difficulty"); createdBy = r.str("created_by")
    }
}

public struct Card: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var materialId: Int?
    public var conceptId: Int?
    public var questionId: Int?
    public var front: String
    public var back: String
    public var sourceLocators: String?
    public var due: Date
    public var state: Int
    public var fsrs: FSRSCard
    public var status: String
    public var createdBy: String
    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); materialId = r.int("material_id"); conceptId = r.int("concept_id")
        questionId = r.int("question_id"); front = r.str("front"); back = r.str("back"); sourceLocators = r.string("source_locators")
        due = ISO.parse(r.str("due")) ?? Date(); state = r.i("state")
        fsrs = FSRSCard.decode(r.string("fsrs_json")) ?? FSRSCard()
        status = r.str("status"); createdBy = r.str("created_by")
    }
}

public struct Note: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var materialId: Int?
    public var assignmentId: Int?
    public var kind: String
    public var title: String
    public var contentMd: String
    public var dataJson: String?
    public var createdBy: String
    public var updatedAt: Date
    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); materialId = r.int("material_id"); assignmentId = r.int("assignment_id")
        kind = r.str("kind"); title = r.str("title"); contentMd = r.str("content_md"); dataJson = r.string("data_json")
        createdBy = r.str("created_by"); updatedAt = ISO.parse(r.str("updated_at")) ?? Date()
    }
}

public struct StudySession: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int?
    public var materialId: Int?
    public var assignmentId: Int?
    public var kind: String
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String?
    public var weakConceptIds: [Int]
    public var itemsTotal: Int?
    public var itemsCorrect: Int?
    public var createdBy: String
    init(row r: Row) {
        id = r.i("id"); courseId = r.int("course_id"); materialId = r.int("material_id"); assignmentId = r.int("assignment_id")
        kind = r.str("kind"); startedAt = ISO.parse(r.str("started_at")) ?? Date()
        endedAt = r.string("ended_at").flatMap { ISO.parse($0) }; summary = r.string("summary")
        weakConceptIds = JSON.intArray(r.string("weak_concept_ids")); itemsTotal = r.int("items_total")
        itemsCorrect = r.int("items_correct"); createdBy = r.str("created_by")
    }
}

public struct StudyBlock: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int?
    public var assignmentId: Int?
    public var plannedStart: Date
    public var plannedMinutes: Int
    public var focus: String?
    public var status: String
    public var createdBy: String
    public init(id: Int = 0, courseId: Int?, assignmentId: Int?, plannedStart: Date, plannedMinutes: Int, focus: String?,
                status: String = "proposed", createdBy: String = "planner") {
        self.id = id; self.courseId = courseId; self.assignmentId = assignmentId; self.plannedStart = plannedStart
        self.plannedMinutes = plannedMinutes; self.focus = focus; self.status = status; self.createdBy = createdBy
    }
    init(row r: Row) {
        id = r.i("id"); courseId = r.int("course_id"); assignmentId = r.int("assignment_id")
        plannedStart = ISO.parse(r.str("planned_start")) ?? Date(); plannedMinutes = r.i("planned_minutes")
        focus = r.string("focus"); status = r.str("status"); createdBy = r.str("created_by")
    }
    public var end: Date { plannedStart.adding(minutes: plannedMinutes) }
}

public struct Conflict: Identifiable, Hashable {
    public var id: Int
    public var entity: String
    public var entityId: Int
    public var source: String
    public var summary: String
    public var incomingJson: String
    init(row r: Row) {
        id = r.i("id"); entity = r.str("entity"); entityId = r.i("entity_id"); source = r.str("source")
        summary = r.str("summary"); incomingJson = r.str("incoming_json")
    }
}

public struct CalendarSource: Identifiable, Hashable {
    public var id: Int
    public var name: String
    public var kind: String // file | feed
    public var role: String // school | busy
    public var keychainAccount: String?
    public var lastSyncedAt: Date?
    public var lastStatus: String?
    init(row r: Row) {
        id = r.i("id"); name = r.str("name"); kind = r.str("kind"); role = r.str("role")
        keychainAccount = r.string("keychain_account"); lastSyncedAt = r.string("last_synced_at").flatMap { ISO.parse($0) }
        lastStatus = r.string("last_status")
    }
}

public struct HandwritingCapture: Identifiable, Hashable {
    public var id: Int
    public var materialId: Int
    public var imagePath: String
    public var ocrText: String
    public var coverageJson: String?
    public var createdAt: Date
    init(row r: Row) {
        id = r.i("id"); materialId = r.i("material_id"); imagePath = r.str("image_path"); ocrText = r.str("ocr_text")
        coverageJson = r.string("coverage_json"); createdAt = ISO.parse(r.str("created_at")) ?? Date()
    }
}

/// Muted 8-token course palette (§7.1). Stored as token names, never hex.
public enum CoursePalette: String, CaseIterable {
    case slate, sage, clay, ocean, plum, sand, moss, rose
    public var hex: String {
        switch self {
        case .slate: return "#6B7A8F"
        case .sage: return "#7F9C86"
        case .clay: return "#B07D62"
        case .ocean: return "#4F7CA8"
        case .plum: return "#8C6A93"
        case .sand: return "#B59B5E"
        case .moss: return "#5F7D4E"
        case .rose: return "#B3707A"
        }
    }
}
