//
//  ModeScreeView.swift
//  DENNIS
//
//  Small-multiple scree plots — one per tensor mode — of the multilinear SVD
//  singular spectra. Each mode's elbow bounds how many components that mode can
//  support; the "to 90%" stat is how many singular values capture 90% of the
//  mode's energy. Built on Swift Charts.
//

import SwiftUI
import Charts

struct ModeScreeView: View {
    let modes: [ModeScree]

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(modes) { mode in
                card(mode)
            }
        }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let component: Int
        let value: Double
        let series: String
    }

    private func points(_ mode: ModeScree) -> [Point] {
        var out = mode.singularValues.enumerated().map {
            Point(component: $0.offset + 1, value: $0.element, series: "Data")
        }
        out += mode.randomFloor.enumerated().map {
            Point(component: $0.offset + 1, value: $0.element, series: "Random")
        }
        return out
    }

    /// Components needed to reach 90% of the mode's energy.
    private func componentsTo90(_ mode: ModeScree) -> Int {
        (mode.cumulativeVariance.firstIndex { $0 >= 0.9 }).map { $0 + 1 } ?? mode.singularValues.count
    }

    private func card(_ mode: ModeScree) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mode.name).font(.subheadline.weight(.semibold))
                Spacer()
                if let retained = mode.retained {
                    Text("\(retained) above floor")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("\(componentsTo90(mode)) to 90%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart(points(mode)) { point in
                LineMark(x: .value("Component", point.component),
                         y: .value("Singular value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                PointMark(x: .value("Component", point.component),
                          y: .value("Singular value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .symbolSize(24)
            }
            .chartForegroundStyleScale(["Data": Color.accentColor, "Random": Color.secondary])
            .chartLegend(mode.randomFloor.isEmpty ? .hidden : .visible)
            .chartXAxisLabel("Component")
            .frame(minHeight: 150)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
