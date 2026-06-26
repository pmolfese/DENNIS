//
//  ClusterERPView.swift
//  DENNIS
//
//  Shown when a TF×SF factor topography is clicked. Splits that factor's
//  spatial loading into a positive cluster (loading ≥ +threshold) and a negative
//  cluster (loading ≤ −threshold), then plots the grand-average ERP averaged
//  across each cluster's channels.
//
//  Traces can be grouped by any combination of dimensions chosen in the
//  "Group by" selector: the within-subject Condition and/or the between-subject
//  design factors (e.g. Twin Type, Age). Selecting Twin Type alone contrasts
//  MZ vs DZ averaged over conditions; selecting Age × Twin Type plots each cell
//  of the interaction. An optional checkbox shades the active temporal-factor
//  window.
//

import SwiftUI

/// One subject's per-condition ERP plus its between-subject factor levels.
nonisolated struct ClusterSubject: Identifiable, Sendable {
    let name: String
    /// Between-subject factor levels, index-aligned with the study's factors.
    let levels: [String]
    /// condition name → channels × samples (references existing arrays; cheap).
    let byCondition: [String: [[Float]]]
    var id: String { name }
}

struct ClusterERPView: View {
    let factor: TwoStepFactor
    let spatialLoading: [Double]          // per channel
    let temporalLoading: [Double]
    let timesMS: [Double]
    let subjects: [ClusterSubject]
    let conditionNames: [String]
    /// Between-subject factor names (study order).
    let factorNames: [String]
    let baselineSamples: Int
    let samplingRate: Double
    var sensorLayout: SensorLayout? = nil

    @Environment(AnalysisStore.self) private var store

    /// Reserved dimension name for the within-subject condition split.
    private static let conditionDimension = "Condition"

    @State private var cursorSample = 0
    @State private var posTraces: [OverlayTrace] = []
    @State private var negTraces: [OverlayTrace] = []
    @State private var cellOrder: [String] = []
    @State private var hidePNGReadout = false
    @State private var tracesRebuilding = false
    @State private var rebuildGeneration = 0
    @State private var rebuildTask: Task<Void, Never>?

    /// Grouping + visibility live in the store so they persist across the
    /// view rebuilds that happen when a different factor topography is clicked.
    private var groupBy: Set<String> { store.clusterGroupBy }
    private func isVisible(_ label: String) -> Bool {
        store.clusterVisibleCells.map { $0.contains(label) } ?? true
    }

    private var threshold: Double { store.spatialThreshold }
    private var positiveChannels: [Int] { spatialLoading.indices.filter { spatialLoading[$0] >= threshold } }
    private var negativeChannels: [Int] { spatialLoading.indices.filter { spatialLoading[$0] <= -threshold } }

    /// Dimensions offered in the selector: Condition + every between factor.
    private var dimensions: [String] { [Self.conditionDimension] + factorNames }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            groupBySelector
            cellChips
            clusterPlot(title: "Positive cluster", channels: positiveChannels,
                        sign: "+", traces: posTraces)
            clusterPlot(title: "Negative cluster", channels: negativeChannels,
                        sign: "−", traces: negTraces)
        }
        // Keep visibility on appear (sticky across factor clicks); only a
        // grouping change resets which cells are shown.
        .onAppear { rebuild(resetVisibility: false) }
        .onChange(of: store.clusterGroupBy) { _, _ in rebuild(resetVisibility: true) }
        .onChange(of: store.spatialThreshold) { _, _ in rebuild(resetVisibility: false) }
        .onDisappear {
            rebuildTask?.cancel()
            rebuildTask = nil
        }
    }

    // MARK: - Controls

    private var header: some View {
        HStack(spacing: 14) {
            Text("Cluster ERP · \(factor.name)").font(.subheadline.weight(.semibold))
            Spacer()
            Toggle("± Std. error", isOn: Binding(
                get: { store.showStandardError },
                set: { store.showStandardError = $0 }
            ))
            .toggleStyle(.checkbox).font(.caption)
            Toggle("Highlight temporal window", isOn: Binding(
                get: { store.highlightTemporalWindow },
                set: { store.highlightTemporalWindow = $0 }
            ))
            .toggleStyle(.checkbox).font(.caption)
            if store.highlightTemporalWindow {
                Text("|TF| ≥").font(.caption).foregroundStyle(.secondary)
                TextField("0.40", value: Binding(
                    get: { store.temporalThreshold },
                    set: { store.temporalThreshold = max(0, $0) }
                ), format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
            }
            if let sensorLayout {
                Toggle("Hide PNG readout", isOn: $hidePNGReadout)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    savePNG(layout: sensorLayout)
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var groupBySelector: some View {
        HStack(spacing: 8) {
            Text("Group by:").font(.caption).foregroundStyle(.secondary)
            ForEach(dimensions, id: \.self) { dim in
                let on = groupBy.contains(dim)
                Button {
                    var set = store.clusterGroupBy
                    if on { set.remove(dim) } else { set.insert(dim) }
                    store.clusterGroupBy = set
                } label: {
                    Text(dim).font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.18)
                                                       : Color.secondary.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if groupBy.isEmpty {
                Text("(overall average)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var cellChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(cellOrder.enumerated()), id: \.element) { index, label in
                    let color = OverlayWaveformView.palette[index % OverlayWaveformView.palette.count]
                    let on = isVisible(label)
                    Button {
                        var set = store.clusterVisibleCells ?? Set(cellOrder)
                        if on { set.remove(label) } else { set.insert(label) }
                        store.clusterVisibleCells = set
                    } label: {
                        HStack(spacing: 5) {
                            Capsule().fill(on ? color : Color.secondary.opacity(0.4)).frame(width: 14, height: 3)
                            Text(label).font(.caption)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(on ? color.opacity(0.12) : Color.secondary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func clusterPlot(title: String, channels: [Int], sign: String,
                             traces: [OverlayTrace]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(channels.count) ch \(sign)\(String(format: "%.2f", threshold))")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if channels.isEmpty {
                Text("No channels in this cluster at the current threshold.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if tracesRebuilding {
                ProgressView()
                    .controlSize(.small)
                    .frame(minHeight: 200, alignment: .center)
            } else {
                let visible = traces.filter { isVisible($0.id) }
                if visible.isEmpty {
                    Text("Select at least one group above.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    OverlayWaveformView(
                        traces: visible, samplingRate: samplingRate, baselineSamples: baselineSamples,
                        showsCentroid: true, cursorSample: $cursorSample,
                        showsStandardError: store.showStandardError, shadedMSRanges: shadedRanges
                    )
                    .frame(minHeight: 200)
                }
            }
        }
    }

    // MARK: - Temporal window shading

    private var shadedRanges: [ClosedRange<Double>] {
        guard store.highlightTemporalWindow else { return [] }
        let th = store.temporalThreshold
        var ranges: [ClosedRange<Double>] = []
        var start: Int?
        for i in temporalLoading.indices {
            let above = abs(temporalLoading[i]) >= th
            if above, start == nil { start = i }
            if !above, let s = start { ranges.append(msAt(s)...msAt(i - 1)); start = nil }
        }
        if let s = start { ranges.append(msAt(s)...msAt(temporalLoading.count - 1)) }
        return ranges
    }

    private func msAt(_ i: Int) -> Double { i < timesMS.count ? timesMS[i] : Double(i) }

    // MARK: - Cell construction

    private func rebuild(resetVisibility: Bool) {
        let generation = rebuildGeneration + 1
        rebuildGeneration = generation
        tracesRebuilding = true
        if resetVisibility {
            store.clusterVisibleCells = nil   // nil = all cells shown
        }

        let input = ClusterERPTraceBuilder.Input(
            groupBy: groupBy,
            conditionDimension: Self.conditionDimension,
            factorNames: factorNames,
            subjects: subjects,
            conditionNames: conditionNames,
            positiveChannels: positiveChannels,
            negativeChannels: negativeChannels
        )

        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .userInitiated) {
            let result = ClusterERPTraceBuilder.build(input)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == rebuildGeneration else { return }
                cellOrder = result.cellOrder
                posTraces = result.positive.map(overlayTrace)
                negTraces = result.negative.map(overlayTrace)
                tracesRebuilding = false
            }
        }
    }

    private func overlayTrace(_ trace: ClusterERPTraceBuilder.TraceData) -> OverlayTrace {
        OverlayTrace(
            id: trace.label,
            label: trace.label,
            color: OverlayWaveformView.palette[trace.colorIndex % OverlayWaveformView.palette.count],
            samples: [],
            centroid: trace.mean,
            contributing: trace.n,
            sensorLayout: nil,
            centroidSE: trace.se
        )
    }

    private func savePNG(layout: SensorLayout) {
        let visiblePos = posTraces.filter { isVisible($0.id) }
        let visibleNeg = negTraces.filter { isVisible($0.id) }
        ImageExport.savePNG(
            ClusterERPExportView(
                factor: factor,
                layout: layout,
                spatialLoading: spatialLoading,
                threshold: threshold,
                positiveChannels: positiveChannels,
                negativeChannels: negativeChannels,
                positiveTraces: visiblePos,
                negativeTraces: visibleNeg,
                samplingRate: samplingRate,
                baselineSamples: baselineSamples,
                showsStandardError: store.showStandardError,
                shadedRanges: shadedRanges,
                showsCursorReadout: !hidePNGReadout
            ),
            suggestedName: "cluster_erp_\(safe(factor.name))"
        )
    }

    private func safe(_ text: String) -> String {
        text
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}

private nonisolated enum ClusterERPTraceBuilder {
    struct Input: Sendable {
        let groupBy: Set<String>
        let conditionDimension: String
        let factorNames: [String]
        let subjects: [ClusterSubject]
        let conditionNames: [String]
        let positiveChannels: [Int]
        let negativeChannels: [Int]
    }

    struct TraceData: Sendable {
        let label: String
        let colorIndex: Int
        let mean: [Float]
        let se: [Float]
        let n: Int
    }

    struct Result: Sendable {
        let cellOrder: [String]
        let positive: [TraceData]
        let negative: [TraceData]
    }

    private struct Cell: Sendable {
        let label: String
        let subjects: [ClusterSubject]
        let conditions: [String]
    }

    static func build(_ input: Input) -> Result {
        let built = cells(input)
        return Result(
            cellOrder: built.map(\.label),
            positive: built.enumerated().compactMap {
                makeTrace($0.element, index: $0.offset, channels: input.positiveChannels)
            },
            negative: built.enumerated().compactMap {
                makeTrace($0.element, index: $0.offset, channels: input.negativeChannels)
            }
        )
    }

    /// Build the trace cells from the current "Group by" selection.
    private static func cells(_ input: Input) -> [Cell] {
        let orderedBetween = input.factorNames.filter { input.groupBy.contains($0) }
        let useCondition = input.groupBy.contains(input.conditionDimension)

        var keys: [String] = []
        var byKey: [String: [ClusterSubject]] = [:]
        for subject in input.subjects {
            let key = orderedBetween.map { levelOf(subject, $0, factorNames: input.factorNames) }
                .joined(separator: "·")
            if byKey[key] == nil { keys.append(key) }
            byKey[key, default: []].append(subject)
        }

        var result: [Cell] = []
        for key in keys {
            let subs = byKey[key] ?? []
            if useCondition {
                for condition in input.conditionNames {
                    let label = key.isEmpty ? condition : "\(key)·\(condition)"
                    result.append(Cell(label: label, subjects: subs, conditions: [condition]))
                }
            } else {
                result.append(Cell(label: key.isEmpty ? "Overall" : key,
                                   subjects: subs, conditions: input.conditionNames))
            }
        }
        return result
    }

    private static func levelOf(_ subject: ClusterSubject, _ factorName: String,
                                factorNames: [String]) -> String {
        guard let idx = factorNames.firstIndex(of: factorName), idx < subject.levels.count else { return "?" }
        let value = subject.levels[idx]
        return value.isEmpty ? "Unassigned" : value
    }

    private static func makeTrace(_ cell: Cell, index: Int, channels: [Int]) -> TraceData? {
        guard let stats = cellStats(cell: cell, channels: channels) else { return nil }
        return TraceData(label: cell.label, colorIndex: index, mean: stats.mean, se: stats.se, n: stats.n)
    }

    /// Mean and +/-1 standard-error (across subjects) of the cluster-mean waveform.
    /// Each subject contributes one waveform (averaged over the cell's conditions),
    /// so the SE reflects between-subject variability.
    private static func cellStats(cell: Cell, channels: [Int]) -> (mean: [Float], se: [Float], n: Int)? {
        var subjectWaves: [[Float]] = []
        for subject in cell.subjects {
            var sum: [Float] = []
            var k = 0
            for condition in cell.conditions {
                guard let samples = subject.byCondition[condition] else { continue }
                let mean = clusterMean(samples, channels: channels)
                guard !mean.isEmpty else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: mean.count) }
                guard sum.count == mean.count else { continue }
                for i in 0..<mean.count { sum[i] += mean[i] }
                k += 1
            }
            if k > 0 { subjectWaves.append(sum.map { $0 / Float(k) }) }
        }
        guard let t = subjectWaves.first?.count else { return nil }
        let waves = subjectWaves.filter { $0.count == t }
        let n = waves.count
        guard n > 0 else { return nil }

        var mean = [Float](repeating: 0, count: t)
        for wave in waves { for i in 0..<t { mean[i] += wave[i] } }
        for i in 0..<t { mean[i] /= Float(n) }

        var se = [Float](repeating: 0, count: t)
        if n > 1 {
            for i in 0..<t {
                var ss = 0.0
                for wave in waves {
                    let d = Double(wave[i] - mean[i])
                    ss += d * d
                }
                se[i] = Float((ss / Double(n - 1)).squareRoot() / Double(n).squareRoot())
            }
        }
        return (mean, se, n)
    }

    /// Mean across the given channel indices at each time point.
    private static func clusterMean(_ samples: [[Float]], channels: [Int]) -> [Float] {
        let valid = channels.filter { $0 < samples.count }
        guard let first = valid.first else { return [] }
        let n = samples[first].count
        var out = [Float](repeating: 0, count: n)
        for ch in valid {
            let trace = samples[ch]
            guard trace.count == n else { continue }
            for i in 0..<n { out[i] += trace[i] }
        }
        let inv = Float(1) / Float(valid.count)
        return out.map { $0 * inv }
    }
}

private struct ClusterERPExportView: View {
    let factor: TwoStepFactor
    let layout: SensorLayout
    let spatialLoading: [Double]
    let threshold: Double
    let positiveChannels: [Int]
    let negativeChannels: [Int]
    let positiveTraces: [OverlayTrace]
    let negativeTraces: [OverlayTrace]
    let samplingRate: Double
    let baselineSamples: Int
    let showsStandardError: Bool
    let shadedRanges: [ClosedRange<Double>]
    let showsCursorReadout: Bool
    private let legendColumns = [GridItem(.adaptive(minimum: 150, maximum: 230), alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cluster ERP · \(factor.name)")
                        .font(.headline)
                    Text(String(format: "Spatial threshold |loading| ≥ %.2f", threshold))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.1f%% variance", factor.variance * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spatial factor topomap")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TopomapView(
                        layout: layout,
                        values: spatialLoading,
                        timeSeconds: 0,
                        fixedScale: nil,
                        showsHeader: false,
                        usesVerticalColorBar: true,
                        canvasMinHeight: 260,
                        highlightThreshold: threshold > 0 ? threshold : nil
                    )
                    .frame(width: 330, height: 330)
                }

                VStack(alignment: .leading, spacing: 12) {
                    exportClusterPlot(title: "Positive cluster", channels: positiveChannels,
                                      sign: "+", traces: positiveTraces)
                    exportClusterPlot(title: "Negative cluster", channels: negativeChannels,
                                      sign: "-", traces: negativeTraces)
                }
                .frame(width: 700)
            }
        }
        .frame(width: 1080, alignment: .leading)
    }

    @ViewBuilder
    private func exportClusterPlot(title: String, channels: [Int], sign: String,
                                   traces: [OverlayTrace]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(channels.count) ch \(sign)\(String(format: "%.2f", threshold))")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if channels.isEmpty {
                Text("No channels in this cluster at the current threshold.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 210, alignment: .center)
            } else if traces.isEmpty {
                Text("No visible groups selected.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: 210, alignment: .center)
            } else {
                exportLegend(traces)
                OverlayWaveformView(
                    traces: traces,
                    samplingRate: samplingRate,
                    baselineSamples: baselineSamples,
                    showsCentroid: true,
                    cursorSample: .constant(baselineSamples),
                    showsStandardError: showsStandardError,
                    shadedMSRanges: shadedRanges,
                    showsCursorReadout: showsCursorReadout,
                    showsLegend: false
                )
                .frame(height: 190)
            }
        }
    }

    private func exportLegend(_ traces: [OverlayTrace]) -> some View {
        LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 6) {
            ForEach(traces) { trace in
                HStack(spacing: 6) {
                    Capsule().fill(trace.color).frame(width: 18, height: 4)
                    Text(trace.label)
                        .font(.caption)
                        .lineLimit(1)
                    Text("n=\(trace.contributing)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
