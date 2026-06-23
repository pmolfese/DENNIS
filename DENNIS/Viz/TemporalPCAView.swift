//
//  TemporalPCAView.swift
//  DENNIS
//
//  Plots the temporal factor loadings of a single-step PCA: each retained
//  factor's `pattern` column is a waveform over time, so a temporal PCA reads as
//  a set of overlaid factor shapes against the post-stimulus time axis. Variance
//  accounted for is shown alongside each factor in the legend.
//

import SwiftUI
import Charts

/// A temporal PCA result paired with the time (ms) of each retained sample, so
/// its loadings plot on a real time axis even after trimming/downsampling. Value
/// type so it can cross actor boundaries.
nonisolated struct TemporalPCAResult {
    let result: PCAResult
    /// Time in ms for each variable (row of `pattern`).
    let timesMS: [Double]
}

struct TemporalPCAView: View {
    let model: TemporalPCAResult

    private struct Point: Identifiable {
        let id = UUID()
        let timeMS: Double
        let loading: Double
        let factor: String
    }

    private var factorLabels: [String] {
        let prefix = model.result.mode.factorPrefix
        return (0..<model.result.nFactors).map { c in
            let pct = model.result.variance.indices.contains(c) ? model.result.variance[c] * 100 : 0
            return String(format: "%@%d (%.0f%%)", prefix, c + 1, pct)
        }
    }

    private func timeMS(_ sample: Int) -> Double {
        model.timesMS.indices.contains(sample) ? model.timesMS[sample] : Double(sample)
    }

    private var points: [Point] {
        let pattern = model.result.pattern   // times × factors
        let labels = factorLabels
        var out: [Point] = []
        out.reserveCapacity(pattern.rows * pattern.cols)
        for c in 0..<pattern.cols {
            for r in 0..<pattern.rows {
                out.append(Point(timeMS: timeMS(r), loading: pattern[r, c], factor: labels[c]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temporal factor loadings · \(model.result.nFactors) factors · "
                 + String(format: "%.0f%% variance", model.result.totalVariance * 100))
                .font(.caption).foregroundStyle(.secondary)

            Chart(points) { point in
                LineMark(
                    x: .value("Time (ms)", point.timeMS),
                    y: .value("Loading", point.loading)
                )
                .foregroundStyle(by: .value("Factor", point.factor))
            }
            .chartXAxisLabel("Time (ms)")
            .chartYAxisLabel("Loading")
            .frame(minHeight: 300)
        }
    }
}
