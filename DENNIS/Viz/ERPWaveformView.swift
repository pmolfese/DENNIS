//
//  ERPWaveformView.swift
//  DENNIS
//
//  A butterfly plot for one averaged condition: every channel's waveform drawn
//  overlaid on a shared time/amplitude axis, with a stimulus-onset flag and a
//  draggable time cursor that the surrounding view feeds to the topomap. An
//  optional bold "centroid" trace (mean across channels) can be overlaid for
//  grand-average plots.
//

import SwiftUI

struct ERPWaveformView: View {
    /// `channels × samples` for this condition's average.
    let samples: [[Float]]
    let samplingRate: Double
    /// Samples before zero (stimulus onset).
    let baselineSamples: Int
    /// Currently selected sample index (drives the topomap), clamped to range.
    @Binding var cursorSample: Int
    /// Optional bold overlay trace (e.g. the channel centroid), `samples` long.
    var centroid: [Float]? = nil

    private var sampleCount: Int { samples.first?.count ?? 0 }

    /// Symmetric amplitude bound (µV) across all channels and samples.
    private var amplitudeBound: Double {
        let maxAbs = samples.reduce(0.0) { partial, channel in
            max(partial, channel.reduce(0.0) { max($0, Double(abs($1))) })
        }
        return maxAbs > 0 ? maxAbs : 1
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize)
                }
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

    // MARK: - Drawing

    private func xPosition(forSample sample: Int, width: CGFloat) -> CGFloat {
        guard sampleCount > 1 else { return 0 }
        return CGFloat(sample) / CGFloat(sampleCount - 1) * width
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard sampleCount > 1 else { return }
        let bound = amplitudeBound
        let midY = size.height / 2
        let yScale = (size.height / 2 - 8) / bound
        let xScale = size.width / CGFloat(sampleCount - 1)

        // Zero baseline (amplitude = 0).
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: midY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(zeroLine, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)

        // Stimulus onset (time zero) vertical line.
        if baselineSamples > 0, baselineSamples < sampleCount {
            let zeroX = CGFloat(baselineSamples) * xScale
            var onset = Path()
            onset.move(to: CGPoint(x: zeroX, y: 0))
            onset.addLine(to: CGPoint(x: zeroX, y: size.height))
            context.stroke(onset, with: .color(.secondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // One translucent trace per channel (the "butterfly").
        for channel in samples {
            guard channel.count == sampleCount else { continue }
            context.stroke(path(for: channel, midY: midY, xScale: xScale, yScale: yScale),
                           with: .color(.accentColor.opacity(0.30)), lineWidth: 0.6)
        }

        // Optional centroid overlay (bold).
        if let centroid, centroid.count == sampleCount {
            context.stroke(path(for: centroid, midY: midY, xScale: xScale, yScale: yScale),
                           with: .color(.primary.opacity(0.85)), lineWidth: 2)
        }

        // Cursor.
        let cursorX = CGFloat(min(max(cursorSample, 0), sampleCount - 1)) * xScale
        var cursor = Path()
        cursor.move(to: CGPoint(x: cursorX, y: 0))
        cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
        context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
    }

    private func path(for channel: [Float], midY: CGFloat, xScale: CGFloat, yScale: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY - CGFloat(channel[0]) * yScale))
        for i in 1..<channel.count {
            path.addLine(to: CGPoint(x: CGFloat(i) * xScale, y: midY - CGFloat(channel[i]) * yScale))
        }
        return path
    }

    // MARK: - Overlays

    /// Stimulus-onset flag: a small capsule label with a stem, matching the
    /// event-marker style used across the EEG projects.
    @ViewBuilder
    private func stimulusFlag(in size: CGSize) -> some View {
        if baselineSamples > 0, baselineSamples < sampleCount {
            let x = xPosition(forSample: baselineSamples, width: size.width)
            VStack(spacing: 0) {
                Text("stim")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: 1, height: 10)
            }
            .fixedSize()
            .offset(x: x - 14, y: 2)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cursorLabel(in size: CGSize) -> some View {
        HStack(spacing: 12) {
            Text(timeLabel(forSample: cursorSample))
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(String(format: "±%.1f µV", amplitudeBound))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
