//
//  WaveformAnalysisTests.swift
//  DENNISTests
//

import Foundation
import Testing
@testable import DENNIS

@MainActor
struct WaveformAnalysisTests {
    @Test func amplitudeMeasuresRespectWindowAndPolarity() {
        let samples: [[Float]] = [
            [0, 1, 4, 2, -1, -5, -2],
            [0, 3, 2, 1, -3, -1, -4],
        ]
        let category = WaveformCategory(name: "P1", startMS: 1, endMS: 5)

        let positivePeak = WaveformAnalysis.amplitude(
            samples: samples, samplingRate: 1_000, baselineSamples: 0,
            category: category, measure: .peak, polarity: .positive
        )
        let negativePeak = WaveformAnalysis.amplitude(
            samples: samples, samplingRate: 1_000, baselineSamples: 0,
            category: category, measure: .peak, polarity: .negative
        )
        let mean = WaveformAnalysis.amplitude(
            samples: samples, samplingRate: 1_000, baselineSamples: 0,
            category: category, measure: .mean, polarity: .both
        )

        #expect(positivePeak == 3)
        #expect(negativePeak == -3)
        #expect(mean == 0.3)
    }

    @Test func exportWritesFileMetadataAndCategoryColumns() {
        let condition = Condition(
            name: "Target",
            samples: [[0, 1, 2], [0, 3, 4]],
            sampleCount: 3,
            baselineSamples: 0
        )
        let dataset = Dataset(
            name: "Subject 1",
            sourceURL: URL(filePath: "/tmp/source 1.mff"),
            conditions: [condition],
            samplingRate: 1_000,
            channelCount: 2,
            levels: ["Adult", "Control"]
        )
        let category = WaveformCategory(name: "Early", startMS: 1, endMS: 2)

        let csv = WaveformAnalysis.exportCSV(
            datasets: [dataset],
            factorNames: ["Age", "Group"],
            conditionNames: ["Target"],
            categories: [category],
            selection: .mean,
            polarity: .both
        )

        #expect(csv.split(separator: "\n").map(String.init) == [
            "File,Age,Group,Early_MeanAmplitude_pos,Early_MeanAmplitude_neg",
            "source 1.mff,Adult,Control,2.5,2.5",
        ])
    }

    @Test func allMeasuresExportAppendsMetricSuffixes() {
        let condition = Condition(
            name: "Target",
            samples: [[0, 1, 2], [0, 3, 4]],
            sampleCount: 3,
            baselineSamples: 0
        )
        let dataset = Dataset(
            name: "Subject 1",
            sourceURL: URL(filePath: "/tmp/source 1.mff"),
            conditions: [condition],
            samplingRate: 1_000,
            channelCount: 2,
            levels: ["Adult"]
        )
        let category = WaveformCategory(name: "Early", startMS: 1, endMS: 2)

        let csv = WaveformAnalysis.exportCSV(
            datasets: [dataset],
            factorNames: ["Age"],
            conditionNames: ["Target"],
            categories: [category],
            selection: .all,
            polarity: .positive,
            adaptivePreMS: 0,
            adaptivePostMS: 0
        )

        #expect(csv.split(separator: "\n").map(String.init) == [
            "File,Age,Early_PeakAmplitude,Early_MeanAmplitude,Early_AdaptiveMeanAmplitude",
            "source 1.mff,Adult,3,2.5,3",
        ])
    }

    @Test func bothPolarityAllMeasuresWritesPositiveAndNegativeColumns() {
        let condition = Condition(
            name: "Target",
            samples: [[0, 1, 2], [0, 3, 4]],
            sampleCount: 3,
            baselineSamples: 0
        )
        let dataset = Dataset(
            name: "Subject 1",
            sourceURL: URL(filePath: "/tmp/source 1.mff"),
            conditions: [condition],
            samplingRate: 1_000,
            channelCount: 2,
            levels: ["Adult"]
        )
        let category = WaveformCategory(name: "Early", startMS: 1, endMS: 2)

        let csv = WaveformAnalysis.exportCSV(
            datasets: [dataset],
            factorNames: ["Age"],
            conditionNames: ["Target"],
            categories: [category],
            selection: .all,
            polarity: .both,
            adaptivePreMS: 0,
            adaptivePostMS: 0
        )

        #expect(csv.split(separator: "\n").map(String.init) == [
            "File,Age,Early_PeakAmplitude_pos,Early_PeakAmplitude_neg,Early_MeanAmplitude_pos,Early_MeanAmplitude_neg,Early_AdaptiveMeanAmplitude_pos,Early_AdaptiveMeanAmplitude_neg",
            "source 1.mff,Adult,3,2,2.5,2.5,3,2",
        ])
    }
}
