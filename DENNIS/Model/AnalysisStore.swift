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
enum AppMode: String, CaseIterable, Identifiable {
    case pca = "PCA"
    case tensor = "Tensor"
    case pls = "PLS"
    case stats = "Statistical Analysis"
    var id: String { rawValue }
}

@Observable
@MainActor
final class AnalysisStore {
    /// A completed two-step (dual) PCA plus the labels needed to interpret and
    /// export it.
    struct DualBundle {
        let result: TwoStepPCAResult
        /// Group the analysis was run on (sidebar group id; "" = all subjects).
        let groupID: String
        let groupLabel: String
        let conditionNames: [String]
        let subjectNames: [String]
        let sensorLayout: SensorLayout?
        let nChannels: Int
    }

    var dual: DualBundle?

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
