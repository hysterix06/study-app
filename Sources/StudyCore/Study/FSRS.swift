import Foundation

/// FSRS-5 (Free Spaced Repetition Scheduler) with default parameters and short learning steps.
/// Deterministic: no interval fuzz, so tests with fixed dates are exact.
public enum CardState: Int, Codable { case new = 0, learning = 1, review = 2, relearning = 3
    public var label: String {
        switch self { case .new: return "New"; case .learning: return "Learning"; case .review: return "Review"; case .relearning: return "Relearning" }
    }
}

public enum Rating: Int, CaseIterable, Codable {
    case again = 1, hard, good, easy
    public var label: String {
        switch self { case .again: return "Again"; case .hard: return "Hard"; case .good: return "Good"; case .easy: return "Easy" }
    }
}

public struct FSRSCard: Codable, Hashable {
    public var stability: Double = 0
    public var difficulty: Double = 0
    public var reps: Int = 0
    public var lapses: Int = 0
    public var state: CardState = .new
    public var lastReview: Date? = nil
    public var scheduledDays: Double = 0

    public init() {}

    public func encode() -> String {
        var d: [String: Any] = ["stability": stability, "difficulty": difficulty, "reps": reps, "lapses": lapses,
                                "state": state.rawValue, "scheduled_days": scheduledDays]
        if let lastReview { d["last_review"] = ISO.instant(lastReview) }
        return JSON.string(d)
    }

    public static func decode(_ s: String?) -> FSRSCard? {
        guard let d = JSON.parse(s) as? [String: Any] else { return nil }
        var c = FSRSCard()
        c.stability = (d["stability"] as? NSNumber)?.doubleValue ?? 0
        c.difficulty = (d["difficulty"] as? NSNumber)?.doubleValue ?? 0
        c.reps = (d["reps"] as? NSNumber)?.intValue ?? 0
        c.lapses = (d["lapses"] as? NSNumber)?.intValue ?? 0
        c.state = CardState(rawValue: (d["state"] as? NSNumber)?.intValue ?? 0) ?? .new
        c.scheduledDays = (d["scheduled_days"] as? NSNumber)?.doubleValue ?? 0
        c.lastReview = (d["last_review"] as? String).flatMap { ISO.parse($0) }
        return c
    }
}

public struct FSRSResult {
    public var card: FSRSCard
    public var due: Date
    public var interval: TimeInterval { due.timeIntervalSince(reviewedAt) }
    public var reviewedAt: Date
}

public struct FSRS {
    public static let defaultWeights: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]
    public var w: [Double]
    public var requestRetention: Double
    public var maximumInterval: Double

    static let decay = -0.5
    static let factor = 19.0 / 81.0

    public init(weights: [Double] = FSRS.defaultWeights, requestRetention: Double = 0.9, maximumInterval: Double = 36500) {
        self.w = weights; self.requestRetention = requestRetention; self.maximumInterval = maximumInterval
    }

    public func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(1 + FSRS.factor * t / s, FSRS.decay)
    }

    func nextIntervalDays(_ s: Double) -> Double {
        let ivl = s / FSRS.factor * (pow(requestRetention, 1 / FSRS.decay) - 1)
        return min(max(ivl.rounded(), 1), maximumInterval)
    }

    func initStability(_ r: Rating) -> Double { max(w[r.rawValue - 1], 0.1) }
    func initDifficulty(_ r: Rating) -> Double { clampD(w[4] - exp(w[5] * Double(r.rawValue - 1)) + 1) }
    func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }

    func nextDifficulty(_ d: Double, _ r: Rating) -> Double {
        let delta = -w[6] * Double(r.rawValue - 3)
        let damped = d + delta * (10 - d) / 9
        return clampD(w[7] * initDifficulty(.easy) + (1 - w[7]) * damped)
    }

    func recallStability(d: Double, s: Double, r: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus)
    }

    func forgetStability(d: Double, s: Double, r: Double) -> Double {
        let f = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(f, s)
    }

    func shortTermStability(_ s: Double, _ rating: Rating) -> Double {
        s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
    }

    /// All four outcomes, so buttons can show the next interval and ordering (hard ≤ good < easy) holds.
    public func preview(_ card: FSRSCard, now: Date) -> [Rating: FSRSResult] {
        var out: [Rating: FSRSResult] = [:]
        switch card.state {
        case .new:
            for rating in Rating.allCases {
                var c = card
                c.stability = initStability(rating)
                c.difficulty = initDifficulty(rating)
                c.reps += 1
                c.lastReview = now
                if rating == .easy {
                    c.state = .review
                    let days = nextIntervalDays(c.stability)
                    c.scheduledDays = days
                    out[rating] = FSRSResult(card: c, due: now.adding(days: days), reviewedAt: now)
                } else {
                    c.state = .learning
                    c.scheduledDays = 0
                    let mins = [1, 5, 10][rating.rawValue - 1]
                    out[rating] = FSRSResult(card: c, due: now.adding(minutes: mins), reviewedAt: now)
                }
            }
        case .learning, .relearning:
            var goodDays = 0.0
            for rating in [Rating.again, .hard, .good, .easy] {
                var c = card
                c.stability = shortTermStability(card.stability, rating)
                c.difficulty = nextDifficulty(card.difficulty, rating)
                c.reps += 1
                c.lastReview = now
                switch rating {
                case .again:
                    c.scheduledDays = 0
                    out[rating] = FSRSResult(card: c, due: now.adding(minutes: 5), reviewedAt: now)
                case .hard:
                    c.scheduledDays = 0
                    out[rating] = FSRSResult(card: c, due: now.adding(minutes: 10), reviewedAt: now)
                case .good:
                    c.state = .review
                    goodDays = nextIntervalDays(c.stability)
                    c.scheduledDays = goodDays
                    out[rating] = FSRSResult(card: c, due: now.adding(days: goodDays), reviewedAt: now)
                case .easy:
                    c.state = .review
                    let days = max(nextIntervalDays(c.stability), goodDays + 1)
                    c.scheduledDays = days
                    out[rating] = FSRSResult(card: c, due: now.adding(days: days), reviewedAt: now)
                }
            }
        case .review:
            let elapsed = max(0, card.lastReview.map { now.timeIntervalSince($0) / 86400 } ?? 0)
            let r = retrievability(elapsedDays: elapsed, stability: card.stability)
            // Again
            var again = card
            again.difficulty = nextDifficulty(card.difficulty, .again)
            again.stability = forgetStability(d: card.difficulty, s: card.stability, r: r)
            again.lapses += 1
            again.reps += 1
            again.state = .relearning
            again.lastReview = now
            again.scheduledDays = 0
            out[.again] = FSRSResult(card: again, due: now.adding(minutes: 10), reviewedAt: now)

            var cards: [Rating: FSRSCard] = [:]
            for rating in [Rating.hard, .good, .easy] {
                var c = card
                c.difficulty = nextDifficulty(card.difficulty, rating)
                c.stability = recallStability(d: card.difficulty, s: card.stability, r: r, rating: rating)
                c.reps += 1
                c.state = .review
                c.lastReview = now
                cards[rating] = c
            }
            var hard = nextIntervalDays(cards[.hard]!.stability)
            var good = nextIntervalDays(cards[.good]!.stability)
            var easy = nextIntervalDays(cards[.easy]!.stability)
            hard = min(hard, good)
            good = max(good, hard + 1)
            easy = max(easy, good + 1)
            for (rating, days) in [(Rating.hard, hard), (.good, good), (.easy, easy)] {
                var c = cards[rating]!
                c.scheduledDays = days
                out[rating] = FSRSResult(card: c, due: now.adding(days: days), reviewedAt: now)
            }
        }
        return out
    }

    public func review(_ card: FSRSCard, rating: Rating, now: Date) -> FSRSResult {
        preview(card, now: now)[rating]!
    }

    /// "1 min", "10 min", "3 d", "2 mo".
    public static func formatInterval(_ seconds: TimeInterval) -> String {
        let m = seconds / 60
        if m < 60 { return "\(Int(m.rounded())) min" }
        let h = m / 60
        if h < 24 { return "\(Int(h.rounded())) h" }
        let d = h / 24
        if d < 30 { return "\(Int(d.rounded())) d" }
        if d < 365 { return String(format: "%.0f mo", d / 30) }
        return String(format: "%.1f y", d / 365)
    }
}
