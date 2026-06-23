//
//  ScreeTests.swift
//  DENNISTests
//
//  Validates the EP tensor reshape and the data-dependent (deterministic) parts
//  of the scree analysis against the Python mne_erppca reference
//  (`/tmp/screedump.py` / `/tmp/screeref.py`) on a fixed 4×6×2×3 EP tensor.
//  Random-draw quantities (scaled-random curve, parallel count) depend on each
//  implementation's RNG and are not compared.
//

import Testing
import Foundation
@testable import DENNIS

struct ScreeTests {

    // Flat Fortran-order values of the reference tensor (channels=4, times=6,
    // cells=2, subjects=3), generated with numpy default_rng(123).
    static let dims = [4, 6, 2, 3, 1, 1, 1]
    static let flat: [Double] = [
        -0.98912135, 0.85988118, 0.95296449, 0.85538665, -0.63646365, 1.42993853, 0.12834321,
        -0.64639674, 1.1921661, 2.28990995, -0.64796521, -0.35631338, -0.31179486, -0.48156286,
        1.2345776, 0.07612151, 0.75476964, -0.54308414, -0.30359134, -0.70570064, -0.36176687,
        0.43899989, -0.2972626, 0.99699865, 0.19397442, -0.29152143, -0.24885871, -1.68578468,
        -0.32238912, -0.6390601, 0.81327372, -0.63668844, 0.13632112, 0.0280499, -0.27287177,
        0.25405868, 0.82792144, -1.48817461, -0.14875753, -0.30520792, 1.07403062, -0.46063974,
        0.85032229, 0.07383952, -2.17204389, -0.43845727, 0.36002051, 0.34747265, -0.36778665,
        1.76166124, 1.51952413, 1.73127944, 0.54195222, -0.15647532, -0.73422189, 1.11510426,
        -0.67108968, -0.71818115, -0.28337121, -0.25581218, 0.33776913, -0.5834075, 0.15088803,
        0.25463292, -0.14597789, -0.55861504, -1.17368868, 1.71988948, -1.2302322, -0.71169503,
        -1.38337712, -0.20363536, 0.9202309, 0.72812756, -0.49974859, -0.37775861, 0.09716732,
        -0.06136133, 1.64180101, 0.32613417, 1.53203308, 0.02827212, 0.42244414, -0.28528677,
        1.54163039, 0.21630683, 1.31566571, -0.53976286, 0.39262084, -1.43626975, -0.51576759,
        0.73362828, -0.37014735, -0.21163743, -0.23439201, 0.13471907, 1.28792526, 0.99332378,
        1.70390945, 1.38588544, -0.31659545, -0.67375915, -0.62047529, -0.8432111, 1.00026942,
        0.03260774, -0.99513136, 0.8089817, -2.2074711, -0.8621605, 0.48111953, 2.00123118,
        1.28190223, -0.31648283, 0.82627351, -0.19419781, 1.22622929, 0.29717176, -0.2812045,
        -0.36642884, 0.57710379, -1.26160032, 0.0995975, -2.72848569, -1.52593041, -0.39278492,
        -0.22650085, 0.7873165, -0.65996941, 0.05534586, -0.08134296, 0.31450349, 1.12680679,
        0.98437635, -1.2223456, 1.41363079, 0.00511431, 1.36510803, 1.65811332, 1.2131097,
        0.16438007, 0.36396383, 2.2655206, -0.64227311,
    ]

    static var tensor: EPTensor { EPTensor(dims: dims, data: flat) }

    @Test func reshapeMatchesReferenceShapeAndColumn() {
        let m = Self.tensor.reshape(forMode: .temporal)
        #expect(m.rows == 24)
        #expect(m.cols == 6)
        let expectedFirstCol = [-0.98912135, 0.85988118, 0.95296449, 0.85538665, 0.19397442]
        for i in 0..<5 { #expect(abs(m[i, 0] - expectedFirstCol[i]) < 1e-6) }
    }

    @Test func temporalScreeMatchesReference() throws {
        let analysis = try Scree.analyze(Self.tensor, mode: .temporal, nRandom: 1, seed: 0)

        let expectedScree = [1.56024385, 1.43391331, 0.72032567, 0.67142428, 0.47883255, 0.39019318]
        #expect(analysis.dataScree.count == 6)
        for i in 0..<6 { #expect(abs(analysis.dataScree[i] - expectedScree[i]) < 1e-6) }

        let expectedCum = [0.29691033, 0.56978029, 0.70685638, 0.83462667, 0.92574726, 1.0]
        for i in 0..<6 { #expect(abs(analysis.cumulativeVariance[i] - expectedCum[i]) < 1e-6) }

        // Deterministic, data-only retention count.
        #expect(analysis.retainedMinVariance == 5)
    }

    @Test func countHelpersMatchToolkit() {
        // Above-threshold run with a gap: factors 0,1 then gap then 4.
        let data = [3.0, 2.0, 0.5, 0.5, 2.0]
        let thresh = [1.0, 1.0, 1.0, 1.0, 1.0]
        #expect(Scree.countAboveThreshold(data, thresh) == 2)

        let cumulative = [0.3, 0.6, 0.8, 0.96, 1.0]
        #expect(Scree.countMinVariance(cumulative, minVariance: 0.95) == 3)
    }
}
