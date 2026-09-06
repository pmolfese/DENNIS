//
//  PCAVoltageMapTests.swift
//  DENNISTests
//

import Testing
@testable import DENNIS

struct PCAVoltageMapTests {
    private let conditionDimension = "Condition"

    @Test func selectsDisjointWindowContainingGlobalTemporalPeak() throws {
        let selection = try #require(PCAVoltageMapBuilder.selectWindow(
            temporalLoading: [0, 0.5, 0.7, 0.2, 0, -0.8, -1.0, 0.1],
            timesMS: [0, 10, 20, 30, 40, 50, 60, 70],
            threshold: 0.4
        ))

        #expect(selection.indices == 5...6)
        #expect(selection.peakIndex == 6)
        #expect(selection.lowerMS == 50)
        #expect(selection.upperMS == 60)
        #expect(selection.peakMS == 60)
    }

    @Test func peakAndWindowMeanUseDifferentTemporalReductions() throws {
        let subjects = [
            subject("S1", samples: [
                [0, 10, 50, 30, 0],
                [0, 2, 4, 12, 0],
            ]),
            subject("S2", samples: [
                [0, 30, 70, 50, 0],
                [0, 6, 8, 10, 0],
            ]),
        ]
        let cells = cells(subjects: subjects)

        let peak = try #require(PCAVoltageMapBuilder.build(input(
            cells: cells, summary: .peakInWindow
        )))
        #expect(peak.values == [60, 6])
        #expect(peak.window.peakIndex == 2)
        #expect(peak.summaryLabel == "Peak · 20 ms")
        #expect(peak.contributingSubjectCells == 2)

        let mean = try #require(PCAVoltageMapBuilder.build(input(
            cells: cells, summary: .meanOverWindow
        )))
        #expect(mean.values == [40, 7])
        #expect(mean.summaryLabel == "Mean · 10–30 ms")
        #expect(mean.contributingSubjectCells == 2)
    }

    @Test func visibleCellsControlTheVoltageAggregation() throws {
        let subjects = [
            subject("A1", level: "A", samples: [[0, 10, 20, 30, 0]]),
            subject("B1", level: "B", samples: [[0, 100, 200, 300, 0]]),
        ]
        let cellInput = ClusterERPCellBuilder.Input(
            groupBy: ["Group"],
            conditionDimension: conditionDimension,
            factorNames: ["Group"],
            subjects: subjects,
            conditionNames: ["Target"]
        )
        let grouped = ClusterERPCellBuilder.build(cellInput)
        #expect(grouped.map(\.label) == ["A", "B"])

        let result = try #require(PCAVoltageMapBuilder.build(PCAVoltageMapBuilder.Input(
            cells: grouped,
            visibleCellLabels: ["A"],
            temporalLoading: [0, 0.5, 1, 0.5, 0],
            timesMS: [0, 10, 20, 30, 40],
            temporalThreshold: 0.4,
            summary: .peakInWindow,
            samplingRate: 100,
            baselineSamples: 0
        )))
        #expect(result.values == [20])
        #expect(result.cellLabels == ["A"])
        #expect(result.contributingSubjectCells == 1)
        #expect(result.aggregationLabel == "A · n=1")
    }

    @Test func meanIgnoresNonfiniteAndMissingSamples() throws {
        let subjects = [
            subject("S1", samples: [[0, 2, .nan, 8, 0], [0, 4]]),
            subject("S2", samples: [[0, 4, 10, 10, 0], [0, 8, 12, 16, 0]]),
        ]
        let result = try #require(PCAVoltageMapBuilder.build(input(
            cells: cells(subjects: subjects), summary: .meanOverWindow
        )))

        // Ch0: mean((2 + 8) / 2, (4 + 10 + 10) / 3) = 6.5.
        #expect(abs(result.values[0] - 6.5) < 1e-12)
        // Ch1: S1 contributes its one in-window sample (4); S2 contributes 12.
        #expect(result.values[1] == 8)
        #expect(result.contributingSubjectCells == 2)
    }

    @Test func pcaMillisecondsMapBackToFullEpochSampleIndices() throws {
        let mappedCells = cells(subjects: [
            subject("S1", samples: [[1, 2, 99, 4, 5]])
        ])
        let peak = try #require(PCAVoltageMapBuilder.build(PCAVoltageMapBuilder.Input(
            cells: mappedCells,
            visibleCellLabels: nil,
            temporalLoading: [0.5, 1, 0.5],
            timesMS: [-100, 0, 100],
            temporalThreshold: 0.4,
            summary: .peakInWindow,
            samplingRate: 10,
            baselineSamples: 2
        )))
        #expect(peak.values == [99])

        let mean = try #require(PCAVoltageMapBuilder.build(PCAVoltageMapBuilder.Input(
            cells: mappedCells,
            visibleCellLabels: nil,
            temporalLoading: [0.5, 1, 0.5],
            timesMS: [-100, 0, 100],
            temporalThreshold: 0.4,
            summary: .meanOverWindow,
            samplingRate: 10,
            baselineSamples: 2
        )))
        #expect(mean.values == [35])
    }

    @Test func thresholdAboveTemporalPeakProducesNoMap() {
        let selection = PCAVoltageMapBuilder.selectWindow(
            temporalLoading: [0, 0.2, -0.3, 0],
            timesMS: [],
            threshold: 0.4
        )
        #expect(selection == nil)
    }

    private func subject(_ name: String, level: String = "",
                         samples: [[Float]]) -> ClusterSubject {
        ClusterSubject(
            name: name,
            levels: level.isEmpty ? [] : [level],
            byCondition: ["Target": samples]
        )
    }

    private func cells(subjects: [ClusterSubject]) -> [ClusterERPCellBuilder.Cell] {
        ClusterERPCellBuilder.build(ClusterERPCellBuilder.Input(
            groupBy: [],
            conditionDimension: conditionDimension,
            factorNames: [],
            subjects: subjects,
            conditionNames: ["Target"]
        ))
    }

    private func input(cells: [ClusterERPCellBuilder.Cell],
                       summary: PCAVoltageSummary) -> PCAVoltageMapBuilder.Input {
        PCAVoltageMapBuilder.Input(
            cells: cells,
            visibleCellLabels: nil,
            temporalLoading: [0, 0.5, 1, 0.5, 0],
            timesMS: [0, 10, 20, 30, 40],
            temporalThreshold: 0.4,
            summary: summary,
            samplingRate: 100,
            baselineSamples: 0
        )
    }
}
