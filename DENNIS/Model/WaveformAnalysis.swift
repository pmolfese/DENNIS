//
//  WaveformAnalysis.swift
//  DENNIS
//
//  Windowed ERP amplitude measures and CSV export for the Waveform Analysis tab.
//

import Foundation

nonisolated enum WaveformAmplitudeMeasure: String, CaseIterable, Identifiable, Sendable {
    case peak = "Peak Amplitude"
    case mean = "Mean Amplitude"
    case adaptiveMean = "Adaptive Mean Amplitude"
    var id: String { rawValue }

    var exportSuffix: String {
        switch self {
        case .peak: "PeakAmplitude"
        case .mean: "MeanAmplitude"
        case .adaptiveMean: "AdaptiveMeanAmplitude"
        }
    }
}

nonisolated enum WaveformMeasureSelection: String, CaseIterable, Identifiable, Sendable {
    case adaptiveMean = "Adaptive Mean"
    case peak = "Peak"
    case mean = "Mean"
    case all = "All Measures"
    var id: String { rawValue }

    var measures: [WaveformAmplitudeMeasure] {
        switch self {
        case .adaptiveMean: [.adaptiveMean]
        case .peak: [.peak]
        case .mean: [.mean]
        case .all: WaveformAmplitudeMeasure.allCases
        }
    }
}

nonisolated enum WaveformPolarity: String, CaseIterable, Identifiable, Sendable {
    case positive = "Positive"
    case negative = "Negative"
    case both = "Both"
    var id: String { rawValue }
}

nonisolated struct WaveformCategory: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var startMS: Double
    var endMS: Double

    init(id: UUID = UUID(), name: String, startMS: Double, endMS: Double) {
        self.id = id
        self.name = name
        self.startMS = startMS
        self.endMS = endMS
    }

    var orderedWindow: ClosedRange<Double> {
        min(startMS, endMS)...max(startMS, endMS)
    }
}

nonisolated struct WaveformExportColumn: Identifiable, Hashable, Sendable {
    let title: String
    let category: WaveformCategory
    let measure: WaveformAmplitudeMeasure
    let polarity: WaveformPolarity

    var id: String { title }
}

@MainActor
enum WaveformAnalysis {
    struct GroupAverage {
        let samples: [[Float]]
        let centroid: [Float]
        let samplingRate: Double
        let baselineSamples: Int
        let sensorLayout: SensorLayout?

        var sampleCount: Int { samples.first?.count ?? centroid.count }
    }

    static func groupAverage(datasets: [Dataset], conditionNames: [String]) -> GroupAverage? {
        var sum: [[Double]] = []
        var count = 0
        var samplingRate = 0.0
        var baselineSamples = 0
        var channelCount = 0
        var sampleCount = 0
        var sensorLayout: SensorLayout?

        for dataset in datasets {
            guard dataset.samplingRate > 0 else { continue }
            if sensorLayout == nil { sensorLayout = dataset.sensorLayout }
            for name in conditionNames {
                guard let condition = dataset.conditions.first(where: { $0.name == name }),
                      let samples = condition.samples,
                      let first = samples.first,
                      !samples.isEmpty,
                      !first.isEmpty else { continue }

                if sum.isEmpty {
                    channelCount = samples.count
                    sampleCount = first.count
                    samplingRate = dataset.samplingRate
                    baselineSamples = condition.baselineSamples
                    sum = Array(repeating: Array(repeating: 0, count: sampleCount), count: channelCount)
                }

                guard samples.count == channelCount, first.count == sampleCount else { continue }
                for channel in 0..<channelCount where samples[channel].count == sampleCount {
                    for sample in 0..<sampleCount {
                        sum[channel][sample] += Double(samples[channel][sample])
                    }
                }
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        let averaged = sum.map { channel in channel.map { Float($0 * inv) } }
        return GroupAverage(
            samples: averaged,
            centroid: centroid(averaged),
            samplingRate: samplingRate,
            baselineSamples: baselineSamples,
            sensorLayout: sensorLayout
        )
    }

    static func datasetAverage(_ dataset: Dataset, conditionNames: [String]) -> [[Float]]? {
        var sum: [[Double]] = []
        var count = 0
        var channelCount = 0
        var sampleCount = 0

        for name in conditionNames {
            guard let condition = dataset.conditions.first(where: { $0.name == name }),
                  let samples = condition.samples,
                  let first = samples.first,
                  !samples.isEmpty,
                  !first.isEmpty else { continue }

            if sum.isEmpty {
                channelCount = samples.count
                sampleCount = first.count
                sum = Array(repeating: Array(repeating: 0, count: sampleCount), count: channelCount)
            }

            guard samples.count == channelCount, first.count == sampleCount else { continue }
            for channel in 0..<channelCount where samples[channel].count == sampleCount {
                for sample in 0..<sampleCount {
                    sum[channel][sample] += Double(samples[channel][sample])
                }
            }
            count += 1
        }

        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        return sum.map { channel in channel.map { Float($0 * inv) } }
    }

    nonisolated static func amplitude(samples: [[Float]], samplingRate: Double, baselineSamples: Int,
                                      category: WaveformCategory, measure: WaveformAmplitudeMeasure,
                                      polarity: WaveformPolarity,
                                      adaptivePreMS: Double = 12.5,
                                      adaptivePostMS: Double = 12.5) -> Double? {
        let values = collapsedTrace(samples)
        guard !values.isEmpty, samplingRate > 0 else { return nil }
        let indices = sampleIndices(for: category.orderedWindow, samplingRate: samplingRate,
                                    baselineSamples: baselineSamples, sampleCount: values.count)
        guard !indices.isEmpty else { return nil }

        switch measure {
        case .peak:
            return peak(in: values, indices: indices, polarity: polarity)
        case .mean:
            return mean(in: values, indices: indices)
        case .adaptiveMean:
            guard let peakIndex = peakIndex(in: values, indices: indices, polarity: polarity) else { return nil }
            let preSamples = max(0, Int((max(0, adaptivePreMS) / 1000 * samplingRate).rounded()))
            let postSamples = max(0, Int((max(0, adaptivePostMS) / 1000 * samplingRate).rounded()))
            let lower = max(indices.first ?? peakIndex, peakIndex - preSamples)
            let upper = min(indices.last ?? peakIndex, peakIndex + postSamples)
            return mean(in: values, indices: Array(lower...upper))
        }
    }

    static func exportCSV(datasets: [Dataset], factorNames: [String], conditionNames: [String],
                          categories: [WaveformCategory], selection: WaveformMeasureSelection,
                          polarity: WaveformPolarity,
                          adaptivePreMS: Double = 12.5,
                          adaptivePostMS: Double = 12.5,
                          limitRows: Int? = nil) -> String {
        let columns = exportColumns(categories: categories, selection: selection, polarity: polarity)
        var headers = ["File"] + factorNames
        headers += columns.map(\.title)
        var lines = [headers.map(escape).joined(separator: ",")]

        let exportedDatasets = limitRows.map { Array(datasets.prefix($0)) } ?? datasets
        for dataset in exportedDatasets {
            let baseline = dataset.conditions.first(where: { conditionNames.contains($0.name) })?.baselineSamples ?? 0
            let averaged = datasetAverage(dataset, conditionNames: conditionNames)
            var row = [escape(dataset.sourceURL.lastPathComponent)]
            for i in factorNames.indices {
                row.append(escape(i < dataset.levels.count ? dataset.levels[i] : ""))
            }
            for column in columns {
                if let averaged,
                   let value = amplitude(samples: averaged, samplingRate: dataset.samplingRate,
                                         baselineSamples: baseline, category: column.category,
                                         measure: column.measure, polarity: column.polarity,
                                         adaptivePreMS: adaptivePreMS,
                                         adaptivePostMS: adaptivePostMS) {
                    row.append(formatExportValue(value))
                } else {
                    row.append("")
                }
            }
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    nonisolated static func exportColumns(categories: [WaveformCategory], selection: WaveformMeasureSelection,
                                          polarity: WaveformPolarity) -> [WaveformExportColumn] {
        let polarities: [WaveformPolarity] = polarity == .both ? [.positive, .negative] : [polarity]
        return categories.flatMap { category in
            selection.measures.flatMap { measure in
                polarities.map { columnPolarity in
                    WaveformExportColumn(
                        title: exportColumnName(category: category, measure: measure,
                                                polarity: columnPolarity,
                                                includesPolaritySuffix: polarity == .both),
                        category: category,
                        measure: measure,
                        polarity: columnPolarity
                    )
                }
            }
        }
    }

    nonisolated static func exportColumnNames(categories: [WaveformCategory], measures: [WaveformAmplitudeMeasure]) -> [String] {
        categories.flatMap { category in
            measures.map { measure in "\(category.name)_\(measure.exportSuffix)" }
        }
    }

    nonisolated static func formatExportValue(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6g", value) : ""
    }

    static func timeRange(sampleCount: Int, samplingRate: Double, baselineSamples: Int) -> ClosedRange<Double> {
        guard sampleCount > 1, samplingRate > 0 else { return 0...1 }
        let start = Double(0 - baselineSamples) / samplingRate * 1000
        let end = Double(sampleCount - 1 - baselineSamples) / samplingRate * 1000
        return start...end
    }

    nonisolated private static func collapsedTrace(_ samples: [[Float]]) -> [Double] {
        guard let first = samples.first, !first.isEmpty else { return [] }
        var output = Array(repeating: 0.0, count: first.count)
        var usedChannels = 0
        for channel in samples where channel.count == first.count {
            for i in channel.indices {
                output[i] += Double(channel[i])
            }
            usedChannels += 1
        }
        guard usedChannels > 0 else { return [] }
        let inv = 1.0 / Double(usedChannels)
        return output.map { $0 * inv }
    }

    private static func centroid(_ samples: [[Float]]) -> [Float] {
        guard let first = samples.first, !first.isEmpty else { return [] }
        var output = Array(repeating: Float(0), count: first.count)
        var usedChannels = 0
        for channel in samples where channel.count == first.count {
            for i in channel.indices {
                output[i] += channel[i]
            }
            usedChannels += 1
        }
        guard usedChannels > 0 else { return [] }
        return output.map { $0 / Float(usedChannels) }
    }

    nonisolated private static func sampleIndices(for window: ClosedRange<Double>, samplingRate: Double,
                                                  baselineSamples: Int, sampleCount: Int) -> [Int] {
        guard sampleCount > 0 else { return [] }
        let start = Int((window.lowerBound / 1000 * samplingRate).rounded()) + baselineSamples
        let end = Int((window.upperBound / 1000 * samplingRate).rounded()) + baselineSamples
        let lower = max(0, min(start, end))
        let upper = min(sampleCount - 1, max(start, end))
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    nonisolated private static func peak(in values: [Double], indices: [Int], polarity: WaveformPolarity) -> Double? {
        guard let index = peakIndex(in: values, indices: indices, polarity: polarity) else { return nil }
        return values[index]
    }

    nonisolated private static func peakIndex(in values: [Double], indices: [Int], polarity: WaveformPolarity) -> Int? {
        switch polarity {
        case .positive:
            return indices.max { values[$0] < values[$1] }
        case .negative:
            return indices.min { values[$0] < values[$1] }
        case .both:
            return indices.max { abs(values[$0]) < abs(values[$1]) }
        }
    }

    nonisolated private static func mean(in values: [Double], indices: [Int]) -> Double? {
        guard !indices.isEmpty else { return nil }
        return indices.reduce(0.0) { $0 + values[$1] } / Double(indices.count)
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    nonisolated private static func exportColumnName(category: WaveformCategory, measure: WaveformAmplitudeMeasure,
                                                     polarity: WaveformPolarity,
                                                     includesPolaritySuffix: Bool) -> String {
        let base = "\(category.name)_\(measure.exportSuffix)"
        guard includesPolaritySuffix else { return base }
        switch polarity {
        case .positive:
            return "\(base)_pos"
        case .negative:
            return "\(base)_neg"
        case .both:
            return base
        }
    }
}
