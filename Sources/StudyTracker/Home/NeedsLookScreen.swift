import SwiftUI
import StudyCore

/// The one place things wait for the student, one decision per row, each with a sensible default. The count on Home and
/// in the sidebar is the number of rows here.
struct NeedsLookScreen: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let _ = model.revision
        let items = model.store.needsLook()
        let failed = model.store.jobsNeedingAttention().filter { $0.state == .failed && !$0.isQuiet }
        let expired = model.store.boolSetting("moodle_needs_signin")
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Needs a look").font(.stTitle)
                if items.isEmpty && failed.isEmpty && !expired {
                    EmptyState(text: "Nothing needs you. Files sort themselves, and deadlines from Moodle and your syllabi come straight in.")
                }
                if expired {
                    row(title: "Moodle sign-in expired", detail: "Sign in again so new files and deadlines keep coming.") {
                        Button("Sign in") { model.go(.settings(.connections)) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                ForEach(items) { item in NeedsLookRow(item: item) }
                ForEach(failed) { job in
                    row(title: job.label, detail: job.error ?? "This AI task failed.") {
                        Button("Dismiss") { model.jobs.cancel(job.id) }.buttonStyle(QuietButtonStyle())
                        Button("Try again") { model.jobs.retry(job.id) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(28).contentWidth()
        }
    }

    func row<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.stBodyStrong).lineLimit(2)
                Text(detail).font(.stSmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.surface))
    }
}

struct NeedsLookRow: View {
    @Environment(AppModel.self) var model
    var item: NeedsLookItem
    @State private var courseId: Int?

    var body: some View {
        let store = model.store
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let c = item.courseId.flatMap({ store.course($0) }), item.kind != .unfiledFile { CourseDot(color: c.color) }
                    Text(item.title).font(.stBodyStrong).lineLimit(2)
                }
                Text(item.detail).font(.stSmall).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions
        }
        .padding(12).background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.surface))
        .onAppear { courseId = item.courseId }
    }

    @ViewBuilder var actions: some View {
        let store = model.store
        switch item.kind {
        case .unfiledFile:
            if let id = item.objectId {
                Picker("", selection: $courseId) {
                    Text("Choose a course").tag(Int?.none)
                    ForEach(store.courses()) { c in Text(c.displayName).tag(Int?.some(c.id)) }
                }.labelsHidden().frame(width: 200)
                Button("Remove") { model.run("Deleted the file.") { try store.trashMaterial(id) } }.buttonStyle(QuietButtonStyle())
                Button("File it") {
                    guard let c = courseId else { return }
                    model.run("Filed.", link: ("Open", .material(id))) { try store.confirmMaterial(id, courseId: c); model.jobs.readNewFiles(); return nil }
                }.buttonStyle(PrimaryButtonStyle()).disabled(courseId == nil)
            }
        case .unsureFile:
            if let id = item.objectId, let m = store.material(id) {
                UseChip(file: m)
                Button("Looks right") { model.run { try store.confirmSort(id); return nil } }.buttonStyle(PrimaryButtonStyle())
            }
        case .proposedDeadline:
            if let id = item.objectId {
                Button("Dismiss") { model.run("Dismissed.") { try store.dismissProposedUndoable(id) } }.buttonStyle(QuietButtonStyle())
                Button("Add") { model.run("Added to your deadlines.") { try store.confirmProposed(id, courseId: item.courseId); return nil } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .conflict:
            if let id = item.objectId {
                Button("Keep mine") { model.run { try store.resolveConflict(id, acceptIncoming: false); return nil } }.buttonStyle(QuietButtonStyle())
                Button("Take the new one") { model.run { try store.resolveConflict(id, acceptIncoming: true); return nil } }.buttonStyle(PrimaryButtonStyle())
            }
        case .oldProposedCards:
            Button("Let them go") { model.run { try store.resolveOldProposedCards(keep: false); return nil } }.buttonStyle(QuietButtonStyle())
            Button("Keep them") { model.run("Added to your reviews.") { try store.resolveOldProposedCards(keep: true); return nil } }.buttonStyle(PrimaryButtonStyle())
        }
    }
}
