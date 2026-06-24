//
//  PARAFAC2Tests.swift
//  DENNISTests
//

import Testing
@testable import DENNIS

struct PARAFAC2Tests {

    @Test func recoversSubjectVaryingTemporalSlices() async throws {
        var rng = SplitMix64(seed: 21)
        let times = 7
        let features = 6
        let subjects = 5
        let rank = 2

        let h = Matrix([[1.0, 0.35], [-0.2, 0.9]])
        let b = randomMatrix(rows: features, cols: rank, rng: &rng)
        var cRows: [[Double]] = []
        for s in 0..<subjects {
            var row: [Double] = []
            for r in 0..<rank {
                row.append(0.7 + 0.2 * Double(s + 1) + 0.15 * Double(r))
            }
            cRows.append(row)
        }
        let c = Matrix(cRows)
        let p = (0..<subjects).map { _ in orthonormal(rows: times, cols: rank, rng: &rng) }

        var data = [Double](repeating: 0, count: times * features * subjects)
        for s in 0..<subjects {
            var scaledH = h
            for col in 0..<rank {
                for row in 0..<rank { scaledH[row, col] *= c[s, col] }
            }
            let slice = p[s].multiply(scaledH).multiply(b.transposed())
            for f in 0..<features {
                for t in 0..<times {
                    data[s * times * features + f * times + t] = slice[t, f]
                }
            }
        }
        let tensor = MultiwayTensor(dims: [times, features, subjects], data: data)

        let result = try await PARAFAC2.decompose(
            tensor, modeNames: ["Time", "Feature", "Subject"],
            varyingMode: 0, sliceMode: 2,
            options: .init(rank: rank, maxIter: 250, tol: 1e-9, nStarts: 4, seed: 0))

        #expect(result.fit > 0.98)
        #expect(result.factors.count == 3)
        #expect(result.factors[0].rows == times)
        #expect(result.factors[1].rows == features)
        #expect(result.factors[2].rows == subjects)
        #expect(result.weights.count == rank)
    }

    private func randomMatrix(rows: Int, cols: Int, rng: inout SplitMix64) -> Matrix {
        var grid = [Double](repeating: 0, count: rows * cols)
        for i in grid.indices { grid[i] = rng.nextGaussian() }
        return Matrix(rows: rows, cols: cols, columnMajor: grid)
    }

    private func orthonormal(rows: Int, cols: Int, rng: inout SplitMix64) -> Matrix {
        let m = randomMatrix(rows: rows, cols: cols, rng: &rng)
        let svd = try! m.svd()
        return svd.u.multiply(svd.vt)
    }
}
