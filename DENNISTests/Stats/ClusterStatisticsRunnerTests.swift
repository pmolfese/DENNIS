//
//  ClusterStatisticsRunnerTests.swift
//  DENNISTests
//
//  The design layer: turning subjects, conditions and between-subject groups
//  into the analyzers' matrices, collapsing within-subject contrasts into a
//  subject measure, and refusing — by name — the situations that would
//  otherwise silently change the design.
//

import Foundation
import Testing
@testable import DENNIS

struct ClusterStatisticsRunnerTests {
    // MARK: - Fixtures

    /// A subject whose every condition is a flat `channels × samples` block at
    /// the given amplitude, plus an optional bump.
    ///
    /// The bump is placed by *latency* — samples 2...7 after stimulus onset —
    /// rather than at fixed array indices, which is how real stimulus-locked
    /// data behaves. With the default 4-sample baseline that is array samples
    /// 6...11; with any other baseline it moves, which is exactly what makes
    /// these fixtures able to tell whether each subject was indexed through its
    /// own pre-stimulus interval.
    private func subject(
        name: String,
        group: String = "",
        conditions: [String: (level: Double, bump: Double)],
        channelCount: Int = 3,
        sampleCount: Int = 20,
        baselineSamples: Int = 4,
        samplingRate: Double = 250
    ) -> ClusterSubjectSnapshot {
        var snapshots: [String: ClusterConditionSnapshot] = [:]
        for (conditionName, spec) in conditions {
            let samples: [[Float]] = (0..<channelCount).map { _ in
                (0..<sampleCount).map { sample in
                    Float(spec.level + ((2...7).contains(sample - baselineSamples) ? spec.bump : 0))
                }
            }
            snapshots[conditionName] = ClusterConditionSnapshot(
                samples: samples,
                sampleCount: sampleCount,
                baselineSamples: baselineSamples
            )
        }
        return ClusterSubjectSnapshot(
            name: name,
            groupLabel: group,
            samplingRate: samplingRate,
            channelCount: channelCount,
            conditions: snapshots
        )
    }

    private func job(
        design: ClusterDesign,
        subjects: [ClusterSubjectSnapshot],
        windowStartMs: Double = 0,
        windowEndMs: Double = 60,
        sampleStride: Int = 1
    ) -> ClusterPermutationJob {
        ClusterPermutationJob(
            design: design,
            subjects: subjects,
            sensorLayout: nil,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            sampleStride: sampleStride,
            permutationCount: 200,
            threshold: .statistic(1.5),
            adjacency: ClusterAdjacencyConfiguration(method: .temporalOnly)
        )
    }

    // MARK: - Window and stride

    @Test func windowIsConvertedThroughBaselineAndSamplingRate() throws {
        // 250 Hz, baseline 4 samples. 0 ms is sample 4; 60 ms is sample 4 + 15.
        let subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
        )
        #expect(prepared.relativeSampleOffsets.first == 0)
        #expect(prepared.relativeSampleOffsets.last == 15)
        #expect(prepared.relativeSampleOffsets.count == 16)
        #expect(prepared.samplingRate == 250)
    }

    @Test func strideThinsTheTemporalLattice() throws {
        let subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(
                design: .withinPairedT(conditionA: "A", conditionB: "B"),
                subjects: subjects,
                sampleStride: 3
            )
        )
        #expect(prepared.relativeSampleOffsets == [0, 3, 6, 9, 12, 15])
    }

    @Test func etacBuildsTheThresholdByMontageRelativeRadiusGrid() throws {
        let subjects = (0..<6).map {
            subject(
                name: "S\($0)",
                conditions: ["A": (0, 1), "B": (0, 0)],
                channelCount: 4
            )
        }
        let layout = SensorLayout(
            name: "Irregular line",
            positions: [
                SensorPosition(channelIndex: 0, x: 0.0, y: 0),
                SensorPosition(channelIndex: 1, x: 0.1, y: 0),
                SensorPosition(channelIndex: 2, x: 0.2, y: 0),
                SensorPosition(channelIndex: 3, x: 0.4, y: 0),
            ]
        )
        let prepared = try ClusterStatisticsRunner.prepare(
            job: ClusterPermutationJob(
                design: .withinPairedT(conditionA: "A", conditionB: "B"),
                subjects: subjects,
                sensorLayout: layout,
                windowStartMs: 0,
                windowEndMs: 60,
                permutationCount: 31,
                inference: .etac
            )
        )

        #expect(abs((prepared.nearestNeighborSpacing ?? 0) - 0.1) < 1e-12)
        let radii = try #require(prepared.resolvedETACRadii)
        #expect(radii.count == 3)
        #expect(abs(radii[0] - 0.125) < 1e-12)
        #expect(abs(radii[1] - 0.17) < 1e-12)
        #expect(abs(radii[2] - 0.21) < 1e-12)
        #expect(prepared.etacSpatialAdjacencies.count == 3)

        let summaries = prepared.etacSpatialAdjacencies.map(ClusterSpatialAdjacency.summarize)
        #expect(summaries[0].isolatedChannelCount == 1)
        #expect(summaries[2].isolatedChannelCount == 0)
        #expect(summaries[2].meanNeighborCount > summaries[0].meanNeighborCount)
    }

    @Test func aWindowOutsideTheEpochIsRefusedWithTheAvailableRangeAndTheLimitingSubjects() {
        var subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        // A short epoch: 12 samples at 250 Hz with a 4-sample baseline covers
        // only -16 to 28 ms, against -16 to 60 ms for everyone else.
        subjects[2] = subject(name: "Short", conditions: ["A": (0, 1), "B": (0, 0)], sampleCount: 12)

        let error = #expect(throws: ClusterStatisticsRunner.PreparationError.self) {
            try ClusterStatisticsRunner.prepare(
                job: job(
                    design: .withinPairedT(conditionA: "A", conditionB: "B"),
                    subjects: subjects,
                    windowStartMs: 0,
                    windowEndMs: 60
                )
            )
        }
        guard case .windowOutsideEpoch(let start, let end, let limiting) = error else {
            Issue.record("expected a window refusal, got \(String(describing: error))")
            return
        }
        #expect(abs(start - -16) < 1e-9)
        #expect(abs(end - 28) < 1e-9)
        #expect(limiting == ["Short"])
        #expect(error?.message.contains("Short") == true)
    }

    // MARK: - Differing pre-stimulus intervals

    @Test func subjectsWithDifferentBaselinesAreAlignedOnStimulusOnset() throws {
        // The same stimulus-locked bump, epoched with different pre-stimulus
        // intervals. These files are perfectly usable together: the window is
        // measured from onset, so each subject is indexed through its own
        // baseline. Refusing them would discard data for no statistical reason.
        let subjects = [
            subject(name: "Long", conditions: ["A": (0, 5), "B": (0, 0)], sampleCount: 30, baselineSamples: 10),
            subject(name: "Short", conditions: ["A": (0, 5), "B": (0, 0)], sampleCount: 24, baselineSamples: 4),
            subject(name: "None", conditions: ["A": (0, 5), "B": (0, 0)], sampleCount: 20, baselineSamples: 0),
            subject(name: "Mid", conditions: ["A": (0, 5), "B": (0, 0)], sampleCount: 26, baselineSamples: 6),
        ]
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(
                design: .withinPairedT(conditionA: "A", conditionB: "B"),
                subjects: subjects,
                windowStartMs: 0,
                windowEndMs: 40
            )
        )
        #expect(prepared.contributingSubjects == ["Long", "Short", "None", "Mid"])
        #expect(prepared.excludedSubjects.isEmpty)
        #expect(prepared.relativeSampleOffsets.first == 0)
        #expect(prepared.relativeSampleOffsets.last == 10)

        // Every subject's first analysis sample is its own onset sample, so the
        // planted bump (epoch samples 6...11) lands at the same analysis index
        // for all of them only if each was indexed through its own baseline.
        for units in prepared.series[0].units {
            #expect(abs(units[0] - 0) < 1e-6)
        }
        let epochs = prepared.epochs
        #expect(epochs.map(\.baselineSamples) == [10, 4, 0, 6])
        // The common stimulus-relative window is bounded by the *tightest*
        // subject on each side: "None" has no pre-stimulus period at all, and
        // "None" also runs out first after onset.
        #expect(abs(epochs.map(\.startMs).max()! - 0) < 1e-9)
        #expect(abs(epochs.map(\.endMs).min()! - 76) < 1e-9)
    }

    @Test func aDifferingBaselineShiftsWhichSamplesAreRead() throws {
        // Two subjects whose bumps sit at different absolute sample indices but
        // the same latency after onset. If the baselines were ignored, one of
        // these would be read from the wrong place and the difference would not
        // cancel.
        let subjects = [
            subject(name: "EarlyOnset", conditions: ["A": (0, 4), "B": (0, 0)], sampleCount: 20, baselineSamples: 2),
            subject(name: "LateOnset", conditions: ["A": (0, 4), "B": (0, 0)], sampleCount: 20, baselineSamples: 9),
        ]
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(
                design: .withinPairedT(conditionA: "A", conditionB: "B"),
                subjects: subjects,
                windowStartMs: 0,
                windowEndMs: 32
            )
        )
        // The bump sits 2...7 samples after each subject's own onset — array
        // samples 4...9 for one and 11...16 for the other. Both must land on
        // analysis samples 2...7, which only happens if each was indexed
        // through its own baseline rather than a shared one.
        #expect(prepared.series[0].units.count == 2)
        for units in prepared.series[0].units {
            #expect(abs(units[0] - 0) < 1e-6)
            #expect(abs(units[1] - 0) < 1e-6)
            #expect(abs(units[2] - 4) < 1e-6)
            #expect(abs(units[7] - 4) < 1e-6)
            #expect(abs(units[8] - 0) < 1e-6)
        }
    }

    // MARK: - Refusals

    @Test func aChannelCountMismatchIsRefusedByNameRatherThanSkipped() {
        var subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        subjects[2] = subject(name: "Odd", conditions: ["A": (0, 1), "B": (0, 0)], channelCount: 2)

        let error = #expect(throws: ClusterStatisticsRunner.PreparationError.self) {
            try ClusterStatisticsRunner.prepare(
                job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
            )
        }
        guard case .channelCountMismatch(let names, _) = error else {
            Issue.record("expected a channel-count mismatch, got \(String(describing: error))")
            return
        }
        #expect(names == ["Odd"])
        #expect(error?.message.contains("Odd") == true)
    }

    @Test func aMismatchedSamplingRateIsRefusedByName() {
        var subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        subjects[1] = subject(name: "Fast", conditions: ["A": (0, 1), "B": (0, 0)], samplingRate: 500)

        let error = #expect(throws: ClusterStatisticsRunner.PreparationError.self) {
            try ClusterStatisticsRunner.prepare(
                job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
            )
        }
        guard case .mismatchedSamplingRate(let names, _) = error else {
            Issue.record("expected a sampling-rate refusal, got \(String(describing: error))")
            return
        }
        #expect(names == ["Fast"])
    }

    @Test func aSubjectMissingAConditionIsExcludedAndReported() throws {
        var subjects = (0..<4).map {
            subject(name: "S\($0)", conditions: ["A": (0, 1), "B": (0, 0)])
        }
        subjects[1] = subject(name: "PartialB", conditions: ["A": (0, 1)])

        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
        )
        // Excluded, never padded with zeros, and named in the report.
        #expect(prepared.contributingSubjects == ["S0", "S2", "S3"])
        #expect(prepared.excludedSubjects.map(\.name) == ["PartialB"])
        #expect(prepared.excludedSubjects[0].reason.contains("B"))
        #expect(prepared.series.allSatisfy { $0.units.count == 3 })
    }

    @Test func aSingleSubjectGroupIsRefused() {
        let subjects = [
            subject(name: "A1", group: "Older", conditions: ["X": (0, 1), "Y": (0, 0)]),
            subject(name: "A2", group: "Older", conditions: ["X": (0, 1), "Y": (0, 0)]),
            subject(name: "B1", group: "Younger", conditions: ["X": (0, 0), "Y": (0, 0)]),
        ]
        let error = #expect(throws: ClusterStatisticsRunner.PreparationError.self) {
            try ClusterStatisticsRunner.prepare(
                job: job(
                    design: .betweenT(measure: .condition("X"), groupA: "Older", groupB: "Younger"),
                    subjects: subjects
                )
            )
        }
        guard case .singleSubjectGroup(let group, let count) = error else {
            Issue.record("expected a single-subject-group refusal, got \(String(describing: error))")
            return
        }
        #expect(group == "Younger")
        #expect(count == 1)
    }

    @Test func anAbsentGroupIsRefused() {
        let subjects = (0..<4).map {
            subject(name: "S\($0)", group: "Older", conditions: ["X": (0, 1), "Y": (0, 0)])
        }
        let error = #expect(throws: ClusterStatisticsRunner.PreparationError.self) {
            try ClusterStatisticsRunner.prepare(
                job: job(
                    design: .betweenT(measure: .condition("X"), groupA: "Older", groupB: "Younger"),
                    subjects: subjects
                )
            )
        }
        guard case .missingGroups(let groups) = error else {
            Issue.record("expected a missing-group refusal, got \(String(describing: error))")
            return
        }
        #expect(groups == ["Younger"])
    }

    @Test func anIncompleteDesignIsRefused() {
        let subjects = (0..<4).map { subject(name: "S\($0)", conditions: ["A": (0, 1)]) }
        #expect(throws: ClusterStatisticsRunner.PreparationError.invalidDesign) {
            try ClusterStatisticsRunner.prepare(
                job: job(design: .withinPairedT(conditionA: "A", conditionB: "A"), subjects: subjects)
            )
        }
    }

    // MARK: - Subject measures

    @Test func differenceMeasureCollapsesTheWithinSubjectDimension() throws {
        let subjects = (0..<4).map { index in
            subject(
                name: "S\(index)",
                group: index < 2 ? "Older" : "Younger",
                conditions: ["X": (10, 3), "Y": (10, 0)]
            )
        }
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(
                design: .betweenT(measure: .difference("X", "Y"), groupA: "Older", groupB: "Younger"),
                subjects: subjects
            )
        )
        #expect(prepared.series.map(\.name) == ["Older", "Younger"])
        #expect(prepared.series.allSatisfy { $0.units.count == 2 })
        // The shared level of 10 µV cancels; only the 3 µV bump survives.
        let unit = try #require(prepared.series[0].units.first)
        let sampleCount = prepared.relativeSampleOffsets.count
        #expect(abs(unit[0]) < 1e-9)
        #expect(abs(unit[6] - 3) < 1e-9)
        #expect(unit.count == 3 * sampleCount)
        #expect(prepared.measureLabel.contains("X"))
    }

    @Test func meanMeasureAveragesTheNamedConditions() throws {
        let subjects = (0..<4).map { index in
            subject(
                name: "S\(index)",
                group: index < 2 ? "Older" : "Younger",
                conditions: ["X": (2, 0), "Y": (6, 0)]
            )
        }
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(
                design: .betweenT(measure: .mean(["X", "Y"]), groupA: "Older", groupB: "Younger"),
                subjects: subjects
            )
        )
        let unit = try #require(prepared.series[0].units.first)
        #expect(abs(unit[0] - 4) < 1e-9)
    }

    @Test func withinSubjectSeriesKeepTheSameSubjectOrder() throws {
        // The pairing is only meaningful if index i means the same subject in
        // every series, so this ordering is load-bearing, not incidental.
        let subjects = (0..<5).map { index in
            subject(name: "S\(index)", conditions: ["A": (Double(index), 1), "B": (Double(index), 0)])
        }
        let prepared = try ClusterStatisticsRunner.prepare(
            job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
        )
        #expect(prepared.contributingSubjects == ["S0", "S1", "S2", "S3", "S4"])
        for index in 0..<5 {
            // Baseline sample carries the subject's own offset in both series.
            #expect(abs(prepared.series[0].units[index][0] - Double(index)) < 1e-9)
            #expect(abs(prepared.series[1].units[index][0] - Double(index)) < 1e-9)
        }
    }

    // MARK: - End to end

    @Test func aWithinSubjectRunFindsThePlantedWindowAndSummarizesItsWaveforms() throws {
        var rng = SplitMix64(seed: 0x0DE_115)
        let subjects = (0..<12).map { index -> ClusterSubjectSnapshot in
            let offset = Double.random(in: -8...8, using: &rng)
            let noise = Double.random(in: -0.2...0.2, using: &rng)
            return subject(
                name: "S\(index)",
                conditions: ["A": (offset + noise, 2.0), "B": (offset - noise, 0)]
            )
        }
        let response = ClusterStatisticsRunner.run(
            job: ClusterPermutationJob(
                design: .withinPairedT(conditionA: "A", conditionB: "B"),
                subjects: subjects,
                sensorLayout: nil,
                windowStartMs: 0,
                windowEndMs: 60,
                permutationCount: 500,
                threshold: .probability(0.05),
                adjacency: ClusterAdjacencyConfiguration(method: .temporalOnly)
            )
        )
        #expect(response.errorMessage == nil)
        let output = try #require(response.output)
        #expect(output.analysis.statistic == .t)
        #expect(output.analysis.unitCount == 12)
        #expect(output.analysis.denominatorDegreesOfFreedom == 11)
        // 2^12 = 4096 sign flips exceeds the 500 requested, so this run samples
        // and its floor is 1/501 rather than 1/4096.
        #expect(!output.analysis.rearrangements.isExhaustive)
        #expect(output.analysis.rearrangements.totalCount == 4_096)

        let cluster = try #require(output.analysis.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.sign == 1)
        // The bump occupies samples 6...11 of the epoch, which is offset 2...7
        // in the analysis window that starts at stimulus onset.
        #expect(cluster.startSample <= 2)
        #expect(cluster.endSample >= 7)

        let waveforms = try #require(output.clusterWaveforms[cluster.id])
        let inA = try #require(waveforms["A"])
        let inB = try #require(waveforms["B"])
        #expect(inA.mean.count == output.analysis.sampleCount)
        // The across-subject SEM reflects the idiosyncratic offsets, which are
        // real between-subject variance even though the paired test removes them.
        #expect(inA.standardError.allSatisfy { $0 > 0 })
        #expect(inA.mean[4] - inB.mean[4] > 1.5)
    }

    @Test func aMixedInteractionRunComparesDifferenceScoresBetweenGroups() throws {
        var rng = SplitMix64(seed: 0x1_D1FF)
        // Both groups show the within-subject effect; only "Older" shows it
        // twice as strongly, so the *interaction* is what is being tested.
        let subjects = (0..<16).map { index -> ClusterSubjectSnapshot in
            let older = index < 8
            let offset = Double.random(in: -10...10, using: &rng)
            let noise = Double.random(in: -0.15...0.15, using: &rng)
            return subject(
                name: "S\(index)",
                group: older ? "Older" : "Younger",
                conditions: [
                    "X": (offset + noise, older ? 3.0 : 1.0),
                    "Y": (offset - noise, 0),
                ]
            )
        }
        let response = ClusterStatisticsRunner.run(
            job: ClusterPermutationJob(
                design: .mixedInteraction(measure: .difference("X", "Y"), groups: ["Older", "Younger"]),
                subjects: subjects,
                sensorLayout: nil,
                windowStartMs: 0,
                windowEndMs: 60,
                permutationCount: 800,
                threshold: .probability(0.05),
                adjacency: ClusterAdjacencyConfiguration(method: .temporalOnly)
            )
        )
        #expect(response.errorMessage == nil)
        let output = try #require(response.output)
        // Two groups, so the interaction runs through the independent t rather
        // than needing any new statistic.
        #expect(output.analysis.statistic == .t)
        #expect(output.analysis.seriesNames == ["Older", "Younger"])
        #expect(output.analysis.seriesCounts == [8, 8])
        #expect(output.analysis.denominatorDegreesOfFreedom == 14)
        #expect(output.measureLabel.contains("X"))

        let cluster = try #require(output.analysis.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.sign == 1)
    }

    @Test func aFailedRunReportsAMessageRatherThanAnEmptyResult() {
        let subjects = [subject(name: "Only", conditions: ["A": (0, 1), "B": (0, 0)])]
        let response = ClusterStatisticsRunner.run(
            job: job(design: .withinPairedT(conditionA: "A", conditionB: "B"), subjects: subjects)
        )
        #expect(response.output == nil)
        let message = response.errorMessage ?? ""
        #expect(message.contains("at least two"))
    }
}
