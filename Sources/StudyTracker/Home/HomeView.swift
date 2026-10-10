import SwiftUI
import StudyCore

/// Home: one big Start for the next session (with why it's next), anything urgent, every course's notebook and path at
/// a glance, the week's deadlines, and how many things need a look.
struct HomeView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let store = model.store
        let home = store.homeSnapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(greeting).font(.stTitle)
                if store.courses().isEmpty {
                    EmptyState(text: "Add your courses to get started: connect Moodle, or add them by name.", actionTitle: "Set up") { model.go(.setup(.school)) }
                } else {
                    NextSessionCard(plan: home.plan)
                    if !home.plan.then.isEmpty { thenRow(home.plan.then) }
                    ForEach(Array(warnings(home.plan.warnings).enumerated()), id: \.offset) { _, w in warning(w) }
                    if let u = home.urgent { urgent(u) }
                    courses(home.courses)
                    if !home.dueThisWeek.isEmpty { week(home.dueThisWeek) }
                    if home.needsLook > 0 {
                        Button { model.go(.needsLook) } label: {
                            HStack {
                                Spacer()
                                Text("\(home.needsLook) thing\(home.needsLook == 1 ? "" : "s") need\(home.needsLook == 1 ? "s" : "") a look")
                                Image(systemName: "arrow.right")
                            }.font(.stBody).foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(28).contentWidth()
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return "\(part) · \(Formatters.longDay(Date(), tz: model.tz))"
    }

    func thenRow(_ picks: [SessionPick]) -> some View {
        HStack(spacing: 10) {
            Text("Then").font(.stSmallStrong).foregroundStyle(Theme.textTertiary)
            ForEach(picks) { p in
                Button { model.startSession(p) } label: {
                    HStack(spacing: 6) {
                        Text(SessionCopy.describe(p, store: model.store)).lineLimit(1)
                        Text("\(p.minutes) min").foregroundStyle(Theme.textTertiary)
                    }.font(.stSmall)
                }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
        }
    }

    /// Only warnings worth a student's attention: a small quiz being tight isn't one.
    func warnings(_ all: [NextSessionPlan.Warning]) -> [NextSessionPlan.Warning] {
        all.filter { w in
            if case .tightForExam(let id, _, _, _) = w { return (model.store.assignment(id)?.weightPct ?? 100) >= 10 }
            return true
        }
    }

    func warning(_ w: NextSessionPlan.Warning) -> some View {
        let text: String
        switch w {
        case .tightForExam(_, let title, let need, let have):
            text = "\(title): about \(Formatters.hours(Double(need) / 60)) of study left and \(Formatters.hours(Double(have) / 60)) free before it. Shorter, daily sessions help."
        case .behindClass(let courseId, let count):
            text = "\(model.store.course(courseId)?.displayName ?? "A course"): \(count) topic\(count == 1 ? "" : "s") behind class."
        }
        return Label(text, systemImage: "info.circle").font(.stBody).foregroundStyle(Theme.textSecondary)
    }

    func urgent(_ u: SuggestedAction) -> some View {
        HStack {
            Label(u.title + (u.detail.map { " · \($0)" } ?? ""), systemImage: "exclamationmark.circle").font(.stBody).foregroundStyle(Theme.attention).lineLimit(2)
            Spacer()
            if let id = u.assignmentId { Button("Open") { model.openAssignment(id) }.buttonStyle(QuietButtonStyle()) }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.attention.opacity(0.08)))
    }

    func courses(_ list: [CourseProgress]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "Courses")
                Text("Notebook").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).frame(width: 80, alignment: .trailing)
                Text("Solid").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).frame(width: 60, alignment: .trailing)
            }
            ForEach(list) { p in
                Button { model.openCourse(p.course.id) } label: {
                    HStack(spacing: 10) {
                        CourseDot(color: p.course.color)
                        Text(p.course.displayName).font(.stBodyStrong).lineLimit(1)
                        let note = courseNote(p)
                        Text(note).font(.stSmall).foregroundStyle(note.hasSuffix("behind class") ? Theme.attention : Theme.textSecondary).lineLimit(1)
                        Spacer()
                        Text(p.topics == 0 ? "–" : "\(p.written)/\(p.topics)").font(.stBody).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Text(p.topics == 0 ? "–" : "\(p.solid)/\(p.topics)").font(.stBody).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.surface))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    func courseNote(_ p: CourseProgress) -> String {
        if let job = model.store.activeJobs().first(where: { $0.task.isCourseBuilding && $0.courseId == p.course.id }) {
            return job.task.builderTier == "full" ? "Building with Claude…" : "Building…"
        }
        if p.behind > 0 { return "\(p.behind) topic\(p.behind == 1 ? "" : "s") behind class" }
        if let e = p.nextExam, let due = e.dueAt { return "\(e.title) \(Formatters.day(due, tz: model.tz))" }
        if p.topics == 0 { return "No path yet" }
        return ""
    }

    func week(_ due: [Assignment]) -> some View {
        let courses = model.store.courseMap()
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "This week")
            ForEach(due.prefix(6)) { a in
                Button { model.openAssignment(a.id) } label: {
                    HStack(spacing: 8) {
                        Text(a.dueAt.map { Formatters.weekdayShort($0, tz: model.tz) } ?? "").font(.stSmall).foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .leading)
                        CourseDot(color: a.courseId.flatMap { courses[$0]?.color })
                        Text(a.title).font(.stBody).lineLimit(1)
                        Spacer()
                        if let w = a.weightPct { Text(Formatters.percent(w)).font(.stSmall).foregroundStyle(Theme.textSecondary) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// The next session, big: what it is, why it's next, and Start. Other sizes and "Just review" underneath.
struct NextSessionCard: View {
    @Environment(AppModel.self) var model
    var plan: NextSessionPlan

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 10) {
            Text("NEXT SESSION").font(.stSmallStrong).foregroundStyle(Theme.textTertiary).kerning(0.6)
            if let p = plan.primary {
                Text(SessionCopy.describe(p, store: store)).font(.stHeading).fixedSize(horizontal: false, vertical: true)
                Text(SessionReasons.line(p, store: store)).font(.stBody).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 14) {
                    Button { model.startSession(p, mode: .standard) } label: { Text("Start").frame(minWidth: 120) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    if p.kind != .review {
                        Button("Quick 10 min") { model.startSession(p, mode: .quick) }.buttonStyle(.borderless)
                        Button("Deep 50 min") { model.startSession(p, mode: .deep) }.buttonStyle(.borderless)
                    }
                    if store.dueCount() > 0 && p.kind != .review { Button("Just review") { model.startReview() }.buttonStyle(.borderless) }
                }
                .font(.stBody)
            } else {
                Text("You're up to date.").font(.stHeading)
                Text("Nothing is due and every topic is in hand. Add files or check back after your next class.").font(.stBody).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
    }
}

/// Why a session is next, in words: "Final exam in 9 days · taught Tuesday · 25 min".
enum SessionReasons {
    @MainActor
    static func line(_ p: SessionPick, store: StudyStore) -> String {
        let tz = store.timezone
        var parts: [String] = p.reasons.prefix(2).map { r in
            switch r {
            case .examIn(let days, let title): return days <= 1 ? "\(title) tomorrow" : "\(title) in \(days) days"
            case .taught(let d): return "taught \(Formatters.weekdayShort(d.at(LocalTime(hour: 12, minute: 0), tz: tz), tz: tz))"
            case .nextInPath: return "next in your path"
            case .prereqFor(let t): return "needed for \(t)"
            case .refresh: return "fading: time for a refresh"
            case .weak: return "it was hard last time"
            case .notebookFirst: return "the words and pictures first"
            case .cardsDue(let n): return "\(n) cards due"
            case .unfinished: return "you left it halfway"
            }
        }
        parts.append("\(p.minutes) min")
        return parts.joined(separator: " · ")
    }
}
