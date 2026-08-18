//
//  ETACCorrectionTests.swift
//  DENNISTests
//

import Testing
@testable import DENNIS

struct ETACCorrectionTests {
    @Test func nullMinimumPUsesEachSubtestsOwnScale() throws {
        // The two subtests have opposite rankings. Raw values are deliberately
        // incomparable; only their within-column tail ranks may be combined.
        let minima = try #require(ETACCorrection.nullMinimumPValues(
            maximaBySubtest: [
                [1, 2, 3, 4],
                [40, 30, 20, 10],
            ]
        ))
        #expect(minima == [0.25, 0.5, 0.5, 0.25])
    }

    @Test func jointCalibrationPreservesDependenceBetweenSubtests() throws {
        // Identical subtests add no multiplicity penalty: their minimum p has
        // the same null distribution as either subtest alone.
        let minima = try #require(ETACCorrection.nullMinimumPValues(
            maximaBySubtest: [
                [1, 2, 3, 4],
                [10, 20, 30, 40],
            ]
        ))
        let combined = ETACCorrection.combinedPValue(
            minimumMarginalP: 0.25,
            sortedNullMinimumPValues: minima.sorted(),
            exhaustive: true
        )
        #expect(combined == 0.25)
    }

    @Test func etacFindsAPlantedSpatiotemporalEffect() throws {
        let channelCount = 3
        let sampleCount = 16
        let featureCount = channelCount * sampleCount
        var rng = SplitMix64(seed: 0xE7AC_0001)

        func units(effect: Double) -> [[Double]] {
            (0..<20).map { _ in
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let planted = channel <= 1 && (5...10).contains(sample) ? effect : 0
                        values[channel * sampleCount + sample] =
                            planted + Double.random(in: -0.8...0.8, using: &rng)
                    }
                }
                return values
            }
        }

        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                sampleA: .init(name: "A", units: units(effect: 1.5)),
                sampleB: .init(name: "B", units: units(effect: 0)),
                channelCount: channelCount,
                sampleCount: sampleCount,
                spatialAdjacency: [[1], [0, 2], [1]],
                etacSpatialAdjacencies: [
                    [[], [], []],
                    [[1], [0, 2], [1]],
                    [[1, 2], [0, 2], [0, 1]],
                ]
            ),
            configuration: .init(
                permutationCount: 299,
                inference: .etac,
                etac: .init(thresholdProbabilities: [0.05, 0.01, 0.005]),
                seed: 31
            )
        ))

        #expect(result.resolvedThreshold == nil)
        #expect(result.resolvedETACThresholds?.count == 3)
        #expect(result.observedTFCEScores == nil)
        let pointPValues = try #require(result.pointPValues)
        #expect(pointPValues.count == featureCount)
        #expect(pointPValues[0 * sampleCount + 8] < 0.05)
        #expect(pointPValues[2 * sampleCount + 8] > 0.05)

        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 6)
        #expect(cluster.endSample >= 9)
    }

    @Test func etacRejectsDuplicateOrSingletonThresholdSets() {
        #expect(!ETACParameters(thresholdProbabilities: [0.05]).isValid)
        #expect(!ETACParameters(thresholdProbabilities: [0.05, 0.05]).isValid)
        #expect(ETACParameters(thresholdProbabilities: [0.05, 0.01]).isValid)
        #expect(!ETACParameters(radiusMultipliers: [1.7]).isValid)
        #expect(!ETACParameters(radiusMultipliers: [1.7, 1.7]).isValid)
    }
}
