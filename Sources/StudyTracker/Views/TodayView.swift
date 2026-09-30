import SwiftUI
import StudyCore

struct TodayView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let store = model.store
        let tz = model.tz
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let snap = store.todaySnapshot(now: ctx.date)
                let courses = store.courseMap()
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatters.longDay(ctx.date, tz: tz)).font(.stTitle)
                        Text(greeting(ctx.date)).font(.stBody).foregroundStyle(Theme.secondaryText)
                    }

                    if store.courses().isEmpty {
                        OnboardingCard()
                    } else {
                        SuggestedActionCard(action: snap.suggested)

                        if let s = snap.openSession {
                            Button { continueSession(s) } label: {
                                HStack {
                                    Image(systemName: "arrow.uturn.right.circle")
                                    Text("Continue: \(sessionLabel(s))").font(.stBody)
                                    Spacer()
                                    Text(RelativeTime.describe(s.startedAt, now: ctx.date)).font(.stSmall).foregroundStyle(Theme.tertiaryText)
                                }.padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                            }.buttonStyle(.plain)
                        }

                        HStack(alignment: .top, spacing: 16) {
                            NextClassCard(next: snap.nextClass, now: ctx.date, courses: courses)
                            CountersCard(cardsDue: snap.cardsDue, inbox: snap.inboxCount)
                                .frame(width: 220)
                        }

                        DueSoonCard(items: snap.dueSoon, now: ctx.date, courses: courses)

                        if !snap.today.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(title: "Today")
                                ForEach(snap.today) { o in
                                    HStack(spacing: 10) {
                                        Text(o.allDay ? "All day" : "\(Formatters.time(o.start, tz: tz))–\(Formatters.time(o.end, tz: tz))")
                                            .font(.stSmall).monospacedDigit().foregroundStyle(Theme.secondaryText).frame(width: 96, alignment: .leading)
                                        CourseDot(color: o.courseId.flatMap { courses[$0]?.color })
                                        Text(o.title).font(.stBody).strikethrough(o.status == .canceled)
                                            .foregroundStyle(o.status == .canceled ? Theme.tertiaryText : .primary)
                                        if let loc = o.location { Text(loc).font(.stSmall).foregroundStyle(Theme.tertiaryText) }
                                        if o.status == .modified { Chip(text: "changed") }
                                        Spacer()
                                    }
                                    .opacity(o.end < ctx.date ? 0.45 : 1)
                                }
                            }
                        }
                    }
                }
                .padding(32)
                .contentWidth()
            }
        }
    }

    func greeting(_ d: Date) -> String {
        let h = calendar(in: model.tz).component(.hour, from: d)
        return h < 12 ? "Good morning." : (h < 18 ? "Good afternoon." : "Good evening.")
    }

    func sessionLabel(_ s: StudySession) -> String {
        let m = s.materialId.flatMap { model.store.material($0)?.title }
        return [s.kind.capitalized, m].compactMap { $0 }.joined(separator: " · ")
    }

    func continueSession(_ s: StudySession) {
        if s.kind == "review" {
            try? model.store.endSession(s.id, summary: nil)
            model.startReview(courseId: s.courseId)
        } else {
            if let id = s.materialId { model.openMaterial(id) }
        }
    }
}

struct SuggestedActionCard: View {
    @Environment(AppModel.self) var model
    var action: SuggestedAction

    var urgent: Bool { [.finishOverdue, .startAtRisk].contains(action.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if urgent { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Needs attention") }
                Text("Suggested").font(.stSmallStrong).foregroundStyle(urgent ? Theme.accent : Theme.tertiaryText).textCase(.uppercase)
            }
            if action.kind == .nothing {
                Text(action.title).font(.stHeading)
            } else {
                Button(action: perform) {
                    HStack {
                        Text(action.title).multilineTextAlignment(.leading)
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                if let d = action.detail { Text(d).font(.stSmall).foregroundStyle(Theme.secondaryText) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(urgent ? Theme.accent.opacity(0.5) : Theme.hairline))
    }

    func perform() {
        switch action.kind {
        case .finishOverdue, .startAtRisk, .keepGoing:
            if let id = action.assignmentId {
                if action.kind == .startAtRisk { try? model.store.setStatus(id, .inProgress); model.refresh() }
                model.openAssignment(id)
            }
        case .planExam: model.planStudy(focusAssignment: action.assignmentId)
        case .review: model.startReview()
        case .recall: if let id = action.materialId { model.openMaterial(id) }
        case .process: if let id = action.materialId { model.process(materialId: id) }
        case .approveCards: model.go(.inbox(.cards))
        case .nothing: break
        }
    }
}

struct NextClassCard: View {
    @Environment(AppModel.self) var model
    var next: Occurrence?
    var now: Date
    var courses: [Int: Course]

    var body: some View {
        Panel {
            SectionHeader(title: "Next class")
            if let n = next {
                HStack(spacing: 8) {
                    CourseDot(color: n.courseId.flatMap { courses[$0]?.color }, size: 10)
                    Text(n.title).font(.stHeading).lineLimit(2)
                }
                HStack(spacing: 12) {
                    Label("\(Formatters.day(n.start, tz: model.tz)), \(Formatters.time(n.start, tz: model.tz))–\(Formatters.time(n.end, tz: model.tz))", systemImage: "clock")
                    if let loc = n.location { Label(loc, systemImage: "mappin.and.ellipse") }
                }.font(.stBody).foregroundStyle(Theme.secondaryText).monospacedDigit()
                let soon = n.start.timeIntervalSince(now) < 3600 && n.start > now
                Text(n.start <= now ? "Happening now" : RelativeTime.describe(n.start, now: now).capitalizedFirst)
                    .font(.stBodyStrong).monospacedDigit().foregroundStyle(soon ? Theme.accent : .primary)
                if n.status == .modified { Chip(text: "Changed from the usual time or room") }
            } else {
                Text("No classes in the next two weeks.").font(.stBody).foregroundStyle(Theme.secondaryText)
                Button("Import your timetable") { model.go(.connections(.calendars)) }.buttonStyle(QuietButtonStyle())
            }
        }
    }
}

struct CountersCard: View {
    @Environment(AppModel.self) var model
    var cardsDue: Int
    var inbox: Int
    var body: some View {
        Panel {
            SectionHeader(title: "Counters")
            Button { model.startReview() } label: {
                HStack { Image(systemName: "rectangle.stack"); Text("Cards due"); Spacer(); Text("\(cardsDue)").monospacedDigit().fontWeight(.semibold) }
            }.buttonStyle(.plain).disabled(cardsDue == 0)
            Divider()
            Button { model.go(.inbox(nil)) } label: {
                HStack { Image(systemName: "tray"); Text("Inbox"); Spacer(); Text("\(inbox)").monospacedDigit().fontWeight(.semibold) }
            }.buttonStyle(.plain)
        }
        .font(.stBody)
    }
}

struct DueSoonCard: View {
    @Environment(AppModel.self) var model
    var items: [Assignment]
    var now: Date
    var courses: [Int: Course]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Due in the next 7 days", trailing: AnyView(Button("See all") { model.go(.assignments) }.buttonStyle(.borderless).font(.stSmall)))
            if items.isEmpty {
                Text("Nothing due this week.").font(.stBody).foregroundStyle(Theme.secondaryText).padding(.vertical, 6)
            }
            ForEach(items.prefix(5)) { a in
                Button { model.openAssignment(a.id) } label: { AssignmentLine(a: a, courses: courses, now: now) }.buttonStyle(.plain)
            }
            if items.count > 5 {
                Button("\(items.count - 5) more") { model.go(.assignments) }.buttonStyle(.borderless).font(.stSmall)
            }
        }
    }
}

struct AssignmentLine: View {
    @Environment(AppModel.self) var model
    var a: Assignment
    var courses: [Int: Course]
    var now: Date = Date()

    var body: some View {
        let overdue = a.isOverdue(now: now)
        let within48 = (a.dueAt.map { $0.timeIntervalSince(now) < 48 * 3600 && $0 > now } ?? false) && a.isOpen
        HStack(spacing: 10) {
            CourseDot(color: a.courseId.flatMap { courses[$0]?.color })
            if a.kind == .exam { Image(systemName: "exclamationmark.square").foregroundStyle(Theme.secondaryText).accessibilityLabel("Exam") }
            Text(a.title).font(.stBody).lineLimit(1)
            if let c = a.courseId.flatMap({ courses[$0] }) { Text(c.displayName).font(.stSmall).foregroundStyle(Theme.tertiaryText) }
            Spacer()
            if let w = a.weightPct { Chip(text: Formatters.percent(w)) }
            HStack(spacing: 4) {
                if overdue { Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Overdue") }
                Text(overdue ? "Overdue · \(a.dueAt.map { Formatters.dayTime($0, tz: model.tz) } ?? "")" : Formatters.due(a.dueAt, tz: model.tz, now: now))
            }
            .font(.stSmall).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(overdue || within48 ? Theme.accent : Theme.secondaryText)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
        .contentShape(Rectangle())
    }
}

struct OnboardingCard: View {
    @Environment(AppModel.self) var model
    @State private var loading = false
    var body: some View {
        Panel(padding: 24) {
            Text("Set up in three steps").font(.stHeading)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Add your timetable", "Import an .ics file from Outlook or subscribe to a calendar link, or connect Moodle.")
                step(2, "Drop in your lecture slides", "Drag PowerPoint or PDF files onto this window or into ~/StudyTracker/Inbox.")
                step(3, "Connect Claude", "One click in Connections › Claude lets Claude Desktop read your lectures and save concepts back here.")
            }
            HStack {
                Button("Open Connections") { model.go(.connections(nil)) }.buttonStyle(PrimaryButtonStyle())
                Button(loading ? "Loading…" : "Try it with sample data") {
                    loading = true
                    do { try SampleData.load(model.store); model.refresh(); model.show("Sample term, courses, classes and a lecture were added. Remove them any time in Settings › Data and export.") }
                    catch { model.fail(error) }
                    loading = false
                }.buttonStyle(QuietButtonStyle())
            }.padding(.top, 6)
        }
    }

    func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.stBodyStrong).frame(width: 24, height: 24).background(Circle().fill(Theme.subtleFill))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.stBodyStrong)
                Text(detail).font(.stBody).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
