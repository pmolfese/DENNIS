//
//  OverlayWaveformView.swift
//  DENNIS
//
//  Overlays several single-trace waveforms (e.g. the channel centroid of each
//  sub-group or each condition) on a shared time/amplitude axis, each in its own
//  color with a legend. Used for grand-average comparisons.
//

import SwiftUI

struct OverlayTrace: Identifiable {
    let id: String
    let label: String
    let color: Color
    /// One waveform (e.g. a centroid), `sampleCount` long.
    let samples: [Float]
    let contributing: Int
}

struct OverlayWaveformView: View {
    let traces: [OverlayTrace]
    let samplingRate: Double
    let baselineSamples: Int
    @Binding var cursorSample: Int

    /// Distinct, color-blind-friendlyish palette for overlays.
    static let palette: [Color] = [.blue, .red, .green, .orange, .purple, .teal, .pink, .brown]

    private var sampleCount: Int { traces.map(\.samples.count).max() ?? 0 }

    private var amplitudeBound: Double {
        let maxAbs = traces.reduce(0.0) { partial, trace in
            max(partial, trace.samples.reduce(0.0) { max($0, Double(abs($1))) })
        }
        return maxAbs > 0 ? maxAbs : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            legend
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvasSize in draw(in: &context, size: canvasSize) }
                    stimulusFlag(in: size)
                    cursorLabel(in: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            cursorSample = sample(forX: value.location.x, width: size.width)
                        }
                )
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(traces) { trace in
                    HStack(spacing: 5) {
                        Capsule().fill(trace.color).frame(width: 14, height: 3)
                        Text(trace.label).font(.caption)
                        Text("n=\(trace.contributing)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard sampleCount > 1 else { return }
        let bound = amplitudeBound
        let midY = size.height / 2
        let yScale = (size.height / 2 - 8) / bound
        let xScale = size.width / CGFloat(sampleCount - 1)

        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: midY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(zeroLine, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)

        if baselineSamples > 0, baselineSamples < sampleCount {
            let zeroX = CGFloat(baselineSamples) * xScale
            var onset = Path()
            onset.move(to: CGPoint(x: zeroX, y: 0))
            onset.addLine(to: CGPoint(x: zeroX, y: size.height))
            context.stroke(onset, with: .color(.secondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        for trace in traces where trace.samples.count > 1 {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY - CGFloat(trace.samples[0]) * yScale))
            for i in 1..<trace.samples.count {
                path.addLine(to: CGPoint(x: CGFloat(i) * xScale, y: midY - CGFloat(trace.samples[i]) * yScale))
            }
            context.stroke(path, with: .color(trace.color), lineWidth: 1.8)
        }

        let cursorX = CGFloat(min(max(cursorSample, 0), sampleCount - 1)) * xScale
        var cursor = Path()
        cursor.move(to: CGPoint(x: cursorX, y: 0))
        cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
        context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
    }

    @ViewBuilder
    private func stimulusFlag(in size: CGSize) -> some View {
        if baselineSamples > 0, baselineSamples < sampleCount {
            let x = CGFloat(baselineSamples) / CGFloat(sampleCount - 1) * size.width
            VStack(spacing: 0) {
                Text("stim")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 1, height: 10)
            }
            .fixedSize()
            .offset(x: x - 14, y: 2)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cursorLabel(in size: CGSize) -> some View {
        HStack(spacing: 10) {
            Text(timeLabel(forSample: cursorSample))
                .font(.caption.monospacedDigit().weight(.semibold))
            // Per-trace value at the cursor.
            ForEach(traces) { trace in
                if cursorSample < trace.samples.count {
                    Text(String(format: "%.1f", trace.samples[cursorSample]))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(trace.color)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Time helpers

    private func sample(forX x: CGFloat, width: CGFloat) -> Int {
        guard sampleCount > 1, width > 0 else { return 0 }
        let fraction = max(0, min(1, x / width))
        return Int((fraction * CGFloat(sampleCount - 1)).rounded())
    }

    private func timeLabel(forSample sample: Int) -> String {
        guard samplingRate > 0 else { return "\(sample)" }
        let ms = Double(sample - baselineSamples) / samplingRate * 1000
        return String(format: "%.0f ms", ms)
    }
}
