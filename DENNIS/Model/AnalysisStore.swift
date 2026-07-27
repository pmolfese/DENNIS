//
//  AnalysisStore.swift
//  DENNIS
//
//  Shared, app-wide store for the most recent PCA results so that different
//  top-level modes (PCA, Tensor, Statistical Analysis) can read the same
//  analysis. Populated by the PCA runners; consumed by the stats/export panel.
//

import Foundation
import Observation

/// Top-level workspace modes shown in the panel selector.
enum AppMode: String, CaseIterable, Identifiable, Codable {
    case pca = "PCA"
    case tensor = "Tensor"
    case decoding = "Decoding / Classification"
    case waveform = "Waveform Analysis"
    case pls = "PLS"
    case clustering = "Clustering"
    case stats = "Statistical Analysis"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pca: "chart.xyaxis.line"
        case .tensor: "cube.transparent"
        case .decoding: "checkerboard.shield"
        case .waveform: "waveform.path.ecg.rectangle"
        case .pls: "arrow.triangle.branch"
        case .clustering: "circle.grid.cross"
        case .stats: "tablecells"
        }
    }

    static let defaultVisible: [AppMode] = [.pca, .tensor, .decoding, .stats]
}

@Observable
@MainActor
final class AnalysisStore {
    private static let visibleModesDefaultsKey = "DENNIS.visibleAppModes"

    var visibleModes: [AppMode] = AnalysisStore.loadVisibleModes() {
        didSet { AnalysisStore.saveVisibleModes(visibleModes) }
    }

    var activeMode: AppMode = .pca
    var requestedSelection: SidebarSelection?
    var tableImportError: String?

    func isModeVisible(_ mode: AppMode) -> Bool {
        visibleModes.contains(mode)
    }

    func setMode(_ mode: AppMode, visible: Bool) {
        if visible {
            guard !visibleModes.contains(mode) else { return }
            visibleModes = AppMode.allCases.filter { $0 == mode || visibleModes.contains($0) }
        } else {
            let remaining = visibleModes.filter { $0 != mode }
            visibleModes = remaining.isEmpty ? [.pca] : remaining
        }
    }

    func resetVisibleModes() {
        visibleModes = AppMode.defaultVisible
    }

    private static func loadVisibleModes() -> [AppMode] {
        guard let raw = UserDefaults.standard.array(forKey: visibleModesDefaultsKey) as? [String] else {
            return AppMode.defaultVisible
        }
        let decoded = raw.compactMap(AppMode.init(rawValue:))
        let ordered = AppMode.allCases.filter { decoded.contains($0) }
        return ordered.isEmpty ? AppMode.defaultVisible : ordered
    }

    private static func saveVisibleModes(_ modes: [AppMode]) {
        UserDefaults.standard.set(modes.map(\.rawValue), forKey: visibleModesDefaultsKey)
    }

    /// A completed two-step (dual) PCA plus the labels needed to interpret and
    /// export it.
    struct DualBundle {
        let result: TwoStepPCAResult
        /// Group the analysis was run on (sidebar group id; "" = all subjects).
        let groupID: String
        let groupLabel: String
        let conditionNames: [String]
        let subjectNames: [String]
        let subjectLevels: [[String]]
        let factorNames: [String]
        let conditionMetadata: ConditionModeMetadata
        let sensorLayout: SensorLayout?
        let nChannels: Int
        let samplingRate: Double
        let baselineSamples: Int
    }

    var dual: DualBundle?

    struct PCAResultCache {
        var screeAnalysis: ScreeAnalysis?
        var pcaModel: TemporalPCAResult?
        var dualModel: TwoStepPCAResult?
        var spatialScree: ScreeAnalysis?
    }

    var pcaResultsByGroup: [String: PCAResultCache] = [:]

    func pcaCache(for groupID: String) -> PCAResultCache? {
        pcaResultsByGroup[groupID]
    }

    func updatePCACache(for groupID: String, _ update: (inout PCAResultCache) -> Void) {
        var cache = pcaResultsByGroup[groupID] ?? PCAResultCache()
        update(&cache)
        pcaResultsByGroup[groupID] = cache
    }

    enum DerivedKind: String, Sendable {
        case reconstructedDualFactor = "PCA reconstructed temporal-spatial factor"
    }

    enum DerivedReconstructionScope: String, CaseIterable, Identifiable, Sendable {
        case fullFactor = "Full factor"
        case selectedElectrodes = "Selected electrodes"

        var id: String { rawValue }
    }

    struct DerivedDataItem: Identifiable {
        enum Unit: String, CaseIterable, Identifiable, Sendable {
            case component = "Component units"
            case microvolts = "Microvolts"

            var id: String { rawValue }
            var symbol: String {
                switch self {
                case .component: "component units"
                case .microvolts: "µV"
                }
            }
        }

        struct FactorPreview: Sendable {
            let factorName: String
            let temporalLoading: [Double]
            let temporalTimesMS: [Double]
            let spatialLoading: [Double]
            let sensorLayout: SensorLayout?
            let channelIndices: [Int]?
            let variance: Double
        }

        let id: UUID
        let name: String
        let kind: DerivedKind
        let sourceGroupID: String
        let sourceGroupLabel: String
        let selectedFactorName: String
        let conditionNames: [String]
        let subjectNames: [String]
        let subjectLevels: [[String]]
        let factorNames: [String]
        let conditionMetadata: ConditionModeMetadata
        let input: EPTensor.Input
        /// Original zero-based channel indices represented by `input.channels`.
        /// Nil means channels are unchanged from the source tensor.
        let channelIndices: [Int]?
        let nativeUnit: Unit
        let microvoltScale: [[Double]]?
        let factorPreview: FactorPreview?
        let provenance: String
    }

    var derivedData: [DerivedDataItem] = []
    struct BehavioralDataItem: Identifiable {
        let id: UUID
        let name: String
        let sourceURL: URL
        let headers: [String]
        let rows: [[String]]
    }

    var behavioralData: [BehavioralDataItem] = []

    func derivedItem(id: UUID) -> DerivedDataItem? {
        derivedData.first { $0.id == id }
    }

    func behavioralItem(id: UUID) -> BehavioralDataItem? {
        behavioralData.first { $0.id == id }
    }

    func addImportedDerivedData(_ item: DerivedDataItem) {
        derivedData.removeAll { $0.name == item.name }
        derivedData.append(item)
        requestedSelection = .derived(item.id)
    }

    @discardableResult
    func addReconstructedFactorDerivedData(
        from bundle: DualBundle,
        factor: TwoStepFactor,
        scope: DerivedReconstructionScope,
        threshold: Double
    ) -> DerivedDataItem? {
        guard let built = DerivedDataBuilder.reconstructedDualFactor(
            bundle: bundle,
            factor: factor,
            scope: scope,
            threshold: threshold
        ) else {
            return nil
        }
        let label = label(for: factor.name)
        let scopeSuffix = scope == .fullFactor ? "full" : "selected electrodes"
        let item = DerivedDataItem(
            id: UUID(),
            name: "\(label) reconstructed (\(scopeSuffix))",
            kind: .reconstructedDualFactor,
            sourceGroupID: bundle.groupID,
            sourceGroupLabel: bundle.groupLabel,
            selectedFactorName: factor.name,
            conditionNames: bundle.conditionNames,
            subjectNames: bundle.subjectNames,
            subjectLevels: bundle.subjectLevels,
            factorNames: bundle.factorNames,
            conditionMetadata: bundle.conditionMetadata,
            input: built.input,
            channelIndices: built.channelIndices,
            nativeUnit: .component,
            microvoltScale: built.microvoltScale,
            factorPreview: built.factorPreview,
            provenance: provenance(for: factor, bundle: bundle, scope: scope, threshold: threshold, channelCount: built.input.nChannels)
        )
        derivedData.removeAll { $0.name == item.name && $0.sourceGroupID == item.sourceGroupID }
        derivedData.append(item)
        requestedSelection = .derived(item.id)
        activeMode = .decoding
        return item
    }

    @discardableResult
    func addReconstructedFactorDerivedData(from bundle: DualBundle, factor: TwoStepFactor) -> DerivedDataItem? {
        addReconstructedFactorDerivedData(from: bundle, factor: factor, scope: .fullFactor, threshold: spatialThreshold)
    }

    private func provenance(
        for factor: TwoStepFactor,
        bundle: DualBundle,
        scope: DerivedReconstructionScope,
        threshold: Double,
        channelCount: Int
    ) -> String {
        let base = "Dual PCA \(factor.name) from \(bundle.groupLabel); reconstructed as score × spatial loading × temporal loading"
        switch scope {
        case .fullFactor:
            return "\(base) across all \(channelCount) channels."
        case .selectedElectrodes:
            return "\(base), restricted to \(channelCount) channels with |spatial loading| ≥ \(String(format: "%.3g", threshold))."
        }
    }

    /// Spatial-loading threshold for the dual-PCA topographies (rings electrodes
    /// at/above |loading|, and defines the channel clusters for cluster ERPs).
    /// Persisted here so it survives switching between app-mode tabs.
    var spatialThreshold: Double = 0.4

    /// Whether the cluster-ERP plot shades the active temporal window, and the
    /// |temporal-loading| threshold that defines that window.
    var highlightTemporalWindow = false
    var temporalThreshold: Double = 0.4

    /// Whether cluster-ERP traces show a ±1 standard-error band (across subjects).
    var showStandardError = false

    /// Cluster-ERP "Group by" dimensions, persisted so the choice stays put while
    /// clicking through factor topographies. A nil visible-cell set means "all".
    var clusterGroupBy: Set<String> = ["Condition"]
    var clusterVisibleCells: Set<String>? = nil

    /// User-supplied factor labels, keyed by the engine factor name (e.g.
    /// "TF1SF2" → "P300").
    var factorLabels: [String: String] = [:]

    /// Whether exported factor scores are reconstructed into microvolts (via
    /// var_sd-scaled loadings) rather than left standardized.
    var scaleToMicrovolts = false

    /// How a factor's loading is reduced to a single amplitude for µV scaling.
    enum MicrovoltMeasure: String, CaseIterable, Identifiable {
        case peak = "Peak"
        case meanWindow = "Mean (window)"
        var id: String { rawValue }
    }
    var microvoltMeasure: MicrovoltMeasure = .peak
    /// Temporal window (ms) for the mean measure; nil bounds use the full epoch.
    var windowStartMS: Double = 0
    var windowEndMS: Double = 800

    func label(for engineName: String) -> String {
        let custom = factorLabels[engineName]?.trimmingCharacters(in: .whitespaces)
        return (custom?.isEmpty == false) ? custom! : engineName
    }
}
