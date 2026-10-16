import SwiftUI
import StudyCore

/// Flashcard review: a question, Space for the answer, then Forgot (←) or Got it (→). A forgotten card comes back at
/// the end of the sitting.
struct ReviewView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: ReviewSession?
    @State private var showing = false
    @State private var shownAt = Date()

    var body: some View {
        Group {
            if let session, let card = session.current {
                ReviewCard(card: card, course: model.course(card.courseId), left: session.queue.count, showing: showing,
                           flip: { showing = true }, answer: answer, close: { dismiss() })
            } else if let session {
                ReviewDone(answered: session.answered, next: model.store.nextDue(), close: { dismiss() })
            }
        }
        .frame(width: 640, height: 460)
        .onAppear {
            guard session == nil else { return }
            session = ReviewSession(cards: model.store.dueCards())
            shownAt = Date()
        }
        .onDisappear { model.reload() }
    }

    func answer(_ gotIt: Bool) {
        guard showing else { return }
        session?.answer(gotIt: gotIt, store: model.store, duration: Date().timeIntervalSince(shownAt))
        showing = false
        shownAt = Date()
    }
}

struct ReviewCard: View {
    let card: Card
    let course: Course?
    let left: Int
    let showing: Bool
    var flip: () -> Void = {}
    var answer: (Bool) -> Void = { _ in }
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) { KeyLabel("Close", key: "Esc") }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(left) left").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer(minLength: 16)
            VStack(spacing: 18) {
                Text(kicker).font(.label).tracking(1.4).foregroundStyle(Color.course(course?.color ?? 0))
                    .help(card.chapterTitle ?? "")
                Text(Card.plain(card.front)).font(.serif(26, weight: .semibold))
                if showing {
                    Rectangle().fill(.quaternary).frame(width: 40, height: 1)
                    Text(Card.plain(card.back)).font(.serif(20))
                }
            }
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
            Spacer(minLength: 16)
            HStack(spacing: 14) {
                if showing {
                    Button { answer(false) } label: { KeyLabel("Forgot", key: "←") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { answer(true) } label: { KeyLabel("Got it", key: "→") }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.rightArrow, modifiers: [])
                } else {
                    Button(action: flip) { KeyLabel("Show answer", key: "Space") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.space, modifiers: [])
                }
            }
        }
        .padding(28)
    }

    /// "ECONOMICS · CHAPTER 5"
    var kicker: String {
        [course?.title, card.chapterPosition.map { "Chapter \($0)" }].compactMap { $0 }.joined(separator: " · ").uppercased()
    }
}

struct ReviewDone: View {
    let answered: Int
    let next: Date?
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(answered == 0 ? "No cards are due right now." : "That's all for now.").font(.serif(24, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close", action: close)
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var detail: String {
        let done = answered == 0 ? "" : "\(answered) card\(answered == 1 ? "" : "s") reviewed. "
        guard let next else { return done + "Cards from chapters you finish will show up here." }
        return done + "The next card is due \(Self.when(next))."
    }

    /// "in 9 minutes", "tomorrow", "on Thursday", "on Thu 29 Oct".
    static func when(_ date: Date, now: Date = Date()) -> String {
        if date.timeIntervalSince(now) < 12 * 3600 { return Format.relative.localizedString(for: date, relativeTo: now) }
        let day = Format.day(date, now: now)
        return Calendar.current.isDateInToday(date) || Calendar.current.isDateInTomorrow(date) ? day.lowercased() : "on \(day)"
    }
}

/// A button label with its key: "Got it  →".
struct KeyLabel: View {
    let title: String
    let key: String
    init(_ title: String, key: String) { self.title = title; self.key = key }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Text(key).font(.system(size: 11, weight: .medium)).opacity(0.6)
        }
    }
}

/// The app's few buttons: quiet by default, filled when it's the one to press.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(minWidth: 140)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
