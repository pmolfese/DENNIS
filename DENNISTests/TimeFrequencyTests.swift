//
//  TimeFrequencyTests.swift
//  DENNISTests
//
//  Validates the time-frequency engine: a pure sinusoid should concentrate its
//  power at its own frequency, for both Morlet and STFT.
//

import Testing
import Foundation
@testable import DENNIS

struct TimeFrequencyTests {

    private func sine(freq: Double, sfreq: Double, count: Int) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * freq * Double($0) / sfreq)) }
    }

    /// Frequency (nearest analysis bin) with the most power, averaged over the
    /// central half of the epoch to avoid edge effects.
    private func peakFrequency(_ tf: TFRepresentation) -> Double {
        let t0 = tf.sampleTimes.count / 4, t1 = max(t0 + 1, 3 * tf.sampleTimes.count / 4)
        var best = 0.0, bestFreq = 0.0
        for fi in tf.freqs.indices {
            let mean = (t0..<t1).reduce(0.0) { $0 + tf.power[fi][$1] } / Double(t1 - t0)
            if mean > best { best = mean; bestFreq = tf.freqs[fi] }
        }
        return bestFreq
    }

    @Test func morletPeaksAtSignalFrequency() {
        let signal = sine(freq: 10, sfreq: 250, count: 500)
        let tf = TimeFrequency.transform(
            signal: signal, sfreq: 250,
            config: TFConfig(method: .morlet, freqMin: 2, freqMax: 40, nFreqs: 39, spacing: .linear))
        #expect(abs(peakFrequency(tf) - 10) <= 1.5)
    }

    @Test func stftPeaksAtSignalFrequency() {
        let signal = sine(freq: 12, sfreq: 250, count: 500)
        let tf = TimeFrequency.transform(
            signal: signal, sfreq: 250,
            config: TFConfig(method: .stft, freqMin: 2, freqMax: 40, windowMS: 200, stepMS: 25))
        #expect(abs(peakFrequency(tf) - 12) <= 2.5)
    }

    @Test func tensorBuilderCollapseTimePeaksAtSignalBand() {
        // Two subjects × two conditions × two channels, each a 10 Hz sine.
        let sfreq = 128.0, n = 128
        let s = sine(freq: 10, sfreq: sfreq, count: n)
        let channels = [s, s]
        let cells = [channels, channels]
        let input = EPTensor.Input(
            nChannels: 2, nTimes: n, conditionCount: 2,
            subjects: [cells, cells], samplingRate: sfreq, baselineSamples: 0)

        var params = TFTensorBuilder.Parameters()
        params.config = TFConfig(method: .morlet, freqMin: 2, freqMax: 40, nFreqs: 39, spacing: .linear)
        params.structure = .collapseTime
        params.transform = .raw
        params.windowStartMS = 0
        params.windowEndMS = 1000

        let tf = TFTensorBuilder.build(from: input, parameters: params)
        #expect(tf.tensor.dims == [2, 39, 2, 2])              // channels × freq × cond × subj
        #expect(tf.nonnegative)

        // Frequency-mode marginal should peak near 10 Hz.
        let freqUnfold = tf.tensor.unfold(mode: 1)            // freq × rest
        var bestFreq = 0.0, best = -Double.infinity
        for f in 0..<freqUnfold.rows {
            let total = (0..<freqUnfold.cols).reduce(0.0) { $0 + freqUnfold[f, $1] }
            if total > best { best = total; bestFreq = tf.freqs[f] }
        }
        #expect(abs(bestFreq - 10) <= 1.5)
    }

    @Test func logSpacingIsMonotonicWithinRange() {
        let freqs = TFConfig(freqMin: 2, freqMax: 40, nFreqs: 30, spacing: .log).frequencies()
        #expect(freqs.count == 30)
        #expect(abs(freqs.first! - 2) < 1e-9)
        #expect(abs(freqs.last! - 40) < 1e-9)
        #expect(zip(freqs, freqs.dropFirst()).allSatisfy { $0 < $1 })
    }
}
