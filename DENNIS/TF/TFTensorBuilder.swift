//
//  TFTensorBuilder.swift
//  DENNIS
//
//  Turns averaged-ERP signals into a time-frequency PARAFAC tensor. The full
//  5-way (channels × time × frequency × condition × subject) is offered, plus two
//  reduced 4-way forms — collapsing time (spectral signature in a window) or
//  collapsing frequency (band power over time). Power can be left raw (for
//  nonnegative PARAFAC) or converted to dB relative to a pre-stimulus baseline.
//

import Foundation

nonisolated enum TFStructure: String, CaseIterable, Sendable {
    case fiveWay = "5-way (time × freq)"
    case collapseTime = "4-way (collapse time)"
    case collapseFrequency = "4-way (collapse freq)"
}

nonisolated enum TFTransform: String, CaseIterable, Sendable {
    case raw = "Raw power (nonneg)"
    case logBaseline = "dB vs baseline"
}

nonisolated enum TFModeType: Sendable { case channel, time, frequency, condition, subject }

nonisolated struct TFTensor: Sendable {
    let tensor: MultiwayTensor
    let modeNames: [String]
    let modeTypes: [TFModeType]
    let freqs: [Double]
    let timesMS: [Double]
    let nonnegative: Bool
}

nonisolated enum TFTensorBuilder {

    struct Parameters: Sendable {
        var config = TFConfig()
        var structure: TFStructure = .collapseTime
        var transform: TFTransform = .logBaseline
        /// Stride applied to the TF time axis (memory control for time-keeping
        /// structures).
        var timeStride = 4
        /// Window (ms) to average over when collapsing time.
        var windowStartMS: Double = 0
        var windowEndMS: Double = 800
        /// Band (Hz) to average over when collapsing frequency.
        var bandLow: Double = 4
        var bandHigh: Double = 8
    }

    /// Assemble the TF tensor. Safe to call off the main actor (heavy).
    static func build(from input: EPTensor.Input, parameters p: Parameters) -> TFTensor {
        let sfreq = input.samplingRate
        let baseline = input.baselineSamples
        let nCh = input.nChannels
        let nCond = input.conditionCount
        let nSubj = input.subjects.count

        // A reference TF gives the shared frequency and time axes.
        let reference = referenceSignal(input)
        let refTF = TimeFrequency.transform(signal: reference, sfreq: sfreq, config: p.config)
        let freqs = refTF.freqs
        let sampleTimes = refTF.sampleTimes

        // Kept time samples (strided) and their ms.
        let keptT = stride(from: 0, to: sampleTimes.count, by: max(1, p.timeStride)).map { $0 }
        let timesMS = keptT.map { (sampleTimes[$0] - Double(baseline)) / sfreq * 1000 }
        let baselineMask = sampleTimes.map { $0 < Double(baseline) }

        // Indices for the collapse modes.
        let windowT = (0..<sampleTimes.count).filter {
            let ms = (sampleTimes[$0] - Double(baseline)) / sfreq * 1000
            return ms >= min(p.windowStartMS, p.windowEndMS) && ms <= max(p.windowStartMS, p.windowEndMS)
        }
        let bandF = freqs.indices.filter { freqs[$0] >= min(p.bandLow, p.bandHigh) && freqs[$0] <= max(p.bandLow, p.bandHigh) }

        let (dims, modeNames, modeTypes): ([Int], [String], [TFModeType]) = {
            switch p.structure {
            case .fiveWay:
                return ([nCh, keptT.count, freqs.count, nCond, nSubj],
                        ["Channels", "Time", "Frequency", "Condition", "Subject"],
                        [.channel, .time, .frequency, .condition, .subject])
            case .collapseTime:
                return ([nCh, freqs.count, nCond, nSubj],
                        ["Channels", "Frequency", "Condition", "Subject"],
                        [.channel, .frequency, .condition, .subject])
            case .collapseFrequency:
                return ([nCh, keptT.count, nCond, nSubj],
                        ["Channels", "Time", "Condition", "Subject"],
                        [.channel, .time, .condition, .subject])
            }
        }()

        let strides = fortranStrides(dims)
        var data = [Double](repeating: 0, count: dims.reduce(1, *))

        for (subj, cells) in input.subjects.enumerated() {
            for cell in 0..<min(nCond, cells.count) {
                let channels = cells[cell]
                for ch in 0..<min(nCh, channels.count) {
                    let raw = TimeFrequency.transform(signal: channels[ch], sfreq: sfreq, config: p.config).power
                    let power = transformed(raw, transform: p.transform, baselineMask: baselineMask)
                    place(power: power, into: &data, strides: strides, structure: p.structure,
                          ch: ch, cell: cell, subj: subj, keptT: keptT, freqCount: freqs.count,
                          windowT: windowT, bandF: bandF)
                }
            }
        }

        return TFTensor(tensor: MultiwayTensor(dims: dims, data: data),
                        modeNames: modeNames, modeTypes: modeTypes,
                        freqs: freqs, timesMS: timesMS, nonnegative: p.transform == .raw)
    }

    // MARK: - Helpers

    private static func referenceSignal(_ input: EPTensor.Input) -> [Float] {
        for cells in input.subjects {
            for cell in cells where !cell.isEmpty {
                if let channel = cell.first { return channel }
            }
        }
        return [Float](repeating: 0, count: input.nTimes)
    }

    /// Apply the power transform per frequency: raw, or dB relative to the
    /// baseline mean of that frequency.
    private static func transformed(_ power: [[Double]], transform: TFTransform,
                                    baselineMask: [Bool]) -> [[Double]] {
        switch transform {
        case .raw:
            return power
        case .logBaseline:
            return power.map { row in
                var baseSum = 0.0, baseN = 0
                for t in row.indices where t < baselineMask.count && baselineMask[t] { baseSum += row[t]; baseN += 1 }
                let base = baseN > 0 ? baseSum / Double(baseN) : 0
                guard base > 0 else { return row.map { _ in 0 } }
                return row.map { 10 * Foundation.log10(max($0, 1e-20) / base) }
            }
        }
    }

    private static func place(power: [[Double]], into data: inout [Double], strides: [Int],
                              structure: TFStructure, ch: Int, cell: Int, subj: Int,
                              keptT: [Int], freqCount: Int, windowT: [Int], bandF: [Int]) {
        switch structure {
        case .fiveWay:
            // dims [ch, time, freq, cond, subj]
            for (ti, t) in keptT.enumerated() {
                for fi in 0..<freqCount where t < power[fi].count {
                    let index = ch * strides[0] + ti * strides[1] + fi * strides[2]
                        + cell * strides[3] + subj * strides[4]
                    data[index] = power[fi][t]
                }
            }
        case .collapseTime:
            // dims [ch, freq, cond, subj] — mean over the window.
            for fi in 0..<freqCount {
                var sum = 0.0, n = 0
                for t in windowT where t < power[fi].count { sum += power[fi][t]; n += 1 }
                let index = ch * strides[0] + fi * strides[1] + cell * strides[2] + subj * strides[3]
                data[index] = n > 0 ? sum / Double(n) : 0
            }
        case .collapseFrequency:
            // dims [ch, time, cond, subj] — mean over the band.
            for (ti, t) in keptT.enumerated() {
                var sum = 0.0, n = 0
                for fi in bandF where t < power[fi].count { sum += power[fi][t]; n += 1 }
                let index = ch * strides[0] + ti * strides[1] + cell * strides[2] + subj * strides[3]
                data[index] = n > 0 ? sum / Double(n) : 0
            }
        }
    }

    private static func fortranStrides(_ dims: [Int]) -> [Int] {
        var s = [Int](repeating: 1, count: dims.count)
        for a in 1..<dims.count { s[a] = s[a - 1] * dims[a - 1] }
        return s
    }
}
