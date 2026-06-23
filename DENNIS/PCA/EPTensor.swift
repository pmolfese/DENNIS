//
//  EPTensor.swift
//  DENNIS
//
//  The seven-dimensional EP data tensor that feeds the PCA engine, mirroring the
//  ERP PCA Toolkit / mne_erppca layout. The standard axis order is
//  (channels, times, cells, subjects, _, freqs, relations); the fifth axis is an
//  unused placeholder kept at length 1 so the dimension count matches the
//  reference. Storage is Fortran/column-major (axis 0 varies fastest), matching
//  numpy's `order="F"` reshapes so the `reshape(forMode:)` bridge reproduces
//  `_reshape_for_mode` exactly.
//

import Foundation

nonisolated struct EPTensor {
    /// Length-7 dimensions: [channels, times, cells, subjects, _, freqs, relations].
    let dims: [Int]
    /// Fortran/column-major flat storage: axis 0 (channels) varies fastest.
    var data: [Double]

    static let rank = 7

    init(dims: [Int], data: [Double]) {
        precondition(dims.count == EPTensor.rank, "EP tensor needs \(EPTensor.rank) dimensions")
        precondition(data.count == dims.reduce(1, *), "data size does not match dims")
        self.dims = dims
        self.data = data
    }

    /// Zero-filled tensor of the given EP dimensions.
    init(dims: [Int]) {
        self.init(dims: dims, data: [Double](repeating: 0, count: dims.reduce(1, *)))
    }

    var nChannels: Int { dims[0] }
    var nTimes: Int { dims[1] }
    var nCells: Int { dims[2] }
    var nSubjects: Int { dims[3] }
    var nFreqs: Int { dims[5] }
    var nRelations: Int { dims[6] }
    var count: Int { data.count }

    /// Fortran strides for a dimension list (stride[0] == 1).
    static func fortranStrides(_ dims: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: dims.count)
        for a in 1..<dims.count { strides[a] = strides[a - 1] * dims[a - 1] }
        return strides
    }

    private var strides: [Int] { EPTensor.fortranStrides(dims) }

    /// Element access by full multi-index.
    subscript(_ idx: [Int]) -> Double {
        get {
            let s = strides
            return data[zip(idx, s).reduce(0) { $0 + $1.0 * $1.1 }]
        }
        set {
            let s = strides
            data[zip(idx, s).reduce(0) { $0 + $1.0 * $1.1 }] = newValue
        }
    }

    // MARK: - Reshape for a PCA mode

    /// Axis permutation putting the variable axis first, matching the Toolkit's
    /// `_reshape_for_mode`. `axes[i]` is the original axis at new position `i`.
    private static func axes(for mode: PCAMode) -> [Int] {
        switch mode {
        case .temporal: return [1, 0, 2, 3, 4, 5, 6]
        case .spatial:  return [0, 1, 2, 3, 4, 5, 6]
        case .frequency: return [5, 0, 1, 2, 3, 4, 6]
        case .asIs:     return [0, 1, 2, 3, 4, 5, 6]
        }
    }

    /// Number of variables (the mode's dimension).
    func variableCount(for mode: PCAMode) -> Int {
        dims[EPTensor.axes(for: mode)[0]]
    }

    /// The tensor axis a mode treats as variables (channels=0, times=1, freqs=5).
    static func variableAxis(for mode: PCAMode) -> Int { axes(for: mode)[0] }

    /// Flatten to an `observations × variables` matrix for the given mode,
    /// reproducing `np.transpose(data, axes).reshape((n_vars, -1), order="F").T`.
    ///
    /// Implemented as an allocation-free odometer: the source buffer is walked in
    /// Fortran order while the destination column (variable index `v`) and row
    /// (observation index `o`) are maintained incrementally. This avoids the
    /// per-element index decoding that dominates on full-size EP tensors.
    func reshape(forMode mode: PCAMode) -> Matrix {
        let ax = EPTensor.axes(for: mode)
        let varAxis = ax[0]
        let td = ax.map { dims[$0] }                 // transposed dims
        let nVars = td[0]
        let nObs = count / max(nVars, 1)
        let tStrides = EPTensor.fortranStrides(td)

        // Per source-axis contribution to the observation index `o`. The variable
        // axis contributes to the column (`v`) instead, so its `o` stride is 0.
        var oStride = [Int](repeating: 0, count: EPTensor.rank)
        for i in 1..<EPTensor.rank { oStride[ax[i]] = tStrides[i] / nVars }

        let dimsLocal = dims
        var out = Matrix(rows: nObs, cols: nVars)
        out.grid.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                var idx = [Int](repeating: 0, count: EPTensor.rank)
                var o = 0, v = 0
                for linear in 0..<src.count {
                    dst[v * nObs + o] = src[linear]
                    // Increment the Fortran odometer (axis 0 fastest), updating
                    // o and v by the affected axis's stride.
                    var a = 0
                    while a < EPTensor.rank {
                        idx[a] += 1
                        o += oStride[a]
                        if a == varAxis { v += 1 }
                        if idx[a] < dimsLocal[a] { break }
                        o -= oStride[a] * dimsLocal[a]
                        if a == varAxis { v -= dimsLocal[a] }
                        idx[a] = 0
                        a += 1
                    }
                }
            }
        }
        return out
    }

    // MARK: - Builders

    /// Build an EP tensor from a group of datasets and an ordered list of shared
    /// condition (cell) names. Convenience wrapper that gathers a snapshot and
    /// assembles in one call (used by tests and synchronous callers).
    ///
    /// Returns nil if no dimension-consistent loaded data is available.
    @MainActor
    static func build(datasets: [Dataset], conditionNames: [String]) -> (tensor: EPTensor, subjects: [Dataset])? {
        guard let snapshot = snapshot(datasets: datasets, conditionNames: conditionNames) else { return nil }
        return (build(from: snapshot.input), snapshot.subjects)
    }

    /// A Sendable description of a group's signal data, gathered on the main
    /// actor (cheap copy-on-write array references) so the numeric tensor fill
    /// can run off the main thread.
    struct Input: Sendable {
        let nChannels: Int
        let nTimes: Int
        let conditionCount: Int
        /// `[subject][cell]` → channels × times Float traces.
        let subjects: [[[[Float]]]]
        let samplingRate: Double
        let baselineSamples: Int
    }

    /// Gather a Sendable snapshot plus the contributing `Dataset`s. Call on the
    /// main actor; the returned `Input` can cross to a background task.
    @MainActor
    static func snapshot(datasets: [Dataset], conditionNames: [String]) -> (input: Input, subjects: [Dataset])? {
        guard !conditionNames.isEmpty else { return nil }

        // Reference dimensions from the first dataset with loaded data for the
        // first condition.
        var nChannels = 0
        var nTimes = 0
        for dataset in datasets {
            if let condition = dataset.conditions.first(where: { $0.name == conditionNames[0] }),
               let samples = condition.samples, !samples.isEmpty {
                nChannels = samples.count
                nTimes = samples.first?.count ?? 0
                break
            }
        }
        guard nChannels > 0, nTimes > 0 else { return nil }

        // Keep subjects that have every shared condition loaded at the reference
        // dimensions.
        let subjects = datasets.filter { dataset in
            conditionNames.allSatisfy { name in
                guard let condition = dataset.conditions.first(where: { $0.name == name }),
                      let samples = condition.samples else { return false }
                return samples.count == nChannels && (samples.first?.count ?? 0) == nTimes
            }
        }
        guard !subjects.isEmpty else { return nil }

        let traces: [[[[Float]]]] = subjects.map { dataset in
            conditionNames.map { name in
                dataset.conditions.first(where: { $0.name == name })?.samples ?? []
            }
        }
        let baseline = subjects.first?.conditions
            .first(where: { $0.name == conditionNames[0] })?.baselineSamples ?? 0
        let input = Input(
            nChannels: nChannels, nTimes: nTimes, conditionCount: conditionNames.count,
            subjects: traces,
            samplingRate: subjects.first?.samplingRate ?? 0,
            baselineSamples: baseline
        )
        return (input, subjects)
    }

    /// A selection of time samples (after trimming/downsampling) with the time
    /// in milliseconds for each retained sample.
    struct TimeAxis: Sendable {
        /// Original sample indices retained, in order.
        let indices: [Int]
        /// Time (ms) relative to stimulus onset for each retained sample.
        let timesMS: [Double]
    }

    /// Select the time samples that fall within `[preMS, postMS]` (inclusive of
    /// stimulus onset at t = 0), keeping every `downsample`-th sample. Returns the
    /// natural full window when the bounds cover everything and `downsample == 1`.
    static func selectTimeSamples(
        samplingRate: Double, baselineSamples: Int, nTimes: Int,
        preMS: Double, postMS: Double, downsample: Int
    ) -> TimeAxis {
        func timeMS(_ i: Int) -> Double {
            samplingRate > 0 ? Double(i - baselineSamples) / samplingRate * 1000 : Double(i)
        }
        let factor = max(1, downsample)
        let lo = min(preMS, postMS) - 1e-6
        let hi = max(preMS, postMS) + 1e-6
        let inWindow = (0..<nTimes).filter { timeMS($0) >= lo && timeMS($0) <= hi }
        let strided = Swift.stride(from: 0, to: inWindow.count, by: factor).map { inWindow[$0] }
        return TimeAxis(indices: strided, timesMS: strided.map(timeMS))
    }

    /// Assemble the numeric tensor from a snapshot. Safe to call off the main
    /// actor — this is the expensive element-by-element fill. When `timeIndices`
    /// is supplied, only those time samples are kept (trimming / downsampling).
    static func build(from input: Input, timeIndices: [Int]? = nil) -> EPTensor {
        let nChannels = input.nChannels
        let times = timeIndices ?? Array(0..<input.nTimes)
        let nTimes = times.count
        let nCells = input.conditionCount
        let nSubjects = input.subjects.count
        let dims = [nChannels, nTimes, nCells, nSubjects, 1, 1, 1]
        var tensor = EPTensor(dims: dims)
        let strides = EPTensor.fortranStrides(dims)

        tensor.data.withUnsafeMutableBufferPointer { dst in
            for (s, cells) in input.subjects.enumerated() {
                for cell in 0..<min(nCells, cells.count) {
                    let samples = cells[cell]
                    guard samples.count == nChannels else { continue }
                    for ch in 0..<nChannels {
                        let trace = samples[ch]
                        let base = ch * strides[0] + cell * strides[2] + s * strides[3]
                        for (t, orig) in times.enumerated() where orig < trace.count {
                            dst[base + t * strides[1]] = Double(trace[orig])
                        }
                    }
                }
            }
        }
        return tensor
    }

    /// Standard-normal tensor of the given dims, drawn from a seedable RNG so
    /// scree/parallel analysis is reproducible.
    static func randomNormal(dims: [Int], rng: inout SplitMix64) -> EPTensor {
        let n = dims.reduce(1, *)
        var data = [Double](repeating: 0, count: n)
        for i in 0..<n { data[i] = rng.nextGaussian() }
        return EPTensor(dims: dims, data: data)
    }
}
