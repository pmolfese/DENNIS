//
//  DerivedDataExporter.swift
//  DENNIS
//
//  Long-form exports for derived datasets. Each row is one
//  subject × condition × channel × time sample.
//

import Foundation

nonisolated enum DerivedDataExporter {
    enum Format: String, CaseIterable, Sendable {
        case csv = "CSV"
        case tsv = "TSV"

        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .tsv: "tsv"
            }
        }

        var delimiter: String {
            switch self {
            case .csv: ","
            case .tsv: "\t"
            }
        }
    }

    struct Snapshot: Sendable {
        let name: String
        let kind: String
        let sourceGroupLabel: String
        let selectedFactorName: String
        let conditionNames: [String]
        let subjectNames: [String]
        let subjectLevels: [[String]]
        let factorNames: [String]
        let conditionMetadata: ConditionModeMetadata
        let input: EPTensor.Input
        let channelIndices: [Int]?

        init(item: AnalysisStore.DerivedDataItem) {
            name = item.name
            kind = item.kind.rawValue
            sourceGroupLabel = item.sourceGroupLabel
            selectedFactorName = item.selectedFactorName
            conditionNames = item.conditionNames
            subjectNames = item.subjectNames
            subjectLevels = item.subjectLevels
            factorNames = item.factorNames
            conditionMetadata = item.conditionMetadata
            input = item.input
            channelIndices = item.channelIndices
        }
    }

    static func table(_ item: AnalysisStore.DerivedDataItem, format: Format) -> String {
        table(Snapshot(item: item), format: format)
    }

    static func table(_ snapshot: Snapshot, format: Format) -> String {
        var buffer = ""
        appendTable(snapshot, format: format) { line in
            buffer += line
            buffer += "\n"
        }
        if buffer.last == "\n" { buffer.removeLast() }
        return buffer
    }

    static func write(_ snapshot: Snapshot, format: Format, to url: URL) throws {
        guard let stream = OutputStream(url: url, append: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        stream.open()
        defer { stream.close() }
        if let error = stream.streamError { throw error }

        var chunk = ""
        chunk.reserveCapacity(1_048_576)
        try appendTable(snapshot, format: format) { line in
            chunk += line
            chunk += "\n"
            if chunk.utf8.count >= 1_048_576 {
                try write(chunk, to: stream)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            if chunk.last == "\n" { chunk.removeLast() }
            try write(chunk, to: stream)
        }
    }

    private static func appendTable(
        _ snapshot: Snapshot,
        format: Format,
        emit: (String) throws -> Void
    ) rethrows {
        let input = snapshot.input
        var headers = [
            "DerivedData",
            "Kind",
            "SourceGroup",
            "SelectedFactor",
            "Subject"
        ]
        headers += snapshot.factorNames
        headers.append("Condition")
        headers += snapshot.conditionMetadata.factorNames
        headers += ["Channel", "TimeIndex", "Time_ms", "Value"]

        try emit(join(headers, format: format))
        for subjectIndex in 0..<input.subjects.count {
            let subject = subjectIndex < snapshot.subjectNames.count ? snapshot.subjectNames[subjectIndex] : "S\(subjectIndex + 1)"
            let betweenLevels = subjectIndex < snapshot.subjectLevels.count ? snapshot.subjectLevels[subjectIndex] : []
            for conditionIndex in 0..<input.subjects[subjectIndex].count {
                let condition = conditionIndex < snapshot.conditionNames.count ? snapshot.conditionNames[conditionIndex] : "c\(conditionIndex + 1)"
                let conditionLevels = conditionIndex < snapshot.conditionMetadata.levelsByCondition.count
                    ? snapshot.conditionMetadata.levelsByCondition[conditionIndex]
                    : []
                for channelIndex in 0..<input.subjects[subjectIndex][conditionIndex].count {
                    let series = input.subjects[subjectIndex][conditionIndex][channelIndex]
                    for timeIndex in 0..<series.count {
                        var row = [
                            snapshot.name,
                            snapshot.kind,
                            snapshot.sourceGroupLabel,
                            snapshot.selectedFactorName,
                            subject
                        ]
                        row += values(betweenLevels, count: snapshot.factorNames.count)
                        row.append(condition)
                        row += values(conditionLevels, count: snapshot.conditionMetadata.factorNames.count)
                        let sourceChannel = snapshot.channelIndices.flatMap {
                            channelIndex < $0.count ? $0[channelIndex] : nil
                        } ?? channelIndex
                        row += [
                            "\(sourceChannel + 1)",
                            "\(timeIndex)",
                            formatNumber(timeMS(index: timeIndex, input: input)),
                            formatNumber(Double(series[timeIndex]))
                        ]
                        try emit(join(row, format: format))
                    }
                }
            }
        }
    }

    private static func values(_ values: [String], count: Int) -> [String] {
        (0..<count).map { $0 < values.count ? values[$0] : "" }
    }

    private static func timeMS(index: Int, input: EPTensor.Input) -> Double {
        guard input.samplingRate > 0 else { return Double(index) }
        return (Double(index) - Double(input.baselineSamples)) / input.samplingRate * 1000
    }

    private static func join(_ fields: [String], format: Format) -> String {
        fields.map { escape($0, delimiter: format.delimiter) }.joined(separator: format.delimiter)
    }

    private static func formatNumber(_ value: Double) -> String {
        value.isFinite ? String(format: "%.9g", value) : ""
    }

    private static func escape(_ field: String, delimiter: String) -> String {
        if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func write(_ string: String, to stream: OutputStream) throws {
        let data = Data(string.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = stream.write(base.advanced(by: written), maxLength: data.count - written)
                if count < 0 {
                    throw stream.streamError ?? CocoaError(.fileWriteUnknown)
                }
                written += count
            }
        }
    }
}
