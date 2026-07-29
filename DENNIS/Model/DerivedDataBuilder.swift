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
        let microvoltScale: [[Double]]?
        let factorPreview: AnalysisStore.DerivedDataItem.FactorPreview?
    }

    static func reconstructedDualFactor(
        bundle: AnalysisStore.DualBundle,
        factor: TwoStepFactor,
        scope: AnalysisStore.DerivedReconstructionScope = .fullFactor,
        threshold: Double = 0,
        output: AnalysisStore.DerivedReconstructionOutput = .includedChannels
    ) -> BuiltDerivedInput? {
        let result = bundle.result
        guard result.second.indices.contains(factor.firstIndex),
              factor.firstIndex < result.first.pattern.cols else { return nil }
        let second = result.second[factor.firstIndex]
        guard factor.secondIndex < second.pattern.cols else { return nil }

        let temporal = result.first.pattern.column(factor.firstIndex)
        let temporalSD = result.first.variableSD
        let spatial = second.pattern.column(factor.secondIndex)
        let spatialSD = second.variableSD
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
        let outputClusters: [[Int]]
        switch output {
        case .includedChannels:
            outputClusters = sourceChannels.map { [$0] }
        case .clusterAverages:
            let positive = sourceChannels.filter { spatial[$0] > 0 }
            let negative = sourceChannels.filter { spatial[$0] < 0 }
            outputClusters = [positive, negative].filter { !$0.isEmpty }
        }
        guard !outputClusters.isEmpty else { return nil }

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
                    count: outputClusters.count
                )
                for (outputChannel, cluster) in outputClusters.enumerated() {
                    let clusterWeight = meanSpatialLoading(spatial, channels: cluster) * score
                    let channelScale = aggregateMicrovoltScale(
                        spatial: spatial,
                        spatialSD: spatialSD,
                        temporalSD: temporalSD,
                        channels: cluster,
                        nTimes: nTimes
                    )
                    for time in 0..<nTimes {
                        samples[outputChannel][time] = Float(clusterWeight * temporal[time] * channelScale[time])
                    }
                }
                cells.append(samples)
            }
            subjects.append(cells)
        }

        let input = EPTensor.Input(
            nChannels: outputClusters.count,
            nTimes: nTimes,
            conditionCount: nCells,
            subjects: subjects,
            samplingRate: bundle.samplingRate,
            baselineSamples: bundle.baselineSamples
        )
        let preview = AnalysisStore.DerivedDataItem.FactorPreview(
            factorName: factor.name,
            temporalLoading: temporal,
            temporalTimesMS: result.firstTimesMS,
            spatialLoading: spatial,
            sensorLayout: bundle.sensorLayout,
            channelIndices: scope == .fullFactor ? nil : sourceChannels,
            variance: factor.variance
        )
        return BuiltDerivedInput(
            input: input,
            channelIndices: output == .includedChannels && scope == .selectedElectrodes ? sourceChannels : nil,
            microvoltScale: nil,
            factorPreview: preview
        )
    }

    private static func meanSpatialLoading(_ spatial: [Double], channels: [Int]) -> Double {
        guard !channels.isEmpty else { return 0 }
        let sum = channels.reduce(0.0) { partial, channel in
            partial + (channel < spatial.count ? spatial[channel] : 0)
        }
        return sum / Double(channels.count)
    }

    private static func aggregateMicrovoltScale(
        spatial: [Double],
        spatialSD: [Double],
        temporalSD: [Double],
        channels: [Int],
        nTimes: Int
    ) -> [Double] {
        let meanSpatial = meanSpatialLoading(spatial, channels: channels)
        guard abs(meanSpatial) > .ulpOfOne else {
            return Array(repeating: 1, count: nTimes)
        }
        let weightedSpatialSD = channels.reduce(0.0) { partial, channel in
            let loading = channel < spatial.count ? spatial[channel] : 0
            let scale = channel < spatialSD.count ? spatialSD[channel] : 1
            return partial + loading * scale
        } / Double(channels.count)
        return (0..<nTimes).map { time in
            let t = time < temporalSD.count ? temporalSD[time] : 1
            return weightedSpatialSD / meanSpatial * t
        }
    }
}
