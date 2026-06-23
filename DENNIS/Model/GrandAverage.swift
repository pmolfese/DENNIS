//
//  GrandAverage.swift
//  DENNIS
//
//  Pools loaded condition averages across subjects to form a group grand
//  average (mean across subjects, all channels) and its channel centroid (mean
//  across subjects *and* channels), mirroring the Python toolkit's
//  `grand_average_evoked` / `channel_centroid_evoked`.
//

import Foundation

struct GrandAverage {
    /// `channels × samples`, averaged across contributing subjects.
    let samples: [[Float]]
    /// Mean across channels of `samples` — one representative trace.
    let centroid: [Float]
    let baselineSamples: Int
    let sampleCount: Int
    let samplingRate: Double
    /// Number of subjects that contributed (loaded + dimension-matched).
    let contributing: Int
    let sensorLayout: SensorLayout?

    /// Compute the grand average for one condition name across the given
    /// datasets. Returns nil if no subject has loaded, dimension-consistent data
    /// for that condition.
    static func compute(datasets: [Dataset], condition name: String) -> GrandAverage? {
        // Gather matching, loaded conditions.
        let matches: [(Dataset, Condition)] = datasets.compactMap { dataset in
            guard let condition = dataset.conditions.first(where: { $0.name == name }),
                  let samples = condition.samples, !samples.isEmpty else { return nil }
            _ = samples
            return (dataset, condition)
        }
        guard let first = matches.first?.1, let firstSamples = first.samples else { return nil }
        let channelCount = firstSamples.count
        let sampleCount = firstSamples.first?.count ?? 0
        guard channelCount > 0, sampleCount > 0 else { return nil }

        // Sum only subjects whose dimensions match the first one.
        var sum = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: channelCount)
        var contributing = 0
        var sensorLayout: SensorLayout? = nil
        var baseline = first.baselineSamples
        for (dataset, condition) in matches {
            guard let samples = condition.samples,
                  samples.count == channelCount,
                  samples.first?.count == sampleCount else { continue }
            for c in 0..<channelCount {
                let channel = samples[c]
                for t in 0..<sampleCount { sum[c][t] += Double(channel[t]) }
            }
            contributing += 1
            if sensorLayout == nil { sensorLayout = dataset.sensorLayout }
            baseline = condition.baselineSamples
        }
        guard contributing > 0 else { return nil }

        let inv = 1.0 / Double(contributing)
        let averaged: [[Float]] = sum.map { channel in channel.map { Float($0 * inv) } }

        // Centroid: mean across channels at each time point.
        var centroid = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            var acc = 0.0
            for c in 0..<channelCount { acc += Double(averaged[c][t]) }
            centroid[t] = Float(acc / Double(channelCount))
        }

        return GrandAverage(
            samples: averaged,
            centroid: centroid,
            baselineSamples: baseline,
            sampleCount: sampleCount,
            samplingRate: matches.first?.0.samplingRate ?? 0,
            contributing: contributing,
            sensorLayout: sensorLayout
        )
    }
}
