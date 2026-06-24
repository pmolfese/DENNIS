//
//  OverlayWaveformView.swift
//  DENNIS
//
//  Overlays several butterfly plots on a shared time/amplitude axis, each in
//  its own color with a bold centroid guide and legend. Used for grand-average
//  comparisons.
//

import SwiftUI

struct OverlayTrace: Identifiable {
    let id: String
    let label: String
    let color: Color
    /// `channels × samples` for this comparison.
    let samples: [[Float]]
    /// Mean across channels, used for a bold guide line and cursor readout.
    let centroid: [Float]
    let contributing: Int
    let sensorLayout: SensorLayout?
    /// Optional ±band (e.g. standard error) around `centroid`, same length.
    var centroidSE: [Float]? = nil

    var sampleCount: Int { samples.first?.count ?? centroid.count }
}

struct OverlayWaveformView: View {
    let traces: [OverlayTrace]
    let samplingRate: Double
    let baselineSamples: Int
    let showsCentroid: Bool
    @Binding var cursorSample: Int
    /// Draw each trace's `centroidSE` as a translucent ±band behind its line.
    var showsStandardError: Bool = false
    /// Time windows (ms, relative to stimulus onset) to gently shade — e.g. the
    /// active span of a temporal PCA factor.
    var shadedMSRanges: [ClosedRange<Double>] = []
    /// Show the floating readout with cursor time and centroid values.
    var showsCursorReadout: Bool = true
    /// Show the trace legend above the waveform.
    var showsLegend: Bool = true

    /// Distinct, color-blind-friendlyish palette for overlays.
    static let palette: [Color] = [.blue, .red, .green, .orange, .purple, .teal, .pink, .brown]

    private var sampleCount: Int { traces.map(\.sampleCount).max() ?? 0 }
    private var markerBandHeight: CGFloat { shadedMSRanges.isEmpty ? 0 : 24 }
    private let yAxisWidth: CGFloat = 48

    private var amplitudeBound: Double {
        let maxAbs = traces.reduce(0.0) { partial, trace in
            let sampleMax = trace.samples.reduce(0.0) { channelPartial, channel in
                max(channelPartial, channel.reduce(0.0) { max($0, Double(abs($1))) })
            }
            var centroidMax = 0.0
            if showsCentroid {
                let se = (showsStandardError ? trace.centroidSE : nil)
                for i in trace.centroid.indices {
                    let band = se.map { i < $0.count ? Double($0[i]) : 0 } ?? 0
                    centroidMax = max(centroidMax, abs(Double(trace.centroid[i])) + band)
                }
            }
            return max(partial, max(sampleMax, centroidMax))
        }
        return maxAbs > 0 ? maxAbs : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLegend {
                legend
            }
            GeometryReader { proxy in
                let size = proxy.size
                let plotHeight = max(40, size.height - markerBandHeight)
                let plotWidth = max(40, size.width - yAxisWidth)
                let plotSize = CGSize(width: plotWidth, height: plotHeight)
                ZStack(alignment: .topLeading) {
                    yAxisScale(plotSize: plotSize)
                        .frame(width: yAxisWidth, height: plotHeight, alignment: .leading)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, canvasSize in draw(in: &context, size: canvasSize) }
                            .frame(width: plotSize.width, height: plotHeight, alignment: .top)
                        stimulusFlag(in: plotSize)
                        temporalRangeMarkers(plotSize: plotSize)
                        if showsCursorReadout {
                            cursorLabel(in: plotSize)
                        }
                    }
                    .frame(width: plotSize.width, height: size.height, alignment: .top)
                    .offset(x: yAxisWidth)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            cursorSample = sample(forX: value.location.x - yAxisWidth, width: plotSize.width)
                        }
                )
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        }
    }

    private func yAxisScale(plotSize: CGSize) -> some View {
        let bound = niceAxisBound(amplitudeBound)
        return VStack(alignment: .trailing, spacing: 0) {
            Text(axisLabel(bound))
            Spacer()
            Text("0")
            Spacer()
            Text(axisLabel(-bound))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
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

        // Gentle shading for the active temporal-factor window(s).
        for range in shadedMSRanges where samplingRate > 0 {
            let loX = CGFloat(sampleForMS(range.lowerBound)) * xScale
            let hiX = CGFloat(sampleForMS(range.upperBound)) * xScale
            let rect = CGRect(x: min(loX, hiX), y: 0, width: abs(hiX - loX), height: size.height)
            context.fill(Path(rect), with: .color(.yellow.opacity(0.12)))
        }

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

        for trace in traces {
            for channel in trace.samples where channel.count == sampleCount {
                context.stroke(
                    path(for: channel, midY: midY, xScale: xScale, yScale: yScale),
                    with: .color(trace.color.opacity(0.22)),
                    lineWidth: 0.8
                )
            }
            if showsCentroid, trace.centroid.count == sampleCount {
                // Translucent ±SE band behind the mean line.
                if showsStandardError, let se = trace.centroidSE, se.count == sampleCount {
                    context.fill(
                        bandPath(center: trace.centroid, half: se,
                                 midY: midY, xScale: xScale, yScale: yScale),
                        with: .color(trace.color.opacity(0.18))
                    )
                }
                context.stroke(
                    path(for: trace.centroid, midY: midY, xScale: xScale, yScale: yScale),
                    with: .color(trace.color.opacity(0.95)),
                    lineWidth: 2.2
                )
            }
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
            if showsCentroid {
                ForEach(traces) { trace in
                    if cursorSample < trace.centroid.count {
                        Text(String(format: "%.1f", trace.centroid[cursorSample]))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(trace.color)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func temporalRangeMarkers(plotSize: CGSize) -> some View {
        if samplingRate > 0, sampleCount > 1, !shadedMSRanges.isEmpty {
            ForEach(Array(shadedMSRanges.enumerated()), id: \.offset) { index, range in
                timeMarker(ms: range.lowerBound, plotSize: plotSize)
                timeMarker(ms: range.upperBound, plotSize: plotSize)
            }
        }
    }

    private func timeMarker(ms: Double, plotSize: CGSize) -> some View {
        let x = markerX(forMS: ms, width: plotSize.width)
        let labelX = min(max(x, 30), max(30, plotSize.width - 30))
        let y = plotSize.height + markerBandHeight / 2
        return VStack(spacing: 1) {
            Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 1, height: 8)
            Text(String(format: "%.0f ms", ms))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.white, in: Capsule())
                .overlay(Capsule().stroke(Color.yellow.opacity(0.85), lineWidth: 1))
        }
        .fixedSize()
        .position(x: labelX, y: y)
        .allowsHitTesting(false)
    }

    // MARK: - Time helpers

    private func path(for channel: [Float], midY: CGFloat, xScale: CGFloat, yScale: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY - CGFloat(channel[0]) * yScale))
        for i in 1..<channel.count {
            path.addLine(to: CGPoint(x: CGFloat(i) * xScale, y: midY - CGFloat(channel[i]) * yScale))
        }
        return path
    }

    /// Closed band between `center + half` (upper) and `center − half` (lower).
    private func bandPath(center: [Float], half: [Float],
                          midY: CGFloat, xScale: CGFloat, yScale: Double) -> Path {
        var path = Path()
        let n = min(center.count, half.count)
        guard n > 1 else { return path }
        func y(_ i: Int, _ sign: CGFloat) -> CGPoint {
            CGPoint(x: CGFloat(i) * xScale,
                    y: midY - (CGFloat(center[i]) + sign * CGFloat(half[i])) * yScale)
        }
        path.move(to: y(0, 1))
        for i in 1..<n { path.addLine(to: y(i, 1)) }          // upper edge →
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: y(i, -1)) }  // ← lower edge
        path.closeSubpath()
        return path
    }

    /// Fractional sample index for a time in ms (relative to stimulus onset).
    private func sampleForMS(_ ms: Double) -> Double {
        Double(baselineSamples) + ms / 1000 * samplingRate
    }

    private func sample(forX x: CGFloat, width: CGFloat) -> Int {
        guard sampleCount > 1, width > 0 else { return 0 }
        let fraction = max(0, min(1, x / width))
        return Int((fraction * CGFloat(sampleCount - 1)).rounded())
    }

    private func markerX(forMS ms: Double, width: CGFloat) -> CGFloat {
        guard sampleCount > 1 else { return 0 }
        let sample = max(0, min(Double(sampleCount - 1), sampleForMS(ms)))
        return CGFloat(sample) / CGFloat(sampleCount - 1) * width
    }

    private func niceAxisBound(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let scaled = value / base
        let nice: Double
        if scaled <= 1 { nice = 1 }
        else if scaled <= 2 { nice = 2 }
        else if scaled <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * base
    }

    private func axisLabel(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 10 { return String(format: "%.0f", value) }
        if absValue >= 1 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func timeLabel(forSample sample: Int) -> String {
        guard samplingRate > 0 else { return "\(sample)" }
        let ms = Double(sample - baselineSamples) / samplingRate * 1000
        return String(format: "%.0f ms", ms)
    }
}
