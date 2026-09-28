import Foundation

public struct GradeSummary: Equatable {
    public enum State: String { case noData = "no_data", secured, onTrack = "on_track", unreachable, componentFailed = "component_failed" }

    public var state: State
    public var scale: GradeScale
    public var earned: Double              // points of the final grade (percent points)
    public var gradedWeight: Double
    public var totalWeight: Double
    public var remainingWeight: Double
    public var currentAverage: Double?     // percent
    public var maxPossible: Double         // percent points
    public var requiredAverage: Double?    // percent needed on what is left
    public var targetPercent: Double?
    public var weightWarning: String?
    public var failedComponents: [Int]     // assignment ids below their minimum
    public var pendingMinimums: [(id: Int, title: String, minPct: Double)]
    public var pointsByAssignment: [Int: Double] // "worth X points of your final grade"

    public static func == (a: GradeSummary, b: GradeSummary) -> Bool {
        a.state == b.state && a.earned == b.earned && a.requiredAverage == b.requiredAverage && a.totalWeight == b.totalWeight
    }

    /// Current average expressed on the course's scale, e.g. 7.4 on a 0–10 scale.
    public var currentOnScale: Double? { currentAverage.map { scale.fromPercent($0) } }
    public var requiredOnScale: Double? { requiredAverage.map { scale.fromPercent(min(max($0, 0), 100)) } }

    public var headline: String {
        switch state {
        case .noData: return "No graded work yet."
        case .secured: return "Target secured."
        case .unreachable: return "Target is no longer reachable. Best possible: \(scale.format(scale.fromPercent(maxPossible)))."
        case .componentFailed: return "A component is below its minimum pass mark."
        case .onTrack:
            if let r = requiredAverage { return "You need \(String(format: "%.0f", max(r, 0)))% on average on what's left." }
            return "On track."
        }
    }

    public func asJSON() -> [String: Any] {
        var d: [String: Any] = [
            "state": state.rawValue, "scale": scale.rawValue, "earned_points": earned, "graded_weight": gradedWeight,
            "total_weight": totalWeight, "remaining_weight": remainingWeight, "max_possible_pct": maxPossible,
            "headline": headline, "failed_component_ids": failedComponents,
            "points_by_assignment": Dictionary(uniqueKeysWithValues: pointsByAssignment.map { (String($0.key), $0.value) }),
            "pending_minimums": pendingMinimums.map { ["assignment_id": $0.id, "title": $0.title, "min_pct": $0.minPct] },
        ]
        if let currentAverage { d["current_average_pct"] = currentAverage; d["current_on_scale"] = scale.fromPercent(currentAverage) }
        if let requiredAverage { d["required_average_pct"] = requiredAverage }
        if let targetPercent { d["target_pct"] = targetPercent; d["target_on_scale"] = scale.fromPercent(targetPercent) }
        if let weightWarning { d["weight_warning"] = weightWarning }
        return d
    }
}

public enum GradeError: Error, Equatable { case zeroMaxScore(assignmentId: Int) }

public enum GradeMath {
    /// §7.6 extended with grading scales and per-component minimums.
    /// `target` is in the course's scale units (e.g. 7 on 0–10).
    public static func summarize(assignments: [Assignment], target: Double?, scale: GradeScale = .percent) throws -> GradeSummary {
        let weighted = assignments.filter { $0.confirmed && !$0.dismissed && ($0.weightPct ?? 0) > 0 }
        for a in weighted where a.status == .graded {
            if let m = a.maxScore, m <= 0 { throw GradeError.zeroMaxScore(assignmentId: a.id) }
        }
        let graded = weighted.filter { $0.status == .graded && $0.score != nil && ($0.maxScore ?? 0) > 0 }
        let earned = graded.reduce(0.0) { $0 + ($1.score! / $1.maxScore! * $1.weightPct!) }
        let gradedWeight = graded.reduce(0.0) { $0 + $1.weightPct! }
        let totalWeight = weighted.reduce(0.0) { $0 + $1.weightPct! }
        let remaining = max(totalWeight - gradedWeight, 0)
        let targetPct = target.map { scale.toPercent($0) }

        var points: [Int: Double] = [:]
        for a in weighted {
            if let pct = a.scorePct, a.status == .graded { points[a.id] = pct / 100 * a.weightPct! } else { points[a.id] = a.weightPct! }
        }

        let failed = graded.filter { a in
            guard let min = a.minPassPct, let pct = a.scorePct else { return false }
            return pct < min
        }.map(\.id)
        let pending = weighted.filter { $0.status != .graded && $0.minPassPct != nil }.map { (id: $0.id, title: $0.title, minPct: $0.minPassPct!) }

        var warning: String?
        if totalWeight > 0 && abs(totalWeight - 100) > 0.01 {
            warning = "Weights add up to \(String(format: "%g", totalWeight))%, not 100%."
        }

        let current = gradedWeight > 0 ? earned / gradedWeight * 100 : nil
        let maxPossible = earned + remaining
        var required: Double?
        let state: GradeSummary.State

        if graded.isEmpty {
            state = .noData
            if let t = targetPct, remaining > 0 { required = t / remaining * 100 }
        } else if !failed.isEmpty {
            state = .componentFailed
        } else if let t = targetPct {
            if t <= earned { state = .secured }
            else if remaining <= 0 { state = .unreachable }
            else {
                let r = (t - earned) / remaining * 100
                required = r
                state = r > 100 ? .unreachable : .onTrack
            }
        } else {
            state = .onTrack
        }

        return GradeSummary(state: state, scale: scale, earned: earned, gradedWeight: gradedWeight, totalWeight: totalWeight,
                            remainingWeight: remaining, currentAverage: current, maxPossible: maxPossible,
                            requiredAverage: required, targetPercent: targetPct, weightWarning: warning,
                            failedComponents: failed, pendingMinimums: pending, pointsByAssignment: points)
    }
}
