//
//  Matrix.swift
//  DENNIS
//
//  A small column-major dense double matrix backed by Accelerate (BLAS/LAPACK).
//  Column-major storage matches LAPACK/Fortran so the linear-algebra wrappers
//  can hand pointers straight through. This is the numerical foundation for the
//  ERP dual-PCA engine.
//

import Accelerate

nonisolated struct Matrix {
    let rows: Int
    let cols: Int
    /// Column-major: element(r, c) == grid[c * rows + r].
    var grid: [Double]

    init(rows: Int, cols: Int, repeating value: Double = 0) {
        self.rows = rows
        self.cols = cols
        self.grid = [Double](repeating: value, count: rows * cols)
    }

    init(rows: Int, cols: Int, columnMajor grid: [Double]) {
        precondition(grid.count == rows * cols, "grid size mismatch")
        self.rows = rows
        self.cols = cols
        self.grid = grid
    }

    /// Build from row-major nested arrays (`rowMajor[r][c]`).
    init(_ rowMajor: [[Double]]) {
        let rows = rowMajor.count
        let cols = rowMajor.first?.count ?? 0
        var grid = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            precondition(rowMajor[r].count == cols, "ragged matrix")
            for c in 0..<cols { grid[c * rows + r] = rowMajor[r][c] }
        }
        self.init(rows: rows, cols: cols, columnMajor: grid)
    }

    subscript(_ r: Int, _ c: Int) -> Double {
        get { grid[c * rows + r] }
        set { grid[c * rows + r] = newValue }
    }

    func column(_ c: Int) -> [Double] {
        Array(grid[(c * rows)..<((c + 1) * rows)])
    }

    func setColumn(_ c: Int, _ values: [Double]) -> Matrix {
        var copy = self
        for r in 0..<rows { copy[r, c] = values[r] }
        return copy
    }

    /// Row-major nested arrays, e.g. for embedding or comparison.
    func toRowMajor() -> [[Double]] {
        (0..<rows).map { r in (0..<cols).map { c in self[r, c] } }
    }

    // MARK: - BLAS

    /// Matrix product `self * other` via cblas_dgemm.
    func multiply(_ other: Matrix) -> Matrix {
        precondition(cols == other.rows, "inner dimensions disagree")
        var result = Matrix(rows: rows, cols: other.cols)
        cblas_dgemm(
            CblasColMajor, CblasNoTrans, CblasNoTrans,
            Int32(rows), Int32(other.cols), Int32(cols),
            1.0, grid, Int32(rows),
            other.grid, Int32(other.rows),
            0.0, &result.grid, Int32(rows)
        )
        return result
    }

    func transposed() -> Matrix {
        var t = Matrix(rows: cols, cols: rows)
        for c in 0..<cols {
            for r in 0..<rows { t[c, r] = self[r, c] }
        }
        return t
    }

    // MARK: - LAPACK

    enum LinAlgError: Error { case eigenFailed(Int), svdFailed(Int), solveFailed(Int) }

    /// Symmetric eigendecomposition (uses the upper triangle). Returns
    /// eigenvalues in **ascending** order and eigenvectors as columns.
    func symmetricEigen() throws -> (values: [Double], vectors: Matrix) {
        precondition(rows == cols, "eigendecomposition needs a square matrix")
        let n = rows
        var a = grid                       // dsyev overwrites with eigenvectors
        var values = [Double](repeating: 0, count: n)
        var jobz: CChar = 86               // 'V'
        var uplo: CChar = 85               // 'U'
        var nn = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var info = __CLPK_integer(0)

        var workQuery = Double(0)
        var lwork = __CLPK_integer(-1)
        dsyev_(&jobz, &uplo, &nn, &a, &lda, &values, &workQuery, &lwork, &info)
        lwork = __CLPK_integer(workQuery)
        var work = [Double](repeating: 0, count: Int(lwork))
        dsyev_(&jobz, &uplo, &nn, &a, &lda, &values, &work, &lwork, &info)

        guard info == 0 else { throw LinAlgError.eigenFailed(Int(info)) }
        return (values, Matrix(rows: n, cols: n, columnMajor: a))
    }

    /// Thin SVD: `self == U * diag(S) * Vt`, with `k = min(rows, cols)`.
    func svd() throws -> (u: Matrix, s: [Double], vt: Matrix) {
        let m = rows, n = cols, k = min(m, n)
        var a = grid                       // destroyed by dgesvd
        var s = [Double](repeating: 0, count: k)
        var u = [Double](repeating: 0, count: m * k)
        var vt = [Double](repeating: 0, count: k * n)
        var jobu: CChar = 83               // 'S'
        var jobvt: CChar = 83              // 'S'
        var mm = __CLPK_integer(m), nn = __CLPK_integer(n)
        var lda = __CLPK_integer(m), ldu = __CLPK_integer(m), ldvt = __CLPK_integer(k)
        var info = __CLPK_integer(0)

        var workQuery = Double(0)
        var lwork = __CLPK_integer(-1)
        dgesvd_(&jobu, &jobvt, &mm, &nn, &a, &lda, &s, &u, &ldu, &vt, &ldvt, &workQuery, &lwork, &info)
        lwork = __CLPK_integer(workQuery)
        var work = [Double](repeating: 0, count: Int(lwork))
        dgesvd_(&jobu, &jobvt, &mm, &nn, &a, &lda, &s, &u, &ldu, &vt, &ldvt, &work, &lwork, &info)

        guard info == 0 else { throw LinAlgError.svdFailed(Int(info)) }
        return (Matrix(rows: m, cols: k, columnMajor: u), s, Matrix(rows: k, cols: n, columnMajor: vt))
    }

    /// Solve `self * X = b` for square `self` (LU via dgesv).
    func solve(_ b: Matrix) throws -> Matrix {
        precondition(rows == cols && b.rows == rows, "solve dimension mismatch")
        let n = rows
        var a = grid
        var x = b.grid
        var nn = __CLPK_integer(n)
        var nrhs = __CLPK_integer(b.cols)
        var lda = __CLPK_integer(n)
        var ldb = __CLPK_integer(n)
        var ipiv = [__CLPK_integer](repeating: 0, count: n)
        var info = __CLPK_integer(0)
        dgesv_(&nn, &nrhs, &a, &lda, &ipiv, &x, &ldb, &info)
        guard info == 0 else { throw LinAlgError.solveFailed(Int(info)) }
        return Matrix(rows: n, cols: b.cols, columnMajor: x)
    }

    func inverse() throws -> Matrix {
        try solve(.identity(rows))
    }

    /// Moore-Penrose pseudoinverse via SVD (matches numpy's `pinv`).
    func pseudoinverse(rcond: Double = 1e-15) throws -> Matrix {
        let (u, s, vt) = try svd()
        let cutoff = rcond * (s.max() ?? 0)
        let sInv = s.map { $0 > cutoff ? 1.0 / $0 : 0.0 }
        // pinv = V * diag(sInv) * U^T = (Vt^T scaled by sInv per row) * U^T
        let v = vt.transposed()                       // n x k
        var scaled = v                                // scale columns of V by sInv
        for c in 0..<scaled.cols {
            for r in 0..<scaled.rows { scaled[r, c] *= sInv[c] }
        }
        return scaled.multiply(u.transposed())        // (n x k)(k x m) = n x m
    }

    static func identity(_ n: Int) -> Matrix {
        var m = Matrix(rows: n, cols: n)
        for i in 0..<n { m[i, i] = 1 }
        return m
    }
}
