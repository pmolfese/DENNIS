//
//  DualPCAView.swift
//  DENNIS
//
//  Summary view for a two-step (dual) PCA: the first-step temporal factor
//  loadings plus a table of the combined temporal×spatial factors ranked by the
//  variance they account for. Spatial topographies per factor are a planned
//  follow-up.
//

import SwiftUI

struct DualPCAView: View {
    let result: TwoStepPCAResult
    var sensorLayout: SensorLayout?

    private var sortedFactors: [TwoStepFactor] {
        result.factors.sorted { $0.variance > $1.variance }
    }

    private func factor(t: Int, s: Int) -> TwoStepFactor? {
        result.factors.first { $0.firstIndex == t && $0.secondIndex == s }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(result.factors.count) combined factors · "
                 + String(format: "%.0f%% total variance", result.totalVariance * 100))
                .font(.caption).foregroundStyle(.secondary)

            if result.firstMode == .temporal {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First step — temporal factor loadings")
                        .font(.subheadline.weight(.semibold))
                    TemporalPCAView(model: TemporalPCAResult(result: result.first,
                                                             timesMS: result.firstTimesMS))
                }
            }

            if let layout = sensorLayout {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Spatial factor topographies").font(.subheadline.weight(.semibold))
                    // One row per temporal factor; its spatial maps sit on that row.
                    ForEach(0..<result.second.count, id: \.self) { t in
                        temporalRow(t, layout: layout)
                    }
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

    private func temporalRow(_ t: Int, layout: SensorLayout) -> some View {
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
                            topomapCard(factor, pattern: step.pattern.column(s), layout: layout)
                                .frame(width: 180)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func topomapCard(_ factor: TwoStepFactor, pattern: [Double], layout: SensorLayout) -> some View {
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
                canvasMinHeight: 150
            )
            .frame(height: 180)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
