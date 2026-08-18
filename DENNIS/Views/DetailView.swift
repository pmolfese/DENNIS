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
    @Environment(AnalysisStore.self) private var store
    let selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            modeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pin the mode bar to the top; without this the whole stack is
        // vertically centered when the content doesn't fill the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modeBar: some View {
        HStack {
            Picker("Mode", selection: activeModeBinding) {
                ForEach(store.visibleModes) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear(perform: ensureVisibleMode)
        .onChange(of: store.visibleModes) { _, _ in ensureVisibleMode() }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch store.activeMode {
        case .pca:
            selectionContent
        case .tensor:
            if case .group(let id) = selection {
                TensorView(dataSource: .group(id)).id(id)
            } else if case .derived(let id) = selection {
                TensorView(dataSource: .derived(id)).id(id)
            } else {
                ContentUnavailableView(
                    "Tensor Mode",
                    systemImage: "cube.transparent",
                    description: Text("Select original or derived data in the sidebar to run tensor analysis.")
                )
            }
        case .decoding:
            if case .group(let id) = selection {
                DecodingView(source: .group(id)).id(id)
            } else if case .derived(let id) = selection {
                DecodingView(source: .derived(id)).id(id)
            } else {
                ContentUnavailableView(
                    "Decoding / Classification",
                    systemImage: "checkerboard.shield",
                    description: Text("Select original or derived data in the sidebar to run decoding.")
                )
            }
        case .waveform:
            if case .group(let id) = selection {
                WaveformAnalysisView(groupID: id).id(id)
            } else {
                ContentUnavailableView(
                    "Waveform Analysis",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Select a group in the sidebar to define waveform measurement windows.")
                )
            }
        case .pls:
            if case .group(let id) = selection {
                PLSView(groupID: id).id(id)
            } else {
                ContentUnavailableView(
                    "PLS Mode",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Select a group in the sidebar to run a mean-centered (task) PLS.")
                )
            }
        case .permutation:
            if case .group(let id) = selection {
                PermutationStatisticsView(groupID: id).id(id)
            } else {
                ContentUnavailableView(
                    "Permutation Statistics",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select a group in the sidebar to run a cluster-based permutation test. "
                                      + "Between-subject designs compare that group's immediate factor levels.")
                )
            }
        case .clustering:
            ContentUnavailableView(
                "Clustering Mode",
                systemImage: "circle.grid.cross",
                description: Text("Clustering analysis is coming soon.")
            )
        case .stats:
            StatisticalAnalysisView()
        }
    }

    private var activeModeBinding: Binding<AppMode> {
        Binding(
            get: { store.activeMode },
            set: { store.activeMode = $0 }
        )
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case .group(let id):
            PCAView(groupID: id).id(id)
        case .condition(let id):
            if let (dataset, condition) = findCondition(id) {
                ConditionDetail(dataset: dataset, condition: condition).id(condition.id)
            } else { placeholder }
        case .dataset(let id):
            if let dataset = findDataset(id) {
                DatasetDetail(dataset: dataset)
            } else { placeholder }
        case .derived(let id):
            if let item = store.derivedItem(id: id) {
                DerivedDataDetail(item: item)
            } else { placeholder }
        case .behavioral(let id):
            if let item = store.behavioralItem(id: id) {
                BehavioralDataDetail(item: item)
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

    private func ensureVisibleMode() {
        guard !store.visibleModes.contains(store.activeMode) else { return }
        store.activeMode = store.visibleModes.first ?? .pca
    }
}

private struct BehavioralDataDetail: View {
    let item: AnalysisStore.BehavioralDataItem

    private let columnWidth: CGFloat = 140

    private var previewRows: ArraySlice<[String]> {
        item.rows.prefix(500)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.largeTitle.bold())
                Text("\(item.rows.count) rows × \(item.headers.count) columns · \(item.sourceURL.lastPathComponent)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(item.headers.enumerated()), id: \.offset) { _, header in
                            tableCell(header, isHeader: true)
                        }
                    }
                    ForEach(Array(previewRows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            ForEach(item.headers.indices, id: \.self) { index in
                                tableCell(index < row.count ? row[index] : "", isHeader: false)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    }
                }
                .frame(minWidth: max(520, CGFloat(max(1, item.headers.count)) * (columnWidth + 16)), alignment: .topLeading)
                .padding(1)
            }
            .frame(minHeight: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
            if item.rows.count > 500 {
                Text("Showing first 500 rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func tableCell(_ value: String, isHeader: Bool) -> some View {
        Text(value)
            .font(isHeader ? .caption.weight(.semibold) : .caption.monospaced())
            .foregroundStyle(isHeader ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: columnWidth, height: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .background(isHeader ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .border(Color.secondary.opacity(0.12), width: 0.5)
    }
}

private struct DerivedDataDetail: View {
    let item: AnalysisStore.DerivedDataItem

    var body: some View {
        ContentUnavailableView {
            Label(item.name, systemImage: "square.stack.3d.forward.dottedline")
        } description: {
            Text("\(item.kind.rawValue)\n\(item.subjectNames.count) subjects × \(item.conditionNames.count) conditions · \(item.input.nChannels) channels × \(item.input.nTimes) samples")
        } actions: {
            Text(item.provenance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(.top, 60)
    }
}
