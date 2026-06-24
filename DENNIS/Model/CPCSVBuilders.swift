//
//  CPCSVBuilders.swift
//  DENNIS
//
//  CSV tables from a PARAFAC (CP) decomposition for statistical software. Modes
//  are addressed by index so the same builders serve the ERP 4-way tensor and
//  every time-frequency structure. The subject loadings carry the between-subject
//  design columns alongside, ready for an ANOVA / mixed model.
//

import Foundation

nonisolated enum CPCSVBuilders {

    /// One row per subject: design factor levels then a column per component.
    static func subjectLoadings(_ result: CPResult, subjectMode: Int, subjectNames: [String],
                                subjectLevels: [[String]], factorNames: [String]) -> String {
        let factor = result.factors[subjectMode]
        let header = ["Subject"] + factorNames + (0..<result.rank).map { "Comp\($0 + 1)" }
        var lines = [header.map(escape).joined(separator: ",")]
        for s in 0..<factor.rows {
            var row = [s < subjectNames.count ? subjectNames[s] : "s\(s + 1)"]
            let levels = s < subjectLevels.count ? subjectLevels[s] : []
            for f in factorNames.indices { row.append(f < levels.count ? levels[f] : "") }
            for r in 0..<result.rank { row.append(format(factor[s, r])) }
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// One row per level of a mode, one column per component.
    static func modeLoadings(_ result: CPResult, mode: Int, rowLabel: String,
                             names: (Int) -> String) -> String {
        let factor = result.factors[mode]
        var lines = [(([rowLabel] + (0..<result.rank).map { "Comp\($0 + 1)" }).map(escape).joined(separator: ","))]
        for i in 0..<factor.rows {
            var row = [names(i)]
            for r in 0..<result.rank { row.append(format(factor[i, r])) }
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6g", value) : ""
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
