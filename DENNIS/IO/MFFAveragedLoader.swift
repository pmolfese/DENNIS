//
//  MFFAveragedLoader.swift
//  DENNIS
//
//  Reads an *averaged* EGI `.mff` package: a single subject whose `signal1.bin`
//  holds one averaged segment per condition, concatenated end to end. The
//  `categories.xml` sidecar names each condition and gives its begin/end time
//  (in microseconds) within that concatenated signal, which is how we slice the
//  signal back into one waveform matrix per condition.
//

import Foundation

/// One condition (a `<cat>` entry in `categories.xml`) and the slice of the
/// concatenated average signal that belongs to it.
struct MFFCategory: Sendable {
    let name: String
    let beginTimeMicros: Double
    let endTimeMicros: Double
    /// Absolute event (stimulus) time in microseconds, if present.
    let eventBeginMicros: Double?
}

/// The fully-parsed contents of one averaged `.mff`: metadata plus per-condition
/// waveform matrices (`channels × samples`).
struct AveragedMFF: Sendable {
    struct ConditionData: Sendable {
        let name: String
        /// `channels × samples` for this condition's average.
        let samples: [[Float]]
        let sampleCount: Int
        /// Samples of pre-stimulus baseline (stimulus onset index within the
        /// slice), derived from `evtBegin − beginTime` in categories.xml.
        let baselineSamples: Int
    }

    let sourceURL: URL
    let subjectName: String
    let samplingRate: Double
    let channelCount: Int
    /// Top-down electrode positions for topomaps; nil if no sensorLayout.xml.
    let sensorLayout: SensorLayout?
    let conditions: [ConditionData]
}

enum AveragedMFFError: LocalizedError {
    case noCategories(URL)
    case sliceOutOfBounds(condition: String, requested: Range<Int>, available: Int)

    var errorDescription: String? {
        switch self {
        case .noCategories(let url):
            return "No categories.xml found in \(url.lastPathComponent); this does not look like an averaged MFF."
        case .sliceOutOfBounds(let condition, let requested, let available):
            return "Condition \(condition) maps to samples \(requested.lowerBound)..<\(requested.upperBound) but the signal only has \(available) samples."
        }
    }
}

nonisolated final class MFFAveragedLoader {
    private let reader = MFFReader()

    /// Inspect categories *without* loading the (potentially large) signal —
    /// used by the import sheet to preview conditions before committing.
    func inspectConditions(at url: URL) throws -> [String] {
        try withScopedAccess(to: url) {
            try parseCategories(in: url).map(\.name)
        }
    }

    /// Fully load a single averaged MFF, slicing the concatenated signal into
    /// one matrix per condition.
    func load(at url: URL) throws -> AveragedMFF {
        try withScopedAccess(to: url) {
            try loadUnscoped(at: url)
        }
    }

    /// Run `body` while holding security-scoped access to a sandbox URL (no-op
    /// for URLs that don't need it, e.g. in the simulator/preview).
    private func withScopedAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func loadUnscoped(at url: URL) throws -> AveragedMFF {
        let categories = try parseCategories(in: url)
        guard !categories.isEmpty else { throw AveragedMFFError.noCategories(url) }

        let signal = try reader.loadSignal(from: url)
        let sfreq = signal.samplingRate
        let totalSamples = signal.data.first?.count ?? 0
        let microsPerSample = 1_000_000.0 / sfreq

        let conditions = try categories.map { category -> AveragedMFF.ConditionData in
            let start = Int((category.beginTimeMicros / microsPerSample).rounded())
            let end = Int((category.endTimeMicros / microsPerSample).rounded())
            let clampedEnd = min(end, totalSamples)
            guard start >= 0, start < clampedEnd else {
                throw AveragedMFFError.sliceOutOfBounds(
                    condition: category.name,
                    requested: start..<max(start, end),
                    available: totalSamples
                )
            }
            let slice = signal.data.map { Array($0[start..<clampedEnd]) }
            // Stimulus onset within the slice, from evtBegin relative to the
            // segment's begin time. Clamp into the slice; 0 if unavailable.
            let baseline: Int
            if let eventBegin = category.eventBeginMicros {
                let onset = Int(((eventBegin - category.beginTimeMicros) / microsPerSample).rounded())
                baseline = min(max(onset, 0), clampedEnd - start)
            } else {
                baseline = 0
            }
            return AveragedMFF.ConditionData(
                name: category.name,
                samples: slice,
                sampleCount: clampedEnd - start,
                baselineSamples: baseline
            )
        }

        return AveragedMFF(
            sourceURL: url,
            subjectName: url.deletingPathExtension().lastPathComponent,
            samplingRate: sfreq,
            channelCount: signal.numberOfChannels,
            sensorLayout: SensorLayout.load(fromPackageContaining: signal.signalURL),
            conditions: conditions
        )
    }

    // MARK: - categories.xml

    func parseCategories(in packageURL: URL) throws -> [MFFCategory] {
        let url = packageURL.appendingPathComponent("categories.xml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AveragedMFFError.noCategories(packageURL)
        }

        let data = try Data(contentsOf: url)
        let document = try XMLDocument(data: data, options: [.documentTidyXML])
        guard let root = document.rootElement() else {
            throw AveragedMFFError.noCategories(packageURL)
        }

        var categories: [MFFCategory] = []
        for cat in elements(named: "cat", in: root) {
            guard let name = firstChildValue(named: "name", in: cat) else { continue }
            // Use the first segment's timing; averaged files have one "Average" segment.
            guard let segments = firstChild(named: "segments", in: cat),
                  let seg = elements(named: "seg", in: segments).first,
                  let beginText = firstChildValue(named: "beginTime", in: seg),
                  let endText = firstChildValue(named: "endTime", in: seg),
                  let begin = Double(beginText),
                  let end = Double(endText) else { continue }
            let eventBegin = firstChildValue(named: "evtBegin", in: seg).flatMap(Double.init)
            categories.append(MFFCategory(
                name: name,
                beginTimeMicros: begin,
                endTimeMicros: end,
                eventBeginMicros: eventBegin
            ))
        }
        return categories
    }

    // MARK: - XML helpers (namespace-agnostic)

    private func localName(_ element: XMLElement) -> String {
        (element.name ?? "").components(separatedBy: ":").last ?? ""
    }

    private func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    /// Direct children with the given local (namespace-stripped) name.
    private func elements(named name: String, in element: XMLElement) -> [XMLElement] {
        childElements(of: element).filter { localName($0) == name }
    }

    private func firstChild(named name: String, in element: XMLElement) -> XMLElement? {
        childElements(of: element).first { localName($0) == name }
    }

    private func firstChildValue(named name: String, in element: XMLElement) -> String? {
        firstChild(named: name, in: element)?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
