//
//  CPExplorerView.swift
//  DENNIS
//
//  Mode-aware component explorer for a PARAFAC (CP) decomposition. Each mode is
//  rendered by its type — channels as a scalp topography, time/frequency as a
//  line, condition as bars, subject as bars grouped by the between-subject design
//  — so it serves the ERP 4-way tensor and every time-frequency structure alike.
//

import SwiftUI
import Charts

struct CPExplorerView: View {
    let result: CPResult
    let modeTypes: [TFModeType]
    let layout: SensorLayout?
    let timesMS: [Double]
    let freqs: [Double]
    let conditionNames: [String]
    /// Between-subject factor levels per subject, aligned with the subject mode.
    let subjectLevels: [[String]]
    let factorNames: [String]
    var coreConsistency: Double? = nil

    @State private var groupBy = "Subject"

    private var channelMode: Int? { modeTypes.firstIndex(of: .channel) }
    private var subjectMode: Int? { modeTypes.firstIndex(of: .subject) }
    private var middleModes: [Int] {
        modeTypes.indices.filter { modeTypes[$0] != .channel && modeTypes[$0] != .subject }
    }
    private var groupingOptions: [String] { ["Subject"] + factorNames }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "Fit %.1f%% · %d iterations · %d/%d starts at best · max congruence %.2f",
                        result.fit * 100, result.iterations, result.bestStartCount, result.nStarts,
                        result.maxCongruence)
                 + (coreConsistency.map { String(format: " · core consistency %.0f%%", $0) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if result.maxCongruence > 0.85 {
                Label("Components are nearly collinear — the solution may be degenerate. Try fewer components.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if subjectMode != nil && !factorNames.isEmpty {
                Picker("Group subjects by", selection: $groupBy) {
                    ForEach(groupingOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
            }
            ForEach(0..<result.rank, id: \.self) { card($0) }
        }
    }

    private func card(_ r: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Component \(r + 1)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f%% · λ=%.3g", result.componentShare[r] * 100, result.weights[r]))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                if let cm = channelMode { topography(mode: cm, r).frame(width: 190) }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(middleModes, id: \.self) { modeChart(mode: $0, r) }
                }
                .frame(maxWidth: .infinity)
            }
            if let sm = subjectMode { subjectLoadings(mode: sm, r) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func topography(mode: Int, _ r: Int) -> some View {
        VStack(spacing: 4) {
            Text("Topography").font(.caption2).foregroundStyle(.secondary)
            if let layout {
                TopomapView(layout: layout, values: result.factors[mode].column(r),
                            timeSeconds: 0, fixedScale: nil, showsHeader: false, canvasMinHeight: 150)
                    .frame(height: 175)
            } else {
                ContentUnavailableView("No layout", systemImage: "circle.dashed").font(.caption)
            }
        }
    }

    private struct AxisPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }
    private struct NamedLoad: Identifiable { let id = UUID(); let name: String; let value: Double }

    @ViewBuilder
    private func modeChart(mode: Int, _ r: Int) -> some View {
        let column = result.factors[mode].column(r)
        switch modeTypes[mode] {
        case .time:
            lineChart(column, axis: timesMS, title: "Time course", xLabel: "Time (ms)")
        case .frequency:
            lineChart(column, axis: freqs, title: "Spectrum", xLabel: "Frequency (Hz)")
        case .condition:
            VStack(alignment: .leading, spacing: 2) {
                Text("Condition loadings").font(.caption2).foregroundStyle(.secondary)
                Chart(column.enumerated().map {
                    NamedLoad(name: $0.offset < conditionNames.count ? conditionNames[$0.offset] : "c\($0.offset)",
                              value: $0.element)
                }) { item in
                    BarMark(x: .value("Condition", item.name), y: .value("Loading", item.value))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 90)
            }
        case .channel, .subject:
            EmptyView()
        }
    }

    private func lineChart(_ values: [Double], axis: [Double], title: String, xLabel: String) -> some View {
        let pts = values.enumerated().map {
            AxisPoint(x: $0.offset < axis.count ? axis[$0.offset] : Double($0.offset), y: $0.element)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Chart(pts) { p in
                LineMark(x: .value(xLabel, p.x), y: .value("Loading", p.y))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxisLabel(xLabel)
            .frame(height: 120)
        }
    }

    // MARK: - Subject loadings (per subject, or grouped by design with mean ± SE)

    private struct SubjectLoad: Identifiable { let id = UUID(); let index: Int; let value: Double }
    private struct GroupStat: Identifiable {
        let id = UUID(); let level: String; let mean: Double; let se: Double; let n: Int
    }

    @ViewBuilder
    private func subjectLoadings(mode: Int, _ r: Int) -> some View {
        let column = result.factors[mode].column(r)
        VStack(alignment: .leading, spacing: 2) {
            Text(groupBy == "Subject" ? "Subject loadings" : "Subject loadings by \(groupBy)")
                .font(.caption2).foregroundStyle(.secondary)
            if groupBy == "Subject" {
                Chart(column.enumerated().map { SubjectLoad(index: $0.offset + 1, value: $0.element) }) { item in
                    BarMark(x: .value("Subject", item.index), y: .value("Loading", item.value))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                }
                .chartXAxisLabel("Subject")
                .frame(height: 80)
            } else {
                Chart(groupStats(column, factor: groupBy)) { stat in
                    BarMark(x: .value("Group", stat.level), y: .value("Mean loading", stat.mean))
                        .foregroundStyle(Color.accentColor)
                    RuleMark(x: .value("Group", stat.level),
                             yStart: .value("lo", stat.mean - stat.se),
                             yEnd: .value("hi", stat.mean + stat.se))
                        .foregroundStyle(.primary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .frame(height: 110)
            }
        }
    }

    private func groupStats(_ column: [Double], factor: String) -> [GroupStat] {
        guard let factorIndex = factorNames.firstIndex(of: factor) else { return [] }
        var order: [String] = []
        var buckets: [String: [Double]] = [:]
        for (i, value) in column.enumerated() {
            let level = (i < subjectLevels.count && factorIndex < subjectLevels[i].count
                         && !subjectLevels[i][factorIndex].isEmpty) ? subjectLevels[i][factorIndex] : "Unassigned"
            if buckets[level] == nil { order.append(level) }
            buckets[level, default: []].append(value)
        }
        return order.map { level in
            let values = buckets[level] ?? []
            let n = values.count
            let mean = values.reduce(0, +) / Double(max(n, 1))
            let se: Double = n > 1
                ? (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)).squareRoot() / Double(n).squareRoot()
                : 0
            return GroupStat(level: level, mean: mean, se: se, n: n)
        }
    }
}
