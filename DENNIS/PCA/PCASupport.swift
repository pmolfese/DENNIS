//
//  PCASupport.swift
//  DENNIS
//
//  Column/row statistics and reshaping helpers used by the PCA engine, plus the
//  PCA mode enum shared by the single- and two-step workflows.
//

import Accelerate

/// Which dimension the PCA treats as variables.
nonisolated enum PCAMode: String, Sendable {
    case temporal, spatial, frequency, asIs

    var factorPrefix: String {
        switch self {
        case .temporal: "TF"
        case .spatial: "SF"
        case .frequency: "FF"
        case .asIs: "F"
        }
    }
}

nonisolated extension Matrix {
    func scaled(_ factor: Double) -> Matrix {
        Matrix(rows: rows, cols: cols, columnMajor: grid.map { $0 * factor })
    }
}

// MARK: - Column / row statistics (ddof = 1)

nonisolated func columnMean(_ m: Matrix) -> [Double] {
    let n = m.rows
    guard n > 0 else { return [Double](repeating: 0, count: m.cols) }
    var means = [Double](repeating: 0, count: m.cols)
    m.grid.withUnsafeBufferPointer { p in
        guard let base = p.baseAddress else { return }
        for c in 0..<m.cols {
            vDSP_meanvD(base + c * n, 1, &means[c], vDSP_Length(n))
        }
    }
    return means
}

nonisolated func columnStd(_ m: Matrix) -> [Double] {
    let n = m.rows
    guard n > 1 else { return [Double](repeating: 0, count: m.cols) }
    let means = columnMean(m)
    var stds = [Double](repeating: 0, count: m.cols)
    var centered = [Double](repeating: 0, count: n)
    m.grid.withUnsafeBufferPointer { p in
        guard let base = p.baseAddress else { return }
        for c in 0..<m.cols {
            var negMean = -means[c]
            vDSP_vsaddD(base + c * n, 1, &negMean, &centered, 1, vDSP_Length(n))
            var ss = 0.0
            vDSP_svesqD(centered, 1, &ss, vDSP_Length(n))
            stds[c] = (ss / Double(n - 1)).squareRoot()
        }
    }
    return stds
}

nonisolated func centerColumns(_ m: Matrix, by means: [Double]) -> Matrix {
    let n = m.rows
    var out = m
    out.grid.withUnsafeMutableBufferPointer { p in
        guard let base = p.baseAddress else { return }
        for c in 0..<m.cols {
            var negMean = -means[c]
            vDSP_vsaddD(base + c * n, 1, &negMean, base + c * n, 1, vDSP_Length(n))
        }
    }
    return out
}

/// Divide each column `c` by `factors[c]`.
nonisolated func scaleColumns(_ m: Matrix, by factors: [Double]) -> Matrix {
    let n = m.rows
    var out = m
    out.grid.withUnsafeMutableBufferPointer { p in
        guard let base = p.baseAddress else { return }
        for c in 0..<m.cols where factors[c] != 0 {
            var divisor = factors[c]
            vDSP_vsdivD(base + c * n, 1, &divisor, base + c * n, 1, vDSP_Length(n))
        }
    }
    return out
}

/// Divide each row `r` by `factors[r]`.
nonisolated func scaleRows(_ m: Matrix, by factors: [Double]) -> Matrix {
    var out = m
    for r in 0..<m.rows where factors[r] != 0 {
        for c in 0..<m.cols { out[r, c] /= factors[r] }
    }
    return out
}

// MARK: - Reshaping

/// `m^T · m` (variables × variables) for an observations × variables matrix,
/// computed in one symmetric rank-k update (BLAS dsyrk) so the huge
/// observations × variables matrix is never explicitly transposed.
nonisolated func crossProduct(_ m: Matrix) -> Matrix {
    let nObs = m.rows, nVars = m.cols
    var result = Matrix(rows: nVars, cols: nVars)
    m.grid.withUnsafeBufferPointer { a in
        result.grid.withUnsafeMutableBufferPointer { c in
            cblas_dsyrk(
                CblasColMajor, CblasUpper, CblasTrans,
                Int32(nVars), Int32(nObs),
                1.0, a.baseAddress, Int32(nObs),
                0.0, c.baseAddress, Int32(nVars)
            )
        }
    }
    // dsyrk only fills the upper triangle; mirror to the lower.
    for i in 0..<nVars {
        for j in (i + 1)..<nVars { result[j, i] = result[i, j] }
    }
    return result
}

/// `m · mᵀ` (rows × rows) via a symmetric rank-k update (BLAS dsyrk). Used to
/// get a tensor mode's singular spectrum from the small mode×mode Gram rather
/// than a full SVD of the wide unfolding.
nonisolated func gramRows(_ m: Matrix) -> Matrix {
    let rows = m.rows, cols = m.cols
    var result = Matrix(rows: rows, cols: rows)
    m.grid.withUnsafeBufferPointer { a in
        result.grid.withUnsafeMutableBufferPointer { c in
            cblas_dsyrk(
                CblasColMajor, CblasUpper, CblasNoTrans,
                Int32(rows), Int32(cols),
                1.0, a.baseAddress, Int32(rows),
                0.0, c.baseAddress, Int32(rows)
            )
        }
    }
    for i in 0..<rows {
        for j in (i + 1)..<rows { result[j, i] = result[i, j] }
    }
    return result
}

nonisolated func selectColumns(_ m: Matrix, _ indices: [Int]) -> Matrix {
    var out = Matrix(rows: m.rows, cols: indices.count)
    for (newC, oldC) in indices.enumerated() {
        for r in 0..<m.rows { out[r, newC] = m[r, oldC] }
    }
    return out
}

nonisolated func reorderColumns(_ m: Matrix, order: [Int]) -> Matrix {
    selectColumns(m, order)
}

/// Reorder both rows and columns of a square matrix by `order`.
nonisolated func reorderSymmetric(_ m: Matrix, order: [Int]) -> Matrix {
    var out = Matrix(rows: order.count, cols: order.count)
    for (i, oi) in order.enumerated() {
        for (j, oj) in order.enumerated() { out[i, j] = m[oi, oj] }
    }
    return out
}
