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
        if let mid = ids["materials"]?.first {
            ids["materials"]! += try loadPath(store, courseId: rm, lecture: mid, assignments: ids["assignments"] ?? [])
        }
        store.setSetting(key, JSON.string(ids))
        store.audit("sample_data_loaded")
    }

    /// HM210 as the course builder would lay it out: two units of three topics, the whole notebook guide (with a
    /// reference drawing and the RevPAR formula), three lessons, a tutorial sheet whose problems are split out word for
    /// word, and which topics the final exam and the pricing report cover. Returns the extra files it imported.
    static func loadPath(_ store: StudyStore, courseId rm: Int, lecture: Int, assignments: [Int]) throws -> [Int] {
        let chunks = store.chunks(materialId: lecture)
        func chunk(_ heading: String) -> [Int] { chunks.filter { ($0.heading ?? "").contains(heading) }.map(\.id) }
        typealias T = PathInput.Topic
        let path = PathInput(units: [
            PathInput.Unit(title: "Demand and pricing", summary: "Why rooms are priced the way they are.", topics: [
                T(title: "Perishable inventory", summary: "A room night unsold today is gone for good.", objectives: ["Explain why hotels manage revenue, not just price"],
                  estMinutes: 20),
                T(title: "ADR, occupancy and RevPAR", summary: "The three numbers every hotel watches.", objectives: ["Calculate ADR, occupancy and RevPAR", "Explain why RevPAR combines both"],
                  prereqs: ["Perishable inventory"], estMinutes: 25, emphasis: 3, sources: [PathInput.Source(materialId: lecture, chunkIds: chunk("Key formulas"))]),
                T(title: "Price elasticity and segments", summary: "Different guests respond differently to price.", objectives: ["Read a demand curve", "Explain segment pricing"],
                  prereqs: ["Perishable inventory"], estMinutes: 30, emphasis: 2),
            ]),
            PathInput.Unit(title: "Capacity", summary: "Selling the right number of rooms.", topics: [
                T(title: "Forecasting no-shows", summary: "How many guests won't arrive.", objectives: ["Calculate a no-show rate", "Explain why it varies by segment"],
                  estMinutes: 25, emphasis: 2, sources: [PathInput.Source(materialId: lecture, chunkIds: chunk("Measuring no-shows"))]),
                T(title: "Overbooking", summary: "Selling more rooms than exist, on purpose.", objectives: ["Set an overbooking level by comparing costs"],
                  prereqs: ["Forecasting no-shows", "ADR, occupancy and RevPAR"], estMinutes: 30, emphasis: 3,
                  sources: [PathInput.Source(materialId: lecture, chunkIds: chunk("Why hotels overbook") + chunk("Setting the overbooking level"))]),
                T(title: "Walking guests", summary: "What to do when the hotel is full after all.", objectives: ["Plan a service recovery"],
                  prereqs: ["Overbooking"], estMinutes: 20, sources: [PathInput.Source(materialId: lecture, chunkIds: chunk("Walking guests"))]),
            ]),
        ], approachMd: """
        - Learn the three performance numbers first: everything else is judged by them.
        - Draw the demand curve for each segment before you price anything.
        - Overbooking is a trade-off between two costs: always write both down.
        """, anglesMd: "Your course weighs overbooking heavily and expects calculations with the costs written out (Week 4, \"Setting the overbooking level\").",
        assessments: assignments.count >= 3 ? [
            PathInput.Assessment(assignmentId: assignments[2], topics: ["ADR, occupancy and RevPAR", "Price elasticity and segments", "Forecasting no-shows", "Overbooking", "Walking guests"]),
            PathInput.Assessment(assignmentId: assignments[0], topics: ["ADR, occupancy and RevPAR", "Price elasticity and segments"]),
        ] : [])
        let saved = try store.savePath(courseId: rm, path, tier: "full", builtWith: "the sample", createdBy: "app")
        func id(_ title: String) -> Int? { saved.topicIds[StudyStore.topicKey(title)] }
        let demandCurve = """
        <svg viewBox="0 0 220 150"><line x1="30" y1="10" x2="30" y2="130" stroke="currentColor" stroke-width="2"/>\
        <line x1="30" y1="130" x2="210" y2="130" stroke="currentColor" stroke-width="2"/>\
        <line x1="45" y1="25" x2="195" y2="120" stroke="currentColor" stroke-width="2"/>\
        <text x="4" y="18" font-size="11" fill="currentColor">Price</text><text x="160" y="145" font-size="11" fill="currentColor">Rooms sold</text>\
        <text x="150" y="90" font-size="11" fill="currentColor">Demand</text></svg>
        """
        let wording = chunk("Measuring no-shows")
        let pages: [StudyStore.NotebookInput] = [
            .init(topicId: id("Perishable inventory"), terms: [
                NotebookTerm(term: "Revenue management", definition: "Selling the right room to the right guest at the right time and price."),
                NotebookTerm(term: "Perishable inventory", definition: "Stock that can't be stored: a room night unsold today can never be sold."),
                NotebookTerm(term: "Fixed capacity", definition: "A hotel can't add rooms for a busy night, so price and availability do the work."),
            ]),
            .init(topicId: id("ADR, occupancy and RevPAR"), terms: [
                NotebookTerm(term: "ADR", definition: "Average daily rate: room revenue divided by rooms sold."),
                NotebookTerm(term: "Occupancy", definition: "The share of available rooms that were sold."),
                NotebookTerm(term: "RevPAR", definition: "Revenue per available room: ADR and occupancy in one number."),
            ], formulas: [
                NotebookFormula(latex: "RevPAR = ADR \\times Occ", meaning: "Revenue per available room = average daily rate × occupancy"),
                NotebookFormula(latex: "Occ = \\frac{\\text{rooms sold}}{\\text{rooms available}}", meaning: "Occupancy, as a share"),
            ]),
            .init(topicId: id("Price elasticity and segments"), terms: [
                NotebookTerm(term: "Price elasticity", definition: "How much demand changes when price changes."),
                NotebookTerm(term: "Segment", definition: "A group of guests who book and respond to price alike, such as corporate or leisure."),
            ], diagrams: [NotebookDiagram(title: "Demand curve", draw: "Price up the side, rooms sold along the bottom, a line sloping down.",
                                          labels: ["Price", "Rooms sold", "Demand"], svg: demandCurve)]),
            .init(topicId: id("Forecasting no-shows"), terms: [
                NotebookTerm(term: "No-show", definition: "A guest with a reservation who neither arrives nor cancels."),
                NotebookTerm(term: "No-show rate", definition: "The share of reservations for a date that turn out to be no-shows.",
                             courseWording: wording.isEmpty ? nil : "no-show reservations ÷ total reservations for the date", sourceChunkIds: wording),
            ]),
            .init(topicId: id("Overbooking"), terms: [
                NotebookTerm(term: "Overbooking", definition: "Accepting more reservations than rooms, expecting some guests not to come."),
                NotebookTerm(term: "Spoilage", definition: "A room left empty that could have been sold."),
                NotebookTerm(term: "Walk cost", definition: "What it costs to send a guest to another hotel."),
            ]),
            .init(topicId: id("Walking guests"), terms: [
                NotebookTerm(term: "Walking a guest", definition: "Moving a guest with a reservation to another hotel because yours is full."),
                NotebookTerm(term: "Service recovery", definition: "Turning a failure into a good experience: comparable room, transport, follow-up."),
            ]),
        ]
        _ = try store.saveNotebook(courseId: rm, pages, tier: "full", generatedBy: "the sample")
        let lessons: [StudyStore.LessonInput] = [
            .init(topicId: id("ADR, occupancy and RevPAR"), preQuestion: "A hotel raises its prices and fills fewer rooms. Did it do better?", sections: [
                LessonSection(kind: "idea", title: "The idea", bodyMd: "Price alone and occupancy alone both mislead. **RevPAR** combines them: $RevPAR = ADR \\times Occ$."),
                LessonSection(kind: "example", title: "Worked example", bodyMd: "100 rooms, 80 sold at €120: occupancy 0.8, ADR €120, RevPAR = 120 × 0.8 = **€96**."),
                LessonSection(kind: "mistakes", title: "Common mistakes", bodyMd: "- Dividing revenue by rooms *sold* and calling it RevPAR (that's ADR)."),
            ], cards: [LessonCard(front: "RevPAR?", back: "ADR × occupancy")], explainPrompt: "Explain why a hotel watches RevPAR rather than occupancy."),
            .init(topicId: id("Forecasting no-shows"), preQuestion: "Why would business travellers miss their reservations more than holidaymakers?", sections: [
                LessonSection(kind: "idea", title: "The idea", bodyMd: "Forecast no-shows by day of week and segment, from past arrivals."),
                LessonSection(kind: "course_angle", title: "Your course's angle", bodyMd: "Your course defines the rate per date and splits corporate from leisure guests.",
                              sourceChunkIds: wording),
            ], cards: [LessonCard(front: "No-show rate?", back: "No-shows ÷ reservations for the date")]),
            .init(topicId: id("Overbooking"), preQuestion: "When is selling a room you don't have the right call?", sections: [
                LessonSection(kind: "idea", title: "The idea", bodyMd: "Overbook one more room while the expected revenue from it is more than its expected walk cost."),
                LessonSection(kind: "example", title: "Worked example", bodyMd: "ADR €120, walk cost €300, 8% no-shows on 100 rooms: start near 8 extra rooms and stop once the chance of walking someone makes the next one cost more than it earns."),
            ], cards: [LessonCard(front: "Overbooking trade-off?", back: "Expected spoilage cost against expected walk cost")],
               explainPrompt: "Explain to a new front-desk agent why the hotel overbooks."),
        ]
        _ = try store.saveLessons(courseId: rm, lessons, tier: "full", generatedBy: "the sample")
        for (title, page) in [("Perishable inventory", "2"), ("ADR, occupancy and RevPAR", "3")] {
            if let t = id(title) { try store.setNotebookWritten(t, written: true, page: page) }
        }
        let tutorial = """
        # HM210 Tutorial 4

        Exercise 1: A 100-room hotel sold 82 rooms last night for €9,840. Calculate ADR, occupancy and RevPAR.

        Exercise 2: The no-show rate on Tuesdays is 9% for corporate guests and 3% for leisure guests. Explain why a single rate for the whole hotel would mislead.

        Exercise 3: ADR is €120 and walking a guest costs €300. Should the hotel accept one more reservation when the chance of walking someone is 30%? Show the expected values.

        Solutions

        Solution 1: ADR = 9,840 ÷ 82 = €120; occupancy = 82%; RevPAR = €98.40.
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("HM210 Tutorial 4.md")
        try tutorial.write(to: tmp, atomically: true, encoding: .utf8)
        var extra: [Int] = []
        if case .imported(let t, _) = store.importMaterial(from: tmp, courseId: rm, role: .practice) {
            extra.append(t)
            store.splitPractice(materialId: t)
        }
        store.linkPracticeAndCards(courseId: rm)
        return extra
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
