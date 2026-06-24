//
//  PARAFACTests.swift
//  DENNISTests
//
//  Validates the CP-ALS engine: a tensor built from known rank-R factors should
//  be reconstructed almost perfectly, and a 4-way decomposition should run.
//

import Testing
import Foundation
@testable import DENNIS

struct PARAFACTests {

    /// Build X[i,j,k,…] = Σ_r ∏ factors[mode][index][r] in Fortran order.
    private func buildTensor(dims: [Int], factors: [[[Double]]], rank: Int) -> MultiwayTensor {
        var data = [Double](repeating: 0, count: dims.reduce(1, *))
        let strides: [Int] = {
            var s = [Int](repeating: 1, count: dims.count)
            for a in 1..<dims.count { s[a] = s[a - 1] * dims[a - 1] }
            return s
        }()
        func recurse(_ mode: Int, _ index: [Int]) {
            if mode == dims.count {
                let linear = zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 }
                var value = 0.0
                for r in 0..<rank {
                    var term = 1.0
                    for m in 0..<dims.count { term *= factors[m][index[m]][r] }
                    value += term
                }
                data[linear] = value
                return
            }
            for i in 0..<dims[mode] { recurse(mode + 1, index + [i]) }
        }
        recurse(0, [])
        return MultiwayTensor(dims: dims, data: data)
    }

    private func randomFactor(rows: Int, rank: Int, rng: inout SplitMix64) -> [[Double]] {
        (0..<rows).map { _ in (0..<rank).map { _ in rng.nextGaussian() } }
    }

    @Test func recoversRankTwoThreeWayTensor() async throws {
        var rng = SplitMix64(seed: 42)
        let dims = [5, 4, 6]
        let rank = 2
        let factors = dims.map { randomFactor(rows: $0, rank: rank, rng: &rng) }
        let tensor = buildTensor(dims: dims, factors: factors, rank: rank)

        let result = try await PARAFAC.decompose(
            tensor, modeNames: ["A", "B", "C"],
            options: .init(rank: rank, maxIter: 500, tol: 1e-10, nStarts: 8, seed: 0))

        #expect(result.fit > 0.9999)                    // near-perfect reconstruction
        #expect(result.factors.count == 3)
        #expect(result.factors[0].rows == 5 && result.factors[0].cols == 2)
        #expect(result.weights.count == 2)
        #expect(result.weights[0] >= result.weights[1]) // sorted descending
        #expect(abs(result.componentShare.reduce(0, +) - 1) < 1e-9)
    }

    @Test func runsFourWayDecomposition() async throws {
        var rng = SplitMix64(seed: 7)
        let dims = [6, 5, 3, 4]                          // channels × time × cond × subject
        let rank = 3
        let factors = dims.map { randomFactor(rows: $0, rank: rank, rng: &rng) }
        let tensor = buildTensor(dims: dims, factors: factors, rank: rank)

        let result = try await PARAFAC.decompose(
            tensor, modeNames: MultiwayTensor.erp4WayModeNames,
            options: .init(rank: rank, maxIter: 800, tol: 1e-11, nStarts: 10, seed: 0))

        #expect(result.fit > 0.999)
        #expect(result.factors.count == 4)
        #expect(result.maxCongruence < 0.999)           // not degenerate
    }

    @Test func coreConsistencyHighAtTrueRankLowWhenOverfit() async throws {
        var rng = SplitMix64(seed: 3)
        let dims = [6, 5, 4]
        let factors = dims.map { randomFactor(rows: $0, rank: 2, rng: &rng) }
        let tensor = buildTensor(dims: dims, factors: factors, rank: 2)

        let atTrue = try await PARAFAC.decompose(tensor, modeNames: ["A", "B", "C"],
                                                 options: .init(rank: 2, nStarts: 8, seed: 0))
        let ccTrue = MultiwayDiagnostics.coreConsistency(tensor: tensor, result: atTrue)
        #expect(ccTrue > 90)                       // genuinely rank-2

        let overfit = try await PARAFAC.decompose(tensor, modeNames: ["A", "B", "C"],
                                                  options: .init(rank: 4, nStarts: 8, seed: 0))
        let ccOver = MultiwayDiagnostics.coreConsistency(tensor: tensor, result: overfit)
        #expect(ccOver < ccTrue)                   // over-rank degrades core consistency
    }

    @Test func nonnegativeRecoversNonnegativeTensor() async throws {
        var rng = SplitMix64(seed: 11)
        let dims = [5, 4, 6]
        // Nonnegative factors → nonnegative tensor.
        let factors = dims.map { rows in
            (0..<rows).map { _ in (0..<2).map { _ in abs(rng.nextGaussian()) + 0.1 } }
        }
        let tensor = buildTensor(dims: dims, factors: factors, rank: 2)

        let result = try await PARAFAC.decompose(
            tensor, modeNames: ["A", "B", "C"],
            options: .init(rank: 2, maxIter: 1000, tol: 1e-11, nStarts: 8, seed: 0, nonnegative: true))

        #expect(result.fit > 0.999)
        for factor in result.factors {
            #expect(factor.grid.allSatisfy { $0 >= 0 })          // all loadings nonnegative
        }
    }

    @Test func emptyTensorThrows() async {
        let zero = MultiwayTensor(dims: [3, 3, 3], data: [Double](repeating: 0, count: 27))
        do {
            _ = try await PARAFAC.decompose(zero, modeNames: ["A", "B", "C"], options: .init(rank: 2))
            Issue.record("Expected empty tensor to throw")
        } catch is PARAFAC.PARAFACError {
            // Expected.
        } catch {
            Issue.record("Expected PARAFACError, got \(error)")
        }
    }
}
