//
//  TimeFrequency.swift
//  DENNIS
//
//  Internal time-frequency transforms for EEG/ERP signals, since precomputed TF
//  rarely round-trips cleanly through MFF. Two methods:
//
//  • Morlet wavelets — a complex Morlet at each frequency, applied as a Gaussian
//    band-pass in the frequency domain (analytic, so power = |analytic signal|²).
//    Keeps the full time resolution. Parameters: frequency range/count/spacing and
//    the cycle count (lower → better time resolution, higher → better frequency).
//  • Windowed FFT (STFT) — a Hann-windowed sliding FFT. Parameters: window length,
//    step, and frequency range. Produces its own (coarser) time grid.
//
//  Computed on the averaged ERP, this is evoked (phase-locked) power.
//

import Accelerate

nonisolated struct TFConfig: Sendable {
    enum Method: String, CaseIterable, Sendable { case morlet = "Morlet wavelet", stft = "Windowed FFT" }
    enum Spacing: String, CaseIterable, Sendable { case linear = "Linear", log = "Log" }

    var method: Method = .morlet
    var freqMin: Double = 2
    var freqMax: Double = 40
    var nFreqs: Int = 30
    var spacing: Spacing = .log

    // Morlet: cycles ramp linearly with frequency across the band.
    var cyclesMin: Double = 3
    var cyclesMax: Double = 10

    // STFT.
    var windowMS: Double = 200
    var stepMS: Double = 25

    /// Target analysis frequencies (Morlet); STFT uses its own FFT bins.
    func frequencies() -> [Double] {
        guard nFreqs > 1 else { return [freqMin] }
        switch spacing {
        case .linear:
            return (0..<nFreqs).map { freqMin + (freqMax - freqMin) * Double($0) / Double(nFreqs - 1) }
        case .log:
            let a = Foundation.log(freqMin), b = Foundation.log(freqMax)
            return (0..<nFreqs).map { exp(a + (b - a) * Double($0) / Double(nFreqs - 1)) }
        }
    }

    func cycles() -> [Double] {
        guard nFreqs > 1 else { return [cyclesMin] }
        return (0..<nFreqs).map { cyclesMin + (cyclesMax - cyclesMin) * Double($0) / Double(nFreqs - 1) }
    }
}

/// Power spectrum over frequency × time for one channel.
nonisolated struct TFRepresentation: Sendable {
    let freqs: [Double]       // Hz
    /// Time positions as original sample indices (Morlet keeps every sample;
    /// STFT returns window centers).
    let sampleTimes: [Double]
    /// `power[freq][time]`.
    let power: [[Double]]
}

nonisolated enum TimeFrequency {

    static func transform(signal: [Float], sfreq: Double, config: TFConfig) -> TFRepresentation {
        switch config.method {
        case .morlet:
            let freqs = config.frequencies()
            let power = morlet(signal: signal, sfreq: sfreq, freqs: freqs, cycles: config.cycles())
            return TFRepresentation(freqs: freqs, sampleTimes: (0..<signal.count).map(Double.init), power: power)
        case .stft:
            return stft(signal: signal, sfreq: sfreq, config: config)
        }
    }

    // MARK: - Morlet (frequency-domain Gaussian band-pass)

    static func morlet(signal: [Float], sfreq: Double, freqs: [Double], cycles: [Double]) -> [[Double]] {
        let len = signal.count
        guard len > 1 else { return freqs.map { _ in [] } }
        let nfft = FFTDouble.nextPow2(len * 2)
        let fft = FFTDouble(n: nfft)
        let half = nfft / 2

        var sigR = [Double](repeating: 0, count: nfft)
        var sigI = [Double](repeating: 0, count: nfft)
        for i in 0..<len { sigR[i] = Double(signal[i]) }
        fft.transform(real: &sigR, imag: &sigI, direction: FFTDirection(kFFTDirection_Forward))

        let binFreq = (0..<nfft).map { Double($0) * sfreq / Double(nfft) }
        var power = [[Double]](repeating: [Double](repeating: 0, count: len), count: freqs.count)
        var prodR = [Double](repeating: 0, count: nfft)
        var prodI = [Double](repeating: 0, count: nfft)
        let invN = 1.0 / Double(nfft)

        for (fi, f) in freqs.enumerated() where cycles[fi] > 0 && f > 0 {
            let sigmaF = f / cycles[fi]
            // Unit-L2 Gaussian over the positive frequencies (analytic).
            var gauss = [Double](repeating: 0, count: half + 1)
            var norm = 0.0
            for k in 0...half {
                let d = binFreq[k] - f
                let value = exp(-0.5 * d * d / (sigmaF * sigmaF))
                gauss[k] = value
                norm += value * value
            }
            let scale = norm > 0 ? 1.0 / norm.squareRoot() : 0
            for k in 0..<nfft {
                let g = k <= half ? gauss[k] * scale : 0
                prodR[k] = sigR[k] * g
                prodI[k] = sigI[k] * g
            }
            fft.transform(real: &prodR, imag: &prodI, direction: FFTDirection(kFFTDirection_Inverse))
            for t in 0..<len {
                let re = prodR[t] * invN, im = prodI[t] * invN
                power[fi][t] = re * re + im * im
            }
        }
        return power
    }

    // MARK: - Windowed FFT (STFT)

    static func stft(signal: [Float], sfreq: Double, config: TFConfig) -> TFRepresentation {
        let len = signal.count
        let window = max(8, Int((config.windowMS / 1000 * sfreq).rounded()))
        let step = max(1, Int((config.stepMS / 1000 * sfreq).rounded()))
        let nfft = FFTDouble.nextPow2(window)
        let fft = FFTDouble(n: nfft)

        var hann = [Double](repeating: 0, count: window)
        vDSP_hann_windowD(&hann, vDSP_Length(window), Int32(vDSP_HANN_DENORM))

        var bins: [Int] = []
        var freqs: [Double] = []
        for k in 0...(nfft / 2) {
            let fk = Double(k) * sfreq / Double(nfft)
            if fk >= config.freqMin && fk <= config.freqMax { bins.append(k); freqs.append(fk) }
        }

        var columns: [[Double]] = []
        var times: [Double] = []
        var start = 0
        while start < len {
            var re = [Double](repeating: 0, count: nfft)
            var im = [Double](repeating: 0, count: nfft)
            for i in 0..<window {
                let idx = start + i
                re[i] = idx < len ? Double(signal[idx]) * hann[i] : 0
            }
            fft.transform(real: &re, imag: &im, direction: FFTDirection(kFFTDirection_Forward))
            columns.append(bins.map { re[$0] * re[$0] + im[$0] * im[$0] })
            times.append(Double(start + window / 2))
            start += step
        }

        var power = [[Double]](repeating: [Double](repeating: 0, count: columns.count), count: freqs.count)
        for w in columns.indices {
            for fi in freqs.indices { power[fi][w] = columns[w][fi] }
        }
        return TFRepresentation(freqs: freqs, sampleTimes: times, power: power)
    }
}
