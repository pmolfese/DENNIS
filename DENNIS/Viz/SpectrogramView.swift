//
//  SpectrogramView.swift
//  DENNIS
//
//  A frequency × time power heatmap, used to preview the time-frequency transform
//  before building the tensor. Sequential scale for raw power, diverging (blue–
//  white–red) for dB-vs-baseline data which is signed.
//

import SwiftUI

struct SpectrogramView: View {
    let freqs: [Double]
    let timesMS: [Double]
    /// `power[freq][time]`.
    let power: [[Double]]
    let isSigned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                Canvas { context, size in draw(in: &context, size: size) }
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            HStack {
                Text(axisText(timesMS.first, "ms")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("frequency \(Int(freqs.first ?? 0))–\(Int(freqs.last ?? 0)) Hz")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(axisText(timesMS.last, "ms")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func axisText(_ value: Double?, _ unit: String) -> String {
        value.map { String(format: "%.0f %@", $0, unit) } ?? ""
    }

    private var bound: Double {
        let maxAbs = power.reduce(0.0) { p, row in max(p, row.reduce(0.0) { max($0, abs($1)) }) }
        return maxAbs > 0 ? maxAbs : 1
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let nF = power.count
        guard nF > 0, let nT = power.first?.count, nT > 0 else { return }
        let cellW = size.width / CGFloat(nT)
        let cellH = size.height / CGFloat(nF)
        let b = bound
        for fi in 0..<nF {
            // Low frequency at the bottom.
            let y = size.height - CGFloat(fi + 1) * cellH
            for ti in 0..<nT {
                let value = power[fi][ti]
                let color = isSigned ? diverging(value / b) : sequential(max(0, value) / b)
                let rect = CGRect(x: CGFloat(ti) * cellW, y: y, width: cellW + 0.5, height: cellH + 0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func sequential(_ t: Double) -> Color {
        let x = max(0, min(1, t))
        // dark navy → teal → yellow
        return Color(red: 0.15 + 0.0 * x, green: 0.1 + 0.8 * x, blue: 0.4 + 0.2 * (1 - x))
    }

    private func diverging(_ t: Double) -> Color {
        let x = max(-1, min(1, t))
        if x < 0 {
            let f = x + 1
            return Color(red: 0.23 + 0.73 * f, green: 0.30 + 0.66 * f, blue: 0.75 + 0.21 * f)
        }
        return Color(red: 0.96 - 0.18 * x, green: 0.96 - 0.80 * x, blue: 0.96 - 0.80 * x)
    }
}
