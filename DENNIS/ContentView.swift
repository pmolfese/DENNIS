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
}

struct ContentView: View {
    @Environment(Study.self) private var study
    @Environment(StudyImporter.self) private var importer

    @State private var selection: SidebarSelection?
    @State private var plan: ImportPlan?
    @State private var showFileImporter = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, onDropURLs: handleDroppedURLs)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Add Files", systemImage: "plus")
                        }
                    }
                }
        } detail: {
            DetailView(selection: selection)
        }
        .sheet(item: $plan) { plan in
            ImportSheet(plan: plan) { confirmed in
                importer.commit(confirmed, into: study)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.mffPackage, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                handleDroppedURLs(urls)
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        Task {
            let built = await importer.makePlan(from: urls)
            guard !built.isEmpty else { return }
            plan = built
        }
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
