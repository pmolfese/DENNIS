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
    private let stats: WaveformRenderStats

    init(samples: [[Float]], samplingRate: Double, baselineSamples: Int,
         cursorSample: Binding<Int>, centroid: [Float]? = nil) {
        self.samples = samples
        self.samplingRate = samplingRate
        self.baselineSamples = baselineSamples
        self._cursorSample = cursorSample
        self.centroid = centroid
        self.stats = WaveformRenderStats(samples: samples, centroid: centroid)
    }

    private var sampleCount: Int { stats.sampleCount }
    private var amplitudeBound: Double { stats.amplitudeBound }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: true) { context, canvasSize in
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
        let paths = WaveformPathCache.shared.paths(
            key: stats.cacheKey(prefix: "erp", size: size, extra: "\(bound)")
        ) {
            WaveformPathSet(
                channels: samples.compactMap { channel in
                    channel.count == sampleCount
                        ? Self.path(for: channel, midY: midY, xScale: xScale, yScale: yScale)
                        : nil
                },
                centroid: centroid.flatMap { trace in
                    trace.count == sampleCount
                        ? Self.path(for: trace, midY: midY, xScale: xScale, yScale: yScale)
                        : nil
                }
            )
        }

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
        for path in paths.channels {
            context.stroke(path,
                           with: .color(.accentColor.opacity(0.30)), lineWidth: 0.6)
        }

        // Optional centroid overlay (bold).
        if let centroid = paths.centroid {
            context.stroke(centroid,
                           with: .color(.primary.opacity(0.85)), lineWidth: 2)
        }

        // Cursor.
        let cursorX = CGFloat(min(max(cursorSample, 0), sampleCount - 1)) * xScale
        var cursor = Path()
        cursor.move(to: CGPoint(x: cursorX, y: 0))
        cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
        context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
    }

    private static func path(for channel: [Float], midY: CGFloat, xScale: CGFloat, yScale: Double) -> Path {
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

nonisolated struct WaveformRenderStats {
    let sampleCount: Int
    let amplitudeBound: Double
    private let fingerprint: Int

    init(samples: [[Float]], centroid: [Float]? = nil,
         standardErrors: [[Float]?] = [], includesCentroid: Bool = true,
         includesStandardError: Bool = false) {
        self.sampleCount = samples.first?.count ?? centroid?.count ?? 0
        var maxAbs = 0.0
        var hasher = Hasher()
        hasher.combine(samples.count)
        hasher.combine(sampleCount)

        for channel in samples {
            hasher.combine(channel.count)
            for value in channel {
                maxAbs = max(maxAbs, Double(abs(value)))
                hasher.combine(value.bitPattern)
            }
        }

        if includesCentroid, let centroid {
            hasher.combine("centroid")
            hasher.combine(centroid.count)
            for value in centroid {
                maxAbs = max(maxAbs, Double(abs(value)))
                hasher.combine(value.bitPattern)
            }
        }

        if includesStandardError {
            hasher.combine("se")
            for maybeSE in standardErrors {
                guard let se = maybeSE else {
                    hasher.combine(0)
                    continue
                }
                hasher.combine(se.count)
                for value in se {
                    maxAbs = max(maxAbs, Double(abs(value)))
                    hasher.combine(value.bitPattern)
                }
            }
        }

        self.amplitudeBound = maxAbs > 0 ? maxAbs : 1
        self.fingerprint = hasher.finalize()
    }

    func cacheKey(prefix: String, size: CGSize, extra: String = "") -> String {
        let width = Int((size.width * 2).rounded())
        let height = Int((size.height * 2).rounded())
        return "\(prefix)-\(fingerprint)-\(width)x\(height)-\(extra)"
    }
}

nonisolated struct WaveformPathSet {
    let channels: [Path]
    let centroid: Path?
}

nonisolated final class WaveformPathCache {
    static let shared = WaveformPathCache()

    private final class Box {
        let value: WaveformPathSet
        init(_ value: WaveformPathSet) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 96
    }

    func paths(key: String, build: () -> WaveformPathSet) -> WaveformPathSet {
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }
        let value = build()
        cache.setObject(Box(value), forKey: cacheKey)
        return value
    }
}
