//
//  PARAFAC2.swift
//  DENNIS
//
//  PARAFAC2 for equal-length EEG tensors, aimed at ERP latency/shape variation.
//  The tensor is sliced along a stable mode (usually Subject), one mode is allowed
//  to vary by slice (usually Time), and all remaining modes are folded into one
//  feature mode. Each slice is modeled as X_k ≈ P_k H diag(c_k) Bᵀ, with P_k
//  orthonormal. The returned CPResult contains a representative average varying
//  factor, feature loadings, and slice/subject loadings.
//

import Foundation

nonisolated enum PARAFAC2 {

    struct Options: Sendable {
        var rank: Int
        var maxIter = 200
        var tol = 1e-7
        var nStarts = 6
        var seed: UInt64 = 0
    }

    enum PARAFAC2Error: Error, LocalizedError {
        case emptyTensor
        case invalidModes
        case rankTooLarge(rank: Int, max: Int)

        var errorDescription: String? {
            switch self {
            case .emptyTensor:
                "The tensor has no energy to decompose."
            case .invalidModes:
                "PARAFAC2 needs distinct varying and slice modes."
            case .rankTooLarge(let rank, let max):
                "Rank \(rank) exceeds the PARAFAC2 limit \(max)."
            }
        }
    }

    private struct StartResult: Sendable {
        let start: Int
        let fit: Double
        let p: [Matrix]
        let h: Matrix
        let b: Matrix
        let c: Matrix
        let iterations: Int
    }

    static func decompose(_ tensor: MultiwayTensor,
                          modeNames: [String],
                          varyingMode: Int,
                          sliceMode: Int,
                          options: Options,
                          report: (@Sendable (Double, String) -> Void)? = nil) async throws -> CPResult {
        guard tensor.frobeniusNormSquared > 0 else { throw PARAFAC2Error.emptyTensor }
        guard varyingMode != sliceMode,
              tensor.dims.indices.contains(varyingMode),
              tensor.dims.indices.contains(sliceMode) else { throw PARAFAC2Error.invalidModes }

        let slices = matrixSlices(tensor, rowMode: varyingMode, sliceMode: sliceMode)
        let rowCount = tensor.dims[varyingMode]
        let sliceCount = tensor.dims[sliceMode]
        let featureCount = slices.first?.cols ?? 0
        let maxRank = min(rowCount, featureCount)
        let r = options.rank
        guard r > 0, r <= maxRank else { throw PARAFAC2Error.rankTooLarge(rank: r, max: maxRank) }

        let starts = max(options.nStarts, 1)
        var completed = 0
        var candidates: [StartResult] = []
        await withTaskGroup(of: StartResult.self) { group in
            for start in 0..<starts {
                group.addTask {
                    var rng = SplitMix64(seed: seed(for: options.seed, start: start))
                    return runStart(start: start, slices: slices, rank: r,
                                    maxIter: options.maxIter, tol: options.tol, rng: &rng)
                }
            }

            for await candidate in group {
                candidates.append(candidate)
                completed += 1
                report?(Double(completed) / Double(starts) * 0.96,
                        "PARAFAC2 starts \(completed)/\(starts)")
            }
        }

        let sorted = candidates.sorted {
            if abs($0.fit - $1.fit) > 1e-9 { return $0.fit > $1.fit }
            return $0.start < $1.start
        }
        guard let best = sorted.first else { throw PARAFAC2Error.emptyTensor }

        report?(0.97, "Normalizing PARAFAC2 components")
        var varying = representativeVaryingFactor(p: best.p, h: best.h)
        var feature = best.b
        var subject = best.c
        var factors = [varying, feature, subject]
        var weights: [Double]
        (factors, weights) = normalize(factors)
        sortByWeight(&factors, &weights)
        fixSigns(&factors)
        varying = factors[0]
        feature = factors[1]
        subject = factors[2]

        let names = [
            varyingMode < modeNames.count ? modeNames[varyingMode] : "Varying",
            "Feature",
            sliceMode < modeNames.count ? modeNames[sliceMode] : "Slice",
        ]
        let bestCount = candidates.filter { abs($0.fit - best.fit) <= 1e-6 }.count
        return CPResult(
            factors: [varying, feature, subject],
            weights: weights,
            modeNames: names,
            dims: [rowCount, featureCount, sliceCount],
            rank: r,
            fit: best.fit,
            iterations: best.iterations,
            nStarts: options.nStarts,
            bestStartCount: bestCount,
            maxCongruence: maxCongruence([varying, feature, subject])
        )
    }

    private static func runStart(start: Int, slices: [Matrix], rank r: Int,
                                 maxIter: Int, tol: Double, rng: inout SplitMix64) -> StartResult {
        let rowCount = slices.first?.rows ?? 0
        let featureCount = slices.first?.cols ?? 0
        let sliceCount = slices.count
        var h = randomMatrix(rows: r, cols: r, rng: &rng)
        var b = randomMatrix(rows: featureCount, cols: r, rng: &rng)
        var c = randomMatrix(rows: sliceCount, cols: r, rng: &rng)
        var p = (0..<sliceCount).map { _ in orthonormalRandom(rows: rowCount, cols: r, rng: &rng) }
        var prevFit = -Double.infinity
        var fit = 0.0
        var iters = 0

        while iters < maxIter {
            for k in 0..<sliceCount {
                let z = componentRows(h: h, b: b, cRow: c.columnValues(row: k))     // R × J
                let m = slices[k].multiply(z.transposed())                          // I × R
                p[k] = procrustesOrthonormal(m)
            }

            let projected = projectedTensor(slices: slices, p: p, rank: r)
            var factors = [h, b, c]
            cpSweep(&factors, tensor: projected)
            h = factors[0]; b = factors[1]; c = factors[2]

            fit = fitOf(slices: slices, p: p, h: h, b: b, c: c)
            iters += 1
            if fit - prevFit < tol { break }
            prevFit = fit
        }

        return StartResult(start: start, fit: fit, p: p, h: h, b: b, c: c, iterations: iters)
    }

    private static func matrixSlices(_ tensor: MultiwayTensor, rowMode: Int, sliceMode: Int) -> [Matrix] {
        let rowCount = tensor.dims[rowMode]
        let sliceCount = tensor.dims[sliceMode]
        let featureModes = tensor.dims.indices.filter { $0 != rowMode && $0 != sliceMode }
        let featureCount = featureModes.reduce(1) { $0 * tensor.dims[$1] }
        var featureStride = [Int](repeating: 0, count: tensor.order)
        var acc = 1
        for mode in featureModes { featureStride[mode] = acc; acc *= tensor.dims[mode] }
        var out = (0..<sliceCount).map { _ in Matrix(rows: rowCount, cols: featureCount) }
        var idx = [Int](repeating: 0, count: tensor.order)
        for value in tensor.data {
            var col = 0
            for mode in featureModes { col += idx[mode] * featureStride[mode] }
            out[idx[sliceMode]][idx[rowMode], col] = value
            var a = 0
            while a < tensor.order {
                idx[a] += 1
                if idx[a] < tensor.dims[a] { break }
                idx[a] = 0
                a += 1
            }
        }
        return out
    }

    private static func projectedTensor(slices: [Matrix], p: [Matrix], rank r: Int) -> MultiwayTensor {
        let featureCount = slices.first?.cols ?? 0
        let sliceCount = slices.count
        var data = [Double](repeating: 0, count: r * featureCount * sliceCount)
        for k in 0..<sliceCount {
            let y = p[k].transposed().multiply(slices[k])       // R × J
            for col in 0..<featureCount {
                for row in 0..<r { data[k * r * featureCount + col * r + row] = y[row, col] }
            }
        }
        return MultiwayTensor(dims: [r, featureCount, sliceCount], data: data)
    }

    private static func cpSweep(_ factors: inout [Matrix], tensor: MultiwayTensor) {
        let unfoldings = (0..<3).map { tensor.unfold(mode: $0) }
        for mode in 0..<3 {
            let rest = (0..<3).filter { $0 != mode }
            var kr = factors[rest[0]]
            for idx in 1..<rest.count { kr = khatriRao(factors[rest[idx]], kr) }
            let mttkrp = unfoldings[mode].multiply(kr)
            var v = crossProduct(factors[rest[0]])
            for idx in 1..<rest.count { v = hadamard(v, crossProduct(factors[rest[idx]])) }
            let vInv = (try? v.pseudoinverse()) ?? v
            factors[mode] = mttkrp.multiply(vInv)
        }
    }

    private static func fitOf(slices: [Matrix], p: [Matrix], h: Matrix, b: Matrix, c: Matrix) -> Double {
        var error2 = 0.0
        var norm2 = 0.0
        for k in slices.indices {
            let z = componentRows(h: h, b: b, cRow: c.columnValues(row: k))
            let xhat = p[k].multiply(z)
            for i in slices[k].grid.indices {
                let diff = slices[k].grid[i] - xhat.grid[i]
                error2 += diff * diff
                norm2 += slices[k].grid[i] * slices[k].grid[i]
            }
        }
        guard norm2 > 0 else { return 0 }
        return 1 - (error2 / norm2).squareRoot()
    }

    private static func componentRows(h: Matrix, b: Matrix, cRow: [Double]) -> Matrix {
        var scaled = h
        for col in 0..<h.cols {
            let weight = cRow[col]
            for row in 0..<h.rows { scaled[row, col] *= weight }
        }
        return scaled.multiply(b.transposed())
    }

    private static func representativeVaryingFactor(p: [Matrix], h: Matrix) -> Matrix {
        let rows = p.first?.rows ?? 0
        let r = h.cols
        var out = Matrix(rows: rows, cols: r)
        guard !p.isEmpty else { return out }
        for pk in p {
            let ak = pk.multiply(h)
            for i in ak.grid.indices { out.grid[i] += ak.grid[i] }
        }
        for i in out.grid.indices { out.grid[i] /= Double(p.count) }
        return out
    }

    private static func procrustesOrthonormal(_ m: Matrix) -> Matrix {
        guard let svd = try? m.svd() else { return m }
        return svd.u.multiply(svd.vt)
    }

    private static func orthonormalRandom(rows: Int, cols: Int, rng: inout SplitMix64) -> Matrix {
        let m = randomMatrix(rows: rows, cols: cols, rng: &rng)
        return procrustesOrthonormal(m)
    }

    private static func randomMatrix(rows: Int, cols: Int, rng: inout SplitMix64) -> Matrix {
        var grid = [Double](repeating: 0, count: rows * cols)
        for i in grid.indices { grid[i] = rng.nextGaussian() }
        return Matrix(rows: rows, cols: cols, columnMajor: grid)
    }

    private static func khatriRao(_ b: Matrix, _ c: Matrix) -> Matrix {
        let r = b.cols
        let rowsB = b.rows, rowsC = c.rows
        var out = Matrix(rows: rowsB * rowsC, cols: r)
        for col in 0..<r {
            for ib in 0..<rowsB {
                let bv = b[ib, col]
                for ic in 0..<rowsC { out[ib * rowsC + ic, col] = bv * c[ic, col] }
            }
        }
        return out
    }

    private static func hadamard(_ a: Matrix, _ b: Matrix) -> Matrix {
        Matrix(rows: a.rows, cols: a.cols, columnMajor: zip(a.grid, b.grid).map(*))
    }

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

    private static func fixSigns(_ factors: inout [Matrix]) {
        guard let r = factors.first?.cols, factors.count > 1 else { return }
        let sink = factors.count - 1
        for c in 0..<r {
            for m in 0..<sink {
                var maxAbs = 0.0, sign = 1.0
                for row in 0..<factors[m].rows where abs(factors[m][row, c]) > maxAbs {
                    maxAbs = abs(factors[m][row, c])
                    sign = factors[m][row, c] < 0 ? -1 : 1
                }
                if sign < 0 {
                    for row in 0..<factors[m].rows { factors[m][row, c] *= -1 }
                    for row in 0..<factors[sink].rows { factors[sink][row, c] *= -1 }
                }
            }
        }
    }

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

    private static func seed(for base: UInt64, start: Int) -> UInt64 {
        base &+ UInt64(start) &* 0x9E3779B97F4A7C15
    }
}

private extension Matrix {
    func columnValues(row: Int) -> [Double] {
        (0..<cols).map { self[row, $0] }
    }
}
