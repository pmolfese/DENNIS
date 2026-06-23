//
//  PCAProgress.swift
//  DENNIS
//
//  Lightweight progress plumbing for long-running PCA / scree jobs. The engine
//  reports `(fraction, stage label)` through a Sendable handler; the UI mirrors
//  it into an observable model on the main actor to drive a determinate progress
//  bar instead of an indeterminate spinner.
//

import Foundation

/// Reports a completion fraction in 0...1 and a human-readable stage label.
typealias PCAProgressHandler = @Sendable (Double, String) -> Void

/// Main-actor observable mirror of a job's progress, held as view state.
@Observable
@MainActor
final class RunProgress {
    var fraction: Double = 0
    var stage: String = ""

    func reset() { fraction = 0; stage = "" }

    /// A Sendable handler that forwards engine progress onto the main actor.
    nonisolated func handler() -> PCAProgressHandler {
        { fraction, stage in
            Task { @MainActor in
                self.fraction = fraction
                self.stage = stage
            }
        }
    }
}
