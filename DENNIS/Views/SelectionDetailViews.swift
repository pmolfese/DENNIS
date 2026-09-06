//
//  SelectionDetailViews.swift
//  DENNIS
//
//  Detail panes for a single selected condition or dataset in the sidebar.
//  Reachable from the PCA mode's selection router (see DetailView).
//

import SwiftUI

// MARK: - Condition detail (waveform + topomap)

struct ConditionDetail: View {
    let dataset: Dataset
    let condition: Condition

    @State private var cursorSample = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let samples = condition.samples, !samples.isEmpty {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Butterfly").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ERPWaveformView(
                            samples: samples,
                            samplingRate: dataset.samplingRate,
                            baselineSamples: condition.baselineSamples,
                            cursorSample: $cursorSample
                        )
                    }
                    .frame(maxWidth: .infinity)

                    topomap(samples: samples)
                        .frame(width: 320)
                }
            } else {
                loadingPlaceholder
            }
        }
        .padding()
        .navigationTitle(condition.name)
        .onAppear { cursorSample = condition.baselineSamples }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(condition.name).font(.largeTitle.bold())
            Text("\(dataset.name) · \(condition.sampleCount) samples · \(dataset.channelCount) channels"
                 + (dataset.samplingRate > 0 ? " · \(Int(dataset.samplingRate)) Hz" : ""))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func topomap(samples: [[Float]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let layout = dataset.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: samples.map { sample in
                        cursorSample < sample.count ? Double(sample[cursorSample]) : 0
                    },
                    timeSeconds: dataset.samplingRate > 0 ? Double(cursorSample) / dataset.samplingRate : 0,
                    fixedScale: nil
                )
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml.")
                )
            }
        }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay { ProgressView("Loading signal…") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dataset detail (summary)

struct DatasetDetail: View {
    let dataset: Dataset

    var body: some View {
        Form {
            Section("Subject") {
                LabeledContent("Name", value: dataset.name)
                LabeledContent("Source", value: dataset.sourceURL.lastPathComponent)
                LabeledContent("Channels", value: dataset.channelCount > 0 ? "\(dataset.channelCount)" : "—")
                LabeledContent("Sampling rate",
                               value: dataset.samplingRate > 0 ? "\(Int(dataset.samplingRate)) Hz" : "—")
                LabeledContent("Status", value: statusText)
            }
            if !dataset.levels.isEmpty {
                Section("Design") {
                    ForEach(Array(dataset.levels.enumerated()), id: \.offset) { _, level in
                        Text(level.isEmpty ? "—" : level)
                    }
                }
            }
            Section {
                ForEach(dataset.conditions) { condition in
                    LabeledContent(condition.name) {
                        Text(epochDescription(condition))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Conditions")
            } footer: {
                if dataset.conditions.contains(where: { $0.sampleCount > 0 && $0.baselineSamples == 0 }) {
                    Text("A 0 ms pre-stimulus interval means the file's categories carried no stimulus-onset event, "
                         + "so the epoch is timed from its own start. Analyses that position a window relative to "
                         + "onset will treat sample 0 as onset for those conditions.")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dataset.name)
    }

    /// Epoch geometry in the terms an analysis window is specified in: the
    /// pre-stimulus interval and the stimulus-relative span the epoch covers.
    private func epochDescription(_ condition: Condition) -> String {
        guard condition.sampleCount > 0 else { return "—" }
        guard dataset.samplingRate > 0 else {
            return "\(condition.sampleCount) samples · \(condition.baselineSamples) pre-stimulus"
        }
        let start = Double(-condition.baselineSamples) / dataset.samplingRate * 1_000
        let end = Double(condition.sampleCount - 1 - condition.baselineSamples) / dataset.samplingRate * 1_000
        let baselineMs = Double(condition.baselineSamples) / dataset.samplingRate * 1_000
        return String(
            format: "%d samples · %.0f ms pre-stimulus (%d) · %.0f to %.0f ms",
            condition.sampleCount, baselineMs, condition.baselineSamples, start, end
        )
    }

    private var statusText: String {
        switch dataset.loadState {
        case .pending: "Pending"
        case .loading: "Loading…"
        case .loaded: "Loaded"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
