//
//  ClusterPermutationFAnalyzerTests.swift
//  DENNISTests
//
//  The omnibus F in both its between-subject and within-subject forms.
//

import Foundation
import Testing
@testable import DENNIS

struct ClusterPermutationFAnalyzerTests {
    @Test func repeatedMeasuresFMatchesAHandCalculatedANOVA() throws {
        // 3 subjects × 3 conditions:
        //   s1: 1, 2, 3   s2: 2, 4, 6   s3: 3, 5, 7
        // Grand sum 33 over 9 observations, so the correction is 33²/9 = 121.
        // Condition sums 6, 11, 16:  (36 + 121 + 256)/3 = 413/3.
        //   SS_condition = 413/3 - 121 = 50/3.
        // Subject sums 6, 12, 15:    (36 + 144 + 225)/3 = 135.
        //   SS_subject   = 135 - 121 = 14.
        // Raw sum of squares 1+4+9+4+16+36+9+25+49 = 153.
        //   SS_total     = 153 - 121 = 32.
        //   SS_error     = 32 - 50/3 - 14 = 4/3.
        // F = (50/3 / 2) / (4/3 / 4) = 8.3333333 / 0.3333333 = 25.
        let input = ClusterPermutationFAnalyzer.Input(
            levels: [
                .init(name: "A", units: [[1], [2], [3]]),
                .init(name: "B", units: [[2], [4], [5]]),
                .init(name: "C", units: [[3], [6], [7]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 25, threshold: .statistic(1), seed: 5)
        ))
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 4)
        #expect(result.unitCount == 3)
        #expect(abs(result.observedStatistics[0] - 25) < 1e-10)
    }

    @Test func independentFMatchesAHandCalculatedOneWayANOVA() throws {
        // Groups: A = 1, 2, 3 (sum 6); B = 4, 5, 6 (sum 15); C = 7, 8, 9 (sum 24).
        // Grand sum 45 over 9, correction 45²/9 = 225.
        //   group correction = (36 + 225 + 576)/3 = 279
        //   SS_between = 279 - 225 = 54,  df 2  -> MS 27
        //   raw SS     = 285, SS_within = 285 - 279 = 6, df 6 -> MS 1
        //   F = 27
        let input = ClusterPermutationFAnalyzer.Input(
            levels: [
                .init(name: "A", units: [[1], [2], [3]]),
                .init(name: "B", units: [[4], [5], [6]]),
                .init(name: "C", units: [[7], [8], [9]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .independent
        )
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 30, threshold: .statistic(1), seed: 5)
        ))
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 6)
        #expect(result.unitCount == nil)
        #expect(abs(result.observedStatistics[0] - 27) < 1e-10)
    }

    @Test func repeatedMeasuresFRemovesTheSubjectMainEffect() throws {
        // Identical condition means, wildly different subject means: the
        // between-subject variance must land in the subject term, not the error
        // term, so F stays at zero rather than being deflated by it.
        let input = ClusterPermutationFAnalyzer.Input(
            levels: [
                .init(name: "A", units: [[1], [101], [1_001]]),
                .init(name: "B", units: [[1], [101], [1_001]]),
                .init(name: "C", units: [[1], [101], [1_001]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 9, threshold: .statistic(1), seed: 2)
        ))
        #expect(result.observedStatistics[0] == 0)
    }

    @Test func repeatedMeasuresFRejectsUnbalancedConditions() {
        let input = ClusterPermutationFAnalyzer.Input(
            levels: [
                .init(name: "A", units: [[1], [2], [3]]),
                .init(name: "B", units: [[1], [2]]),
                .init(name: "C", units: [[1], [2], [3]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        #expect(throws: ClusterPermutationFAnalyzer.AnalysisError.unbalancedUnits) {
            try ClusterPermutationFAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    @Test func twoLevelsAreRefusedByTheOmnibusF() {
        let input = ClusterPermutationFAnalyzer.Input(
            levels: [
                .init(name: "A", units: [[1], [2], [3]]),
                .init(name: "B", units: [[1], [2], [3]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .independent
        )
        #expect(throws: ClusterPermutationFAnalyzer.AnalysisError.insufficientLevels) {
            try ClusterPermutationFAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    @Test func repeatedMeasuresFFindsAPlantedWithinSubjectEffect() throws {
        let channelCount = 3
        let sampleCount = 18
        let featureCount = channelCount * sampleCount
        var rng = SplitMix64(seed: 0x5EED_F00D)
        let subjectCount = 14

        var conditions = [[[Double]]](repeating: [], count: 3)
        for _ in 0..<subjectCount {
            let offset = Double.random(in: -15...15, using: &rng)
            for condition in 0..<3 {
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let planted = channel <= 1 && (5...11).contains(sample)
                            ? Double(condition) * 1.5
                            : 0
                        values[channel * sampleCount + sample] =
                            offset + planted + Double.random(in: -0.5...0.5, using: &rng)
                    }
                }
                conditions[condition].append(values)
            }
        }

        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                levels: [
                    .init(name: "A", units: conditions[0]),
                    .init(name: "B", units: conditions[1]),
                    .init(name: "C", units: conditions[2]),
                ],
                channelCount: channelCount,
                sampleCount: sampleCount,
                spatialAdjacency: [[1], [0, 2], [1]],
                design: .repeatedMeasures
            ),
            configuration: .init(permutationCount: 499, threshold: .probability(0.05), seed: 77)
        ))
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 5)
        #expect(cluster.endSample >= 11)
        #expect(Set(cluster.channelIndices).isSuperset(of: [0, 1]))
    }

    @Test func fProbabilityThresholdResolvesAgainstBothDegreesOfFreedom() throws {
        var rng = SplitMix64(seed: 0xABCD)
        let units = { (0..<16).map { _ in (0..<5).map { _ in Double.random(in: -1...1, using: &rng) } } }
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                levels: [
                    .init(name: "A", units: units()),
                    .init(name: "B", units: units()),
                    .init(name: "C", units: units()),
                ],
                channelCount: 1,
                sampleCount: 5,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 19, threshold: .probability(0.05), seed: 4)
        ))
        // df = (2, 45), so qf(.95, 2, 45) = 3.2043175.
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 45)
        let resolved = try #require(result.resolvedThreshold)
        #expect(abs(resolved - 3.204_317_5) < 1e-5)
    }

    @Test func smallRepeatedMeasuresDesignsEnumerateWithinSubjectRelabelings() throws {
        // 3 conditions × 4 subjects = (3!)^4 = 1296 relabelings.
        let units = { (shift: Double) in
            (0..<4).map { index in [shift + Double(index) * 0.05] }
        }
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                levels: [
                    .init(name: "A", units: units(0)),
                    .init(name: "B", units: units(2)),
                    .init(name: "C", units: units(4)),
                ],
                channelCount: 1,
                sampleCount: 1,
                spatialAdjacency: [[]],
                design: .repeatedMeasures
            ),
            configuration: .init(permutationCount: 2_000, threshold: .statistic(1), seed: 17)
        ))
        #expect(result.rearrangements.isExhaustive)
        #expect(result.rearrangements.count == 1_296)
        #expect(result.nullMaximumClusterMasses.count == 1_296)

        // A strictly ordered condition effect is near-maximal under relabeling,
        // so only a handful of the 1296 arrangements tie it. What matters is
        // that the p-value lands on the 1/1296 grid — a Monte-Carlo p from the
        // same run would sit on a 1/2001 grid instead.
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.01)
        let scaled = cluster.pValue * 1_296
        #expect(abs(scaled - scaled.rounded()) < 1e-9)
    }

    @Test func fIsDeterministicForBothDesignsAndInferenceModes() throws {
        var rng = SplitMix64(seed: 0x3131)
        let makeUnits = { (0..<7).map { _ in (0..<8).map { _ in Double.random(in: -1...1, using: &rng) } } }
        let levels = [
            ClusterPermutationFAnalyzer.Level(name: "A", units: makeUnits()),
            ClusterPermutationFAnalyzer.Level(name: "B", units: makeUnits()),
            ClusterPermutationFAnalyzer.Level(name: "C", units: makeUnits()),
        ]
        for design in ClusterPermutationFAnalyzer.Design.allCases {
            for inference in ClusterInferenceMode.allCases {
                let input = ClusterPermutationFAnalyzer.Input(
                    levels: levels,
                    channelCount: 2,
                    sampleCount: 4,
                    spatialAdjacency: [[1], [0]],
                    design: design
                )
                let configuration = ClusterPermutationFAnalyzer.Configuration(
                    permutationCount: 200,
                    threshold: .statistic(2),
                    inference: inference,
                    seed: 44
                )
                let first = try ClusterPermutationFAnalyzer.analyze(input: input, configuration: configuration)
                let second = try ClusterPermutationFAnalyzer.analyze(input: input, configuration: configuration)
                #expect(first == second)
            }
        }
    }

    @Test func tfceWorksForTheOmnibusF() throws {
        var rng = SplitMix64(seed: 0x7C3E_0002)
        let sampleCount = 12
        func units(effect: Double) -> [[Double]] {
            (0..<12).map { _ in
                (0..<sampleCount).map { sample in
                    ((4...8).contains(sample) ? effect : 0) + Double.random(in: -0.6...0.6, using: &rng)
                }
            }
        }
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                levels: [
                    .init(name: "A", units: units(effect: 0)),
                    .init(name: "B", units: units(effect: 2.0)),
                    .init(name: "C", units: units(effect: -2.0)),
                ],
                channelCount: 1,
                sampleCount: sampleCount,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 299, inference: .tfce, seed: 61)
        ))
        let scores = try #require(result.observedTFCEScores)
        // F is non-negative, so no enhanced score may be negative.
        #expect(scores.allSatisfy { $0 >= 0 })
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 5)
        #expect(cluster.endSample >= 7)
    }
}
