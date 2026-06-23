//
//  DetailView.swift
//  DENNIS
//
//  Right-hand pane. Shows a grand-average view for a selected group, the
//  butterfly + topomap for a selected condition, or a summary for a dataset.
//  Scree and factor views will join here once the PCA engine lands.
//

import SwiftUI

struct DetailView: View {
    @Environment(Study.self) private var study
    let selection: SidebarSelection?

    var body: some View {
        switch selection {
        case .group(let id):
            GroupDetail(groupID: id).id(id)
        case .condition(let id):
            if let (dataset, condition) = findCondition(id) {
                ConditionDetail(dataset: dataset, condition: condition).id(condition.id)
            } else { placeholder }
        case .dataset(let id):
            if let dataset = findDataset(id) {
                DatasetDetail(dataset: dataset)
            } else { placeholder }
        case .none:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "waveform",
            description: Text("Select a group, dataset, or condition from the sidebar.")
        )
    }

    private func findDataset(_ id: UUID) -> Dataset? {
        study.datasets.first { $0.id == id }
    }

    private func findCondition(_ id: UUID) -> (Dataset, Condition)? {
        for dataset in study.datasets {
            if let condition = dataset.conditions.first(where: { $0.id == id }) {
                return (dataset, condition)
            }
        }
        return nil
    }
}

// MARK: - Group detail (info + grand average)

private struct GroupDetail: View {
    @Environment(Study.self) private var study
    let groupID: String

    enum OverlayMode: String, CaseIterable, Identifiable {
        case single = "Single", subgroups = "Subgroups", conditions = "Conditions"
        var id: String { rawValue }
    }

    @State private var selectedCondition: String?
    @State private var showPlot = false
    @State private var overlayMode: OverlayMode = .single
    @State private var showOverlayCentroid = false
    @State private var compareTopomaps = false
    @State private var cursorSample = 0
    @State private var topomapSample = 0
    @State private var topomapUpdateTask: Task<Void, Never>?

    private var members: [Dataset] { study.datasets(inGroupID: groupID) }
    private var conditionNames: [String] { study.sharedConditionNames(inGroupID: groupID) }
    private var children: [Study.ChildGroup] { study.childGroups(ofGroupID: groupID) }
    private var title: String {
        groupID.isEmpty ? study.name : (groupID.split(separator: "/").last.map(String.init) ?? groupID)
    }
    private var loadedCount: Int { members.filter { $0.loadState == .loaded }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoGrid
                Divider()
                grandAverageSection
            }
            .padding()
        }
        .navigationTitle(title)
        .onAppear {
            topomapSample = cursorSample
        }
        .onDisappear {
            topomapUpdateTask?.cancel()
            topomapUpdateTask = nil
        }
        .onChange(of: cursorSample) { _, newValue in
            scheduleTopomapUpdate(sample: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(groupID.isEmpty ? "All subjects" : groupID.replacingOccurrences(of: "/", with: " › "))
                .foregroundStyle(.secondary)
        }
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            GridRow {
                stat("Subjects", "\(members.count)")
                stat("Loaded", "\(loadedCount)/\(members.count)")
                stat("Conditions", "\(conditionNames.count)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var grandAverageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Grand Average").font(.headline)
                Spacer()
                if !showPlot {
                    Button {
                        if selectedCondition == nil { selectedCondition = conditionNames.first }
                        showPlot = true
                    } label: {
                        Label("Plot Grand Average", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0)
                }
            }

            if conditionNames.isEmpty {
                Text("No shared conditions across these subjects yet (still loading?).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if showPlot {
                Picker("Compare", selection: $overlayMode) {
                    Text("Single").tag(OverlayMode.single)
                    Text(children.isEmpty ? "Subgroups (none)" : "Subgroups").tag(OverlayMode.subgroups)
                    Text("Conditions").tag(OverlayMode.conditions)
                }
                .pickerStyle(.segmented)
                .onChange(of: overlayMode) { _, _ in cursorSample = 0 }

                // The condition picker is only relevant when not overlaying conditions.
                if overlayMode != .conditions {
                    Picker("Condition", selection: $selectedCondition) {
                        ForEach(conditionNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedCondition) { _, _ in cursorSample = 0 }
                }

                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch overlayMode {
        case .single:
            if let name = selectedCondition,
               let ga = GrandAverage.compute(datasets: members, condition: name) {
                grandAveragePlot(ga, condition: name)
            } else {
                unavailable("Couldn't compute a grand average for this condition.")
            }
        case .subgroups:
            if children.isEmpty {
                unavailable("This group has no sub-folders to compare. Select a parent folder, "
                            + "or use “Conditions”.")
            } else if let name = selectedCondition {
                overlayPlot(traces: subgroupTraces(condition: name),
                            caption: "\(name) · butterfly plot per sub-folder")
            }
        case .conditions:
            overlayPlot(traces: conditionTraces(),
                        caption: "Butterfly plot per condition · \(members.count) subjects")
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Overlay rendering

    @ViewBuilder
    private func overlayPlot(traces: [OverlayTrace], caption: String) -> some View {
        if traces.isEmpty {
            unavailable("Not enough loaded data to plot this comparison yet.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Toggle("Show centroid", isOn: $showOverlayCentroid)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("Compare Topomaps", isOn: $compareTopomaps)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                HStack(alignment: .top, spacing: 16) {
                    OverlayWaveformView(
                        traces: traces,
                        samplingRate: overlaySamplingRate,
                        baselineSamples: overlayBaseline,
                        showsCentroid: showOverlayCentroid,
                        cursorSample: cursorBinding(max: traces.map(\.sampleCount).max() ?? 1)
                    )
                    .frame(minHeight: 320)
                    .frame(maxWidth: .infinity)

                    overlayTopomaps(traces: traces)
                        .frame(width: compareTopomaps ? 340 : 320)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayTopomaps(traces: [OverlayTrace]) -> some View {
        let mappable = traces.filter { $0.sensorLayout != nil }
        if mappable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ContentUnavailableView("No Sensor Layout", systemImage: "circle.dashed")
            }
        } else {
            let scale = overlayTopomapScale(for: mappable)
            if compareTopomaps {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(mappable) { trace in
                            overlayTopomapCard(for: trace, scale: scale)
                        }
                    }
                }
            } else if let combined = combinedTopomapTrace(from: mappable) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    overlayTopomapCard(for: combined, scale: scale)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayTopomapCard(for trace: OverlayTrace, scale: Double) -> some View {
        if let layout = trace.sensorLayout {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Capsule().fill(trace.color).frame(width: 14, height: 3)
                    Text(trace.label).font(.caption.weight(.semibold))
                    Text("n=\(trace.contributing)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "t = %.3f s", overlaySamplingRate > 0 ? Double(topomapSample) / overlaySamplingRate : 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TopomapView(
                    layout: layout,
                    values: trace.samples.map { channel in
                        topomapSample < channel.count ? Double(channel[topomapSample]) : 0
                    },
                    timeSeconds: overlaySamplingRate > 0 ? Double(topomapSample) / overlaySamplingRate : 0,
                    fixedScale: scale,
                    showsHeader: false,
                    interpolationStep: compareTopomaps ? 6 : 7,
                    usesVerticalColorBar: true,
                    canvasMinHeight: compareTopomaps ? 190 : 230
                )
                .frame(height: compareTopomaps ? 250 : 290)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(trace.color.opacity(0.35), lineWidth: 1))
            }
        }
    }

    private func combinedTopomapTrace(from traces: [OverlayTrace]) -> OverlayTrace? {
        guard let first = traces.first else { return nil }
        let channelCount = first.samples.count
        let sampleCount = first.sampleCount
        guard channelCount > 0, sampleCount > 0 else { return nil }

        var weighted = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: channelCount
        )
        var totalWeight = 0
        for trace in traces {
            guard trace.samples.count == channelCount,
                  trace.samples.allSatisfy({ $0.count == sampleCount }) else { continue }
            let weight = max(trace.contributing, 1)
            totalWeight += weight
            for channelIndex in 0..<channelCount {
                for sampleIndex in 0..<sampleCount {
                    weighted[channelIndex][sampleIndex] += Double(trace.samples[channelIndex][sampleIndex]) * Double(weight)
                }
            }
        }
        guard totalWeight > 0 else { return nil }

        let samples = weighted.map { channel in
            channel.map { Float($0 / Double(totalWeight)) }
        }
        var centroid = [Float](repeating: 0, count: sampleCount)
        for sampleIndex in 0..<sampleCount {
            let total = samples.reduce(0.0) { partial, channel in
                partial + Double(channel[sampleIndex])
            }
            centroid[sampleIndex] = Float(total / Double(channelCount))
        }

        return OverlayTrace(
            id: "combined-topomap",
            label: "Combined",
            color: .secondary,
            samples: samples,
            centroid: centroid,
            contributing: totalWeight,
            sensorLayout: first.sensorLayout
        )
    }

    private func overlayTopomapScale(for traces: [OverlayTrace]) -> Double {
        let maxAbs = traces.reduce(0.0) { partial, trace in
            let values = trace.samples.compactMap { channel in
                topomapSample < channel.count ? Double(channel[topomapSample]) : nil
            }
            return max(partial, values.map(abs).max() ?? 0)
        }
        return maxAbs > 0 ? maxAbs : 1
    }

    private func scheduleTopomapUpdate(sample: Int) {
        topomapUpdateTask?.cancel()
        topomapUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                topomapSample = sample
            }
        }
    }

    /// One butterfly plot per immediate sub-folder, for a condition.
    private func subgroupTraces(condition name: String) -> [OverlayTrace] {
        children.enumerated().compactMap { index, child in
            guard let ga = GrandAverage.compute(datasets: child.datasets, condition: name) else { return nil }
            return OverlayTrace(
                id: child.id, label: child.label,
                color: OverlayWaveformView.palette[index % OverlayWaveformView.palette.count],
                samples: ga.samples,
                centroid: ga.centroid,
                contributing: ga.contributing,
                sensorLayout: ga.sensorLayout
            )
        }
    }

    /// One butterfly plot per condition, for this whole group.
    private func conditionTraces() -> [OverlayTrace] {
        conditionNames.enumerated().compactMap { index, name in
            guard let ga = GrandAverage.compute(datasets: members, condition: name) else { return nil }
            return OverlayTrace(
                id: name, label: name,
                color: OverlayWaveformView.palette[index % OverlayWaveformView.palette.count],
                samples: ga.samples,
                centroid: ga.centroid,
                contributing: ga.contributing,
                sensorLayout: ga.sensorLayout
            )
        }
    }

    /// Shared baseline/sfreq for overlays (taken from the first computable GA).
    private var overlayReference: GrandAverage? {
        switch overlayMode {
        case .conditions:
            return conditionNames.lazy.compactMap { GrandAverage.compute(datasets: members, condition: $0) }.first
        default:
            guard let name = selectedCondition else { return nil }
            return children.lazy.compactMap { GrandAverage.compute(datasets: $0.datasets, condition: name) }.first
                ?? GrandAverage.compute(datasets: members, condition: name)
        }
    }
    private var overlayBaseline: Int { overlayReference?.baselineSamples ?? 0 }
    private var overlaySamplingRate: Double { overlayReference?.samplingRate ?? 0 }

    private func grandAveragePlot(_ ga: GrandAverage, condition name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) · grand average of \(ga.contributing) subject\(ga.contributing == 1 ? "" : "s") "
                 + "· centroid shown bold")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                ERPWaveformView(
                    samples: ga.samples,
                    samplingRate: ga.samplingRate,
                    baselineSamples: ga.baselineSamples,
                    cursorSample: cursorBinding(max: ga.sampleCount),
                    centroid: ga.centroid
                )
                .frame(minHeight: 280)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let layout = ga.sensorLayout {
                        TopomapView(
                            layout: layout,
                            values: ga.samples.map { ch in
                                cursorSample < ch.count ? Double(ch[cursorSample]) : 0
                            },
                            timeSeconds: ga.samplingRate > 0 ? Double(cursorSample) / ga.samplingRate : 0,
                            fixedScale: nil,
                            usesVerticalColorBar: true
                        )
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                    } else {
                        ContentUnavailableView("No Sensor Layout", systemImage: "circle.dashed")
                    }
                }
                .frame(width: 300)
            }
        }
    }

    private func cursorBinding(max sampleCount: Int) -> Binding<Int> {
        Binding(
            get: { min(cursorSample, max(sampleCount - 1, 0)) },
            set: { cursorSample = $0 }
        )
    }
}

// MARK: - Condition detail (waveform + topomap)

private struct ConditionDetail: View {
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

private struct DatasetDetail: View {
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
