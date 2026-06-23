//
//  StudyImporter.swift
//  DENNIS
//
//  Turns dropped/opened URLs into an editable import plan, then commits them
//  into the Study. Folders are walked recursively to find `.mff` packages, and
//  the folder structure *above* each file is used to pre-fill between-subject
//  factor levels (e.g. `…/6mo/Monozygotic/x.mff` → ["6mo", "Monozygotic"]).
//
//  Categories are read eagerly (cheap, XML only) so the import sheet can preview
//  conditions; the heavy signal data is loaded asynchronously after confirm.
//

import Foundation
import Observation

/// The editable plan presented in the import sheet.
@Observable
final class ImportPlan {
    /// Editable factor names; positionally aligned with each candidate's levels.
    var factorNames: [String]
    var candidates: [ImportCandidate]

    init(factorNames: [String], candidates: [ImportCandidate]) {
        self.factorNames = factorNames
        self.candidates = candidates
    }

    var isEmpty: Bool { candidates.isEmpty }
    var validCandidates: [ImportCandidate] { candidates.filter(\.isValid) }
}

/// One file about to be imported, with editable factor levels.
@Observable
final class ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let subjectName: String
    let conditions: [String]
    /// Levels inferred from the folder path; editable in the sheet. Index-aligned
    /// with `ImportPlan.factorNames`.
    var levels: [String]
    let warning: String?

    init(url: URL, conditions: [String], levels: [String], warning: String?) {
        self.url = url
        self.subjectName = url.deletingPathExtension().lastPathComponent
        self.conditions = conditions
        self.levels = levels
        self.warning = warning
    }

    var isValid: Bool { warning == nil && !conditions.isEmpty }
}

@Observable
@MainActor
final class StudyImporter {
    private let loader = MFFAveragedLoader()

    /// Plain Sendable preview of one file, computed off the main actor.
    private struct RawCandidate: Sendable {
        let url: URL
        let conditions: [String]
        let levels: [String]
        let warning: String?
    }

    /// Build an import plan from dropped URLs: expand folders, infer factor
    /// levels from the folder tree, and read categories for preview. The heavy
    /// file work runs off-actor; the observable plan is built back on the main
    /// actor (where these `@Observable` types are isolated).
    func makePlan(from urls: [URL]) async -> ImportPlan {
        let loader = self.loader
        let (factorCount, raw): (Int, [RawCandidate]) = await Task.detached(priority: .userInitiated) {
            let packages = Self.expandToMFFPackages(urls)
            guard !packages.isEmpty else { return (0, []) }

            let (factorCount, levelsByURL) = Self.inferLevels(for: packages)
            let raw = packages.map { url -> RawCandidate in
                let levels = levelsByURL[url] ?? []
                do {
                    let conditions = try loader.inspectConditions(at: url)
                    return RawCandidate(url: url, conditions: conditions, levels: levels, warning: nil)
                } catch {
                    return RawCandidate(url: url, conditions: [], levels: levels,
                                        warning: error.localizedDescription)
                }
            }
            return (factorCount, raw)
        }.value

        let candidates = raw.map {
            ImportCandidate(url: $0.url, conditions: $0.conditions, levels: $0.levels, warning: $0.warning)
        }
        let names = (0..<factorCount).map { "Factor \($0 + 1)" }
        return ImportPlan(factorNames: names, candidates: candidates)
    }

    /// Commit valid candidates: align/extend the study's factors, create
    /// `pending` datasets, then kick off async signal loading.
    func commit(_ plan: ImportPlan, into study: Study) {
        let factors = study.ensureFactors(count: plan.factorNames.count)
        // Apply edited factor names onto the study's factor objects.
        for (index, name) in plan.factorNames.enumerated() where index < factors.count {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { factors[index].name = trimmed }
        }

        for candidate in plan.validCandidates {
            let dataset = Dataset(
                name: candidate.subjectName,
                sourceURL: candidate.url,
                conditions: candidate.conditions.map { Condition(name: $0) },
                levels: candidate.levels
            )
            study.add(dataset)
            load(dataset)
        }
    }

    /// Read the full averaged signal for one dataset and populate its conditions.
    func load(_ dataset: Dataset) {
        dataset.loadState = .loading
        let url = dataset.sourceURL
        let loader = self.loader
        Task {
            let result: Result<AveragedMFF, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try loader.load(at: url)) }
                catch { return .failure(error) }
            }.value

            switch result {
            case .success(let mff):
                dataset.samplingRate = mff.samplingRate
                dataset.channelCount = mff.channelCount
                dataset.sensorLayout = mff.sensorLayout
                for conditionData in mff.conditions {
                    if let condition = dataset.conditions.first(where: { $0.name == conditionData.name }) {
                        condition.samples = conditionData.samples
                        condition.sampleCount = conditionData.sampleCount
                        condition.baselineSamples = conditionData.baselineSamples
                    }
                }
                dataset.loadState = .loaded
            case .failure(let error):
                dataset.loadState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Folder expansion

    /// Recursively resolve dropped URLs into `.mff` package directories. A
    /// `.mff` is itself a directory, so we treat it as a leaf and don't descend.
    nonisolated static func expandToMFFPackages(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted { found.append(standardized) }
        }

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            if url.pathExtension.lowercased() == "mff" {
                add(url)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Walk the tree, treating any .mff directory as a leaf package.
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let child as URL in enumerator {
                    if child.pathExtension.lowercased() == "mff" {
                        add(child)
                        enumerator.skipDescendants()
                    }
                }
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Derive factor levels for each package from the folder components between
    /// the packages' common ancestor and the file. Falls back to the immediate
    /// parent folder name as a single factor when everything shares a directory.
    nonisolated static func inferLevels(for packages: [URL]) -> (factorCount: Int, levels: [URL: [String]]) {
        guard !packages.isEmpty else { return (0, [:]) }

        let parentComponents = packages.map { $0.deletingLastPathComponent().pathComponents }
        let minLen = parentComponents.map(\.count).min() ?? 0
        var common = 0
        for i in 0..<minLen {
            let value = parentComponents[0][i]
            if parentComponents.allSatisfy({ $0[i] == value }) { common += 1 } else { break }
        }

        var levels: [URL: [String]] = [:]
        var maxDepth = 0
        for (url, components) in zip(packages, parentComponents) {
            let tail = Array(components[common...])
            levels[url] = tail
            maxDepth = max(maxDepth, tail.count)
        }

        // Fallback: a flat folder of files yields no distinguishing levels, so
        // group by the immediate parent folder name.
        if maxDepth == 0 {
            for url in packages {
                levels[url] = [url.deletingLastPathComponent().lastPathComponent]
            }
            maxDepth = 1
        }

        // Pad shorter level lists so every candidate aligns with factorCount.
        for url in packages where (levels[url]?.count ?? 0) < maxDepth {
            var padded = levels[url] ?? []
            padded.append(contentsOf: Array(repeating: "", count: maxDepth - padded.count))
            levels[url] = padded
        }

        return (maxDepth, levels)
    }
}
