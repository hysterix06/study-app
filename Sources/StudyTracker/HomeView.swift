import SwiftUI
import StudyCore

/// The whole app on one screen: what's due this week, and each course as a book.
struct HomeView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                HomeContent { path.append($0) }
                    .padding(.horizontal, 40)
                    .padding(.top, 36)
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity)
            }
            .navigationDestination(for: Int.self) { id in BookView(courseId: id) { path.append(ChapterRoute(courseId: id, chapterId: $0)) } }
            .navigationDestination(for: ChapterRoute.self) { r in ChapterView(courseId: r.courseId, chapterId: r.chapterId) }
        }
    }
}

struct ChapterRoute: Hashable { let courseId: Int; let chapterId: Int }

struct HomeContent: View {
    @Environment(AppModel.self) var model
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            header
            if model.moodleSite == nil || model.needsSignIn {
                ConnectMoodleCard()
            } else if model.engineChoice == nil && !model.engineDeclined {
                WriteBooksCard()
            }
            if model.moodleSite != nil {
                thisWeek
                books
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.serif(30, weight: .semibold))
            Spacer()
            SyncStatus()
        }
    }

    // MARK: This week

    var thisWeek: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("This week")
            if model.deadlines.isEmpty {
                Text(model.syncing && model.lastSync == nil ? "Looking for deadlines…" : "Nothing due in the next 7 days.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.deadlines) { d in DeadlineRow(deadline: d, course: model.course(d.courseId)) }
                }
            }
        }
    }

    // MARK: Books

    var books: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Books")
            if model.courses.isEmpty {
                Text(model.syncing ? "Finding this term's courses…" : "No courses yet.").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 22, lineSpacing: 26) {
                    ForEach(model.courses) { c in
                        Button { open(c.id) } label: { BookCover(course: c, progress: bookProgress(c)) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Hide this course") { model.setHidden(c, true) }
                            }
                    }
                }
            }
        }
    }
}

extension HomeContent {
    /// "3 of 9 chapters", "Planning…", or nothing before the books are started.
    func bookProgress(_ c: Course) -> String? {
        let _ = model.revision
        switch c.tocStatus {
        case "writing": return "Planning…"
        case "ready":
            let chs = model.store.chapters(courseId: c.id)
            let ready = chs.filter(\.isReady).count
            return ready == chs.count ? "\(ready) chapters" : "\(ready) of \(chs.count) chapters"
        case "failed": return "Couldn't plan"
        default: return model.engineChoice == nil ? nil : "Waiting to start"
        }
    }
}

/// Lays children out left to right, wrapping onto new lines, like books on shelves.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct DeadlineRow: View {
    let deadline: Deadline
    let course: Course?

    var overdue: Bool { (deadline.dueAt ?? .distantFuture) < Date() }

    var body: some View {
        Button {
            if let s = deadline.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(overdue ? "Overdue" : deadline.dueAt.map { Format.day($0) } ?? "")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(overdue ? Color.red : Color.primary)
                    .frame(width: 92, alignment: .leading)
                Circle().fill(Color.course(course?.color ?? 0)).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(deadline.title).font(.body)
                    Text(course?.title ?? "").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let due = deadline.dueAt { Text(Format.time(due)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(deadline.url == nil ? "" : "Open in Moodle")
        Divider()
    }
}

/// A course as a book on a shelf: its colour, its title in a serif, its code, and how far along it is.
struct BookCover: View {
    let course: Course
    var progress: String? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.white.opacity(0.35)).frame(width: 26, height: 2).padding(.bottom, 14)
            Text(course.title)
                .font(.serif(17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(6)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if let progress {
                Text(progress).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9)).padding(.bottom, 4)
            }
            if let code = course.code {
                Text(code).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .frame(width: 168, height: 228, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.cover(course.color).gradient)
        )
        .overlay(alignment: .leading) {
            // The spine.
            Rectangle().fill(.black.opacity(0.18)).frame(width: 7)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, style: .continuous))
        }
        .shadow(color: .black.opacity(hover ? 0.28 : 0.16), radius: hover ? 10 : 5, y: hover ? 6 : 3)
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }
}

struct SyncStatus: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
                if model.syncing {
                    ProgressView().controlSize(.small)
                    Text(model.progress ?? "Syncing…")
                } else if let last = model.lastSync {
                    Text("Synced \(Format.relative.localizedString(for: last, relativeTo: Date()))")
                        .help(model.lastStatus ?? "")
                }
            }
            if let until = model.books.pausedUntil, until > Date() {
                Text("Books paused until \(Format.time(until))").help(model.books.pausedReason ?? "")
            } else if let writing = model.books.writing {
                Text("Writing \(writing)…")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
