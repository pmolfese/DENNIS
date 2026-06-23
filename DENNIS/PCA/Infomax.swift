//
//  Infomax.swift
//  DENNIS
//
//  (Extended) Infomax ICA, ported to Swift from MNE-Python's
//  `mne/preprocessing/infomax_.py`, which is itself a port of the EEGLAB
//  `runica` infomax. Used as an oblique "rotation" in the ERP PCA Toolkit
//  workflow, mirroring mne_erppca.pca.core._infomax_rotation.
//
//  ----------------------------------------------------------------------------
//  This file is a derivative of MNE-Python, licensed BSD-3-Clause:
//
//    Copyright the MNE-Python contributors.
//    Redistribution and use in source and binary forms, with or without
//    modification, are permitted provided that the BSD-3-Clause conditions are
//    met. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
//
//  DENNIS as a whole is distributed under the GNU GPL v3; the BSD-3-Clause
//  terms above are compatible with that and are retained for this derived work.
//  References: Bell & Sejnowski (1995); Lee, Girolami & Sejnowski (1999).
//  ----------------------------------------------------------------------------
//

import Foundation

nonisolated enum Infomax {

    struct Result {
        /// The `n_features × n_features` unmixing matrix.
        let unmixing: Matrix
        let nIter: Int
    }

    /// Run (extended) Infomax on whitened `data` (n_samples × n_features).
    static func run(
        _ data: Matrix,
        extended: Bool = true,
        lRate: Double? = nil,
        block: Int? = nil,
        wChange: Double = 1e-12,
        annealDeg: Double = 60.0,
        annealStep: Double = 0.9,
        nSubgauss: Int = 1,
        kurtSize: Int = 6000,
        extBlocks: Int = 1,
        maxIter: Int = 200,
        blowup: Double = 1e4,
        blowupFac: Double = 0.5,
        nSmallAngle: Int? = 20,
        useBias: Bool = true,
        seed: UInt64 = 0
    ) -> Result {
        var rng = SplitMix64(seed: seed)

        let maxWeight = 1e8
        let restartFac = 0.9
        let minLRate = 1e-10
        let degconst = 180.0 / Double.pi

        // Extended-Infomax constants.
        let extmomentum = 0.5
        let signsbias = 0.02
        let signcountThreshold = 25
        let signcountStep = 2

        let nSamples = data.rows
        let nFeatures = data.cols
        let nFeaturesSquare = nFeatures * nFeatures

        var lrate = lRate ?? 0.01 / log(Double(nFeatures * nFeatures))
        let blk = block ?? Int(Double(nSamples / 3).squareRoot().rounded(.down))
        let nblock = blk > 0 ? nSamples / blk : 0
        let lastt = max((nblock - 1) * blk + 1, 1)

        var weights = Matrix.identity(nFeatures)
        let BI = Matrix.identity(nFeatures).scaled(Double(blk))
        var bias = [Double](repeating: 0, count: nFeatures)
        let startweights = weights
        var oldweights = startweights
        var step = 0
        var countSmallAngle = 0
        var wtsBlowup = false
        var blockno = 0
        var signcount = 0
        var maxIterMutable = maxIter
        var extBlocksMutable = extBlocks
        let initialExtBlocks = extBlocks

        // Extended-Infomax sign state.
        var signs = [Double](repeating: 1, count: nFeatures)
        var oldKurt = [Double](repeating: 0, count: nFeatures)
        var oldsigns = [Double](repeating: 0, count: nFeatures)
        let kurtWindow = min(kurtSize, nSamples)
        if extended { for k in 0..<min(nSubgauss, nFeatures) { signs[k] = -1 } }

        var olddelta = [Double](repeating: 0, count: nFeaturesSquare)
        var oldchange = 0.0

        while step < maxIterMutable {
            let permute = randomPermutation(nSamples, rng: &rng)

            var t = 0
            while t < lastt {
                let upper = min(t + blk, nSamples)
                let rows = Array(permute[t..<min(t + blk, permute.count)])
                let dataBlock = selectRows(data, rows)           // rowsCount × nFeatures
                var u = dataBlock.multiply(weights)              // rowsCount × nFeatures
                addRowVector(&u, bias)                           // u += bias (broadcast)

                if extended {
                    let y = elementwise(u) { Foundation.tanh($0) }
                    let uTy = crossProductAB(u, y)               // nFeatures × nFeatures
                    let uTu = crossProduct(u)                    // nFeatures × nFeatures
                    var m = BI
                    for j in 0..<nFeatures {
                        for i in 0..<nFeatures {
                            m[i, j] = BI[i, j] - signs[j] * uTy[i, j] - uTu[i, j]
                        }
                    }
                    let delta = weights.multiply(m)
                    weights = add(weights, delta.scaled(lrate))
                    if useBias {
                        let colSum = columnSum(y)
                        for i in 0..<nFeatures { bias[i] += lrate * colSum[i] * -2.0 }
                    }
                } else {
                    let y = elementwise(u) { 1.0 / (1.0 + Foundation.exp(-$0)) }   // expit
                    var oneMinus2y = y
                    for idx in 0..<oneMinus2y.grid.count { oneMinus2y.grid[idx] = 1.0 - 2.0 * y.grid[idx] }
                    let term = crossProductAB(u, oneMinus2y)     // nFeatures × nFeatures
                    let m = add(BI, term)
                    let delta = weights.multiply(m)
                    weights = add(weights, delta.scaled(lrate))
                    if useBias {
                        let colSum = columnSum(oneMinus2y)
                        for i in 0..<nFeatures { bias[i] += lrate * colSum[i] }
                    }
                }

                if maxAbs(weights) > maxWeight { wtsBlowup = true }
                blockno += 1
                if wtsBlowup { break }

                // Extended-Infomax kurtosis-based sign estimation.
                if extended, extBlocksMutable > 0, blockno % extBlocksMutable == 0 {
                    let act: Matrix
                    if kurtWindow < nSamples {
                        let rp = (0..<kurtWindow).map { _ in Int((Double(nSamples - 1) * rng.nextUnit()).rounded(.down)) }
                        act = selectRows(data, rp).multiply(weights)   // kurtWindow × nFeatures
                    } else {
                        act = data.multiply(weights)
                    }
                    var kurt = rowKurtosis(transposeToRows(act, nFeatures: nFeatures))
                    if extmomentum != 0 {
                        for i in 0..<nFeatures { kurt[i] = extmomentum * oldKurt[i] + (1 - extmomentum) * kurt[i] }
                        oldKurt = kurt
                    }
                    signs = kurt.map { ($0 + signsbias) >= 0 ? 1.0 : -1.0 }
                    let ndiff = zip(signs, oldsigns).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                    signcount = ndiff == 0 ? signcount + 1 : 0
                    oldsigns = signs
                    if signcount >= signcountThreshold {
                        extBlocksMutable = Int(Double(extBlocksMutable * signcountStep).rounded(.towardZero))
                        signcount = 0
                    }
                }
                t += blk
                _ = upper
            }

            if !wtsBlowup {
                let oldwtchange = subtract(weights, oldweights)
                step += 1
                var angledelta = 0.0
                let delta = oldwtchange.grid                  // length nFeaturesSquare (column-major)
                let change = delta.reduce(0) { $0 + $1 * $1 }
                if step > 2 {
                    let dot = zip(delta, olddelta).reduce(0) { $0 + $1.0 * $1.1 }
                    let denom = (change * oldchange).squareRoot()
                    if denom != 0 {
                        angledelta = acos(max(-1.0, min(1.0, dot / denom))) * degconst
                    }
                }

                oldweights = weights
                if angledelta > annealDeg {
                    lrate *= annealStep
                    olddelta = delta
                    oldchange = change
                    countSmallAngle = 0
                } else {
                    if step == 1 { olddelta = delta; oldchange = change }
                    if let nSmall = nSmallAngle {
                        countSmallAngle += 1
                        if countSmallAngle > nSmall { maxIterMutable = step }
                    }
                }

                if step > 2 && change < wChange {
                    step = maxIterMutable
                } else if change > blowup {
                    lrate *= blowupFac
                }
            } else {
                // Weights blew up: restart with a lower learning rate.
                step = 0
                wtsBlowup = false
                blockno = 1
                lrate *= restartFac
                weights = startweights
                oldweights = startweights
                olddelta = [Double](repeating: 0, count: nFeaturesSquare)
                bias = [Double](repeating: 0, count: nFeatures)
                extBlocksMutable = initialExtBlocks
                if extended {
                    signs = [Double](repeating: 1, count: nFeatures)
                    for k in 0..<min(nSubgauss, nFeatures) { signs[k] = -1 }
                    oldsigns = [Double](repeating: 0, count: nFeatures)
                }
                if lrate <= minLRate {
                    // Give up gracefully; return the identity-derived weights so far.
                    break
                }
            }
        }

        return Result(unmixing: weights.transposed(), nIter: step)
    }

    // MARK: - Linear-algebra helpers (small n_features)

    /// `a^T · a` for an m × n matrix → n × n.
    private static func crossProductAB(_ a: Matrix, _ b: Matrix) -> Matrix {
        a.transposed().multiply(b)
    }

    private static func selectRows(_ m: Matrix, _ rows: [Int]) -> Matrix {
        var out = Matrix(rows: rows.count, cols: m.cols)
        for (newR, r) in rows.enumerated() {
            for c in 0..<m.cols { out[newR, c] = m[r, c] }
        }
        return out
    }

    private static func addRowVector(_ m: inout Matrix, _ v: [Double]) {
        for c in 0..<m.cols {
            for r in 0..<m.rows { m[r, c] += v[c] }
        }
    }

    private static func elementwise(_ m: Matrix, _ f: (Double) -> Double) -> Matrix {
        Matrix(rows: m.rows, cols: m.cols, columnMajor: m.grid.map(f))
    }

    private static func add(_ a: Matrix, _ b: Matrix) -> Matrix {
        Matrix(rows: a.rows, cols: a.cols, columnMajor: zip(a.grid, b.grid).map(+))
    }

    private static func subtract(_ a: Matrix, _ b: Matrix) -> Matrix {
        Matrix(rows: a.rows, cols: a.cols, columnMajor: zip(a.grid, b.grid).map(-))
    }

    private static func columnSum(_ m: Matrix) -> [Double] {
        (0..<m.cols).map { c in (0..<m.rows).reduce(0.0) { $0 + m[$1, c] } }
    }

    private static func maxAbs(_ m: Matrix) -> Double {
        m.grid.reduce(0.0) { Swift.max($0, Swift.abs($1)) }
    }

    /// Return the rows of `act^T` as `[feature][sample]` for kurtosis estimation.
    private static func transposeToRows(_ act: Matrix, nFeatures: Int) -> [[Double]] {
        (0..<nFeatures).map { f in act.column(f) }
    }

    /// Fisher kurtosis (population moments) per row, matching scipy.stats.kurtosis.
    private static func rowKurtosis(_ rows: [[Double]]) -> [Double] {
        rows.map { x in
            let n = Double(x.count)
            guard n > 0 else { return 0 }
            let mean = x.reduce(0, +) / n
            var m2 = 0.0, m4 = 0.0
            for v in x { let d = v - mean; let d2 = d * d; m2 += d2; m4 += d2 * d2 }
            m2 /= n; m4 /= n
            return m2 == 0 ? 0 : m4 / (m2 * m2) - 3.0
        }
    }

    /// Emulate MNE's `random_permutation`: argsort of n uniforms.
    private static func randomPermutation(_ n: Int, rng: inout SplitMix64) -> [Int] {
        let keys = (0..<n).map { _ in rng.nextUnit() }
        return Array(0..<n).sorted { keys[$0] < keys[$1] }
    }

    // MARK: - Infomax as a PCA rotation

    enum InfomaxError: Error, LocalizedError {
        case tooFewObservations
        case zeroVarianceScore

        var errorDescription: String? {
            switch self {
            case .tooFewObservations: "Too few observations to conduct Infomax rotation."
            case .zeroVarianceScore: "Infomax rotation received a zero-variance factor score."
            }
        }
    }

    /// Oblique Infomax "rotation" of a PCA solution, mirroring
    /// mne_erppca.pca.core._infomax_rotation. `work` is the observations ×
    /// variables data, `initialScores` the obs × factors PCA scores, and
    /// `initialCoefficients` the variables × factors scoring coefficients.
    static func rotate(
        work: Matrix,
        initialScores: Matrix,
        initialCoefficients: Matrix,
        extended: Bool,
        rotopt: Double?,
        seed: UInt64
    ) throws -> (pattern: Matrix, structure: Matrix, correlation: Matrix,
                 scores: Matrix, coefficients: Matrix) {
        let nObs = work.rows
        let nFeatures = initialScores.cols
        guard nObs > nFeatures else { throw InfomaxError.tooFewObservations }

        guard let (whitened, sphere) = eeglabSphere(initialScores) else {
            throw InfomaxError.zeroVarianceScore
        }

        let block = Int(min(5 * log(Double(nObs)), 0.3 * Double(nObs)).rounded(.up))
        guard block >= 2 else { throw InfomaxError.tooFewObservations }

        let extBlocks = (extended && rotopt != nil) ? Int(rotopt!) : 1
        let result = run(
            whitened,
            extended: extended,
            lRate: 0.00065 / log(Double(nFeatures)),
            block: block,
            wChange: nFeatures > 32 ? 1e-7 : 1e-6,
            annealStep: extended ? 0.98 : 0.9,
            extBlocks: extBlocks,
            maxIter: 512,
            blowup: 1e9,
            blowupFac: 0.8,
            nSmallAngle: nil,
            seed: seed
        )
        let unmixing = orderLikeEeglab(result.unmixing, whitened: whitened)
        let transform = sphere.transposed().multiply(unmixing.transposed())   // F × F
        let scores = initialScores.multiply(transform)                        // obs × F
        let coefficients = initialCoefficients.multiply(transform)            // nVars × F
        let structure = columnCorrelations(work, scores)                      // nVars × F
        let correlation = columnCorrelations(scores, scores)                  // F × F
        // fac_pat = (fac_cor^T \ fac_str^T)^T
        let pattern = try correlation.transposed().solve(structure.transposed()).transposed()
        return (pattern, structure, correlation, scores, coefficients)
    }

    /// EEGLAB-style sphering: returns whitened scores (obs × F) and the sphere
    /// matrix (F × F), or nil if the scores have zero global variance.
    private static func eeglabSphere(_ scores: Matrix) -> (whitened: Matrix, sphere: Matrix)? {
        let nObs = scores.rows
        let nF = scores.cols
        // features × samples, centered per feature (row mean over samples).
        let featMean = (0..<nF).map { f in scores.column(f).reduce(0, +) / Double(nObs) }
        var centered = Matrix(rows: nF, cols: nObs)            // F × obs
        for f in 0..<nF {
            let col = scores.column(f)
            for s in 0..<nObs { centered[f, s] = col[s] - featMean[f] }
        }
        // Global population standard deviation over all elements.
        let total = centered.grid.reduce(0, +)
        let mean = total / Double(centered.grid.count)
        let variance = centered.grid.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(centered.grid.count)
        let globalSd = variance.squareRoot()
        guard globalSd != 0 else { return nil }

        let scaled = centered.scaled(1.0 / globalSd)           // F × obs
        let covariance = scaled.multiply(scaled.transposed()).scaled(1.0 / Double(nObs))  // F × F
        guard let (u, s, _) = try? covariance.svd() else { return nil }
        // sphere = u @ diag(1/sqrt(s)) @ u^T / globalSd
        var scaledU = u                                        // F × F
        for c in 0..<scaledU.cols {
            let inv = 1.0 / s[c].squareRoot()
            for r in 0..<scaledU.rows { scaledU[r, c] *= inv }
        }
        let sphere = scaledU.multiply(u.transposed()).scaled(1.0 / globalSd)   // F × F
        // whitened = centered_unscaled^T @ sphere^T  (obs × F)
        let whitened = centered.transposed().multiply(sphere.transposed())
        return (whitened, sphere)
    }

    /// Reorder the unmixing rows by descending component variance index, as in
    /// EEGLAB's `pop_runica` post-processing.
    private static func orderLikeEeglab(_ unmixing: Matrix, whitened: Matrix) -> Matrix {
        let sources = whitened.multiply(unmixing.transposed()).transposed()   // F × obs
        let nF = sources.rows
        let nObs = sources.cols
        guard let mixing = try? unmixing.pseudoinverse() else { return unmixing }  // F × F
        let varianceIndex: [Double] = (0..<nF).map { k in
            let mixCol = (0..<mixing.rows).reduce(0.0) { $0 + mixing[$1, k] * mixing[$1, k] }
            let srcRow = (0..<nObs).reduce(0.0) { $0 + sources[k, $1] * sources[k, $1] }
            return mixCol * srcRow / Double(nF * nObs - 1)
        }
        let order = Array(0..<nF).sorted { varianceIndex[$0] > varianceIndex[$1] }
        var out = Matrix(rows: nF, cols: unmixing.cols)
        for (newR, oldR) in order.enumerated() {
            for c in 0..<unmixing.cols { out[newR, c] = unmixing[oldR, c] }
        }
        return out
    }

    /// Per-column Pearson correlations between the columns of `left` (obs × p)
    /// and `right` (obs × q) → p × q.
    private static func columnCorrelations(_ left: Matrix, _ right: Matrix) -> Matrix {
        let nObs = left.rows
        let leftMean = columnMean(left), rightMean = columnMean(right)
        let leftSd = columnStd(left), rightSd = columnStd(right)
        let lc = centerColumns(left, by: leftMean)
        let rc = centerColumns(right, by: rightMean)
        var cov = lc.transposed().multiply(rc)                 // p × q
        let scale = 1.0 / Double(nObs - 1)
        for c in 0..<cov.cols {
            for r in 0..<cov.rows {
                let denom = leftSd[r] * rightSd[c]
                cov[r, c] = denom != 0 ? cov[r, c] * scale / denom : 0
            }
        }
        return cov
    }
}
