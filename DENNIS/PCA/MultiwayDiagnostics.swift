//
//  MultiwayDiagnostics.swift
//  DENNIS
//
//  Pre-decomposition diagnostics for the PARAFAC pipeline. The per-mode scree
//  (the n-mode singular spectra, a.k.a. the multilinear SVD) bounds how much
//  structure each mode carries and the multilinear rank — the tensor analog of
//  the PCA scree. Computed from each mode's small Gram matrix, so no large SVD
//  of the wide unfoldings is needed.
//

import Foundation

/// The singular spectrum of one tensor mode.
nonisolated struct ModeScree: Sendable, Identifiable {
    let mode: Int
    let name: String
    /// Singular values, descending (truncated to the leading components).
    let singularValues: [Double]
    /// Cumulative fraction of that mode's total energy, aligned with
    /// `singularValues`.
    let cumulativeVariance: [Double]
    /// Mean random-tensor singular values (the parallel-analysis floor); empty
    /// when parallel analysis was not run.
    let randomFloor: [Double]
    /// Components whose data singular value beats the floor; nil if not run.
    let retained: Int?
    var id: Int { mode }
}

nonisolated enum MultiwayDiagnostics {

    /// Per-mode singular spectra (multilinear SVD). When `parallelReps > 0`, also
    /// computes the random noise floor (parallel analysis) per mode and how many
    /// components rise above it.
    static func perModeScree(_ tensor: MultiwayTensor,
                             modeNames: [String],
                             maxComponents: Int = 20,
                             parallelReps: Int = 0,
                             seed: UInt64 = 0) throws -> [ModeScree] {
        let dataSpectra = try (0..<tensor.order).map { try modeSingularValues(tensor, mode: $0) }

        // Parallel analysis: average random-tensor spectra, matched in variance.
        var floors = [[Double]](repeating: [], count: tensor.order)
        if parallelReps > 0 {
            let std = (tensor.frobeniusNormSquared / Double(max(tensor.count, 1))).squareRoot()
            var rng = SplitMix64(seed: seed)
            var sums = (0..<tensor.order).map { [Double](repeating: 0, count: tensor.dims[$0]) }
            for _ in 0..<parallelReps {
                let random = MultiwayTensor.randomNormal(dims: tensor.dims, std: std, rng: &rng)
                for n in 0..<tensor.order {
                    let sv = try modeSingularValues(random, mode: n)
                    for i in sv.indices { sums[n][i] += sv[i] }
                }
            }
            floors = sums.map { $0.map { $0 / Double(parallelReps) } }
        }

        return (0..<tensor.order).map { n in
            let eigs = dataSpectra[n]                          // descending singular values
            let energy = eigs.map { $0 * $0 }
            let total = energy.reduce(0, +)
            var cumulative: [Double] = []
            var running = 0.0
            for value in energy { running += value; cumulative.append(total > 0 ? running / total : 0) }

            let floor = floors[n]
            let retained: Int? = floor.isEmpty ? nil
                : (0..<min(eigs.count, floor.count)).filter { eigs[$0] > floor[$0] }.count

            let k = min(maxComponents, eigs.count)
            return ModeScree(
                mode: n,
                name: n < modeNames.count ? modeNames[n] : "Mode \(n + 1)",
                singularValues: Array(eigs.prefix(k)),
                cumulativeVariance: Array(cumulative.prefix(k)),
                randomFloor: Array(floor.prefix(k)),
                retained: retained
            )
        }
    }

    /// Recommended CP rank: the binding (smallest) per-mode retained count from
    /// parallel analysis, else the smallest mode's components-to-90% (capped).
    static func recommendedRank(from modes: [ModeScree]) -> Int {
        let retained = modes.compactMap(\.retained)
        if let minRetained = retained.min() { return max(1, minRetained) }
        let to90 = modes.map { mode in
            (mode.cumulativeVariance.firstIndex { $0 >= 0.9 }).map { $0 + 1 } ?? mode.singularValues.count
        }
        return max(1, min(to90.min() ?? 3, 8))
    }

    // MARK: - Core consistency (CORCONDIA)

    /// Core consistency diagnostic (Bro & Kiers): how close the CP model is to a
    /// perfectly trilinear one. ~100% means every retained component is real; it
    /// collapses (toward 0 or below) once the rank is too high. Computed from the
    /// Tucker core estimated through the CP factor pseudoinverses. The component
    /// weights are distributed back into the factors (λ^{1/N} per mode) so the
    /// ideal core is the superdiagonal of ones.
    static func coreConsistency(tensor: MultiwayTensor, result: CPResult) -> Double {
        let factors = result.factors
        guard let r = factors.first?.cols, r > 0 else { return 0 }
        let nModes = factors.count
        let scale = result.weights.map { pow($0, 1.0 / Double(nModes)) }
        let scaled = factors.map { factor -> Matrix in
            var out = factor
            for c in 0..<r { for row in 0..<out.rows { out[row, c] *= scale[c] } }
            return out
        }

        var core = tensor
        for n in scaled.indices {
            guard let pinv = try? scaled[n].pseudoinverse() else { return .nan }
            core = core.modeProduct(mode: n, pinv)          // mode n becomes size R
        }
        var numerator = 0.0
        var idx = [Int](repeating: 0, count: nModes)
        for linear in 0..<core.count {
            let isSuperdiagonal = idx.allSatisfy { $0 == idx[0] }
            let diff = core.data[linear] - (isSuperdiagonal ? 1.0 : 0.0)
            numerator += diff * diff
            var a = 0
            while a < nModes { idx[a] += 1; if idx[a] < r { break }; idx[a] = 0; a += 1 }
        }
        return 100 * (1 - numerator / Double(r))             // ‖superdiagonal‖² = R
    }

    // MARK: - Fit / core-consistency sweep over rank

    struct RankPoint: Sendable, Identifiable {
        let rank: Int
        let fit: Double
        let coreConsistency: Double
        var id: Int { rank }
    }

    /// Run CP at R = 1…maxRank and record fit and core consistency at each,
    /// reporting the ALS progress and the running fit/CORCONDIA per rank.
    static func rankSweep(_ tensor: MultiwayTensor, modeNames: [String],
                          maxRank: Int, nStarts: Int = 4, seed: UInt64 = 0, nonnegative: Bool = false,
                          report: (@Sendable (Double, String) -> Void)? = nil) throws -> [RankPoint] {
        var points: [RankPoint] = []
        for r in 1...maxRank {
            let lo = Double(r - 1) / Double(maxRank)
            let span = 1.0 / Double(maxRank)
            let inner: @Sendable (Double, String) -> Void = { fraction, stage in
                report?(lo + span * fraction * 0.85, "Rank \(r)/\(maxRank) · \(stage)")
            }
            let result = try PARAFAC.decompose(
                tensor, modeNames: modeNames,
                options: .init(rank: r, nStarts: nStarts, seed: seed, nonnegative: nonnegative),
                report: inner)
            report?(lo + span * 0.92, "Rank \(r)/\(maxRank) · core consistency")
            let cc = coreConsistency(tensor: tensor, result: result)
            report?(lo + span, String(format: "Rank %d/%d done · fit %.0f%% · CORCONDIA %.0f%%",
                                      r, maxRank, result.fit * 100, cc))
            points.append(RankPoint(rank: r, fit: result.fit, coreConsistency: cc))
        }
        return points
    }

    // MARK: - Split-half reliability

    struct SplitHalf: Sendable {
        let meanCongruence: Double
        /// Best-matched congruence for each component of the first half.
        let perComponent: [Double]
    }

    /// Decompose two subject halves and match components by congruence over the
    /// shared (non-subject) modes. Replicable components score near 1.
    static func splitHalfReliability(_ tensor: MultiwayTensor, subjectMode: Int,
                                     modeNames: [String], rank: Int, nStarts: Int = 4,
                                     seed: UInt64 = 0, nonnegative: Bool = false) throws -> SplitHalf {
        let nSubjects = tensor.dims[subjectMode]
        let halfA = stride(from: 0, to: nSubjects, by: 2).map { $0 }
        let halfB = stride(from: 1, to: nSubjects, by: 2).map { $0 }
        guard halfA.count >= 2, halfB.count >= 2 else {
            return SplitHalf(meanCongruence: 0, perComponent: [])
        }
        let resultA = try PARAFAC.decompose(
            tensor.selecting(mode: subjectMode, indices: halfA),
            modeNames: modeNames, options: .init(rank: rank, nStarts: nStarts, seed: seed, nonnegative: nonnegative))
        let resultB = try PARAFAC.decompose(
            tensor.selecting(mode: subjectMode, indices: halfB),
            modeNames: modeNames, options: .init(rank: rank, nStarts: nStarts, seed: seed &+ 1, nonnegative: nonnegative))

        let sharedModes = (0..<tensor.order).filter { $0 != subjectMode }
        var used = Set<Int>()
        var perComponent: [Double] = []
        for a in 0..<rank {
            var best = 0.0
            var bestIndex = -1
            for b in 0..<rank where !used.contains(b) {
                let congruence = abs(multiCongruence(resultA.factors, a, resultB.factors, b, modes: sharedModes))
                if congruence > best { best = congruence; bestIndex = b }
            }
            if bestIndex >= 0 { used.insert(bestIndex) }
            perComponent.append(best)
        }
        let mean = perComponent.isEmpty ? 0 : perComponent.reduce(0, +) / Double(perComponent.count)
        return SplitHalf(meanCongruence: mean, perComponent: perComponent)
    }

    /// Product of cosine similarities across `modes` between component `a` of one
    /// solution and `b` of another (columns are unit-norm, so cosine = dot).
    private static func multiCongruence(_ fa: [Matrix], _ a: Int,
                                        _ fb: [Matrix], _ b: Int, modes: [Int]) -> Double {
        var product = 1.0
        for m in modes {
            var dot = 0.0
            for row in 0..<fa[m].rows { dot += fa[m][row, a] * fb[m][row, b] }
            product *= dot
        }
        return product
    }

    /// Descending singular values of a mode, via its small Gram matrix.
    private static func modeSingularValues(_ tensor: MultiwayTensor, mode n: Int) throws -> [Double] {
        let gram = gramRows(tensor.unfold(mode: n))
        let (eigsAscending, _) = try gram.symmetricEigen()
        return eigsAscending.reversed().map { max($0, 0).squareRoot() }
    }
}
