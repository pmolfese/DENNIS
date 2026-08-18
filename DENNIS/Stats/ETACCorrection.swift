//
//  ETACCorrection.swift
//  DENNIS
//
//  Permutation calibration for ETAC-EEG's union of cluster subtests.
//

import Foundation

/// The inferential core of DENNIS's ETAC-style multi-threshold correction.
///
/// Raw cluster masses cannot be maximized across cluster-forming thresholds or
/// sensor radii: permissive thresholds and broader graphs naturally produce
/// larger masses. Instead, each subtest's maximum-cluster null is
/// rank-transformed to a marginal p-value. The minimum marginal p across the
/// threshold × radius grid is then calibrated against its own permutation
/// distribution. Equal marginal cutoffs make the subtests equitable, while the
/// final calibration controls their union.
nonisolated enum ETACCorrection {
    /// One minimum marginal p-value per rearrangement.
    /// `maximaBySubtest[j][p]` is the largest null cluster mass for subtest j
    /// under rearrangement p.
    static func nullMinimumPValues(maximaBySubtest: [[Double]]) -> [Double]? {
        guard let count = maximaBySubtest.first?.count,
              count > 0,
              maximaBySubtest.count >= 2,
              maximaBySubtest.allSatisfy({ $0.count == count }) else { return nil }

        let sortedColumns = maximaBySubtest.map { $0.sorted() }
        var minima = [Double](repeating: 1, count: count)
        for subtest in maximaBySubtest.indices {
            let sorted = sortedColumns[subtest]
            for permutation in 0..<count {
                // A null value is already one member of this empirical null;
                // its rank therefore uses count rather than count + 1.
                let exceedances = tailCount(atLeast: maximaBySubtest[subtest][permutation], in: sorted)
                let marginal = Double(max(exceedances, 1)) / Double(count)
                minima[permutation] = min(minima[permutation], marginal)
            }
        }
        return minima
    }

    /// Spatially corrected p-value for one observed cluster within a subtest.
    static func marginalPValue(
        clusterMass: Double,
        sortedNullMaxima: [Double],
        exhaustive: Bool
    ) -> Double {
        guard !sortedNullMaxima.isEmpty else { return 1 }
        let exceedances = tailCount(atLeast: clusterMass, in: sortedNullMaxima)
        if exhaustive {
            return Double(max(exceedances, 1)) / Double(sortedNullMaxima.count)
        }
        return Double(exceedances + 1) / Double(sortedNullMaxima.count + 1)
    }

    /// Joint corrected p-value for the union across all ETAC subtests.
    static func combinedPValue(
        minimumMarginalP: Double,
        sortedNullMinimumPValues: [Double],
        exhaustive: Bool
    ) -> Double {
        guard !sortedNullMinimumPValues.isEmpty else { return 1 }
        let hits = lowerTailCount(atMost: minimumMarginalP, in: sortedNullMinimumPValues)
        if exhaustive {
            return Double(max(hits, 1)) / Double(sortedNullMinimumPValues.count)
        }
        return Double(hits + 1) / Double(sortedNullMinimumPValues.count + 1)
    }

    private static func tailCount(atLeast value: Double, in sorted: [Double]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return sorted.count - low
    }

    private static func lowerTailCount(atMost value: Double, in sorted: [Double]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
