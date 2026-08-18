//
//  ClusterPermutationFAnalyzer.swift
//  DENNIS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Omnibus spatiotemporal cluster permutation F-test, in both a one-way
//  between-subject and a one-way within-subject (repeated-measures) form.
//
//  The exchangeability schemes differ in an important way. The between-subject
//  form permutes group labels across the whole pool of subjects. The
//  within-subject form permutes condition labels *within* each subject, which
//  leaves the subject main effect intact under the null — the same restriction
//  that makes the repeated-measures F sensitive in the first place. Permuting
//  across subjects instead would test a null nobody asked about and would
//  inflate the error term with between-subject variance.
//
//  References (full citations in `References.swift`):
//    - Maris & Oostenveld (2007), J Neurosci Methods 164(1):177-190 — the
//      cluster test; the F statistic simply replaces t on the same lattice.
//    - Winkler et al. (2014), NeuroImage 92:381-397 — exchangeability under
//      within- versus between-subject relabeling.
//    - Anderson & ter Braak (2003), J Stat Comput Simul 73(2):85-113 — why this
//      stops at a one-way omnibus rather than attempting a factorial
//      permutation scheme.
//

import Foundation

nonisolated enum ClusterPermutationFAnalyzer {
    nonisolated enum Design: String, CaseIterable, Identifiable, Sendable, Equatable {
        case independent = "Independent"
        case repeatedMeasures = "Repeated measures"

        var id: String { rawValue }
    }

    /// One cell of the design: a between-subject group, or all subjects
    /// measured in one within-subject condition.
    struct Level: Sendable {
        let name: String
        /// One flattened channel-major matrix per subject.
        let units: [[Double]]
    }

    struct Input: Sendable {
        let levels: [Level]
        let channelCount: Int
        let sampleCount: Int
        let spatialAdjacency: [[Int]]
        let etacSpatialAdjacencies: [[[Int]]]
        let design: Design

        init(
            levels: [Level],
            channelCount: Int,
            sampleCount: Int,
            spatialAdjacency: [[Int]],
            etacSpatialAdjacencies: [[[Int]]] = [],
            design: Design = .independent
        ) {
            self.levels = levels
            self.channelCount = channelCount
            self.sampleCount = sampleCount
            self.spatialAdjacency = spatialAdjacency
            self.etacSpatialAdjacencies = etacSpatialAdjacencies
            self.design = design
        }
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        var threshold = ClusterFormingThreshold.statistic(4.0)
        var inference = ClusterInferenceMode.clusterMass
        var tfce = TFCEParameters.default
        var etac = ETACParameters.default
        var seed: UInt64 = 0xE7A_F1A5_7E57

        init(
            permutationCount: Int = 1_000,
            threshold: ClusterFormingThreshold = .statistic(4.0),
            inference: ClusterInferenceMode = .clusterMass,
            tfce: TFCEParameters = .default,
            etac: ETACParameters = .default,
            seed: UInt64 = 0xE7A_F1A5_7E57
        ) {
            self.permutationCount = permutationCount
            self.threshold = threshold
            self.inference = inference
            self.tfce = tfce
            self.etac = etac
            self.seed = seed
        }
    }

    struct Result: Sendable, Equatable {
        let levelNames: [String]
        let levelCounts: [Int]
        let design: Design
        /// Subjects contributing to every condition under repeated measures.
        let unitCount: Int?
        let channelCount: Int
        let sampleCount: Int
        let numeratorDegreesOfFreedom: Int
        let denominatorDegreesOfFreedom: Int
        let observedStatistics: [Double]
        let observedTFCEScores: [Double]?
        let pointPValues: [Double]?
        let resolvedThreshold: Double?
        let resolvedETACThresholds: [Double]?
        let clusters: [SpatiotemporalCluster]
        let nullMaximumClusterMasses: [Double]
        let rearrangements: ClusterRearrangementPlan
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientLevels
        case insufficientSubjects
        case invalidConfiguration
        case unbalancedUnits
    }

    // MARK: - Entry point

    static func analyze(
        input: Input,
        configuration: Configuration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result? {
        let featureCount = input.channelCount * input.sampleCount
        guard input.channelCount > 0,
              input.sampleCount > 0,
              input.spatialAdjacency.count == input.channelCount,
              input.etacSpatialAdjacencies.allSatisfy({ $0.count == input.channelCount }),
              input.levels.allSatisfy({ level in
                  level.units.allSatisfy { $0.count == featureCount }
              }) else { throw AnalysisError.invalidDimensions }
        guard input.levels.count >= 3 else { throw AnalysisError.insufficientLevels }
        guard input.levels.allSatisfy({ $0.units.count >= 2 }) else {
            throw AnalysisError.insufficientSubjects
        }
        guard configuration.permutationCount > 0 else { throw AnalysisError.invalidConfiguration }
        if configuration.inference == .tfce {
            guard configuration.tfce.isValid else { throw AnalysisError.invalidConfiguration }
        }
        if configuration.inference == .etac {
            guard configuration.etac.isValid else { throw AnalysisError.invalidConfiguration }
            if !input.etacSpatialAdjacencies.isEmpty {
                guard input.etacSpatialAdjacencies.count
                        == configuration.etac.radiusMultipliers.count else {
                    throw AnalysisError.invalidConfiguration
                }
            }
        }

        let levelCounts = input.levels.map { $0.units.count }
        let levelCount = input.levels.count
        let numeratorDF = levelCount - 1

        let denominatorDF: Int
        let unitCount: Int?
        switch input.design {
        case .independent:
            denominatorDF = levelCounts.reduce(0, +) - levelCount
            unitCount = nil
        case .repeatedMeasures:
            guard Set(levelCounts).count == 1 else { throw AnalysisError.unbalancedUnits }
            let units = levelCounts[0]
            denominatorDF = (levelCount - 1) * (units - 1)
            unitCount = units
        }
        guard denominatorDF > 0 else { throw AnalysisError.insufficientSubjects }

        let resolvedThreshold: Double?
        if configuration.inference == .clusterMass {
            guard let value = resolveThreshold(
                configuration.threshold,
                numeratorDegreesOfFreedom: Double(numeratorDF),
                denominatorDegreesOfFreedom: Double(denominatorDF)
            ) else { throw AnalysisError.invalidConfiguration }
            resolvedThreshold = value
        } else {
            resolvedThreshold = nil
        }
        let resolvedETACThresholds: [Double]?
        if configuration.inference == .etac {
            let values = configuration.etac.orderedProbabilities.compactMap {
                resolveThreshold(
                    .probability($0),
                    numeratorDegreesOfFreedom: Double(numeratorDF),
                    denominatorDegreesOfFreedom: Double(denominatorDF)
                )
            }
            guard values.count == configuration.etac.thresholdProbabilities.count else {
                throw AnalysisError.invalidConfiguration
            }
            resolvedETACThresholds = values
        } else {
            resolvedETACThresholds = nil
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
        let etacGrids = input.etacSpatialAdjacencies.map {
            ClusterGrid(
                channelCount: input.channelCount,
                sampleCount: input.sampleCount,
                spatialAdjacency: $0
            )
        }

        let observed: [Double]
        let permute: @Sendable (Int, [Int]?, inout SplitMix64, ClusterGrid.Workspace) -> [Double]

        switch input.design {
        case .independent:
            let units = input.levels.flatMap(\.units)
            let totalUnitCount = units.count
            var totalSums = [Double](repeating: 0, count: featureCount)
            var totalSumSquares = [Double](repeating: 0, count: featureCount)
            for unit in units {
                ClusterPermutationAnalyzer.add(unit, to: &totalSums)
                ClusterPermutationAnalyzer.addSquares(unit, to: &totalSumSquares)
            }
            let fixedTotalSums = totalSums
            let fixedTotalSumSquares = totalSumSquares

            let observedGroupSums = input.levels.map { level -> [Double] in
                var sums = [Double](repeating: 0, count: featureCount)
                for unit in level.units { ClusterPermutationAnalyzer.add(unit, to: &sums) }
                return sums
            }
            observed = independentFStatistics(
                groupSums: observedGroupSums,
                groupCounts: levelCounts,
                totalSums: fixedTotalSums,
                totalSumSquares: fixedTotalSumSquares
            )
            permute = { _, arrangement, rng, _ in
                var groupSums = [[Double]](
                    repeating: [Double](repeating: 0, count: featureCount),
                    count: levelCount
                )
                if let arrangement {
                    for (unit, label) in arrangement.enumerated() {
                        ClusterPermutationAnalyzer.add(units[unit], to: &groupSums[label])
                    }
                } else {
                    var indices = Array(0..<totalUnitCount)
                    shuffle(&indices, using: &rng)
                    var cursor = 0
                    for (group, count) in levelCounts.enumerated() {
                        for index in indices[cursor..<(cursor + count)] {
                            ClusterPermutationAnalyzer.add(units[index], to: &groupSums[group])
                        }
                        cursor += count
                    }
                }
                return independentFStatistics(
                    groupSums: groupSums,
                    groupCounts: levelCounts,
                    totalSums: fixedTotalSums,
                    totalSumSquares: fixedTotalSumSquares
                )
            }

        case .repeatedMeasures:
            let subjects = unitCount ?? 0
            // unitObservations[i][j] is subject i observed in condition j.
            let unitObservations: [[[Double]]] = (0..<subjects).map { unit in
                input.levels.map { $0.units[unit] }
            }
            let relabelings = ClusterRearrangements.permutations(ofCount: levelCount)

            // Everything except the condition sums is invariant under
            // within-subject relabeling, so it is computed once here.
            var grandSums = [Double](repeating: 0, count: featureCount)
            var totalSumSquares = [Double](repeating: 0, count: featureCount)
            var unitSumOfSquaredSums = [Double](repeating: 0, count: featureCount)
            for observations in unitObservations {
                var unitSums = [Double](repeating: 0, count: featureCount)
                for observation in observations {
                    ClusterPermutationAnalyzer.add(observation, to: &unitSums)
                    ClusterPermutationAnalyzer.addSquares(observation, to: &totalSumSquares)
                }
                ClusterPermutationAnalyzer.add(unitSums, to: &grandSums)
                ClusterPermutationAnalyzer.addSquares(unitSums, to: &unitSumOfSquaredSums)
            }
            let fixedGrandSums = grandSums
            let fixedTotalSumSquares = totalSumSquares
            let fixedUnitSumOfSquaredSums = unitSumOfSquaredSums

            let observedConditionSums = input.levels.map { level -> [Double] in
                var sums = [Double](repeating: 0, count: featureCount)
                for unit in level.units { ClusterPermutationAnalyzer.add(unit, to: &sums) }
                return sums
            }
            observed = repeatedMeasuresFStatistics(
                conditionSums: observedConditionSums,
                grandSums: fixedGrandSums,
                totalSumSquares: fixedTotalSumSquares,
                unitSumOfSquaredSums: fixedUnitSumOfSquaredSums,
                unitCount: subjects,
                conditionCount: levelCount
            )
            permute = { _, arrangement, rng, _ in
                var conditionSums = [[Double]](
                    repeating: [Double](repeating: 0, count: featureCount),
                    count: levelCount
                )
                var assignment = Array(0..<levelCount)
                for (unit, observations) in unitObservations.enumerated() {
                    // A fresh within-subject relabeling for every subject; the
                    // subject itself is never exchanged with any other.
                    if let arrangement {
                        assignment = relabelings[arrangement[unit]]
                    } else {
                        shuffle(&assignment, using: &rng)
                    }
                    for slot in 0..<levelCount {
                        ClusterPermutationAnalyzer.add(
                            observations[slot],
                            to: &conditionSums[assignment[slot]]
                        )
                    }
                }
                return repeatedMeasuresFStatistics(
                    conditionSums: conditionSums,
                    grandSums: fixedGrandSums,
                    totalSumSquares: fixedTotalSumSquares,
                    unitSumOfSquaredSums: fixedUnitSumOfSquaredSums,
                    unitCount: subjects,
                    conditionCount: levelCount
                )
            }
        }

        // F is non-negative, so clusters are grown without a sign constraint.
        let outcome = try ClusterPermutationAnalyzer.runPermutations(
            grid: grid,
            configuration: .init(
                permutationCount: configuration.permutationCount,
                threshold: configuration.threshold,
                inference: configuration.inference,
                tfce: configuration.tfce,
                etac: configuration.etac,
                seed: configuration.seed
            ),
            plan: plan,
            resolvedThreshold: resolvedThreshold,
            resolvedETACThresholds: resolvedETACThresholds,
            etacGrids: etacGrids,
            observed: observed,
            signed: false,
            progress: progress,
            statisticsForRearrangement: permute
        )
        guard let outcome else { return nil }

        return Result(
            levelNames: input.levels.map(\.name),
            levelCounts: levelCounts,
            design: input.design,
            unitCount: unitCount,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            numeratorDegreesOfFreedom: numeratorDF,
            denominatorDegreesOfFreedom: denominatorDF,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            resolvedETACThresholds: resolvedETACThresholds,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            rearrangements: plan,
            configuration: configuration
        )
    }

    static func rearrangementKind(input: Input) -> ClusterRearrangementKind {
        switch input.design {
        case .independent:
            return .groupLabels(sizes: input.levels.map { $0.units.count })
        case .repeatedMeasures:
            return .withinUnitRelabel(
                conditionCount: input.levels.count,
                unitCount: input.levels.first?.units.count ?? 0
            )
        }
    }

    static func resolveThreshold(
        _ threshold: ClusterFormingThreshold,
        numeratorDegreesOfFreedom d1: Double,
        denominatorDegreesOfFreedom d2: Double
    ) -> Double? {
        switch threshold {
        case .statistic(let value):
            guard value.isFinite, value > 0 else { return nil }
            return value
        case .probability(let alpha):
            return ClusterStatisticsDistributions.criticalF(
                alpha: alpha,
                numeratorDegreesOfFreedom: d1,
                denominatorDegreesOfFreedom: d2
            )
        }
    }

    // MARK: - Statistics

    /// Conventional one-way ANOVA F at every channel/time feature.
    static func independentFStatistics(
        groupSums: [[Double]],
        groupCounts: [Int],
        totalSums: [Double],
        totalSumSquares: [Double]
    ) -> [Double] {
        let groupCount = groupCounts.count
        let totalCount = groupCounts.reduce(0, +)
        let betweenDF = Double(groupCount - 1)
        let withinDF = Double(totalCount - groupCount)
        var result = [Double](repeating: 0, count: totalSums.count)
        guard groupCount >= 2, totalCount > groupCount else { return result }

        for feature in result.indices {
            var groupCorrection = 0.0
            for group in groupSums.indices {
                let count = Double(groupCounts[group])
                let sum = groupSums[group][feature]
                groupCorrection += sum * sum / count
            }
            let grandCorrection = totalSums[feature] * totalSums[feature] / Double(totalCount)
            let betweenSS = max(groupCorrection - grandCorrection, 0)
            let withinSS = max(totalSumSquares[feature] - groupCorrection, 0)
            let denominator = withinSS / withinDF
            if denominator > 1e-15, denominator.isFinite {
                let value = (betweenSS / betweenDF) / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    /// One-way repeated-measures F. The error term is the condition x subject
    /// interaction, obtained by removing both main effects from the total.
    ///
    /// Sphericity is assumed, as it is by every uncorrected repeated-measures F.
    /// The permutation step corrects the *family-wise* error across the lattice;
    /// it does not repair a violated sphericity assumption within a feature. In
    /// practice this matters little here because the reference distribution is
    /// the permutation distribution of the same statistic rather than the
    /// tabulated F, so the test remains valid under exchangeability even where
    /// the tabulated F would not be.
    static func repeatedMeasuresFStatistics(
        conditionSums: [[Double]],
        grandSums: [Double],
        totalSumSquares: [Double],
        unitSumOfSquaredSums: [Double],
        unitCount: Int,
        conditionCount: Int
    ) -> [Double] {
        let n = Double(unitCount)
        let k = Double(conditionCount)
        let conditionDF = k - 1
        let errorDF = (k - 1) * (n - 1)
        var result = [Double](repeating: 0, count: grandSums.count)
        guard unitCount > 1, conditionCount > 1, errorDF > 0 else { return result }
        let observationCount = n * k

        for feature in result.indices {
            let grand = grandSums[feature]
            let correction = grand * grand / observationCount

            var conditionCorrection = 0.0
            for condition in conditionSums.indices {
                let sum = conditionSums[condition][feature]
                conditionCorrection += sum * sum
            }
            conditionCorrection /= n

            let unitCorrection = unitSumOfSquaredSums[feature] / k

            let conditionSS = max(conditionCorrection - correction, 0)
            let totalSS = max(totalSumSquares[feature] - correction, 0)
            let unitSS = max(unitCorrection - correction, 0)
            let errorSS = max(totalSS - conditionSS - unitSS, 0)

            let denominator = errorSS / errorDF
            if denominator > 1e-15, denominator.isFinite {
                let value = (conditionSS / conditionDF) / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    private static func shuffle<R: RandomNumberGenerator>(_ values: inout [Int], using rng: inout R) {
        guard values.count > 1 else { return }
        for index in 0..<(values.count - 1) {
            let other = Int.random(in: index..<values.count, using: &rng)
            if index != other { values.swapAt(index, other) }
        }
    }
}
