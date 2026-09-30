import SwiftUI
import Charts
import AppKit
import StudyCore
import UniformTypeIdentifiers

struct StudyScreen: View {
    @Environment(AppModel.self) var model
    var tab: StudySegment { if case .study(let s) = model.route { return s == .insights ? .insights : .lectures }; return .lectures }

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            HStack {
                Text("Study").font(.stTitle)
                Spacer()
                Picker("", selection: Binding(get: { tab }, set: { model.go(.study($0), replace: true) })) {
                    Text("Lecture").tag(StudySegment.lectures); Text("Insights").tag(StudySegment.insights)
                }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Button { model.startReview() } label: { Label("Review \(model.store.dueCount()) cards", systemImage: "rectangle.stack") }
                    .buttonStyle(QuietButtonStyle()).disabled(model.store.dueCount() == 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if tab == .insights { InsightsView() } else { LectureStudy() }
        }
    }
}

struct LectureStudy: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let store = model.store
        let lectures = store.materials(statuses: ["ready", "needs_ocr"]).filter { $0.courseId != nil && ($0.role == .lecture || $0.role == .reading) }
        let courses = store.courseMap()
        let current = model.studyMaterialId.flatMap { id in lectures.first { $0.id == id } } ?? lectures.first
        HStack(spacing: 0) {
            List(selection: Binding(get: { current?.id }, set: { model.studyMaterialId = $0 })) {
                ForEach(lectures) { m in
                    HStack(spacing: 8) {
                        CourseDot(color: m.courseId.flatMap { courses[$0]?.color })
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.title).font(.stBody).lineLimit(1)
                            Text(m.courseId.flatMap { courses[$0]?.displayName } ?? "").font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        if m.processedAt != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.textSecondary).font(.system(size: 11)).accessibilityLabel("Processed") }
                    }.tag(m.id)
                }
            }
            .frame(width: 260)
            Divider()
            if let m = current {
                ScrollView { StudyFlow(material: m).padding(24).contentWidth() }
            } else {
                EmptyState(text: "File a lecture under a course and it shows up here, ready to study.", actionTitle: "Go to Inbox") { model.go(.inbox(nil)) }
            }
        }
    }
}

/// Recall → Learn → Write → Test, with one action per step (§7.3 Study).
struct StudyFlow: View {
    @Environment(AppModel.self) var model
    let m: Material
    init(material: Material) { m = material }

    var body: some View {
        let store = model.store
        let course = m.courseId.flatMap { store.course($0) }
        let sessions = store.sessions(materialId: m.id, limit: 50)
        let concepts = store.concepts(materialId: m.id)
        let sheet = store.notes(materialId: m.id, kind: "cornell_sheet").first
        let captures = store.handwritingCaptures(materialId: m.id)
        let latestScore = sessions.first { ($0.itemsTotal ?? 0) > 0 }
        let recalled = latestScore.map { Double($0.itemsCorrect ?? 0) / Double(max($0.itemsTotal ?? 1, 1)) } ?? 0
        let done: (String) -> Bool = { kind in sessions.contains { $0.kind == kind } }
        let cardsForMaterial = store.cards(status: "active", materialId: m.id)
        // One primary action per screen (§2.5): the first step that isn't done.
        let current: Int = m.processedAt == nil ? 2 : (!done("recall") ? 1 : (captures.isEmpty ? 3 : 4))
        let style: (Int) -> AnyButtonStyle = { step in step == current ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()) }
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title).font(.stHeading)
                Text([course?.name, m.processedAt.map { "processed \(RelativeTime.describe($0))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.stBody).foregroundStyle(Theme.textSecondary)
            }
            if !concepts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Concepts recalled").font(.stSmallStrong); Spacer(); Text("\(Int(recalled * Double(concepts.count))) of \(concepts.count)").font(.stSmall).monospacedDigit() }
                    ProgressView(value: recalled).tint(Theme.course(course?.color))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                StepCard(n: 1, title: "Recall", detail: "Write what you remember before looking.", done: done("recall")) {
                    ClaudeButton(task: .recall) { model.jobs.run(.recall, material: m.id) }.buttonStyle(style(1))
                        .disabled(m.processedAt == nil).help(m.processedAt == nil ? "Process the lecture first so Claude can compare your recall" : "")
                }
                StepCard(n: 2, title: "Learn", detail: m.processedAt == nil ? "Claude reads the lecture and builds concepts, questions and your sheet." : "\(concepts.count) concepts, linked to their slides.", done: m.processedAt != nil) {
                    if m.processedAt == nil {
                        ClaudeButton(task: .process) { model.jobs.run(.process, material: m.id) }.buttonStyle(style(2))
                    } else if let c = course {
                        Button("Concepts") { model.openCourse(c.id, tab: .concepts) }.buttonStyle(style(2))
                    }
                }
                StepCard(n: 3, title: "Write", detail: "Fill the sheet by hand from memory, then photograph it for a gap check.", done: !captures.isEmpty) {
                    if let sheet {
                        Button("Print sheet") { model.exportSheet(sheet, print: true) }.buttonStyle(style(3))
                    }
                    Button("Check my notes") { model.handwritingMaterialId = m.id }
                        .buttonStyle(sheet == nil ? style(3) : AnyButtonStyle(QuietButtonStyle()))
                }
                StepCard(n: 4, title: "Test", detail: "\(cardsForMaterial.count) cards from this lecture. Mixed with others for interleaving.", done: done("quiz") || done("review")) {
                    Button("Start review") { model.startReview(courseId: m.courseId) }.buttonStyle(style(4))
                    ClaudeButton(task: .quiz) { model.jobs.run(.quiz, material: m.id) }.buttonStyle(.borderless).font(.stSmall)
                }
            }
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Sessions")
                    ForEach(sessions.prefix(8)) { s in
                        HStack(alignment: .top) {
                            Text(s.kind.capitalized).font(.stSmallStrong).frame(width: 90, alignment: .leading)
                            Text(s.summary ?? "").font(.stSmall).foregroundStyle(Theme.textSecondary).lineLimit(3)
                            Spacer()
                            Text(Formatters.day(s.startedAt, tz: model.tz)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            let reports = store.notes(materialId: m.id).filter { $0.kind != "cornell_sheet" }
            if !reports.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Gap reports and notes")
                    ForEach(reports.prefix(6)) { n in
                        DisclosureGroup {
                            Text(LocalizedStringKey(n.contentMd)).font(.stBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: { Text(n.title).font(.stBody) }
                    }
                }
            }
        }
    }
}

struct AnyButtonStyle: ButtonStyle {
    let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct StepCard<Actions: View>: View {
    var n: Int
    var title: String
    var detail: String
    var done: Bool
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(n)").font(.stSmallStrong).frame(width: 20, height: 20).background(Circle().fill(Theme.fillSubtle))
                Text(title).font(.stBodyStrong)
                Spacer()
                if done { Image(systemName: "checkmark").font(.stSmallStrong).foregroundStyle(Theme.textSecondary).accessibilityLabel("Done") }
            }
            Text(detail).font(.stSmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions()
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
    }
}

// MARK: - Review session

@Observable
final class ReviewSession: Identifiable {
    let id = UUID()
    var cards: [Card]
    var index = 0
    var revealed = false
    var ratings: [Rating] = []
    var longer = 0
    var courseId: Int?
    var sessionId: Int?
    var shownAt = Date()
    var finished = false

    init(cards: [Card], courseId: Int?, sessionId: Int?) { self.cards = cards; self.courseId = courseId; self.sessionId = sessionId }
    var current: Card? { index < cards.count ? cards[index] : nil }
}

struct ReviewView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var session: ReviewSession
    let fsrs = FSRS()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(session.finished ? "Session complete" : "Review").font(.stHeading)
                Spacer()
                if !session.finished { Text("\(session.index + 1) of \(session.cards.count)").font(.stBody).monospacedDigit().foregroundStyle(Theme.textSecondary) }
                Button("Close") { finish(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(session.index), total: Double(max(session.cards.count, 1))).tint(.primary)
            if session.finished { summary } else if let card = session.current { cardView(card) }
        }
        .padding(28).frame(width: 640, height: 480)
    }

    @ViewBuilder func cardView(_ card: Card) -> some View {
        let courses = model.store.courseMap()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) { CourseDot(color: courses[card.courseId]?.color); Text(courses[card.courseId]?.displayName ?? "").font(.stSmall).foregroundStyle(Theme.textTertiary) }
            Text(card.front).font(.system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if session.revealed {
                Divider()
                Text(card.back).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let l = card.sourceLocators { Text(l).font(.stSmall).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            if session.revealed {
                let preview = fsrs.preview(card.fsrs, now: Date())
                HStack(spacing: 10) {
                    ForEach(Rating.allCases, id: \.self) { r in
                        Button { rate(card, r) } label: {
                            VStack(spacing: 2) {
                                Text(r.label).font(.stBodyStrong)
                                Text(FSRS.formatInterval(preview[r]!.interval)).font(.stSmall).monospacedDigit().opacity(0.7)
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(r == .good ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
                        .keyboardShortcut(KeyEquivalent(Character("\(r.rawValue)")), modifiers: [])
                        .accessibilityLabel("\(r.label), next review in \(FSRS.formatInterval(preview[r]!.interval))")
                    }
                }
                Text("Keys 1–4 rate your own recall.").font(.stSmall).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
            } else {
                Button { session.revealed = true } label: { Text("Show answer").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.space, modifiers: [])
                Text("Try to answer first. Space reveals.").font(.stSmall).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Peak-end: finish on a specific, positive summary (§7.2).
    var summary: some View {
        let recalled = session.ratings.filter { $0 != .again }.count
        return VStack(spacing: 14) {
            Spacer()
            Text("You recalled \(recalled) of \(session.ratings.count).").font(.stTitle)
            Text("\(session.longer) card\(session.longer == 1 ? "" : "s") moved to longer intervals.").font(.stBody).foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack {
                let more = model.store.dueCount()
                if more > 0 {
                    Button("Continue with \(min(more, 20)) more") {
                        let next = model.store.reviewQueue(courseId: session.courseId, limit: 20)
                        session.cards = next; session.index = 0; session.revealed = false; session.finished = false; session.shownAt = Date()
                    }.buttonStyle(QuietButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.frame(maxWidth: .infinity)
    }

    func rate(_ card: Card, _ r: Rating) {
        let ms = Int(Date().timeIntervalSince(session.shownAt) * 1000)
        do {
            let before = card.fsrs.scheduledDays
            let result = try model.store.logReview(cardId: card.id, rating: r, durationMs: ms)
            if result.card.scheduledDays > before && result.card.state == .review { session.longer += 1 }
            session.ratings.append(r)
            session.index += 1
            session.revealed = false
            session.shownAt = Date()
            if session.index >= session.cards.count { finish() }
        } catch { model.fail(error) }
    }

    func finish() {
        guard !session.finished else { return }
        session.finished = session.index >= session.cards.count
        if let sid = session.sessionId {
            let recalled = session.ratings.filter { $0 != .again }.count
            try? model.store.endSession(sid, summary: "Reviewed \(session.ratings.count) cards; recalled \(recalled).", total: session.ratings.count, correct: recalled)
        }
        model.refresh()
    }
}

// MARK: - Handwriting capture

struct HandwritingSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var materialId: Int
    @State private var capture: HandwritingCapture?
    @State private var working = false

    var body: some View {
        let m = model.store.material(materialId)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Check handwritten notes").font(.stHeading)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(m?.title ?? "").font(.stBody).foregroundStyle(Theme.textSecondary)
            if let c = capture {
                let cov = JSON.parse(c.coverageJson) as? [String: Any] ?? [:]
                let covered = cov["covered"] as? [String] ?? []
                let missing = cov["missing"] as? [String] ?? []
                Text("Your notes mention \(covered.count) of \(covered.count + missing.count) concepts.").font(.stBodyStrong)
                if !missing.isEmpty {
                    Text("Not found in your notes: " + missing.joined(separator: ", ")).font(.stBody).foregroundStyle(Theme.textSecondary)
                }
                Text("This quick check only looks for concept names. Claude can read the photo and tell you what's right, partial or wrong.")
                    .font(.stSmall).foregroundStyle(Theme.textTertiary)
                HStack {
                    ClaudeButton(task: .reviewNotes) {
                        model.jobs.run(.reviewNotes, material: materialId)
                        dismiss()
                    }.buttonStyle(PrimaryButtonStyle())
                    Button("Show photo") { NSWorkspace.shared.open(model.store.paths.absolute(c.imagePath)) }.buttonStyle(QuietButtonStyle())
                }
                DisclosureGroup("Text read from your photo") { Text(c.ocrText).font(.stSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                ContinuityDropZone(working: working) { url in ingest(url) }
                    .frame(height: 220)
                Text("Photograph your sheet with your iPhone: right-click the box and choose Import from iPhone → Take Photo. Or drop a photo, or choose a file.")
                    .font(.stSmall).foregroundStyle(Theme.textSecondary)
                Button("Choose photo…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.image]
                    if p.runModal() == .OK, let u = p.url { ingest(u) }
                }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(24).frame(width: 560)
    }

    func ingest(_ url: URL) {
        working = true
        let store = model.store
        let id = materialId
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.addHandwritingCapture(materialId: id, imageURL: url) }
            DispatchQueue.main.async {
                working = false
                switch result {
                case .success(let c): capture = c; model.refresh()
                case .failure(let e): model.fail(e)
                }
            }
        }
    }
}

/// A drop target that also accepts Continuity Camera ("Import from iPhone") through the services menu.
struct ContinuityDropZone: NSViewRepresentable {
    var working: Bool
    var onImage: (URL) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onImage = onImage
        v.registerForDraggedTypes([.fileURL, .tiff, .png])
        let menu = NSMenu()
        menu.addItem(withTitle: "Choose Photo…", action: #selector(CaptureView.choose), keyEquivalent: "").target = v
        v.menu = menu
        return v
    }
    func updateNSView(_ v: CaptureView, context: Context) { v.working = working; v.onImage = onImage; v.needsDisplay = true }

    final class CaptureView: NSView, NSServicesMenuRequestor {
        var onImage: ((URL) -> Void)?
        var working = false
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke(); path.lineWidth = 1.5; path.stroke()
            let text = working ? "Reading your handwriting…" : "Drop a photo of your notes here"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }

        @objc func choose() {
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]
            if p.runModal() == .OK, let u = p.url { onImage?(u) }
        }

        // Continuity Camera.
        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
            if let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        func readSelection(from pboard: NSPasteboard) -> Bool {
            guard let image = NSImage(pasteboard: pboard), let tiff = image.tiffRepresentation else { return false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).tiff")
            guard (try? tiff.write(to: url)) != nil else { return false }
            onImage?(url)
            return true
        }
        func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let u = urls.first { onImage?(u); return true }
            return readSelection(from: sender.draggingPasteboard)
        }
    }
}

// MARK: - Insights (outcomes)

struct InsightsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let o = model.store.outcomes()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Is this working? These measure outcomes, not activity.").font(.stBody).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    stat("On-time rate", o.onTimeRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "\(o.missedDeadlines.count) missed this term")
                    stat("Card retention", o.retention30d.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "\(o.reviews30d) reviews in 30 days")
                    stat("Recalled within 48 h", o.processedLectures == 0 ? "—" : "\(o.recalledWithin48h)/\(o.processedLectures)", "processed lectures")
                }
                Panel {
                    SectionHeader(title: "Study minutes per week")
                    if o.minutesByWeek.allSatisfy({ $0.minutes == 0 }) {
                        Text("No study time logged yet. Reviews, Claude sessions and study blocks you mark done count here.")
                            .font(.stSmall).foregroundStyle(Theme.textSecondary)
                    }
                    Chart(o.minutesByWeek, id: \.weekStart) { w in
                        BarMark(x: .value("Week", w.weekStart.at(LocalTime(hour: 12, minute: 0), tz: model.tz), unit: .weekOfYear),
                                y: .value("Minutes", w.minutes))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(height: 160)
                    .accessibilityLabel("Study minutes for the last eight weeks")
                }
                if !o.gradeByCourse.isEmpty {
                    Panel {
                        SectionHeader(title: "Grades against targets")
                        ForEach(o.gradeByCourse, id: \.course.id) { g in
                            HStack {
                                CourseDot(color: g.course.color)
                                Text(g.course.displayName).font(.stBodyStrong).frame(width: 90, alignment: .leading)
                                Text(g.summary.currentOnScale.map { g.course.gradeScale.format($0) } ?? "—").monospacedDigit()
                                Text(g.course.targetGrade.map { "target \(g.course.gradeScale.format($0))" } ?? "").foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(g.summary.headline).font(.stSmall)
                                    .foregroundStyle(g.summary.state == .unreachable || g.summary.state == .componentFailed ? Theme.attention : Theme.textSecondary)
                            }.font(.stBody)
                        }
                    }
                }
                if !o.weakConcepts.isEmpty {
                    Panel {
                        SectionHeader(title: "Concepts flagged weak most often (30 days)")
                        ForEach(o.weakConcepts.prefix(8), id: \.concept.id) { w in
                            HStack {
                                Text(w.concept.name).font(.stBody)
                                Spacer()
                                Text("\(w.count)×").font(.stSmall).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                ClaudeButton(task: .explain) { model.jobs.run(.explain, concept: w.concept.id) }.buttonStyle(.borderless).font(.stSmall)
                            }
                        }
                    }
                }
                if !o.sessionsByKind.isEmpty {
                    Panel {
                        SectionHeader(title: "Techniques used")
                        HStack(spacing: 16) {
                            ForEach(o.sessionsByKind.sorted { $0.value > $1.value }, id: \.key) { k, v in
                                VStack { Text("\(v)").font(.stHeading).monospacedDigit(); Text(k.capitalized).font(.stSmall).foregroundStyle(Theme.textSecondary) }
                            }
                        }
                    }
                }
            }
            .padding(24).contentWidth()
        }
    }

    func stat(_ title: String, _ value: String, _ sub: String) -> some View {
        Panel {
            Text(title).font(.stSmall).foregroundStyle(Theme.textSecondary)
            Text(value).font(.stTitle).monospacedDigit()
            Text(sub).font(.stSmall).foregroundStyle(Theme.textTertiary)
        }
    }
}
