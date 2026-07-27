//
//  TableDataImporter.swift
//  DENNIS
//
//  Imports dropped CSV/TSV tables as either rehydrated derived EEG data or
//  generic behavioral data.
//

import Foundation

enum TableImportKind: String, CaseIterable, Identifiable {
    case derived = "Derived Data"
    case behavioral = "Behavioral Data"

    var id: String { rawValue }
}

@Observable
final class TableImportEntry: Identifiable {
    let id = UUID()
    let url: URL
    var kind: TableImportKind

    init(url: URL, kind: TableImportKind = .behavioral) {
        self.url = url
        self.kind = kind
    }
}

@Observable
final class TableImportPlan: Identifiable {
    let id = UUID()
    var entries: [TableImportEntry]

    init(urls: [URL]) {
        entries = urls.map { TableImportEntry(url: $0, kind: Self.defaultKind(for: $0)) }
    }

    private static func defaultKind(for url: URL) -> TableImportKind {
        if let headers = try? TableDataImporter.peekHeaders(url: url),
           TableDataImporter.looksLikeDerivedData(headers: headers) {
            return .derived
        }
        let filename = url.lastPathComponent.lowercased()
        if filename.contains("derived") || filename.contains("reconstructed") || filename.contains("tfsf") {
            return .derived
        }
        return .behavioral
    }
}

nonisolated enum TableDataImporter {
    struct ParsedTable: Sendable {
        let headers: [String]
        let rows: [[String]]
    }

    static func loadBehavioralData(from url: URL) async throws -> AnalysisStore.BehavioralDataItem {
        try await Task.detached(priority: .utility) {
            let table = try parse(url: url)
            return AnalysisStore.BehavioralDataItem(
                id: UUID(),
                name: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                headers: table.headers,
                rows: table.rows
            )
        }.value
    }

    static func loadDerivedData(from url: URL) async throws -> AnalysisStore.DerivedDataItem {
        try await Task.detached(priority: .utility) {
            let table = try parse(url: url)
            return try derivedItem(from: table, url: url)
        }.value
    }

    static func parse(url: URL) throws -> ParsedTable {
        let text = normalizedLineEndings(try String(contentsOf: url, encoding: .utf8))
        let delimiter = delimiter(for: url, text: text)
        let records = parseRecords(text, delimiter: delimiter)
        guard let header = records.first, !header.isEmpty else {
            throw ImportError.emptyTable
        }
        return ParsedTable(headers: cleanHeaders(header), rows: Array(records.dropFirst()))
    }

    static func peekHeaders(url: URL) throws -> [String] {
        let text = normalizedLineEndings(try String(contentsOf: url, encoding: .utf8))
        let delimiter = delimiter(for: url, text: text)
        guard let first = parseRecords(text, delimiter: delimiter).first else {
            throw ImportError.emptyTable
        }
        return cleanHeaders(first)
    }

    static func looksLikeDerivedData(headers: [String]) -> Bool {
        let set = Set(headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let required = ["deriveddata", "subject", "condition", "channel", "timeindex", "value"]
        return required.allSatisfy { set.contains($0) }
    }

    private static func derivedItem(from table: ParsedTable, url: URL) throws -> AnalysisStore.DerivedDataItem {
        let required = ["DerivedData", "Kind", "SourceGroup", "SelectedFactor", "Subject", "Condition", "Channel", "TimeIndex", "Time_ms", "Value"]
        let index = Dictionary(uniqueKeysWithValues: table.headers.enumerated().map { ($1, $0) })
        for header in required where index[header] == nil {
            throw ImportError.missingColumn(header)
        }

        let subjectColumn = index["Subject"]!
        let conditionColumn = index["Condition"]!
        let channelColumn = index["Channel"]!
        let timeColumn = index["TimeIndex"]!
        let valueColumn = index["Value"]!
        let unitColumn = index["Unit"]
        let fixedBeforeSubject = 5
        let conditionIndex = index["Condition"]!
        let channelIndex = index["Channel"]!
        let factorNames = Array(table.headers[fixedBeforeSubject..<conditionIndex])
        let conditionFactorNames = Array(table.headers[(conditionIndex + 1)..<channelIndex])

        var subjectNames: [String] = []
        var subjectMap: [String: Int] = [:]
        var conditionNames: [String] = []
        var conditionMap: [String: Int] = [:]
        var sourceChannels: [Int] = []
        var channelMap: [Int: Int] = [:]
        var maxTime = -1
        var values: [CellKey: Float] = [:]
        var subjectLevels: [[String]] = []
        var conditionLevels: [[String]] = []
        var timesMS: [Int: Double] = [:]
        var metadataName = url.deletingPathExtension().lastPathComponent
        var kind = AnalysisStore.DerivedKind.reconstructedDualFactor.rawValue
        var sourceGroup = ""
        var selectedFactor = ""
        var nativeUnit = AnalysisStore.DerivedDataItem.Unit.component

        for row in table.rows where !row.isEmpty {
            guard row.indices.contains(valueColumn),
                  let channel = Int(row[channelColumn]),
                  let time = Int(row[timeColumn]),
                  let value = Float(row[valueColumn]) else { continue }
            if let timeMSColumn = index["Time_ms"],
               row.indices.contains(timeMSColumn),
               let ms = Double(row[timeMSColumn]) {
                timesMS[time] = ms
            }
            if row.indices.contains(index["DerivedData"]!), !row[index["DerivedData"]!].isEmpty { metadataName = row[index["DerivedData"]!] }
            if row.indices.contains(index["Kind"]!), !row[index["Kind"]!].isEmpty { kind = row[index["Kind"]!] }
            if row.indices.contains(index["SourceGroup"]!) { sourceGroup = row[index["SourceGroup"]!] }
            if row.indices.contains(index["SelectedFactor"]!) { selectedFactor = row[index["SelectedFactor"]!] }
            if let unitColumn, row.indices.contains(unitColumn) {
                nativeUnit = unit(from: row[unitColumn])
            }

            let subject = row[subjectColumn]
            let subjectIndex = subjectMap[subject] ?? {
                let new = subjectNames.count
                subjectMap[subject] = new
                subjectNames.append(subject)
                subjectLevels.append(valuesAt(row, range: fixedBeforeSubject..<conditionIndex))
                return new
            }()

            let condition = row[conditionColumn]
            let conditionIndexValue = conditionMap[condition] ?? {
                let new = conditionNames.count
                conditionMap[condition] = new
                conditionNames.append(condition)
                conditionLevels.append(valuesAt(row, range: (conditionIndex + 1)..<channelIndex))
                return new
            }()

            let zeroBasedChannel = max(0, channel - 1)
            let outputChannel = channelMap[zeroBasedChannel] ?? {
                let new = sourceChannels.count
                channelMap[zeroBasedChannel] = new
                sourceChannels.append(zeroBasedChannel)
                return new
            }()

            maxTime = max(maxTime, time)
            values[CellKey(subject: subjectIndex, condition: conditionIndexValue, channel: outputChannel, time: time)] = value
        }

        guard !subjectNames.isEmpty, !conditionNames.isEmpty, !sourceChannels.isEmpty, maxTime >= 0 else {
            throw ImportError.emptyDerivedData
        }

        var subjects = Array(
            repeating: Array(
                repeating: Array(
                    repeating: Array(repeating: Float(0), count: maxTime + 1),
                    count: sourceChannels.count
                ),
                count: conditionNames.count
            ),
            count: subjectNames.count
        )
        for (key, value) in values {
            subjects[key.subject][key.condition][key.channel][key.time] = value
        }

        let channelIndices = sourceChannels == Array(0..<sourceChannels.count) ? nil : sourceChannels
        let timing = timingMetadata(timesMS: timesMS, nTimes: maxTime + 1)
        return AnalysisStore.DerivedDataItem(
            id: UUID(),
            name: metadataName,
            kind: AnalysisStore.DerivedKind(rawValue: kind) ?? .reconstructedDualFactor,
            sourceGroupID: sourceGroup,
            sourceGroupLabel: sourceGroup.isEmpty ? "Imported" : sourceGroup,
            selectedFactorName: selectedFactor,
            conditionNames: conditionNames,
            subjectNames: subjectNames,
            subjectLevels: subjectLevels,
            factorNames: factorNames,
            conditionMetadata: ConditionModeMetadata(factorNames: conditionFactorNames, levelsByCondition: conditionLevels),
            input: EPTensor.Input(
                nChannels: sourceChannels.count,
                nTimes: maxTime + 1,
                conditionCount: conditionNames.count,
                subjects: subjects,
                samplingRate: timing.samplingRate,
                baselineSamples: timing.baselineSamples
            ),
            channelIndices: channelIndices,
            nativeUnit: nativeUnit,
            microvoltScale: nil,
            factorPreview: nil,
            provenance: "Imported from \(url.lastPathComponent)."
        )
    }

    private static func unit(from raw: String) -> AnalysisStore.DerivedDataItem.Unit {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned == "µv" || cleaned == "uv" || cleaned.contains("microvolt") {
            return .microvolts
        }
        return .component
    }

    private struct CellKey: Hashable {
        let subject: Int
        let condition: Int
        let channel: Int
        let time: Int
    }

    private static func valuesAt(_ row: [String], range: Range<Int>) -> [String] {
        range.map { $0 < row.count ? row[$0] : "" }
    }

    private static func cleanHeaders(_ headers: [String]) -> [String] {
        headers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        }
    }

    private static func delimiter(for url: URL, text: String) -> Character {
        switch url.pathExtension.lowercased() {
        case "tsv":
            return "\t"
        case "csv":
            return ","
        default:
            let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? ""
            return firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
        }
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func timingMetadata(timesMS: [Int: Double], nTimes: Int) -> (samplingRate: Double, baselineSamples: Int) {
        let ordered = (0..<nTimes).compactMap { index in timesMS[index].map { (index, $0) } }
        let diffs = zip(ordered, ordered.dropFirst()).map { $1.1 - $0.1 }.filter { $0 > 0 }
        let step = diffs.sorted().dropFirst(diffs.count / 2).first ?? diffs.first ?? 0
        let samplingRate = step > 0 ? 1000 / step : 0
        let baseline = ordered.min(by: { abs($0.1) < abs($1.1) })?.0 ?? 0
        return (samplingRate, baseline)
    }

    private static func parseRecords(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                let next = text.index(after: i)
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    i = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if c == delimiter, !inQuotes {
                row.append(field)
                field.removeAll(keepingCapacity: true)
            } else if (c == "\n" || c == "\r"), !inQuotes {
                row.append(field)
                field.removeAll(keepingCapacity: true)
                if !row.allSatisfy(\.isEmpty) { rows.append(row) }
                row.removeAll(keepingCapacity: true)
                if c == "\r" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\n" { i = next }
                }
            } else {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        if !row.allSatisfy(\.isEmpty) { rows.append(row) }
        return rows
    }

    enum ImportError: LocalizedError {
        case emptyTable
        case missingColumn(String)
        case emptyDerivedData

        var errorDescription: String? {
            switch self {
            case .emptyTable:
                "The table is empty."
            case .missingColumn(let column):
                "Derived data import is missing the \(column) column."
            case .emptyDerivedData:
                "No derived data rows could be read."
            }
        }
    }
}
