//
//  MultiwayTests.swift
//  DENNISTests
//
//  Validates the multiway tensor unfolding and the per-mode (multilinear) scree.
//

import Testing
import Foundation
@testable import DENNIS

struct MultiwayTests {

    /// 2×2×2 tensor in Fortran order (mode 0 fastest): value == linear index.
    private func ramp222() -> MultiwayTensor {
        MultiwayTensor(dims: [2, 2, 2], data: (0..<8).map(Double.init))
    }

    @Test func unfoldMatchesKoldaConvention() {
        let t = ramp222()
        // X_(0)
        let m0 = t.unfold(mode: 0)
        #expect(m0.rows == 2 && m0.cols == 4)
        #expect(m0.toRowMajor() == [[0, 2, 4, 6], [1, 3, 5, 7]])
        // X_(1)
        let m1 = t.unfold(mode: 1)
        #expect(m1.toRowMajor() == [[0, 1, 4, 5], [2, 3, 6, 7]])
        // X_(2)
        let m2 = t.unfold(mode: 2)
        #expect(m2.toRowMajor() == [[0, 1, 2, 3], [4, 5, 6, 7]])
    }

    @Test func rankOneTensorHasOneComponentPerMode() throws {
        // X = a ⊗ b ⊗ c is rank 1, so every mode's unfolding is rank 1: the first
        // singular value should carry ~100% of the mode's energy.
        let a = [1.0, 2.0, -0.5]
        let b = [1.0, 3.0]
        let c = [2.0, 1.0, 0.5, -1.0]
        let dims = [a.count, b.count, c.count]
        var data = [Double](repeating: 0, count: dims.reduce(1, *))
        var linear = 0
        for k in 0..<c.count {
            for j in 0..<b.count {
                for i in 0..<a.count {
                    data[linear] = a[i] * b[j] * c[k]
                    linear += 1
                }
            }
        }
        let tensor = MultiwayTensor(dims: dims, data: data)
        let scree = try MultiwayDiagnostics.perModeScree(tensor, modeNames: ["A", "B", "C"])

        #expect(scree.count == 3)
        for mode in scree {
            #expect(mode.cumulativeVariance.first! > 0.9999)   // one component explains all
            #expect(mode.singularValues[0] > 0)
        }
    }

    @Test func erp4WayDropsTrailingSingletonDims() {
        let ep = EPTensor(dims: [2, 2, 2, 2, 1, 1, 1], data: (0..<16).map(Double.init))
        let tensor = MultiwayTensor.erp4Way(from: ep)
        #expect(tensor.dims == [2, 2, 2, 2])
        #expect(tensor.count == 16)
        #expect(tensor.data == (0..<16).map(Double.init))
    }

    @Test func foldInvertsUnfold() {
        let t = ramp222()
        for mode in 0..<3 {
            let round = MultiwayTensor.fold(t.unfold(mode: mode), mode: mode, dims: t.dims)
            #expect(round.data == t.data)
        }
    }

    @Test func selectingPicksSubTensor() {
        // 3×2 (×1 trivially) — select columns of mode 1.
        let t = MultiwayTensor(dims: [3, 2], data: [0, 1, 2, 3, 4, 5])  // col0=[0,1,2], col1=[3,4,5]
        let sub = t.selecting(mode: 1, indices: [1])
        #expect(sub.dims == [3, 1])
        #expect(sub.data == [3, 4, 5])
    }

    @Test func meanCollapsingAveragesAndDropsMode() {
        let t = MultiwayTensor(dims: [2, 2, 2, 2], data: (0..<16).map(Double.init))
        let collapsed = t.meanCollapsing(mode: 2)
        #expect(collapsed.dims == [2, 2, 2])
        #expect(collapsed.data == [2, 3, 4, 5, 10, 11, 12, 13])  // mean over mode 2
    }

    @Test func centeringAcrossModeZeroesFiberMeans() {
        let t = ramp222()
        let centered = t.centeredAcross(mode: 2)   // center across the last mode
        // Each fiber along mode 2 should now sum to ~0.
        let len = 2, stride = 4   // mode 2 stride = dims[0]*dims[1]
        for s in 0..<stride {
            var sum = 0.0
            for k in 0..<len { sum += centered.data[s + k * stride] }
            #expect(abs(sum) < 1e-12)
        }
    }
}
