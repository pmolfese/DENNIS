//
//  CategoriesBar.swift
//  DENNIS
//
//  A horizontal strip across the top of the window listing every condition
//  (category) found across the loaded datasets — the union of the `<cat>`
//  entries from each MFF's `categories.xml`. Each chip can be deleted, which
//  removes that condition from every dataset in the study.
//

import SwiftUI

struct CategoriesBar: View {
    @Environment(Study.self) private var study

    /// The condition whose deletion is awaiting confirmation.
    @State private var pendingDeletion: String?

    var body: some View {
        let names = study.allConditionNames
        if !names.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Categories")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(names, id: \.self) { name in
                                chip(name)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()
            }
            .background(.bar)
            .confirmationDialog(
                "Delete category “\(pendingDeletion ?? "")”?",
                isPresented: deletionBinding,
                titleVisibility: .visible
            ) {
                Button("Delete from all subjects", role: .destructive) {
                    if let name = pendingDeletion { study.removeCondition(named: name) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                if let name = pendingDeletion {
                    Text("Removes “\(name)” from \(study.datasetCount(forCondition: name)) subject(s). This cannot be undone.")
                }
            }
        }
    }

    private func chip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .lineLimit(1)
            Text("\(study.datasetCount(forCondition: name))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                pendingDeletion = name
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete “\(name)” from all subjects")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}
