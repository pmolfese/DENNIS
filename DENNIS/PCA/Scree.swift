//
//  Scree.swift
//  DENNIS
//
//  Toolkit-style scree / parallel analysis for choosing how many factors to
//  retain, ported from mne_erppca.pca.scree. The data scree is the unrotated
//  eigenvalue curve; the random scree is the same curve computed on
//  standard-normal data of identical shape, rescaled so its total variance
//  matches the data. Factors above the rescaled random curve are "retained" by
//  the parallel test; a cumulative-variance threshold gives a second suggestion.
//

import Foundation

nonisolated struct ScreeAnalysis {
    /// Unrotated eigenvalue curve of the data (length = number of variables).
    let dataScree: [Double]
    /// Mean unrotated eigenvalue curve across random draws.
    let randomScree: [Double]
    /// `randomScree` rescaled so its total matches `dataScree`.
    let randomScreeScaled: [Double]
    /// Factors retained by the parallel (data > scaled-random) test.
    let retainedParallel: Int
    /// Factors retained by the cumulative-variance threshold test.
    let retainedMinVariance: Int
    /// Cumulative proportion of variance per factor.
    let cumulativeVariance: [Double]
    let mode: PCAMode
    let matrixType: PCAMatrixType
    let loading: PCALoading
    let nRandom: Int
}

nonisolated enum Scree {

    /// Run single-step scree analysis on an EP tensor for the given mode.
    static func analyze(
        _ tensor: EPTensor,
        mode: PCAMode,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        nRandom: Int = 1,
        minVariance: Double = 0.95,
        seed: UInt64 = 0,
        report: PCAProgressHandler? = nil
    ) throws -> ScreeAnalysis {
        precondition(nRandom >= 1, "nRandom must be at least 1")
        precondition(minVariance > 0 && minVariance <= 1, "minVariance must be in (0, 1]")

        report?(0.1, "Analyzing data")
        let dataResult = try PCACore.doPCA(
            tensor.reshape(forMode: mode),
            mode: mode, rotation: .unrotated, nFactors: 1,
            matrixType: matrixType, loading: loading
        )
        let dataScree = dataResult.scree

        // Each random draw is independent, so run them concurrently. A per-draw
        // seed keeps results reproducible regardless of completion order.
        let dims = tensor.dims
        var draws = [[Double]](repeating: [], count: nRandom)
        report?(0.2, "Random draw 0/\(nRandom)")
        try draws.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes a distinct index, and shared state is
            // lock-guarded, so the concurrent access is data-race free.
            nonisolated(unsafe) let buffer = buffer
            let lock = NSLock()
            nonisolated(unsafe) var caught: Error?
            nonisolated(unsafe) var completed = 0
            DispatchQueue.concurrentPerform(iterations: nRandom) { i in
                var rng = SplitMix64(seed: seed &+ UInt64(i))
                let randomTensor = EPTensor.randomNormal(dims: dims, rng: &rng)
                do {
                    let randomResult = try PCACore.doPCA(
                        randomTensor.reshape(forMode: mode),
                        mode: mode, rotation: .unrotated, nFactors: 1,
                        matrixType: matrixType, loading: loading
                    )
                    buffer[i] = randomResult.scree
                } catch {
                    lock.lock(); if caught == nil { caught = error }; lock.unlock()
                }
                lock.lock(); completed += 1; let done = completed; lock.unlock()
                report?(0.2 + 0.7 * Double(done) / Double(nRandom), "Random draw \(done)/\(nRandom)")
            }
            if let caught { throw caught }
        }

        var accum = [Double](repeating: 0, count: dataScree.count)
        for draw in draws {
            for i in 0..<min(accum.count, draw.count) { accum[i] += draw[i] }
        }
        let randomScree = accum.map { $0 / Double(nRandom) }

        return fromCurves(
            dataScree: dataScree, randomScree: randomScree,
            mode: mode, matrixType: matrixType, loading: loading,
            nRandom: nRandom, minVariance: minVariance
        )
    }

    /// Second-step (e.g. spatial) scree analysis for a two-step PCA, mirroring
    /// mne_erppca's `do_two_step_scree_analysis`. Runs the first PCA, then an
    /// unrotated 1-factor second PCA on each first-step factor's scores, and
    /// averages the resulting scree curves. The random reference repeats the
    /// whole pipeline on standard-normal data of identical shape.
    static func analyzeTwoStep(
        _ tensor: EPTensor,
        firstMode: PCAMode,
        secondMode: PCAMode,
        firstFactors: Int,
        firstRotation: PCARotation = .promax,
        rotopt: Double = 3,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        nRandom: Int = 1,
        minVariance: Double = 0.95,
        seed: UInt64 = 0,
        report: PCAProgressHandler? = nil
    ) throws -> ScreeAnalysis {
        precondition(nRandom >= 1, "nRandom must be at least 1")
        precondition(firstMode != secondMode, "two-step modes must differ")

        report?(0.1, "First-step \(firstMode.rawValue) PCA")
        let dataScree = try secondStepScreeCurve(
            tensor, firstMode: firstMode, secondMode: secondMode,
            firstFactors: firstFactors, firstRotation: firstRotation, rotopt: rotopt,
            matrixType: matrixType, loading: loading, seed: seed
        )

        let dims = tensor.dims
        var rng = SplitMix64(seed: seed)
        var accum = [Double](repeating: 0, count: dataScree.count)
        for i in 0..<nRandom {
            report?(0.2 + 0.7 * Double(i) / Double(nRandom), "Random draw \(i + 1)/\(nRandom)")
            let randomTensor = EPTensor.randomNormal(dims: dims, rng: &rng)
            let curve = try secondStepScreeCurve(
                randomTensor, firstMode: firstMode, secondMode: secondMode,
                firstFactors: firstFactors, firstRotation: firstRotation, rotopt: rotopt,
                matrixType: matrixType, loading: loading, seed: seed &+ UInt64(i + 1)
            )
            for j in 0..<min(accum.count, curve.count) { accum[j] += curve[j] }
        }
        let randomScree = accum.map { $0 / Double(nRandom) }

        return fromCurves(
            dataScree: dataScree, randomScree: randomScree,
            mode: secondMode, matrixType: matrixType, loading: loading,
            nRandom: nRandom, minVariance: minVariance
        )
    }

    /// Mean second-step scree curve across first-step factors (unrotated,
    /// 1-factor second PCA), matching `_as_scree_curve` of a two-step run.
    private static func secondStepScreeCurve(
        _ tensor: EPTensor,
        firstMode: PCAMode,
        secondMode: PCAMode,
        firstFactors: Int,
        firstRotation: PCARotation,
        rotopt: Double,
        matrixType: PCAMatrixType,
        loading: PCALoading,
        seed: UInt64
    ) throws -> [Double] {
        let nf1 = min(firstFactors, tensor.variableCount(for: firstMode))
        let first = try PCACore.doPCA(
            tensor.reshape(forMode: firstMode), mode: firstMode, rotation: firstRotation,
            nFactors: nf1, matrixType: matrixType, loading: loading, rotopt: rotopt, seed: seed
        )
        var scoreDims = tensor.dims
        scoreDims[EPTensor.variableAxis(for: firstMode)] = 1

        var accum: [Double] = []
        for t in 0..<first.nFactors {
            let scoreTensor = EPTensor(dims: scoreDims, data: first.scores.column(t))
            let step = try PCACore.doPCA(
                scoreTensor.reshape(forMode: secondMode), mode: secondMode,
                rotation: .unrotated, nFactors: 1, matrixType: matrixType, loading: loading
            )
            if accum.isEmpty { accum = [Double](repeating: 0, count: step.scree.count) }
            for i in 0..<min(accum.count, step.scree.count) { accum[i] += step.scree[i] }
        }
        let n = Double(max(first.nFactors, 1))
        return accum.map { $0 / n }
    }

    /// Assemble an analysis from precomputed data/random scree curves.
    static func fromCurves(
        dataScree: [Double],
        randomScree: [Double],
        mode: PCAMode,
        matrixType: PCAMatrixType,
        loading: PCALoading,
        nRandom: Int,
        minVariance: Double = 0.95
    ) -> ScreeAnalysis {
        let scaled = scaleToTotal(randomScree, matching: dataScree)
        let total = dataScree.reduce(0, +)
        var cumulative = [Double](repeating: 0, count: dataScree.count)
        if total != 0 {
            var running = 0.0
            for i in 0..<dataScree.count {
                running += dataScree[i]
                cumulative[i] = running / total
            }
        }
        return ScreeAnalysis(
            dataScree: dataScree,
            randomScree: randomScree,
            randomScreeScaled: scaled,
            retainedParallel: countAboveThreshold(dataScree, scaled),
            retainedMinVariance: countMinVariance(cumulative, minVariance: minVariance),
            cumulativeVariance: cumulative,
            mode: mode, matrixType: matrixType, loading: loading, nRandom: nRandom
        )
    }

    /// Scale `reference` so its sum matches `target`.
    static func scaleToTotal(_ reference: [Double], matching target: [Double]) -> [Double] {
        let total = reference.reduce(0, +)
        guard total != 0 else { return reference }
        let factor = target.reduce(0, +) / total
        return reference.map { $0 * factor }
    }

    /// Toolkit-style count of factors above a scree threshold: the index of the
    /// first gap in the run of above-threshold factors, else the last such factor.
    static func countAboveThreshold(_ dataScree: [Double], _ threshold: [Double]) -> Int {
        let n = min(dataScree.count, threshold.count)
        let above = (0..<n).filter { dataScree[$0] > threshold[$0] }
        guard !above.isEmpty else { return 0 }
        for i in 1..<above.count where above[i] - above[i - 1] > 1 {
            return above[i - 1] + 1
        }
        return above[above.count - 1] + 1
    }

    /// Toolkit-style count for the minimum-variance pane: the last factor whose
    /// cumulative variance is still at or below the threshold.
    static func countMinVariance(_ cumulative: [Double], minVariance: Double = 0.95) -> Int {
        let below = (0..<cumulative.count).filter { minVariance >= cumulative[$0] }
        return below.last.map { $0 + 1 } ?? 0
    }
}
