//
//  PARAFAC.swift
//  DENNIS
//
//  CANDECOMP/PARAFAC (CP) decomposition by alternating least squares, native on
//  Accelerate. A rank-R CP model writes the tensor as a sum of R rank-1 terms,
//  each an outer product of one vector per mode (for the 4-way ERP tensor: a
//  topography × a time course × a condition loading × a subject loading). Unlike
//  PCA the solution is essentially unique — no rotation needed.
//
//  ALS, per Kolda & Bader (2009): for each mode n, A⁽ⁿ⁾ ← X₍ₙ₎ · KR · V⁺, where
//  KR is the Khatri-Rao product of the other factors and V is the Hadamard
//  product of their Gram matrices. The Khatri-Rao fold order matches
//  `MultiwayTensor.unfold` (ascending rest modes, smallest varying fastest).
//

import Accelerate

nonisolated struct CPResult: Sendable {
    /// One factor matrix per mode (Iₙ × R), columns unit-norm.
    let factors: [Matrix]
    /// Component weights λ (length R), descending — the magnitude of each rank-1
    /// term once the factors are normalized.
    let weights: [Double]
    let modeNames: [String]
    let dims: [Int]
    let rank: Int
    /// 1 − ‖X − X̂‖ / ‖X‖.
    let fit: Double
    let iterations: Int
    let nStarts: Int
    /// How many random starts reached (within tolerance of) the best fit — a
    /// stability indicator.
    let bestStartCount: Int
    /// Worst multi-cosine congruence between two components; → 1 signals a
    /// degenerate (collinear) solution.
    let maxCongruence: Double

    /// Per-component share of the model magnitude (λ² normalized), for display.
    var componentShare: [Double] {
        let total = weights.reduce(0) { $0 + $1 * $1 }
        guard total > 0 else { return weights.map { _ in 0 } }
        return weights.map { $0 * $0 / total }
    }
}

nonisolated enum PARAFAC {

    struct Options: Sendable {
        var rank: Int
        var maxIter = 500
        var tol = 1e-7
        var nStarts = 10
        var seed: UInt64 = 0
        /// Constrain all factors to be nonnegative (for raw power tensors), via
        /// HALS updates instead of the unconstrained normal-equations solve.
        var nonnegative = false
    }

    enum PARAFACError: Error, LocalizedError {
        case emptyTensor
        case rankTooLarge(rank: Int, max: Int)
        var errorDescription: String? {
            switch self {
            case .emptyTensor: "The tensor has no energy to decompose."
            case .rankTooLarge(let r, let m): "Rank \(r) exceeds the largest mode size \(m)."
            }
        }
    }

    private struct StartResult: Sendable {
        let start: Int
        let fit: Double
        let factors: [Matrix]
        let iterations: Int
    }

    /// Run multi-start CP-ALS and return the best (highest-fit) solution.
    static func decompose(_ tensor: MultiwayTensor,
                          modeNames: [String],
                          options: Options,
                          report: (@Sendable (Double, String) -> Void)? = nil) async throws -> CPResult {
        let n = tensor.order
        let dims = tensor.dims
        let r = options.rank
        let normX2 = tensor.frobeniusNormSquared
        guard normX2 > 0 else { throw PARAFACError.emptyTensor }
        guard r <= dims.max()! * 4 else { throw PARAFACError.rankTooLarge(rank: r, max: dims.max()!) }

        // Unfoldings are fixed; compute once and share across starts/iterations.
        let unfoldings = (0..<n).map { tensor.unfold(mode: $0) }

        let starts = max(options.nStarts, 1)
        var completedStarts = 0
        var candidates: [StartResult] = []

        await withTaskGroup(of: StartResult.self) { group in
            for start in 0..<starts {
                group.addTask {
                    var rng = SplitMix64(seed: seed(for: options.seed, start: start))
                    var factors = (0..<n).map {
                        randomMatrix(rows: dims[$0], cols: r, rng: &rng, nonnegative: options.nonnegative)
                    }
                    var prevFit = -Double.infinity
                    var fit = 0.0
                    var iters = 0

                    while iters < options.maxIter {
                        fit = sweep(&factors, unfoldings: unfoldings, normX2: normX2,
                                    nonnegative: options.nonnegative)
                        iters += 1
                        if fit - prevFit < options.tol { break }
                        prevFit = fit
                    }

                    return StartResult(start: start, fit: fit, factors: factors, iterations: iters)
                }
            }

            for await candidate in group {
                candidates.append(candidate)
                completedStarts += 1
                report?(Double(completedStarts) / Double(starts) * 0.96,
                        "ALS starts \(completedStarts)/\(starts)")
            }
        }

        let sorted = candidates.sorted {
            if abs($0.fit - $1.fit) > 1e-9 { return $0.fit > $1.fit }
            return $0.start < $1.start
        }
        guard let best = sorted.first else { throw PARAFACError.emptyTensor }
        let bestCount = candidates.filter { abs($0.fit - best.fit) <= 1e-6 }.count

        report?(0.97, "Normalizing components")
        var (factors, weights) = normalize(best.factors)
        sortByWeight(&factors, &weights)
        fixSigns(&factors)

        return CPResult(
            factors: factors, weights: weights, modeNames: modeNames, dims: dims, rank: r,
            fit: best.fit, iterations: best.iterations, nStarts: options.nStarts,
            bestStartCount: bestCount, maxCongruence: maxCongruence(factors)
        )
    }

    // MARK: - One ALS sweep (returns the fit afterward)

    private static func sweep(_ factors: inout [Matrix], unfoldings: [Matrix], normX2: Double,
                              nonnegative: Bool) -> Double {
        let n = factors.count
        var lastM = Matrix(rows: 0, cols: 0)

        for mode in 0..<n {
            let rest = (0..<n).filter { $0 != mode }
            // Khatri-Rao of the other factors (ascending fold → matches unfold).
            var kr = factors[rest[0]]
            for idx in 1..<rest.count { kr = khatriRao(factors[rest[idx]], kr) }
            let mttkrp = unfoldings[mode].multiply(kr)         // Iₙ × R

            // V = Hadamard of the other Gram matrices (R × R).
            var v = crossProduct(factors[rest[0]])
            for idx in 1..<rest.count { v = hadamard(v, crossProduct(factors[rest[idx]])) }

            if nonnegative {
                halsUpdate(&factors[mode], mttkrp: mttkrp, v: v)
            } else {
                let vInv = (try? v.pseudoinverse()) ?? v
                factors[mode] = mttkrp.multiply(vInv)
            }
            if mode == n - 1 { lastM = mttkrp }
        }

        // Fit via ‖X̂‖² = sum(⊛ all Grams), ⟨X,X̂⟩ = ⟨A_last, M_last⟩.
        var gAll = crossProduct(factors[0])
        for mode in 1..<n { gAll = hadamard(gAll, crossProduct(factors[mode])) }
        let normXhat2 = gAll.grid.reduce(0, +)
        let inner = zip(factors[n - 1].grid, lastM.grid).reduce(0) { $0 + $1.0 * $1.1 }
        let error2 = max(normX2 - 2 * inner + normXhat2, 0)
        return 1 - (error2 / normX2).squareRoot()
    }

    // MARK: - Linear-algebra helpers

    /// Column-wise Khatri-Rao: (B ⊙ C)[:,r] = kron(B[:,r], C[:,r]); C varies
    /// fastest, so the result aligns with `unfold`'s ascending column order.
    private static func khatriRao(_ b: Matrix, _ c: Matrix) -> Matrix {
        let r = b.cols
        let rowsB = b.rows, rowsC = c.rows
        var out = Matrix(rows: rowsB * rowsC, cols: r)
        out.grid.withUnsafeMutableBufferPointer { dst in
            b.grid.withUnsafeBufferPointer { bp in
                c.grid.withUnsafeBufferPointer { cp in
                    for col in 0..<r {
                        let bBase = col * rowsB, cBase = col * rowsC, oBase = col * rowsB * rowsC
                        for ib in 0..<rowsB {
                            let bv = bp[bBase + ib]
                            let rowBase = oBase + ib * rowsC
                            for ic in 0..<rowsC { dst[rowBase + ic] = bv * cp[cBase + ic] }
                        }
                    }
                }
            }
        }
        return out
    }

    private static func hadamard(_ a: Matrix, _ b: Matrix) -> Matrix {
        Matrix(rows: a.rows, cols: a.cols, columnMajor: zip(a.grid, b.grid).map(*))
    }

    /// One HALS (hierarchical ALS) sweep over the columns of a factor, projecting
    /// each onto the nonnegative orthant — the constrained replacement for the
    /// normal-equations solve.
    private static func halsUpdate(_ factor: inout Matrix, mttkrp m: Matrix, v: Matrix) {
        let rows = factor.rows, r = factor.cols
        let eps = 1e-12
        for col in 0..<r {
            let denom = v[col, col]
            guard denom > 0 else { continue }
            for i in 0..<rows {
                var numerator = m[i, col]
                for s in 0..<r { numerator -= factor[i, s] * v[s, col] }
                numerator += factor[i, col] * denom            // exclude the col term
                factor[i, col] = Swift.max(eps, numerator / denom)
            }
        }
    }

    private static func randomMatrix(rows: Int, cols: Int, rng: inout SplitMix64,
                                     nonnegative: Bool = false) -> Matrix {
        var grid = [Double](repeating: 0, count: rows * cols)
        for i in 0..<grid.count {
            let value = rng.nextGaussian()
            grid[i] = nonnegative ? abs(value) : value
        }
        return Matrix(rows: rows, cols: cols, columnMajor: grid)
    }

    private static func seed(for base: UInt64, start: Int) -> UInt64 {
        base &+ UInt64(start) &* 0x9E3779B97F4A7C15
    }

    // MARK: - Post-processing

    /// Normalize each factor's columns to unit length, collecting λ = ∏ norms.
    private static func normalize(_ factors: [Matrix]) -> (factors: [Matrix], weights: [Double]) {
        guard let r = factors.first?.cols else { return ([], []) }
        var out = factors
        var weights = [Double](repeating: 1, count: r)
        for m in out.indices {
            for c in 0..<r {
                let norm = (0..<out[m].rows).reduce(0.0) { $0 + out[m][$1, c] * out[m][$1, c] }.squareRoot()
                if norm > 0 {
                    for row in 0..<out[m].rows { out[m][row, c] /= norm }
                    weights[c] *= norm
                }
            }
        }
        return (out, weights)
    }

    private static func sortByWeight(_ factors: inout [Matrix], _ weights: inout [Double]) {
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        weights = order.map { weights[$0] }
        factors = factors.map { reorderColumns($0, order: order) }
    }

    /// Resolve CP sign ambiguity: make each non-sink mode's dominant entry
    /// positive, flipping the sink mode (last) to preserve each rank-1 term.
    private static func fixSigns(_ factors: inout [Matrix]) {
        guard let r = factors.first?.cols, factors.count > 1 else { return }
        let sink = factors.count - 1
        for c in 0..<r {
            for m in 0..<sink {
                var maxAbs = 0.0, sign = 1.0
                for row in 0..<factors[m].rows where abs(factors[m][row, c]) > maxAbs {
                    maxAbs = abs(factors[m][row, c]); sign = factors[m][row, c] < 0 ? -1 : 1
                }
                if sign < 0 {
                    for row in 0..<factors[m].rows { factors[m][row, c] *= -1 }
                    for row in 0..<factors[sink].rows { factors[sink][row, c] *= -1 }
                }
            }
        }
    }

    /// Worst |multi-cosine| between distinct components (unit-norm columns).
    private static func maxCongruence(_ factors: [Matrix]) -> Double {
        guard let r = factors.first?.cols, r > 1 else { return 0 }
        var worst = 0.0
        for a in 0..<r {
            for b in (a + 1)..<r {
                var product = 1.0
                for m in factors.indices {
                    var dot = 0.0
                    for row in 0..<factors[m].rows { dot += factors[m][row, a] * factors[m][row, b] }
                    product *= dot
                }
                worst = max(worst, abs(product))
            }
        }
        return worst
    }
}
