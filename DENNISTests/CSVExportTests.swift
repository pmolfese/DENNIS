//
//  CSVExportTests.swift
//  DENNISTests
//
//  Reproduction harness for the "Factor Scores" export. Runs a small two-step
//  PCA and builds every CSV table to catch out-of-range / shape crashes.
//

import Testing
import Foundation
@testable import DENNIS

@MainActor
struct CSVExportTests {

    private func makeBundle(channels: Int, times: Int, cells: Int, subjects: Int,
                            firstFactors: Int, secondFactors: Int) throws -> AnalysisStore.DualBundle {
        var rng = SplitMix64(seed: 1)
        let tensor = EPTensor.randomNormal(dims: [channels, times, cells, subjects, 1, 1, 1], rng: &rng)
        let result = try TwoStepPCA.run(
            tensor: tensor, firstMode: .temporal, secondMode: .spatial,
            firstFactors: firstFactors, secondFactors: secondFactors,
            firstRotation: .promax, secondRotation: .promax,
            firstTimesMS: (0..<times).map { Double($0) * 4 }
        )
        return AnalysisStore.DualBundle(
            result: result, groupID: "g", groupLabel: "Group",
            conditionNames: (0..<cells).map { "c\($0)" },
            subjectNames: (0..<subjects).map { "s\($0)" },
            sensorLayout: nil, nChannels: channels
        )
    }

    @Test func factorScoresExportDoesNotCrash() throws {
        let bundle = try makeBundle(channels: 8, times: 20, cells: 3, subjects: 4,
                                    firstFactors: 2, secondFactors: 2)
        let store = AnalysisStore()

        let plain = CSVBuilders.factorScores(bundle, microvolts: false, measure: .peak,
                                             windowStartMS: 0, windowEndMS: 800, label: store.label)
        // header + one row per subject.
        #expect(plain.split(separator: "\n").count == 5)

        let microvolts = CSVBuilders.factorScores(bundle, microvolts: true, measure: .peak,
                                                  windowStartMS: 0, windowEndMS: 800, label: store.label)
        #expect(!microvolts.isEmpty)

        _ = CSVBuilders.temporalLoadings(bundle, label: store.label)
        _ = CSVBuilders.spatialLoadings(bundle, label: store.label)
    }
}
