//
//  PCATests.swift
//  DENNISTests
//
//  Validates the native Accelerate PCA engine against ground-truth numbers
//  generated from the Python mne_erppca reference (`/tmp/genref.py`) on a fixed
//  9×5 two-factor input. Unrotated results are deterministic and checked
//  directly; Promax is checked up to factor permutation and sign.
//

import Testing
import Foundation
@testable import DENNIS

struct PCATests {

    // Fixed input shared with the Python reference.
    static let input: [[Double]] = [
        [-0.093831, -0.125417, -0.712562, -0.508011, -0.372749],
        [0.312309, 0.325693, 0.480496, 0.29591, 0.427108],
        [-0.276563, -0.20537, 0.28038, 0.234208, -0.062379],
        [-0.931034, -0.737946, 0.065038, -0.006354, -0.526488],
        [-0.483851, -0.507836, -0.924945, -0.786652, -0.844756],
        [-0.98784, -0.827466, -0.106609, -0.079597, -0.702811],
        [0.02807, 0.22368, 0.733416, 0.502292, 0.393478],
        [1.36905, 1.062333, -1.310069, -0.944676, 0.299406],
        [-0.42028, -0.522531, -0.447459, -0.438479, -0.566989],
    ]

    // MARK: - Linear algebra sanity

    @Test func symmetricEigenReconstructsMatrix() throws {
        let a = Matrix([[2, -1, 0], [-1, 2, -1], [0, -1, 2]])
        let (values, vectors) = try a.symmetricEigen()
        // Reconstruct A = V diag(values) V^T.
        var recon = vectors
        for c in 0..<recon.cols {
            for r in 0..<recon.rows { recon[r, c] *= values[c] }
        }
        let result = recon.multiply(vectors.transposed())
        for r in 0..<3 { for c in 0..<3 { #expect(abs(result[r, c] - a[r, c]) < 1e-9) } }
    }

    @Test func pseudoinverseSatisfiesMoorePenrose() throws {
        let a = Matrix([[1, 2], [3, 4], [5, 7]])
        let pinv = try a.pseudoinverse()
        let recon = a.multiply(pinv).multiply(a)            // A A+ A == A
        for r in 0..<3 { for c in 0..<2 { #expect(abs(recon[r, c] - a[r, c]) < 1e-8) } }
    }

    // MARK: - PCA vs Python reference

    @Test func unrotatedMatchesReference() throws {
        let result = try PCACore.doPCA(Matrix(Self.input), mode: .asIs,
                                       rotation: .unrotated, nFactors: 2,
                                       matrixType: .cov, loading: .kaiser)

        let expectedScree = [1.075781863, 0.7554823471, 0.002241231146, 0.001103506889, 0.0005453065908]
        for i in 0..<5 { #expect(abs(result.scree[i] - expectedScree[i]) < 1e-6) }

        let expectedPattern = [
            [0.9920277902, 0.1190345222],
            [0.9604654187, 0.2737637129],
            [-0.438526021, 0.8978375712],
            [-0.4035464353, 0.9130188501],
            [0.6687949471, 0.742198584],
        ]
        #expect(columnsMatch(result.pattern, expected: expectedPattern, tol: 1e-5))

        let expectedVar = [0.5862078679, 0.411672395]
        #expect(setsMatch(result.variance, expectedVar, tol: 1e-5))
        #expect(abs(result.totalVariance - 0.9978802629) < 1e-6)
    }

    @Test func promaxMatchesReference() throws {
        let result = try PCACore.doPCA(Matrix(Self.input), mode: .asIs,
                                       rotation: .promax, nFactors: 2,
                                       matrixType: .cov, loading: .kaiser, rotopt: 3)

        let expectedPattern = [
            [0.9586676429, -0.2582096437],
            [0.9908097921, -0.102781442],
            [-0.04817390011, 0.9968237841],
            [-0.01002990032, 0.9979199293],
            [0.9078962176, 0.4406701625],
        ]
        #expect(columnsMatch(result.pattern, expected: expectedPattern, tol: 1e-4))

        let expectedVar = [0.5605772953, 0.4373029675]
        #expect(setsMatch(result.variance, expectedVar, tol: 1e-4))

        // Off-diagonal factor correlation magnitude.
        #expect(abs(abs(result.correlation[0, 1]) - 0.02539513807) < 1e-4)
        #expect(abs(result.totalVariance - 0.9978802629) < 1e-5)
    }

    @Test func leaveOneSubjectOutJackknifeSummarizesAlignedLoadings() throws {
        let tensor = TwoStepTests.tensor
        let full = try PCACore.doPCA(
            tensor.reshape(forMode: .temporal),
            mode: .temporal,
            rotation: .unrotated,
            nFactors: 3
        )
        let jackknife = try PCAJackknife.leaveOneSubjectOut(
            tensor: tensor,
            mode: .temporal,
            fullResult: full,
            subjectNames: ["S1", "S2", "S3", "S4"],
            rotation: .unrotated,
            nFactors: 3
        )

        #expect(jackknife.succeeded == 4)
        #expect(jackknife.loadingMean.rows == full.pattern.rows)
        #expect(jackknife.loadingMean.cols == full.pattern.cols)
        #expect(jackknife.loadingSD.grid.allSatisfy { $0.isFinite })
        #expect(jackknife.maxLoadingSD > 0)
    }

    @MainActor
    @Test func reconstructedDualFactorPreservesTensorShapeAndMetadata() throws {
        let result = try TwoStepPCA.run(
            tensor: TwoStepTests.tensor,
            firstMode: .temporal,
            secondMode: .spatial,
            firstFactors: 3,
            secondFactors: 2,
            firstRotation: .unrotated,
            secondRotation: .unrotated
        )
        let bundle = AnalysisStore.DualBundle(
            result: result,
            groupID: "all",
            groupLabel: "All Subjects",
            conditionNames: ["Target", "Standard"],
            subjectNames: ["S1", "S2", "S3", "S4"],
            subjectLevels: [["Control"], ["Control"], ["Patient"], ["Patient"]],
            factorNames: ["Group"],
            conditionMetadata: ConditionModeMetadata(
                factorNames: ["Stimulus"],
                levelsByCondition: [["Target"], ["Standard"]]
            ),
            sensorLayout: nil,
            nChannels: 5,
            samplingRate: 250,
            baselineSamples: 25
        )
        let factor = try #require(result.factors.first)
        let built = try #require(DerivedDataBuilder.reconstructedDualFactor(bundle: bundle, factor: factor))
        let input = built.input

        #expect(input.nChannels == 5)
        #expect(input.nTimes == 8)
        #expect(input.conditionCount == 2)
        #expect(input.subjects.count == 4)
        #expect(input.subjects.allSatisfy { $0.count == 2 })
        #expect(input.subjects.flatMap { $0 }.allSatisfy { $0.count == 5 })
        #expect(input.subjects.flatMap { $0 }.flatMap { $0 }.allSatisfy { $0.count == 8 })
        #expect(input.samplingRate == 250)
        #expect(input.baselineSamples == 25)
        #expect(built.channelIndices == nil)
        #expect(input.subjects.flatMap { $0 }.flatMap { $0 }.flatMap { $0 }.allSatisfy { $0.isFinite })
    }

    @MainActor
    @Test func reconstructedDualFactorCanKeepOnlySelectedElectrodes() throws {
        let result = try TwoStepPCA.run(
            tensor: TwoStepTests.tensor,
            firstMode: .temporal,
            secondMode: .spatial,
            firstFactors: 3,
            secondFactors: 2,
            firstRotation: .unrotated,
            secondRotation: .unrotated
        )
        let bundle = AnalysisStore.DualBundle(
            result: result,
            groupID: "all",
            groupLabel: "All Subjects",
            conditionNames: ["Target", "Standard"],
            subjectNames: ["S1", "S2", "S3", "S4"],
            subjectLevels: [[], [], [], []],
            factorNames: [],
            conditionMetadata: .empty,
            sensorLayout: nil,
            nChannels: 5,
            samplingRate: 250,
            baselineSamples: 25
        )
        let factor = try #require(result.factors.first)
        let spatial = result.second[factor.firstIndex].pattern.column(factor.secondIndex)
        let threshold = spatial.map(abs).sorted()[2]
        let built = try #require(DerivedDataBuilder.reconstructedDualFactor(
            bundle: bundle,
            factor: factor,
            scope: .selectedElectrodes,
            threshold: threshold
        ))

        #expect(built.input.nChannels == built.channelIndices?.count)
        #expect((built.channelIndices ?? []).allSatisfy { abs(spatial[$0]) >= threshold })
        #expect(built.input.nChannels < bundle.nChannels)
    }

    @MainActor
    @Test func derivedDataExporterWritesLongFormCSVAndTSV() {
        let item = AnalysisStore.DerivedDataItem(
            id: UUID(),
            name: "Comma, Factor",
            kind: .reconstructedDualFactor,
            sourceGroupID: "all",
            sourceGroupLabel: "All",
            selectedFactorName: "TF1SF1",
            conditionNames: ["Target"],
            subjectNames: ["S1"],
            subjectLevels: [["Control"]],
            factorNames: ["Group"],
            conditionMetadata: ConditionModeMetadata(
                factorNames: ["Stimulus"],
                levelsByCondition: [["Oddball"]]
            ),
            input: EPTensor.Input(
                nChannels: 1,
                nTimes: 2,
                conditionCount: 1,
                subjects: [[[[1.25, -2.5]]]],
                samplingRate: 1000,
                baselineSamples: 1
            ),
            channelIndices: nil,
            nativeUnit: .component,
            microvoltScale: nil,
            factorPreview: nil,
            provenance: "test"
        )

        let csv = DerivedDataExporter.table(item, format: .csv)
        let tsv = DerivedDataExporter.table(item, format: .tsv)

        #expect(csv.split(separator: "\n").count == 3)
        #expect(csv.contains("\"Comma, Factor\""))
        #expect(csv.contains("-1,component units,1.25"))
        #expect(tsv.split(separator: "\n").count == 3)
        #expect(tsv.contains("\tControl\tTarget\tOddball\t"))
        #expect(tsv.contains("0\tcomponent units\t-2.5"))
    }

    @MainActor
    @Test func derivedDataExporterCanWriteMicrovoltScaledValues() {
        let item = AnalysisStore.DerivedDataItem(
            id: UUID(),
            name: "Scaled",
            kind: .reconstructedDualFactor,
            sourceGroupID: "all",
            sourceGroupLabel: "All",
            selectedFactorName: "TF1SF1",
            conditionNames: ["Target"],
            subjectNames: ["S1"],
            subjectLevels: [[]],
            factorNames: [],
            conditionMetadata: .empty,
            input: EPTensor.Input(
                nChannels: 1,
                nTimes: 2,
                conditionCount: 1,
                subjects: [[[[1, 2]]]],
                samplingRate: 1000,
                baselineSamples: 0
            ),
            channelIndices: nil,
            nativeUnit: .component,
            microvoltScale: [[2, 3]],
            factorPreview: nil,
            provenance: "test"
        )

        let csv = DerivedDataExporter.table(
            DerivedDataExporter.Snapshot(item: item),
            format: .csv,
            units: .microvolts
        )

        #expect(csv.contains("µV,2"))
        #expect(csv.contains("µV,6"))
    }

    @Test func tableImporterRecognizesDerivedExportHeaders() {
        let headers = [
            "DerivedData", "Kind", "SourceGroup", "SelectedFactor",
            "Subject", "Group", "Condition", "Stimulus",
            "Channel", "TimeIndex", "Time_ms", "Unit", "Value"
        ]

        #expect(TableDataImporter.looksLikeDerivedData(headers: headers))
        #expect(!TableDataImporter.looksLikeDerivedData(headers: ["Subject", "Age", "Accuracy"]))
    }

    @Test func tableImporterHandlesWindowsCRLFLineEndings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("behavioral_crlf_\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try "Subject,Age,Accuracy\r\nS1,20,0.95\r\nS2,21,0.90\r\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try TableDataImporter.parse(url: url)

        #expect(parsed.headers == ["Subject", "Age", "Accuracy"])
        #expect(parsed.rows.count == 2)
        #expect(parsed.rows[1] == ["S2", "21", "0.90"])
    }

    @MainActor
    @Test func derivedDataCSVCanBeReimported() async throws {
        let item = AnalysisStore.DerivedDataItem(
            id: UUID(),
            name: "Round Trip",
            kind: .reconstructedDualFactor,
            sourceGroupID: "all",
            sourceGroupLabel: "All",
            selectedFactorName: "TF1SF1",
            conditionNames: ["A"],
            subjectNames: ["S1"],
            subjectLevels: [["Control"]],
            factorNames: ["Group"],
            conditionMetadata: ConditionModeMetadata(factorNames: ["Stimulus"], levelsByCondition: [["A"]]),
            input: EPTensor.Input(
                nChannels: 2,
                nTimes: 2,
                conditionCount: 1,
                subjects: [[[[1, 2], [3, 4]]]],
                samplingRate: 1000,
                baselineSamples: 1
            ),
            channelIndices: [0, 2],
            nativeUnit: .component,
            microvoltScale: nil,
            factorPreview: nil,
            provenance: "test"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived_roundtrip_\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try DerivedDataExporter.table(item, format: .csv).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await TableDataImporter.loadDerivedData(from: url)
        #expect(imported.name == "Round Trip")
        #expect(imported.subjectNames == ["S1"])
        #expect(imported.conditionNames == ["A"])
        #expect(imported.input.nChannels == 2)
        #expect(imported.input.nTimes == 2)
        #expect(imported.input.samplingRate == 1000)
        #expect(imported.input.baselineSamples == 1)
        #expect(imported.channelIndices == [0, 2])
        #expect(imported.nativeUnit == .component)
        #expect(imported.input.subjects[0][0][1][1] == 4)
    }

    // MARK: - Comparison helpers

    /// True if result columns equal expected columns up to permutation and a
    /// per-column sign flip.
    private func columnsMatch(_ result: Matrix, expected: [[Double]], tol: Double) -> Bool {
        let nf = expected.first?.count ?? 0
        guard result.cols == nf, result.rows == expected.count else { return false }
        var used = Set<Int>()
        for e in 0..<nf {
            let expCol = expected.map { $0[e] }
            var matched = false
            for r in 0..<nf where !used.contains(r) {
                let resCol = result.column(r)
                if colsEqual(resCol, expCol, tol: tol) || colsEqual(resCol.map { -$0 }, expCol, tol: tol) {
                    used.insert(r); matched = true; break
                }
            }
            if !matched { return false }
        }
        return true
    }

    private func colsEqual(_ a: [Double], _ b: [Double], tol: Double) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) < tol }
    }

    /// True if two value lists match as multisets within tolerance.
    private func setsMatch(_ a: [Double], _ b: [Double], tol: Double) -> Bool {
        guard a.count == b.count else { return false }
        var remaining = b
        for value in a {
            guard let idx = remaining.firstIndex(where: { abs($0 - value) < tol }) else { return false }
            remaining.remove(at: idx)
        }
        return true
    }
}
