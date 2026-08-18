//
//  PermutationStatisticsView.swift
//  DENNIS
//
//  The "Permutation Statistics" mode: spatiotemporal cluster-based permutation
//  testing over subjects (Maris & Oostenveld 2007) with an optional
//  threshold-free alternative (Smith & Nichols 2009).
//
//  Two UI decisions here are deliberate and load-bearing rather than cosmetic.
//  The cluster-forming threshold is entered as a *p* by default with a live
//  readout of the statistic it resolves to, because a fixed |t| means a
//  different p at every N and is only comparable within one analysis. And the
//  sensor neighborhood reports its mean degree, because a fragmented graph
//  splits one real effect into sub-threshold pieces while an over-connected one
//  merges distinct effects into a single uninterpretable blob.
//

import Charts
import SwiftUI

struct PermutationStatisticsView: View {
    @Environment(Study.self) private var study
    let groupID: String

    // Design. Both multi-selections are ordered by click, because the order is
    // the direction of the contrast: the first entry is the "A" of A − B.
    @State private var family: DesignFamily = .within
    @State private var withinConditions: [String] = []
    @State private var measureKind: MeasureKind = .mean
    @State private var measureA: String?
    @State private var measureB: String?
    @State private var measureMean: [String] = []
    @State private var selectedGroups: [String] = []
    @State private var groupSource: GroupSource = .factor(0)

    // Test settings
    @State private var windowStartMs: Double = 0
    @State private var windowEndMs: Double = 800
    @State private var windowInitialized = false
    @State private var sampleStride = 1
    @State private var permutationCount = 1_000
    @State private var alpha = 0.05
    @State private var inference: ClusterInferenceMode = .clusterMass
    @State private var tfce = TFCEParameters.default
    @State private var etac = ETACParameters.default
    @State private var usesProbabilityThreshold = true
    @State private var thresholdProbability = 0.05
    @State private var thresholdT = 2.0
    @State private var thresholdF = 4.0
    @State private var adjacency = ClusterAdjacencyConfiguration.default
    @State private var adjacencyInitialized = false

    // Run state
    @State private var output: ClusterPermutationOutput?
    @State private var statusMessage: String?
    @State private var isRunning = false
    @State private var progress = RunProgress()
    @State private var analysisTask: Task<Void, Never>?
    @State private var selectedClusterID: Int?
    @State private var showsStandardError = true
    @State private var showsEpochList = false

    /// Which question is being asked. The *statistic* is not a separate choice:
    /// two cells give a t, three or more give an omnibus F, and picking that for
    /// the user removes the commonest way to configure a test that silently
    /// refuses to run.
    enum DesignFamily: String, CaseIterable, Identifiable {
        case within = "Within subjects (conditions)"
        case between = "Between subjects (groups)"
        case mixed = "Interaction (contrast × groups)"

        var id: String { rawValue }
        var isBetween: Bool { self != .within }
    }

    /// What defines a between-subject group. One factor on its own gives that
    /// factor's main effect; the crossed cells give the omnibus over every cell
    /// of the between-subject design, which is how a factorial study gets
    /// tested without a mixed-model permutation scheme.
    enum GroupSource: Hashable {
        case factor(Int)
        case crossedCells
    }

    enum MeasureKind: String, CaseIterable, Identifiable {
        case condition = "One condition"
        case difference = "Difference (A − B)"
        case mean = "Mean of conditions"

        var id: String { rawValue }
    }

    // MARK: - Derived study facts

    private var members: [Dataset] { study.datasets(inGroupID: groupID) }
    private var conditionNames: [String] { study.sharedConditionNames(inGroupID: groupID) }
    private var groupLabel: String {
        groupID == "_all" || groupID.isEmpty ? "All Files" : groupID
    }

    /// One entry per between-subject cell defined by the current `groupSource`,
    /// in first-seen order. Levels come from `Study.resolvedLevel`, the same
    /// accessor the sidebar's grouping tree uses, so "Unassigned" behaves here
    /// exactly as it does there.
    private var analysisGroups: [(label: String, datasets: [Dataset])] {
        let factorCount = study.factors.count
        guard factorCount > 0 else { return [] }
        var order: [String] = []
        var buckets: [String: [Dataset]] = [:]
        for dataset in members {
            let label: String
            switch groupSource {
            case .factor(let index):
                guard index < factorCount else { continue }
                label = study.resolvedLevel(dataset, depth: index)
            case .crossedCells:
                label = (0..<factorCount)
                    .map { study.resolvedLevel(dataset, depth: $0) }
                    .joined(separator: " × ")
            }
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(dataset)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Groupings worth offering: any factor that actually varies among these
    /// subjects, plus the crossed cells when more than one factor does.
    private var availableGroupSources: [(label: String, source: GroupSource)] {
        var options: [(String, GroupSource)] = []
        var varying = 0
        for (index, factor) in study.factors.enumerated() {
            let levels = Set(members.map { study.resolvedLevel($0, depth: index) })
            guard levels.count >= 2 else { continue }
            varying += 1
            options.append((factor.name, .factor(index)))
        }
        if varying >= 2 {
            let names = study.factors.map(\.name).joined(separator: " × ")
            options.append(("\(names) (all cells)", .crossedCells))
        }
        return options
    }

    private var groupSourceName: String {
        availableGroupSources.first { $0.source == groupSource }?.label ?? "Groups"
    }

    private var sensorLayout: SensorLayout? {
        members.compactMap(\.sensorLayout).first
    }

    private var samplingRate: Double {
        members.first { $0.samplingRate > 0 }?.samplingRate ?? 0
    }

    /// Each subject's epoch geometry, computed exactly the way a run computes
    /// it. Subjects epoched with different pre-stimulus intervals are perfectly
    /// usable together — the analysis window is stimulus-relative — so this is
    /// shown for inspection rather than as a gate.
    private var epochSummaries: [ClusterEpochSummary] {
        let required = design?.requiredConditions ?? conditionNames
        guard !required.isEmpty, samplingRate > 0 else { return [] }
        return ClusterStatisticsRunner.epochSummaries(
            candidates: subjectSnapshots(),
            required: required,
            samplingRate: samplingRate
        )
    }

    /// The stimulus-relative interval every contributing subject can supply.
    private var availableWindowMs: ClosedRange<Double>? {
        let summaries = epochSummaries
        guard let lower = summaries.map(\.startMs).max(),
              let upper = summaries.map(\.endMs).min(),
              lower < upper else { return nil }
        return lower...upper
    }

    private var baselineSpread: (minimum: Double, maximum: Double)? {
        let baselines = epochSummaries.map(\.baselineMs)
        guard let minimum = baselines.min(), let maximum = baselines.max(),
              maximum - minimum > 1e-6 else { return nil }
        return (minimum, maximum)
    }

    private var analysisChannels: [Int] {
        guard let layout = sensorLayout else {
            return Array(0..<(members.first?.channelCount ?? 0))
        }
        let channelCount = members.first?.channelCount ?? 0
        let positions = Set(layout.positions.map(\.channelIndex))
        return (0..<channelCount).filter { positions.contains($0) }
    }

    // MARK: - Design assembly

    /// Selected cells that still exist, in click order.
    private var orderedSelectedGroups: [String] {
        let available = Set(analysisGroups.map(\.label))
        return selectedGroups.filter { available.contains($0) }
    }

    private var subjectMeasure: SubjectMeasure? {
        switch measureKind {
        case .condition:
            guard let measureA else { return nil }
            return .condition(measureA)
        case .difference:
            guard let measureA, let measureB, measureA != measureB else { return nil }
            return .difference(measureA, measureB)
        case .mean:
            let names = measureMean.filter { conditionNames.contains($0) }
            guard names.count >= 2 else { return nil }
            return .mean(names)
        }
    }

    private var design: ClusterDesign? {
        let groups = orderedSelectedGroups
        switch family {
        case .within:
            let names = withinConditions.filter { conditionNames.contains($0) }
            if names.count == 2 { return .withinPairedT(conditionA: names[0], conditionB: names[1]) }
            if names.count >= 3 { return .withinRepeatedF(conditions: names) }
            return nil
        case .between:
            guard let measure = subjectMeasure else { return nil }
            if groups.count == 2 { return .betweenT(measure: measure, groupA: groups[0], groupB: groups[1]) }
            if groups.count >= 3 { return .betweenF(measure: measure, groups: groups) }
            return nil
        case .mixed:
            guard let measure = subjectMeasure, groups.count >= 2 else { return nil }
            return .mixedInteraction(measure: measure, groups: groups)
        }
    }

    private var thresholdSpecification: ClusterFormingThreshold {
        if usesProbabilityThreshold { return .probability(thresholdProbability) }
        return .statistic(design?.statisticKind == .f ? thresholdF : thresholdT)
    }

    /// Degrees of freedom this run will produce, so the resolved critical value
    /// shown beside the threshold field is the one the test will actually use.
    private var previewedDegreesOfFreedom: (numerator: Double?, denominator: Double)? {
        guard let design else { return nil }
        let counts = plannedCellCounts
        guard !counts.isEmpty, counts.allSatisfy({ $0 >= 2 }) else { return nil }
        switch design {
        case .withinPairedT:
            return (nil, Double(counts[0] - 1))
        case .withinRepeatedF(let conditions):
            let units = counts[0]
            guard units > 1 else { return nil }
            return (Double(conditions.count - 1), Double((conditions.count - 1) * (units - 1)))
        case .betweenT:
            return (nil, Double(counts.reduce(0, +) - 2))
        case .betweenF, .mixedInteraction:
            guard counts.count >= 2 else { return nil }
            if counts.count == 2 { return (nil, Double(counts.reduce(0, +) - 2)) }
            return (Double(counts.count - 1), Double(counts.reduce(0, +) - counts.count))
        }
    }

    /// Subjects per cell as the run would count them: within-subject designs
    /// have one cell of matched subjects, between designs one cell per group.
    private var plannedCellCounts: [Int] {
        guard let design else { return [] }
        let required = design.requiredConditions
        let usable = members.filter { dataset in
            required.allSatisfy { name in
                dataset.conditions.contains { $0.name == name && ($0.samples?.isEmpty == false) }
            }
        }
        guard design.isWithinSubject == false else { return [usable.count] }
        var byGroup: [String: Int] = [:]
        for group in analysisGroups where selectedGroups.contains(group.label) {
            let ids = Set(group.datasets.map(\.id))
            byGroup[group.label] = usable.filter { ids.contains($0.id) }.count
        }
        return orderedSelectedGroups.map { byGroup[$0] ?? 0 }
    }

    private var previewedRearrangements: ClusterRearrangementPlan? {
        guard let design else { return nil }
        let counts = plannedCellCounts
        guard !counts.isEmpty, counts.allSatisfy({ $0 >= 2 }) else { return nil }
        let kind: ClusterRearrangementKind
        switch design {
        case .withinPairedT:
            kind = .signFlip(unitCount: counts[0])
        case .withinRepeatedF(let conditions):
            kind = .withinUnitRelabel(conditionCount: conditions.count, unitCount: counts[0])
        case .betweenT, .betweenF, .mixedInteraction:
            kind = .groupLabels(sizes: counts)
        }
        return ClusterRearrangements.plan(kind, requestedCount: permutationCount)
    }

    private var previewedCriticalValue: Double? {
        guard usesProbabilityThreshold, inference == .clusterMass,
              let design, let degrees = previewedDegreesOfFreedom else { return nil }
        switch design.statisticKind {
        case .t:
            return ClusterStatisticsDistributions.criticalT(
                twoTailedAlpha: thresholdProbability,
                degreesOfFreedom: degrees.denominator
            )
        case .f:
            guard let numerator = degrees.numerator else { return nil }
            return ClusterStatisticsDistributions.criticalF(
                alpha: thresholdProbability,
                numeratorDegreesOfFreedom: numerator,
                denominatorDegreesOfFreedom: degrees.denominator
            )
        }
    }

    private var previewedAdjacency: ClusterAdjacencySummary? {
        guard sensorLayout != nil, !analysisChannels.isEmpty else { return nil }
        let configuration: ClusterAdjacencyConfiguration
        if inference == .etac, let spacing = previewedNearestNeighborSpacing {
            configuration = ClusterAdjacencyConfiguration(
                method: .distance,
                distance: min((etac.orderedRadiusMultipliers.last ?? 1) * spacing, 2)
            )
        } else {
            configuration = adjacency
        }
        return ClusterSpatialAdjacency.summarize(
            ClusterSpatialAdjacency.build(
                channelIndices: analysisChannels,
                layout: sensorLayout,
                configuration: configuration
            )
        )
    }

    private var previewedNearestNeighborSpacing: Double? {
        ClusterSpatialAdjacency.medianNearestNeighborDistance(
            channelIndices: analysisChannels,
            layout: sensorLayout
        )
    }

    private var canRun: Bool {
        guard let design, design.isValid, !isRunning else { return false }
        let counts = plannedCellCounts
        guard !counts.isEmpty, counts.allSatisfy({ $0 >= 2 }) else { return false }
        guard (inference == .etac || adjacency.isValid),
              windowEndMs > windowStartMs,
              permutationCount > 0,
              sampleStride > 0 else {
            return false
        }
        if inference == .tfce { return tfce.isValid }
        if inference == .etac { return etac.isValid }
        if usesProbabilityThreshold { return thresholdProbability > 0 && thresholdProbability < 1 }
        return (design.statisticKind == .f ? thresholdF : thresholdT) > 0
    }

    /// Anything that would make an already-computed result stale.
    private struct Invalidation: Equatable {
        let designName: String
        let conditions: [String]
        let groups: [String]
        let window: [Double]
        let stride: Int
        let permutations: Int
        let threshold: ClusterFormingThreshold
        let inference: ClusterInferenceMode
        let tfce: TFCEParameters
        let etac: ETACParameters
        let adjacency: ClusterAdjacencyConfiguration
        let subjects: [String]
    }

    private var invalidation: Invalidation {
        Invalidation(
            designName: design?.name ?? "",
            conditions: (design?.conditionNames ?? []) + (design?.requiredConditions ?? []),
            groups: design?.groupNames ?? [],
            window: [windowStartMs, windowEndMs],
            stride: sampleStride,
            permutations: permutationCount,
            threshold: thresholdSpecification,
            inference: inference,
            tfce: tfce,
            etac: etac,
            adjacency: adjacency,
            subjects: members.map(\.name)
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if members.isEmpty {
                    ContentUnavailableView(
                        "No Subjects",
                        systemImage: "person.slash",
                        description: Text("This group contains no datasets.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else if conditionNames.isEmpty {
                    ContentUnavailableView(
                        "No Shared Conditions",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("The subjects in this group share no condition, so nothing can be compared.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    designCard
                    if let output {
                        results(output)
                    } else if let statusMessage {
                        Label(statusMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else {
                        ContentUnavailableView(
                            "Configure a Comparison",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text(emptyStateText)
                        )
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            seedSelections()
            seedWindowIfNeeded()
            seedAdjacencyIfNeeded()
        }
        .onChange(of: invalidation) { _, _ in
            seedSelections()
            invalidateResult()
        }
        .onDisappear { cancelRun(clearStatus: false) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Permutation Statistics").font(.largeTitle.bold())
            Text("\(groupLabel) · \(members.count) subject\(members.count == 1 ? "" : "s") · "
                 + "\(conditionNames.count) shared condition\(conditionNames.count == 1 ? "" : "s")"
                 + (analysisGroups.isEmpty ? "" : " · \(analysisGroups.count) \(groupSourceName) cell\(analysisGroups.count == 1 ? "" : "s")"))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyStateText: String {
        switch family {
        case .within:
            return "Choose two conditions for a paired test, or three or more for the omnibus. Every subject must have all of them."
        case .between:
            return "Choose the per-subject measure, then two groups for a t-test or three or more for the omnibus F."
        case .mixed:
            return "Choose a within-subject contrast and at least two groups. Comparing that contrast between groups is the interaction."
        }
    }

    // MARK: - Design card

    private var designCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Spatiotemporal Cluster Permutation Test").font(.headline)
                        HelpButton(text: Self.methodHelp)
                    }
                    Text(designSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(analysisChannels.count) channels")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Channels with coordinates in the sensor layout. Spatial adjacency is "
                          + "undefined without them, so channels the layout cannot place are excluded.")
                referencesButton
            }

            HStack(alignment: .bottom, spacing: 14) {
                labeled("Design", help: Self.methodHelp) {
                    Picker("", selection: $family) {
                        ForEach(DesignFamily.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 168).disabled(isRunning)
                }
                .help(design?.explanation ?? "Choose the exchangeability scheme that matches your design.")

                if family.isBetween {
                    measureControls
                    groupMenu
                } else {
                    orderedConditionMenu(
                        "Conditions",
                        help: Self.withinConditionsHelp,
                        selection: $withinConditions
                    )
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 14) {
                numericField("Start ms", value: $windowStartMs, width: 78, help: Self.windowHelp)
                numericField("End ms", value: $windowEndMs, width: 78)
                    .help("End of the analysis window, in ms after stimulus onset.")
                labeled("Sample stride", help: Self.strideHelp) {
                    Stepper("\(sampleStride)", value: $sampleStride, in: 1...16)
                        .frame(width: 84).disabled(isRunning)
                }
                .help("Keeps every Nth sample. Changes the temporal lattice clusters grow on, not just plot resolution.")
                labeled("Correction", help: Self.correctionHelp) {
                    Picker("", selection: $inference) {
                        ForEach(ClusterInferenceMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 132).disabled(isRunning)
                }
                .help(inference.explanation)
                if inference == .etac {
                    labeled("Sensor radius basis", help: Self.etacHelp) {
                        Text(previewedNearestNeighborSpacing.map {
                            "median nearest = \(String(format: "%.3f", $0)) r"
                        } ?? "time only — no layout")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 156, alignment: .leading)
                    }
                } else {
                    labeled("Sensor neighbors", help: Self.neighborsHelp) {
                        Picker("", selection: $adjacency.method) {
                            ForEach(ClusterAdjacencyMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 132)
                        .disabled(isRunning || sensorLayout == nil)
                    }
                    .help(adjacency.method.explanation)
                    adjacencyParameter
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 14) {
                labeled("Permutations", help: Self.permutationsHelp) {
                    Picker("", selection: $permutationCount) {
                        Text("1,000 · quick").tag(1_000)
                        Text("5,000").tag(5_000)
                        Text("10,000 · final").tag(10_000)
                    }
                    .labelsHidden().frame(width: 132).disabled(isRunning)
                }
                inferenceControls
                labeled("Cluster α", help: Self.alphaHelp) {
                    Picker("", selection: $alpha) {
                        Text(".001").tag(0.001)
                        Text(".0025").tag(0.0025)
                        Text(".005").tag(0.005)
                        Text(".01").tag(0.01)
                        Text(".025").tag(0.025)
                        Text(".05").tag(0.05)
                        Text(".10").tag(0.10)
                    }
                    .labelsHidden().frame(width: 70)
                    .onChange(of: alpha) { _, newAlpha in
                        selectedClusterID = output?.clusters(at: newAlpha).first?.id
                    }
                }
                .help("Corrected p a cluster must beat. Re-filters existing results without another run.")
                Spacer(minLength: 6)
                if isRunning {
                    Button("Cancel", role: .cancel) { cancelRun(clearStatus: true) }
                } else {
                    Button("Run Test") { runAnalysis() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRun)
                        .help(canRun
                              ? "Runs the permutation test across all available CPU cores. Results are deterministic for a given seed."
                              : "Complete the design first: every cell needs at least two subjects, and the window must fit inside every epoch.")
                }
            }

            if isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: min(max(progress.fraction, 0), 1)).frame(maxWidth: 320)
                    Text(progress.stage).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            statusRow
            epochList

            HStack(alignment: .top, spacing: 4) {
                Text(interpretationCaveat)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HelpButton(text: Self.interpretationHelp).imageScale(.small).font(.caption2)
            }

            if design?.statisticKind == .f {
                Text("The omnibus F indicates that at least one cell differs; it does not say which. Run a two-cell test separately for a follow-up contrast.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var referencesButton: some View {
        ReferencesButton(
            title: "References",
            intro: "The methods implemented in this pane. Journal, volume and pages are "
                + "given so each source can be located directly.",
            references: References.forCluster
        )
    }

    private var designSubtitle: String {
        guard let design else { return "Subjects are the exchangeable unit." }
        let correction: String
        switch inference {
        case .clusterMass: correction = "maximum cluster-mass correction"
        case .tfce: correction = "threshold-free cluster enhancement"
        case .etac: correction = "multi-threshold, multi-radius ETAC-EEG correction"
        }
        return "\(design.name) · \(correction)"
    }

    private var interpretationCaveat: String {
        switch inference {
        case .clusterMass:
            return "Corrected p-values apply to whole clusters. Their member sensors and time samples should not be interpreted as independently significant or as precise spatial or temporal boundaries."
        case .tfce:
            return "TFCE corrects each channel × time point against the permutation distribution of the largest enhanced score. Points listed together below are a readability grouping, not the inference unit."
        case .etac:
            return "ETAC-EEG corrects the union of cluster subtests across the displayed p thresholds and montage-relative sensor radii. Listed regions group overlapping surviving subtest clusters for readability; their points are not independent significance claims or precise boundaries."
        }
    }

    private var statusRow: some View {
        HStack(spacing: 14) {
            if sensorLayout == nil {
                Label("No sensor layout: temporal clusters only", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let summary = previewedAdjacency {
                Label(
                    inference == .etac
                        ? String(format: "%.1f neighbors at broadest ETAC radius", summary.meanNeighborCount)
                        : String(format: "%.1f neighbors per sensor", summary.meanNeighborCount),
                    systemImage: summary.isDegenerate || summary.isOverConnected
                        ? "exclamationmark.triangle"
                        : "point.3.connected.trianglepath.dotted"
                )
                .foregroundStyle(summary.isDegenerate || summary.isOverConnected ? Color.orange : .secondary)
                .help(adjacencyHelp(summary))
            }
            if let available = availableWindowMs {
                Label("Window available \(formatMs(available.lowerBound)) to \(formatMs(available.upperBound)) ms",
                      systemImage: "clock")
                    .help("Relative to stimulus onset, across every contributing subject. "
                          + "Each subject is indexed through its own pre-stimulus interval, so epochs "
                          + "of different lengths still contribute the same stimulus-relative samples.")
            }
            if let spread = baselineSpread {
                Label(
                    "Pre-stimulus \(formatMs(spread.minimum))–\(formatMs(spread.maximum)) ms across subjects",
                    systemImage: "info.circle"
                )
                .help("These files were epoched with different pre-stimulus intervals. That is fine here: "
                      + "the window below is measured from stimulus onset, so each subject is indexed "
                      + "through its own baseline. See the epoch list for the per-subject values.")
            }
            if let plan = previewedRearrangements {
                Label(plan.summary, systemImage: plan.isExhaustive ? "checkmark.seal" : "dice")
                    .help(plan.isExhaustive
                          ? "Every distinct rearrangement is evaluated, so the p-values are exact and the smallest attainable p is 1/\(plan.count)."
                          : "Sampled without replacement from a null too large to enumerate; the smallest attainable p is 1/\(plan.count + 1).")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The per-subject epoch geometry, on demand. Opened by default when the
    /// baselines disagree, since that is when someone needs to look.
    @ViewBuilder
    private var epochList: some View {
        let summaries = epochSummaries
        if !summaries.isEmpty {
            DisclosureGroup(isExpanded: $showsEpochList) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("Subject")
                        Text("Pre-stimulus")
                        Text("Samples")
                        Text("Covers")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(summaries) { epoch in
                        GridRow {
                            Text(epoch.subject).lineLimit(1)
                            Text("\(formatMs(epoch.baselineMs)) ms (\(epoch.baselineSamples))")
                            Text("\(epoch.sampleCount)")
                            Text("\(formatMs(epoch.startMs)) to \(formatMs(epoch.endMs)) ms")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            baselineSpread != nil && epoch.baselineSamples != summaries[0].baselineSamples
                                ? Color.orange
                                : .secondary
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 3) {
                    Text("Epoch layout · \(summaries.count) subject\(summaries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HelpButton(text: Self.epochHelp).imageScale(.small).font(.caption2)
                }
            }
            .onAppear { if baselineSpread != nil { showsEpochList = true } }
        }
    }

    @ViewBuilder
    private var adjacencyParameter: some View {
        switch adjacency.method {
        case .distance:
            labeled("Radius") {
                TextField("", value: $adjacency.distance, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                    .disabled(isRunning || sensorLayout == nil)
            }
            .help("Fraction of the head radius. Sensors closer than this are neighbors.")
        case .nearestNeighbors:
            labeled("K") {
                Stepper("\(adjacency.neighborCount)", value: $adjacency.neighborCount, in: 1...32)
                    .frame(width: 80).disabled(isRunning || sensorLayout == nil)
            }
        case .temporalOnly:
            EmptyView()
        }
    }

    private var thresholdControl: some View {
        let isF = design?.statisticKind == .f
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(usesProbabilityThreshold ? "Cluster-forming p" : (isF ? "Cluster F" : "Cluster |t|"))
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(text: Self.thresholdHelp).imageScale(.small).font(.caption2)
                Button { toggleThresholdMode() } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(isRunning)
                .help(usesProbabilityThreshold
                      ? "Switch to entering the raw statistic."
                      : "Switch to an uncorrected p, converted to the critical statistic for this design's degrees of freedom.")
            }
            HStack(spacing: 5) {
                if usesProbabilityThreshold {
                    TextField("", value: $thresholdProbability, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder).frame(width: 68).disabled(isRunning)
                    if let critical = previewedCriticalValue {
                        Text("= \(isF ? "F" : "|t|") \(String(format: "%.2f", critical))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    TextField("", value: isF ? $thresholdF : $thresholdT,
                              format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 68).disabled(isRunning)
                }
            }
        }
    }

    @ViewBuilder
    private var inferenceControls: some View {
        switch inference {
        case .clusterMass:
            thresholdControl
        case .tfce:
            tfceControls
        case .etac:
            etacControls
        }
    }

    private var tfceControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            labeled("TFCE E", help: Self.correctionHelp) {
                TextField("", value: $tfce.extentExponent, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 58).disabled(isRunning)
            }
            .help("Extent exponent. 0.5 is the Smith & Nichols default.")
            labeled("TFCE H") {
                TextField("", value: $tfce.heightExponent, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 58).disabled(isRunning)
            }
            .help("Height exponent. 2.0 is the Smith & Nichols default.")
            labeled("Steps") {
                Stepper("\(tfce.stepCount)", value: $tfce.stepCount, in: 2...500, step: 10)
                    .frame(width: 88).disabled(isRunning)
            }
        }
    }

    private var etacControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(etac.thresholdProbabilities.indices, id: \.self) { index in
                    labeled("Cluster p\(index + 1)", help: index == 0 ? Self.etacHelp : nil) {
                        TextField(
                            "",
                            value: Binding(
                                get: { etac.thresholdProbabilities[index] },
                                set: { etac.thresholdProbabilities[index] = $0 }
                            ),
                            format: .number.precision(.fractionLength(3))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .disabled(isRunning)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(etac.radiusMultipliers.indices, id: \.self) { index in
                    labeled("Radius \(index + 1) × NN") {
                        TextField(
                            "",
                            value: Binding(
                                get: { etac.radiusMultipliers[index] },
                                set: { etac.radiusMultipliers[index] = $0 }
                            ),
                            format: .number.precision(.fractionLength(2))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .disabled(isRunning || sensorLayout == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var measureControls: some View {
        labeled("Subject measure", help: Self.measureHelp) {
            Picker("", selection: $measureKind) {
                ForEach(MeasureKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 160).disabled(isRunning || family == .mixed)
        }
        .help(family == .mixed
              ? "An interaction compares a within-subject contrast between groups, so the measure is fixed to a difference."
              : "Collapses each subject to one channel × time map before the groups are compared. "
                + "\"Mean of conditions\" pools over stimulus type and tests the group effect on its own.")

        switch measureKind {
        case .condition:
            conditionPicker("Condition", selection: $measureA)
        case .difference:
            conditionPicker("A", selection: $measureA)
            Text("−").font(.title3).foregroundStyle(.secondary).padding(.bottom, 5)
            conditionPicker("B", selection: $measureB)
        case .mean:
            orderedConditionMenu("Averaged over", help: nil, selection: $measureMean)
        }
    }

    /// Multi-select whose *order* is the click order, so the user controls the
    /// direction of a two-cell contrast rather than inheriting an arbitrary one.
    private func orderedConditionMenu(
        _ title: String,
        help: String?,
        selection: Binding<[String]>
    ) -> some View {
        labeled(title, help: help) {
            Menu {
                Button("Select all") { selection.wrappedValue = conditionNames }
                Button("Clear") { selection.wrappedValue = [] }
                Divider()
                ForEach(conditionNames, id: \.self) { name in
                    Button {
                        if let index = selection.wrappedValue.firstIndex(of: name) {
                            selection.wrappedValue.remove(at: index)
                        } else {
                            selection.wrappedValue.append(name)
                        }
                    } label: {
                        Label(orderedLabel(name, in: selection.wrappedValue),
                              systemImage: selection.wrappedValue.contains(name) ? "checkmark" : "circle")
                    }
                }
            } label: {
                Text(selection.wrappedValue.isEmpty
                     ? "Choose…"
                     : selection.wrappedValue.joined(separator: selection.wrappedValue.count == 2 ? " − " : ", "))
                    .lineLimit(1)
                    .frame(width: 172, alignment: .leading)
            }
            .menuStyle(.borderlessButton).frame(width: 188).disabled(isRunning)
        }
    }

    private func orderedLabel(_ name: String, in selection: [String]) -> String {
        guard let index = selection.firstIndex(of: name) else { return name }
        return selection.count == 2
            ? "\(name)  (\(index == 0 ? "A" : "B"))"
            : "\(name)  (\(index + 1))"
    }

    @ViewBuilder
    private var groupMenu: some View {
        let sources = availableGroupSources
        labeled("Group by", help: Self.groupHelp) {
            Picker("", selection: $groupSource) {
                ForEach(sources, id: \.source) { option in
                    Text(option.label).tag(option.source)
                }
            }
            .labelsHidden().frame(width: 168)
            .disabled(isRunning || sources.count < 2)
        }
        .help("One factor on its own tests that factor's main effect. The crossed cells let you "
              + "compare every combination — or tick just the two cells you want, such as "
              + "6mo × MZ against 6mo × DZ.")

        labeled("Compare cells") {
            Menu {
                if analysisGroups.isEmpty {
                    Text("No between-subject factors are defined for these subjects")
                }
                Button("Select all") { selectedGroups = analysisGroups.map(\.label) }
                Button("Clear") { selectedGroups = [] }
                Divider()
                ForEach(analysisGroups, id: \.label) { group in
                    Button {
                        if let index = selectedGroups.firstIndex(of: group.label) {
                            selectedGroups.remove(at: index)
                        } else {
                            selectedGroups.append(group.label)
                        }
                    } label: {
                        Label("\(orderedLabel(group.label, in: orderedSelectedGroups)) — n=\(group.datasets.count)",
                              systemImage: selectedGroups.contains(group.label) ? "checkmark" : "circle")
                    }
                }
            } label: {
                Text(orderedSelectedGroups.isEmpty
                     ? "Choose…"
                     : orderedSelectedGroups.joined(separator: orderedSelectedGroups.count == 2 ? " vs " : ", "))
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)
            }
            .menuStyle(.borderlessButton).frame(width: 196)
            .disabled(isRunning || analysisGroups.isEmpty)
        }
        .help("Tick two cells for a t-test, or three or more for the omnibus F. "
              + "Cells you leave unticked are excluded from the run entirely.")
    }

    private func conditionPicker(_ title: String, selection: Binding<String?>) -> some View {
        labeled(title) {
            Picker("", selection: selection) {
                Text("Choose…").tag(String?.none)
                ForEach(conditionNames, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden().frame(width: 146).disabled(isRunning)
        }
    }

    private func conditionMenu(_ title: String, selection: Binding<Set<String>>) -> some View {
        labeled(title) {
            Menu {
                Button("Select all") { selection.wrappedValue = Set(conditionNames) }
                Divider()
                ForEach(conditionNames, id: \.self) { name in
                    Button {
                        if selection.wrappedValue.contains(name) {
                            selection.wrappedValue.remove(name)
                        } else {
                            selection.wrappedValue.insert(name)
                        }
                    } label: {
                        Label(name, systemImage: selection.wrappedValue.contains(name) ? "checkmark" : "circle")
                    }
                }
            } label: {
                Text("\(selection.wrappedValue.intersection(Set(conditionNames)).count) selected")
                    .frame(width: 122, alignment: .leading)
            }
            .menuStyle(.borderlessButton).frame(width: 138).disabled(isRunning)
        }
    }

    /// A captioned control. Passing `help` adds a "?" popover beside the
    /// caption; hover tooltips stay on the control itself, so the two layers
    /// don't compete — the tooltip says what the setting does, the popover says
    /// why it matters and what to cite.
    private func labeled<Content: View>(
        _ title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                if let help {
                    HelpButton(text: help)
                        .imageScale(.small)
                        .font(.caption2)
                }
            }
            content()
        }
    }

    private func numericField(
        _ title: String,
        value: Binding<Double>,
        width: CGFloat,
        help: String? = nil
    ) -> some View {
        labeled(title, help: help) {
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder).frame(width: width).disabled(isRunning)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ output: ClusterPermutationOutput) -> some View {
        let significant = output.clusters(at: alpha)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Text(cellSummary(output.analysis)).font(.subheadline.weight(.semibold))
                Text("\(significant.count) cluster\(significant.count == 1 ? "" : "s") at p ≤ \(formatP(alpha))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(significant.isEmpty ? .secondary : Color.accentColor)
                Spacer()
            }
            Text(methodSummary(output))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help("Everything needed to describe this run in a methods section. Selectable — copy it directly.")

            if !output.excludedSubjects.isEmpty {
                Label(
                    "Excluded \(output.excludedSubjects.count) subject\(output.excludedSubjects.count == 1 ? "" : "s"): "
                    + output.excludedSubjects.map { "\($0.name) (\($0.reason))" }.joined(separator: "; "),
                    systemImage: "person.fill.xmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .help("Subjects lacking a condition the design requires. They are never padded with "
                      + "zeros or silently dropped — excluding a subject changes the design, so it is reported.")
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Observed \(output.analysis.statistic.rawValue) map")
                        .font(.caption.weight(.semibold))
                    Text("Channels ↓ · time → · saturated cells belong to corrected clusters")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Every channel × time point's statistic. Faded points did not survive correction. "
                              + "Click any saturated point to select the cluster it belongs to.")
                    ClusterStatisticHeatmap(
                        analysis: output.analysis,
                        clusters: significant,
                        selectedClusterID: selectedClusterID,
                        onSelectCluster: { selectedClusterID = $0 }
                    )
                    .frame(minWidth: 480, maxWidth: .infinity, minHeight: 250)
                }
                clusterList(output, clusters: significant).frame(width: 300, height: 300)
            }

            if let cluster = selectedCluster(in: output) {
                Divider()
                clusterDetail(cluster, output: output)
            } else if significant.isEmpty {
                ContentUnavailableView(
                    "No Corrected Clusters",
                    systemImage: "checkmark.circle",
                    description: Text("No spatiotemporal cluster met the corrected p-value threshold.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func clusterList(_ output: ClusterPermutationOutput,
                             clusters: [SpatiotemporalCluster]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Corrected clusters").font(.caption.weight(.semibold))
                .help("Clusters passing the corrected α, most significant first. "
                      + "Latency and sensor counts describe the cluster; they are not claims about "
                      + "the effect's true onset, offset, or extent.")
            if clusters.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(clusters) { cluster in
                            Button { selectedClusterID = cluster.id } label: {
                                clusterRow(cluster, output: output)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func clusterRow(_ cluster: SpatiotemporalCluster,
                            output: ClusterPermutationOutput) -> some View {
        let isF = output.analysis.statistic == .f
        return HStack(spacing: 8) {
            Image(systemName: isF ? "chart.bar.fill" : (cluster.sign > 0 ? "arrow.up.right" : "arrow.down.right"))
                .foregroundStyle(isF ? Color.purple : (cluster.sign > 0 ? Color.red : Color.blue))
            VStack(alignment: .leading, spacing: 1) {
                Text("Cluster \(cluster.id + 1) · p = \(formatP(cluster.pValue))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text("\(latencyText(cluster.startSample, output: output))–\(latencyText(cluster.endSample, output: output)) ms · \(cluster.channelIndices.count) ch · mass \(String(format: "%.1f", cluster.mass))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if cluster.pValue <= alpha {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selectedClusterID == cluster.id ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private func clusterDetail(_ cluster: SpatiotemporalCluster,
                               output: ClusterPermutationOutput) -> some View {
        let globalChannels = cluster.channelIndices.compactMap {
            output.channelIndices.indices.contains($0) ? output.channelIndices[$0] : nil
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cluster \(cluster.id + 1)").font(.headline)
                Text(directionText(cluster, output: output))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(output.analysis.statistic == .f
                                     ? Color.purple
                                     : (cluster.sign > 0 ? Color.red : Color.blue))
                Text("corrected p = \(formatP(cluster.pValue)) · \(latencyText(cluster.startSample, output: output))–\(latencyText(cluster.endSample, output: output)) ms")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Toggle("Standard error", isOn: $showsStandardError)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Shades ±1 standard error across subjects — the meaningful error bar for a group "
                          + "test. Note a within-subject test removes between-subject variance, so these "
                          + "bands can look wide even for a strong paired effect.")
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ClusterTraceChart(
                        output: output,
                        cluster: cluster,
                        alpha: alpha,
                        showsStandardError: showsStandardError
                    )
                    .frame(minWidth: 460, maxWidth: .infinity)
                    .frame(height: 260)

                    savePNGButton("cluster\(cluster.id + 1)_waveform") {
                        ClusterTraceChart(
                            output: output,
                            cluster: cluster,
                            alpha: alpha,
                            showsStandardError: showsStandardError
                        )
                        .frame(width: 640, height: 340)
                    }
                    .help(showsStandardError
                          ? "Saves the waveform with the ±1 SEM band currently shown."
                          : "Saves the waveform. Turn on \"Standard error\" first to include the band.")
                }

                if let layout = sensorLayout {
                    VStack(spacing: 2) {
                        Text("Mean \(output.analysis.statistic.rawValue) over the cluster window")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("The statistic averaged across the cluster's time span. Ringed sensors are "
                                  + "the cluster's members — a descriptive extent, not a localisation claim.")
                        TopomapView(
                            layout: layout,
                            values: statisticTopography(cluster: cluster, output: output),
                            timeSeconds: midLatencySeconds(cluster, output: output),
                            fixedScale: nil,
                            showsHeader: false,
                            usesVerticalColorBar: true,
                            canvasMinHeight: 190,
                            unitLabel: output.analysis.statistic.rawValue,
                            highlightedChannels: Set(globalChannels),
                            usesPositiveSequentialScale: output.analysis.statistic == .f
                        )
                        .frame(width: 290, height: 250)

                        savePNGButton("cluster\(cluster.id + 1)_topomap_\(output.analysis.statistic.rawValue.lowercased())") {
                            TopomapView(
                                layout: layout,
                                values: statisticTopography(cluster: cluster, output: output),
                                timeSeconds: midLatencySeconds(cluster, output: output),
                                fixedScale: nil,
                                usesVerticalColorBar: true,
                                unitLabel: output.analysis.statistic.rawValue,
                                highlightedChannels: Set(globalChannels),
                                usesPositiveSequentialScale: output.analysis.statistic == .f
                            )
                            .frame(width: 360, height: 360)
                        }
                    }
                }
            }

            Text("Cluster sensors (\(globalChannels.count)): "
                 + globalChannels.map { "E\($0 + 1)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).textSelection(.enabled)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func directionText(_ cluster: SpatiotemporalCluster,
                               output: ClusterPermutationOutput) -> String {
        guard output.analysis.statistic == .t, output.analysis.seriesNames.count == 2 else {
            return "Omnibus effect"
        }
        let (a, b) = (output.analysis.seriesNames[0], output.analysis.seriesNames[1])
        return cluster.sign > 0 ? "\(a) > \(b)" : "\(a) < \(b)"
    }

    private func selectedCluster(in output: ClusterPermutationOutput) -> SpatiotemporalCluster? {
        let significant = output.clusters(at: alpha)
        if let selectedClusterID,
           let match = significant.first(where: { $0.id == selectedClusterID }) {
            return match
        }
        return significant.first
    }

    /// Mean statistic over the cluster's time span, mapped back onto original
    /// channel indices so the topomap can ring the member sensors.
    private func statisticTopography(cluster: SpatiotemporalCluster,
                                     output: ClusterPermutationOutput) -> [Double] {
        let channelCount = (members.first?.channelCount ?? 0)
        var values = [Double](repeating: 0, count: max(channelCount, 1))
        let samples = cluster.startSample...cluster.endSample
        for (localChannel, globalChannel) in output.channelIndices.enumerated()
        where values.indices.contains(globalChannel) {
            var sum = 0.0
            for sample in samples {
                sum += output.analysis.observedStatistics[localChannel * output.analysis.sampleCount + sample]
            }
            values[globalChannel] = sum / Double(samples.count)
        }
        return values
    }

    private func midLatencySeconds(_ cluster: SpatiotemporalCluster,
                                   output: ClusterPermutationOutput) -> Double {
        let offsets = output.relativeSampleOffsets
        guard offsets.indices.contains(cluster.startSample),
              offsets.indices.contains(cluster.endSample) else { return 0 }
        return Double(offsets[cluster.startSample] + offsets[cluster.endSample]) / 2 / output.samplingRate
    }

    private func latencyText(_ localSample: Int, output: ClusterPermutationOutput) -> String {
        guard output.relativeSampleOffsets.indices.contains(localSample) else { return "?" }
        return String(Int((Double(output.relativeSampleOffsets[localSample]) / output.samplingRate * 1_000).rounded()))
    }

    private func cellSummary(_ analysis: ClusterPermutationAnalysis) -> String {
        let joiner = analysis.statistic == .t ? " vs " : " · "
        if analysis.unitCount != nil {
            return analysis.seriesNames.joined(separator: joiner)
                + " (n=\(analysis.unitCount ?? 0) subjects)"
        }
        return zip(analysis.seriesNames, analysis.seriesCounts)
            .map { "\($0.0) (n=\($0.1))" }
            .joined(separator: joiner)
    }

    /// One line recording exactly how the p-values were produced, so a figure
    /// exported from this pane can be described in a methods section.
    private func methodSummary(_ output: ClusterPermutationOutput) -> String {
        let analysis = output.analysis
        var parts = [analysis.rearrangements.summary]
        switch analysis.inference {
        case .clusterMass:
            var threshold = "\(analysis.statistic.symbol) ≥ \(String(format: "%.2f", analysis.resolvedThreshold ?? 0))"
            if case .probability(let value) = analysis.thresholdSpecification {
                threshold += " (p \(formatP(value)))"
            }
            parts.append(threshold)
        case .tfce:
            parts.append("TFCE E=\(String(format: "%.2g", analysis.tfce.extentExponent)) H=\(String(format: "%.2g", analysis.tfce.heightExponent)) · \(analysis.tfce.stepCount) steps")
        case .etac:
            let probabilities = analysis.etac.orderedProbabilities
                .map { formatP($0) }
                .joined(separator: ", ")
            let criticals = (analysis.resolvedETACThresholds ?? [])
                .map { String(format: "%.2f", $0) }
                .joined(separator: ", ")
            if let resolvedRadii = analysis.resolvedETACRadii, !resolvedRadii.isEmpty {
                let multipliers = analysis.etac.orderedRadiusMultipliers
                    .map { String(format: "%.2g", $0) }
                    .joined(separator: ", ")
                let radii = resolvedRadii
                    .map { String(format: "%.3f", $0) }
                    .joined(separator: ", ")
                parts.append("ETAC-EEG cluster p=[\(probabilities)] · \(analysis.statistic.symbol)=[\(criticals)] · radii=[\(multipliers)]× median NN ([\(radii)] r) · equitable minP union")
            } else {
                parts.append("ETAC-EEG cluster p=[\(probabilities)] · \(analysis.statistic.symbol)=[\(criticals)] · temporal-only graph (no sensor layout) · equitable minP union")
            }
        }
        if analysis.inference != .etac { parts.append(adjacencyDescription(output)) }
        if let numerator = analysis.numeratorDegreesOfFreedom {
            parts.append("df=(\(numerator), \(analysis.denominatorDegreesOfFreedom))")
        } else {
            parts.append("df=\(analysis.denominatorDegreesOfFreedom)")
        }
        parts.append("p floor \(formatP(analysis.rearrangements.pValueFloor))")
        return parts.joined(separator: " · ")
    }

    private func adjacencyDescription(_ output: ClusterPermutationOutput) -> String {
        let mean = String(format: "%.1f", output.adjacencySummary.meanNeighborCount)
        switch output.adjacencyConfiguration.method {
        case .temporalOnly: return "no spatial adjacency"
        case .distance:
            return "neighbors < \(String(format: "%.2f", output.adjacencyConfiguration.distance)) r (\(mean) mean)"
        case .nearestNeighbors:
            return "\(output.adjacencyConfiguration.neighborCount)-nearest neighbors (\(mean) mean)"
        }
    }

    private func adjacencyHelp(_ summary: ClusterAdjacencySummary) -> String {
        var parts = ["Range \(summary.minimumNeighborCount)–\(summary.maximumNeighborCount) neighbors, \(summary.componentCount) connected group\(summary.componentCount == 1 ? "" : "s")."]
        if summary.isolatedChannelCount > 0 {
            parts.append("\(summary.isolatedChannelCount) sensor\(summary.isolatedChannelCount == 1 ? "" : "s") have no neighbors and can only form temporal clusters. Increase the radius or K.")
        }
        if summary.isOverConnected {
            parts.append("Neighborhoods this large tend to merge distinct effects into one uninterpretable cluster.")
        }
        return parts.joined(separator: " ")
    }

    private func formatP(_ value: Double) -> String {
        if value < 0.001 { return "<.001" }
        return String(format: "%.3f", value).replacingOccurrences(of: "0.", with: ".")
    }

    private func savePNGButton<V: View>(_ name: String, @ViewBuilder _ view: @escaping () -> V) -> some View {
        Button {
            ImageExport.savePNG(view(), suggestedName: name)
        } label: {
            Label("Save PNG", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .font(.caption2)
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    // MARK: - Seeding and running

    private func seedSelections() {
        if family == .mixed, measureKind == .condition { measureKind = .difference }

        let names = conditionNames
        if measureA == nil || !names.contains(measureA ?? "") { measureA = names.first }
        if measureB == nil || !names.contains(measureB ?? "") || measureB == measureA {
            measureB = names.first { $0 != measureA }
        }
        withinConditions.removeAll { !names.contains($0) }
        if withinConditions.count < 2 { withinConditions = Array(names.prefix(max(names.count, 0))) }
        measureMean.removeAll { !names.contains($0) }
        if measureMean.count < 2 { measureMean = names }

        let sources = availableGroupSources
        if !sources.contains(where: { $0.source == groupSource }) {
            groupSource = sources.first?.source ?? .factor(0)
        }
        let labels = analysisGroups.map(\.label)
        selectedGroups.removeAll { !labels.contains($0) }
        if selectedGroups.count < 2 { selectedGroups = labels }
    }

    private func seedWindowIfNeeded() {
        guard !windowInitialized, let available = availableWindowMs else { return }
        windowStartMs = max(0, available.lowerBound)
        windowEndMs = available.upperBound
        windowInitialized = true
    }

    /// The starting neighbor radius comes from this montage's own spacing: a
    /// constant would be far too small for a 32-channel cap and far too large
    /// for a 256-channel net.
    private func seedAdjacencyIfNeeded() {
        guard !adjacencyInitialized else { return }
        if let suggested = ClusterSpatialAdjacency.suggestedDistance(
            channelIndices: analysisChannels,
            layout: sensorLayout
        ) {
            adjacency.distance = suggested
        }
        if sensorLayout == nil { adjacency.method = .temporalOnly }
        adjacencyInitialized = true
    }

    private func toggleThresholdMode() {
        let isF = design?.statisticKind == .f
        if usesProbabilityThreshold {
            if let critical = previewedCriticalValue {
                let rounded = (critical * 100).rounded() / 100
                if isF { thresholdF = rounded } else { thresholdT = rounded }
            }
            usesProbabilityThreshold = false
        } else {
            if let degrees = previewedDegreesOfFreedom {
                let value = isF ? thresholdF : thresholdT
                let probability: Double? = isF
                    ? degrees.numerator.map {
                        ClusterStatisticsDistributions.upperTailFProbability(
                            value, numeratorDegreesOfFreedom: $0, denominatorDegreesOfFreedom: degrees.denominator
                        )
                    }
                    : ClusterStatisticsDistributions.twoTailedTProbability(
                        value, degreesOfFreedom: degrees.denominator
                    )
                if let probability, probability > 0, probability < 1 {
                    thresholdProbability = (probability * 1_000).rounded() / 1_000
                }
            }
            usesProbabilityThreshold = true
        }
    }

    private func invalidateResult() {
        guard !isRunning else { return }
        output = nil
        statusMessage = nil
        selectedClusterID = nil
    }

    private func subjectSnapshots() -> [ClusterSubjectSnapshot] {
        var groupOf: [UUID: String] = [:]
        for group in analysisGroups {
            for dataset in group.datasets { groupOf[dataset.id] = group.label }
        }
        return members.map { dataset in
            var conditions: [String: ClusterConditionSnapshot] = [:]
            for condition in dataset.conditions {
                guard let samples = condition.samples, !samples.isEmpty else { continue }
                // First occurrence wins; duplicate category names in one file
                // would otherwise silently pick an arbitrary one.
                if conditions[condition.name] == nil {
                    conditions[condition.name] = ClusterConditionSnapshot(
                        samples: samples,
                        sampleCount: condition.sampleCount,
                        baselineSamples: condition.baselineSamples
                    )
                }
            }
            return ClusterSubjectSnapshot(
                name: dataset.name,
                groupLabel: groupOf[dataset.id] ?? "",
                samplingRate: dataset.samplingRate,
                channelCount: dataset.channelCount,
                conditions: conditions
            )
        }
    }

    private func runAnalysis() {
        guard canRun, let design else { return }
        analysisTask?.cancel()
        output = nil
        statusMessage = nil
        selectedClusterID = nil
        isRunning = true
        progress.reset()
        progress.stage = "Starting…"

        let job = ClusterPermutationJob(
            design: design,
            subjects: subjectSnapshots(),
            sensorLayout: sensorLayout,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            sampleStride: sampleStride,
            permutationCount: permutationCount,
            threshold: thresholdSpecification,
            inference: inference,
            tfce: tfce,
            etac: etac,
            adjacency: sensorLayout == nil
                ? ClusterAdjacencyConfiguration(method: .temporalOnly)
                : adjacency,
            seed: design.statisticKind == .t ? 0xDE_115_C1A5_7E57 : 0xDE_115_F1A5_7E57
        )
        let handler = progress.handler()

        analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                ClusterStatisticsRunner.run(job: job, progress: handler)
            }
            let response = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled else { return }
            output = response.output
            statusMessage = response.errorMessage
            selectedClusterID = response.output?.clusters(at: alpha).first?.id
            isRunning = false
            analysisTask = nil
        }
    }

    private func cancelRun(clearStatus: Bool) {
        analysisTask?.cancel()
        analysisTask = nil
        isRunning = false
        if clearStatus { statusMessage = "Permutation run cancelled." }
    }
}

// MARK: - Help text

extension PermutationStatisticsView {
    /// A help blurb followed by the sources it rests on, so the popover a user
    /// opens while configuring a run is also the one they can cite afterwards.
    static func help(_ body: String, _ references: [Reference]) -> String {
        body + "\n\n" + References.shortList(references)
    }

    static let methodHelp = help("""
    Finds where and when your conditions or groups differ, while correcting for \
    testing every sensor at every time point.

    Each channel × time point gets a t or F. Neighbouring points that pass the \
    cluster-forming threshold are joined into clusters, and each cluster's summed \
    statistic is compared against the distribution of the largest cluster found \
    after relabelling the data many times. Only whole clusters get a corrected \
    p-value — that is what makes the correction exact without assuming anything \
    about the shape of the data.

    Subjects are the exchangeable unit, so the relabelling matches your design: \
    sign flips within subject, or shuffled group membership across subjects.
    """, References.forClusterMethod)

    static let withinConditionsHelp = help("""
    Conditions every subject contributes. Two gives a paired t-test on each \
    subject's difference map; three or more gives the repeated-measures omnibus F.

    Click order sets the direction: the first condition is the A of A − B, so a \
    positive cluster means A > B. Subjects missing any selected condition are \
    excluded and named in the results.
    """, References.forClusterDesign)

    static let measureHelp = help("""
    How each subject is reduced to a single channel × time map before groups are \
    compared.

    • One condition — that condition alone.
    • Difference (A − B) — the within-subject contrast. Comparing it between \
    groups is the interaction.
    • Mean of conditions — pools over stimulus type, so you test the group effect \
    on its own rather than any particular contrast.

    Collapsing first is what lets a mixed design reuse the ordinary \
    between-subject statistic instead of needing a factorial permutation scheme, \
    for which no single exact test is agreed on.
    """, References.forClusterDesign)

    static let groupHelp = help("""
    What defines a between-subject cell.

    Choosing one factor tests that factor's main effect — for example Age with \
    three levels compares 6, 12 and 18 months in one omnibus F.

    Choosing the crossed cells gives every combination of your factors. Tick all \
    of them for the omnibus over the whole between-subject design, or tick just \
    two for a focused contrast such as 6mo × MZ against 6mo × DZ. Unticked cells \
    are excluded from the run.
    """, References.forClusterDesign)

    static let windowHelp = help("""
    The analysis window, in milliseconds relative to stimulus onset. Negative \
    values are pre-stimulus.

    Each subject is indexed through its own pre-stimulus interval, so files \
    epoched differently still contribute the same stimulus-relative samples. The \
    window is limited to what every contributing subject can supply; see the \
    epoch layout below for per-subject values.

    Choose the window from your hypothesis, not from the statistic map — picking \
    it after seeing where the effect is reintroduces the multiple-comparisons \
    problem the correction exists to solve.
    """, [References.groppe])

    static let strideHelp = help("""
    Keeps every Nth sample. This is not a display setting: it changes the lattice \
    clusters grow on, so a coarser stride means fewer, larger time steps and \
    slightly different clusters.

    Use it to make an exploratory run faster, then set it back to 1 for the run \
    you report.
    """, [References.marisOostenveld])

    static let correctionHelp = help("""
    How the family-wise error rate is controlled.

    • Cluster mass — points passing the cluster-forming threshold are grown into \
    clusters and each cluster's summed statistic is tested. Sensitive to broad \
    effects, but the threshold is an arbitrary choice you must declare.

    • TFCE — every point is scored by integrating cluster extent over all possible \
    thresholds, removing that choice. Correction is then point-wise, and it costs \
    more computation.

    • ETAC-EEG — cluster tests are run over a grid of uncorrected p thresholds and \
    montage-relative sensor radii. Each subtest's maximum-cluster null is converted \
    to a marginal p scale, then the minimum p across the grid is permutation-calibrated. \
    This controls the union while balancing focal/strong and broad/weak clusters.
    """, References.forClusterInference)

    static let etacHelp = help("""
    ETAC-EEG runs one maximum-cluster-mass subtest at each listed uncorrected p \
    threshold and montage-relative sensor radius, using the same permutation maps.

    Each radius is a multiplier of the montage's median nearest-neighbor spacing. \
    This makes the sweep scale with sensor density instead of silently meaning \
    something different on 32-, 128-, and 256-channel arrays.

    Raw masses are not compared across thresholds. DENNIS rank-transforms each \
    subtest against its own null, then calibrates the minimum marginal p-value \
    across the set against the permutation distribution of that same minimum. \
    The resulting union has one jointly corrected p-value scale.

    The default 1.25×, 1.7×, and 2.1× sweep ranges from the immediate local ring \
    to a modestly broader graph. The p thresholds and radii form a complete grid, \
    and the minP calibration corrects their union together.
    """, References.forClusterInference)

    static let thresholdHelp = help("""
    The statistic a point must reach to join a cluster. It does not control any \
    error rate by itself — the permutation step does that.

    Enter it as a p-value (the default) and it is converted to the critical \
    statistic for this design's degrees of freedom, shown beside the field. Use ⇄ \
    to enter a raw statistic instead.

    Prefer the p form: a fixed |t| of 2.0 is p = .05 at 60 df but p = .18 at 2 df, \
    so a raw threshold is only comparable within a single analysis. A higher \
    threshold favours strong, focal effects; a lower one favours broad, weak ones.
    """, References.forClusterThreshold)

    static let permutationsHelp = help("""
    How many relabellings the observed statistic is compared against.

    When the design admits fewer distinct relabellings than you request, DENNIS \
    evaluates all of them instead of sampling, and the p-values are exact. With 12 \
    subjects a paired design has only 2¹² = 4096 sign flips, so the smallest \
    possible p is 1/4096 — asking for 10,000 permutations cannot buy a smaller \
    one. The status line reports which mode is in use and the resulting p floor.

    1,000 is fine while exploring; use 5,000–10,000 for a result you report.
    """, References.forClusterPermutationCount)

    static let neighborsHelp = help("""
    Which sensors count as adjacent, and therefore which clusters can form at all.

    • Within distance — every sensor inside a radius, given as a fraction of the \
    head radius. Neighbourhood size follows sensor density. The default comes from \
    your montage's own median spacing.
    • K nearest — a fixed number of neighbours per sensor, symmetrized. Better for \
    irregular or sparse montages.
    • Time only — no spatial links; clusters extend in time within a channel.

    Watch the mean neighbour count. Too sparse and one real effect fragments into \
    sub-threshold pieces; above about 12 it turns orange, because neighbourhoods \
    that large merge distinct effects into a single uninterpretable blob.
    """, References.forClusterAdjacency)

    static let alphaHelp = help("""
    The corrected p-value required for display. Under fixed-threshold cluster \
    mass it applies to the cluster as a whole, so changing alpha can remove a \
    cluster but cannot shrink its descriptive extent.

    TFCE and ETAC provide corrected point support for display; DENNIS regroups \
    those surviving points at the selected alpha, so their displayed spatial \
    and temporal extent can shrink at a stricter level.

    Changing it re-filters the existing results; it does not require another run. \
    An alpha below the reported permutation p-value floor cannot select anything.
    """, References.forClusterInterpretation)

    static let epochHelp = help("""
    Each subject's epoch geometry: the pre-stimulus interval, the number of \
    samples, and the stimulus-relative span it can supply.

    Different pre-stimulus intervals are fine — the window is measured from onset, \
    so each subject is indexed through its own baseline. Rows that differ from the \
    first are shown in orange so an oddly epoched file is easy to spot.

    A 0 ms pre-stimulus interval is worth checking: it means that file's categories \
    carried no stimulus-onset event, so sample 0 is being treated as onset.
    """, [References.groppe])

    static let interpretationHelp = help("""
    What a significant cluster does and does not license.

    It licenses the claim that the conditions or groups differ somewhere in the \
    tested window and sensor set. It does not establish the effect's onset, its \
    offset, or which sensors carry it: those boundaries are artefacts of the \
    cluster-forming threshold, and member points are not individually significant.

    Report the effect, and describe the cluster's extent as descriptive rather than \
    as an inferential claim about timing or localisation.
    """, References.forClusterInterpretation)
}

// MARK: - Heatmap

private struct ClusterStatisticHeatmap: View {
    let analysis: ClusterPermutationAnalysis
    let clusters: [SpatiotemporalCluster]
    let selectedClusterID: Int?
    let onSelectCluster: (Int?) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let cellWidth = size.width / CGFloat(max(analysis.sampleCount, 1))
                let cellHeight = size.height / CGFloat(max(analysis.channelCount, 1))
                let scale = analysis.observedStatistics.map(abs).max() ?? 1
                let significant = Set(clusters.flatMap(\.pointIndices))
                let selected = Set(clusters.first { $0.id == selectedClusterID }?.pointIndices ?? [])

                for channel in 0..<analysis.channelCount {
                    for sample in 0..<analysis.sampleCount {
                        let point = channel * analysis.sampleCount + sample
                        let rect = CGRect(
                            x: CGFloat(sample) * cellWidth,
                            y: CGFloat(channel) * cellHeight,
                            width: max(cellWidth + 0.4, 1),
                            height: max(cellHeight + 0.4, 1)
                        )
                        let shade = color(analysis.observedStatistics[point], scale: scale)
                        context.fill(Path(rect), with: .color(shade.opacity(significant.contains(point) ? 1 : 0.34)))
                        if selected.contains(point) {
                            context.stroke(Path(rect), with: .color(.yellow.opacity(0.95)), lineWidth: 0.8)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let sample = min(max(Int(value.location.x / max(proxy.size.width, 1) * CGFloat(analysis.sampleCount)), 0),
                                     max(analysis.sampleCount - 1, 0))
                    let channel = min(max(Int(value.location.y / max(proxy.size.height, 1) * CGFloat(analysis.channelCount)), 0),
                                      max(analysis.channelCount - 1, 0))
                    let point = channel * analysis.sampleCount + sample
                    onSelectCluster(clusters.first { $0.pointIndices.contains(point) }?.id)
                }
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func color(_ value: Double, scale: Double) -> Color {
        if analysis.statistic == .f {
            let t = min(max(value / max(scale, 1e-12), 0), 1)
            return Color(red: 0.96 - 0.52 * t, green: 0.96 - 0.83 * t, blue: 0.98 - 0.23 * t)
        }
        let t = min(max(value / max(scale, 1e-12), -1), 1)
        if t >= 0 {
            return Color(red: 0.96 - 0.20 * t, green: 0.96 - 0.80 * t, blue: 0.96 - 0.80 * t)
        }
        let magnitude = -t
        return Color(red: 0.96 - 0.73 * magnitude, green: 0.96 - 0.66 * magnitude, blue: 0.96 - 0.21 * magnitude)
    }
}

// MARK: - Cluster waveform chart

private struct ClusterTracePoint: Identifiable {
    let series: String
    let latencyMs: Double
    let mean: Double
    let standardError: Double
    let id: String
    var lowerBound: Double { mean - standardError }
    var upperBound: Double { mean + standardError }
}

private struct ClusterTraceChart: View {
    let output: ClusterPermutationOutput
    let cluster: SpatiotemporalCluster
    let alpha: Double
    let showsStandardError: Bool

    private let palette: [Color] = [.blue, .red, .green, .orange, .purple, .teal, .brown, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsStandardError
                 ? "Cluster-sensor mean ± SEM across subjects"
                 : "Cluster-sensor mean across subjects")
                .font(.caption.weight(.semibold))
            chart
        }
    }

    private var chart: some View {
        Chart {
            RectangleMark(
                xStart: .value("Cluster start", latencyMs(cluster.startSample)),
                xEnd: .value("Cluster end", latencyMs(cluster.endSample))
            )
            .foregroundStyle(Color.yellow.opacity(0.12))

            if showsStandardError {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Latency", point.latencyMs),
                        yStart: .value("Mean − SEM", point.lowerBound),
                        yEnd: .value("Mean + SEM", point.upperBound),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(color(for: point.series).opacity(0.16))
                }
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Latency", point.latencyMs),
                    y: .value("Amplitude", point.mean),
                    series: .value("Series", point.series)
                )
                .foregroundStyle(color(for: point.series))
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            RuleMark(x: .value("Cluster start", latencyMs(cluster.startSample)))
                .foregroundStyle(Color.yellow.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading, spacing: 3) {
                    latencyMarkerLabel(latencyMs(cluster.startSample))
                }
            RuleMark(x: .value("Cluster end", latencyMs(cluster.endSample)))
                .foregroundStyle(Color.yellow.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .trailing, spacing: 3) {
                    latencyMarkerLabel(latencyMs(cluster.endSample))
                }
        }
        .chartXAxisLabel("Latency (ms)")
        .chartYAxisLabel(output.measureLabel)
        .chartLegend(position: .top, alignment: .leading) {
            HStack(spacing: 14) {
                ForEach(output.analysis.seriesNames, id: \.self) { name in
                    HStack(spacing: 4) {
                        Circle().fill(color(for: name)).frame(width: 7, height: 7)
                        Text(name).font(.caption)
                    }
                }
            }
        }
        .help("The yellow span and labeled markers show this cluster's observed temporal extent. "
              + "They do not establish the effect's true onset or imply that every cluster sensor "
              + "belongs to the cluster at every highlighted sample.")
    }

    private func latencyMarkerLabel(_ milliseconds: Double) -> some View {
        Text(String(format: "%.0f ms", milliseconds))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().stroke(Color.yellow.opacity(0.85), lineWidth: 1))
    }

    private func color(for series: String) -> Color {
        let index = output.analysis.seriesNames.firstIndex(of: series) ?? 0
        return palette[index % palette.count]
    }

    private var points: [ClusterTracePoint] {
        output.analysis.seriesNames.flatMap { name -> [ClusterTracePoint] in
            guard let summary = output.waveforms(at: alpha)[cluster.id]?[name],
                  summary.mean.count == output.analysis.sampleCount,
                  summary.standardError.count == output.analysis.sampleCount else { return [] }
            return (0..<output.analysis.sampleCount).map { sample in
                ClusterTracePoint(
                    series: name,
                    latencyMs: latencyMs(sample),
                    mean: summary.mean[sample],
                    standardError: summary.standardError[sample],
                    id: "\(name)-\(sample)"
                )
            }
        }
    }

    private func latencyMs(_ sample: Int) -> Double {
        guard output.relativeSampleOffsets.indices.contains(sample) else { return 0 }
        return Double(output.relativeSampleOffsets[sample]) / output.samplingRate * 1_000
    }
}
