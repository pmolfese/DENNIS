//
//  ScreePlotView.swift
//  DENNIS
//
//  Renders a Toolkit-style scree / parallel-analysis plot: the unrotated data
//  eigenvalue curve against the rescaled random curve, with the retention
//  suggestions called out. Built on Swift Charts.
//

import SwiftUI
import Charts

struct ScreePlotView: View {
    let analysis: ScreeAnalysis
    var maxFactors: Int = 20

    private struct Point: Identifiable {
        let id = UUID()
        let factor: Int
        let value: Double
        let series: String
    }

    private var points: [Point] {
        let n = min(maxFactors, analysis.dataScree.count, analysis.randomScreeScaled.count)
        var out: [Point] = []
        for i in 0..<n {
            out.append(Point(factor: i + 1, value: analysis.dataScree[i], series: "Data"))
            out.append(Point(factor: i + 1, value: analysis.randomScreeScaled[i], series: "Random (scaled)"))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                retentionStat("Parallel test", analysis.retainedParallel)
                retentionStat("Min-variance (95%)", analysis.retainedMinVariance)
            }

            Chart(points) { point in
                LineMark(
                    x: .value("Factor", point.factor),
                    y: .value("Eigenvalue", point.value)
                )
                .foregroundStyle(by: .value("Series", point.series))
                PointMark(
                    x: .value("Factor", point.factor),
                    y: .value("Eigenvalue", point.value)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .symbolSize(40)
            }
            .chartForegroundStyleScale([
                "Data": Color.accentColor,
                "Random (scaled)": Color.secondary,
            ])
            .chartXAxisLabel("Factor")
            .chartYAxisLabel("Eigenvalue")
            .frame(minHeight: 280)
        }
    }

    private func retentionStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
