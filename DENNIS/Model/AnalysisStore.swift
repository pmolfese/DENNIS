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

    /// User-supplied factor labels, keyed by the engine factor name (e.g.
    /// "TF1SF2" → "P300").
    var factorLabels: [String: String] = [:]

    /// Whether exported factor scores are scaled toward microvolts by peak
    /// loading (approximate) rather than left standardized.
    var scaleToMicrovolts = false

    func label(for engineName: String) -> String {
        let custom = factorLabels[engineName]?.trimmingCharacters(in: .whitespaces)
        return (custom?.isEmpty == false) ? custom! : engineName
    }
}
