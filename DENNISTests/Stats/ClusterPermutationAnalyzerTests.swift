//
//  ClusterPermutationAnalyzerTests.swift
//  DENNISTests
//
//  The statistics themselves, the two exchangeability schemes, and the
//  exhaustive-vs-Monte-Carlo branch. Hand calculations are written out in the
//  comments because both of the reference project's hand calculations were
//  wrong on the first pass and the arithmetic is what made that obvious.
//

import Foundation
import Testing
@testable import DENNIS

struct ClusterPermutationAnalyzerTests {
    // MARK: - Paired t

    @Test func pairedTMatchesAHandCalculatedOneSampleT() throws {
        // A = 2, 4, 6, 8 and B = 1, 2, 3, 4, so the differences are 1, 2, 3, 4.
        //   mean      = 10 / 4                = 2.5
        //   SS        = (1.5² + .5² + .5² + 1.5²) = 5
        //   variance  = 5 / 3                 = 1.666666667
        //   sd        = 1.290994449
        //   se        = 1.290994449 / 2       = 0.6454972244
        //   t         = 2.5 / 0.6454972244    = 3.872983346
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: [[2], [4], [6], [8]]),
            sampleB: .init(name: "B", units: [[1], [2], [3], [4]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 15, threshold: .statistic(1), seed: 3)
        ))
        #expect(abs(result.observedStatistics[0] - 3.872_983_346) < 1e-9)
        #expect(result.degreesOfFreedom == 3)
        #expect(result.pairCount == 4)
    }

    @Test func independentTMatchesAHandCalculatedTwoSampleT() throws {
        // A = 5, 7, 9 (mean 7, SS 8); B = 2, 4 (mean 3, SS 2).
        //   pooled variance = (8 + 2) / (5 - 2)      = 3.333333333
        //   se              = sqrt(3.333333333 * (1/3 + 1/2)) = sqrt(2.777777778)
        //                                                     = 1.666666667
        //   t               = (7 - 3) / 1.666666667  = 2.4
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: [[5], [7], [9]]),
            sampleB: .init(name: "B", units: [[2], [4]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .independent
        )
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 5, threshold: .statistic(1), seed: 3)
        ))
        #expect(abs(result.observedStatistics[0] - 2.4) < 1e-12)
        #expect(result.degreesOfFreedom == 3)
    }

    @Test func withinSubjectDesignRecoversAnEffectTheBetweenDesignMisses() throws {
        // Every subject has a large idiosyncratic offset and a small consistent
        // condition effect. Pairing removes the offset; treating the same data
        // as two independent groups drowns in it.
        let channelCount = 2
        let sampleCount = 20
        let featureCount = channelCount * sampleCount
        var rng = SplitMix64(seed: 0x9A1_7ED)
        let subjectCount = 20

        var conditionA: [[Double]] = []
        var conditionB: [[Double]] = []
        for _ in 0..<subjectCount {
            let offset = Double.random(in: -20...20, using: &rng)
            var a = [Double](repeating: 0, count: featureCount)
            var b = [Double](repeating: 0, count: featureCount)
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    let index = channel * sampleCount + sample
                    let effect = (6...13).contains(sample) ? 1.2 : 0
                    a[index] = offset + effect + Double.random(in: -0.4...0.4, using: &rng)
                    b[index] = offset + Double.random(in: -0.4...0.4, using: &rng)
                }
            }
            conditionA.append(a)
            conditionB.append(b)
        }

        func run(_ design: ClusterPermutationAnalyzer.Design) throws -> ClusterPermutationAnalyzer.Result {
            try #require(try ClusterPermutationAnalyzer.analyze(
                input: .init(
                    sampleA: .init(name: "A", units: conditionA),
                    sampleB: .init(name: "B", units: conditionB),
                    channelCount: channelCount,
                    sampleCount: sampleCount,
                    spatialAdjacency: [[1], [0]],
                    design: design
                ),
                configuration: .init(permutationCount: 499, threshold: .probability(0.05), seed: 11)
            ))
        }

        let paired = try run(.repeatedMeasures)
        let independent = try run(.independent)

        let pairedCluster = try #require(paired.clusters.first)
        #expect(pairedCluster.pValue < 0.05)
        #expect(pairedCluster.startSample <= 6)
        #expect(pairedCluster.endSample >= 13)
        // The between-subject offset swamps the independent test.
        #expect(independent.clusters.allSatisfy { $0.pValue > 0.05 })
    }

    @Test func betweenSubjectDesignRecoversAGroupEffectAPairedTestCannotSee() throws {
        // The mirror case: two genuinely independent groups whose subjects are
        // in no way matched. Pairing them by list position is meaningless here,
        // and the paired test has no group difference left to find.
        let channelCount = 2
        let sampleCount = 18
        let featureCount = channelCount * sampleCount
        var rng = SplitMix64(seed: 0x6B0_1DEA)

        func group(shift: Double, count: Int) -> [[Double]] {
            (0..<count).map { _ in
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let planted = (5...12).contains(sample) ? shift : 0
                        values[channel * sampleCount + sample] =
                            planted + Double.random(in: -0.7...0.7, using: &rng)
                    }
                }
                return values
            }
        }
        let groupA = group(shift: 1.4, count: 14)
        let groupB = group(shift: 0, count: 14)

        let between = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                sampleA: .init(name: "Older", units: groupA),
                sampleB: .init(name: "Younger", units: groupB),
                channelCount: channelCount,
                sampleCount: sampleCount,
                spatialAdjacency: [[1], [0]],
                design: .independent
            ),
            configuration: .init(permutationCount: 499, threshold: .probability(0.05), seed: 13)
        ))
        let cluster = try #require(between.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 6)
        #expect(cluster.endSample >= 11)
        #expect(between.degreesOfFreedom == 26)
    }

    @Test func pairedDesignRejectsUnequalSampleSizes() {
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: [[1], [2], [3]]),
            sampleB: .init(name: "B", units: [[1], [2]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        #expect(throws: ClusterPermutationAnalyzer.AnalysisError.unbalancedPairs) {
            try ClusterPermutationAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    @Test func rejectsRaggedMatrices() {
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: [[1, 2], [1]]),
            sampleB: .init(name: "B", units: [[1, 2], [1, 2]]),
            channelCount: 1,
            sampleCount: 2,
            spatialAdjacency: [[]],
            design: .independent
        )
        #expect(throws: ClusterPermutationAnalyzer.AnalysisError.invalidDimensions) {
            try ClusterPermutationAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    // MARK: - Determinism

    @Test func everyDesignAndInferenceModeIsDeterministicForTheSameSeed() throws {
        var rng = SplitMix64(seed: 0x2222)
        let makeUnits = { (0..<9).map { _ in (0..<12).map { _ in Double.random(in: -1...1, using: &rng) } } }
        let unitsA = makeUnits()
        let unitsB = makeUnits()

        for design in ClusterPermutationAnalyzer.Design.allCases {
            for inference in ClusterInferenceMode.allCases {
                let input = ClusterPermutationAnalyzer.Input(
                    sampleA: .init(name: "A", units: unitsA),
                    sampleB: .init(name: "B", units: unitsB),
                    channelCount: 2,
                    sampleCount: 6,
                    spatialAdjacency: [[1], [0]],
                    design: design
                )
                // 300 permutations against a 512-flip / 48,620-label null keeps
                // both the sampled and enumerated branches out of this case.
                let configuration = ClusterPermutationAnalyzer.Configuration(
                    permutationCount: 300,
                    threshold: .statistic(1.5),
                    inference: inference,
                    seed: 8
                )
                let first = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
                let second = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
                #expect(first == second)
            }
        }
    }

    // MARK: - Exhaustive enumeration

    @Test func smallPairedDesignsEnumerateInsteadOfSampling() throws {
        // 6 subjects admit only 2^6 = 64 sign flips. Asking for 5,000 must not
        // pretend to a p floor of 1/5001.
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                sampleA: .init(name: "A", units: (0..<6).map { [1.0 + Double($0) * 0.1] }),
                sampleB: .init(name: "B", units: (0..<6).map { _ in [0.0] }),
                channelCount: 1,
                sampleCount: 1,
                spatialAdjacency: [[]],
                design: .repeatedMeasures
            ),
            configuration: .init(permutationCount: 5_000, threshold: .statistic(1), seed: 5)
        ))
        #expect(result.rearrangements.isExhaustive)
        #expect(result.rearrangements.count == 64)
        #expect(result.nullMaximumClusterMasses.count == 64)
        #expect(abs(result.rearrangements.pValueFloor - 1.0 / 64) < 1e-12)

        // Every subject's difference points the same way, so no sign flip beats
        // the observed one except its own mirror image (cluster mass is the
        // absolute sum). The p-value is therefore 2/64 — and, crucially, an
        // exact multiple of 1/64 rather than of 1/5001.
        let cluster = try #require(result.clusters.first)
        #expect(abs(cluster.pValue - 2.0 / 64) < 1e-12)
        #expect(isExactMultipleOfTheEnumeratedCount(cluster.pValue, count: 64))
    }

    @Test func smallTwoGroupDesignsEnumerateTheirLabelSplits() throws {
        // C(8, 4) = 70 distinct group assignments.
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                sampleA: .init(name: "A", units: [[3.0], [3.2], [3.4], [3.6]]),
                sampleB: .init(name: "B", units: [[0.0], [0.2], [0.4], [0.6]]),
                channelCount: 1,
                sampleCount: 1,
                spatialAdjacency: [[]],
                design: .independent
            ),
            configuration: .init(permutationCount: 2_000, threshold: .statistic(1), seed: 7)
        ))
        #expect(result.rearrangements.isExhaustive)
        #expect(result.rearrangements.count == 70)
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue <= 2.0 / 70 + 1e-12)
        #expect(isExactMultipleOfTheEnumeratedCount(cluster.pValue, count: 70))
    }

    /// Under enumeration a p-value is a count over the enumerated total, so it
    /// must land exactly on a `1/count` grid. A Monte-Carlo p from the same run
    /// would sit on a `1/(n+1)` grid instead, which this catches.
    private func isExactMultipleOfTheEnumeratedCount(_ pValue: Double, count: Int) -> Bool {
        let scaled = pValue * Double(count)
        return abs(scaled - scaled.rounded()) < 1e-9
    }

    @Test func monteCarloApproachesTheExhaustivePValue() throws {
        // 10 subjects: 1024 sign flips, small enough to enumerate exactly and
        // large enough that a sampled run has to converge onto it.
        var rng = SplitMix64(seed: 0xA11_5EED)
        let unitsA = (0..<10).map { _ in [0.9 + Double.random(in: -0.5...0.5, using: &rng)] }
        let unitsB = (0..<10).map { _ in [Double.random(in: -0.5...0.5, using: &rng)] }
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: unitsA),
            sampleB: .init(name: "B", units: unitsB),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )

        let exhaustive = try #require(try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 4_000, threshold: .statistic(1), seed: 1)
        ))
        #expect(exhaustive.rearrangements.isExhaustive)
        #expect(exhaustive.rearrangements.count == 1_024)

        let sampled = try #require(try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 900, threshold: .statistic(1), seed: 1)
        ))
        #expect(!sampled.rearrangements.isExhaustive)

        let exact = try #require(exhaustive.clusters.first).pValue
        let approximate = try #require(sampled.clusters.first).pValue
        #expect(abs(approximate - exact) < 0.02)
    }

    // MARK: - Probability thresholds

    @Test func probabilityThresholdResolvesToTheCriticalStatistic() throws {
        var rng = SplitMix64(seed: 0x4B1D)
        let units = { (count: Int) in
            (0..<count).map { _ in (0..<10).map { _ in Double.random(in: -1...1, using: &rng) } }
        }
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                sampleA: .init(name: "A", units: units(16)),
                sampleB: .init(name: "B", units: units(16)),
                channelCount: 1,
                sampleCount: 10,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 49, threshold: .probability(0.05), seed: 9)
        ))
        // df = 30, so qt(.975, 30) = 2.042272.
        #expect(result.degreesOfFreedom == 30)
        let resolved = try #require(result.resolvedThreshold)
        #expect(abs(resolved - 2.042_272_456) < 1e-6)
    }

    // MARK: - TFCE end to end

    @Test func tfceFindsAPlantedEffectAndReportsPointPValues() throws {
        let channelCount = 3
        let sampleCount = 16
        let featureCount = channelCount * sampleCount
        var rng = SplitMix64(seed: 0x7C3E_0001)

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
                spatialAdjacency: [[1], [0, 2], [1]]
            ),
            configuration: .init(
                permutationCount: 299,
                inference: .tfce,
                tfce: .init(extentExponent: 0.5, heightExponent: 2, stepCount: 30),
                seed: 31
            )
        ))

        // TFCE ignores the cluster-forming threshold entirely.
        #expect(result.resolvedThreshold == nil)
        let scores = try #require(result.observedTFCEScores)
        let pointPValues = try #require(result.pointPValues)
        #expect(scores.count == featureCount)
        #expect(pointPValues.count == featureCount)

        // The planted region is significant; the untouched third channel is not.
        #expect(pointPValues[0 * sampleCount + 8] < 0.05)
        #expect(pointPValues[2 * sampleCount + 8] > 0.05)

        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 6)
        #expect(cluster.endSample >= 9)
    }

    @Test func tfceRejectsDegenerateParameters() {
        let input = ClusterPermutationAnalyzer.Input(
            sampleA: .init(name: "A", units: [[1], [2]]),
            sampleB: .init(name: "B", units: [[3], [4]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]]
        )
        #expect(throws: ClusterPermutationAnalyzer.AnalysisError.invalidConfiguration) {
            try ClusterPermutationAnalyzer.analyze(
                input: input,
                configuration: .init(inference: .tfce, tfce: .init(stepCount: 1))
            )
        }
    }
}
