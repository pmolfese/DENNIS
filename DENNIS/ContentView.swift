//
//  ContentView.swift
//  DENNIS
//
//  Root layout: a sidebar of grouped datasets/conditions on the left, a detail
//  pane on the right. Dropping (or opening) MFF files — or folders of them —
//  raises an import sheet that lets the user name between-subject factors and
//  assign levels before the files land in the tree.
//

import SwiftUI
import UniformTypeIdentifiers

/// What's currently selected in the sidebar.
enum SidebarSelection: Hashable {
    case group(String)      // group-node id (level path)
    case dataset(UUID)
    case condition(UUID)
    case derived(UUID)
    case behavioral(UUID)
}

struct ContentView: View {
    @Environment(Study.self) private var study
    @Environment(StudyImporter.self) private var importer
    @Environment(AnalysisStore.self) private var store

    @State private var selection: SidebarSelection?
    @State private var plan: ImportPlan?
    @State private var designPlan: DesignAssignmentPlan?
    @State private var tablePlan: TableImportPlan?
    @State private var showFileImporter = false

    var body: some View {
        splitView
        .sheet(item: $plan) { plan in
            ImportSheet(plan: plan) { confirmed in
                importer.commit(confirmed, into: study)
                if !confirmed.validCandidates.isEmpty {
                    selection = .group(study.factors.isEmpty ? "_all" : "")
                }
            }
        }
        .sheet(item: $designPlan) { plan in
            DesignEditorView(plan: plan) { confirmed in
                study.applyDesignAssignment(confirmed)
                selection = study.factors.isEmpty ? .group("_all") : .group("")
            }
        }
        .sheet(item: $tablePlan) { plan in
            TableImportSheet(plan: plan) { confirmed in
                importTables(confirmed)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.mffPackage, .folder, .commaSeparatedText, .tabSeparatedText, .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                handleDroppedURLs(urls)
            }
        }
        .onChange(of: store.requestedSelection) { _, requested in
            guard let requested else { return }
            selection = requested
            store.requestedSelection = nil
        }
        .alert("Table Import Failed", isPresented: Binding(
            get: { store.tableImportError != nil },
            set: { if !$0 { store.tableImportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.tableImportError ?? "")
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, onDropURLs: handleDroppedURLs)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack {
                            Button {
                                designPlan = DesignAssignmentPlan(study: study)
                            } label: {
                                Label("Edit Design", systemImage: "slider.horizontal.3")
                            }
                            .disabled(study.datasets.isEmpty)

                            Button {
                                showFileImporter = true
                            } label: {
                                Label("Add Files", systemImage: "plus")
                            }
                        }
                    }
                }
        } detail: {
            DetailView(selection: selection)
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        let tableURLs = urls.filter(Self.isTableURL)
        if !tableURLs.isEmpty {
            tablePlan = TableImportPlan(urls: tableURLs)
        }
        let eegURLs = urls.filter { !Self.isTableURL($0) }
        guard !eegURLs.isEmpty else { return }
        Task {
            let built = await importer.makePlan(from: eegURLs)
            guard !built.isEmpty else { return }
            plan = built
        }
    }

    private func importTables(_ plan: TableImportPlan) {
        let entries = plan.entries
        Task {
            var lastSelection: SidebarSelection?
            for entry in entries {
                do {
                    switch entry.kind {
                    case .derived:
                        let item = try await TableDataImporter.loadDerivedData(from: entry.url)
                        await MainActor.run {
                            store.addImportedDerivedData(item)
                            lastSelection = .derived(item.id)
                        }
                    case .behavioral:
                        let item = try await TableDataImporter.loadBehavioralData(from: entry.url)
                        await MainActor.run {
                            store.behavioralData.append(item)
                            lastSelection = .behavioral(item.id)
                        }
                    }
                } catch {
                    await MainActor.run {
                        store.tableImportError = "\(entry.url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run {
                if let lastSelection { selection = lastSelection }
            }
        }
    }

    nonisolated private static func isTableURL(_ url: URL) -> Bool {
        ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased())
    }
}

extension ImportPlan: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension UTType {
    /// EGI MFF recording package (a directory bundle).
    static var mffPackage: UTType {
        UTType(importedAs: "com.egi.mff")
    }
}

#Preview {
    ContentView()
        .environment(Study())
        .environment(StudyImporter())
        .environment(AnalysisStore())
}
