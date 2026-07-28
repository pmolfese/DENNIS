//
//  Decoding.swift
//  DENNIS
//
//  ERP decoding / classification. Current data source is averaged ERP condition
//  data; the same row/model machinery is set up to accept single-trial or
//  pseudo-trial observations once segmented epochs are imported.
//

import Foundation

nonisolated enum DecodingClassifier: String, CaseIterable, Identifiable, Sendable {
    case shrinkageLDA = "Shrinkage LDA"
    case logisticL2 = "L2 Logistic"
    case linearSVM = "Linear SVM"
    case nearestCentroid = "Nearest centroid"
    var id: String { rawValue }
}

nonisolated enum DecodingRegressor: String, CaseIterable, Identifiable, Sendable {
    case ridgeElasticNet = "Ridge / Elastic Net"
    var id: String { rawValue }
}

nonisolated enum DecodingFeatureMode: String, CaseIterable, Identifiable, Sendable {
    case wholeWindow = "Whole window"
    case timeResolved = "Time-resolved"
    case slidingWindow = "Sliding window"
    case temporalGeneralization = "Temporal generalization"
    var id: String { rawValue }
}

nonisolated enum DecodingObservationKind: String, Sendable {
    case averagedCondition
    case singleTrial
    case pseudoTrial
}

nonisolated struct DecodingSubjectInfo: Sendable {
    let name: String
    let levels: [String]
}

nonisolated struct DecodingObservation: Sendable {
    let subjectIndex: Int
    let subjectName: String
    let label: String
    let features: [Double]
    var kind: DecodingObservationKind = .averagedCondition
}

nonisolated struct DecodingDataset: Sendable {
    let observations: [DecodingObservation]
    let labels: [String]
    let featureCount: Int
    var timeLabelMS: Double?
    var windowStartMS: Double?
    var windowEndMS: Double?

    func relabeled(_ labelsByObservation: [String]) -> DecodingDataset {
        let rows = zip(observations, labelsByObservation).map { row, label in
            DecodingObservation(
                subjectIndex: row.subjectIndex,
                subjectName: row.subjectName,
                label: label,
                features: row.features,
                kind: row.kind
            )
        }
        return DecodingDataset(
            observations: rows,
            labels: labels,
            featureCount: featureCount,
            timeLabelMS: timeLabelMS,
            windowStartMS: windowStartMS,
            windowEndMS: windowEndMS
        )
    }
}

nonisolated struct DecodingRegressionObservation: Sendable {
    let subjectIndex: Int
    let subjectName: String
    let target: Double
    let features: [Double]
    var kind: DecodingObservationKind = .averagedCondition
}

nonisolated struct DecodingRegressionDataset: Sendable {
    let observations: [DecodingRegressionObservation]
    let featureCount: Int
    var timeLabelMS: Double?
    var windowStartMS: Double?
    var windowEndMS: Double?

    func retargeted(_ targetsByObservation: [Double]) -> DecodingRegressionDataset {
        let rows = zip(observations, targetsByObservation).map { row, target in
            DecodingRegressionObservation(
                subjectIndex: row.subjectIndex,
                subjectName: row.subjectName,
                target: target,
                features: row.features,
                kind: row.kind
            )
        }
        return DecodingRegressionDataset(
            observations: rows,
            featureCount: featureCount,
            timeLabelMS: timeLabelMS,
            windowStartMS: windowStartMS,
            windowEndMS: windowEndMS
        )
    }
}

nonisolated struct DecodingPrediction: Identifiable, Sendable {
    let id: Int
    let subjectName: String
    let actual: String
    let predicted: String
    let fold: Int
    var isCorrect: Bool { actual == predicted }
}

nonisolated struct DecodingRegressionPrediction: Identifiable, Sendable {
    let id: Int
    let subjectName: String
    let actual: Double
    let predicted: Double
    let fold: Int
    var residual: Double { actual - predicted }
}

nonisolated struct DecodingResult: Sendable {
    let classifier: DecodingClassifier
    let labels: [String]
    let predictions: [DecodingPrediction]
    let confusion: [[Int]]
    let accuracy: Double
    let balancedAccuracy: Double
    let chance: Double
}

nonisolated struct DecodingRegressionResult: Sendable {
    let regressor: DecodingRegressor
    let predictions: [DecodingRegressionPrediction]
    let correlation: Double
    let rSquared: Double
    let rmse: Double
    let mae: Double
    let baselineRMSE: Double
}

nonisolated struct DecodingWindowResult: Identifiable, Sendable {
    let id = UUID()
    let centerMS: Double
    let startMS: Double
    let endMS: Double
    let result: DecodingResult
    var balancedAccuracy: Double { result.balancedAccuracy }
    var accuracy: Double { result.accuracy }
}

nonisolated struct DecodingRegressionWindowResult: Identifiable, Sendable {
    let id = UUID()
    let centerMS: Double
    let startMS: Double
    let endMS: Double
    let result: DecodingRegressionResult
    var correlation: Double { result.correlation }
    var rSquared: Double { result.rSquared }
    var rmse: Double { result.rmse }
}

nonisolated struct DecodingPermutationResult: Sendable {
    let observed: Double
    let nullDistribution: [Double]
    let pValue: Double
}

nonisolated struct DecodingRegressionPermutationResult: Sendable {
    let observed: Double
    let nullDistribution: [Double]
    let pValue: Double
}

nonisolated struct TemporalGeneralizationResult: Sendable {
    let trainTimesMS: [Double]
    let testTimesMS: [Double]
    let balancedAccuracy: [[Double]]
}

nonisolated struct RegressionTemporalGeneralizationResult: Sendable {
    let trainTimesMS: [Double]
    let testTimesMS: [Double]
    let correlations: [[Double]]
}

nonisolated struct DecodingProgress: Sendable {
    let completed: Int
    let total: Int
    let message: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

nonisolated struct DecodingEpoch: Identifiable, Sendable {
    let id: UUID
    let subjectIndex: Int
    let subjectName: String
    let label: String
    let samples: [[Float]]
    let samplingRate: Double
    let baselineSamples: Int
    let isAccepted: Bool
    let trialLevels: [String]

    init(
        id: UUID = UUID(),
        subjectIndex: Int,
        subjectName: String,
        label: String,
        samples: [[Float]],
        samplingRate: Double,
        baselineSamples: Int,
        isAccepted: Bool = true,
        trialLevels: [String] = []
    ) {
        self.id = id
        self.subjectIndex = subjectIndex
        self.subjectName = subjectName
        self.label = label
        self.samples = samples
        self.samplingRate = samplingRate
        self.baselineSamples = baselineSamples
        self.isAccepted = isAccepted
        self.trialLevels = trialLevels
    }
}

nonisolated enum Decoding {
    enum DecodingError: Error, LocalizedError {
        case empty
        case oneClass
        case insufficientSubjects
        case foldMissingClass(String)
        case dimensionMismatch
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .empty: "No decodable observations were available."
            case .oneClass: "Select at least two classes to decode."
            case .insufficientSubjects: "Leave-one-subject-out decoding needs at least two subjects."
            case .foldMissingClass(let label): "A training fold has no examples for class \(label)."
            case .dimensionMismatch: "Training and testing feature dimensions do not match."
            case .unsupported(let message): message
            }
        }
    }

    @MainActor
    static func makeConditionDataset(
        from input: EPTensor.Input,
        subjects: [Dataset],
        conditionNames: [String],
        selectedConditions: Set<String>,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        makeConditionDataset(
            from: input,
            subjects: subjects.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) },
            conditionNames: conditionNames,
            selectedConditions: selectedConditions,
            timeIndices: timeIndices,
            timesMS: timesMS
        )
    }

    static func makeConditionDataset(
        from input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        conditionNames: [String],
        selectedConditions: Set<String>,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        let selected = conditionNames.filter { selectedConditions.contains($0) }
        guard selected.count >= 2, !timeIndices.isEmpty else { return nil }
        var observations: [DecodingObservation] = []

        for (subjectIndex, cells) in input.subjects.enumerated() {
            let subjectName = subjectIndex < subjects.count ? subjects[subjectIndex].name : "Subject \(subjectIndex + 1)"
            for (conditionIndex, conditionName) in conditionNames.enumerated() where selectedConditions.contains(conditionName) {
                guard conditionIndex < cells.count else { continue }
                let samples = cells[conditionIndex]
                let features = flatten(samples: samples, timeIndices: timeIndices)
                guard !features.isEmpty else { continue }
                observations.append(DecodingObservation(
                    subjectIndex: subjectIndex,
                    subjectName: subjectName,
                    label: conditionName,
                    features: features
                ))
            }
        }

        guard let featureCount = observations.first?.features.count,
              observations.allSatisfy({ $0.features.count == featureCount }) else { return nil }

        let windowTimes = timeIndices.compactMap { index -> Double? in
            guard let timesMS, index < timesMS.count else { return nil }
            return timesMS[index]
        }
        return DecodingDataset(
            observations: observations,
            labels: selected,
            featureCount: featureCount,
            timeLabelMS: windowTimes.isEmpty ? nil : windowTimes.reduce(0, +) / Double(windowTimes.count),
            windowStartMS: windowTimes.min(),
            windowEndMS: windowTimes.max()
        )
    }

    @MainActor
    static func makeConditionFactorDataset(
        from input: EPTensor.Input,
        subjects: [Dataset],
        conditionNames: [String],
        conditionMetadata: ConditionModeMetadata,
        factorIndex: Int,
        selectedConditions: Set<String>,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        makeConditionFactorDataset(
            from: input,
            subjects: subjects.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) },
            conditionNames: conditionNames,
            conditionMetadata: conditionMetadata,
            factorIndex: factorIndex,
            selectedConditions: selectedConditions,
            timeIndices: timeIndices,
            timesMS: timesMS
        )
    }

    static func makeConditionFactorDataset(
        from input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        conditionNames: [String],
        conditionMetadata: ConditionModeMetadata,
        factorIndex: Int,
        selectedConditions: Set<String>,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        guard conditionMetadata.factorNames.indices.contains(factorIndex),
              !timeIndices.isEmpty else { return nil }
        let labelsByCondition = conditionNames.enumerated().map { conditionIndex, condition -> String in
            guard selectedConditions.contains(condition),
                  conditionIndex < conditionMetadata.levelsByCondition.count,
                  factorIndex < conditionMetadata.levelsByCondition[conditionIndex].count else { return "" }
            let label = conditionMetadata.levelsByCondition[conditionIndex][factorIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "Unassigned" : label
        }
        let labels = orderedUnique(labelsByCondition.filter { !$0.isEmpty })
        guard labels.count >= 2 else { return nil }
        var observations: [DecodingObservation] = []

        for (subjectIndex, cells) in input.subjects.enumerated() {
            let subjectName = subjectIndex < subjects.count ? subjects[subjectIndex].name : "Subject \(subjectIndex + 1)"
            for (conditionIndex, label) in labelsByCondition.enumerated() where !label.isEmpty {
                guard conditionIndex < cells.count else { continue }
                let features = flatten(samples: cells[conditionIndex], timeIndices: timeIndices)
                guard !features.isEmpty else { continue }
                observations.append(DecodingObservation(
                    subjectIndex: subjectIndex,
                    subjectName: subjectName,
                    label: label,
                    features: features
                ))
            }
        }

        return makeDataset(observations: observations, labels: labels, timeIndices: timeIndices, timesMS: timesMS)
    }

    @MainActor
    static func makeBetweenSubjectDataset(
        from input: EPTensor.Input,
        subjects: [Dataset],
        conditionNames: [String],
        selectedConditions: Set<String>,
        factorIndex: Int,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        makeBetweenSubjectDataset(
            from: input,
            subjects: subjects.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) },
            conditionNames: conditionNames,
            selectedConditions: selectedConditions,
            factorIndex: factorIndex,
            timeIndices: timeIndices,
            timesMS: timesMS
        )
    }

    static func makeBetweenSubjectDataset(
        from input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        conditionNames: [String],
        selectedConditions: Set<String>,
        factorIndex: Int,
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        guard !timeIndices.isEmpty else { return nil }
        let selectedConditionIndices = conditionNames.indices.filter { selectedConditions.contains(conditionNames[$0]) }
        guard !selectedConditionIndices.isEmpty else { return nil }
        let labels = orderedUnique(subjects.map { subject -> String in
            guard factorIndex < subject.levels.count else { return "Unassigned" }
            let label = subject.levels[factorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "Unassigned" : label
        })
        guard labels.count >= 2 else { return nil }
        var observations: [DecodingObservation] = []

        for (subjectIndex, cells) in input.subjects.enumerated() {
            guard subjectIndex < subjects.count else { continue }
            var features: [Double] = []
            for conditionIndex in selectedConditionIndices where conditionIndex < cells.count {
                features += flatten(samples: cells[conditionIndex], timeIndices: timeIndices)
            }
            guard !features.isEmpty else { continue }
            let subject = subjects[subjectIndex]
            let rawLabel = factorIndex < subject.levels.count ? subject.levels[factorIndex] : ""
            let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedLabel.isEmpty ? "Unassigned" : trimmedLabel
            observations.append(DecodingObservation(
                subjectIndex: subjectIndex,
                subjectName: subject.name,
                label: label,
                features: features,
                kind: .averagedCondition
            ))
        }

        return makeDataset(observations: observations, labels: labels, timeIndices: timeIndices, timesMS: timesMS)
    }

    static func makeSubjectLabelDataset(
        from input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        conditionNames: [String],
        selectedConditions: Set<String>,
        labelsBySubjectName: [String: String],
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingDataset? {
        guard !timeIndices.isEmpty else { return nil }
        let selectedConditionIndices = conditionNames.indices.filter { selectedConditions.contains(conditionNames[$0]) }
        guard !selectedConditionIndices.isEmpty else { return nil }
        let labels = orderedUnique(subjects.compactMap { labelsBySubjectName[$0.name] })
        guard labels.count >= 2 else { return nil }
        var observations: [DecodingObservation] = []

        for (subjectIndex, cells) in input.subjects.enumerated() {
            guard subjectIndex < subjects.count,
                  let label = labelsBySubjectName[subjects[subjectIndex].name] else { continue }
            var features: [Double] = []
            for conditionIndex in selectedConditionIndices where conditionIndex < cells.count {
                features += flatten(samples: cells[conditionIndex], timeIndices: timeIndices)
            }
            guard !features.isEmpty else { continue }
            observations.append(DecodingObservation(
                subjectIndex: subjectIndex,
                subjectName: subjects[subjectIndex].name,
                label: label,
                features: features,
                kind: .averagedCondition
            ))
        }

        return makeDataset(observations: observations, labels: labels, timeIndices: timeIndices, timesMS: timesMS)
    }

    static func makeSubjectValueDataset(
        from input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        conditionNames: [String],
        selectedConditions: Set<String>,
        valuesBySubjectName: [String: Double],
        timeIndices: [Int],
        timesMS: [Double]? = nil
    ) -> DecodingRegressionDataset? {
        guard !timeIndices.isEmpty else { return nil }
        let selectedConditionIndices = conditionNames.indices.filter { selectedConditions.contains(conditionNames[$0]) }
        guard !selectedConditionIndices.isEmpty else { return nil }
        var observations: [DecodingRegressionObservation] = []

        for (subjectIndex, cells) in input.subjects.enumerated() {
            guard subjectIndex < subjects.count,
                  let target = valuesBySubjectName[subjects[subjectIndex].name] else { continue }
            var features: [Double] = []
            for conditionIndex in selectedConditionIndices where conditionIndex < cells.count {
                features += flatten(samples: cells[conditionIndex], timeIndices: timeIndices)
            }
            guard !features.isEmpty else { continue }
            observations.append(DecodingRegressionObservation(
                subjectIndex: subjectIndex,
                subjectName: subjects[subjectIndex].name,
                target: target,
                features: features,
                kind: .averagedCondition
            ))
        }

        return makeRegressionDataset(observations: observations, timeIndices: timeIndices, timesMS: timesMS)
    }

    static func makeEpochDataset(
        epochs: [DecodingEpoch],
        labels: [String],
        timeIndices: [Int],
        kind: DecodingObservationKind = .singleTrial
    ) -> DecodingDataset? {
        let selected = Set(labels)
        let observations = epochs.filter { $0.isAccepted && selected.contains($0.label) }.map { epoch in
            DecodingObservation(
                subjectIndex: epoch.subjectIndex,
                subjectName: epoch.subjectName,
                label: epoch.label,
                features: flatten(samples: epoch.samples, timeIndices: timeIndices),
                kind: kind
            )
        }.filter { !$0.features.isEmpty }
        guard let featureCount = observations.first?.features.count,
              observations.allSatisfy({ $0.features.count == featureCount }) else { return nil }
        return DecodingDataset(observations: observations, labels: labels, featureCount: featureCount)
    }

    static func leaveOneSubjectOut(
        _ dataset: DecodingDataset,
        classifier: DecodingClassifier = .shrinkageLDA,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> DecodingResult {
        try validate(dataset)
        let subjects = Array(Set(dataset.observations.map(\.subjectIndex))).sorted()
        guard subjects.count >= 2 else { throw DecodingError.insufficientSubjects }

        progress?(DecodingProgress(
            completed: 0,
            total: subjects.count,
            message: "Starting leave-one-subject-out decoding with \(subjects.count) folds, "
                + "\(dataset.observations.count) observations, \(dataset.labels.count) classes, "
                + "\(dataset.featureCount.formatted()) features, classifier \(classifier.rawValue), "
                + "and \(concurrent ? "multithreaded" : "serial") fold execution."
        ))

        let foldRunner: (Int, Int) throws -> [DecodingPrediction] = { fold, heldOutSubject in
            let train = dataset.observations.filter { $0.subjectIndex != heldOutSubject }
            let test = dataset.observations.filter { $0.subjectIndex == heldOutSubject }
            let model = try trainModel(classifier, observations: train, labels: dataset.labels)
            return test.enumerated().map { offset, observation in
                DecodingPrediction(
                    id: fold * 100_000 + offset,
                    subjectName: observation.subjectName,
                    actual: observation.label,
                    predicted: model.predict(observation.features),
                    fold: fold + 1
                )
            }
        }

        let predictionsByFold: [[DecodingPrediction]]
        if concurrent {
            predictionsByFold = try concurrentMap(Array(subjects.enumerated()), progress: progress) { foldAndSubject in
                let (fold, subject) = foldAndSubject
                let subjectName = dataset.observations.first(where: { $0.subjectIndex == subject })?.subjectName ?? "subject \(subject + 1)"
                let out = try foldRunner(fold, subject)
                return (fold, out, "Completed fold \(fold + 1) of \(subjects.count): held out \(subjectName), predicted \(out.count) observations.")
            }
        } else {
            var out: [[DecodingPrediction]] = []
            for (fold, subject) in subjects.enumerated() {
                let subjectName = dataset.observations.first(where: { $0.subjectIndex == subject })?.subjectName ?? "subject \(subject + 1)"
                progress?(DecodingProgress(
                    completed: fold,
                    total: subjects.count,
                    message: "Fold \(fold + 1) of \(subjects.count): holding out \(subjectName); preprocessing is fit on training observations only."
                ))
                out.append(try foldRunner(fold, subject))
                progress?(DecodingProgress(
                    completed: fold + 1,
                    total: subjects.count,
                    message: "Completed fold \(fold + 1) of \(subjects.count): held-out predictions for \(subjectName) are in."
                ))
            }
            predictionsByFold = out
        }

        progress?(DecodingProgress(
            completed: subjects.count,
            total: subjects.count,
            message: "Aggregating held-out predictions into accuracy, balanced accuracy, chance level, and confusion matrix."
        ))
        return summarize(
            classifier: classifier,
            labels: dataset.labels,
            predictions: predictionsByFold.flatMap { $0 }.sorted { $0.id < $1.id }
        )
    }

    static func leaveOneSubjectOutRegression(
        _ dataset: DecodingRegressionDataset,
        regressor: DecodingRegressor = .ridgeElasticNet,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> DecodingRegressionResult {
        try validate(dataset)
        let subjects = Array(Set(dataset.observations.map(\.subjectIndex))).sorted()
        guard subjects.count >= 3 else { throw DecodingError.insufficientSubjects }

        progress?(DecodingProgress(
            completed: 0,
            total: subjects.count,
            message: "Starting leave-one-subject-out prediction with \(subjects.count) folds, "
                + "\(dataset.observations.count) subjects, \(dataset.featureCount.formatted()) features, "
                + "model \(regressor.rawValue), and \(concurrent ? "multithreaded" : "serial") fold execution."
        ))

        let foldRunner: (Int, Int) throws -> [DecodingRegressionPrediction] = { fold, heldOutSubject in
            let train = dataset.observations.filter { $0.subjectIndex != heldOutSubject }
            let test = dataset.observations.filter { $0.subjectIndex == heldOutSubject }
            let model = try trainRegressionModel(regressor, observations: train)
            return test.enumerated().map { offset, observation in
                DecodingRegressionPrediction(
                    id: fold * 100_000 + offset,
                    subjectName: observation.subjectName,
                    actual: observation.target,
                    predicted: model.predict(observation.features),
                    fold: fold + 1
                )
            }
        }

        let predictionsByFold: [[DecodingRegressionPrediction]]
        if concurrent {
            predictionsByFold = try concurrentMap(Array(subjects.enumerated()), progress: progress) { foldAndSubject in
                let (fold, subject) = foldAndSubject
                let subjectName = dataset.observations.first(where: { $0.subjectIndex == subject })?.subjectName ?? "subject \(subject + 1)"
                let out = try foldRunner(fold, subject)
                return (fold, out, "Completed fold \(fold + 1) of \(subjects.count): held out \(subjectName), predicted \(out.count) behavioral value.")
            }
        } else {
            var out: [[DecodingRegressionPrediction]] = []
            for (fold, subject) in subjects.enumerated() {
                let subjectName = dataset.observations.first(where: { $0.subjectIndex == subject })?.subjectName ?? "subject \(subject + 1)"
                progress?(DecodingProgress(
                    completed: fold,
                    total: subjects.count,
                    message: "Fold \(fold + 1) of \(subjects.count): holding out \(subjectName); preprocessing is fit on training subjects only."
                ))
                out.append(try foldRunner(fold, subject))
                progress?(DecodingProgress(
                    completed: fold + 1,
                    total: subjects.count,
                    message: "Completed fold \(fold + 1) of \(subjects.count): held-out behavioral prediction for \(subjectName) is in."
                ))
            }
            predictionsByFold = out
        }

        progress?(DecodingProgress(
            completed: subjects.count,
            total: subjects.count,
            message: "Aggregating held-out behavioral predictions into correlation, R-squared, RMSE, and MAE."
        ))
        return summarize(
            regressor: regressor,
            predictions: predictionsByFold.flatMap { $0 }.sorted { $0.id < $1.id }
        )
    }

    static func timeResolved(
        datasets: [DecodingDataset],
        classifier: DecodingClassifier,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> [DecodingWindowResult] {
        try decodeWindows(datasets: datasets, classifier: classifier, concurrent: concurrent, progress: progress)
    }

    static func timeResolvedRegression(
        datasets: [DecodingRegressionDataset],
        regressor: DecodingRegressor,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> [DecodingRegressionWindowResult] {
        try decodeRegressionWindows(datasets: datasets, regressor: regressor, concurrent: concurrent, progress: progress)
    }

    static func permutationTest(
        dataset: DecodingDataset,
        classifier: DecodingClassifier,
        observed: DecodingResult? = nil,
        permutations: Int,
        concurrent: Bool = true,
        seed: UInt64 = 0xDEC0DE,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> DecodingPermutationResult {
        let observedValue = try (observed ?? leaveOneSubjectOut(dataset, classifier: classifier, concurrent: concurrent)).balancedAccuracy
        guard permutations > 0 else {
            return DecodingPermutationResult(observed: observedValue, nullDistribution: [], pValue: .nan)
        }
        let jobs = Array(0..<permutations)
        let null: [Double]
        if concurrent {
            null = try concurrentMap(jobs, progress: progress) { index in
                var rng = SplitMix64(seed: seed &+ UInt64(index))
                let labels = shuffledLabels(dataset.observations.map(\.label), rng: &rng)
                let permuted = dataset.relabeled(labels)
                let metric = try leaveOneSubjectOut(permuted, classifier: classifier, concurrent: false).balancedAccuracy
                return (index, metric, "Permutation \(index + 1) of \(permutations): null balanced accuracy \(formatPercent(metric)).")
            }
        } else {
            var out: [Double] = []
            for index in jobs {
                var rng = SplitMix64(seed: seed &+ UInt64(index))
                let labels = shuffledLabels(dataset.observations.map(\.label), rng: &rng)
                let permuted = dataset.relabeled(labels)
                out.append(try leaveOneSubjectOut(permuted, classifier: classifier, concurrent: false).balancedAccuracy)
                progress?(DecodingProgress(completed: index + 1, total: permutations, message: "Completed permutation \(index + 1) of \(permutations)."))
            }
            null = out
        }
        let ge = null.filter { $0 >= observedValue }.count
        let p = Double(ge + 1) / Double(permutations + 1)
        return DecodingPermutationResult(observed: observedValue, nullDistribution: null, pValue: p)
    }

    static func regressionPermutationTest(
        dataset: DecodingRegressionDataset,
        regressor: DecodingRegressor,
        observed: DecodingRegressionResult? = nil,
        permutations: Int,
        concurrent: Bool = true,
        seed: UInt64 = 0xDEC0DE,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> DecodingRegressionPermutationResult {
        let observedValue = try (observed ?? leaveOneSubjectOutRegression(dataset, regressor: regressor, concurrent: concurrent)).correlation
        guard permutations > 0 else {
            return DecodingRegressionPermutationResult(observed: observedValue, nullDistribution: [], pValue: .nan)
        }
        let jobs = Array(0..<permutations)
        let null: [Double]
        if concurrent {
            null = try concurrentMap(jobs, progress: progress) { index in
                var rng = SplitMix64(seed: seed &+ UInt64(index))
                let targets = shuffledTargets(dataset.observations.map(\.target), rng: &rng)
                let permuted = dataset.retargeted(targets)
                let metric = try leaveOneSubjectOutRegression(permuted, regressor: regressor, concurrent: false).correlation
                return (index, metric, "Permutation \(index + 1) of \(permutations): null prediction r \(format(metric)).")
            }
        } else {
            var out: [Double] = []
            for index in jobs {
                var rng = SplitMix64(seed: seed &+ UInt64(index))
                let targets = shuffledTargets(dataset.observations.map(\.target), rng: &rng)
                let permuted = dataset.retargeted(targets)
                out.append(try leaveOneSubjectOutRegression(permuted, regressor: regressor, concurrent: false).correlation)
                progress?(DecodingProgress(completed: index + 1, total: permutations, message: "Completed permutation \(index + 1) of \(permutations)."))
            }
            null = out
        }
        let observedMagnitude = abs(observedValue)
        let ge = null.filter { abs($0) >= observedMagnitude }.count
        let p = Double(ge + 1) / Double(permutations + 1)
        return DecodingRegressionPermutationResult(observed: observedValue, nullDistribution: null, pValue: p)
    }

    static func temporalGeneralization(
        datasets: [DecodingDataset],
        classifier: DecodingClassifier,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> TemporalGeneralizationResult {
        guard !datasets.isEmpty else { throw DecodingError.empty }
        let jobs = (0..<datasets.count).flatMap { train in (0..<datasets.count).map { (train, $0) } }
        let cells: [((Int, Int), Double)]
        if concurrent {
            cells = try concurrentMap(jobs, progress: progress) { pair in
                let metric = try crossTemporalLOSO(
                    trainDataset: datasets[pair.0],
                    testDataset: datasets[pair.1],
                    classifier: classifier
                )
                return (pair.0 * datasets.count + pair.1, (pair, metric), "Temporal generalization cell train \(pair.0 + 1), test \(pair.1 + 1): \(formatPercent(metric)).")
            }
        } else {
            var out: [((Int, Int), Double)] = []
            for (index, pair) in jobs.enumerated() {
                let metric = try crossTemporalLOSO(trainDataset: datasets[pair.0], testDataset: datasets[pair.1], classifier: classifier)
                out.append((pair, metric))
                progress?(DecodingProgress(completed: index + 1, total: jobs.count, message: "Completed temporal generalization cell \(index + 1) of \(jobs.count)."))
            }
            cells = out
        }

        var matrix = Array(repeating: Array(repeating: 0.0, count: datasets.count), count: datasets.count)
        for (pair, metric) in cells { matrix[pair.0][pair.1] = metric }
        return TemporalGeneralizationResult(
            trainTimesMS: datasets.map { $0.timeLabelMS ?? 0 },
            testTimesMS: datasets.map { $0.timeLabelMS ?? 0 },
            balancedAccuracy: matrix
        )
    }

    static func regressionTemporalGeneralization(
        datasets: [DecodingRegressionDataset],
        regressor: DecodingRegressor,
        concurrent: Bool = true,
        progress: (@Sendable (DecodingProgress) -> Void)? = nil
    ) throws -> RegressionTemporalGeneralizationResult {
        guard !datasets.isEmpty else { throw DecodingError.empty }
        let jobs = (0..<datasets.count).flatMap { train in (0..<datasets.count).map { (train, $0) } }
        let cells: [((Int, Int), Double)]
        if concurrent {
            cells = try concurrentMap(jobs, progress: progress) { pair in
                let metric = try crossTemporalRegressionLOSO(
                    trainDataset: datasets[pair.0],
                    testDataset: datasets[pair.1],
                    regressor: regressor
                )
                return (pair.0 * datasets.count + pair.1, (pair, metric), "Temporal prediction cell train \(pair.0 + 1), test \(pair.1 + 1): r \(format(metric)).")
            }
        } else {
            var out: [((Int, Int), Double)] = []
            for (index, pair) in jobs.enumerated() {
                let metric = try crossTemporalRegressionLOSO(trainDataset: datasets[pair.0], testDataset: datasets[pair.1], regressor: regressor)
                out.append((pair, metric))
                progress?(DecodingProgress(completed: index + 1, total: jobs.count, message: "Completed temporal prediction cell \(index + 1) of \(jobs.count)."))
            }
            cells = out
        }

        var matrix = Array(repeating: Array(repeating: 0.0, count: datasets.count), count: datasets.count)
        for (pair, metric) in cells { matrix[pair.0][pair.1] = metric }
        return RegressionTemporalGeneralizationResult(
            trainTimesMS: datasets.map { $0.timeLabelMS ?? 0 },
            testTimesMS: datasets.map { $0.timeLabelMS ?? 0 },
            correlations: matrix
        )
    }

    static func summarize(
        classifier: DecodingClassifier,
        labels: [String],
        predictions: [DecodingPrediction]
    ) -> DecodingResult {
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
        let n = labels.count
        var confusion = Array(repeating: Array(repeating: 0, count: n), count: n)
        var correct = 0
        for prediction in predictions {
            guard let actual = labelIndex[prediction.actual],
                  let predicted = labelIndex[prediction.predicted] else { continue }
            confusion[actual][predicted] += 1
            if actual == predicted { correct += 1 }
        }

        let total = max(1, predictions.count)
        let recalls = (0..<n).map { row -> Double in
            let rowTotal = confusion[row].reduce(0, +)
            return rowTotal > 0 ? Double(confusion[row][row]) / Double(rowTotal) : 0
        }
        let balanced = recalls.isEmpty ? 0 : recalls.reduce(0, +) / Double(recalls.count)
        return DecodingResult(
            classifier: classifier,
            labels: labels,
            predictions: predictions,
            confusion: confusion,
            accuracy: Double(correct) / Double(total),
            balancedAccuracy: balanced,
            chance: labels.isEmpty ? 0 : 1.0 / Double(labels.count)
        )
    }

    static func summarize(
        regressor: DecodingRegressor,
        predictions: [DecodingRegressionPrediction]
    ) -> DecodingRegressionResult {
        let actual = predictions.map(\.actual)
        let predicted = predictions.map(\.predicted)
        let residuals = zip(actual, predicted).map { $0 - $1 }
        let mse = residuals.map { $0 * $0 }.reduce(0, +) / Double(max(1, residuals.count))
        let mae = residuals.map { abs($0) }.reduce(0, +) / Double(max(1, residuals.count))
        let meanActual = actual.isEmpty ? 0 : actual.reduce(0, +) / Double(actual.count)
        let baselineMSE = actual.map { value in
            let d = value - meanActual
            return d * d
        }.reduce(0, +) / Double(max(1, actual.count))
        let totalSS: Double = actual.map { value in
            let d = value - meanActual
            return d * d
        }.reduce(0.0, +)
        let residualSS: Double = residuals.map { $0 * $0 }.reduce(0.0, +)
        let r2 = totalSS > 1e-12 ? 1 - residualSS / totalSS : .nan
        return DecodingRegressionResult(
            regressor: regressor,
            predictions: predictions,
            correlation: pearson(actual, predicted),
            rSquared: r2,
            rmse: mse.squareRoot(),
            mae: mae,
            baselineRMSE: baselineMSE.squareRoot()
        )
    }

    static func predictionsCSV(_ result: DecodingResult) -> String {
        var lines = ["Fold,Subject,Actual,Predicted,Correct"]
        for p in result.predictions {
            lines.append([String(p.fold), escape(p.subjectName), escape(p.actual), escape(p.predicted), p.isCorrect ? "1" : "0"].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func regressionPredictionsCSV(_ result: DecodingRegressionResult) -> String {
        var lines = ["Fold,Subject,Actual,Predicted,Residual"]
        for p in result.predictions {
            lines.append([
                String(p.fold),
                escape(p.subjectName),
                format(p.actual),
                format(p.predicted),
                format(p.residual)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func confusionCSV(_ result: DecodingResult) -> String {
        var lines = [(["Actual\\Predicted"] + result.labels).map(escape).joined(separator: ",")]
        for (row, label) in result.labels.enumerated() {
            lines.append(([escape(label)] + result.confusion[row].map(String.init)).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func curveCSV(_ windows: [DecodingWindowResult]) -> String {
        var lines = ["Center_ms,Start_ms,End_ms,Accuracy,BalancedAccuracy,Chance"]
        for w in windows {
            lines.append([
                format(w.centerMS), format(w.startMS), format(w.endMS),
                format(w.accuracy), format(w.balancedAccuracy), format(w.result.chance)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func regressionCurveCSV(_ windows: [DecodingRegressionWindowResult]) -> String {
        var lines = ["Center_ms,Start_ms,End_ms,Correlation,RSquared,RMSE,MAE,BaselineRMSE"]
        for w in windows {
            lines.append([
                format(w.centerMS), format(w.startMS), format(w.endMS),
                format(w.correlation), format(w.rSquared), format(w.result.rmse),
                format(w.result.mae), format(w.result.baselineRMSE)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func temporalGeneralizationCSV(_ result: TemporalGeneralizationResult) -> String {
        var lines = [(["Train_ms\\Test_ms"] + result.testTimesMS.map(format)).joined(separator: ",")]
        for (row, train) in result.trainTimesMS.enumerated() {
            lines.append(([format(train)] + result.balancedAccuracy[row].map(format)).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func regressionTemporalGeneralizationCSV(_ result: RegressionTemporalGeneralizationResult) -> String {
        var lines = [(["Train_ms\\Test_ms"] + result.testTimesMS.map(format)).joined(separator: ",")]
        for (row, train) in result.trainTimesMS.enumerated() {
            lines.append(([format(train)] + result.correlations[row].map(format)).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func decodeWindows(
        datasets: [DecodingDataset],
        classifier: DecodingClassifier,
        concurrent: Bool,
        progress: (@Sendable (DecodingProgress) -> Void)?
    ) throws -> [DecodingWindowResult] {
        guard !datasets.isEmpty else { throw DecodingError.empty }
        let jobs = Array(datasets.enumerated())
        if concurrent {
            return try concurrentMap(jobs, progress: progress) { index, dataset in
                let result = try leaveOneSubjectOut(dataset, classifier: classifier, concurrent: false)
                let center = dataset.timeLabelMS ?? 0
                let window = DecodingWindowResult(
                    centerMS: center,
                    startMS: dataset.windowStartMS ?? center,
                    endMS: dataset.windowEndMS ?? center,
                    result: result
                )
                return (index, window, "Decoded window \(index + 1) of \(datasets.count) centered at \(format(center)) ms: balanced accuracy \(formatPercent(result.balancedAccuracy)).")
            }
        } else {
            var out: [DecodingWindowResult] = []
            for (index, dataset) in jobs {
                let result = try leaveOneSubjectOut(dataset, classifier: classifier, concurrent: false)
                let center = dataset.timeLabelMS ?? 0
                out.append(DecodingWindowResult(centerMS: center, startMS: dataset.windowStartMS ?? center, endMS: dataset.windowEndMS ?? center, result: result))
                progress?(DecodingProgress(completed: index + 1, total: datasets.count, message: "Decoded window \(index + 1) of \(datasets.count)."))
            }
            return out
        }
    }

    private static func decodeRegressionWindows(
        datasets: [DecodingRegressionDataset],
        regressor: DecodingRegressor,
        concurrent: Bool,
        progress: (@Sendable (DecodingProgress) -> Void)?
    ) throws -> [DecodingRegressionWindowResult] {
        guard !datasets.isEmpty else { throw DecodingError.empty }
        let jobs = Array(datasets.enumerated())
        if concurrent {
            return try concurrentMap(jobs, progress: progress) { index, dataset in
                let result = try leaveOneSubjectOutRegression(dataset, regressor: regressor, concurrent: false)
                let center = dataset.timeLabelMS ?? 0
                let window = DecodingRegressionWindowResult(
                    centerMS: center,
                    startMS: dataset.windowStartMS ?? center,
                    endMS: dataset.windowEndMS ?? center,
                    result: result
                )
                return (index, window, "Predicted window \(index + 1) of \(datasets.count) centered at \(format(center)) ms: r \(format(result.correlation)).")
            }
        } else {
            var out: [DecodingRegressionWindowResult] = []
            for (index, dataset) in jobs {
                let result = try leaveOneSubjectOutRegression(dataset, regressor: regressor, concurrent: false)
                let center = dataset.timeLabelMS ?? 0
                out.append(DecodingRegressionWindowResult(centerMS: center, startMS: dataset.windowStartMS ?? center, endMS: dataset.windowEndMS ?? center, result: result))
                progress?(DecodingProgress(completed: index + 1, total: datasets.count, message: "Predicted window \(index + 1) of \(datasets.count)."))
            }
            return out
        }
    }

    private static func crossTemporalLOSO(
        trainDataset: DecodingDataset,
        testDataset: DecodingDataset,
        classifier: DecodingClassifier
    ) throws -> Double {
        guard trainDataset.featureCount == testDataset.featureCount else { throw DecodingError.dimensionMismatch }
        try validate(trainDataset)
        let subjects = Array(Set(trainDataset.observations.map(\.subjectIndex))).sorted()
        let predictions = try subjects.enumerated().flatMap { fold, heldOut -> [DecodingPrediction] in
            let train = trainDataset.observations.filter { $0.subjectIndex != heldOut }
            let test = testDataset.observations.filter { $0.subjectIndex == heldOut }
            let model = try trainModel(classifier, observations: train, labels: trainDataset.labels)
            return test.enumerated().map { offset, observation in
                DecodingPrediction(
                    id: fold * 100_000 + offset,
                    subjectName: observation.subjectName,
                    actual: observation.label,
                    predicted: model.predict(observation.features),
                    fold: fold + 1
                )
            }
        }
        return summarize(classifier: classifier, labels: trainDataset.labels, predictions: predictions).balancedAccuracy
    }

    private static func crossTemporalRegressionLOSO(
        trainDataset: DecodingRegressionDataset,
        testDataset: DecodingRegressionDataset,
        regressor: DecodingRegressor
    ) throws -> Double {
        guard trainDataset.featureCount == testDataset.featureCount else { throw DecodingError.dimensionMismatch }
        try validate(trainDataset)
        let subjects = Array(Set(trainDataset.observations.map(\.subjectIndex))).sorted()
        let predictions = try subjects.enumerated().flatMap { fold, heldOut -> [DecodingRegressionPrediction] in
            let train = trainDataset.observations.filter { $0.subjectIndex != heldOut }
            let test = testDataset.observations.filter { $0.subjectIndex == heldOut }
            let model = try trainRegressionModel(regressor, observations: train)
            return test.enumerated().map { offset, observation in
                DecodingRegressionPrediction(
                    id: fold * 100_000 + offset,
                    subjectName: observation.subjectName,
                    actual: observation.target,
                    predicted: model.predict(observation.features),
                    fold: fold + 1
                )
            }
        }
        return summarize(regressor: regressor, predictions: predictions).correlation
    }

    private static func validate(_ dataset: DecodingDataset) throws {
        guard !dataset.observations.isEmpty else { throw DecodingError.empty }
        guard dataset.labels.count >= 2 else { throw DecodingError.oneClass }
        guard dataset.observations.allSatisfy({ $0.features.count == dataset.featureCount }) else {
            throw DecodingError.dimensionMismatch
        }
    }

    private static func validate(_ dataset: DecodingRegressionDataset) throws {
        guard !dataset.observations.isEmpty else { throw DecodingError.empty }
        guard Set(dataset.observations.map(\.target)).count >= 2 else {
            throw DecodingError.unsupported("Continuous prediction needs variation in the behavioral target.")
        }
        guard dataset.observations.allSatisfy({ $0.features.count == dataset.featureCount }) else {
            throw DecodingError.dimensionMismatch
        }
    }

    private static func trainModel(_ classifier: DecodingClassifier, observations: [DecodingObservation], labels: [String]) throws -> DecodingModel {
        switch classifier {
        case .nearestCentroid:
            return try CentroidModel.train(observations, labels: labels)
        case .logisticL2:
            return try LogisticRegressionModel.train(observations, labels: labels)
        case .linearSVM:
            return try LinearSVMModel.train(observations, labels: labels)
        case .shrinkageLDA:
            return try ShrinkageLDAModel.train(observations, labels: labels)
        }
    }

    private static func trainRegressionModel(_ regressor: DecodingRegressor, observations: [DecodingRegressionObservation]) throws -> DecodingRegressionModel {
        switch regressor {
        case .ridgeElasticNet:
            return try RidgeElasticNetModel.train(observations)
        }
    }

    private static func flatten(samples: [[Float]], timeIndices: [Int]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        var features: [Double] = []
        features.reserveCapacity(samples.count * timeIndices.count)
        for time in timeIndices {
            for channel in samples where time < channel.count {
                features.append(Double(channel[time]))
            }
        }
        return features
    }

    private static func makeDataset(
        observations: [DecodingObservation],
        labels: [String],
        timeIndices: [Int],
        timesMS: [Double]?
    ) -> DecodingDataset? {
        guard let featureCount = observations.first?.features.count,
              observations.allSatisfy({ $0.features.count == featureCount }) else { return nil }
        let windowTimes = timeIndices.compactMap { index -> Double? in
            guard let timesMS, index < timesMS.count else { return nil }
            return timesMS[index]
        }
        return DecodingDataset(
            observations: observations,
            labels: labels,
            featureCount: featureCount,
            timeLabelMS: windowTimes.isEmpty ? nil : windowTimes.reduce(0, +) / Double(windowTimes.count),
            windowStartMS: windowTimes.min(),
            windowEndMS: windowTimes.max()
        )
    }

    private static func makeRegressionDataset(
        observations: [DecodingRegressionObservation],
        timeIndices: [Int],
        timesMS: [Double]?
    ) -> DecodingRegressionDataset? {
        guard let featureCount = observations.first?.features.count,
              observations.allSatisfy({ $0.features.count == featureCount }) else { return nil }
        let windowTimes = timeIndices.compactMap { index -> Double? in
            guard let timesMS, index < timesMS.count else { return nil }
            return timesMS[index]
        }
        return DecodingRegressionDataset(
            observations: observations,
            featureCount: featureCount,
            timeLabelMS: windowTimes.isEmpty ? nil : windowTimes.reduce(0, +) / Double(windowTimes.count),
            windowStartMS: windowTimes.min(),
            windowEndMS: windowTimes.max()
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }

    private static func shuffledLabels(_ labels: [String], rng: inout SplitMix64) -> [String] {
        var out = labels
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
    }

    private static func shuffledTargets(_ targets: [Double], rng: inout SplitMix64) -> [Double] {
        var out = targets
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n >= 2 else { return .nan }
        let mx = x.prefix(n).reduce(0, +) / Double(n)
        let my = y.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0
        var sx = 0.0
        var sy = 0.0
        for i in 0..<n {
            let dx = x[i] - mx
            let dy = y[i] - my
            num += dx * dy
            sx += dx * dx
            sy += dy * dy
        }
        let denom = (sx * sy).squareRoot()
        return denom > 1e-12 ? num / denom : .nan
    }

    private static func concurrentMap<Input, Output>(
        _ inputs: [Input],
        progress: (@Sendable (DecodingProgress) -> Void)?,
        work: @escaping @Sendable (Input) throws -> (Int, Output, String)
    ) throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let lock = NSLock()
        var outputs = Array<Output?>(repeating: nil, count: inputs.count)
        var firstError: Error?
        var completed = 0
        var nextIndex = 0
        let workerCount = WorkerPool.maxWorkers(for: inputs.count)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "DENNIS.Decoding.Workers", qos: .userInitiated, attributes: .concurrent)

        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                while true {
                    lock.lock()
                    if firstError != nil || nextIndex >= inputs.count {
                        lock.unlock()
                        return
                    }
                    let index = nextIndex
                    nextIndex += 1
                    lock.unlock()

                    do {
                        let (outputIndex, output, message) = try work(inputs[index])
                        lock.lock()
                        if outputs.indices.contains(outputIndex) { outputs[outputIndex] = output }
                        completed += 1
                        let done = completed
                        lock.unlock()
                        progress?(DecodingProgress(completed: done, total: inputs.count, message: message))
                    } catch {
                        lock.lock()
                        if firstError == nil { firstError = error }
                        completed += 1
                        let done = completed
                        lock.unlock()
                        progress?(DecodingProgress(completed: done, total: inputs.count, message: "A decoding worker failed: \(error.localizedDescription)"))
                        return
                    }
                }
            }
        }
        group.wait()

        if let firstError { throw firstError }
        return outputs.compactMap { $0 }
    }

    nonisolated static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    nonisolated static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6g", value) : ""
    }

    private static func formatPercent(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f%%", value * 100) : "n/a"
    }
}

private nonisolated protocol DecodingModel: Sendable {
    func predict(_ features: [Double]) -> String
}

private nonisolated protocol DecodingRegressionModel: Sendable {
    func predict(_ features: [Double]) -> Double
}

private nonisolated struct Standardizer: Sendable {
    let mean: [Double]
    let scale: [Double]

    static func fit(_ observations: [DecodingObservation]) throws -> Standardizer {
        try fit(features: observations.map(\.features))
    }

    static func fit(_ observations: [DecodingRegressionObservation]) throws -> Standardizer {
        try fit(features: observations.map(\.features))
    }

    static func fit(features rows: [[Double]]) throws -> Standardizer {
        guard let featureCount = rows.first?.count else { throw Decoding.DecodingError.empty }
        var mean = Array(repeating: 0.0, count: featureCount)
        for row in rows {
            for i in 0..<featureCount { mean[i] += row[i] }
        }
        let invN = 1.0 / Double(max(1, rows.count))
        for i in 0..<featureCount { mean[i] *= invN }

        var variance = Array(repeating: 0.0, count: featureCount)
        for row in rows {
            for i in 0..<featureCount {
                let d = row[i] - mean[i]
                variance[i] += d * d
            }
        }
        let denom = Double(max(1, rows.count - 1))
        let scale = variance.map { value in
            let sd = (value / denom).squareRoot()
            return sd > 1e-12 ? sd : 1
        }
        return Standardizer(mean: mean, scale: scale)
    }

    func transform(_ features: [Double]) -> [Double] {
        features.indices.map { (features[$0] - mean[$0]) / scale[$0] }
    }
}

private nonisolated struct RidgeElasticNetModel: DecodingRegressionModel {
    let weights: [Double]
    let intercept: Double
    let targetMean: Double
    let targetScale: Double
    let standardizer: Standardizer

    static func train(_ observations: [DecodingRegressionObservation]) throws -> RidgeElasticNetModel {
        let standardizer = try Standardizer.fit(observations)
        let featureCount = observations.first?.features.count ?? 0
        let rows = observations.map { standardizer.transform($0.features) }
        let targets = observations.map(\.target)
        let n = Double(max(1, observations.count))
        let targetMean = targets.reduce(0, +) / n
        let targetVariance = targets.map { value in
            let d = value - targetMean
            return d * d
        }.reduce(0, +) / Double(max(1, observations.count - 1))
        let targetScale = targetVariance.squareRoot() > 1e-12 ? targetVariance.squareRoot() : 1
        let y = targets.map { ($0 - targetMean) / targetScale }

        let lambda = max(0.05, 1.0 / n)
        let l1Ratio = 0.15
        let l2 = lambda * (1 - l1Ratio)
        let l1 = lambda * l1Ratio
        var weights = Array(repeating: 0.0, count: featureCount)
        var intercept = 0.0
        var step = 0.2

        for iteration in 0..<900 {
            var gradW = Array(repeating: 0.0, count: featureCount)
            var gradB = 0.0
            for rowIndex in rows.indices {
                let prediction = dot(weights, rows[rowIndex]) + intercept
                let error = prediction - y[rowIndex]
                gradB += error
                for feature in 0..<featureCount { gradW[feature] += error * rows[rowIndex][feature] }
            }
            gradB /= n
            intercept -= step * gradB
            for feature in 0..<featureCount {
                let gradient = gradW[feature] / n + l2 * weights[feature]
                weights[feature] = softThreshold(weights[feature] - step * gradient, step * l1)
            }
            if iteration > 0 && iteration % 150 == 0 { step *= 0.7 }
        }

        return RidgeElasticNetModel(
            weights: weights,
            intercept: intercept,
            targetMean: targetMean,
            targetScale: targetScale,
            standardizer: standardizer
        )
    }

    func predict(_ features: [Double]) -> Double {
        let z = standardizer.transform(features)
        return (Self.dot(weights, z) + intercept) * targetScale + targetMean
    }

    private static func softThreshold(_ value: Double, _ threshold: Double) -> Double {
        if value > threshold { return value - threshold }
        if value < -threshold { return value + threshold }
        return 0
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(left.count, right.count) { sum += left[i] * right[i] }
        return sum
    }
}

private nonisolated struct CentroidModel: DecodingModel {
    let labels: [String]
    let centroids: [[Double]]
    let standardizer: Standardizer

    static func train(_ observations: [DecodingObservation], labels: [String]) throws -> CentroidModel {
        let standardizer = try Standardizer.fit(observations)
        let featureCount = observations.first?.features.count ?? 0
        var sums = Array(repeating: Array(repeating: 0.0, count: featureCount), count: labels.count)
        var counts = Array(repeating: 0, count: labels.count)
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })

        for observation in observations {
            guard let label = labelIndex[observation.label] else { continue }
            counts[label] += 1
            let z = standardizer.transform(observation.features)
            for i in 0..<featureCount { sums[label][i] += z[i] }
        }

        for (index, count) in counts.enumerated() {
            guard count > 0 else { throw Decoding.DecodingError.foldMissingClass(labels[index]) }
            let inv = 1.0 / Double(count)
            for i in 0..<featureCount { sums[index][i] *= inv }
        }

        return CentroidModel(labels: labels, centroids: sums, standardizer: standardizer)
    }

    func predict(_ features: [Double]) -> String {
        let z = standardizer.transform(features)
        var bestLabel = labels.first ?? ""
        var bestDistance = Double.infinity
        for (labelIndex, centroid) in centroids.enumerated() {
            var distance = 0.0
            for i in 0..<min(z.count, centroid.count) {
                let d = z[i] - centroid[i]
                distance += d * d
            }
            if distance < bestDistance {
                bestDistance = distance
                bestLabel = labels[labelIndex]
            }
        }
        return bestLabel
    }
}

private nonisolated struct ShrinkageLDAModel: DecodingModel {
    let labels: [String]
    let means: [[Double]]
    let variances: [Double]
    let priors: [Double]
    let standardizer: Standardizer

    static func train(_ observations: [DecodingObservation], labels: [String]) throws -> ShrinkageLDAModel {
        let standardizer = try Standardizer.fit(observations)
        let featureCount = observations.first?.features.count ?? 0
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
        var sums = Array(repeating: Array(repeating: 0.0, count: featureCount), count: labels.count)
        var counts = Array(repeating: 0, count: labels.count)
        var rows: [(label: Int, z: [Double])] = []

        for observation in observations {
            guard let label = labelIndex[observation.label] else { continue }
            let z = standardizer.transform(observation.features)
            rows.append((label, z))
            counts[label] += 1
            for i in 0..<featureCount { sums[label][i] += z[i] }
        }

        for (index, count) in counts.enumerated() {
            guard count > 0 else { throw Decoding.DecodingError.foldMissingClass(labels[index]) }
            let inv = 1.0 / Double(count)
            for i in 0..<featureCount { sums[index][i] *= inv }
        }

        var pooled = Array(repeating: 0.0, count: featureCount)
        var residualCount = 0
        for row in rows {
            let mean = sums[row.label]
            for i in 0..<featureCount {
                let d = row.z[i] - mean[i]
                pooled[i] += d * d
            }
            residualCount += 1
        }
        let denom = Double(max(1, residualCount - labels.count))
        pooled = pooled.map { max($0 / denom, 1e-6) }
        let grand = pooled.reduce(0, +) / Double(max(1, pooled.count))
        let shrinkage = min(0.95, max(0.05, Double(featureCount) / Double(max(featureCount + residualCount, 1))))
        let variances = pooled.map { (1 - shrinkage) * $0 + shrinkage * grand }
        let priors = counts.map { Double($0) / Double(max(1, observations.count)) }

        return ShrinkageLDAModel(labels: labels, means: sums, variances: variances, priors: priors, standardizer: standardizer)
    }

    func predict(_ features: [Double]) -> String {
        let z = standardizer.transform(features)
        var bestLabel = labels.first ?? ""
        var bestScore = -Double.infinity
        for label in labels.indices {
            var score = log(max(priors[label], 1e-12))
            let mean = means[label]
            for i in 0..<min(z.count, mean.count, variances.count) {
                score += z[i] * mean[i] / variances[i]
                score -= 0.5 * mean[i] * mean[i] / variances[i]
            }
            if score > bestScore {
                bestScore = score
                bestLabel = labels[label]
            }
        }
        return bestLabel
    }
}

private nonisolated struct LogisticRegressionModel: DecodingModel {
    let labels: [String]
    let weights: [[Double]]
    let intercepts: [Double]
    let standardizer: Standardizer

    static func train(_ observations: [DecodingObservation], labels: [String]) throws -> LogisticRegressionModel {
        let standardizer = try Standardizer.fit(observations)
        let featureCount = observations.first?.features.count ?? 0
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
        var counts = Array(repeating: 0, count: labels.count)
        var rows: [(label: Int, z: [Double])] = []

        for observation in observations {
            guard let label = labelIndex[observation.label] else { continue }
            counts[label] += 1
            rows.append((label, standardizer.transform(observation.features)))
        }
        for (index, count) in counts.enumerated() where count == 0 {
            throw Decoding.DecodingError.foldMissingClass(labels[index])
        }

        if labels.count == 2 {
            return trainBinary(labels: labels, rows: rows, counts: counts, featureCount: featureCount, standardizer: standardizer)
        }

        let n = Double(max(1, rows.count))
        let lambda = 1.0 / n
        var weights = Array(repeating: Array(repeating: 0.0, count: featureCount), count: labels.count)
        var intercepts = counts.map { count in
            let p = min(0.99, max(0.01, Double(count) / n))
            return log(p / (1 - p))
        }

        for label in labels.indices {
            var w = weights[label]
            var b = intercepts[label]
            var step = 0.35
            for iteration in 0..<700 {
                var gradW = Array(repeating: 0.0, count: featureCount)
                var gradB = 0.0
                for row in rows {
                    let y = row.label == label ? 1.0 : 0.0
                    let p = sigmoid(dot(w, row.z) + b)
                    let error = p - y
                    gradB += error
                    for i in 0..<featureCount { gradW[i] += error * row.z[i] }
                }
                gradB /= n
                for i in 0..<featureCount {
                    gradW[i] = gradW[i] / n + lambda * w[i]
                    w[i] -= step * gradW[i]
                }
                b -= step * gradB
                if iteration > 0 && iteration % 100 == 0 { step *= 0.7 }
            }
            weights[label] = w
            intercepts[label] = b
        }

        return LogisticRegressionModel(labels: labels, weights: weights, intercepts: intercepts, standardizer: standardizer)
    }

    private static func trainBinary(
        labels: [String],
        rows: [(label: Int, z: [Double])],
        counts: [Int],
        featureCount: Int,
        standardizer: Standardizer
    ) -> LogisticRegressionModel {
        let n = Double(max(1, rows.count))
        let lambda = 1.0 / n
        var w = Array(repeating: 0.0, count: featureCount)
        let positiveP = min(0.99, max(0.01, Double(counts[1]) / n))
        var b = log(positiveP / (1 - positiveP))
        var step = 0.35

        for iteration in 0..<450 {
            var gradW = Array(repeating: 0.0, count: featureCount)
            var gradB = 0.0
            for row in rows {
                let y = row.label == 1 ? 1.0 : 0.0
                let p = sigmoid(dot(w, row.z) + b)
                let error = p - y
                gradB += error
                for i in 0..<featureCount { gradW[i] += error * row.z[i] }
            }
            gradB /= n
            var maxStep = abs(step * gradB)
            for i in 0..<featureCount {
                gradW[i] = gradW[i] / n + lambda * w[i]
                let delta = step * gradW[i]
                w[i] -= delta
                maxStep = max(maxStep, abs(delta))
            }
            b -= step * gradB
            if maxStep < 1e-6 { break }
            if iteration > 0 && iteration % 100 == 0 { step *= 0.7 }
        }

        return LogisticRegressionModel(
            labels: labels,
            weights: [w.map { -$0 }, w],
            intercepts: [-b, b],
            standardizer: standardizer
        )
    }

    func predict(_ features: [Double]) -> String {
        let z = standardizer.transform(features)
        var bestLabel = labels.first ?? ""
        var bestScore = -Double.infinity
        for label in labels.indices {
            let score = Self.dot(weights[label], z) + intercepts[label]
            if score > bestScore {
                bestScore = score
                bestLabel = labels[label]
            }
        }
        return bestLabel
    }

    private static func sigmoid(_ value: Double) -> Double {
        if value >= 35 { return 1 }
        if value <= -35 { return 0 }
        return 1 / (1 + exp(-value))
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(left.count, right.count) { sum += left[i] * right[i] }
        return sum
    }
}

private nonisolated struct LinearSVMModel: DecodingModel {
    let labels: [String]
    let weights: [[Double]]
    let intercepts: [Double]
    let standardizer: Standardizer

    static func train(_ observations: [DecodingObservation], labels: [String]) throws -> LinearSVMModel {
        let standardizer = try Standardizer.fit(observations)
        let featureCount = observations.first?.features.count ?? 0
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
        var counts = Array(repeating: 0, count: labels.count)
        var rows: [(label: Int, z: [Double])] = []

        for observation in observations {
            guard let label = labelIndex[observation.label] else { continue }
            counts[label] += 1
            rows.append((label, standardizer.transform(observation.features)))
        }
        for (index, count) in counts.enumerated() where count == 0 {
            throw Decoding.DecodingError.foldMissingClass(labels[index])
        }

        if labels.count == 2 {
            return trainBinary(labels: labels, rows: rows, featureCount: featureCount, standardizer: standardizer)
        }

        let n = Double(max(1, rows.count))
        let lambda = 1.0 / n
        var weights = Array(repeating: Array(repeating: 0.0, count: featureCount), count: labels.count)
        var intercepts = Array(repeating: 0.0, count: labels.count)

        for label in labels.indices {
            var w = weights[label]
            var b = 0.0
            var step = 0.25
            for iteration in 0..<800 {
                var gradW = w.map { lambda * $0 }
                var gradB = 0.0
                for row in rows {
                    let y = row.label == label ? 1.0 : -1.0
                    let margin = y * (dot(w, row.z) + b)
                    if margin < 1 {
                        gradB -= y
                        for feature in 0..<featureCount {
                            gradW[feature] -= y * row.z[feature]
                        }
                    }
                }
                gradB /= n
                for feature in 0..<featureCount {
                    w[feature] -= step * (gradW[feature] / n)
                }
                b -= step * gradB
                if iteration > 0 && iteration % 120 == 0 { step *= 0.72 }
            }
            weights[label] = w
            intercepts[label] = b
        }

        return LinearSVMModel(labels: labels, weights: weights, intercepts: intercepts, standardizer: standardizer)
    }

    private static func trainBinary(
        labels: [String],
        rows: [(label: Int, z: [Double])],
        featureCount: Int,
        standardizer: Standardizer
    ) -> LinearSVMModel {
        let n = Double(max(1, rows.count))
        let lambda = 1.0 / n
        var w = Array(repeating: 0.0, count: featureCount)
        var b = 0.0
        var step = 0.25

        for iteration in 0..<360 {
            var gradW = w.map { lambda * $0 }
            var gradB = 0.0
            for row in rows {
                let y = row.label == 1 ? 1.0 : -1.0
                let margin = y * (dot(w, row.z) + b)
                if margin < 1 {
                    gradB -= y
                    for feature in 0..<featureCount {
                        gradW[feature] -= y * row.z[feature]
                    }
                }
            }
            gradB /= n
            var maxStep = abs(step * gradB)
            for feature in 0..<featureCount {
                let delta = step * (gradW[feature] / n)
                w[feature] -= delta
                maxStep = max(maxStep, abs(delta))
            }
            b -= step * gradB
            if maxStep < 1e-6 { break }
            if iteration > 0 && iteration % 90 == 0 { step *= 0.72 }
        }

        return LinearSVMModel(
            labels: labels,
            weights: [w.map { -$0 }, w],
            intercepts: [-b, b],
            standardizer: standardizer
        )
    }

    func predict(_ features: [Double]) -> String {
        let z = standardizer.transform(features)
        var bestLabel = labels.first ?? ""
        var bestScore = -Double.infinity
        for label in labels.indices {
            let score = Self.dot(weights[label], z) + intercepts[label]
            if score > bestScore {
                bestScore = score
                bestLabel = labels[label]
            }
        }
        return bestLabel
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(left.count, right.count) { sum += left[i] * right[i] }
        return sum
    }
}
