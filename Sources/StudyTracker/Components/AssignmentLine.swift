import SwiftUI
import StudyCore

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
            if a.kind == .exam { Image(systemName: "exclamationmark.square").foregroundStyle(Theme.textSecondary).accessibilityLabel("Exam") }
            Text(a.title).font(.stBody).lineLimit(1)
            if let c = a.courseId.flatMap({ courses[$0] }) { Text(c.displayName).font(.stSmall).foregroundStyle(Theme.textTertiary) }
            Spacer()
            if let w = a.weightPct { Chip(text: Formatters.percent(w)) }
            HStack(spacing: 4) {
                if overdue { Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Overdue") }
                Text(overdue ? "Overdue · \(a.dueAt.map { Formatters.dayTime($0, tz: model.tz) } ?? "")" : Formatters.due(a.dueAt, tz: model.tz, now: now))
            }
            .font(.stSmall).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(overdue || within48 ? Theme.attention : Theme.textSecondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: Theme.corner(6)).fill(Theme.fillSubtle))
        .contentShape(Rectangle())
    }
}
extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
