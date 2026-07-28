//
//  DecodingTests.swift
//  DENNISTests
//

import Foundation
import Testing
@testable import DENNIS

struct DecodingTests {
    @Test func leaveOneSubjectOutSeparatesLinearClasses() throws {
        let dataset = linearlySeparableDataset()
        let result = try Decoding.leaveOneSubjectOut(dataset, classifier: .shrinkageLDA, concurrent: false)

        #expect(result.predictions.count == 8)
        #expect(result.accuracy == 1)
        #expect(result.balancedAccuracy == 1)
        #expect(result.confusion == [[4, 0], [0, 4]])
    }

    @Test func nearestCentroidClassifierRemainsAvailable() throws {
        let dataset = linearlySeparableDataset()
        let result = try Decoding.leaveOneSubjectOut(dataset, classifier: .nearestCentroid, concurrent: true)

        #expect(result.classifier == .nearestCentroid)
        #expect(result.predictions.count == 8)
        #expect(result.balancedAccuracy == 1)
    }

    @Test func l2LogisticClassifierSeparatesLinearClasses() throws {
        let dataset = linearlySeparableDataset()
        let result = try Decoding.leaveOneSubjectOut(dataset, classifier: .logisticL2, concurrent: false)

        #expect(result.classifier == .logisticL2)
        #expect(result.predictions.count == 8)
        #expect(result.accuracy == 1)
        #expect(result.balancedAccuracy == 1)
    }

    @Test func linearSVMClassifierSeparatesLinearClasses() throws {
        let dataset = linearlySeparableDataset()
        let result = try Decoding.leaveOneSubjectOut(dataset, classifier: .linearSVM, concurrent: false)

        #expect(result.classifier == .linearSVM)
        #expect(result.predictions.count == 8)
        #expect(result.accuracy == 1)
        #expect(result.balancedAccuracy == 1)
    }

    @Test func timeResolvedLinearSVMUsesWindowParallelPath() throws {
        let windows = [linearlySeparableDataset(time: 100), linearlySeparableDataset(time: 125)]
        let result = try Decoding.timeResolved(datasets: windows, classifier: .linearSVM, concurrent: true)

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.result.classifier == .linearSVM })
        #expect(result.allSatisfy { $0.balancedAccuracy == 1 })
    }

    @Test func ridgeElasticNetPredictsContinuousTargets() throws {
        let dataset = continuousPredictionDataset()
        let result = try Decoding.leaveOneSubjectOutRegression(dataset, regressor: .ridgeElasticNet, concurrent: false)

        #expect(result.regressor == .ridgeElasticNet)
        #expect(result.predictions.count == 8)
        #expect(result.correlation > 0.95)
        #expect(result.rmse < result.baselineRMSE)
    }

    @Test func permutationTestReportsRequestedNullRuns() throws {
        let dataset = linearlySeparableDataset()
        let observed = try Decoding.leaveOneSubjectOut(dataset, classifier: .shrinkageLDA, concurrent: false)
        let result = try Decoding.permutationTest(
            dataset: dataset,
            classifier: .shrinkageLDA,
            observed: observed,
            permutations: 12,
            concurrent: true,
            seed: 42
        )

        #expect(result.observed == 1)
        #expect(result.nullDistribution.count == 12)
        #expect(result.pValue > 0)
        #expect(result.pValue <= 1)
    }

    @Test func temporalGeneralizationBuildsSquareAccuracyMatrix() throws {
        let early = linearlySeparableDataset(time: 100)
        let late = linearlySeparableDataset(time: 200)
        let result = try Decoding.temporalGeneralization(
            datasets: [early, late],
            classifier: .shrinkageLDA,
            concurrent: true
        )

        #expect(result.trainTimesMS == [100, 200])
        #expect(result.testTimesMS == [100, 200])
        #expect(result.balancedAccuracy.count == 2)
        #expect(result.balancedAccuracy.allSatisfy { $0.count == 2 })
        #expect(result.balancedAccuracy.flatMap { $0 }.allSatisfy { $0 == 1 })
    }

    @MainActor
    @Test func buildsBetweenSubjectFactorDataset() throws {
        let subjects = [
            subject("S1", levels: ["Control"]),
            subject("S2", levels: ["Patient"])
        ]
        let input = tinyInput()

        let dataset = try #require(Decoding.makeBetweenSubjectDataset(
            from: input,
            subjects: subjects,
            conditionNames: ["A", "B"],
            selectedConditions: ["A", "B"],
            factorIndex: 0,
            timeIndices: [0, 1],
            timesMS: [0, 100]
        ))

        #expect(dataset.labels == ["Control", "Patient"])
        #expect(dataset.observations.map(\.label) == ["Control", "Patient"])
        #expect(dataset.observations.count == 2)
        #expect(dataset.featureCount == 4)
    }

    @MainActor
    @Test func buildsConditionFactorDataset() throws {
        let subjects = [subject("S1", levels: []), subject("S2", levels: [])]
        let input = tinyInput()
        let metadata = ConditionModeMetadata(
            factorNames: ["Stimulus"],
            levelsByCondition: [["Target"], ["Distractor"]]
        )

        let dataset = try #require(Decoding.makeConditionFactorDataset(
            from: input,
            subjects: subjects,
            conditionNames: ["A", "B"],
            conditionMetadata: metadata,
            factorIndex: 0,
            selectedConditions: ["A", "B"],
            timeIndices: [0, 1],
            timesMS: [0, 100]
        ))

        #expect(dataset.labels == ["Target", "Distractor"])
        #expect(dataset.observations.map(\.label) == ["Target", "Distractor", "Target", "Distractor"])
        #expect(dataset.observations.count == 4)
        #expect(dataset.featureCount == 2)
    }

    @MainActor
    @Test func buildsLinkedBehavioralSubjectDataset() throws {
        let subjects = [subject("S1", levels: []), subject("S2", levels: [])]
        let input = tinyInput()

        let dataset = try #require(Decoding.makeSubjectLabelDataset(
            from: input,
            subjects: subjects.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) },
            conditionNames: ["A", "B"],
            selectedConditions: ["A"],
            labelsBySubjectName: ["S1": "Fast", "S2": "Slow"],
            timeIndices: [0, 1],
            timesMS: [0, 100]
        ))

        #expect(dataset.labels == ["Fast", "Slow"])
        #expect(dataset.observations.map(\.label) == ["Fast", "Slow"])
        #expect(dataset.featureCount == 2)
    }

    @MainActor
    @Test func buildsLinkedBehavioralValueDataset() throws {
        let subjects = [subject("S1", levels: []), subject("S2", levels: []), subject("S3", levels: [])]
        let input = EPTensor.Input(
            nChannels: 1,
            nTimes: 2,
            conditionCount: 1,
            subjects: [
                [[[1, 2]]],
                [[[3, 4]]],
                [[[5, 6]]]
            ],
            samplingRate: 10,
            baselineSamples: 0
        )

        let dataset = try #require(Decoding.makeSubjectValueDataset(
            from: input,
            subjects: subjects.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) },
            conditionNames: ["A"],
            selectedConditions: ["A"],
            valuesBySubjectName: ["S1": 10, "S2": 20, "S3": 30],
            timeIndices: [0, 1],
            timesMS: [0, 100]
        ))

        #expect(dataset.observations.map(\.target) == [10, 20, 30])
        #expect(dataset.featureCount == 2)
    }

    private func linearlySeparableDataset(time: Double? = nil) -> DecodingDataset {
        var observations: [DecodingObservation] = []
        for subject in 0..<4 {
            observations.append(DecodingObservation(
                subjectIndex: subject,
                subjectName: "S\(subject + 1)",
                label: "A",
                features: [0.0, Double(subject) * 0.01]
            ))
            observations.append(DecodingObservation(
                subjectIndex: subject,
                subjectName: "S\(subject + 1)",
                label: "B",
                features: [10.0, Double(subject) * 0.01]
            ))
        }

        return DecodingDataset(
            observations: observations,
            labels: ["A", "B"],
            featureCount: 2,
            timeLabelMS: time,
            windowStartMS: time,
            windowEndMS: time
        )
    }

    private func continuousPredictionDataset(time: Double? = nil) -> DecodingRegressionDataset {
        var observations: [DecodingRegressionObservation] = []
        for subject in 0..<8 {
            let x = Double(subject)
            observations.append(DecodingRegressionObservation(
                subjectIndex: subject,
                subjectName: "S\(subject + 1)",
                target: 2 * x + 5,
                features: [x, x * 0.5, 1.0]
            ))
        }

        return DecodingRegressionDataset(
            observations: observations,
            featureCount: 3,
            timeLabelMS: time,
            windowStartMS: time,
            windowEndMS: time
        )
    }

    @MainActor
    private func subject(_ name: String, levels: [String]) -> Dataset {
        Dataset(
            name: name,
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).mff"),
            conditions: [],
            samplingRate: 10,
            channelCount: 1,
            loadState: .loaded,
            levels: levels
        )
    }

    private func tinyInput() -> EPTensor.Input {
        EPTensor.Input(
            nChannels: 1,
            nTimes: 2,
            conditionCount: 2,
            subjects: [
                [
                    [[1, 2]],
                    [[3, 4]]
                ],
                [
                    [[10, 20]],
                    [[30, 40]]
                ]
            ],
            samplingRate: 10,
            baselineSamples: 0
        )
    }
}
