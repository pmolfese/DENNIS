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

    @State private var mode: AppMode = .pca

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
            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .pca:
            selectionContent
        case .tensor:
            if case .group(let id) = selection {
                TensorView(groupID: id).id(id)
            } else {
                ContentUnavailableView(
                    "Tensor Mode",
                    systemImage: "cube.transparent",
                    description: Text("Select a group in the sidebar to run a 4-way PARAFAC analysis.")
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
