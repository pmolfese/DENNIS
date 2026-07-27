//
//  DerivedDataBuilder.swift
//  DENNIS
//
//  Builders for first-class derived datasets. These keep reconstructed analysis
//  products separate from imported EEG while preserving subject, condition, and
//  design metadata so every tab can operate on the selected source uniformly.
//

import Foundation

enum DerivedDataBuilder {
    struct BuiltDerivedInput {
        let input: EPTensor.Input
        let channelIndices: [Int]?
    }

    static func reconstructedDualFactor(
        bundle: AnalysisStore.DualBundle,
        factor: TwoStepFactor,
        scope: AnalysisStore.DerivedReconstructionScope = .fullFactor,
        threshold: Double = 0
    ) -> BuiltDerivedInput? {
        let result = bundle.result
        guard result.second.indices.contains(factor.firstIndex),
              factor.firstIndex < result.first.pattern.cols else { return nil }
        let second = result.second[factor.firstIndex]
        guard factor.secondIndex < second.pattern.cols else { return nil }

        let temporal = result.first.pattern.column(factor.firstIndex)
        let spatial = second.pattern.column(factor.secondIndex)
        let nChannels = min(bundle.nChannels, spatial.count)
        let nTimes = temporal.count
        let nCells = bundle.conditionNames.count
        let nSubjects = bundle.subjectNames.count
        guard nChannels > 0, nTimes > 0, nCells > 0, nSubjects > 0 else { return nil }
        let sourceChannels: [Int]
        switch scope {
        case .fullFactor:
            sourceChannels = Array(0..<nChannels)
        case .selectedElectrodes:
            sourceChannels = (0..<nChannels).filter { abs(spatial[$0]) >= threshold }
        }
        guard !sourceChannels.isEmpty else { return nil }

        var subjects: [[[[Float]]]] = []
        subjects.reserveCapacity(nSubjects)
        for subject in 0..<nSubjects {
            var cells: [[[Float]]] = []
            cells.reserveCapacity(nCells)
            for cell in 0..<nCells {
                let scoreRow = cell + subject * nCells
                let score = scoreRow < second.scores.rows ? second.scores[scoreRow, factor.secondIndex] : 0
                var samples = Array(
                    repeating: Array(repeating: Float(0), count: nTimes),
                    count: sourceChannels.count
                )
                for (outputChannel, sourceChannel) in sourceChannels.enumerated() {
                    let channelWeight = spatial[sourceChannel] * score
                    for time in 0..<nTimes {
                        samples[outputChannel][time] = Float(channelWeight * temporal[time])
                    }
                }
                cells.append(samples)
            }
            subjects.append(cells)
        }

        let input = EPTensor.Input(
            nChannels: sourceChannels.count,
            nTimes: nTimes,
            conditionCount: nCells,
            subjects: subjects,
            samplingRate: bundle.samplingRate,
            baselineSamples: bundle.baselineSamples
        )
        return BuiltDerivedInput(
            input: input,
            channelIndices: scope == .fullFactor ? nil : sourceChannels
        )
    }
}
