//
//  PCA.swift
//  DENNIS
//
//  Core ERP PCA Toolkit-style PCA on a 2-D observations × variables matrix,
//  ported from mne_erppca.pca.core._do_pca_2d. Builds a COV/COR/SCP relation
//  matrix, eigendecomposes it, applies Kaiser loading normalization, rotates
//  (Varimax/Promax), and returns factor patterns, scores, and variance shares.
//
//  This is the single-step engine; the temporal→spatial two-step workflow is
//  layered on top of this.
//

import Foundation

nonisolated enum PCAMatrixType: String, CaseIterable { case cov = "COV", cor = "COR", scp = "SCP" }
nonisolated enum PCARotation: String, CaseIterable {
    case unrotated, varimax, promax, infomax, extendedInfomax

    /// True for the Infomax family, which bypasses the Kaiser loading path.
    var isInfomax: Bool { self == .infomax || self == .extendedInfomax }
}
nonisolated enum PCALoading: String, CaseIterable { case kaiser = "K", none = "N" }

nonisolated struct PCAResult {
    /// Variables × factors loading (pattern) matrix.
    let pattern: Matrix
    /// Variables × factors structure matrix.
    let structure: Matrix
    /// Observations × factors factor scores (standardized).
    let scores: Matrix
    /// Variables × factors scoring coefficients.
    let coefficients: Matrix
    /// Factors × factors factor correlation matrix.
    let correlation: Matrix
    /// Eigenvalues (descending), length = number of variables.
    let scree: [Double]
    /// Proportion of total variance per factor (communality share).
    let variance: [Double]
    /// Unique variance per factor.
    let uniqueVariance: [Double]
    /// Total communality (sum across variables).
    let totalVariance: Double
    let mode: PCAMode
    let nFactors: Int
}

nonisolated enum PCAError: Error, LocalizedError {
    case noGoodVariables
    case tooMuchBadData
    case tooFewObservations(needed: Int, have: Int)

    var errorDescription: String? {
        switch self {
        case .noGoodVariables: "No variables with nonzero variance for PCA."
        case .tooMuchBadData: "Too much missing data to conduct PCA."
        case .tooFewObservations(let needed, let have):
            "PCA needs at least \(needed) observations/variables but has \(have)."
        }
    }
}

nonisolated enum PCACore {

    /// Run one PCA step on a 2-D matrix (observations × variables).
    static func doPCA(
        _ data: Matrix,
        mode: PCAMode = .asIs,
        rotation: PCARotation = .promax,
        nFactors: Int,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        rotopt: Double = 3,
        seed: UInt64 = 0,
        report: PCAProgressHandler? = nil
    ) throws -> PCAResult {
        report?(0.1, "Preparing data")
        let nObs = data.rows
        let nVars = data.cols

        // Good variables: nonzero standard deviation.
        let stdev = columnStd(data)
        let goodVars = (0..<nVars).filter { stdev[$0] != 0 }
        guard !goodVars.isEmpty else { throw PCAError.noGoodVariables }
        guard nObs >= 2 else { throw PCAError.tooMuchBadData }

        // Restrict to good variables (all observations kept; no NaN handling yet).
        let work = selectColumns(data, goodVars)
        guard work.rows >= nFactors && work.cols >= nFactors else {
            throw PCAError.tooFewObservations(needed: nFactors, have: min(work.rows, work.cols))
        }

        let varSd = columnStd(work)
        let varMean = columnMean(work)

        // Relation matrix.
        var relationData = work
        switch matrixType {
        case .scp:
            break
        case .cov:
            relationData = centerColumns(work, by: varMean)
        case .cor:
            relationData = scaleColumns(centerColumns(work, by: varMean), by: varSd)
        }
        report?(0.3, "Building covariance matrix")
        let relation = crossProduct(relationData).scaled(1.0 / Double(work.rows - 1))
        let sdRelation = (0..<relation.rows).map { relation[$0, $0].squareRoot() }

        // Eigendecomposition (ascending) → take top nFactors descending.
        report?(0.5, "Eigendecomposition")
        let (eigValsAsc, eigVecsAsc) = try relation.symmetricEigen()
        let order = Array((0..<eigValsAsc.count).reversed())  // descending
        let scree = order.map { eigValsAsc[$0] }
        let eigVecs = reorderColumns(eigVecsAsc, order: Array(order.prefix(nFactors)))

        // Score coefficients & initial scores.
        let scoreCoefficients: Matrix
        switch matrixType {
        case .scp, .cov: scoreCoefficients = eigVecs
        case .cor: scoreCoefficients = scaleRows(eigVecs, by: varSd)   // eigVecs / varSd per row
        }
        var facScr = work.multiply(scoreCoefficients)
        let scrSd = columnStd(facScr)

        var pattern: Matrix
        var correlation: Matrix
        var structure: Matrix
        var coefficients: Matrix

        if rotation.isInfomax {
            // Infomax bypasses the Kaiser loading path and produces the pattern,
            // structure, correlation, scores, and coefficients directly.
            report?(0.7, rotation == .extendedInfomax ? "Extended Infomax rotation" : "Infomax rotation")
            let inf = try Infomax.rotate(
                work: work,
                initialScores: facScr,
                initialCoefficients: scoreCoefficients,
                extended: rotation == .extendedInfomax,
                rotopt: rotopt, seed: seed
            )
            pattern = inf.pattern
            structure = inf.structure
            correlation = inf.correlation
            coefficients = inf.coefficients
            facScr = inf.scores
        } else {
            // Initial loadings = (eigVecs * scrSd) / sdRelation.
            var loadings = eigVecs
            for c in 0..<loadings.cols {
                for r in 0..<loadings.rows {
                    loadings[r, c] = loadings[r, c] * scrSd[c] / sdRelation[r]
                }
            }

            // Kaiser normalization.
            let communalities = (0..<loadings.rows).map { r in
                (0..<loadings.cols).reduce(0.0) { $0 + loadings[r, $1] * loadings[r, $1] }
            }
            if loading == .kaiser {
                for r in 0..<loadings.rows {
                    let denom = communalities[r].squareRoot()
                    if denom != 0 { for c in 0..<loadings.cols { loadings[r, c] /= denom } }
                }
            }

            // Rotation.
            report?(0.7, rotation == .unrotated ? "Finalizing factors" : "Rotating factors")
            switch rotation {
            case .unrotated:
                pattern = loadings
                correlation = .identity(nFactors)
                structure = loadings
            case .varimax:
                pattern = Rotations.varimax(loadings, seed: seed)
                correlation = .identity(nFactors)
                structure = pattern
            case .promax:
                let vmx = Rotations.varimax(loadings, seed: seed)
                let (pat, cor) = try Rotations.promax(vmx, power: rotopt)
                pattern = pat
                correlation = cor
                structure = pat.multiply(cor)
            case .infomax, .extendedInfomax:
                fatalError("Infomax handled above")
            }

            // Undo Kaiser normalization.
            if loading == .kaiser {
                for r in 0..<pattern.rows {
                    let scale = communalities[r].squareRoot()
                    for c in 0..<pattern.cols {
                        pattern[r, c] *= scale
                        structure[r, c] *= scale
                    }
                }
            }

            // Scoring coefficients & final scores.
            report?(0.9, "Computing scores")
            var sdScaledPattern = pattern
            for r in 0..<pattern.rows {
                for c in 0..<pattern.cols { sdScaledPattern[r, c] *= sdRelation[r] }
            }
            coefficients = try sdScaledPattern.pseudoinverse().transposed()
            facScr = work.multiply(coefficients)
        }

        let facScrSd = columnStd(facScr)
        for c in 0..<facScr.cols where facScrSd[c] != 0 {
            for r in 0..<facScr.rows { facScr[r, c] /= facScrSd[c] }
        }

        // Variance accounting.
        let varDiag = sdRelation.map { $0 * $0 }
        let denom = varDiag.reduce(0, +)
        var communalityShare = [Double](repeating: 0, count: pattern.rows)
        var facVar = [Double](repeating: 0, count: nFactors)
        for r in 0..<pattern.rows {
            for c in 0..<nFactors {
                let term = varDiag[r] * pattern[r, c] * structure[r, c]
                communalityShare[r] += term / denom
                facVar[c] += term / denom
            }
        }
        let facVarQ = uniqueFactorVariance(pattern: pattern, correlation: correlation,
                                           varDiag: varDiag, denom: denom)
        let totalVariance = communalityShare.reduce(0, +)

        // Sort factors by variance (descending) and reflect signs.
        let index = (0..<nFactors).sorted { facVar[$0] > facVar[$1] }
        pattern = reorderColumns(pattern, order: index)
        structure = reorderColumns(structure, order: index)
        var coefficientsSorted = reorderColumns(coefficients, order: index)
        var scoresSorted = reorderColumns(facScr, order: index)
        var correlationSorted = reorderSymmetric(correlation, order: index)
        let facVarSorted = index.map { facVar[$0] }
        let facVarQSorted = index.map { facVarQ[$0] }

        for c in 0..<nFactors {
            let colSum = (0..<pattern.rows).reduce(0.0) { $0 + pattern[$1, c] }
            if colSum < 0 {
                for r in 0..<pattern.rows {
                    pattern[r, c] *= -1; structure[r, c] *= -1
                    coefficientsSorted[r, c] *= -1
                }
                for r in 0..<scoresSorted.rows { scoresSorted[r, c] *= -1 }
                for k in 0..<nFactors { correlationSorted[k, c] *= -1; correlationSorted[c, k] *= -1 }
            }
        }

        // Full-length scree (pad to nVars to mirror Python).
        var fullScree = [Double](repeating: 0, count: nVars)
        for i in 0..<min(nVars, scree.count) { fullScree[i] = scree[i] }

        // Scatter variable-indexed results (good vars only) back to the full
        // variable space so rows align with original channel/time indices, with
        // zeros for dropped (flat) variables — mirrors Python's `full_pat`.
        let fullPattern = scatterRows(pattern, goodVars: goodVars, nVars: nVars)
        let fullStructure = scatterRows(structure, goodVars: goodVars, nVars: nVars)
        let fullCoefficients = scatterRows(coefficientsSorted, goodVars: goodVars, nVars: nVars)

        return PCAResult(
            pattern: fullPattern,
            structure: fullStructure,
            scores: scoresSorted,
            coefficients: fullCoefficients,
            correlation: correlationSorted,
            scree: fullScree,
            variance: facVarSorted,
            uniqueVariance: facVarQSorted,
            totalVariance: totalVariance,
            mode: mode,
            nFactors: nFactors
        )
    }

    /// Scatter the rows of a `goodVars × cols` matrix into a `nVars × cols`
    /// matrix, placing each row at its original variable index and zero elsewhere.
    private static func scatterRows(_ m: Matrix, goodVars: [Int], nVars: Int) -> Matrix {
        guard m.rows != nVars else { return m }
        var out = Matrix(rows: nVars, cols: m.cols)
        for (newR, origR) in goodVars.enumerated() {
            for c in 0..<m.cols { out[origR, c] = m[newR, c] }
        }
        return out
    }

    // MARK: - Variance helper

    private static func uniqueFactorVariance(pattern: Matrix, correlation: Matrix,
                                             varDiag: [Double], denom: Double) -> [Double] {
        guard let inv = try? correlation.inverse() else {
            return [Double](repeating: 0, count: pattern.cols)
        }
        let scale = (0..<inv.rows).map { inv[$0, $0].squareRoot() }
        var result = [Double](repeating: 0, count: pattern.cols)
        for c in 0..<pattern.cols {
            var acc = 0.0
            for r in 0..<pattern.rows {
                let adjusted = pattern[r, c] / scale[c]
                acc += varDiag[r] * adjusted * adjusted
            }
            result[c] = acc / denom
        }
        return result
    }
}
