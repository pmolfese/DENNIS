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

    @State private var threshold: Double = 0

    private var sortedFactors: [TwoStepFactor] {
        result.factors.sorted { $0.variance > $1.variance }
    }

    /// Largest absolute spatial loading across all factors — the slider's range.
    private var maxAbsLoading: Double {
        result.second.flatMap { $0.pattern.grid }.map(abs).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(result.factors.count) combined factors · "
                 + String(format: "%.0f%% total variance", result.totalVariance * 100))
                .font(.caption).foregroundStyle(.secondary)

            if result.firstMode == .temporal {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("First step — temporal factor loadings")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            ImageExport.savePNG(
                                TemporalPCAView(model: TemporalPCAResult(result: result.first,
                                                                         timesMS: result.firstTimesMS)),
                                suggestedName: "temporal_loadings")
                        } label: { Label("Save PNG", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    TemporalPCAView(model: TemporalPCAResult(result: result.first,
                                                             timesMS: result.firstTimesMS))
                }
            }

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
                        Text("Threshold (loading): " + String(format: "%.2f", threshold))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Slider(value: $threshold, in: 0...max(maxAbsLoading, 0.001))
                            .frame(maxWidth: 280)
                        if threshold > 0 {
                            Button("Clear") { threshold = 0 }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    TopomapGridView(result: result, layout: layout, threshold: threshold)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Combined factors").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("Factor").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Variance").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(sortedFactors.enumerated()), id: \.offset) { _, factor in
                        GridRow {
                            Text(factor.name).font(.callout.monospaced())
                            Text(String(format: "%.1f%%", factor.variance * 100))
                                .font(.callout.monospacedDigit())
                        }
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
