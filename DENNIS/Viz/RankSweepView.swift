//
//  RankSweepView.swift
//  DENNIS
//
//  Fit and core-consistency (CORCONDIA) against PARAFAC rank. The chosen rank is
//  the largest where core consistency is still high while fit gains have
//  flattened.
//

import SwiftUI
import Charts

struct RankSweepView: View {
    let points: [MultiwayDiagnostics.RankPoint]

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Rank", point.rank),
                         y: .value("Fit %", point.fit * 100),
                         series: .value("Series", "Fit %"))
                    .foregroundStyle(by: .value("Series", "Fit %"))
                PointMark(x: .value("Rank", point.rank), y: .value("Fit %", point.fit * 100))
                    .foregroundStyle(by: .value("Series", "Fit %"))
                    .symbolSize(28)
            }
            ForEach(points) { point in
                let cc = displayCoreConsistency(point.coreConsistency)
                LineMark(x: .value("Rank", point.rank),
                         y: .value("Core consistency %", cc),
                         series: .value("Series", "Core consistency %"))
                    .foregroundStyle(by: .value("Series", "Core consistency %"))
                PointMark(x: .value("Rank", point.rank),
                          y: .value("Core consistency %", cc))
                    .foregroundStyle(by: .value("Series", "Core consistency %"))
                    .symbolSize(28)
            }
            RuleMark(y: .value("threshold", 50))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartForegroundStyleScale([
            "Fit %": Color.accentColor,
            "Core consistency %": Color.orange,
        ])
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                if let y = value.as(Double.self) {
                    AxisValueLabel("\(Int(y.rounded()))%")
                }
            }
        }
        .chartXAxisLabel("Rank (components)")
        .frame(minHeight: 220)
    }

    private func displayCoreConsistency(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -20), 100)
    }
}
