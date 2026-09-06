//
//  TwoStepPCA.swift
//  DENNIS
//
//  The dual (two-step) ERP PCA: a first PCA on one mode (e.g. temporal), then a
//  separate PCA on a second mode (e.g. spatial) run on each first-step factor's
//  scores. Ported from mne_erppca.pca.core.do_pca_two_step. Each first factor's
//  score column is reshaped back into the EP layout (with the first mode's
//  dimension collapsed to 1) and re-flattened for the second mode, so the second
//  PCA sees that factor's spatial (or temporal) structure. Combined factors are
//  the cross product of the two steps; their variance is the product of the
//  per-step variances.
//
//  References (full citations in `Model/References.swift`):
//    - Dien (2010), J Neurosci Methods 187(1):138-145 — the two-step
//      decomposition itself.
//    - Dien, Beal & Berg (2005), Clin Neurophysiol 116(8):1808-1825 — why
//      temporal-then-spatial is the recommended order.
//

import Foundation

/// One combined factor of a two-step solution, e.g. temporal factor 1 ×
/// spatial factor 2 ("TF1SF2").
nonisolated struct TwoStepFactor: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let name: String
    /// Combined variance share = first-step variance × second-step variance.
    let variance: Double
}

nonisolated struct TwoStepPCAResult: Sendable {
    let first: PCAResult
    /// Second-step PCA for each first-step factor (aligned by `firstIndex`).
    let second: [PCAResult]
    let firstMode: PCAMode
    let secondMode: PCAMode
    let factors: [TwoStepFactor]
    let totalVariance: Double
    /// Time (ms) per first-step variable, when the first mode is temporal.
    let firstTimesMS: [Double]
    let jackknife: TwoStepPCAJackknifeResult?
}

nonisolated struct TwoStepPCAJackknifeResult: Sendable {
    let first: PCAJackknifeResult?
    /// Second-step jackknife summaries, aligned with `TwoStepPCAResult.second`.
    let second: [PCAJackknifeResult?]
}

nonisolated enum TwoStepPCA {

    static func run(
        tensor: EPTensor,
        firstMode: PCAMode,
        secondMode: PCAMode,
        firstFactors: Int,
        secondFactors: Int,
        firstRotation: PCARotation = .promax,
        secondRotation: PCARotation = .promax,
        decomposition: PCADecomposition = .svd,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        firstDecomposition: PCADecomposition? = nil,
        secondDecomposition: PCADecomposition? = nil,
        firstMatrixType: PCAMatrixType? = nil,
        firstLoading: PCALoading? = nil,
        secondMatrixType: PCAMatrixType? = nil,
        secondLoading: PCALoading? = nil,
        rotopt: Double = 3,
        seed: UInt64 = 0,
        firstTimesMS: [Double] = [],
        jackknife: TwoStepPCAJackknifeResult? = nil,
        report: PCAProgressHandler? = nil
    ) throws -> TwoStepPCAResult {
        precondition(firstMode != secondMode, "two-step modes must differ")

        report?(0.05, "First-step \(firstMode.rawValue) PCA")
        let firstMatrixType = firstMatrixType ?? matrixType
        let firstLoading = firstLoading ?? loading
        let secondMatrixType = secondMatrixType ?? matrixType
        let secondLoading = secondLoading ?? loading
        let firstDecomposition = firstDecomposition ?? decomposition
        let secondDecomposition = secondDecomposition ?? decomposition
        let firstMatrix = tensor.reshape(forMode: firstMode)
        let nf1 = min(firstFactors, tensor.variableCount(for: firstMode))
        let first = try PCACore.doPCA(
            firstMatrix, mode: firstMode, rotation: firstRotation, nFactors: nf1,
            decomposition: firstDecomposition,
            matrixType: firstMatrixType, loading: firstLoading, rotopt: rotopt, seed: seed
        )

        // Score sub-tensor dimensions: collapse the first mode's variable axis.
        var scoreDims = tensor.dims
        scoreDims[EPTensor.variableAxis(for: firstMode)] = 1

        var second: [PCAResult] = []
        var factors: [TwoStepFactor] = []
        for t in 0..<first.nFactors {
            report?(0.1 + 0.85 * Double(t) / Double(first.nFactors),
                    "Second-step \(secondMode.rawValue) PCA \(t + 1)/\(first.nFactors)")
            let scoreTensor = EPTensor(dims: scoreDims, data: first.scores.column(t))
            let secondMatrix = scoreTensor.reshape(forMode: secondMode)
            let nf2 = min(secondFactors, scoreTensor.variableCount(for: secondMode))
            let step = try PCACore.doPCA(
                secondMatrix, mode: secondMode, rotation: secondRotation, nFactors: nf2,
                decomposition: secondDecomposition,
                matrixType: secondMatrixType, loading: secondLoading, rotopt: rotopt, seed: seed
            )
            second.append(step)
            for s in 0..<step.nFactors {
                let firstVar = first.variance.indices.contains(t) ? first.variance[t] : 0
                let secondVar = step.variance.indices.contains(s) ? step.variance[s] : 0
                factors.append(TwoStepFactor(
                    firstIndex: t, secondIndex: s,
                    name: "\(firstMode.factorPrefix)\(t + 1)\(secondMode.factorPrefix)\(s + 1)",
                    variance: firstVar * secondVar
                ))
            }
        }

        report?(1.0, "Done")
        return TwoStepPCAResult(
            first: first, second: second,
            firstMode: firstMode, secondMode: secondMode,
            factors: factors,
            totalVariance: factors.reduce(0) { $0 + $1.variance },
            firstTimesMS: firstTimesMS,
            jackknife: jackknife
        )
    }

    static func jackknife(
        tensor: EPTensor,
        result: TwoStepPCAResult,
        subjectNames: [String],
        firstRotation: PCARotation = .promax,
        secondRotation: PCARotation = .promax,
        decomposition: PCADecomposition = .svd,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        firstDecomposition: PCADecomposition? = nil,
        secondDecomposition: PCADecomposition? = nil,
        firstMatrixType: PCAMatrixType? = nil,
        firstLoading: PCALoading? = nil,
        secondMatrixType: PCAMatrixType? = nil,
        secondLoading: PCALoading? = nil,
        rotopt: Double = 3,
        seed: UInt64 = 0,
        report: PCAProgressHandler? = nil
    ) -> TwoStepPCAJackknifeResult {
        let firstRange = 0.0...0.35
        let firstMatrixType = firstMatrixType ?? matrixType
        let firstLoading = firstLoading ?? loading
        let secondMatrixType = secondMatrixType ?? matrixType
        let secondLoading = secondLoading ?? loading
        let firstDecomposition = firstDecomposition ?? decomposition
        let secondDecomposition = secondDecomposition ?? decomposition
        let firstJackknife = try? PCAJackknife.leaveOneSubjectOut(
            tensor: tensor,
            mode: result.firstMode,
            fullResult: result.first,
            subjectNames: subjectNames,
            rotation: firstRotation,
            nFactors: result.first.nFactors,
            decomposition: firstDecomposition,
            matrixType: firstMatrixType,
            loading: firstLoading,
            rotopt: rotopt,
            seed: seed,
            report: report,
            progressRange: firstRange
        )

        var scoreDims = tensor.dims
        scoreDims[EPTensor.variableAxis(for: result.firstMode)] = 1
        var secondJackknife: [PCAJackknifeResult?] = []

        for t in 0..<result.first.nFactors {
            let start = 0.35 + 0.65 * Double(t) / Double(max(result.first.nFactors, 1))
            let end = 0.35 + 0.65 * Double(t + 1) / Double(max(result.first.nFactors, 1))
            let scoreTensor = EPTensor(dims: scoreDims, data: result.first.scores.column(t))
            let fullSecond = result.second.indices.contains(t) ? result.second[t] : nil
            let jack = fullSecond.flatMap { full in
                try? PCAJackknife.leaveOneSubjectOut(
                    tensor: scoreTensor,
                    mode: result.secondMode,
                    fullResult: full,
                    subjectNames: subjectNames,
                    rotation: secondRotation,
                    nFactors: full.nFactors,
                    decomposition: secondDecomposition,
                    matrixType: secondMatrixType,
                    loading: secondLoading,
                    rotopt: rotopt,
                    seed: seed,
                    report: report,
                    progressRange: start...end
                )
            }
            secondJackknife.append(jack)
        }

        report?(1.0, "Dual PCA jackknife complete.")
        return TwoStepPCAJackknifeResult(first: firstJackknife, second: secondJackknife)
    }
}
