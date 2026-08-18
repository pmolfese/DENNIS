//
//  ClusterStatisticsRunner.swift
//  DENNIS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns a `Study` — subjects, conditions, between-subject groups — into the
//  flattened channel-major matrices the cluster analyzers consume, then runs the
//  analyzer the chosen `ClusterDesign` calls for.
//
//  This layer is deliberately stricter than `GrandAverage`, which silently skips
//  subjects whose dimensions disagree with the first one. Dropping a subject
//  changes the design, so every mismatch is refused by name rather than
//  absorbed, and every legitimately excluded subject (one missing a required
//  condition) is reported back to the UI. Nothing is ever padded with zeros.
//
//  Reads `Condition.samples` and writes nothing back: the PCA, tensor,
//  waveform, and grand-average paths are untouched by this feature.
//
//  References (full citations in `References.swift`):
//    - Groppe, Urbach & Kutas (2011), Psychophysiology 48(12):1711-1725 —
//      choosing the analysis time window and channel set as an a priori
//      decision rather than one made after seeing the statistic map.
//    - Maris & Oostenveld (2007), J Neurosci Methods 164(1):177-190 — the test
//      this prepares data for.
//

import Foundation

// MARK: - Sendable snapshots of the study

/// One condition's averaged data, copied out of the observable model so the
/// analysis can run off the main actor.
nonisolated struct ClusterConditionSnapshot: Sendable {
    /// `channels × samples`.
    let samples: [[Float]]
    let sampleCount: Int
    /// Stimulus-onset sample index (pre-stimulus baseline length).
    let baselineSamples: Int
}

nonisolated struct ClusterSubjectSnapshot: Sendable {
    let name: String
    /// The between-subject group this subject falls in, as labeled by the
    /// grouping tree. Empty when the design is purely within-subject.
    let groupLabel: String
    let samplingRate: Double
    let channelCount: Int
    let conditions: [String: ClusterConditionSnapshot]
}

// MARK: - Job

nonisolated struct ClusterPermutationJob: Sendable {
    let design: ClusterDesign
    let subjects: [ClusterSubjectSnapshot]
    let sensorLayout: SensorLayout?
    let windowStartMs: Double
    let windowEndMs: Double
    /// Kept explicit rather than hidden as an optimization: striding changes the
    /// temporal lattice clusters grow on, not merely the plot resolution.
    let sampleStride: Int
    let permutationCount: Int
    let threshold: ClusterFormingThreshold
    let inference: ClusterInferenceMode
    let tfce: TFCEParameters
    let etac: ETACParameters
    let adjacency: ClusterAdjacencyConfiguration
    let seed: UInt64

    init(
        design: ClusterDesign,
        subjects: [ClusterSubjectSnapshot],
        sensorLayout: SensorLayout?,
        windowStartMs: Double,
        windowEndMs: Double,
        sampleStride: Int = 1,
        permutationCount: Int = 1_000,
        threshold: ClusterFormingThreshold = .probability(0.05),
        inference: ClusterInferenceMode = .clusterMass,
        tfce: TFCEParameters = .default,
        etac: ETACParameters = .default,
        adjacency: ClusterAdjacencyConfiguration = .default,
        seed: UInt64 = 0xDE_115_C1A5_7E57
    ) {
        self.design = design
        self.subjects = subjects
        self.sensorLayout = sensorLayout
        self.windowStartMs = windowStartMs
        self.windowEndMs = windowEndMs
        self.sampleStride = sampleStride
        self.permutationCount = permutationCount
        self.threshold = threshold
        self.inference = inference
        self.tfce = tfce
        self.etac = etac
        self.adjacency = adjacency
        self.seed = seed
    }
}

// MARK: - Results

/// The t and F analyzer results in one shape, so the UI has a single path.
nonisolated struct ClusterPermutationAnalysis: Sendable {
    let statistic: ClusterStatisticKind
    /// The plotted series: the conditions of a within-subject design, or the
    /// groups of a between-subject one.
    let seriesNames: [String]
    let seriesCounts: [Int]
    /// Subjects contributing to every cell, for within-subject designs.
    let unitCount: Int?
    let numeratorDegreesOfFreedom: Int?
    let denominatorDegreesOfFreedom: Int
    let channelCount: Int
    let sampleCount: Int
    let observedStatistics: [Double]
    let observedTFCEScores: [Double]?
    let pointPValues: [Double]?
    let clusters: [SpatiotemporalCluster]
    let rearrangements: ClusterRearrangementPlan
    let inference: ClusterInferenceMode
    let tfce: TFCEParameters
    let etac: ETACParameters
    /// The statistic value clusters were formed at, after resolving a
    /// probability threshold. Nil under TFCE.
    let resolvedThreshold: Double?
    let resolvedETACThresholds: [Double]?
    /// Montage-relative radii actually used by ETAC, in normalized head units.
    let resolvedETACRadii: [Double]?
    let etacNearestNeighborSpacing: Double?
    let thresholdSpecification: ClusterFormingThreshold
}

nonisolated struct ClusterWaveformSummary: Sendable, Equatable {
    let mean: [Double]
    /// Standard error **across subjects** after averaging each subject over the
    /// cluster's participating sensors. Across-subject is the meaningful error
    /// bar for a group test.
    let standardError: [Double]
}

/// One subject's epoch geometry, so the pre-stimulus interval is something the
/// user can read rather than infer from an error message. Subjects epoched with
/// different baselines are analyzed together — the window is stimulus-relative —
/// but seeing the spread is how you notice a file that was epoched differently
/// from the rest, or one whose MFF carried no `evtBegin` and so reports a zero
/// baseline.
nonisolated struct ClusterEpochSummary: Sendable, Equatable, Identifiable {
    let subject: String
    /// Samples before stimulus onset.
    let baselineSamples: Int
    let sampleCount: Int
    /// Earliest and latest sample this epoch can supply, in ms relative to
    /// stimulus onset. `startMs` is negative for a genuine pre-stimulus period.
    let startMs: Double
    let endMs: Double

    var id: String { subject }
    var baselineMs: Double { -startMs }
}

/// A subject left out of the analysis, and why. Never silent.
nonisolated struct ClusterExcludedSubject: Sendable, Equatable, Identifiable {
    let name: String
    let reason: String
    var id: String { name }
}

nonisolated struct ClusterPermutationOutput: Sendable {
    let design: ClusterDesign
    let analysis: ClusterPermutationAnalysis
    /// Local analysis channel index -> original signal channel index.
    let channelIndices: [Int]
    /// Analysis sample index -> samples relative to stimulus onset.
    let relativeSampleOffsets: [Int]
    let samplingRate: Double
    /// What each plotted series is measuring, e.g. "Congruent − Incongruent".
    let measureLabel: String
    /// Corrected cluster id -> series name -> across-subject ROI waveform.
    let clusterWaveforms: [Int: [String: ClusterWaveformSummary]]
    /// Point-wise corrections (TFCE and ETAC) must be regrouped at the alpha
    /// currently displayed. Grouping once at .10 and merely filtering by a
    /// component's best p-value would retain overly generous .10 extents at
    /// stricter alpha levels.
    let displayClustersByAlpha: [Double: [SpatiotemporalCluster]]
    let displayWaveformsByAlpha: [Double: [Int: [String: ClusterWaveformSummary]]]
    let contributingSubjects: [String]
    let excludedSubjects: [ClusterExcludedSubject]
    /// Per-subject epoch geometry for the contributing subjects.
    let epochs: [ClusterEpochSummary]
    let adjacencySummary: ClusterAdjacencySummary
    let adjacencyConfiguration: ClusterAdjacencyConfiguration

    /// True when the subjects were not all epoched with the same pre-stimulus
    /// interval. Not an error — the window is stimulus-relative — but worth
    /// surfacing, because it usually means the files came from different
    /// pipelines.
    var hasMixedBaselines: Bool {
        Set(epochs.map(\.baselineSamples)).count > 1
    }

    func clusters(at alpha: Double) -> [SpatiotemporalCluster] {
        displayClustersByAlpha[alpha]
            ?? analysis.clusters.filter { $0.pValue <= alpha }
    }

    func waveforms(at alpha: Double) -> [Int: [String: ClusterWaveformSummary]] {
        displayWaveformsByAlpha[alpha] ?? clusterWaveforms
    }
}

nonisolated struct ClusterPermutationResponse: Sendable {
    let output: ClusterPermutationOutput?
    let errorMessage: String?

    static let cancelled = ClusterPermutationResponse(output: nil, errorMessage: nil)
}

// MARK: - Runner

nonisolated enum ClusterStatisticsRunner {
    static let displayAlphaLevels = [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.10]

    static func run(
        job: ClusterPermutationJob,
        progress: PCAProgressHandler? = nil
    ) -> ClusterPermutationResponse {
        do {
            progress?(0.02, "Gathering subject averages and checking dimensions.")
            let prepared = try prepare(job: job)
            if Task.isCancelled { return .cancelled }

            let workers = WorkerPool.maxWorkers(for: job.permutationCount)
            let stage: String
            switch job.inference {
            case .clusterMass: stage = "Permuting labels on \(workers) CPU workers."
            case .tfce: stage = "Integrating cluster extent on \(workers) CPU workers."
            case .etac:
                let radiusCount = prepared.etacSpatialAdjacencies.isEmpty
                    ? 1
                    : prepared.etacSpatialAdjacencies.count
                let subtests = job.etac.thresholdProbabilities.count * radiusCount
                stage = "Combining \(subtests) threshold × radius subtests on \(workers) CPU workers."
            }
            progress?(0.08, stage)
            let permutationProgress: (@Sendable (Double) -> Void)? = progress.map { report in
                { fraction in
                    report(0.08 + 0.88 * fraction, "Permuting: \(Int((fraction * 100).rounded()))% complete.")
                }
            }

            guard let analysis = try analyze(
                job: job,
                prepared: prepared,
                progress: permutationProgress
            ) else { return .cancelled }

            progress?(0.98, "Summarizing cluster waveforms.")
            let waveforms = waveformSummaries(analysis: analysis, series: prepared.series)
            let clustersByAlpha: [Double: [SpatiotemporalCluster]] = Dictionary(
                uniqueKeysWithValues: displayAlphaLevels.map { alpha in
                    (
                        alpha,
                        displayClusters(
                            analysis: analysis,
                            spatialAdjacency: prepared.spatialAdjacency,
                            alpha: alpha
                        )
                    )
                }
            )
            let waveformsByAlpha: [Double: [Int: [String: ClusterWaveformSummary]]] = Dictionary(
                uniqueKeysWithValues: clustersByAlpha.map { alpha, clusters in
                    (
                        alpha,
                        waveformSummaries(
                            clusters: clusters,
                            sampleCount: analysis.sampleCount,
                            series: prepared.series
                        )
                    )
                }
            )
            progress?(1, "Ready to inspect.")

            return ClusterPermutationResponse(
                output: ClusterPermutationOutput(
                    design: job.design,
                    analysis: analysis,
                    channelIndices: prepared.channelIndices,
                    relativeSampleOffsets: prepared.relativeSampleOffsets,
                    samplingRate: prepared.samplingRate,
                    measureLabel: prepared.measureLabel,
                    clusterWaveforms: waveforms,
                    displayClustersByAlpha: clustersByAlpha,
                    displayWaveformsByAlpha: waveformsByAlpha,
                    contributingSubjects: prepared.contributingSubjects,
                    excludedSubjects: prepared.excludedSubjects,
                    epochs: prepared.epochs,
                    adjacencySummary: ClusterSpatialAdjacency.summarize(prepared.spatialAdjacency),
                    adjacencyConfiguration: job.adjacency
                ),
                errorMessage: nil
            )
        } catch let error as PreparationError {
            return ClusterPermutationResponse(output: nil, errorMessage: error.message)
        } catch let error as ClusterPermutationAnalyzer.AnalysisError {
            return ClusterPermutationResponse(output: nil, errorMessage: message(for: error))
        } catch let error as ClusterPermutationFAnalyzer.AnalysisError {
            return ClusterPermutationResponse(output: nil, errorMessage: message(for: error))
        } catch {
            return ClusterPermutationResponse(
                output: nil,
                errorMessage: "The cluster permutation test could not be computed."
            )
        }
    }

    // MARK: - Analysis dispatch

    private static func analyze(
        job: ClusterPermutationJob,
        prepared: PreparedData,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> ClusterPermutationAnalysis? {
        let channelCount = prepared.channelIndices.count
        let sampleCount = prepared.relativeSampleOffsets.count
        let paired = job.design.isWithinSubject

        switch job.design.statisticKind {
        case .t:
            guard prepared.series.count == 2 else { throw PreparationError.wrongCellCount(2, prepared.series.count) }
            let result = try ClusterPermutationAnalyzer.analyze(
                input: .init(
                    sampleA: .init(name: prepared.series[0].name, units: prepared.series[0].units),
                    sampleB: .init(name: prepared.series[1].name, units: prepared.series[1].units),
                    channelCount: channelCount,
                    sampleCount: sampleCount,
                    spatialAdjacency: prepared.spatialAdjacency,
                    etacSpatialAdjacencies: prepared.etacSpatialAdjacencies,
                    design: paired ? .repeatedMeasures : .independent
                ),
                configuration: .init(
                    permutationCount: job.permutationCount,
                    threshold: job.threshold,
                    inference: job.inference,
                    tfce: job.tfce,
                    etac: job.etac,
                    seed: job.seed
                ),
                progress: progress
            )
            guard let result else { return nil }
            return ClusterPermutationAnalysis(
                statistic: .t,
                seriesNames: [result.sampleAName, result.sampleBName],
                seriesCounts: [result.sampleACount, result.sampleBCount],
                unitCount: result.pairCount,
                numeratorDegreesOfFreedom: nil,
                denominatorDegreesOfFreedom: Int(result.degreesOfFreedom),
                channelCount: result.channelCount,
                sampleCount: result.sampleCount,
                observedStatistics: result.observedStatistics,
                observedTFCEScores: result.observedTFCEScores,
                pointPValues: result.pointPValues,
                clusters: result.clusters,
                rearrangements: result.rearrangements,
                inference: result.configuration.inference,
                tfce: result.configuration.tfce,
                etac: result.configuration.etac,
                resolvedThreshold: result.resolvedThreshold,
                resolvedETACThresholds: result.resolvedETACThresholds,
                resolvedETACRadii: prepared.resolvedETACRadii,
                etacNearestNeighborSpacing: prepared.nearestNeighborSpacing,
                thresholdSpecification: result.configuration.threshold
            )

        case .f:
            let result = try ClusterPermutationFAnalyzer.analyze(
                input: .init(
                    levels: prepared.series.map { .init(name: $0.name, units: $0.units) },
                    channelCount: channelCount,
                    sampleCount: sampleCount,
                    spatialAdjacency: prepared.spatialAdjacency,
                    etacSpatialAdjacencies: prepared.etacSpatialAdjacencies,
                    design: paired ? .repeatedMeasures : .independent
                ),
                configuration: .init(
                    permutationCount: job.permutationCount,
                    threshold: job.threshold,
                    inference: job.inference,
                    tfce: job.tfce,
                    etac: job.etac,
                    seed: job.seed
                ),
                progress: progress
            )
            guard let result else { return nil }
            return ClusterPermutationAnalysis(
                statistic: .f,
                seriesNames: result.levelNames,
                seriesCounts: result.levelCounts,
                unitCount: result.unitCount,
                numeratorDegreesOfFreedom: result.numeratorDegreesOfFreedom,
                denominatorDegreesOfFreedom: result.denominatorDegreesOfFreedom,
                channelCount: result.channelCount,
                sampleCount: result.sampleCount,
                observedStatistics: result.observedStatistics,
                observedTFCEScores: result.observedTFCEScores,
                pointPValues: result.pointPValues,
                clusters: result.clusters,
                rearrangements: result.rearrangements,
                inference: result.configuration.inference,
                tfce: result.configuration.tfce,
                etac: result.configuration.etac,
                resolvedThreshold: result.resolvedThreshold,
                resolvedETACThresholds: result.resolvedETACThresholds,
                resolvedETACRadii: prepared.resolvedETACRadii,
                etacNearestNeighborSpacing: prepared.nearestNeighborSpacing,
                thresholdSpecification: result.configuration.threshold
            )
        }
    }

    // MARK: - Preparation

    struct PreparedSeries: Sendable {
        let name: String
        /// One flattened channel-major matrix per contributing subject. For
        /// within-subject designs the subject order is identical across series,
        /// which is what makes the pairing meaningful.
        let units: [[Double]]
    }

    struct PreparedData: Sendable {
        let series: [PreparedSeries]
        let channelIndices: [Int]
        let relativeSampleOffsets: [Int]
        let spatialAdjacency: [[Int]]
        let etacSpatialAdjacencies: [[[Int]]]
        let resolvedETACRadii: [Double]?
        let nearestNeighborSpacing: Double?
        let samplingRate: Double
        let measureLabel: String
        let contributingSubjects: [String]
        let excludedSubjects: [ClusterExcludedSubject]
        let epochs: [ClusterEpochSummary]
    }

    enum PreparationError: Error, Equatable {
        case invalidDesign
        case invalidAdjacency
        case invalidWindow
        case windowOutsideEpoch(Double, Double, [String])
        case noChannels
        case tooFewSubjects(Int)
        case emptyGroup(String)
        case singleSubjectGroup(String, Int)
        case missingGroups([String])
        case mismatchedSamplingRate([String], Double)
        case channelCountMismatch([String], Int)
        case wrongCellCount(Int, Int)

        var message: String {
            switch self {
            case .invalidDesign:
                return "Choose a complete design: distinct conditions, or distinct groups with a within-subject measure."
            case .invalidAdjacency:
                return "Choose a valid sensor neighborhood: a positive radius, or between 1 and 32 nearest neighbors."
            case .invalidWindow:
                return "Choose a time window with at least two samples inside the epoch."
            case .windowOutsideEpoch(let start, let end, let limiting):
                var text = "The selected window falls outside the interval every subject can supply "
                    + "(\(format(start)) to \(format(end)) ms relative to stimulus onset)."
                if !limiting.isEmpty {
                    text += " The shortest epochs belong to: \(limiting.joined(separator: ", "))."
                }
                return text
            case .noChannels:
                return "No channels with sensor-layout positions are available in these subjects."
            case .tooFewSubjects(let count):
                return "Only \(count) subject\(count == 1 ? "" : "s") can contribute to this design; at least two are required in every cell."
            case .emptyGroup(let group):
                return "Group \"\(group)\" has no subject with all of the required conditions."
            case .singleSubjectGroup(let group, let count):
                return "Group \"\(group)\" contributes \(count) subject\(count == 1 ? "" : "s"); a between-subject test needs at least two per group."
            case .missingGroups(let groups):
                return "No subjects were found in \(groups.count == 1 ? "group" : "groups") \(groups.map { "\"\($0)\"" }.joined(separator: ", "))."
            case .mismatchedSamplingRate(let names, let expected):
                return "These subjects were recorded at a different sampling rate than \(format(expected)) Hz and cannot share a time lattice: \(names.joined(separator: ", "))."
            case .channelCountMismatch(let names, let expected):
                return "These subjects do not have the expected \(expected) channels and would silently change the design if dropped: \(names.joined(separator: ", "))."
            case .wrongCellCount(let expected, let actual):
                return "This design needs \(expected) cells but produced \(actual)."
            }
        }

        private func format(_ value: Double) -> String {
            String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
        }
    }

    static func prepare(job: ClusterPermutationJob) throws -> PreparedData {
        guard job.design.isValid else { throw PreparationError.invalidDesign }
        // ETAC constructs its own montage-relative distance graphs; the
        // ordinary single-graph control is irrelevant (and hidden) in that
        // mode. Without a layout, `build` safely falls back to temporal-only.
        guard job.inference == .etac || job.adjacency.isValid else {
            throw PreparationError.invalidAdjacency
        }
        guard job.windowEndMs > job.windowStartMs else { throw PreparationError.invalidWindow }

        let required = job.design.requiredConditions
        let groups = job.design.groupNames

        // 1. Restrict to the groups under test, and exclude — by name — any
        //    subject that cannot contribute every required condition.
        var excluded: [ClusterExcludedSubject] = []
        var candidates: [ClusterSubjectSnapshot] = []
        for subject in job.subjects {
            if !groups.isEmpty, !groups.contains(subject.groupLabel) { continue }
            let missing = required.filter { name in
                guard let condition = subject.conditions[name] else { return true }
                return condition.samples.isEmpty || condition.sampleCount <= 0
            }
            if missing.isEmpty {
                candidates.append(subject)
            } else {
                excluded.append(ClusterExcludedSubject(
                    name: subject.name,
                    reason: "missing \(missing.joined(separator: ", "))"
                ))
            }
        }
        guard candidates.count >= 2 else { throw PreparationError.tooFewSubjects(candidates.count) }

        if !groups.isEmpty {
            let present = Set(candidates.map(\.groupLabel))
            let absent = groups.filter { !present.contains($0) }
            guard absent.isEmpty else { throw PreparationError.missingGroups(absent) }
        }

        // 2. Every contributing subject must share a sampling rate and a channel
        //    count. Those two really are incompatible when they differ — one
        //    changes the time lattice, the other the spatial one — so they are
        //    refused by name rather than absorbed.
        //
        //    A differing *pre-stimulus baseline* is not in that category. The
        //    window below is specified relative to stimulus onset, and each
        //    subject's own `baselineSamples` is exactly the offset needed to
        //    find that window in that subject's array. Subjects epoched with
        //    different pre-stimulus intervals therefore contribute the same
        //    stimulus-relative samples, and refusing them would discard usable
        //    data for no statistical reason.
        let samplingRate = candidates[0].samplingRate
        guard samplingRate > 0 else { throw PreparationError.invalidWindow }
        let rateOffenders = candidates
            .filter { abs($0.samplingRate - samplingRate) > 1e-6 }
            .map(\.name)
        guard rateOffenders.isEmpty else {
            throw PreparationError.mismatchedSamplingRate(rateOffenders, samplingRate)
        }

        guard let referenceCondition = candidates[0].conditions[required[0]] else {
            throw PreparationError.invalidDesign
        }
        let channelCount = referenceCondition.samples.count
        var channelOffenders: [String] = []
        for subject in candidates {
            for name in required {
                guard let condition = subject.conditions[name] else { continue }
                if condition.samples.count != channelCount {
                    channelOffenders.append(subject.name)
                    break
                }
            }
        }
        guard channelOffenders.isEmpty else {
            throw PreparationError.channelCountMismatch(channelOffenders, channelCount)
        }

        // 3. The time window, in samples relative to stimulus onset, clipped to
        //    the interval *every* contributing epoch can supply.
        let epochs = epochSummaries(candidates: candidates, required: required, samplingRate: samplingRate)
        guard let common = commonRelativeSampleWindow(candidates: candidates, required: required) else {
            throw PreparationError.invalidWindow
        }
        let startRelative = Int((job.windowStartMs * samplingRate / 1_000).rounded())
        let endRelative = Int((job.windowEndMs * samplingRate / 1_000).rounded())
        guard startRelative >= common.lowerBound,
              endRelative <= common.upperBound,
              endRelative > startRelative else {
            let lower = Double(common.lowerBound) / samplingRate * 1_000
            let upper = Double(common.upperBound) / samplingRate * 1_000
            // Name whoever is setting the binding constraint: a subject sitting
            // on the common bound, on a side where somebody else reaches
            // further. When every epoch is the same shape nobody is singled
            // out, and the range alone is the whole story.
            let loosestStart = epochs.map(\.startMs).min() ?? lower
            let furthestEnd = epochs.map(\.endMs).max() ?? upper
            let limiting = epochs.filter { epoch in
                (abs(epoch.startMs - lower) < 1e-9 && lower > loosestStart + 1e-9)
                    || (abs(epoch.endMs - upper) < 1e-9 && upper < furthestEnd - 1e-9)
            }
            .map(\.subject)
            throw PreparationError.windowOutsideEpoch(lower, upper, limiting)
        }
        let stride = max(job.sampleStride, 1)
        let relativeOffsets = Array(Swift.stride(from: startRelative, through: endRelative, by: stride))
        guard relativeOffsets.count > 1 else { throw PreparationError.invalidWindow }

        // 4. Channels: only those the sensor layout can place, since spatial
        //    adjacency is meaningless without coordinates.
        let layoutChannels = Set(job.sensorLayout?.positions.map(\.channelIndex) ?? [])
        let channels = layoutChannels.isEmpty
            ? Array(0..<channelCount)
            : (0..<channelCount).filter { layoutChannels.contains($0) }
        guard !channels.isEmpty else { throw PreparationError.noChannels }

        let configuredAdjacency = ClusterSpatialAdjacency.build(
            channelIndices: channels,
            layout: job.sensorLayout,
            configuration: job.adjacency
        )
        let nearestNeighborSpacing = ClusterSpatialAdjacency.medianNearestNeighborDistance(
            channelIndices: channels,
            layout: job.sensorLayout
        )
        let resolvedETACRadii: [Double]?
        let etacAdjacencies: [[[Int]]]
        if job.inference == .etac, let nearestNeighborSpacing {
            let radii = job.etac.orderedRadiusMultipliers.map {
                min($0 * nearestNeighborSpacing, 2.0)
            }
            resolvedETACRadii = radii
            etacAdjacencies = radii.map { radius in
                ClusterSpatialAdjacency.build(
                    channelIndices: channels,
                    layout: job.sensorLayout,
                    configuration: ClusterAdjacencyConfiguration(method: .distance, distance: radius)
                )
            }
        } else {
            resolvedETACRadii = nil
            // Without a sensor layout ETAC still sweeps statistic thresholds,
            // using the same temporal-only graph as the other corrections.
            etacAdjacencies = []
        }
        let adjacency = etacAdjacencies.last ?? configuredAdjacency

        // 5. Flatten, then collapse the within-subject dimension if the design
        //    calls for a subject measure. Each condition is indexed through its
        //    own onset, which is what makes differing baselines harmless.
        func matrix(_ subject: ClusterSubjectSnapshot, _ conditionName: String) -> [Double]? {
            guard let condition = subject.conditions[conditionName] else { return nil }
            return flatten(
                condition.samples,
                channels: channels,
                sampleOffsets: relativeOffsets.map { condition.baselineSamples + $0 }
            )
        }

        if job.design.isWithinSubject {
            let conditions = job.design.conditionNames
            var perCondition = [[[Double]]](repeating: [], count: conditions.count)
            var contributing: [String] = []
            for subject in candidates {
                let matrices = conditions.compactMap { matrix(subject, $0) }
                guard matrices.count == conditions.count else {
                    excluded.append(ClusterExcludedSubject(
                        name: subject.name,
                        reason: "condition data could not be read"
                    ))
                    continue
                }
                for (index, values) in matrices.enumerated() { perCondition[index].append(values) }
                contributing.append(subject.name)
            }
            guard contributing.count >= 2 else { throw PreparationError.tooFewSubjects(contributing.count) }

            return PreparedData(
                series: conditions.enumerated().map { PreparedSeries(name: $1, units: perCondition[$0]) },
                channelIndices: channels,
                relativeSampleOffsets: relativeOffsets,
                spatialAdjacency: adjacency,
                etacSpatialAdjacencies: etacAdjacencies,
                resolvedETACRadii: resolvedETACRadii,
                nearestNeighborSpacing: nearestNeighborSpacing,
                samplingRate: samplingRate,
                measureLabel: "Condition mean amplitude (µV)",
                contributingSubjects: contributing,
                excludedSubjects: excluded,
                epochs: epochs
            )
        }

        guard let measure = job.design.measure else { throw PreparationError.invalidDesign }
        var byGroup: [String: [[Double]]] = [:]
        var contributing: [String] = []
        for subject in candidates {
            guard let collapsed = collapse(measure, subject: subject, matrix: matrix) else {
                excluded.append(ClusterExcludedSubject(
                    name: subject.name,
                    reason: "condition data could not be read"
                ))
                continue
            }
            byGroup[subject.groupLabel, default: []].append(collapsed)
            contributing.append(subject.name)
        }
        for group in groups {
            let count = byGroup[group]?.count ?? 0
            guard count > 0 else { throw PreparationError.emptyGroup(group) }
            guard count >= 2 else { throw PreparationError.singleSubjectGroup(group, count) }
        }
        return PreparedData(
            series: groups.map { PreparedSeries(name: $0, units: byGroup[$0] ?? []) },
            channelIndices: channels,
            relativeSampleOffsets: relativeOffsets,
            spatialAdjacency: adjacency,
            etacSpatialAdjacencies: etacAdjacencies,
            resolvedETACRadii: resolvedETACRadii,
            nearestNeighborSpacing: nearestNeighborSpacing,
            samplingRate: samplingRate,
            measureLabel: "\(measure.label) (µV)",
            contributingSubjects: contributing,
            excludedSubjects: excluded,
            epochs: epochs
        )
    }

    /// Collapses one subject's conditions into the single matrix a
    /// between-subject or mixed design compares. Doing this *before* the
    /// permutation is exactly what lets the interaction reuse the independent
    /// statistic without a mixed-model exchangeability argument.
    private static func collapse(
        _ measure: SubjectMeasure,
        subject: ClusterSubjectSnapshot,
        matrix: (ClusterSubjectSnapshot, String) -> [Double]?
    ) -> [Double]? {
        switch measure {
        case .condition(let name):
            return matrix(subject, name)
        case .difference(let a, let b):
            guard let first = matrix(subject, a), let second = matrix(subject, b) else { return nil }
            var result = first
            ClusterPermutationAnalyzer.subtract(second, from: &result)
            return result
        case .mean(let names):
            let matrices = names.compactMap { matrix(subject, $0) }
            guard matrices.count == names.count, let first = matrices.first else { return nil }
            var sums = [Double](repeating: 0, count: first.count)
            for values in matrices { ClusterPermutationAnalyzer.add(values, to: &sums) }
            let scale = Double(matrices.count)
            for index in sums.indices { sums[index] /= scale }
            return sums
        }
    }

    /// `channels × samples` Float matrix -> flattened channel-major Double.
    static func flatten(
        _ samples: [[Float]],
        channels: [Int],
        sampleOffsets: [Int]
    ) -> [Double]? {
        var result = [Double](repeating: 0, count: channels.count * sampleOffsets.count)
        for (localChannel, channel) in channels.enumerated() {
            guard channel < samples.count else { return nil }
            let row = samples[channel]
            for (localSample, offset) in sampleOffsets.enumerated() {
                guard offset < row.count else { return nil }
                let value = Double(row[offset])
                guard value.isFinite else { return nil }
                result[localChannel * sampleOffsets.count + localSample] = value
            }
        }
        return result
    }

    /// Per-subject epoch geometry, taking each subject's tightest required
    /// condition. Public so the UI can show the same numbers the run uses.
    static func epochSummaries(
        candidates: [ClusterSubjectSnapshot],
        required: [String],
        samplingRate: Double
    ) -> [ClusterEpochSummary] {
        candidates.compactMap { subject -> ClusterEpochSummary? in
            var baseline = 0
            var sampleCount = Int.max
            var lower = Int.min
            var upper = Int.max
            var found = false
            for name in required {
                guard let condition = subject.conditions[name], condition.sampleCount > 1 else { continue }
                found = true
                baseline = max(baseline, condition.baselineSamples)
                sampleCount = min(sampleCount, condition.sampleCount)
                lower = max(lower, -condition.baselineSamples)
                upper = min(upper, condition.sampleCount - 1 - condition.baselineSamples)
            }
            guard found, lower <= upper, samplingRate > 0 else { return nil }
            return ClusterEpochSummary(
                subject: subject.name,
                baselineSamples: baseline,
                sampleCount: sampleCount,
                startMs: Double(lower) / samplingRate * 1_000,
                endMs: Double(upper) / samplingRate * 1_000
            )
        }
    }

    /// The stimulus-relative sample interval every contributing epoch can
    /// supply. This — not an identical baseline — is the real requirement.
    static func commonRelativeSampleWindow(
        candidates: [ClusterSubjectSnapshot],
        required: [String]
    ) -> ClosedRange<Int>? {
        var lower = Int.min
        var upper = Int.max
        var found = false
        for subject in candidates {
            for name in required {
                guard let condition = subject.conditions[name], condition.sampleCount > 1 else { continue }
                found = true
                lower = max(lower, -condition.baselineSamples)
                upper = min(upper, condition.sampleCount - 1 - condition.baselineSamples)
            }
        }
        guard found, lower < upper else { return nil }
        return lower...upper
    }

    /// The stimulus-relative interval an epoch of this shape can supply.
    static func availableWindowMilliseconds(
        baselineSamples: Int,
        sampleCount: Int,
        samplingRate: Double
    ) -> ClosedRange<Double> {
        guard samplingRate > 0, sampleCount > 1 else { return 0...0 }
        let lower = Double(-baselineSamples) / samplingRate * 1_000
        let upper = Double(sampleCount - 1 - baselineSamples) / samplingRate * 1_000
        return lower <= upper ? lower...upper : upper...lower
    }

    // MARK: - Waveform summaries

    /// Components shown at one corrected alpha. Fixed-threshold cluster mass
    /// has cluster-level p-values, so alpha only filters whole clusters. TFCE
    /// and ETAC expose point p-values and therefore need fresh connected
    /// components at each alpha; otherwise a single stringent point would make
    /// its entire .10 display component appear stringent.
    static func displayClusters(
        analysis: ClusterPermutationAnalysis,
        spatialAdjacency: [[Int]],
        alpha: Double
    ) -> [SpatiotemporalCluster] {
        guard analysis.inference != .clusterMass,
              let pointPValues = analysis.pointPValues,
              pointPValues.count == analysis.channelCount * analysis.sampleCount else {
            return analysis.clusters.filter { $0.pValue <= alpha }
        }

        let scores: [Double]
        switch analysis.inference {
        case .clusterMass:
            return analysis.clusters.filter { $0.pValue <= alpha }
        case .tfce:
            guard let tfceScores = analysis.observedTFCEScores else { return [] }
            scores = tfceScores
        case .etac:
            scores = analysis.observedStatistics
        }

        let grid = ClusterGrid(
            channelCount: analysis.channelCount,
            sampleCount: analysis.sampleCount,
            spatialAdjacency: spatialAdjacency
        )
        let candidates = grid.componentsOfSignificantPoints(
            scores: scores,
            pValues: pointPValues,
            alpha: alpha,
            signed: analysis.statistic == .t,
            workspace: grid.makeWorkspace()
        )
        let clusters = candidates.map { candidate in
            let mass: Double
            if analysis.inference == .tfce {
                mass = candidate.mass
            } else {
                mass = candidate.points.reduce(0) { $0 + abs(analysis.observedStatistics[$1]) }
            }
            return SpatiotemporalCluster(
                id: 0,
                sign: candidate.sign,
                pointIndices: candidate.points,
                mass: mass,
                pValue: candidate.points.map { pointPValues[$0] }.min() ?? 1,
                startSample: candidate.startSample,
                endSample: candidate.endSample,
                channelIndices: candidate.channels
            )
        }
        return ClusterCorrection.sortedForDisplay(clusters)
    }

    private static func waveformSummaries(
        analysis: ClusterPermutationAnalysis,
        series: [PreparedSeries]
    ) -> [Int: [String: ClusterWaveformSummary]] {
        waveformSummaries(
            clusters: analysis.clusters.filter { $0.pValue <= 0.10 },
            sampleCount: analysis.sampleCount,
            series: series
        )
    }

    private static func waveformSummaries(
        clusters: [SpatiotemporalCluster],
        sampleCount: Int,
        series: [PreparedSeries]
    ) -> [Int: [String: ClusterWaveformSummary]] {
        var summaries: [Int: [String: ClusterWaveformSummary]] = [:]
        for cluster in clusters {
            var byName: [String: ClusterWaveformSummary] = [:]
            for entry in series {
                byName[entry.name] = waveformSummary(
                    units: entry.units,
                    channelIndices: cluster.channelIndices,
                    sampleCount: sampleCount
                )
            }
            summaries[cluster.id] = byName
        }
        return summaries
    }

    /// Mean and across-subject SEM of the cluster-sensor average, per sample.
    static func waveformSummary(
        units: [[Double]],
        channelIndices: [Int],
        sampleCount: Int
    ) -> ClusterWaveformSummary {
        guard !units.isEmpty, !channelIndices.isEmpty, sampleCount > 0 else {
            return ClusterWaveformSummary(
                mean: [Double](repeating: 0, count: max(sampleCount, 0)),
                standardError: [Double](repeating: 0, count: max(sampleCount, 0))
            )
        }

        var means = [Double](repeating: 0, count: sampleCount)
        var standardErrors = [Double](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            // Welford, so a long window does not accumulate cancellation error.
            var runningMean = 0.0
            var sumSquaredDeviations = 0.0
            var count = 0
            for unit in units {
                var sensorSum = 0.0
                var sensorCount = 0
                for channel in channelIndices {
                    let feature = channel * sampleCount + sample
                    guard unit.indices.contains(feature) else { continue }
                    sensorSum += unit[feature]
                    sensorCount += 1
                }
                guard sensorCount > 0 else { continue }
                let subjectMean = sensorSum / Double(sensorCount)
                count += 1
                let delta = subjectMean - runningMean
                runningMean += delta / Double(count)
                sumSquaredDeviations += delta * (subjectMean - runningMean)
            }
            means[sample] = runningMean
            if count > 1 {
                let variance = sumSquaredDeviations / Double(count - 1)
                standardErrors[sample] = sqrt(max(variance, 0) / Double(count))
            }
        }
        return ClusterWaveformSummary(mean: means, standardError: standardErrors)
    }

    // MARK: - Error text

    private static func message(for error: ClusterPermutationAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions:
            return "The prepared subject matrices do not have compatible dimensions."
        case .insufficientSubjects:
            return "Each cell of the design needs at least two subjects."
        case .invalidConfiguration:
            return "Choose a positive cluster-forming threshold and permutation count."
        case .unbalancedPairs:
            return "A within-subject design needs the same subjects in both conditions."
        }
    }

    private static func message(for error: ClusterPermutationFAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions:
            return "The prepared subject matrices do not have compatible dimensions."
        case .insufficientLevels:
            return "An omnibus F-test needs at least three conditions or groups."
        case .insufficientSubjects:
            return "Each cell of the design needs at least two subjects."
        case .invalidConfiguration:
            return "Choose a positive cluster-forming F threshold and permutation count."
        case .unbalancedUnits:
            return "A repeated-measures design needs the same subjects in every condition."
        }
    }
}
