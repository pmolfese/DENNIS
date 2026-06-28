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
            Section("Conditions") {
                ForEach(dataset.conditions) { condition in
                    LabeledContent(condition.name,
                                   value: condition.sampleCount > 0 ? "\(condition.sampleCount) samples" : "—")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dataset.name)
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
