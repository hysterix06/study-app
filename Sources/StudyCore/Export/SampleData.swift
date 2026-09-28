import Foundation

/// A small, realistic hospitality-management term for trying the app. Removable in one step.
public enum SampleData {
    static let key = "sample_data_ids"

    public static func isLoaded(_ store: StudyStore) -> Bool { store.setting(key) != nil }

    public static func load(_ store: StudyStore, now: Date = Date()) throws {
        guard !isLoaded(store) else { return }
        let tz = store.timezone
        let today = LocalDate(now, tz: tz)
        let monday = today.startOfWeek()
        let termStart = monday.adding(days: -21)
        let termEnd = monday.adding(days: 84)
        var ids: [String: [Int]] = [:]
        try store.db.transaction {
            let term = try store.saveTerm(Term(name: "Sample term", startDate: termStart, endDate: termEnd, isCurrent: store.currentTerm() == nil))
            ids["terms"] = [term]
            _ = try store.saveBreak(TermBreak(termId: term, startDate: monday.adding(days: 35), endDate: monday.adding(days: 39), label: "Reading week"))
            let rm = try store.saveCourse(Course(termId: term, code: "HM210", name: "Revenue Management", instructor: "Dr. Serra", color: "ocean",
                                                 aliases: "revman", gradeScale: .ten, targetGrade: 7.5, passMark: 5))
            let mkt = try store.saveCourse(Course(termId: term, code: "MKT201", name: "Hospitality Marketing", instructor: "Prof. Lindqvist", color: "clay",
                                                  gradeScale: .ten, targetGrade: 7, passMark: 5))
            let fb = try store.saveCourse(Course(termId: term, code: "FB150", name: "Food and Beverage Operations", instructor: "Chef Moreau", color: "sage",
                                                 kind: "practical", gradeScale: .ten, targetGrade: 7, passMark: 5))
            ids["courses"] = [rm, mkt, fb]
            let zone = tz.identifier
            for (c, wd, s, e, room) in [(rm, 2, "09:00", "10:30", "B204"), (rm, 4, "09:00", "10:30", "B204"), (mkt, 1, "11:00", "12:30", "A12"),
                                        (mkt, 3, "14:00", "15:30", "A12"), (fb, 5, "08:00", "12:00", "Training kitchen")] {
                _ = try store.savePattern(ClassPattern(courseId: c, weekday: wd, startTime: LocalTime(s)!, endTime: LocalTime(e)!, location: room,
                                                       validFrom: termStart, validTo: termEnd, timezone: zone))
            }
            func due(_ days: Int, _ time: String = "23:59") -> Date { today.adding(days: days).at(LocalTime(time)!, tz: tz) }
            let items: [Assignment] = [
                Assignment(courseId: rm, title: "Pricing report", kind: .report, dueAt: due(4), status: .inProgress, weightPct: 30, estHours: 8),
                Assignment(courseId: rm, title: "Forecasting quiz", kind: .quiz, dueAt: due(1, "10:00"), weightPct: 5, estHours: 1),
                Assignment(courseId: rm, title: "Final exam", kind: .exam, dueAt: due(40, "09:00"), weightPct: 50, minPassPct: 40),
                Assignment(courseId: rm, title: "Overbooking case", kind: .case_, dueAt: due(-10), status: .graded, weightPct: 15, score: 16, maxScore: 20),
                Assignment(courseId: mkt, title: "Brand audit presentation", kind: .presentation, dueAt: due(9, "14:00"), weightPct: 25, estHours: 6,
                           groupMembers: "Ana, Luca, Mei"),
                Assignment(courseId: mkt, title: "Social media plan", kind: .project, dueAt: due(18), weightPct: 35, estHours: 10),
                Assignment(courseId: mkt, title: "Reading: service-dominant logic", kind: .reading, dueAt: due(2), estHours: 1.5),
                Assignment(courseId: fb, title: "Menu costing exercise", kind: .lab, dueAt: due(6), weightPct: 20, estHours: 3),
            ]
            var aids: [Int] = []
            for a in items { aids.append(try store.saveAssignment(a, markModified: false)) }
            ids["assignments"] = aids
        }
        // A short lecture so the Study flow has something to show.
        let lecture = """
        # HM210 Week 4 — Overbooking and No-shows

        ## Why hotels overbook
        Hotels sell more rooms than they have because some guests do not arrive (no-shows) and some cancel late.
        An empty room is revenue lost forever: room nights are perishable inventory.

        ## Measuring no-shows
        No-show rate = no-show reservations ÷ total reservations for the date.
        Forecast it by day of week and segment; corporate guests behave differently from leisure guests.

        ## Setting the overbooking level
        Compare the cost of a spoiled room (lost ADR) with the cost of walking a guest (relocation, compensation, goodwill).
        The optimal level is where the expected cost of one more overbooked room equals the expected revenue gain.

        ## Walking guests
        Service recovery matters: arrange a comparable hotel, pay transport and the first night, and follow up.
        Never walk loyalty members or guests with special needs if it can be avoided.

        ## Key formulas
        RevPAR = ADR × occupancy. Occupancy = rooms sold ÷ rooms available. ADR = room revenue ÷ rooms sold.
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("HM210 Week 4 - Overbooking.md")
        try lecture.write(to: tmp, atomically: true, encoding: .utf8)
        let rm = ids["courses"]![0]
        if case .imported(let mid, _) = store.importMaterial(from: tmp, courseId: rm, role: .lecture) {
            ids["materials"] = [mid]
            try store.saveUserConcept(courseId: rm, name: "Perishable inventory", definition: "A room night unsold today can never be sold again.", importance: 1)
            for (f, b) in [("Why do hotels overbook?", "Because of no-shows and late cancellations; empty rooms are lost revenue."),
                           ("How is RevPAR calculated?", "ADR × occupancy (or room revenue ÷ rooms available)."),
                           ("What should a hotel do when it walks a guest?", "Arrange a comparable hotel, pay transport and the first night, follow up.")] {
                _ = try store.addUserCard(courseId: rm, materialId: mid, front: f, back: b)
            }
        }
        store.setSetting(key, JSON.string(ids))
        store.audit("sample_data_loaded")
    }

    public static func remove(_ store: StudyStore) throws {
        guard let d = JSON.parse(store.setting(key)) as? [String: [Int]] else { return }
        for id in d["materials"] ?? [] { try store.deleteMaterial(id) }
        try store.db.transaction {
            for id in d["courses"] ?? [] { try store.db.execute("DELETE FROM courses WHERE id = ?", [id]) }
            for id in d["terms"] ?? [] {
                if try store.db.scalarInt("SELECT count(*) FROM courses WHERE term_id = ?", [id]) == 0 {
                    try store.db.execute("DELETE FROM terms WHERE id = ?", [id])
                }
            }
        }
        store.setSetting(key, nil)
    }
}
