//
//  TableImportSheet.swift
//  DENNIS
//
//  Lets dropped CSV/TSV tables be classified before import.
//

import SwiftUI

struct TableImportSheet: View {
    @Bindable var plan: TableImportPlan
    let onConfirm: (TableImportPlan) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Table Data")
                    .font(.title3.bold())
                Text("Choose whether each CSV/TSV contains reimported derived data or behavioral data for decoding, MVPA, and statistics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.entries) { entry in
                        HStack(spacing: 12) {
                            Label(entry.url.lastPathComponent, systemImage: "tablecells")
                                .lineLimit(1)
                            Spacer()
                            Picker("Type", selection: kindBinding(entry)) {
                                ForEach(TableImportKind.allCases) { kind in
                                    Text(kind.rawValue).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    onConfirm(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.entries.isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 360)
    }

    private func kindBinding(_ entry: TableImportEntry) -> Binding<TableImportKind> {
        Binding(
            get: { entry.kind },
            set: { entry.kind = $0 }
        )
    }
}
