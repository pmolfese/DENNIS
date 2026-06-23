//
//  Rotations.swift
//  DENNIS
//
//  Varimax (orthogonal) and Promax (oblique) factor rotations, ported from the
//  ERP PCA Toolkit / mne_erppca implementation. Varimax uses the Kaiser
//  pairwise (Jacobi) sweep with random restarts; Promax follows the SAS branch.
//

import Foundation

nonisolated enum Rotations {

    // MARK: - Varimax

    /// Rotate `loadings` (n_vars × n_factors) with the Toolkit Varimax procedure.
    static func varimax(_ loadings: Matrix,
                        nRestarts: Int = 10,
                        maxIter: Int = 1000,
                        tol: Double = 1e-5,
                        seed: UInt64 = 0) -> Matrix {
        let nVars = loadings.rows
        let nFactors = loadings.cols
        if nFactors == 1 { return loadings }

        var rng = SplitMix64(seed: seed)
        var best: Matrix?
        var bestValue = -Double.infinity

        for _ in 0..<nRestarts {
            let start = loadings.multiply(randomOrthogonal(nFactors, rng: &rng))
            let rotated = sweep(start, nVars: nVars, nFactors: nFactors, maxIter: maxIter, tol: tol)
            let value = criterion(rotated)
            if value > bestValue { bestValue = value; best = rotated }
        }
        return best ?? loadings
    }

    /// One full Kaiser pairwise optimization to convergence.
    private static func sweep(_ start: Matrix, nVars: Int, nFactors: Int,
                              maxIter: Int, tol: Double) -> Matrix {
        var rotated = start
        let fullCounter = nFactors * (nFactors - 1) / 2
        var counter = fullCounter
        var iter = 0

        while counter > 0 && iter < maxIter {
            for f1 in 0..<(nFactors - 1) {
                for f2 in (f1 + 1)..<nFactors {
                    let a1 = rotated.column(f1)
                    let a2 = rotated.column(f2)
                    var rA = 0.0, rB = 0.0, rC = 0.0, rD = 0.0
                    for i in 0..<nVars {
                        let u = a1[i] * a1[i] - a2[i] * a2[i]   // ru
                        let v = 2 * a1[i] * a2[i]               // rv
                        rA += u
                        rB += v
                        rC += u * u - v * v
                        rD += 2 * u * v
                    }
                    let num = rD - (2 * rA * rB) / Double(nVars)
                    let den = rC - (rA * rA - rB * rB) / Double(nVars)
                    if den != 0 && abs(num / den) > tol {
                        let g = (num * num + den * den).squareRoot()
                        let cos4phi = den / g
                        let cos2phi = ((1 + cos4phi) / 2).squareRoot()
                        let cosphi = ((1 + cos2phi) / 2).squareRoot()
                        var sinphi = ((1 - cos2phi) / 2).squareRoot()
                        sinphi = num < 0 ? -abs(sinphi) : abs(sinphi)

                        var newA1 = a1, newA2 = a2
                        for i in 0..<nVars {
                            newA1[i] = a1[i] * cosphi + a2[i] * sinphi
                            newA2[i] = -a1[i] * sinphi + a2[i] * cosphi
                        }
                        rotated = rotated.setColumn(f1, newA1).setColumn(f2, newA2)
                        counter = fullCounter
                    } else {
                        counter -= 1
                    }
                }
            }
            iter += 1
        }
        return rotated
    }

    /// Selection criterion among restarts: sum over variables of the variance
    /// (ddof=1) of squared loadings across factors — matches the Python code.
    private static func criterion(_ m: Matrix) -> Double {
        guard m.cols > 1 else { return 0 }
        var total = 0.0
        for r in 0..<m.rows {
            let squares = (0..<m.cols).map { m[r, $0] * m[r, $0] }
            let mean = squares.reduce(0, +) / Double(squares.count)
            let varr = squares.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(squares.count - 1)
            total += varr
        }
        return total
    }

    // MARK: - Promax (SAS branch)

    /// Returns `(fac_pat, fac_cor)` for the oblique Promax rotation of an
    /// already-Varimax-rotated loading matrix.
    static func promax(_ varimaxLoadings: Matrix, power: Double = 3) throws -> (pattern: Matrix, correlation: Matrix) {
        let v = varimaxLoadings
        let nf = v.cols

        // h = row-normalize, then divide each column by its max abs, then
        // raise to the power preserving sign.
        var h = rowNormalize(v)
        let colMax = (0..<nf).map { c in (0..<h.rows).map { abs(h[$0, c]) }.max() ?? 1 }
        for c in 0..<nf where colMax[c] != 0 {
            for r in 0..<h.rows { h[r, c] /= colMax[c] }
        }
        for c in 0..<nf {
            for r in 0..<h.rows {
                let sign = v[r, c] > 0 ? 1.0 : (v[r, c] < 0 ? -1.0 : 0.0)
                h[r, c] = pow(abs(h[r, c]), power) * sign
            }
        }

        let vt = v.transposed()
        var lam = try (vt.multiply(v)).solve(vt.multiply(h))   // nf × nf
        // Normalize columns of lam.
        for c in 0..<nf {
            let norm = (0..<lam.rows).reduce(0.0) { $0 + lam[$1, c] * lam[$1, c] }.squareRoot()
            if norm != 0 { for r in 0..<lam.rows { lam[r, c] /= norm } }
        }

        let psi = lam.transposed().multiply(lam)
        let r = try psi.inverse()
        let invD = (0..<r.rows).map { r[$0, $0].squareRoot() }
        var transform = lam
        for c in 0..<transform.cols {
            for row in 0..<transform.rows { transform[row, c] *= invD[c] }
        }
        let invTransform = try transform.inverse()
        let phi = invTransform.multiply(invTransform.transposed())
        return (v.multiply(transform), phi)
    }

    private static func rowNormalize(_ m: Matrix) -> Matrix {
        var out = m
        for r in 0..<m.rows {
            let norm = (0..<m.cols).reduce(0.0) { $0 + m[r, $1] * m[r, $1] }.squareRoot()
            if norm != 0 { for c in 0..<m.cols { out[r, c] /= norm } }
        }
        return out
    }

    // MARK: - Random orthogonal start

    /// A random orthogonal n×n matrix built from a product of Givens rotations
    /// (sufficient for varimax restarts; not Haar-uniform).
    private static func randomOrthogonal(_ n: Int, rng: inout SplitMix64) -> Matrix {
        var q = Matrix.identity(n)
        guard n > 1 else { return q }
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                let angle = rng.nextUnit() * 2 * .pi
                let c = cos(angle), s = sin(angle)
                let coli = q.column(i), colj = q.column(j)
                var newI = coli, newJ = colj
                for r in 0..<n {
                    newI[r] = c * coli[r] - s * colj[r]
                    newJ[r] = s * coli[r] + c * colj[r]
                }
                q = q.setColumn(i, newI).setColumn(j, newJ)
            }
        }
        return q
    }
}

/// Tiny seedable PRNG so rotation restarts are reproducible.
nonisolated struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform double in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Standard-normal double via the Box-Muller transform.
    mutating func nextGaussian() -> Double {
        // Avoid log(0) by keeping u1 in (0, 1].
        let u1 = 1.0 - nextUnit()
        let u2 = nextUnit()
        return (-2.0 * Foundation.log(u1)).squareRoot() * Foundation.cos(2.0 * Double.pi * u2)
    }
}
