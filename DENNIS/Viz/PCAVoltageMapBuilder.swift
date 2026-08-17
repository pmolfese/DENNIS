//
//  PCAVoltageMapBuilder.swift
//  DENNIS
//
//  Shared cell resolution and observed-voltage topomap summaries for the
//  Cluster ERP view/export. The voltage map is computed from the same displayed
//  subject/condition cells as the ERP traces, while the PCA temporal loading is
//  used only to define the active window and (for peak mode) its representative
//  latency.
//

import Foundation

nonisolated enum PCAVoltageSummary: String, CaseIterable, Identifiable, Sendable {
    case peakInWindow = "Peak"
    case meanOverWindow = "Mean"

    var id: Self { self }
}

nonisolated enum ClusterERPCellBuilder {
    struct Input: Sendable {
        let groupBy: Set<String>
        let conditionDimension: String
        let factorNames: [String]
        let subjects: [ClusterSubject]
        let conditionNames: [String]
    }

    struct Cell: Sendable {
        let label: String
        let subjects: [ClusterSubject]
        let conditions: [String]
    }

    static func build(_ input: Input) -> [Cell] {
        let orderedBetween = input.factorNames.filter { input.groupBy.contains($0) }
        let useCondition = input.groupBy.contains(input.conditionDimension)

        var keys: [String] = []
        var byKey: [String: [ClusterSubject]] = [:]
        for subject in input.subjects {
            let key = orderedBetween.map {
                level(of: subject, factorName: $0, factorNames: input.factorNames)
            }.joined(separator: "·")
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(subject)
        }

        var result: [Cell] = []
        for key in keys {
            let subjects = byKey[key] ?? []
            if useCondition {
                for condition in input.conditionNames {
                    let label = key.isEmpty ? condition : "\(key)·\(condition)"
                    result.append(Cell(label: label, subjects: subjects, conditions: [condition]))
                }
            } else {
                result.append(Cell(
                    label: key.isEmpty ? "Overall" : key,
                    subjects: subjects,
                    conditions: input.conditionNames
                ))
            }
        }
        return result
    }

    private static func level(of subject: ClusterSubject, factorName: String,
                              factorNames: [String]) -> String {
        guard let index = factorNames.firstIndex(of: factorName),
              index < subject.levels.count else { return "?" }
        let value = subject.levels[index]
        return value.isEmpty ? "Unassigned" : value
    }
}

nonisolated enum PCAVoltageMapBuilder {
    struct Input: Sendable {
        let cells: [ClusterERPCellBuilder.Cell]
        /// Nil means all cells; an empty set means no cells are visible.
        let visibleCellLabels: Set<String>?
        let temporalLoading: [Double]
        let timesMS: [Double]
        let temporalThreshold: Double
        let summary: PCAVoltageSummary
        let samplingRate: Double
        let baselineSamples: Int
    }

    struct WindowSelection: Sendable, Equatable {
        let indices: ClosedRange<Int>
        let peakIndex: Int
        let lowerMS: Double
        let upperMS: Double
        let peakMS: Double
    }

    struct Result: Sendable {
        let values: [Double]
        let window: WindowSelection
        let summary: PCAVoltageSummary
        let cellLabels: [String]
        /// Each subject contributes once per displayed cell. When Condition is a
        /// displayed dimension, the same subject can therefore contribute once
        /// to each visible condition, matching the trace-cell construction.
        let contributingSubjectCells: Int

        var summaryLabel: String {
            switch summary {
            case .peakInWindow:
                return "Peak · \(PCAVoltageMapBuilder.formatMS(window.peakMS)) ms"
            case .meanOverWindow:
                return "Mean · \(PCAVoltageMapBuilder.formatMS(window.lowerMS))–"
                    + "\(PCAVoltageMapBuilder.formatMS(window.upperMS)) ms"
            }
        }

        var aggregationLabel: String {
            let cells = cellLabels.count == 1 ? cellLabels[0] : "\(cellLabels.count) visible cells"
            return "\(cells) · n=\(contributingSubjectCells)"
        }
    }

    static func build(_ input: Input) -> Result? {
        guard let window = selectWindow(
            temporalLoading: input.temporalLoading,
            timesMS: input.timesMS,
            threshold: input.temporalThreshold
        ) else { return nil }

        let selectedCells = input.cells.filter { cell in
            input.visibleCellLabels?.contains(cell.label) ?? true
        }
        guard !selectedCells.isEmpty else { return nil }

        let rawWindow = rawWindow(
            for: window,
            samplingRate: input.samplingRate,
            baselineSamples: input.baselineSamples
        )

        let nChannels = selectedCells.lazy
            .flatMap(\.subjects)
            .flatMap { $0.byCondition.values }
            .map(\.count)
            .max() ?? 0
        guard nChannels > 0 else { return nil }

        var channelSums = [Double](repeating: 0, count: nChannels)
        var channelCounts = [Int](repeating: 0, count: nChannels)
        var contributingSubjectCells = 0
        var contributingCellLabels: [String] = []

        for cell in selectedCells {
            let countBeforeCell = contributingSubjectCells
            for subject in cell.subjects {
                var conditionSums = [Double](repeating: 0, count: nChannels)
                var conditionCounts = [Int](repeating: 0, count: nChannels)

                for condition in cell.conditions {
                    guard let samples = subject.byCondition[condition] else { continue }
                    for channel in 0..<min(samples.count, nChannels) {
                        guard let value = summarizedValue(
                            samples[channel], summary: input.summary, rawWindow: rawWindow
                        ) else { continue }
                        conditionSums[channel] += value
                        conditionCounts[channel] += 1
                    }
                }

                var contributed = false
                for channel in 0..<nChannels where conditionCounts[channel] > 0 {
                    channelSums[channel] += conditionSums[channel] / Double(conditionCounts[channel])
                    channelCounts[channel] += 1
                    contributed = true
                }
                if contributed { contributingSubjectCells += 1 }
            }
            if contributingSubjectCells > countBeforeCell {
                contributingCellLabels.append(cell.label)
            }
        }

        guard contributingSubjectCells > 0 else { return nil }
        let values = (0..<nChannels).map { channel in
            channelCounts[channel] > 0
                ? channelSums[channel] / Double(channelCounts[channel])
                : 0
        }
        return Result(
            values: values,
            window: window,
            summary: input.summary,
            cellLabels: contributingCellLabels,
            contributingSubjectCells: contributingSubjectCells
        )
    }

    /// Select the threshold-defined contiguous window containing the temporal
    /// loading's global absolute peak. This makes disjoint threshold crossings
    /// deterministic and gives both summary modes the exact same window.
    static func selectWindow(temporalLoading: [Double], timesMS: [Double],
                             threshold: Double) -> WindowSelection? {
        guard !temporalLoading.isEmpty else { return nil }
        let threshold = max(0, threshold)
        let finite = temporalLoading.indices.filter { temporalLoading[$0].isFinite }
        guard let first = finite.first else { return nil }

        var peakIndex = first
        for index in finite.dropFirst()
        where abs(temporalLoading[index]) > abs(temporalLoading[peakIndex]) {
            peakIndex = index
        }
        guard abs(temporalLoading[peakIndex]) >= threshold else { return nil }

        var windows: [ClosedRange<Int>] = []
        var start: Int?
        for index in temporalLoading.indices {
            let value = temporalLoading[index]
            let isActive = value.isFinite && abs(value) >= threshold
            if isActive, start == nil { start = index }
            if !isActive, let lower = start {
                windows.append(lower...(index - 1))
                start = nil
            }
        }
        if let lower = start { windows.append(lower...(temporalLoading.count - 1)) }
        guard let selected = windows.first(where: { $0.contains(peakIndex) }) else { return nil }

        return WindowSelection(
            indices: selected,
            peakIndex: peakIndex,
            lowerMS: ms(at: selected.lowerBound, timesMS: timesMS),
            upperMS: ms(at: selected.upperBound, timesMS: timesMS),
            peakMS: ms(at: peakIndex, timesMS: timesMS)
        )
    }

    private struct RawWindow {
        let indices: ClosedRange<Int>
        let peakIndex: Int
    }

    private static func summarizedValue(_ samples: [Float], summary: PCAVoltageSummary,
                                        rawWindow: RawWindow) -> Double? {
        switch summary {
        case .peakInWindow:
            guard samples.indices.contains(rawWindow.peakIndex) else { return nil }
            let value = Double(samples[rawWindow.peakIndex])
            return value.isFinite ? value : nil

        case .meanOverWindow:
            var sum = 0.0
            var count = 0
            for index in rawWindow.indices where samples.indices.contains(index) {
                let value = Double(samples[index])
                guard value.isFinite else { continue }
                sum += value
                count += 1
            }
            return count > 0 ? sum / Double(count) : nil
        }
    }

    private static func rawWindow(for window: WindowSelection, samplingRate: Double,
                                  baselineSamples: Int) -> RawWindow {
        let lower = rawSampleIndex(
            ms: window.lowerMS, samplingRate: samplingRate, baselineSamples: baselineSamples
        )
        let upper = rawSampleIndex(
            ms: window.upperMS, samplingRate: samplingRate, baselineSamples: baselineSamples
        )
        return RawWindow(
            indices: min(lower, upper)...max(lower, upper),
            peakIndex: rawSampleIndex(
                ms: window.peakMS, samplingRate: samplingRate, baselineSamples: baselineSamples
            )
        )
    }

    private static func rawSampleIndex(ms: Double, samplingRate: Double,
                                       baselineSamples: Int) -> Int {
        guard ms.isFinite else { return baselineSamples }
        guard samplingRate > 0 else { return Int(ms.rounded()) }
        return baselineSamples + Int((ms / 1_000 * samplingRate).rounded())
    }

    private static func ms(at index: Int, timesMS: [Double]) -> Double {
        timesMS.indices.contains(index) ? timesMS[index] : Double(index)
    }

    private static func formatMS(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}
