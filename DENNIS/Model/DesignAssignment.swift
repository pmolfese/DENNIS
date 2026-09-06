//
//  DesignAssignment.swift
//  DENNIS
//
//  Editable between-subject design table. It is used after import to reorganize
//  subjects into factors/levels without reloading signal data.
//

import Foundation
import Observation

@Observable
final class DesignAssignmentPlan: Identifiable {
    let id = UUID()
    var factorNames: [String]
    var rows: [DesignAssignmentRow]

    init(factorNames: [String], rows: [DesignAssignmentRow]) {
        self.factorNames = factorNames
        self.rows = rows
    }

    @MainActor
    convenience init(study: Study) {
        let names = study.factors.map(\.name)
        let rows = study.datasets.map { dataset in
            DesignAssignmentRow(
                datasetID: dataset.id,
                subjectName: dataset.name,
                sourceName: dataset.sourceURL.lastPathComponent,
                levels: DesignAssignmentPlan.padded(dataset.levels, count: names.count),
                conditionSummary: dataset.conditions.map(\.name).joined(separator: ", "),
                status: DesignAssignmentPlan.statusText(dataset.loadState)
            )
        }
        self.init(factorNames: names, rows: rows)
    }

    var factorCount: Int { factorNames.count }

    func addFactor() {
        factorNames.append("Factor \(factorNames.count + 1)")
        for row in rows { row.levels.append("") }
    }

    func removeFactor(at index: Int) {
        guard factorNames.indices.contains(index) else { return }
        factorNames.remove(at: index)
        for row in rows where index < row.levels.count {
            row.levels.remove(at: index)
        }
    }

    func moveFactor(from source: Int, to destination: Int) {
        guard factorNames.indices.contains(source),
              factorNames.indices.contains(destination),
              source != destination else { return }
        let name = factorNames.remove(at: source)
        factorNames.insert(name, at: destination)
        for row in rows {
            guard row.levels.indices.contains(source) else { continue }
            let value = row.levels.remove(at: source)
            row.levels.insert(value, at: min(destination, row.levels.count))
        }
    }

    func normalizeWidths() {
        for row in rows {
            row.levels = DesignAssignmentPlan.padded(row.levels, count: factorNames.count)
        }
    }

    private static func padded(_ levels: [String], count: Int) -> [String] {
        if levels.count == count { return levels }
        if levels.count > count { return Array(levels.prefix(count)) }
        return levels + Array(repeating: "", count: count - levels.count)
    }

    private static func statusText(_ state: LoadState) -> String {
        switch state {
        case .pending: "Pending"
        case .loading: "Loading"
        case .loaded: "Loaded"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

@Observable
final class DesignAssignmentRow: Identifiable {
    let id = UUID()
    let datasetID: UUID
    let subjectName: String
    let sourceName: String
    var levels: [String]
    let conditionSummary: String
    let status: String

    init(
        datasetID: UUID,
        subjectName: String,
        sourceName: String,
        levels: [String],
        conditionSummary: String,
        status: String
    ) {
        self.datasetID = datasetID
        self.subjectName = subjectName
        self.sourceName = sourceName
        self.levels = levels
        self.conditionSummary = conditionSummary
        self.status = status
    }
}
