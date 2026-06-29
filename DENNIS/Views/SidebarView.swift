//
//  SidebarView.swift
//  DENNIS
//
//  The left-hand tree: nested between-subject groups (collapsible) → datasets
//  (subjects) → within-subject conditions. Accepts dropped MFF packages and
//  folders of them.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(Study.self) private var study
    @Environment(StudyImporter.self) private var importer
    @Binding var selection: SidebarSelection?

    /// Called with file/folder URLs dropped onto the sidebar.
    let onDropURLs: ([URL]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            CategoriesBar(selection: $selection)
            Group {
                if study.isEmpty {
                    emptyState
                } else {
                    tree
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDropURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
    }

    private var tree: some View {
        List(selection: $selection) {
            // A study-root row so the top-level folders can be compared too.
            if !study.factors.isEmpty {
                Label("All Subjects", systemImage: "person.3")
                    .fontWeight(.medium)
                    .tag(SidebarSelection.group(""))
            }
            ForEach(study.groupTree()) { node in
                GroupNodeView(node: node, selection: $selection)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Drop averaged MFF files or folders here")
                .font(.headline)
            Text("Each file is treated as one subject.\nFolder names become between-subject factors.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A collapsible grouping node. Recurses for sub-groups; renders datasets at
/// leaf level. The "_all" sentinel node (no factors) renders its datasets flat.
private struct GroupNodeView: View {
    let node: GroupNode
    @Binding var selection: SidebarSelection?

    var body: some View {
        if node.id == "_all" {
            ForEach(node.datasets) { dataset in
                DatasetNodeView(dataset: dataset, selection: $selection)
            }
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    GroupNodeView(node: child, selection: $selection)
                }
                ForEach(node.datasets) { dataset in
                    DatasetNodeView(dataset: dataset, selection: $selection)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(node.level).fontWeight(.medium)
                    Spacer()
                    Text("\(node.datasets.count + descendantCount(node.children))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help(node.factorName.isEmpty ? node.level : "\(node.factorName): \(node.level)")
                .tag(SidebarSelection.group(node.id))
            }
        }
    }

    private func descendantCount(_ nodes: [GroupNode]) -> Int {
        nodes.reduce(0) { $0 + $1.datasets.count + descendantCount($1.children) }
    }
}

/// A dataset (subject) and its within-subject conditions.
private struct DatasetNodeView: View {
    @Environment(Study.self) private var study
    @Environment(StudyImporter.self) private var importer
    let dataset: Dataset
    @Binding var selection: SidebarSelection?

    var body: some View {
        DisclosureGroup {
            ForEach(dataset.conditions) { condition in
                Label(condition.name, systemImage: "waveform.path")
                    .tag(SidebarSelection.condition(condition.id))
            }
        } label: {
            DatasetRow(dataset: dataset)
                .tag(SidebarSelection.dataset(dataset.id))
                .contextMenu {
                    Button("Reload") { importer.load(dataset) }
                    Button("Remove", role: .destructive) { study.removeDataset(dataset) }
                }
        }
    }
}

/// A dataset row showing its name and load status.
private struct DatasetRow: View {
    let dataset: Dataset

    var body: some View {
        HStack(spacing: 6) {
            Label(dataset.name, systemImage: "person.crop.square")
                .lineLimit(1)
            Spacer(minLength: 4)
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch dataset.loadState {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded:
            Text("\(dataset.channelCount) ch")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
