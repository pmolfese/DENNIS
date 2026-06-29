//
//  Study.swift
//  DENNIS
//
//  The in-memory model for an analysis session. A `Study` holds a flat list of
//  datasets (one averaged .mff = one subject) plus an ordered list of
//  between-subject factors (e.g. Age, TwinType). Each dataset carries a `levels`
//  array positionally aligned with those factors, so the sidebar can build a
//  nested, collapsible grouping tree on demand.
//
//  Persistence is intentionally out of scope for now — this all lives in memory.
//

import Foundation
import Observation

/// Loading lifecycle for a dataset's signal data.
enum LoadState: Equatable, Sendable {
    case pending          // known from categories, signal not yet read
    case loading
    case loaded
    case failed(String)
}

/// A between-subject grouping factor, e.g. "Age" or "TwinType".
@Observable
final class DesignFactor: Identifiable {
    let id = UUID()
    var name: String
    init(name: String) { self.name = name }
}

/// One within-subject condition (an MFF `<cat>`), e.g. "ba+".
@Observable
final class Condition: Identifiable {
    let id = UUID()
    var name: String
    /// `channels × samples`; nil until the parent dataset is loaded.
    var samples: [[Float]]?
    var sampleCount: Int
    /// Stimulus-onset sample index (pre-stimulus baseline length).
    var baselineSamples: Int

    init(name: String, samples: [[Float]]? = nil, sampleCount: Int = 0, baselineSamples: Int = 0) {
        self.name = name
        self.samples = samples
        self.sampleCount = sampleCount
        self.baselineSamples = baselineSamples
    }
}

/// One averaged `.mff` file — treated as a single subject.
@Observable
final class Dataset: Identifiable {
    let id = UUID()
    var name: String
    let sourceURL: URL
    var conditions: [Condition]
    var samplingRate: Double
    var channelCount: Int
    var sensorLayout: SensorLayout?
    var loadState: LoadState
    /// Between-subject factor levels, aligned by index with `Study.factors`,
    /// e.g. ["6mo", "Monozygotic"].
    var levels: [String]

    init(
        name: String,
        sourceURL: URL,
        conditions: [Condition] = [],
        samplingRate: Double = 0,
        channelCount: Int = 0,
        sensorLayout: SensorLayout? = nil,
        loadState: LoadState = .pending,
        levels: [String] = []
    ) {
        self.name = name
        self.sourceURL = sourceURL
        self.conditions = conditions
        self.samplingRate = samplingRate
        self.channelCount = channelCount
        self.sensorLayout = sensorLayout
        self.loadState = loadState
        self.levels = levels
    }
}

/// A node in the derived between-subject grouping tree. Leaf nodes carry the
/// datasets that fall into that combination of factor levels.
struct GroupNode: Identifiable {
    let id: String          // stable path key, e.g. "6mo/Monozygotic"
    let factorName: String  // the factor this level belongs to
    let level: String       // the level value, e.g. "6mo"
    var children: [GroupNode]
    var datasets: [Dataset]
}

/// Top-level session store. Injected into the SwiftUI environment.
@Observable
final class Study {
    var name: String
    var factors: [DesignFactor]
    var datasets: [Dataset]

    @ObservationIgnored private var derivedRevision = 0
    @ObservationIgnored private var conditionSummaryCache: (revision: Int, summary: ConditionSummary)?
    @ObservationIgnored private var groupTreeCache: (revision: Int, tree: [GroupNode])?
    @ObservationIgnored private var groupMembersCache: [String: (revision: Int, datasets: [Dataset])] = [:]
    @ObservationIgnored private var childGroupsCache: [String: (revision: Int, groups: [ChildGroup])] = [:]
    @ObservationIgnored private var sharedConditionsCache: [String: (revision: Int, names: [String])] = [:]

    private struct ConditionSummary {
        let names: [String]
        let counts: [String: Int]
    }

    init(name: String = "Untitled Study", factors: [DesignFactor] = [], datasets: [Dataset] = []) {
        self.name = name
        self.factors = factors
        self.datasets = datasets
    }

    var isEmpty: Bool { datasets.isEmpty }

    /// Ensure the study has at least `count` factors, creating generically-named
    /// ones as needed. Returns the (possibly extended) factor list.
    @discardableResult
    func ensureFactors(count: Int) -> [DesignFactor] {
        var changed = false
        while factors.count < count {
            factors.append(DesignFactor(name: "Factor \(factors.count + 1)"))
            changed = true
        }
        if changed { invalidateDerivedCache() }
        return factors
    }

    func add(_ dataset: Dataset) {
        datasets.append(dataset)
        invalidateDerivedCache()
    }

    func removeDataset(_ dataset: Dataset) {
        datasets.removeAll { $0.id == dataset.id }
        invalidateDerivedCache()
    }

    // MARK: - Conditions (categories)

    /// The union of all condition (category) names across every dataset, in
    /// first-seen order. These correspond to the `<cat>` entries in an MFF's
    /// `categories.xml`.
    var allConditionNames: [String] {
        conditionSummary().names
    }

    /// Number of datasets that contain a condition with the given name.
    func datasetCount(forCondition name: String) -> Int {
        conditionSummary().counts[name] ?? 0
    }

    /// Remove a condition (category) by name from every dataset that has it.
    func removeCondition(named name: String) {
        for dataset in datasets {
            dataset.conditions.removeAll { $0.name == name }
        }
        invalidateDerivedCache()
    }

    // MARK: - Derived grouping tree

    /// Build the nested grouping tree by walking `factors` in order. Datasets
    /// missing a level fall into an "Unassigned" bucket at that depth.
    func groupTree() -> [GroupNode] {
        if let cached = groupTreeCache, cached.revision == derivedRevision {
            return cached.tree
        }

        let tree: [GroupNode]
        guard !factors.isEmpty else {
            // No between-subject factors: a single flat list.
            tree = [GroupNode(id: "_all", factorName: "", level: "", children: [], datasets: datasets)]
            groupTreeCache = (derivedRevision, tree)
            return tree
        }
        tree = buildNodes(datasets: datasets, depth: 0, pathPrefix: "")
        groupTreeCache = (derivedRevision, tree)
        return tree
    }

    /// The level value used for grouping at a given factor depth, matching how
    /// `groupTree` labels nodes (empty/missing → "Unassigned").
    func resolvedLevel(_ dataset: Dataset, depth: Int) -> String {
        depth < dataset.levels.count && !dataset.levels[depth].isEmpty ? dataset.levels[depth] : "Unassigned"
    }

    /// All datasets falling under a group-node id (a "/"-joined level path).
    func datasets(inGroupID id: String) -> [Dataset] {
        if let cached = groupMembersCache[id], cached.revision == derivedRevision {
            return cached.datasets
        }

        let result: [Dataset]
        guard !factors.isEmpty, id != "_all" else {
            result = datasets
            groupMembersCache[id] = (derivedRevision, result)
            return result
        }
        let target = id.split(separator: "/").map(String.init)
        guard target.count <= factors.count else {
            groupMembersCache[id] = (derivedRevision, [])
            return []
        }
        result = datasets.filter { dataset in
            for (depth, level) in target.enumerated() where resolvedLevel(dataset, depth: depth) != level {
                return false
            }
            return true
        }
        groupMembersCache[id] = (derivedRevision, result)
        return result
    }

    /// One immediate child group (next factor level down) of a selected group.
    struct ChildGroup: Identifiable {
        let id: String
        let label: String
        let datasets: [Dataset]
    }

    /// Immediate sub-folders of a group: the distinct levels at the next factor
    /// depth, each with its datasets. Empty if the group is already a leaf. An
    /// empty id ("") means the whole study, whose children are the top-level
    /// factor levels.
    func childGroups(ofGroupID id: String) -> [ChildGroup] {
        if let cached = childGroupsCache[id], cached.revision == derivedRevision {
            return cached.groups
        }

        guard !factors.isEmpty, id != "_all" else {
            childGroupsCache[id] = (derivedRevision, [])
            return []
        }
        let components = id.isEmpty ? [] : id.split(separator: "/").map(String.init)
        let depth = components.count
        guard depth < factors.count else {
            childGroupsCache[id] = (derivedRevision, [])
            return []
        }

        let members = datasets(inGroupID: id)
        var order: [String] = []
        var buckets: [String: [Dataset]] = [:]
        for dataset in members {
            let level = resolvedLevel(dataset, depth: depth)
            if buckets[level] == nil { order.append(level) }
            buckets[level, default: []].append(dataset)
        }
        let groups = order.map { level in
            let childID = (components + [level]).joined(separator: "/")
            return ChildGroup(id: childID, label: level, datasets: buckets[level] ?? [])
        }
        childGroupsCache[id] = (derivedRevision, groups)
        return groups
    }

    /// Condition names shared by every dataset in a group (intersection),
    /// preserving the order seen in the first dataset.
    func sharedConditionNames(inGroupID id: String) -> [String] {
        if let cached = sharedConditionsCache[id], cached.revision == derivedRevision {
            return cached.names
        }

        let members = datasets(inGroupID: id)
        guard let first = members.first else {
            sharedConditionsCache[id] = (derivedRevision, [])
            return []
        }
        let ordered = first.conditions.map(\.name)
        let names = ordered.filter { name in
            members.allSatisfy { $0.conditions.contains { $0.name == name } }
        }
        sharedConditionsCache[id] = (derivedRevision, names)
        return names
    }

    private func conditionSummary() -> ConditionSummary {
        if let cached = conditionSummaryCache, cached.revision == derivedRevision {
            return cached.summary
        }

        var order: [String] = []
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for dataset in datasets {
            var datasetConditions = Set<String>()
            for condition in dataset.conditions {
                if seen.insert(condition.name).inserted {
                    order.append(condition.name)
                }
                datasetConditions.insert(condition.name)
            }
            for name in datasetConditions {
                counts[name, default: 0] += 1
            }
        }

        let summary = ConditionSummary(names: order, counts: counts)
        conditionSummaryCache = (derivedRevision, summary)
        return summary
    }

    private func invalidateDerivedCache() {
        derivedRevision += 1
        conditionSummaryCache = nil
        groupTreeCache = nil
        groupMembersCache.removeAll(keepingCapacity: true)
        childGroupsCache.removeAll(keepingCapacity: true)
        sharedConditionsCache.removeAll(keepingCapacity: true)
    }

    private func buildNodes(datasets: [Dataset], depth: Int, pathPrefix: String) -> [GroupNode] {
        guard depth < factors.count else { return [] }
        let factorName = factors[depth].name

        // Preserve first-seen order of levels rather than alphabetizing.
        var order: [String] = []
        var buckets: [String: [Dataset]] = [:]
        for dataset in datasets {
            let level = depth < dataset.levels.count && !dataset.levels[depth].isEmpty
                ? dataset.levels[depth]
                : "Unassigned"
            if buckets[level] == nil { order.append(level) }
            buckets[level, default: []].append(dataset)
        }

        return order.map { level in
            let members = buckets[level] ?? []
            let path = pathPrefix.isEmpty ? level : "\(pathPrefix)/\(level)"
            let isLeaf = depth == factors.count - 1
            return GroupNode(
                id: path,
                factorName: factorName,
                level: level,
                children: isLeaf ? [] : buildNodes(datasets: members, depth: depth + 1, pathPrefix: path),
                datasets: isLeaf ? members : []
            )
        }
    }
}
