import SwiftUI
import StudyCore

/// A course's book: its contents, with this week's chapter marked, and what each chapter is waiting for.
struct BookView: View {
    @Environment(AppModel.self) var model
    let courseId: Int
    let openChapter: (Int) -> Void

    var body: some View {
        ScrollView {
            BookContent(courseId: courseId, openChapter: openChapter)
                .padding(.horizontal, 40)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.course(courseId)?.title ?? "")
    }
}

struct BookContent: View {
    @Environment(AppModel.self) var model
    let courseId: Int
    let openChapter: (Int) -> Void

    var body: some View {
        let _ = model.revision
        let course = model.course(courseId)
        let chapters = model.store.chapters(courseId: courseId)
        return VStack(alignment: .leading, spacing: 30) {
            header(course)
            if let course { status(course, chapters: chapters) }
            if !chapters.isEmpty { contents(chapters, current: currentIndex(chapters)) }
            BuiltFrom(courseId: courseId)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    func header(_ course: Course?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.course(course?.color ?? 0)).frame(width: 40, height: 3)
            Text(course?.title ?? "").font(.serif(34, weight: .semibold))
            if let code = course?.code { Text(code).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    func status(_ course: Course, chapters: [Chapter]) -> some View {
        switch course.tocStatus {
        case "ready":
            let ready = chapters.filter(\.isReady).count
            Text(ready == chapters.count ? "All \(chapters.count) chapters are written." :
                 "\(ready) of \(chapters.count) chapters written. The rest are written in the background, this week's first.")
                .foregroundStyle(.secondary)
        case "failed":
            HStack {
                Text("Couldn't plan this book: \(course.tocError ?? "unknown problem").").foregroundStyle(.secondary)
                Button("Try again") { model.retry(.toc(courseId: course.id)) }
            }
        case "writing":
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Planning the chapters…").foregroundStyle(.secondary) }
        default:
            Text(model.engineChoice == nil ? "Choose how books are written on Home, and this course's book starts."
                 : course.filesSyncedAt == nil ? "The book is planned once the syllabus has been read from Moodle."
                 : "Waiting its turn to be planned.")
                .foregroundStyle(.secondary)
        }
    }

    /// This week's chapter, when the term's weeks are known.
    func currentIndex(_ chapters: [Chapter]) -> Int? {
        guard let week = model.store.currentWeek(), chapters.contains(where: { $0.week != nil }) else { return nil }
        return chapters.lastIndex { ($0.week ?? .max) <= week }
    }

    func contents(_ chapters: [Chapter], current: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Contents").padding(.bottom, 10)
            ForEach(Array(chapters.enumerated()), id: \.element.id) { i, ch in
                Button {
                    model.open(ch)
                    openChapter(ch.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("\(ch.position)").font(.serif(22)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(ch.title).font(.serif(18, weight: .semibold)).foregroundStyle(.primary)
                                if i == current {
                                    Text("THIS WEEK").font(.system(size: 9, weight: .bold)).tracking(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.course(model.course(courseId)?.color ?? 0).opacity(0.18)))
                                }
                            }
                            if !ch.summary.isEmpty { Text(ch.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 12)
                        state(ch)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    @ViewBuilder
    func state(_ ch: Chapter) -> some View {
        switch ch.status {
        case "ready":
            if ch.readAt != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).help("Read") }
            else { Text("\(ch.words / 230 + 1) min").font(.callout).foregroundStyle(.secondary).help("Reading time") }
        case "writing":
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Writing…").font(.callout).foregroundStyle(.secondary) }
        case "failed":
            Button("Try again") { model.retry(.chapter(id: ch.id)) }.help(ch.error ?? "")
        default:
            Text("Not written yet").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

/// The course files a book is built from, collapsed.
struct BuiltFrom: View {
    @Environment(AppModel.self) var model
    let courseId: Int
    @State private var open = false

    var body: some View {
        let files = model.store.files(courseId: courseId)
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([("Syllabus", FileKind.syllabus), ("Lectures and readings", FileKind.lecture), ("Not used for the book", FileKind.other)], id: \.1) { label, kind in
                    let group = files.filter { $0.kind == kind }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(label)
                            ForEach(group) { f in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(f.title)
                                    if let s = f.section, s != f.title { Text(s).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(f.error != nil ? "Couldn't read" : f.text.isEmpty ? (kind == FileKind.other ? "" : "Not read yet") : "\(f.text.count / 1000)k characters")
                                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Built from \(files.filter { $0.kind != FileKind.other }.count) course files").foregroundStyle(.secondary)
        }
    }
}

/// The one-time choice of what writes the books. Shown on Home until made (or declined).
struct WriteBooksCard: View {
    @Environment(AppModel.self) var model
    @State private var key = ""
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let Claude write your books").font(.serif(22, weight: .semibold))
            Text("Each course becomes a book of about 8 to 14 chapters, one per topic on the syllabus, written in the background with this week's chapter first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.claudeCLI != nil {
                HStack(spacing: 12) {
                    Button("Use Claude Code") { model.choose(.claudeCode) }.keyboardShortcut(.defaultAction)
                    Text("Uses your Claude plan: about 150,000–200,000 tokens per course, spread over days.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Claude Code isn't on this Mac. Install it from claude.com/code and sign in, or use an Anthropic API key.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if showKey || model.claudeCLI == nil {
                HStack(spacing: 10) {
                    SecureField("Anthropic API key (sk-ant-…)", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Button("Use this key") { model.choose(.anthropic, apiKey: key) }.disabled(!key.hasPrefix("sk-ant-"))
                }
                Text("Charged to your Anthropic account: roughly $2–3 per course with Claude Opus 5.5.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if model.claudeCLI != nil && !showKey { Button("Use an API key instead") { showKey = true }.buttonStyle(.link) }
                Button("Not now") { model.declineBooks() }.buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }
}
