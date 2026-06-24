//
//  FFTDouble.swift
//  DENNIS
//
//  A minimal power-of-two complex FFT over Accelerate's vDSP, double precision,
//  for the time-frequency engine. Forward and inverse in-place on split-complex
//  buffers; the inverse is unscaled (callers divide by n).
//

import Accelerate

nonisolated final class FFTDouble {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    /// `n` must be a power of two.
    init(n: Int) {
        precondition(n > 1 && (n & (n - 1)) == 0, "FFT length must be a power of two")
        self.n = n
        self.log2n = vDSP_Length(Foundation.log2(Double(n)).rounded())
        self.setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// In-place complex FFT. `direction` is `FFT_FORWARD` or `FFT_INVERSE`.
    func transform(real: inout [Double], imag: inout [Double], direction: FFTDirection) {
        precondition(real.count == n && imag.count == n, "buffers must be length n")
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, direction)
            }
        }
    }

    /// Next power of two ≥ `value`.
    static func nextPow2(_ value: Int) -> Int {
        var n = 1
        while n < value { n <<= 1 }
        return n
    }
}
