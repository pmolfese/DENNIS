//
//  ClusterPermutationAnalyzer.swift
//  DENNIS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Deterministic two-sample spatiotemporal cluster permutation statistics, with
//  the *subject* as the exchangeable unit.
//
//  Two exchangeability schemes are supported, and they answer different
//  questions. Under `.independent` the subjects belong to unrelated groups and
//  group labels are shuffled freely, preserving group sizes. Under
//  `.repeatedMeasures` each subject contributes both conditions, and only the
//  sign of that subject's difference is exchangeable. Applying the independent
//  scheme to within-subject data discards the pairing that makes the design
//  sensitive and is anticonservative when subjects differ systematically from
//  one another.
//
//  References (full citations in `References.swift`):
//    - Maris & Oostenveld (2007), J Neurosci Methods 164(1):177-190 — the test.
//    - Nichols & Holmes (2002), Hum Brain Mapp 15(1):1-25 — the max-statistic
//      framework, and sign flipping as the within-subject scheme.
//    - Winkler, Ridgway, Webster, Smith & Nichols (2014), NeuroImage 92:381-397
//      — which relabelings are exchangeable in a given design.
//    - Ernst (2004), Statist Sci 19(4):676-685 — systematic enumeration and the
//      exact p-value it yields at small N.
//

import Accelerate
import Foundation

nonisolated enum ClusterPermutationAnalyzer {
    typealias Cluster = SpatiotemporalCluster

    // MARK: - Inputs

    nonisolated enum Design: String, CaseIterable, Identifiable, Sendable, Equatable {
        case independent = "Independent"
        case repeatedMeasures = "Paired"

        var id: String { rawValue }
    }

    /// One side of the comparison: a group of subjects, or all subjects
    /// measured in one condition.
    struct Sample: Sendable {
        let name: String
        /// One flattened channel-major matrix per subject:
        /// channel 0's samples, then channel 1's samples, and so on.
        let units: [[Double]]
    }

    struct Input: Sendable {
        let sampleA: Sample
        let sampleB: Sample
        let channelCount: Int
        let sampleCount: Int
        /// Local channel index -> local neighboring channel indices.
        let spatialAdjacency: [[Int]]
        let design: Design

        init(
            sampleA: Sample,
            sampleB: Sample,
            channelCount: Int,
            sampleCount: Int,
            spatialAdjacency: [[Int]],
            design: Design = .independent
        ) {
            self.sampleA = sampleA
            self.sampleB = sampleB
            self.channelCount = channelCount
            self.sampleCount = sampleCount
            self.spatialAdjacency = spatialAdjacency
            self.design = design
        }
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        /// How the cluster-forming threshold was specified. Ignored under TFCE.
        var threshold = ClusterFormingThreshold.statistic(2.0)
        var inference = ClusterInferenceMode.clusterMass
        var tfce = TFCEParameters.default
        var seed: UInt64 = 0xE7A_C1A5_7E57

        init(
            permutationCount: Int = 1_000,
            threshold: ClusterFormingThreshold = .statistic(2.0),
            inference: ClusterInferenceMode = .clusterMass,
            tfce: TFCEParameters = .default,
            seed: UInt64 = 0xE7A_C1A5_7E57
        ) {
            self.permutationCount = permutationCount
            self.threshold = threshold
            self.inference = inference
            self.tfce = tfce
            self.seed = seed
        }
    }

    struct Result: Sendable, Equatable {
        let sampleAName: String
        let sampleBName: String
        let sampleACount: Int
        let sampleBCount: Int
        let design: Design
        /// Matched subjects under `.repeatedMeasures`; nil otherwise.
        let pairCount: Int?
        let degreesOfFreedom: Double
        let channelCount: Int
        let sampleCount: Int
        let observedStatistics: [Double]
        /// Populated under TFCE only.
        let observedTFCEScores: [Double]?
        /// Point-wise corrected p-values; populated under TFCE only.
        let pointPValues: [Double]?
        /// The `|t|` actually used to form clusters, after resolving a
        /// probability threshold against the design's df. Nil under TFCE.
        let resolvedThreshold: Double?
        let clusters: [Cluster]
        let nullMaximumClusterMasses: [Double]
        let rearrangements: ClusterRearrangementPlan
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientSubjects
        case invalidConfiguration
        case unbalancedPairs
    }

    // MARK: - Entry point

    /// Returns `nil` when the surrounding task is cancelled.
    static func analyze(
        input: Input,
        configuration: Configuration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result? {
        let featureCount = input.channelCount * input.sampleCount
        let dimensionsMatch = input.sampleA.units.allSatisfy { $0.count == featureCount }
            && input.sampleB.units.allSatisfy { $0.count == featureCount }
        guard input.channelCount > 0,
              input.sampleCount > 0,
              input.spatialAdjacency.count == input.channelCount,
              dimensionsMatch else {
            throw AnalysisError.invalidDimensions
        }
        let nA = input.sampleA.units.count
        let nB = input.sampleB.units.count
        guard nA >= 2, nB >= 2 else { throw AnalysisError.insufficientSubjects }
        guard configuration.permutationCount > 0 else { throw AnalysisError.invalidConfiguration }
        if configuration.inference == .tfce {
            guard configuration.tfce.isValid else { throw AnalysisError.invalidConfiguration }
        }
        if input.design == .repeatedMeasures, nA != nB {
            throw AnalysisError.unbalancedPairs
        }

        let degreesOfFreedom = input.design == .repeatedMeasures
            ? Double(nA - 1)
            : Double(nA + nB - 2)
        guard degreesOfFreedom > 0 else { throw AnalysisError.insufficientSubjects }

        let resolvedThreshold: Double?
        if configuration.inference == .clusterMass {
            guard let value = resolveThreshold(configuration.threshold, degreesOfFreedom: degreesOfFreedom) else {
                throw AnalysisError.invalidConfiguration
            }
            resolvedThreshold = value
        } else {
            resolvedThreshold = nil
        }

        let plan = ClusterRearrangements.plan(
            rearrangementKind(input: input),
            requestedCount: configuration.permutationCount
        )

        let grid = ClusterGrid(
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            spatialAdjacency: input.spatialAdjacency
        )

        switch input.design {
        case .independent:
            return try analyzeIndependent(
                input: input,
                configuration: configuration,
                plan: plan,
                grid: grid,
                degreesOfFreedom: degreesOfFreedom,
                resolvedThreshold: resolvedThreshold,
                progress: progress
            )
        case .repeatedMeasures:
            return try analyzePaired(
                input: input,
                configuration: configuration,
                plan: plan,
                grid: grid,
                degreesOfFreedom: degreesOfFreedom,
                resolvedThreshold: resolvedThreshold,
                progress: progress
            )
        }
    }

    static func rearrangementKind(input: Input) -> ClusterRearrangementKind {
        switch input.design {
        case .repeatedMeasures:
            return .signFlip(unitCount: input.sampleA.units.count)
        case .independent:
            return .groupLabels(sizes: [input.sampleA.units.count, input.sampleB.units.count])
        }
    }

    static func resolveThreshold(
        _ threshold: ClusterFormingThreshold,
        degreesOfFreedom: Double
    ) -> Double? {
        switch threshold {
        case .statistic(let value):
            guard value.isFinite, value > 0 else { return nil }
            return value
        case .probability(let alpha):
            guard alpha > 0, alpha < 1 else { return nil }
            return ClusterStatisticsDistributions.criticalT(
                twoTailedAlpha: alpha,
                degreesOfFreedom: degreesOfFreedom
            )
        }
    }

    // MARK: - Independent samples

    private static func analyzeIndependent(
        input: Input,
        configuration: Configuration,
        plan: ClusterRearrangementPlan,
        grid: ClusterGrid,
        degreesOfFreedom: Double,
        resolvedThreshold: Double?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> Result? {
        let featureCount = grid.featureCount
        let nA = input.sampleA.units.count
        let nB = input.sampleB.units.count

        let units = input.sampleA.units + input.sampleB.units
        let totalCount = units.count
        var totalSums = [Double](repeating: 0, count: featureCount)
        var totalSumSquares = [Double](repeating: 0, count: featureCount)
        for unit in units {
            add(unit, to: &totalSums)
            addSquares(unit, to: &totalSumSquares)
        }
        // Freeze the accumulated arrays before they cross the concurrent
        // permutation boundary. Their contents are read-only from here on.
        let fixedTotalSums = totalSums
        let fixedTotalSumSquares = totalSumSquares

        var observedGroupSums = [Double](repeating: 0, count: featureCount)
        for unit in input.sampleA.units {
            add(unit, to: &observedGroupSums)
        }
        let observed = independentTStatistics(
            groupASums: observedGroupSums,
            totalSums: fixedTotalSums,
            totalSumSquares: fixedTotalSumSquares,
            nA: nA,
            nB: nB
        )

        let outcome = try runPermutations(
            grid: grid,
            configuration: configuration,
            plan: plan,
            resolvedThreshold: resolvedThreshold,
            observed: observed,
            progress: progress
        ) { _, arrangement, rng, _ in
            var groupSums = [Double](repeating: 0, count: featureCount)
            if let arrangement {
                for (unit, label) in arrangement.enumerated() where label == 0 {
                    add(units[unit], to: &groupSums)
                }
            } else {
                var indices = Array(0..<totalCount)
                shufflePrefix(&indices, prefixCount: nA, using: &rng)
                for offset in 0..<nA {
                    add(units[indices[offset]], to: &groupSums)
                }
            }
            return independentTStatistics(
                groupASums: groupSums,
                totalSums: fixedTotalSums,
                totalSumSquares: fixedTotalSumSquares,
                nA: nA,
                nB: nB
            )
        }
        guard let outcome else { return nil }

        return Result(
            sampleAName: input.sampleA.name,
            sampleBName: input.sampleB.name,
            sampleACount: nA,
            sampleBCount: nB,
            design: .independent,
            pairCount: nil,
            degreesOfFreedom: degreesOfFreedom,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            rearrangements: plan,
            configuration: configuration
        )
    }

    /// Equal-variance independent-samples t. Under the label-exchangeability
    /// null, this studentized statistic works with unequal group sizes without
    /// throwing away subjects merely to equalize counts.
    static func independentTStatistics(
        groupASums: [Double],
        totalSums: [Double],
        totalSumSquares: [Double],
        nA: Int,
        nB: Int
    ) -> [Double] {
        let a = Double(nA)
        let b = Double(nB)
        let degreesOfFreedom = Double(nA + nB - 2)
        let scale = (1 / a) + (1 / b)
        var result = [Double](repeating: 0, count: groupASums.count)
        guard degreesOfFreedom > 0 else { return result }

        for feature in result.indices {
            let sumA = groupASums[feature]
            let sumB = totalSums[feature] - sumA
            let meanDifference = (sumA / a) - (sumB / b)
            // Within-group SS derived from invariant total sum-of-squares.
            let withinSS = max(totalSumSquares[feature] - (sumA * sumA / a) - (sumB * sumB / b), 0)
            let denominator = sqrt((withinSS / degreesOfFreedom) * scale)
            if denominator > 1e-15, denominator.isFinite {
                let value = meanDifference / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    // MARK: - Repeated measures (paired)

    private static func analyzePaired(
        input: Input,
        configuration: Configuration,
        plan: ClusterRearrangementPlan,
        grid: ClusterGrid,
        degreesOfFreedom: Double,
        resolvedThreshold: Double?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> Result? {
        let featureCount = grid.featureCount
        let pairCount = input.sampleA.units.count

        // The paired design collapses to a one-sample test on differences.
        var differences: [[Double]] = []
        differences.reserveCapacity(pairCount)
        for index in 0..<pairCount {
            let a = input.sampleA.units[index]
            let b = input.sampleB.units[index]
            var difference = [Double](repeating: 0, count: featureCount)
            for feature in 0..<featureCount {
                difference[feature] = a[feature] - b[feature]
            }
            differences.append(difference)
        }
        let fixedDifferences = differences

        // Sign flipping leaves every squared difference untouched, so the
        // sum-of-squares term is computed once and reused by every permutation.
        var sumSquares = [Double](repeating: 0, count: featureCount)
        for difference in fixedDifferences {
            addSquares(difference, to: &sumSquares)
        }
        let fixedSumSquares = sumSquares

        var observedSums = [Double](repeating: 0, count: featureCount)
        for difference in fixedDifferences {
            add(difference, to: &observedSums)
        }
        let observed = pairedTStatistics(
            sums: observedSums,
            sumSquares: fixedSumSquares,
            pairCount: pairCount
        )

        let outcome = try runPermutations(
            grid: grid,
            configuration: configuration,
            plan: plan,
            resolvedThreshold: resolvedThreshold,
            observed: observed,
            progress: progress
        ) { _, arrangement, rng, _ in
            var sums = [Double](repeating: 0, count: featureCount)
            for (index, difference) in fixedDifferences.enumerated() {
                // One fair coin per subject: the exchangeable unit under the
                // repeated-measures null is the sign of the difference.
                let keepsSign = arrangement.map { $0[index] == 0 } ?? Bool.random(using: &rng)
                if keepsSign {
                    add(difference, to: &sums)
                } else {
                    subtract(difference, from: &sums)
                }
            }
            return pairedTStatistics(
                sums: sums,
                sumSquares: fixedSumSquares,
                pairCount: pairCount
            )
        }
        guard let outcome else { return nil }

        return Result(
            sampleAName: input.sampleA.name,
            sampleBName: input.sampleB.name,
            sampleACount: pairCount,
            sampleBCount: pairCount,
            design: .repeatedMeasures,
            pairCount: pairCount,
            degreesOfFreedom: degreesOfFreedom,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            rearrangements: plan,
            configuration: configuration
        )
    }

    /// One-sample t on the paired differences.
    static func pairedTStatistics(
        sums: [Double],
        sumSquares: [Double],
        pairCount: Int
    ) -> [Double] {
        let n = Double(pairCount)
        var result = [Double](repeating: 0, count: sums.count)
        guard pairCount > 1 else { return result }
        let degreesOfFreedom = n - 1

        for feature in result.indices {
            let sum = sums[feature]
            let mean = sum / n
            let deviationSS = max(sumSquares[feature] - (sum * sum / n), 0)
            let standardError = sqrt((deviationSS / degreesOfFreedom) / n)
            if standardError > 1e-15, standardError.isFinite {
                let value = mean / standardError
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    // MARK: - Shared permutation driver

    struct PermutationOutcome {
        let clusters: [Cluster]
        let nullMaxima: [Double]
        let tfceScores: [Double]?
        let pointPValues: [Double]?
    }

    /// Drives the permutation loop for either design and either inference mode.
    /// `statisticsForRearrangement` returns the full statistic map for one
    /// relabeling; everything downstream — cluster growth, TFCE, correction —
    /// is identical between designs.
    ///
    /// The second closure argument is the explicit rearrangement under
    /// systematic enumeration, and `nil` when sampling. Every branch that
    /// consumes it must fall back to the generator so a single closure serves
    /// both modes.
    ///
    /// Returns `nil` when the surrounding task is cancelled.
    static func runPermutations(
        grid: ClusterGrid,
        configuration: Configuration,
        plan: ClusterRearrangementPlan,
        resolvedThreshold: Double?,
        observed: [Double],
        signed: Bool = true,
        progress: (@Sendable (Double) -> Void)?,
        statisticsForRearrangement: @escaping @Sendable (Int, [Int]?, inout SplitMix64, ClusterGrid.Workspace) -> [Double]
    ) throws -> PermutationOutcome? {
        // Give each permutation an index-stable seed before parallel work
        // begins. Results therefore do not depend on thread scheduling.
        var seedSource = SplitMix64(seed: configuration.seed)
        let permutationSeeds = (0..<plan.count).map { _ in seedSource.next() }
        let arrangements = plan.arrangements
        let nullStorage = PermutationValueStorage(count: plan.count)
        defer { nullStorage.deallocate() }

        let observedTFCE: [Double]? = configuration.inference == .tfce
            ? grid.tfceScores(statistics: observed, signed: signed, parameters: configuration.tfce)
            : nil

        // Process several waves rather than one monolithic concurrentPerform.
        // Besides keeping all CPU cores occupied, this returns to the parent
        // Swift task regularly so cancellation remains responsive.
        let workerCount = WorkerPool.maxWorkers(for: plan.count)
        let batchSize = max(workerCount * 4, 1)
        var completed = 0
        let inference = configuration.inference
        let tfceParameters = configuration.tfce
        let threshold = resolvedThreshold ?? 0

        while completed < plan.count {
            if Task.isCancelled { return nil }
            let batchStart = completed
            let batchCount = min(batchSize, plan.count - batchStart)
            WorkerPool.concurrentPerform(iterations: batchCount) { batchOffset in
                let permutation = batchStart + batchOffset
                var rng = SplitMix64(seed: permutationSeeds[permutation])
                let workspace = grid.makeWorkspace()
                let arrangement = arrangements?[permutation]
                let statistics = statisticsForRearrangement(permutation, arrangement, &rng, workspace)
                switch inference {
                case .clusterMass:
                    nullStorage[permutation] = grid.maximumClusterMass(
                        statistics: statistics,
                        threshold: threshold,
                        signed: signed,
                        workspace: workspace
                    )
                case .tfce:
                    let scores = grid.tfceScores(
                        statistics: statistics,
                        signed: signed,
                        parameters: tfceParameters
                    )
                    nullStorage[permutation] = scores.reduce(0) { max($0, abs($1)) }
                }
            }
            completed += batchCount
            progress?(Double(completed) / Double(plan.count))
        }
        let nullMaxima = nullStorage.values
        let exhaustive = plan.isExhaustive

        let workspace = grid.makeWorkspace()
        switch inference {
        case .clusterMass:
            let candidates = grid.formClusters(
                statistics: observed,
                threshold: threshold,
                signed: signed,
                workspace: workspace
            )
            let clusters = candidates.map { candidate in
                Cluster(
                    id: 0,
                    sign: candidate.sign,
                    pointIndices: candidate.points,
                    mass: candidate.mass,
                    pValue: ClusterCorrection.pValue(
                        observed: candidate.mass,
                        nullMaxima: nullMaxima,
                        exhaustive: exhaustive
                    ),
                    startSample: candidate.startSample,
                    endSample: candidate.endSample,
                    channelIndices: candidate.channels
                )
            }
            return PermutationOutcome(
                clusters: ClusterCorrection.sortedForDisplay(clusters),
                nullMaxima: nullMaxima,
                tfceScores: nil,
                pointPValues: nil
            )
        case .tfce:
            let scores = observedTFCE ?? []
            let pointPValues = ClusterCorrection.pointPValues(
                scores: scores,
                nullMaxima: nullMaxima,
                exhaustive: exhaustive
            )
            // Group the surviving points at the most permissive alpha the UI
            // offers, so the alpha control can still filter afterwards.
            let candidates = grid.componentsOfSignificantPoints(
                scores: scores,
                pValues: pointPValues,
                alpha: 0.10,
                signed: signed,
                workspace: workspace
            )
            let clusters = candidates.map { candidate -> Cluster in
                let best = candidate.points.map { pointPValues[$0] }.min() ?? 1
                return Cluster(
                    id: 0,
                    sign: candidate.sign,
                    pointIndices: candidate.points,
                    mass: candidate.mass,
                    pValue: best,
                    startSample: candidate.startSample,
                    endSample: candidate.endSample,
                    channelIndices: candidate.channels
                )
            }
            return PermutationOutcome(
                clusters: ClusterCorrection.sortedForDisplay(clusters),
                nullMaxima: nullMaxima,
                tfceScores: scores,
                pointPValues: pointPValues
            )
        }
    }

    // MARK: - Vector helpers

    static func add(_ source: [Double], to destination: inout [Double]) {
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else { return }
                vDSP_vaddD(sourceBase, 1, destinationBase, 1, destinationBase, 1, vDSP_Length(source.count))
            }
        }
    }

    static func subtract(_ source: [Double], from destination: inout [Double]) {
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else { return }
                vDSP_vsubD(sourceBase, 1, destinationBase, 1, destinationBase, 1, vDSP_Length(source.count))
            }
        }
    }

    static func addSquares(_ source: [Double], to destination: inout [Double]) {
        for index in source.indices {
            destination[index] += source[index] * source[index]
        }
    }

    /// Partial Fisher-Yates: only the first `prefixCount` positions need to be
    /// a uniformly sampled group.
    static func shufflePrefix<R: RandomNumberGenerator>(
        _ values: inout [Int],
        prefixCount: Int,
        using rng: inout R
    ) {
        guard prefixCount > 0, prefixCount <= values.count else { return }
        for index in 0..<prefixCount {
            let other = Int.random(in: index..<values.count, using: &rng)
            if index != other { values.swapAt(index, other) }
        }
    }
}
