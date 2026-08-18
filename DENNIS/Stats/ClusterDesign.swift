//
//  ClusterDesign.swift
//  DENNIS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The design taxonomy for group-level cluster permutation testing, and the
//  enumeration of the rearrangements each design admits.
//
//  Maris & Oostenveld (2007) is written for designs whose exchangeable unit is
//  the *subject*. DENNIS's data model already has that shape — one averaged
//  `.mff` is one subject, `Study.factors` are between-subject, and
//  `Study.conditionFactors` are within-subject — so the design layer, not the
//  numerical core, is where this feature lives.
//
//  The organizing simplification: every between-subject and mixed design
//  reduces to *one* channel x time matrix per subject followed by an
//  independent-samples test, and every within-subject design reduces to *k*
//  matrices per subject followed by a paired or repeated-measures test. The
//  mixed (interaction) case therefore needs no new statistic — only a
//  `SubjectMeasure` that collapses the within-subject dimension first.
//
//  References (full citations in `References.swift`):
//    - Maris & Oostenveld (2007), J Neurosci Methods 164(1):177-190 — written
//      for designs whose exchangeable unit is the subject, which is why this
//      taxonomy is organized around subjects rather than trials.
//    - Winkler et al. (2014), NeuroImage 92:381-397 — exchangeability per
//      design; the basis for each case's permutation scheme.
//    - Anderson & ter Braak (2003), J Stat Comput Simul 73(2):85-113 — the
//      reason `mixedInteraction` is a difference score compared between groups
//      rather than a factorial model: there is no single agreed exact
//      permutation test for interactions in a mixed design.
//    - Ernst (2004), Statist Sci 19(4):676-685 — exhaustive enumeration, and
//      the exact p-value that follows from it.
//    - Phipson & Smyth (2010), SAGMB 9(1):39 — the Monte-Carlo p-value used
//      when the null is too large to enumerate.
//

import Foundation

// MARK: - Subject measure

/// What one subject contributes to a between-subject design: a single
/// condition, or a within-subject contrast collapsed to one `channels x
/// samples` matrix before the test runs.
nonisolated enum SubjectMeasure: Sendable, Equatable, Hashable {
    case condition(String)
    /// `A - B`, the difference score whose between-group comparison *is* the
    /// mixed within x between interaction.
    case difference(String, String)
    /// Unweighted average over the named conditions.
    case mean([String])

    /// Conditions a subject must have for this measure to be computable.
    var requiredConditions: [String] {
        switch self {
        case .condition(let name): return [name]
        case .difference(let a, let b): return [a, b]
        case .mean(let names): return names
        }
    }

    var label: String {
        switch self {
        case .condition(let name): return name
        case .difference(let a, let b): return "\(a) − \(b)"
        case .mean(let names): return "mean(\(names.joined(separator: ", ")))"
        }
    }

    var isValid: Bool {
        switch self {
        case .condition(let name): return !name.isEmpty
        case .difference(let a, let b): return !a.isEmpty && !b.isEmpty && a != b
        case .mean(let names): return names.count >= 2 && Set(names).count == names.count
        }
    }
}

// MARK: - Design

/// The designs DENNIS's data model can express, each with an exchangeability
/// scheme that is defensible without a mixed-model permutation argument.
nonisolated enum ClusterDesign: Sendable, Equatable {
    /// Two within-subject conditions, all subjects contribute both.
    /// Paired t on the differences; permutation = per-subject sign flip.
    case withinPairedT(conditionA: String, conditionB: String)

    /// k >= 3 within-subject conditions, all subjects contribute all.
    /// Repeated-measures F; permutation = relabel conditions within subject.
    case withinRepeatedF(conditions: [String])

    /// One measure compared across two between-subject groups. Independent t;
    /// permutation = shuffle group labels across subjects.
    case betweenT(measure: SubjectMeasure, groupA: String, groupB: String)

    /// One measure across k >= 3 between-subject groups. One-way F.
    case betweenF(measure: SubjectMeasure, groups: [String])

    /// The interaction: a within-subject difference score compared between
    /// groups. Statistically identical to `betweenT`/`betweenF` on a difference
    /// measure; kept as its own case so the UI can name it correctly.
    case mixedInteraction(measure: SubjectMeasure, groups: [String])

    /// Which analyzer runs this design.
    var statisticKind: ClusterStatisticKind {
        switch self {
        case .withinPairedT, .betweenT:
            return .t
        case .withinRepeatedF, .betweenF:
            return .f
        case .mixedInteraction(_, let groups):
            return groups.count == 2 ? .t : .f
        }
    }

    /// True when the exchangeable relabeling happens inside each subject.
    var isWithinSubject: Bool {
        switch self {
        case .withinPairedT, .withinRepeatedF: return true
        case .betweenT, .betweenF, .mixedInteraction: return false
        }
    }

    /// The between-subject groups compared, in order. Empty for within designs.
    var groupNames: [String] {
        switch self {
        case .withinPairedT, .withinRepeatedF: return []
        case .betweenT(_, let a, let b): return [a, b]
        case .betweenF(_, let groups), .mixedInteraction(_, let groups): return groups
        }
    }

    /// The within-subject conditions each subject must carry, in order. Empty
    /// for between designs (whose requirement comes from `measure`).
    var conditionNames: [String] {
        switch self {
        case .withinPairedT(let a, let b): return [a, b]
        case .withinRepeatedF(let conditions): return conditions
        case .betweenT, .betweenF, .mixedInteraction: return []
        }
    }

    var measure: SubjectMeasure? {
        switch self {
        case .withinPairedT, .withinRepeatedF: return nil
        case .betweenT(let measure, _, _),
             .betweenF(let measure, _),
             .mixedInteraction(let measure, _):
            return measure
        }
    }

    /// Every condition name a contributing subject must have.
    var requiredConditions: [String] {
        switch self {
        case .withinPairedT(let a, let b): return [a, b]
        case .withinRepeatedF(let conditions): return conditions
        case .betweenT(let measure, _, _),
             .betweenF(let measure, _),
             .mixedInteraction(let measure, _):
            return measure.requiredConditions
        }
    }

    var name: String {
        switch self {
        case .withinPairedT: return "Within-subject paired t"
        case .withinRepeatedF: return "Within-subject repeated-measures F"
        case .betweenT: return "Between-subject independent t"
        case .betweenF: return "Between-subject one-way F"
        case .mixedInteraction(_, let groups):
            return groups.count == 2
                ? "Mixed interaction (difference between two groups)"
                : "Mixed interaction (difference across groups)"
        }
    }

    var explanation: String {
        switch self {
        case .withinPairedT:
            return "Every subject contributes both conditions. The test runs on each subject's difference map; the null flips the sign of whole subjects, which is the only relabeling that leaves the subject's own mean level intact."
        case .withinRepeatedF:
            return "Every subject contributes all conditions. The subject main effect is partialled out and condition labels are shuffled only within a subject — shuffling across subjects would inflate the error term with between-subject variance."
        case .betweenT:
            return "Each subject is reduced to one map, then the two groups are compared. The null shuffles group membership across subjects, preserving the two group sizes."
        case .betweenF:
            return "Each subject is reduced to one map, then k groups are compared with a one-way ANOVA. The null shuffles group membership across all subjects."
        case .mixedInteraction:
            return "Each subject's within-subject difference score is compared between groups. This is the interaction, and it needs no mixed-model assumption: the difference collapses the within-subject dimension before any between-subject relabeling happens."
        }
    }

    var isValid: Bool {
        switch self {
        case .withinPairedT(let a, let b):
            return !a.isEmpty && !b.isEmpty && a != b
        case .withinRepeatedF(let conditions):
            return conditions.count >= 3 && Set(conditions).count == conditions.count
        case .betweenT(let measure, let a, let b):
            return measure.isValid && !a.isEmpty && !b.isEmpty && a != b
        case .betweenF(let measure, let groups):
            return measure.isValid && groups.count >= 3 && Set(groups).count == groups.count
        case .mixedInteraction(let measure, let groups):
            if case .condition = measure { return false }   // not an interaction
            return measure.isValid && groups.count >= 2 && Set(groups).count == groups.count
        }
    }
}

/// Which analyzer a design routes to.
nonisolated enum ClusterStatisticKind: String, CaseIterable, Identifiable, Sendable, Equatable {
    case t = "t"
    case f = "F"

    var id: String { rawValue }
    var symbol: String { self == .t ? "|t|" : "F" }
}

// MARK: - Rearrangements

/// The exchangeability scheme a design admits, expressed as something that can
/// be both counted and enumerated.
nonisolated enum ClusterRearrangementKind: Sendable, Equatable {
    /// One fair coin per subject: 2^n distinct sign patterns.
    case signFlip(unitCount: Int)
    /// Group labels shuffled across subjects with fixed group sizes:
    /// the multinomial n! / (n_1! ... n_k!).
    case groupLabels(sizes: [Int])
    /// Condition labels shuffled within each subject: (k!)^n.
    case withinUnitRelabel(conditionCount: Int, unitCount: Int)
}

/// How many rearrangements will actually be evaluated, and whether that
/// constitutes the complete null.
///
/// This matters far more at group N than it did at trial N. With 12 subjects a
/// paired design has only 2^12 = 4096 distinct sign flips, so requesting 10,000
/// permutations resamples a saturated null and the true p-value floor is
/// 1/4096, not 1/10001. At N = 8 the floor is 1/256. Reporting "p < .001" from
/// a design that cannot produce a p below .004 would be wrong.
nonisolated struct ClusterRearrangementPlan: Sendable, Equatable {
    /// Number of rearrangements evaluated.
    let count: Int
    /// True when `count` is the complete set of distinct rearrangements.
    let isExhaustive: Bool
    /// Exact total, when it fits in an `Int`.
    let totalCount: Int?
    /// Floating-point total, for display when the exact count overflows.
    let approximateTotal: Double
    /// One entry per evaluated rearrangement; non-nil exactly when exhaustive.
    /// Interpretation depends on the kind: sign bit, group label, or index into
    /// the lexicographic permutations of the conditions.
    let arrangements: [[Int]]?

    /// The smallest p-value this run can produce.
    var pValueFloor: Double {
        isExhaustive ? 1 / Double(count) : 1 / Double(count + 1)
    }

    /// One line for the results header, e.g.
    /// "4096 exhaustive rearrangements (complete null)".
    var summary: String {
        if isExhaustive {
            return "\(count.formatted(.number.grouping(.automatic))) exhaustive rearrangements (complete null)"
        }
        let total = totalCount.map { $0.formatted(.number.grouping(.automatic)) }
            ?? String(format: "%.1e", approximateTotal)
        return "\(count.formatted(.number.grouping(.automatic))) of \(total) sampled"
    }
}

nonisolated enum ClusterRearrangements {
    /// Refuse to materialize more than this many arrangements even if the
    /// requested permutation count is larger. Exhaustive enumeration is a
    /// correctness feature for *small* designs; past this point the Monte-Carlo
    /// null is indistinguishable anyway.
    static let enumerationCap = 200_000

    /// Total distinct rearrangements, or nil when it overflows `Int`.
    static func rearrangementCount(_ kind: ClusterRearrangementKind) -> Int? {
        switch kind {
        case .signFlip(let n):
            guard n >= 0, n < 62 else { return nil }
            return 1 << n
        case .groupLabels(let sizes):
            return multinomial(sizes)
        case .withinUnitRelabel(let k, let n):
            guard k >= 1, n >= 0, let perUnit = factorial(k) else { return nil }
            var total = 1
            for _ in 0..<n {
                let (product, overflow) = total.multipliedReportingOverflow(by: perUnit)
                if overflow { return nil }
                total = product
            }
            return total
        }
    }

    /// A `Double` approximation that survives the overflow cases, so the UI can
    /// still say "10,000 of 3.2e18 sampled".
    static func approximateRearrangementCount(_ kind: ClusterRearrangementKind) -> Double {
        switch kind {
        case .signFlip(let n):
            return pow(2, Double(max(n, 0)))
        case .groupLabels(let sizes):
            let total = sizes.reduce(0, +)
            var logTotal = logFactorial(total)
            for size in sizes { logTotal -= logFactorial(size) }
            return exp(logTotal)
        case .withinUnitRelabel(let k, let n):
            return exp(logFactorial(k) * Double(max(n, 0)))
        }
    }

    /// Decides between systematic enumeration and Monte-Carlo sampling, and
    /// materializes the arrangements when enumerating.
    static func plan(_ kind: ClusterRearrangementKind, requestedCount: Int) -> ClusterRearrangementPlan {
        let requested = max(requestedCount, 1)
        let total = rearrangementCount(kind)
        let approximate = approximateRearrangementCount(kind)

        if let total, total <= requested, total <= enumerationCap, total >= 1 {
            return ClusterRearrangementPlan(
                count: total,
                isExhaustive: true,
                totalCount: total,
                approximateTotal: approximate,
                arrangements: enumerate(kind)
            )
        }
        return ClusterRearrangementPlan(
            count: requested,
            isExhaustive: false,
            totalCount: total,
            approximateTotal: approximate,
            arrangements: nil
        )
    }

    /// Every distinct rearrangement, with the *identity* arrangement first.
    /// That ordering is what makes the exhaustive p-value correct: the observed
    /// data's own arrangement is a member of the enumerated null and must not
    /// be added to it a second time.
    static func enumerate(_ kind: ClusterRearrangementKind) -> [[Int]] {
        switch kind {
        case .signFlip(let n):
            guard n >= 0, n < 31 else { return [] }
            return (0..<(1 << n)).map { mask in
                (0..<n).map { (mask >> $0) & 1 }
            }
        case .groupLabels(let sizes):
            return groupAssignments(sizes: sizes)
        case .withinUnitRelabel(let k, let n):
            guard let perUnit = factorial(k), perUnit > 0, n >= 0 else { return [] }
            var result: [[Int]] = []
            var current = [Int](repeating: 0, count: n)
            var counter = 0
            var total = 1
            for _ in 0..<n { total *= perUnit }
            while counter < total {
                result.append(current)
                counter += 1
                // Odometer in base k!, least-significant subject first.
                var position = 0
                while position < n {
                    current[position] += 1
                    if current[position] < perUnit { break }
                    current[position] = 0
                    position += 1
                }
            }
            return result
        }
    }

    /// All distinct assignments of group labels to units with the given group
    /// sizes, in lexicographic order. The first is `[0,0,…,1,1,…]`, which is
    /// the observed assignment because units are laid out group by group.
    static func groupAssignments(sizes: [Int]) -> [[Int]] {
        let total = sizes.reduce(0, +)
        guard total > 0, sizes.allSatisfy({ $0 >= 0 }) else { return [] }
        var result: [[Int]] = []
        var current = [Int](repeating: 0, count: total)
        var remaining = sizes

        func recurse(_ position: Int) {
            if position == total {
                result.append(current)
                return
            }
            for group in remaining.indices where remaining[group] > 0 {
                remaining[group] -= 1
                current[position] = group
                recurse(position + 1)
                remaining[group] += 1
            }
        }
        recurse(0)
        return result
    }

    /// Lexicographic permutations of `0..<k`; index 0 is the identity.
    static func permutations(ofCount k: Int) -> [[Int]] {
        guard k >= 1, k <= 8 else { return k == 0 ? [[]] : [] }
        var result: [[Int]] = []
        var current: [Int] = []
        var used = [Bool](repeating: false, count: k)

        func recurse() {
            if current.count == k {
                result.append(current)
                return
            }
            for value in 0..<k where !used[value] {
                used[value] = true
                current.append(value)
                recurse()
                current.removeLast()
                used[value] = false
            }
        }
        recurse()
        return result
    }

    // MARK: - Counting helpers

    static func factorial(_ n: Int) -> Int? {
        guard n >= 0 else { return nil }
        var result = 1
        for value in 2...max(n, 2) where value <= n {
            let (product, overflow) = result.multipliedReportingOverflow(by: value)
            if overflow { return nil }
            result = product
        }
        return result
    }

    /// `C(n, k)`, computed multiplicatively so intermediate values stay small.
    static func binomial(_ n: Int, _ k: Int) -> Int? {
        guard n >= 0, k >= 0, k <= n else { return nil }
        let smaller = min(k, n - k)
        var result = 1
        for step in 1...max(smaller, 1) where step <= smaller {
            let (product, overflow) = result.multipliedReportingOverflow(by: n - smaller + step)
            if overflow { return nil }
            result = product / step
        }
        return result
    }

    /// `n! / (n_1! … n_k!)`, built as a chain of binomials for the same reason.
    static func multinomial(_ sizes: [Int]) -> Int? {
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 >= 0 }) else { return nil }
        var remaining = sizes.reduce(0, +)
        var result = 1
        for size in sizes {
            guard let choose = binomial(remaining, size) else { return nil }
            let (product, overflow) = result.multipliedReportingOverflow(by: choose)
            if overflow { return nil }
            result = product
            remaining -= size
        }
        return result
    }

    private static func logFactorial(_ n: Int) -> Double {
        guard n > 1 else { return 0 }
        return ClusterStatisticsDistributions.logGamma(Double(n) + 1)
    }
}
