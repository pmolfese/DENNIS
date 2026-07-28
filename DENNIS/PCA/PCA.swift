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
nonisolated enum PCADecomposition: String, CaseIterable {
    case svd = "SVD"
    case nipals = "NIPALS"
}
nonisolated enum PCARotation: String, CaseIterable {
    case unrotated, varimax, promax, infomax, extendedInfomax

    /// True for the Infomax family, which bypasses the Kaiser loading path.
    var isInfomax: Bool { self == .infomax || self == .extendedInfomax }
}
nonisolated enum PCALoading: String, CaseIterable {
    case kaiser = "K"
    case none = "N"
    case covariance = "C"
    case curetonMulaik = "W"
}

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
    /// Per-variable standard deviation (full length, zero for dropped vars).
    /// Scaling the pattern by this gives microvolt-valued loadings.
    let variableSD: [Double]
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

nonisolated struct PCAJackknifeResult: Sendable {
    let subjectNames: [String]
    /// Variable × factor mean loading after congruence/sign alignment.
    let loadingMean: Matrix
    /// Variable × factor leave-one-subject-out loading standard deviation.
    let loadingSD: Matrix
    /// Mean of each PCA run's per-variable SD vector.
    let variableSDMean: [Double]
    /// Leave-one-subject-out SD of the PCA variable SD vector.
    let variableSDSD: [Double]
    let succeeded: Int
    let failures: [String]

    var maxLoadingSD: Double { loadingSD.grid.max() ?? 0 }
    var meanLoadingSD: Double {
        guard !loadingSD.grid.isEmpty else { return 0 }
        return loadingSD.grid.reduce(0, +) / Double(loadingSD.grid.count)
    }
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
        decomposition: PCADecomposition = .svd,
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

        // Eigendecomposition (ascending) → full scree and SVD/default factors.
        report?(0.5, decomposition == .nipals ? "NIPALS decomposition" : "Eigendecomposition")
        let (eigValsAsc, eigVecsAsc) = try relation.symmetricEigen()
        let order = Array((0..<eigValsAsc.count).reversed())  // descending
        let scree = order.map { eigValsAsc[$0] }
        let eigVecs: Matrix
        switch decomposition {
        case .svd:
            eigVecs = reorderColumns(eigVecsAsc, order: Array(order.prefix(nFactors)))
        case .nipals:
            eigVecs = nipalsComponents(relationData, nFactors: nFactors)
        }

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

            // EP Toolkit loading normalization / weighting.
            let communalities = (0..<loadings.rows).map { r in
                (0..<loadings.cols).reduce(0.0) { $0 + loadings[r, $1] * loadings[r, $1] }
            }
            var curetonWeights = [Double](repeating: 1, count: loadings.rows)
            var curetonReflect = [Double](repeating: 1, count: loadings.rows)
            switch loading {
            case .kaiser:
                for r in 0..<loadings.rows {
                    let denom = communalities[r].squareRoot()
                    if denom != 0 { for c in 0..<loadings.cols { loadings[r, c] /= denom } }
                }
            case .covariance:
                for r in 0..<loadings.rows {
                    for c in 0..<loadings.cols { loadings[r, c] *= sdRelation[r] }
                }
            case .none:
                break
            case .curetonMulaik:
                for r in 0..<loadings.rows {
                    let denom = communalities[r].squareRoot()
                    if denom != 0 { for c in 0..<loadings.cols { loadings[r, c] /= denom } }
                }
                guard nFactors > 1 else { break }
                let target = (1.0 / Double(nFactors)).squareRoot()
                let targetAngle = acos(target)
                let halfPi = Double.pi / 2
                for r in 0..<loadings.rows {
                    let reflected = loadings[r, 0] < 0 ? -1.0 : 1.0
                    curetonReflect[r] = reflected
                    for c in 0..<loadings.cols { loadings[r, c] *= reflected }
                    let firstLoading = loadings[r, 0]
                    let angle = acos(min(1, max(-1, firstLoading)))
                    let weight: Double
                    if firstLoading >= target {
                        weight = pow(cos(((targetAngle - angle) / targetAngle) * halfPi), 2) + 0.001
                    } else {
                        weight = pow(cos(((angle - targetAngle) / (halfPi - targetAngle)) * halfPi), 2) + 0.001
                    }
                    curetonWeights[r] = weight
                    for c in 0..<loadings.cols { loadings[r, c] *= weight }
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

            // Undo loading normalization / weighting before computing final scores.
            switch loading {
            case .kaiser:
                for r in 0..<pattern.rows {
                    let scale = communalities[r].squareRoot()
                    for c in 0..<pattern.cols {
                        pattern[r, c] *= scale
                        structure[r, c] *= scale
                    }
                }
            case .covariance:
                for r in 0..<pattern.rows where sdRelation[r] != 0 {
                    for c in 0..<pattern.cols {
                        pattern[r, c] /= sdRelation[r]
                        structure[r, c] /= sdRelation[r]
                    }
                }
            case .none:
                break
            case .curetonMulaik:
                for r in 0..<pattern.rows {
                    let inverseWeight = curetonWeights[r] == 0 ? 1 : 1 / curetonWeights[r]
                    let scale = communalities[r].squareRoot()
                    for c in 0..<pattern.cols {
                        pattern[r, c] *= inverseWeight * curetonReflect[r] * scale
                        structure[r, c] *= inverseWeight * curetonReflect[r] * scale
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

        // Full-length per-variable SD (zeros for dropped vars) for µV scaling.
        var fullVarSD = [Double](repeating: 0, count: nVars)
        for (i, origVar) in goodVars.enumerated() { fullVarSD[origVar] = varSd[i] }

        return PCAResult(
            pattern: fullPattern,
            structure: fullStructure,
            scores: scoresSorted,
            coefficients: fullCoefficients,
            correlation: correlationSorted,
            variableSD: fullVarSD,
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

    private static func nipalsComponents(
        _ data: Matrix,
        nFactors: Int,
        maxIterations: Int = 20_000,
        tolerance: Double = 1e-5
    ) -> Matrix {
        var residual = data
        var components = Matrix(rows: data.cols, cols: nFactors)
        let initialColumn = columnStd(data).enumerated().max { $0.element < $1.element }?.offset ?? 0

        for factor in 0..<nFactors {
            var scores = residual.column(initialColumn)
            if vectorNorm(scores) == 0 {
                scores = residual.column(maxVarianceColumn(residual))
            }
            guard vectorNorm(scores) > 0 else { break }

            var loadings = [Double](repeating: 0, count: residual.cols)
            for _ in 0..<maxIterations {
                let oldScores = scores
                loadings = multiplyTransposed(residual, by: scores)
                let scoreSS = dot(scores, scores)
                if scoreSS != 0 {
                    for i in 0..<loadings.count { loadings[i] /= scoreSS }
                }
                normalize(&loadings)

                scores = multiply(residual, by: loadings)
                let loadingSS = dot(loadings, loadings)
                if loadingSS != 0 {
                    for i in 0..<scores.count { scores[i] /= loadingSS }
                }

                if squaredDistance(scores, oldScores) <= tolerance * tolerance { break }
            }

            for r in 0..<components.rows { components[r, factor] = loadings[r] }
            for r in 0..<residual.rows {
                for c in 0..<residual.cols {
                    residual[r, c] -= scores[r] * loadings[c]
                }
            }
        }

        return components
    }

    private static func maxVarianceColumn(_ m: Matrix) -> Int {
        columnStd(m).enumerated().max { $0.element < $1.element }?.offset ?? 0
    }

    private static func multiply(_ m: Matrix, by vector: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: m.rows)
        for r in 0..<m.rows {
            var sum = 0.0
            for c in 0..<m.cols { sum += m[r, c] * vector[c] }
            out[r] = sum
        }
        return out
    }

    private static func multiplyTransposed(_ m: Matrix, by vector: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: m.cols)
        for c in 0..<m.cols {
            var sum = 0.0
            for r in 0..<m.rows { sum += m[r, c] * vector[r] }
            out[c] = sum
        }
        return out
    }

    private static func normalize(_ vector: inout [Double]) {
        let norm = vectorNorm(vector)
        guard norm > 0 else { return }
        for i in 0..<vector.count { vector[i] /= norm }
    }

    private static func vectorNorm(_ vector: [Double]) -> Double {
        dot(vector, vector).squareRoot()
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0.0) { $0 + $1.0 * $1.1 }
    }

    private static func squaredDistance(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0.0) {
            let diff = $1.0 - $1.1
            return $0 + diff * diff
        }
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

nonisolated enum PCAJackknife {
    static func leaveOneSubjectOut(
        tensor: EPTensor,
        mode: PCAMode,
        fullResult: PCAResult,
        subjectNames: [String],
        rotation: PCARotation,
        nFactors: Int,
        decomposition: PCADecomposition = .svd,
        matrixType: PCAMatrixType = .cov,
        loading: PCALoading = .kaiser,
        rotopt: Double = 3,
        seed: UInt64 = 0,
        report: PCAProgressHandler? = nil,
        progressRange: ClosedRange<Double> = 0...1
    ) throws -> PCAJackknifeResult {
        let nSubjects = tensor.nSubjects
        guard nSubjects > 1 else { throw PCAError.tooFewObservations(needed: 2, have: nSubjects) }

        var alignedPatterns: [Matrix] = []
        var variableSDs: [[Double]] = []
        var keptNames: [String] = []
        var failures: [String] = []

        for heldOut in 0..<nSubjects {
            let name = subjectNames.indices.contains(heldOut) ? subjectNames[heldOut] : "Subject \(heldOut + 1)"
            let fraction = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * Double(heldOut) / Double(nSubjects)
            report?(fraction, "Jackknife \(heldOut + 1)/\(nSubjects): refitting PCA without \(name)")
            do {
                let indices = (0..<nSubjects).filter { $0 != heldOut }
                let subset = tensor.selectingSubjects(indices)
                let result = try PCACore.doPCA(
                    subset.reshape(forMode: mode),
                    mode: mode,
                    rotation: rotation,
                    nFactors: min(nFactors, subset.variableCount(for: mode)),
                    decomposition: decomposition,
                    matrixType: matrixType,
                    loading: loading,
                    rotopt: rotopt,
                    seed: seed
                )
                alignedPatterns.append(align(result.pattern, to: fullResult.pattern))
                variableSDs.append(result.variableSD)
                keptNames.append(name)
            } catch {
                failures.append("\(name): \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            }
        }

        guard let first = alignedPatterns.first else { throw PCAError.tooMuchBadData }
        let loadingMean = meanMatrix(alignedPatterns, rows: first.rows, cols: first.cols)
        let loadingSD = sdMatrix(alignedPatterns, mean: loadingMean)
        let sdLength = variableSDs.map(\.count).min() ?? 0
        let variableSDMean = meanVectors(variableSDs.map { Array($0.prefix(sdLength)) }, length: sdLength)
        let variableSDSD = sdVectors(variableSDs.map { Array($0.prefix(sdLength)) }, mean: variableSDMean)

        report?(progressRange.upperBound, "Jackknife complete: \(alignedPatterns.count) leave-one-subject-out PCA refits.")
        return PCAJackknifeResult(
            subjectNames: keptNames,
            loadingMean: loadingMean,
            loadingSD: loadingSD,
            variableSDMean: variableSDMean,
            variableSDSD: variableSDSD,
            succeeded: alignedPatterns.count,
            failures: failures
        )
    }

    private static func align(_ candidate: Matrix, to reference: Matrix) -> Matrix {
        guard candidate.rows == reference.rows, candidate.cols == reference.cols else { return candidate }
        var out = Matrix(rows: candidate.rows, cols: candidate.cols)
        var used = Set<Int>()
        for refCol in 0..<reference.cols {
            var bestCol = 0
            var bestScore = -Double.infinity
            var bestSign = 1.0
            for candCol in 0..<candidate.cols where !used.contains(candCol) {
                let score = congruence(reference, refCol, candidate, candCol)
                if abs(score) > bestScore {
                    bestScore = abs(score)
                    bestCol = candCol
                    bestSign = score < 0 ? -1 : 1
                }
            }
            used.insert(bestCol)
            for r in 0..<candidate.rows { out[r, refCol] = candidate[r, bestCol] * bestSign }
        }
        return out
    }

    private static func congruence(_ a: Matrix, _ ac: Int, _ b: Matrix, _ bc: Int) -> Double {
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for r in 0..<a.rows {
            let av = a[r, ac]
            let bv = b[r, bc]
            dot += av * bv
            aa += av * av
            bb += bv * bv
        }
        guard aa > 0, bb > 0 else { return 0 }
        return dot / (aa.squareRoot() * bb.squareRoot())
    }

    private static func meanMatrix(_ matrices: [Matrix], rows: Int, cols: Int) -> Matrix {
        var out = Matrix(rows: rows, cols: cols)
        guard !matrices.isEmpty else { return out }
        for matrix in matrices {
            for i in 0..<out.grid.count { out.grid[i] += matrix.grid[i] }
        }
        for i in 0..<out.grid.count { out.grid[i] /= Double(matrices.count) }
        return out
    }

    private static func sdMatrix(_ matrices: [Matrix], mean: Matrix) -> Matrix {
        var out = Matrix(rows: mean.rows, cols: mean.cols)
        guard matrices.count > 1 else { return out }
        for matrix in matrices {
            for i in 0..<out.grid.count {
                let d = matrix.grid[i] - mean.grid[i]
                out.grid[i] += d * d
            }
        }
        for i in 0..<out.grid.count { out.grid[i] = (out.grid[i] / Double(matrices.count - 1)).squareRoot() }
        return out
    }

    private static func meanVectors(_ vectors: [[Double]], length: Int) -> [Double] {
        guard !vectors.isEmpty, length > 0 else { return [] }
        var out = [Double](repeating: 0, count: length)
        for vector in vectors {
            for i in 0..<length { out[i] += vector[i] }
        }
        for i in 0..<length { out[i] /= Double(vectors.count) }
        return out
    }

    private static func sdVectors(_ vectors: [[Double]], mean: [Double]) -> [Double] {
        guard vectors.count > 1, !mean.isEmpty else { return [Double](repeating: 0, count: mean.count) }
        var out = [Double](repeating: 0, count: mean.count)
        for vector in vectors {
            for i in 0..<mean.count {
                let d = vector[i] - mean[i]
                out[i] += d * d
            }
        }
        for i in 0..<out.count { out[i] = (out[i] / Double(vectors.count - 1)).squareRoot() }
        return out
    }
}
