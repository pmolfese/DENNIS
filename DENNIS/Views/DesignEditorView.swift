//
//  DesignEditorView.swift
//  DENNIS
//
//  Reorganizes the study's between-subject factor structure after files have
//  been imported. Loaded EEG data is left untouched.
//

import SwiftUI

struct DesignEditorView: View {
    @Bindable var plan: DesignAssignmentPlan
    let onApply: (DesignAssignmentPlan) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            factorEditor
            Divider()
            columnHeader
            Divider()
            table
            Divider()
            footer
        }
        .frame(width: 860, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Study Design")
                .font(.title3.bold())
            Text("Edit between-subject factors and levels. Applying rearranges the sidebar tree without reimporting files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var factorEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Between-subject factors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(plan.factorNames.indices, id: \.self) { index in
                    HStack(spacing: 2) {
                        Button {
                            plan.moveFactor(from: index, to: index - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        .help("Move factor left")

                        TextField("Factor \(index + 1)", text: factorBinding(index))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)

                        Button {
                            plan.moveFactor(from: index, to: index + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == plan.factorNames.count - 1)
                        .help("Move factor right")

                        Button {
                            plan.removeFactor(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove factor")
                    }
                }

                Button {
                    plan.addFactor()
                } label: {
                    Label("Add Factor", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Subject").frame(width: 145, alignment: .leading)
            Text("File").frame(width: 160, alignment: .leading)
            ForEach(plan.factorNames.indices, id: \.self) { index in
                HStack(spacing: 3) {
                    Text(displayFactorName(index)).lineLimit(1)
                    Button {
                        autoFill(factor: index)
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("Auto-fill blanks from file and subject names using levels already typed in this column.")
                }
                .frame(width: 120, alignment: .leading)
            }
            Text("Conditions").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(plan.rows) { row in
                    DesignRowView(row: row, factorCount: plan.factorNames.count)
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(plan.rows.count) subject\(plan.rows.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Apply") {
                onApply(plan)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func autoFill(factor index: Int) {
        func level(_ row: DesignAssignmentRow) -> String {
            index < row.levels.count ? row.levels[index] : ""
        }
        let labelled = plan.rows
            .filter { !level($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .flatMap { row in
                [
                    (name: row.subjectName, value: level(row)),
                    (name: row.sourceName, value: level(row))
                ]
            }
        let blanks = plan.rows
            .filter { level($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .flatMap { [$0.subjectName, $0.sourceName] }

        let inferred = LevelInference.fill(labelled: labelled, blanks: blanks)
        guard !inferred.isEmpty else { return }
        for row in plan.rows where level(row).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = inferred[row.subjectName] ?? inferred[row.sourceName]
            guard let value else { continue }
            while row.levels.count <= index { row.levels.append("") }
            row.levels[index] = value
        }
    }

    private func displayFactorName(_ index: Int) -> String {
        let name = plan.factorNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Factor \(index + 1)" : name
    }

    private func factorBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < plan.factorNames.count ? plan.factorNames[index] : "" },
            set: { if index < plan.factorNames.count { plan.factorNames[index] = $0 } }
        )
    }
}

private struct DesignRowView: View {
    @Bindable var row: DesignAssignmentRow
    let factorCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(row.subjectName)
                .lineLimit(1)
                .frame(width: 145, alignment: .leading)

            Text(row.sourceName)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            ForEach(0..<factorCount, id: \.self) { index in
                TextField("Unassigned", text: levelBinding(index))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Text(row.conditionSummary.isEmpty ? row.status : row.conditionSummary)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
    }

    private func levelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < row.levels.count ? row.levels[index] : "" },
            set: {
                while row.levels.count <= index { row.levels.append("") }
                row.levels[index] = $0
            }
        )
    }
}

#Preview {
    let plan = DesignAssignmentPlan(
        factorNames: ["Age", "TwinType"],
        rows: [
            DesignAssignmentRow(datasetID: UUID(), subjectName: "1201m", sourceName: "1201m.mff", levels: ["12mo", "DZ"], conditionSummary: "ba, da", status: "Loaded"),
            DesignAssignmentRow(datasetID: UUID(), subjectName: "4201m", sourceName: "4201m.mff", levels: ["12mo", "MZ"], conditionSummary: "ba, da", status: "Loaded")
        ]
    )
    DesignEditorView(plan: plan) { _ in }
}
