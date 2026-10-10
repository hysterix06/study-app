import SwiftUI
import StudyCore

/// Cards to go through, one at a time: the warm-up of a topic session, or a review session.
@MainActor
@Observable
final class CardQueue {
    var cards: [Card]
    var index = 0
    var revealed = false
    var ratings: [Rating] = []
    /// Cards that moved to a longer interval: the summary's good news.
    var longer = 0
    var shownAt = Date()

    init(_ cards: [Card]) { self.cards = cards }

    var current: Card? { index < cards.count ? cards[index] : nil }
    var finished: Bool { index >= cards.count }
    var recalled: Int { ratings.filter { $0 != .again }.count }
}

/// One card: try to answer, reveal, then rate your own recall (keys 1–4). The rating is always the student's.
struct CardReviewer: View {
    @Environment(AppModel.self) var model
    var queue: CardQueue
    let fsrs = FSRS()

    var body: some View {
        if let card = queue.current {
            let course = model.store.course(card.courseId)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    CourseDot(color: course?.color)
                    Text(course?.displayName ?? "").font(.stSmall).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("\(queue.index + 1) of \(queue.cards.count)").font(.stSmall).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
                Text(card.front).font(.system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if queue.revealed {
                    Divider()
                    Text(card.back).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let l = card.sourceLocators { Text(l).font(.stSmall).foregroundStyle(Theme.textTertiary) }
                }
                Spacer(minLength: 12)
                if queue.revealed {
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
                    Button { queue.revealed = true } label: { Text("Show answer").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.space, modifiers: [])
                    Text("Try to answer first. Space reveals.").font(.stSmall).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    func rate(_ card: Card, _ r: Rating) {
        let ms = Int(Date().timeIntervalSince(queue.shownAt) * 1000)
        do {
            let before = card.fsrs.scheduledDays
            let result = try model.store.logReview(cardId: card.id, rating: r, durationMs: ms)
            if result.card.scheduledDays > before && result.card.state == .review { queue.longer += 1 }
            queue.ratings.append(r)
            queue.index += 1
            queue.revealed = false
            queue.shownAt = Date()
        } catch { model.fail(error) }
    }
}
