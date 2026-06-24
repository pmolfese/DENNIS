//
//  PLS.swift
//  DENNIS
//
//  Partial Least Squares in the neuroimaging (McIntosh/Krishnan) sense: an SVD
//  of a cross-covariance between brain data and an experimental design. Built on
//  the same `Matrix`/LAPACK layer as the PCA and PARAFAC engines — it is a peer
//  of PARAFAC2, not a client of it. The only genuinely new machinery here is the
//  resampling layer (permutation tests on the singular values, bootstrap ratios
//  on the saliences), which the decomposition engines don't carry.
//
//  Mean-centered (task) PLS is implemented. Behavior and non-rotated (contrast)
//  PLS share the type surface but are reserved for a later pass.
//

import Foundation

/// The algorithmic family a method belongs to. PLS spans two paradigms that
/// share a name but not an algorithm.
nonisolated enum PLSFamily: String, Sendable {
    /// Symmetric SVD of a cross-covariance between two blocks. The entire Rotman
    /// neuroimaging toolbox (task / behavior / multiblock PLS) lives here.
    case correlation = "PLS-C"
    /// Asymmetric, predictive: regress Y on X via latent components
    /// (NIPALS/SIMPLS), yielding regression coefficients and cross-validated fit.
    case regression = "PLS-R"
}

/// The specific analysis. Numbered cases mirror `pls_analysis.m`'s
/// `option.method` 1–6; the trailing cases are families the toolbox doesn't
/// cover. `sparse` is a modifier (L1 feature selection) layered on a base
/// family rather than a standalone algorithm.
nonisolated enum PLSMethod: String, CaseIterable, Sendable {
    // MARK: PLS-Correlation family (toolbox methods 1–6)
    /// Mean-Centering Task PLS — toolbox method 1.
    case meanCentered = "Mean-centered task"
    /// Non-Rotated Task PLS — a priori contrast supplied as the design. Method 2.
    case nonRotatedTask = "Non-rotated task"
    /// Regular Behavior PLS — brain × behavior cross-correlation. Method 3.
    case behavior = "Behavior"
    /// Regular Multiblock PLS — task and behavior blocks together. Method 4.
    case multiblock = "Multiblock"
    /// Non-Rotated Behavior PLS — method 5.
    case nonRotatedBehavior = "Non-rotated behavior"
    /// Non-Rotated Multiblock PLS — method 6.
    case nonRotatedMultiblock = "Non-rotated multiblock"
    /// Generic two-block PLS-C / covariance PLS: SVD of the cross-covariance (or
    /// correlation) of arbitrary X and Y, outside the brain-vs-design framing.
    case covariance = "Covariance (two-block)"

    // MARK: PLS-Regression family
    /// Predictive PLS regression (NIPALS/SIMPLS) with cross-validated components.
    case regression = "Regression (predictive)"

    // MARK: Modifier
    /// Sparse PLS — an L1 penalty on the saliences/weights for feature selection.
    /// Built on top of a base family in a later pass.
    case sparse = "Sparse"

    var family: PLSFamily {
        switch self {
        case .regression: return .regression
        default: return .correlation
        }
    }

    /// One-line description of what running this method does, shown under the
    /// method picker.
    var blurb: String {
        switch self {
        case .meanCentered:
            return "Finds spatiotemporal patterns that maximally separate your conditions (and groups). No external variable needed."
        case .behavior:
            return "Finds brain patterns that covary with the loaded behavioral measures, correlated within each group × condition."
        case .multiblock:
            return "Analyzes task (condition) and behavior effects together in one decomposition. Needs a behavior CSV."
        case .nonRotatedTask:
            return "Tests a specific a priori contrast across conditions instead of a discovered pattern. (Not yet implemented.)"
        case .nonRotatedMultiblock:
            return "Multiblock against an a priori design. (Not yet implemented.)"
        case .nonRotatedBehavior:
            return "Behavior PLS against an a priori design. (Not yet implemented.)"
        case .covariance:
            return "Generic two-block covariance/correlation PLS on arbitrary X and Y. (Not yet implemented.)"
        case .regression:
            return "Predictive PLS regression — predicts Y from X via latent components. (Not yet implemented.)"
        case .sparse:
            return "Sparse PLS with L1 feature selection. (Not yet implemented.)"
        }
    }

    /// Toolbox `option.method` number, when this method has a direct analog.
    var toolboxMethod: Int? {
        switch self {
        case .meanCentered: return 1
        case .nonRotatedTask: return 2
        case .behavior: return 3
        case .multiblock: return 4
        case .nonRotatedBehavior: return 5
        case .nonRotatedMultiblock: return 6
        default: return nil
        }
    }
}

/// How the per-cell means are centered before the SVD in task/multiblock PLS.
/// Mirrors `pls_analysis.m`'s `option.meancentering_type` (applies to toolbox
/// methods 1, 2, 4, 6). Types 1 and 3 need more than one group to be meaningful.
nonisolated enum MeanCenteringType: Int, CaseIterable, Sendable {
    /// 0 — remove each group's mean (across its conditions) from its condition
    /// means. Boosts condition differences, removes overall group differences.
    case withinGroupCondition = 0
    /// 1 — remove the grand condition mean (across groups) from each group's
    /// condition mean. Boosts group differences, removes condition differences.
    case grandConditionAcrossGroups = 1
    /// 2 — remove the grand mean over all subjects and conditions. Full spectrum
    /// of condition and group effects.
    case grandMean = 2
    /// 3 — remove both group and condition main effects (two-way centering).
    /// Pure group × condition interaction.
    case interaction = 3

    var label: String {
        switch self {
        case .withinGroupCondition: return "Within-group condition (boost condition)"
        case .grandConditionAcrossGroups: return "Grand condition (boost group)"
        case .grandMean: return "Grand mean (full spectrum)"
        case .interaction: return "Remove main effects (interaction)"
        }
    }
}

/// The data + design handed to the engine. Rows of `data` are observations
/// (one per subject × condition); columns are features (channels × times). The
/// `*OfRow` arrays label each observation so the engine can form per-cell means
/// and resample within group/subject.
nonisolated struct PLSInput: Sendable {
    let data: Matrix
    var groupOfRow: [Int]
    var conditionOfRow: [Int]
    var subjectOfRow: [Int]
    let nGroups: Int
    let nConditions: Int
    let nSubjects: Int

    /// obs × measures — for behavior/multiblock methods.
    var behavior: Matrix?
    /// conditions × k — the a priori design for non-rotated methods.
    var contrasts: Matrix?
    /// Condition indices that feed the behavior block of multiblock PLS
    /// (toolbox `bscan`); nil = all conditions.
    var bscanConditions: [Int]? = nil

    var nFeatures: Int { data.cols }
    var nObservations: Int { data.rows }
    /// Rows of the design (cross-block) matrix: one per group × condition cell.
    var nDesignRows: Int { nGroups * nConditions }
}

/// Field names follow the Rotman `pls_analysis.m` result convention so output
/// can be cross-checked against the toolbox directly: `u` is the brain salience,
/// `v` the design salience, `usc` the brain scores, `s` the singular values.
nonisolated struct PLSResult: Sendable {
    let method: PLSMethod
    /// `s` — singular values, descending. `count == min(nDesignRows, nFeatures)`.
    let s: [Double]
    /// `u` — Brainlv / brain salience: features × L, the spatiotemporal pattern
    /// of each latent variable.
    let u: Matrix
    /// `v` — Designlv / design salience: (groups·conditions) × L, how each cell
    /// weights onto each LV.
    let v: Matrix
    /// `usc` — brain scores: observations × L, data projected onto `u`.
    let usc: Matrix
    /// Fraction of cross-block covariance carried by each LV (Σ = 1).
    let crossblockCovariance: [Double]

    /// Per-LV permutation p-value (toolbox `perm_result.sprob`); nil until run.
    var permutationP: [Double]?
    /// `compare_u` — features × L bootstrap ratios (`u` / bootstrap SE); nil
    /// until `bootstrapRatios` is run.
    var bootstrapRatios: Matrix?
}

nonisolated enum PLS {
    enum PLSError: Error { case empty, notImplemented(PLSMethod), dimensionMismatch }

    // MARK: - Decomposition

    /// Run the SVD-based decomposition for the requested method.
    static func decompose(
        _ input: PLSInput, method: PLSMethod,
        meanCentering: MeanCenteringType = .withinGroupCondition
    ) throws -> PLSResult {
        guard input.nObservations > 0, input.nFeatures > 0 else { throw PLSError.empty }
        switch method {
        case .meanCentered:
            return try core(input, method: method, centering: meanCentering)
        case .behavior, .multiblock:
            guard let beh = input.behavior,
                  beh.rows == input.nObservations, beh.cols > 0 else {
                throw PLSError.dimensionMismatch
            }
            return try core(input, method: method, centering: meanCentering)
        case .nonRotatedTask,
             .nonRotatedBehavior, .nonRotatedMultiblock,
             .covariance, .regression, .sparse:
            // Reserved: type surface accepts these so the UI and resampling
            // layer can be wired now; the math lands in a later pass.
            throw PLSError.notImplemented(method)
        }
    }

    /// Shared SVD core: build the method's cross-block matrix, decompose it, and
    /// package the result. `u` is the brain salience (feature side), `v` the
    /// design/behavior salience, `usc` the brain scores.
    private static func core(
        _ input: PLSInput, method: PLSMethod, centering: MeanCenteringType
    ) throws -> PLSResult {
        let crossblockMatrix = try crossblock(input, method: method, centering: centering)
        // X = svdU · diag(s) · svdVt; the brain salience is the feature side.
        let (svdU, s, svdVt) = try crossblockMatrix.svd()

        let u = svdVt.transposed()          // P × L   — brain salience
        let v = svdU                        // rows × L — design / behavior salience
        let usc = input.data.multiply(u)    // obs × L  — brain scores

        let total = s.reduce(0) { $0 + $1 * $1 }
        let crossblockCov = total > 0 ? s.map { ($0 * $0) / total } : s.map { _ in 0 }

        return PLSResult(
            method: method,
            s: s,
            u: u,
            v: v,
            usc: usc,
            crossblockCovariance: crossblockCov,
            permutationP: nil,
            bootstrapRatios: nil
        )
    }

    /// Singular values only, via the small Gram matrix `X·Xᵀ` (rows × rows)
    /// rather than a P-dimensional SVD — the cross-block has only `rows`
    /// non-zero singular values, and `rows` (G·C or G·C·B) is tiny next to the
    /// feature count P. This is the per-iteration kernel of the permutation test.
    private static func singularValues(
        _ input: PLSInput, method: PLSMethod, centering: MeanCenteringType
    ) throws -> [Double] {
        let m = try crossblock(input, method: method, centering: centering)   // rows × P
        let gram = m.multiply(m.transposed())                                 // rows × rows
        let (eigs, _) = try gram.symmetricEigen()
        return eigs.map { ($0 > 0 ? $0 : 0).squareRoot() }.sorted(by: >)
    }

    /// The matrix whose SVD drives each method: the centered cell-mean deviation
    /// for task PLS, or the stacked brain×behavior correlations for behavior PLS.
    private static func crossblock(
        _ input: PLSInput, method: PLSMethod, centering: MeanCenteringType
    ) throws -> Matrix {
        switch method {
        case .meanCentered:
            return deviationMatrix(input, centering: centering)
        case .behavior:
            return behaviorCorrelation(input, conditions: Array(0..<input.nConditions))
        case .multiblock:
            return multiblockMatrix(input, centering: centering)
        default:
            throw PLSError.notImplemented(method)
        }
    }

    /// Regular Multiblock PLS cross-block: per group, stack the task block (the
    /// centered cell means, as in method 1) above the behavior block (within-cell
    /// brain×behavior correlations, as in method 3). Each block is row-normalized
    /// to unit length first — `normalize(...,2)` in the toolbox — so the two
    /// blocks contribute on a comparable scale. Rows run group by group:
    /// `[g1 task; g1 behavior; g2 task; g2 behavior; …]`.
    private static func multiblockMatrix(_ input: PLSInput, centering: MeanCenteringType) -> Matrix {
        let bscan = behaviorConditions(input)
        let task = rowNormalized(deviationMatrix(input, centering: centering))          // (G·C) × P
        let behav = rowNormalized(behaviorCorrelation(input, conditions: bscan))        // (G·Cb·B) × P
        let G = input.nGroups, C = input.nConditions, P = input.nFeatures
        let Cb = bscan.count
        let B = input.behavior?.cols ?? 0

        var out = Matrix(rows: G * (C + Cb * B), cols: P)
        var dst = 0
        func copyRow(_ src: Matrix, _ srcRow: Int) {
            for p in 0..<P { out[dst, p] = src[srcRow, p] }
            dst += 1
        }
        for g in 0..<G {
            for c in 0..<C { copyRow(task, g * C + c) }
            for ci in 0..<Cb { for b in 0..<B { copyRow(behav, (g * Cb + ci) * B + b) } }
        }
        return out
    }

    /// Scale each row to unit Euclidean length; all-zero rows stay zero.
    private static func rowNormalized(_ m: Matrix) -> Matrix {
        var out = m
        for r in 0..<m.rows {
            var ss = 0.0
            for c in 0..<m.cols { ss += m[r, c] * m[r, c] }
            let norm = ss.squareRoot()
            guard norm > 0 else { continue }
            for c in 0..<m.cols { out[r, c] = m[r, c] / norm }
        }
        return out
    }

    /// Regular Behavior PLS cross-block: within each group × condition cell,
    /// the Pearson correlation of every behavior measure with every brain
    /// feature across that cell's subjects. Only the conditions in `conditions`
    /// are included (`bscan` for multiblock; all conditions otherwise). Blocks
    /// are stacked in "behavior in condition in group" order → (G·Cb·B) × P.
    private static func behaviorCorrelation(_ input: PLSInput, conditions: [Int]) -> Matrix {
        let beh = input.behavior!
        let B = beh.cols, P = input.nFeatures
        let G = input.nGroups, Cb = conditions.count
        var out = Matrix(rows: G * Cb * B, cols: P)

        for g in 0..<G {
            for (ci, c) in conditions.enumerated() {
                let rows = (0..<input.nObservations).filter {
                    input.groupOfRow[$0] == g && input.conditionOfRow[$0] == c
                }
                guard rows.count > 1 else { continue }

                // Standardized behavior columns for this cell (B × n).
                let behZ = (0..<B).map { b in standardize(rows.map { beh[$0, b] }) }
                // Standardize each feature across the cell's subjects, then the
                // correlation is the dot product / (n − 1).
                let denom = Double(rows.count - 1)
                for p in 0..<P {
                    let xZ = standardize(rows.map { input.data[$0, p] })
                    for b in 0..<B {
                        let zb = behZ[b]
                        var dot = 0.0
                        for k in 0..<rows.count { dot += zb[k] * xZ[k] }
                        out[(g * Cb + ci) * B + b, p] = dot / denom
                    }
                }
            }
        }
        return out
    }

    /// The behavior block's conditions: `bscanConditions` if set, else all.
    private static func behaviorConditions(_ input: PLSInput) -> [Int] {
        input.bscanConditions ?? Array(0..<input.nConditions)
    }

    /// Mean-center and scale to unit standard deviation; all-equal input → zeros.
    private static func standardize(_ values: [Double]) -> [Double] {
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let centered = values.map { $0 - mean }
        let variance = centered.reduce(0) { $0 + $1 * $1 } / max(n - 1, 1)
        let sd = variance.squareRoot()
        return sd > 0 ? centered.map { $0 / sd } : centered.map { _ in 0 }
    }

    /// The (G·C) × P matrix whose SVD drives task PLS: each row is the mean
    /// feature vector for a group × condition cell, centered per `centering`.
    /// With `M[g,c]` the cell means, `groupMean[g] = mean_c M[g,c]`,
    /// `condMean[c] = mean_g M[g,c]`, and `grand = mean_{g,c} M[g,c]`:
    ///   0  M[g,c] − groupMean[g]
    ///   1  M[g,c] − condMean[c]
    ///   2  M[g,c] − grand
    ///   3  M[g,c] − groupMean[g] − condMean[c] + grand
    private static func deviationMatrix(
        _ input: PLSInput, centering: MeanCenteringType
    ) -> Matrix {
        let cellMeans = cellMeanMatrix(input)     // (G·C) × P
        let G = input.nGroups, C = input.nConditions, P = input.nFeatures
        var dev = cellMeans

        for c in 0..<P {
            // Per-feature group means, condition means, and grand mean.
            var groupMean = [Double](repeating: 0, count: G)
            var condMean = [Double](repeating: 0, count: C)
            var grand = 0.0
            for g in 0..<G {
                for cond in 0..<C {
                    let v = cellMeans[g * C + cond, c]
                    groupMean[g] += v
                    condMean[cond] += v
                    grand += v
                }
            }
            for g in 0..<G { groupMean[g] /= Double(C) }
            for cond in 0..<C { condMean[cond] /= Double(G) }
            grand /= Double(G * C)

            for g in 0..<G {
                for cond in 0..<C {
                    let r = g * C + cond
                    switch centering {
                    case .withinGroupCondition:
                        dev[r, c] = cellMeans[r, c] - groupMean[g]
                    case .grandConditionAcrossGroups:
                        dev[r, c] = cellMeans[r, c] - condMean[cond]
                    case .grandMean:
                        dev[r, c] = cellMeans[r, c] - grand
                    case .interaction:
                        dev[r, c] = cellMeans[r, c] - groupMean[g] - condMean[cond] + grand
                    }
                }
            }
        }
        return dev
    }

    /// Average the observation rows within each group × condition cell. Missing
    /// cells (no contributing observations) stay zero.
    private static func cellMeanMatrix(_ input: PLSInput) -> Matrix {
        let P = input.nFeatures
        var means = Matrix(rows: input.nDesignRows, cols: P)
        var counts = [Int](repeating: 0, count: input.nDesignRows)
        for row in 0..<input.nObservations {
            let cell = input.groupOfRow[row] * input.nConditions + input.conditionOfRow[row]
            counts[cell] += 1
            for c in 0..<P { means[cell, c] += input.data[row, c] }
        }
        for cell in 0..<input.nDesignRows where counts[cell] > 0 {
            let inv = 1.0 / Double(counts[cell])
            for c in 0..<P { means[cell, c] *= inv }
        }
        return means
    }

    // MARK: - Inference

    /// Permutation test on the singular values. The null is built by reshuffling
    /// the brain–design link — condition labels within subject for task PLS, or
    /// the brain↔behavior subject pairing within group for behavior PLS — then
    /// re-running the decomposition. Each LV's p-value is the fraction of
    /// permutations whose singular value meets or exceeds the observed one.
    static func permutationTest(
        _ input: PLSInput, observed: PLSResult,
        meanCentering: MeanCenteringType = .withinGroupCondition,
        iterations: Int = 500, seed: UInt64 = 1,
        progress: PCAProgressHandler? = nil
    ) -> [Double] {
        let L = observed.s.count
        let method = observed.method
        let lock = NSLock()
        var exceed = [Int](repeating: 0, count: L)
        var done = 0
        let reportEvery = max(1, iterations / 100)

        // Iterations are independent: each gets its own seeded RNG so the run is
        // both parallelizable and reproducible. Only the singular values are
        // needed, so we take the fast Gram-matrix path (no P-dimensional SVD).
        DispatchQueue.concurrentPerform(iterations: iterations) { iter in
            var rng = SplitMix64(seed: seed &+ UInt64(iter) &* 0x9E3779B97F4A7C15)
            let permuted = method == .behavior
                ? permuteBehavior(input, rng: &rng)
                : permuteConditionLabels(input, rng: &rng)
            let s = (try? singularValues(permuted, method: method, centering: meanCentering)) ?? []

            lock.lock()
            for l in 0..<L where l < s.count {
                if s[l] >= observed.s[l] { exceed[l] += 1 }
            }
            done += 1
            let d = done
            lock.unlock()
            if d % reportEvery == 0 || d == iterations {
                progress?(Double(d) / Double(iterations), "Permutation \(d)/\(iterations)")
            }
        }

        let denom = Double(iterations + 1)
        return exceed.map { Double($0 + 1) / denom }
    }

    /// Bootstrap ratios for the brain saliences: subjects are resampled with
    /// replacement, the decomposition re-run, each bootstrap's saliences aligned
    /// to the observed ones by a Procrustes rotation, and the ratio is the
    /// observed salience divided by its bootstrap standard error.
    static func bootstrapRatios(
        _ input: PLSInput, observed: PLSResult,
        meanCentering: MeanCenteringType = .withinGroupCondition,
        iterations: Int = 500, seed: UInt64 = 7,
        progress: PCAProgressHandler? = nil
    ) -> Matrix {
        let P = observed.u.rows
        let L = observed.u.cols
        let method = observed.method
        let lock = NSLock()
        var sum = Matrix(rows: P, cols: L)
        var sumSq = Matrix(rows: P, cols: L)
        var n = 0
        var done = 0
        let reportEvery = max(1, iterations / 100)

        // Each replicate is independent (own seeded RNG). The SVD + Procrustes
        // run lock-free; only the accumulation into the shared sums is guarded.
        DispatchQueue.concurrentPerform(iterations: iterations) { iter in
            var rng = SplitMix64(seed: seed &+ UInt64(iter) &* 0x9E3779B97F4A7C15)
            let resampled = resampleSubjects(input, rng: &rng)
            let aligned = (try? core(resampled, method: method, centering: meanCentering))
                .map { procrustesAlign($0.u, to: observed.u) }

            lock.lock()
            if let aligned {
                for c in 0..<L {
                    for r in 0..<P {
                        let v = aligned[r, c]
                        sum[r, c] += v
                        sumSq[r, c] += v * v
                    }
                }
                n += 1
            }
            done += 1
            let d = done
            lock.unlock()
            if d % reportEvery == 0 || d == iterations {
                progress?(Double(d) / Double(iterations), "Bootstrap \(d)/\(iterations)")
            }
        }

        var ratios = Matrix(rows: P, cols: L)
        guard n > 1 else { return ratios }
        let invN = 1.0 / Double(n)
        for c in 0..<L {
            for r in 0..<P {
                let mean = sum[r, c] * invN
                let variance = max(0, sumSq[r, c] * invN - mean * mean)
                let se = (variance * Double(n) / Double(n - 1)).squareRoot()
                ratios[r, c] = se > 0 ? observed.u[r, c] / se : 0
            }
        }
        return ratios
    }

    // MARK: - Resampling helpers

    /// Shuffle condition assignments independently within each subject.
    private static func permuteConditionLabels(_ input: PLSInput, rng: inout SplitMix64) -> PLSInput {
        var conditionOfRow = input.conditionOfRow
        // Group rows by subject, then Fisher-Yates the condition labels among them.
        var rowsBySubject: [Int: [Int]] = [:]
        for row in 0..<input.nObservations {
            rowsBySubject[input.subjectOfRow[row], default: []].append(row)
        }
        for (_, rows) in rowsBySubject {
            var labels = rows.map { input.conditionOfRow[$0] }
            for i in stride(from: labels.count - 1, to: 0, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                labels.swapAt(i, j)
            }
            for (k, row) in rows.enumerated() { conditionOfRow[row] = labels[k] }
        }
        var out = input
        out.conditionOfRow = conditionOfRow
        return out
    }

    /// Resample whole subjects with replacement (within group), rebuilding the
    /// data matrix and the label arrays for the bootstrap replicate.
    private static func resampleSubjects(_ input: PLSInput, rng: inout SplitMix64) -> PLSInput {
        // Rows grouped by subject, and each subject's group.
        var rowsBySubject: [Int: [Int]] = [:]
        var groupBySubject: [Int: Int] = [:]
        for row in 0..<input.nObservations {
            let s = input.subjectOfRow[row]
            rowsBySubject[s, default: []].append(row)
            groupBySubject[s] = input.groupOfRow[row]
        }
        var subjectsByGroup: [Int: [Int]] = [:]
        for (s, g) in groupBySubject { subjectsByGroup[g, default: []].append(s) }

        var grid = [Double]()
        var behGrid = [Double]()
        var groupOfRow = [Int]()
        var conditionOfRow = [Int]()
        var subjectOfRow = [Int]()
        var newSubject = 0
        let P = input.nFeatures
        let beh = input.behavior
        let B = beh?.cols ?? 0

        for g in 0..<input.nGroups {
            let pool = (subjectsByGroup[g] ?? []).sorted()
            guard !pool.isEmpty else { continue }
            for _ in pool {
                let picked = pool[Int(rng.next() % UInt64(pool.count))]
                for row in rowsBySubject[picked] ?? [] {
                    for c in 0..<P { grid.append(input.data[row, c]) }   // row-major append
                    if let beh { for b in 0..<B { behGrid.append(beh[row, b]) } }
                    groupOfRow.append(g)
                    conditionOfRow.append(input.conditionOfRow[row])
                    subjectOfRow.append(newSubject)
                }
                newSubject += 1
            }
        }

        let nObs = groupOfRow.count
        // Grids were appended row-major; transpose into column-major Matrices.
        var data = Matrix(rows: nObs, cols: P)
        for r in 0..<nObs {
            for c in 0..<P { data[r, c] = grid[r * P + c] }
        }
        var behavior: Matrix?
        if beh != nil {
            var m = Matrix(rows: nObs, cols: B)
            for r in 0..<nObs {
                for b in 0..<B { m[r, b] = behGrid[r * B + b] }
            }
            behavior = m
        }
        return PLSInput(
            data: data,
            groupOfRow: groupOfRow,
            conditionOfRow: conditionOfRow,
            subjectOfRow: subjectOfRow,
            nGroups: input.nGroups,
            nConditions: input.nConditions,
            nSubjects: newSubject,
            behavior: behavior,
            contrasts: input.contrasts,
            bscanConditions: input.bscanConditions
        )
    }

    /// Behavior PLS null: within each group, shuffle which subject's behavior
    /// row is paired with which subject's brain data, keeping condition
    /// alignment. Breaks the brain–behavior correspondence under the null.
    private static func permuteBehavior(_ input: PLSInput, rng: inout SplitMix64) -> PLSInput {
        guard let beh = input.behavior else { return input }
        let B = beh.cols

        // Subjects per group, and each subject's (condition → row) map.
        var subjectsByGroup: [Int: [Int]] = [:]
        var rowOfSubjectCondition: [Int: [Int: Int]] = [:]
        for row in 0..<input.nObservations {
            let s = input.subjectOfRow[row], g = input.groupOfRow[row]
            if rowOfSubjectCondition[s] == nil { subjectsByGroup[g, default: []].append(s) }
            rowOfSubjectCondition[s, default: [:]][input.conditionOfRow[row]] = row
        }

        var permuted = beh
        for (_, subjectsRaw) in subjectsByGroup {
            let subjects = subjectsRaw.sorted()
            var shuffled = subjects
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                shuffled.swapAt(i, j)
            }
            // Subject `subjects[k]` receives subject `shuffled[k]`'s behavior,
            // matched condition-for-condition.
            for k in 0..<subjects.count {
                let dst = rowOfSubjectCondition[subjects[k]] ?? [:]
                let src = rowOfSubjectCondition[shuffled[k]] ?? [:]
                for (cond, dstRow) in dst {
                    guard let srcRow = src[cond] else { continue }
                    for b in 0..<B { permuted[dstRow, b] = beh[srcRow, b] }
                }
            }
        }
        var out = input
        out.behavior = permuted
        return out
    }

    /// Orthogonal Procrustes: rotate `boot` (P × L) onto `reference` (P × L) so
    /// bootstrap saliences are sign/rotation-aligned before accumulating SEs.
    private static func procrustesAlign(_ boot: Matrix, to reference: Matrix) -> Matrix {
        // R = reference' · boot ; SVD R = U S Vt ; rotation Q = U · Vt ; boot·Q.
        let cross = reference.transposed().multiply(boot)   // L × L
        guard let (u, _, vt) = try? cross.svd() else { return boot }
        let q = u.multiply(vt)                              // L × L
        return boot.multiply(q)
    }
}
