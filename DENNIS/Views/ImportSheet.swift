//
//  ImportSheet.swift
//  DENNIS
//
//  Shown when files/folders are dropped or opened. Lets the user name the
//  between-subject factors (pre-filled positionally from the folder structure)
//  and edit each file's factor levels before import. Conditions detected in each
//  file are previewed read-only.
//

import SwiftUI

struct ImportSheet: View {
    @Bindable var plan: ImportPlan
    let onConfirm: (ImportPlan) -> Void

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
        .frame(width: 680, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import \(plan.candidates.count) file\(plan.candidates.count == 1 ? "" : "s")")
                .font(.title3.bold())
            Text("Each file is one subject. Name the between-subject factors and "
                 + "confirm each file's levels — files sharing levels are pooled together.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Factor names

    private var factorEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Between-subject factors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(plan.factorNames.indices, id: \.self) { index in
                    HStack(spacing: 2) {
                        TextField("Factor \(index + 1)", text: factorBinding(index))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        if plan.factorNames.count > 1 {
                            Button {
                                removeFactor(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button {
                    plan.factorNames.append("Factor \(plan.factorNames.count + 1)")
                    for candidate in plan.candidates { candidate.levels.append("") }
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

    // MARK: - Table

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Subject").frame(width: 150, alignment: .leading)
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
                    .help("Auto-fill from file names using the levels you've already typed in this column.")
                }
                .frame(width: 110, alignment: .leading)
            }
            Text("Conditions").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Learn an extraction rule from the cells already filled in this column and
    /// fill the remaining blanks.
    private func autoFill(factor index: Int) {
        func level(_ candidate: ImportCandidate) -> String {
            index < candidate.levels.count ? candidate.levels[index] : ""
        }
        let labelled = plan.candidates
            .filter { !level($0).trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (name: $0.subjectName, value: level($0)) }
        let blanks = plan.candidates
            .filter { level($0).trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.subjectName)

        let inferred = LevelInference.fill(labelled: labelled, blanks: blanks)
        guard !inferred.isEmpty else { return }
        for candidate in plan.candidates where inferred[candidate.subjectName] != nil {
            while candidate.levels.count <= index { candidate.levels.append("") }
            candidate.levels[index] = inferred[candidate.subjectName]!
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(plan.candidates) { candidate in
                    CandidateRow(candidate: candidate, factorCount: plan.factorNames.count)
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            let skipped = plan.candidates.count - plan.validCandidates.count
            if skipped > 0 {
                Label("\(skipped) file(s) skipped", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Import \(plan.validCandidates.count)") {
                onConfirm(plan)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plan.validCandidates.isEmpty)
        }
        .padding()
    }

    // MARK: - Helpers

    private func displayFactorName(_ index: Int) -> String {
        let name = plan.factorNames[index].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Factor \(index + 1)" : name
    }

    private func factorBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < plan.factorNames.count ? plan.factorNames[index] : "" },
            set: { if index < plan.factorNames.count { plan.factorNames[index] = $0 } }
        )
    }

    private func removeFactor(at index: Int) {
        plan.factorNames.remove(at: index)
        for candidate in plan.candidates where index < candidate.levels.count {
            candidate.levels.remove(at: index)
        }
    }
}

private struct CandidateRow: View {
    @Bindable var candidate: ImportCandidate
    let factorCount: Int

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: candidate.isValid ? "doc.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(candidate.isValid ? Color.accentColor : .orange)
                Text(candidate.subjectName).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            ForEach(0..<factorCount, id: \.self) { index in
                TextField("—", text: levelBinding(index))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .disabled(!candidate.isValid)
            }

            Group {
                if let warning = candidate.warning {
                    Text(warning).foregroundStyle(.orange)
                } else {
                    Text(candidate.conditions.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
    }

    private func levelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < candidate.levels.count ? candidate.levels[index] : "" },
            set: {
                while candidate.levels.count <= index { candidate.levels.append("") }
                candidate.levels[index] = $0
            }
        )
    }
}
