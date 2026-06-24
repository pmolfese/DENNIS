//
//  MultiwayTensor.swift
//  DENNIS
//
//  A dense N-way tensor for the PARAFAC / multiway pipeline. Storage is
//  Fortran/column-major (mode 0 varies fastest), matching `EPTensor`, so the
//  averaged-ERP 4-way tensor (channels × time × condition × subject) is just the
//  first four EP dimensions. The order is generic so a 5th frequency mode (for
//  the time-frequency extension) drops in without changing this type.
//

import Accelerate

nonisolated struct MultiwayTensor: Sendable {
    /// Length-`order` dimensions.
    let dims: [Int]
    /// Fortran/column-major flat storage: mode 0 varies fastest.
    var data: [Double]

    init(dims: [Int], data: [Double]) {
        precondition(data.count == dims.reduce(1, *), "data size does not match dims")
        self.dims = dims
        self.data = data
    }

    var order: Int { dims.count }
    var count: Int { data.count }

    /// Build the signed 4-way ERP tensor from an assembled EP tensor by dropping
    /// the trailing singleton EP dimensions (factors, freqs, relations). The flat
    /// Fortran layout is identical, so no data is moved.
    static func erp4Way(from ep: EPTensor) -> MultiwayTensor {
        MultiwayTensor(dims: Array(ep.dims.prefix(4)), data: ep.data)
    }

    static let erp4WayModeNames = ["Channels", "Time", "Condition", "Subject"]

    // MARK: - Norm

    /// A Gaussian random tensor of the given dims with per-element standard
    /// deviation `std` — used for the per-mode parallel-analysis noise floor.
    static func randomNormal(dims: [Int], std: Double, rng: inout SplitMix64) -> MultiwayTensor {
        let n = dims.reduce(1, *)
        var data = [Double](repeating: 0, count: n)
        for i in 0..<n { data[i] = rng.nextGaussian() * std }
        return MultiwayTensor(dims: dims, data: data)
    }

    var frobeniusNormSquared: Double {
        var ss = 0.0
        data.withUnsafeBufferPointer { p in
            vDSP_svesqD(p.baseAddress!, 1, &ss, vDSP_Length(p.count))
        }
        return ss
    }

    // MARK: - Mode-n unfolding (matricization)

    /// Mode-`n` unfolding: a `dims[n] × (∏ other dims)` matrix whose columns index
    /// the remaining modes in ascending order. (Column order is a consistent
    /// bijection — singular values are invariant to it, which is all the
    /// diagnostics need.) Walks the Fortran odometer, tracking row and column
    /// incrementally to avoid per-element index decoding.
    func unfold(mode n: Int) -> Matrix {
        let rows = dims[n]
        let cols = count / max(rows, 1)
        var out = Matrix(rows: rows, cols: cols)

        // Per-axis contribution to the destination column; the unfolded mode
        // contributes to the row instead, so its column stride is 0.
        var colStride = [Int](repeating: 0, count: order)
        var acc = 1
        for m in 0..<order where m != n { colStride[m] = acc; acc *= dims[m] }

        let dimsLocal = dims
        out.grid.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                var idx = [Int](repeating: 0, count: order)
                var row = 0, col = 0
                for linear in 0..<src.count {
                    dst[col * rows + row] = src[linear]
                    var a = 0
                    while a < order {
                        idx[a] += 1
                        if a == n { row += 1 }
                        col += colStride[a]
                        if idx[a] < dimsLocal[a] { break }
                        if a == n { row -= dimsLocal[a] }
                        col -= colStride[a] * dimsLocal[a]
                        idx[a] = 0
                        a += 1
                    }
                }
            }
        }
        return out
    }

    /// Fold a mode-`n` matrix (`dims[n] × rest`) back into a tensor — the inverse
    /// of `unfold`, using the same ascending column convention.
    static func fold(_ m: Matrix, mode n: Int, dims: [Int]) -> MultiwayTensor {
        let total = dims.reduce(1, *)
        var data = [Double](repeating: 0, count: total)
        var colStride = [Int](repeating: 0, count: dims.count)
        var acc = 1
        for a in 0..<dims.count where a != n { colStride[a] = acc; acc *= dims[a] }

        m.grid.withUnsafeBufferPointer { src in
            var idx = [Int](repeating: 0, count: dims.count)
            let rows = dims[n]
            for linear in 0..<total {
                var col = 0
                for a in 0..<dims.count where a != n { col += idx[a] * colStride[a] }
                data[linear] = src[col * rows + idx[n]]
                var a = 0
                while a < dims.count { idx[a] += 1; if idx[a] < dims[a] { break }; idx[a] = 0; a += 1 }
            }
        }
        return MultiwayTensor(dims: dims, data: data)
    }

    /// Mode-`n` product with `matrix` (J × dims[n]): replaces mode n by J.
    func modeProduct(mode n: Int, _ matrix: Matrix) -> MultiwayTensor {
        let product = matrix.multiply(unfold(mode: n))      // J × rest
        var newDims = dims
        newDims[n] = matrix.rows
        return MultiwayTensor.fold(product, mode: n, dims: newDims)
    }

    /// Average over `mode` and drop it, reducing the order by one (e.g. pooling
    /// conditions to a channels × time × subject tensor).
    func meanCollapsing(mode n: Int) -> MultiwayTensor {
        let len = dims[n]
        var stride = 1
        for a in 0..<n { stride *= dims[a] }
        let outer = count / (len * stride)
        var newDims = dims
        newDims.remove(at: n)
        var out = [Double](repeating: 0, count: count / len)
        for o in 0..<outer {
            for s in 0..<stride {
                var sum = 0.0
                for k in 0..<len { sum += data[o * len * stride + s + k * stride] }
                out[o * stride + s] = sum / Double(len)
            }
        }
        return MultiwayTensor(dims: newDims, data: out)
    }

    /// Sub-tensor keeping only `indices` along `mode` (e.g. a subject half).
    func selecting(mode n: Int, indices: [Int]) -> MultiwayTensor {
        var newDims = dims
        newDims[n] = indices.count
        let strides = MultiwayTensor.fortranStrides(dims)
        var out = [Double](repeating: 0, count: newDims.reduce(1, *))
        var idx = [Int](repeating: 0, count: order)
        for linear in 0..<out.count {
            var srcLinear = 0
            for a in 0..<order {
                let srcIndex = (a == n) ? indices[idx[a]] : idx[a]
                srcLinear += srcIndex * strides[a]
            }
            out[linear] = data[srcLinear]
            var a = 0
            while a < order { idx[a] += 1; if idx[a] < newDims[a] { break }; idx[a] = 0; a += 1 }
        }
        return MultiwayTensor(dims: newDims, data: out)
    }

    private static func fortranStrides(_ dims: [Int]) -> [Int] {
        var s = [Int](repeating: 1, count: dims.count)
        for a in 1..<dims.count { s[a] = s[a - 1] * dims[a - 1] }
        return s
    }

    // MARK: - Preprocessing (opt-in)

    /// Center across a mode: subtract, for every fiber along `mode`, its mean over
    /// that mode. Centering across subjects removes the grand average so the
    /// decomposition models between-subject variation; centering across time
    /// removes a per-channel DC offset. Off by default for ERP.
    func centeredAcross(mode n: Int) -> MultiwayTensor {
        let len = dims[n]
        guard len > 1 else { return self }
        // Subtract each fiber's mean over the mode, working directly on the flat
        // data via the mode's stride.
        var out = self
        var stride = 1
        for a in 0..<n { stride *= dims[a] }
        let outer = count / (len * stride)
        out.data.withUnsafeMutableBufferPointer { p in
            for o in 0..<outer {
                for s in 0..<stride {
                    let base = o * len * stride + s
                    var mean = 0.0
                    for k in 0..<len { mean += p[base + k * stride] }
                    mean /= Double(len)
                    for k in 0..<len { p[base + k * stride] -= mean }
                }
            }
        }
        return out
    }

    /// Scale within a mode: divide each slice along `mode` by its RMS so no single
    /// channel (or condition) dominates by sheer amplitude. Off by default.
    func scaledWithin(mode n: Int) -> MultiwayTensor {
        let len = dims[n]
        let unfolded = unfold(mode: n)            // len × rest
        let gram = gramRows(unfolded)             // len × len; diagonal = slice SS
        var out = self
        var stride = 1
        for a in 0..<n { stride *= dims[a] }
        let outer = count / (len * stride)
        let restCount = Double(count / len)
        out.data.withUnsafeMutableBufferPointer { p in
            for k in 0..<len {
                let rms = (gram[k, k] / restCount).squareRoot()
                guard rms > 0 else { continue }
                for o in 0..<outer {
                    for s in 0..<stride {
                        p[o * len * stride + s + k * stride] /= rms
                    }
                }
            }
        }
        return out
    }
}
