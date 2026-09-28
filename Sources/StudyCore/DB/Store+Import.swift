import Foundation

public extension StudyStore {
    // MARK: Calendar sources

    func calendarSources() -> [CalendarSource] {
        ((try? db.query("SELECT * FROM calendar_sources ORDER BY id")) ?? []).map(CalendarSource.init)
    }

    /// Feed URLs contain tokens, so they go to the Keychain; the row only keeps an account name.
    @discardableResult
    func addCalendarSource(name: String, kind: String, role: String, feedURL: String?) throws -> Int {
        let id = try db.execute("INSERT INTO calendar_sources(name, kind, role) VALUES(?,?,?)", [name, kind, role]).lastInsertId
        if let feedURL, kind == "feed" {
            let account = "calendar-feed-\(id)"
            Keychain.set(feedURL, account: account)
            try db.execute("UPDATE calendar_sources SET keychain_account = ? WHERE id = ?", [account, id])
        }
        return id
    }

    func removeCalendarSource(_ id: Int) throws {
        if let acct = try db.scalarString("SELECT keychain_account FROM calendar_sources WHERE id = ?", [id]) { Keychain.delete(acct) }
        try db.transaction {
            try db.execute("DELETE FROM events WHERE calendar_source_id = ? AND user_modified = 0", [id])
            try db.execute("UPDATE events SET calendar_source_id = NULL WHERE calendar_source_id = ?", [id])
            try db.execute("DELETE FROM calendar_sources WHERE id = ?", [id])
        }
    }

    func setSourceStatus(_ id: Int, _ status: String) {
        _ = try? db.execute("UPDATE calendar_sources SET last_status = ?, last_synced_at = ? WHERE id = ?", [status, ISO.instant(Date()), id])
    }

    // MARK: ICS

    func existingForICS(sourceId: Int?) -> ICSMapper.Existing {
        var ex = ICSMapper.Existing()
        for p in patterns() { if let u = p.externalUid { ex.patterns[u] = p } }
        for e in ((try? db.query("SELECT * FROM events WHERE source = 'ics' AND external_uid IS NOT NULL")) ?? []).map(Event.init) {
            ex.events[e.externalUid!] = e
            if let sourceId, e.calendarSourceId == sourceId { ex.sourceEventUids[e.externalUid!] = e.id }
        }
        for a in ((try? db.query("SELECT * FROM assignments WHERE source = 'ics' AND external_uid IS NOT NULL")) ?? []).map(Assignment.init) {
            ex.assignments[a.externalUid!] = a
        }
        return ex
    }

    func planICSImport(text: String, role: String, sourceId: Int?, now: Date = Date()) throws -> ICSImportPlan {
        let events = try ICS.parse(text)
        return ICSMapper.plan(events: events, courses: courses(), term: currentTerm(), defaultTZ: timezone, role: role,
                              existing: existingForICS(sourceId: sourceId), now: now)
    }

    /// Applies a previewed plan in one transaction. Creates a term if none exists so classes have a home.
    func applyICSImport(_ plan: ICSImportPlan, sourceId: Int?) throws {
        try db.transaction {
            var termId = currentTerm()?.id
            if termId == nil && (!plan.newCourses.isEmpty || !plan.patterns.isEmpty) {
                let starts = plan.patterns.map(\.pattern.validFrom)
                let ends = plan.patterns.map(\.pattern.validTo)
                let today = LocalDate.today(tz: timezone)
                termId = try saveTerm(Term(name: "Current term", startDate: starts.min() ?? today, endDate: ends.max() ?? today.adding(days: 120), isCurrent: true))
            }
            var newCourseIds: [String: Int] = [:]
            for nc in plan.newCourses {
                newCourseIds[nc.key] = try saveCourse(Course(termId: termId!, code: nc.code, name: nc.name, color: ""))
            }
            func resolve(_ ref: ICSImportPlan.CourseRef?) -> Int? {
                switch ref {
                case .existing(let id): return id
                case .new(let key): return newCourseIds[key]
                case nil: return nil
                }
            }
            var patternIds: [String: Int] = [:]
            for op in plan.patterns {
                var p = op.pattern
                p.courseId = resolve(op.course) ?? 0
                switch op.action {
                case .create: patternIds[op.uid] = try savePattern(p)
                case .update:
                    p.id = op.existingId!
                    try savePattern(p)
                    patternIds[op.uid] = p.id
                case .unchanged, .conflict: patternIds[op.uid] = op.existingId
                }
            }
            for op in plan.exceptions {
                guard let pid = patternIds[op.patternUid] ?? plan.patterns.first(where: { $0.uid == op.patternUid })?.existingId else { continue }
                let ex = op.exception
                // Never overwrite a change the student made to that date.
                try db.execute("""
                    INSERT OR IGNORE INTO class_exceptions(pattern_id, original_date, kind, new_date, new_start_time, new_end_time, new_location)
                    VALUES(?,?,?,?,?,?,?)
                    """, [pid, ex.originalDate, ex.kind.rawValue, ex.newDate, ex.newStartTime, ex.newEndTime, ex.newLocation])
            }
            for op in plan.events {
                var e = op.event
                e.courseId = resolve(op.course)
                e.calendarSourceId = sourceId
                switch op.action {
                case .create: try saveEvent(e)
                case .update:
                    e.id = op.existingId!
                    try saveEvent(e)
                default: break
                }
            }
            for op in plan.assignments {
                var a = op.assignment
                a.courseId = resolve(op.course)
                switch op.action {
                case .create: try saveAssignment(a, markModified: false)
                case .update:
                    guard var old = assignment(op.existingId!) else { continue }
                    old.title = a.title; old.dueAt = a.dueAt; old.description = a.description
                    try saveAssignment(old, markModified: false)
                default: break
                }
            }
            for c in plan.conflicts {
                let open = try db.scalarInt("SELECT count(*) FROM conflicts WHERE entity = ? AND entity_id = ? AND resolved_at IS NULL", [c.entity, c.entityId])
                if open == 0 {
                    try db.execute("INSERT INTO conflicts(entity, entity_id, source, summary, incoming_json) VALUES(?,?,?,?,?)",
                                   [c.entity, c.entityId, "ics", c.summary, JSON.string(c.incoming)])
                }
            }
            for id in plan.staleEventIds {
                if plan.role == "busy" { try deleteEvent(id) }
                else { try db.execute("UPDATE events SET canceled = 1 WHERE id = ?", [id]) }
            }
            audit("ics_import", detail: plan.summary)
        }
    }

    /// Downloads a feed stored in the Keychain. User-initiated or scheduled while the app is open (§10).
    func fetchFeed(_ source: CalendarSource) async throws -> String {
        guard let acct = source.keychainAccount, var urlString = Keychain.get(acct) else { throw StoreError.notFound("The feed address is missing. Remove and re-add this calendar.") }
        if urlString.lowercased().hasPrefix("webcal://") { urlString = "https://" + urlString.dropFirst("webcal://".count) }
        guard let url = URL(string: urlString) else { throw StoreError.invalid("The feed address is not a valid URL.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("text/calendar", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StoreError.invalid("The calendar server answered \(http.statusCode).")
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
