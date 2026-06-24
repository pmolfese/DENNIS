//
//  DualPCAView.swift
//  DENNIS
//
//  Summary view for a two-step (dual) PCA: the first-step temporal factor
//  loadings, the per-temporal-factor spatial topographies (with an electrode
//  threshold), and a table of combined factors ranked by variance.
//

import SwiftUI

struct DualPCAView: View {
    let result: TwoStepPCAResult
    var sensorLayout: SensorLayout?
    /// Per-subject ERP + design levels for the group, used for cluster ERPs when
    /// a factor topography is clicked.
    var clusterSubjects: [ClusterSubject] = []
    var clusterConditionNames: [String] = []
    var clusterFactorNames: [String] = []
    var clusterBaseline: Int = 0
    var clusterSamplingRate: Double = 0

    @Environment(AnalysisStore.self) private var store
    @State private var selectedFactorID: String?

    private var threshold: Double { store.spatialThreshold }

    private var selectedFactor: TwoStepFactor? {
        result.factors.first { $0.name == selectedFactorID }
    }

    private func spatialLoading(_ factor: TwoStepFactor) -> [Double] {
        guard result.second.indices.contains(factor.firstIndex) else { return [] }
        let step = result.second[factor.firstIndex]
        guard factor.secondIndex < step.pattern.cols else { return [] }
        return step.pattern.column(factor.secondIndex)
    }

    private func temporalLoading(_ factor: TwoStepFactor) -> [Double] {
        guard factor.firstIndex < result.first.pattern.cols else { return [] }
        return result.first.pattern.column(factor.firstIndex)
    }

    /// Largest absolute spatial loading across all factors.
    private var maxAbsLoading: Double {
        result.second.flatMap { $0.pattern.grid }.map(abs).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let layout = sensorLayout {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Spatial factor topographies").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            ImageExport.savePNG(
                                TopomapGridView(result: result, layout: layout, threshold: threshold),
                                suggestedName: "tfsf_topomaps")
                        } label: { Label("Save PNG", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    HStack(spacing: 10) {
                        Text("Threshold (loading):").font(.caption).foregroundStyle(.secondary)
                        TextField("0.40", value: Binding(
                            get: { store.spatialThreshold },
                            set: { store.spatialThreshold = max(0, $0) }
                        ), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: Binding(
                            get: { store.spatialThreshold },
                            set: { store.spatialThreshold = max(0, $0) }
                        ), in: 0...max(maxAbsLoading, 1), step: 0.05)
                            .labelsHidden()
                        Text("max |loading| " + String(format: "%.2f", maxAbsLoading))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Text("Click a factor topography to plot its cluster ERP.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    TopomapGridView(
                        result: result, layout: layout, threshold: threshold,
                        selectedID: selectedFactorID,
                        onSelect: { factor in
                            selectedFactorID = (selectedFactorID == factor.name) ? nil : factor.name
                        }
                    )

                    if let factor = selectedFactor, !clusterSubjects.isEmpty {
                        Divider()
                        ClusterERPView(
                            factor: factor,
                            spatialLoading: spatialLoading(factor),
                            temporalLoading: temporalLoading(factor),
                            timesMS: result.firstTimesMS,
                            subjects: clusterSubjects,
                            conditionNames: clusterConditionNames,
                            factorNames: clusterFactorNames,
                            baselineSamples: clusterBaseline,
                            samplingRate: clusterSamplingRate
                        )
                        .id(factor.name)
                    }
                }
            }
        }
    }
}

/// A compact, multi-column listing of the combined (TF×SF) factors ranked by
/// variance share. Wraps into as many columns as the available width allows so
/// it stays short rather than one long skinny column.
struct CombinedFactorsTable: View {
    let result: TwoStepPCAResult

    private var sortedFactors: [TwoStepFactor] {
        result.factors.sorted { $0.variance > $1.variance }
    }

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 240), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%.0f%% total variance", result.totalVariance * 100))
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Array(sortedFactors.enumerated()), id: \.offset) { _, factor in
                    HStack(spacing: 8) {
                        Text(factor.name).font(.callout.monospaced())
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f%%", factor.variance * 100))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The per-temporal-factor grid of spatial topographies, reused for on-screen
/// display and PNG export.
struct TopomapGridView: View {
    let result: TwoStepPCAResult
    let layout: SensorLayout
    var threshold: Double = 0
    var selectedID: String? = nil
    var onSelect: ((TwoStepFactor) -> Void)? = nil

    private func factor(t: Int, s: Int) -> TwoStepFactor? {
        result.factors.first { $0.firstIndex == t && $0.secondIndex == s }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<result.second.count, id: \.self) { t in
                temporalRow(t)
            }
        }
    }

    private func temporalRow(_ t: Int) -> some View {
        let step = result.second[t]
        let tfLabel = "\(result.firstMode.factorPrefix)\(t + 1)"
        let tfVar = result.first.variance.indices.contains(t) ? result.first.variance[t] * 100 : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(tfLabel) · " + String(format: "%.1f%% temporal", tfVar))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<step.pattern.cols, id: \.self) { s in
                        if let factor = factor(t: t, s: s) {
                            topomapCard(factor, pattern: step.pattern.column(s))
                                .frame(width: 180)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.accentColor,
                                                      lineWidth: selectedID == factor.name ? 2.5 : 0)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect?(factor) }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func topomapCard(_ factor: TwoStepFactor, pattern: [Double]) -> some View {
        VStack(spacing: 4) {
            Text(factor.name).font(.caption.monospaced().weight(.semibold))
            Text(String(format: "%.1f%%", factor.variance * 100))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            TopomapView(
                layout: layout,
                values: pattern,
                timeSeconds: 0,
                fixedScale: nil,
                showsHeader: false,
                canvasMinHeight: 150,
                highlightThreshold: threshold > 0 ? threshold : nil
            )
            .frame(height: 180)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
