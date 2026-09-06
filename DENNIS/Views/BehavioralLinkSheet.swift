//
//  BehavioralLinkSheet.swift
//  DENNIS
//
//  Links an imported behavioral table to EEG subjects by a selected subject
//  identifier column. The confirmed link is stored separately from the table so
//  users can relink without changing imported data.
//

import SwiftUI

struct BehavioralLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: AnalysisStore.BehavioralDataItem
    let subjectNames: [String]
    let existing: AnalysisStore.BehavioralLink?
    let onConfirm: (AnalysisStore.BehavioralLink) -> Void

    @State private var subjectColumn: String
    @State private var keyStrategy: AnalysisStore.BehavioralSubjectKey

    init(
        item: AnalysisStore.BehavioralDataItem,
        subjectNames: [String],
        existing: AnalysisStore.BehavioralLink?,
        onConfirm: @escaping (AnalysisStore.BehavioralLink) -> Void
    ) {
        self.item = item
        self.subjectNames = subjectNames
        self.existing = existing
        self.onConfirm = onConfirm
        let defaultColumn = existing?.subjectColumn
            ?? item.headers.first(where: { $0.localizedCaseInsensitiveContains("subject") })
            ?? item.headers.first
            ?? ""
        _subjectColumn = State(initialValue: defaultColumn)
        _keyStrategy = State(initialValue: existing?.keyStrategy ?? .caseInsensitive)
    }

    private var preview: BehavioralLinkPreview {
        BehavioralLinkPreview(item: item, subjectNames: subjectNames, subjectColumn: subjectColumn, keyStrategy: keyStrategy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link Behavioral Data")
                    .font(.title2.bold())
                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                Picker("Behavioral subject column", selection: $subjectColumn) {
                    ForEach(item.headers, id: \.self) { header in
                        Text(header).tag(header)
                    }
                }
                .frame(width: 280)

                Picker("Match", selection: $keyStrategy) {
                    ForEach(AnalysisStore.BehavioralSubjectKey.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }
                .frame(width: 180)
            }

            HStack(spacing: 22) {
                stat("Matched", "\(preview.matches.count)/\(subjectNames.count)")
                stat("Unmatched EEG", "\(preview.unmatchedSubjects.count)")
                stat("Extra Rows", "\(preview.extraRows.count)")
                stat("Duplicate IDs", "\(preview.duplicateKeys.count)")
            }

            HStack(alignment: .top, spacing: 16) {
                previewList("Matched EEG Subjects", rows: preview.matches.map { "\($0.subject) → row \($0.rowIndex + 1)" })
                previewList("Unmatched EEG Subjects", rows: preview.unmatchedSubjects)
                previewList("Extra Behavioral IDs", rows: preview.extraRows)
                previewList("Duplicate IDs", rows: preview.duplicateKeys)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Link") {
                    onConfirm(preview.link)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.matches.isEmpty || subjectColumn.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 520)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func previewList(_ title: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if rows.isEmpty {
                        Text("None")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(rows.prefix(250).enumerated()), id: \.offset) { _, row in
                            Text(row)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(width: 175, height: 290)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        }
    }
}

private struct BehavioralLinkPreview {
    struct Match {
        let subject: String
        let rowIndex: Int
    }

    let matches: [Match]
    let unmatchedSubjects: [String]
    let extraRows: [String]
    let duplicateKeys: [String]
    let link: AnalysisStore.BehavioralLink

    init(
        item: AnalysisStore.BehavioralDataItem,
        subjectNames: [String],
        subjectColumn: String,
        keyStrategy: AnalysisStore.BehavioralSubjectKey
    ) {
        let columnIndex = item.headers.firstIndex(of: subjectColumn)
        var rowsByKey: [String: [Int]] = [:]
        if let columnIndex {
            for (rowIndex, row) in item.rows.enumerated() where columnIndex < row.count {
                let key = keyStrategy.normalize(row[columnIndex])
                if !key.isEmpty { rowsByKey[key, default: []].append(rowIndex) }
            }
        }

        let duplicateKeys = rowsByKey
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        let duplicateSet = Set(duplicateKeys)
        var usedRows = Set<Int>()
        var matches: [Match] = []
        var unmatched: [String] = []
        var subjectToRow: [String: Int] = [:]
        for subject in subjectNames {
            let key = keyStrategy.normalize(subject)
            if let rows = rowsByKey[key], rows.count == 1, !duplicateSet.contains(key) {
                matches.append(Match(subject: subject, rowIndex: rows[0]))
                subjectToRow[subject] = rows[0]
                usedRows.insert(rows[0])
            } else {
                unmatched.append(subject)
            }
        }

        let extraRows = item.rows.enumerated().compactMap { rowIndex, row -> String? in
            guard !usedRows.contains(rowIndex), let columnIndex, columnIndex < row.count else { return nil }
            let value = row[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        self.matches = matches
        self.unmatchedSubjects = unmatched
        self.extraRows = extraRows
        self.duplicateKeys = duplicateKeys
        self.link = AnalysisStore.BehavioralLink(
            id: UUID(),
            tableID: item.id,
            subjectColumn: subjectColumn,
            keyStrategy: keyStrategy,
            subjectToRow: subjectToRow,
            unmatchedSubjects: unmatched,
            duplicateKeys: duplicateKeys
        )
    }
}
