//
//  PCASupport.swift
//  DENNIS
//
//  Column/row statistics and reshaping helpers used by the PCA engine, plus the
//  PCA mode enum shared by the single- and two-step workflows.
//

import Foundation

/// Which dimension the PCA treats as variables.
enum PCAMode: String, Sendable {
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

extension Matrix {
    func scaled(_ factor: Double) -> Matrix {
        Matrix(rows: rows, cols: cols, columnMajor: grid.map { $0 * factor })
    }
}

// MARK: - Column / row statistics (ddof = 1)

func columnMean(_ m: Matrix) -> [Double] {
    (0..<m.cols).map { c in
        (0..<m.rows).reduce(0.0) { $0 + m[$1, c] } / Double(m.rows)
    }
}

func columnStd(_ m: Matrix) -> [Double] {
    let means = columnMean(m)
    guard m.rows > 1 else { return [Double](repeating: 0, count: m.cols) }
    return (0..<m.cols).map { c in
        let ss = (0..<m.rows).reduce(0.0) {
            let d = m[$1, c] - means[c]; return $0 + d * d
        }
        return (ss / Double(m.rows - 1)).squareRoot()
    }
}

func centerColumns(_ m: Matrix, by means: [Double]) -> Matrix {
    var out = m
    for c in 0..<m.cols {
        for r in 0..<m.rows { out[r, c] -= means[c] }
    }
    return out
}

/// Divide each column `c` by `factors[c]`.
func scaleColumns(_ m: Matrix, by factors: [Double]) -> Matrix {
    var out = m
    for c in 0..<m.cols where factors[c] != 0 {
        for r in 0..<m.rows { out[r, c] /= factors[c] }
    }
    return out
}

/// Divide each row `r` by `factors[r]`.
func scaleRows(_ m: Matrix, by factors: [Double]) -> Matrix {
    var out = m
    for r in 0..<m.rows where factors[r] != 0 {
        for c in 0..<m.cols { out[r, c] /= factors[r] }
    }
    return out
}

// MARK: - Reshaping

/// `m^T · m` (variables × variables) for an observations × variables matrix.
func crossProduct(_ m: Matrix) -> Matrix {
    m.transposed().multiply(m)
}

func selectColumns(_ m: Matrix, _ indices: [Int]) -> Matrix {
    var out = Matrix(rows: m.rows, cols: indices.count)
    for (newC, oldC) in indices.enumerated() {
        for r in 0..<m.rows { out[r, newC] = m[r, oldC] }
    }
    return out
}

func reorderColumns(_ m: Matrix, order: [Int]) -> Matrix {
    selectColumns(m, order)
}

/// Reorder both rows and columns of a square matrix by `order`.
func reorderSymmetric(_ m: Matrix, order: [Int]) -> Matrix {
    var out = Matrix(rows: order.count, cols: order.count)
    for (i, oi) in order.enumerated() {
        for (j, oj) in order.enumerated() { out[i, j] = m[oi, oj] }
    }
    return out
}
