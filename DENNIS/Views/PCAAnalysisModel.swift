//
//  PCAAnalysisModel.swift
//  DENNIS
//
//  Analysis orchestration for the PCA mode, pulled out of the view so the
//  scree / temporal / dual runners are plain, testable methods rather than
//  private functions buried in a SwiftUI body. The view owns user inputs
//  (factor counts, rotations, the trim window) and display state; this model
//  owns the results, their run lifecycle (running / error / progress), and the
//  per-subject cluster data that the dual decomposition produces.
//

import SwiftUI

@Observable
@MainActor
final class PCAAnalysisModel {
    // Temporal scree / parallel analysis.
    var screeAnalysis: ScreeAnalysis?
    var screeError: String?
    var screeRunning = false
    var screeProgress = RunProgress()

    // Temporal PCA.
    var pcaModel: TemporalPCAResult?
    var pcaError: String?
    var pcaRunning = false
    var pcaProgress = RunProgress()

    // Dual (two-step) PCA: temporal → spatial.
    var dualModel: TwoStepPCAResult?
    var dualError: String?
    var dualRunning = false
    var dualProgress = RunProgress()

    // Spatial scree (second step of the dual decomposition).
    var spatialScree: ScreeAnalysis?
    var spatialScreeError: String?
    var spatialScreeRunning = false
    var spatialScreeProgress = RunProgress()

    // Per-subject ERP + design levels for cluster plots (built when dual results land).
    var clusterSubjects: [ClusterSubject] = []
    var clusterBaseline = 0
    var clusterSamplingRate = 0.0

    // MARK: - Cluster ERP data

    /// Per-subject ERPs (channels × samples per condition) plus each subject's
    /// design levels, used by the cluster-ERP plots when a factor topography is
    /// clicked. References existing sample arrays (copy-on-write).
    struct ClusterData: Sendable {
        var subjects: [ClusterSubject]
        var baseline: Int
        var samplingRate: Double
    }

    static func makeClusterData(members: [Dataset], conditionNames: [String]) -> ClusterData {
        var out: [ClusterSubject] = []
        var baseline = 0
        var sfreq = 0.0
        for dataset in members {
            var byCondition: [String: [[Float]]] = [:]
            for name in conditionNames {
                if let condition = dataset.conditions.first(where: { $0.name == name }),
                   let samples = condition.samples, !samples.isEmpty {
                    byCondition[name] = samples
                    baseline = condition.baselineSamples
                    sfreq = dataset.samplingRate
                }
            }
            if !byCondition.isEmpty {
                out.append(ClusterSubject(name: dataset.name, levels: dataset.levels, byCondition: byCondition))
            }
        }
        return ClusterData(subjects: out, baseline: baseline, samplingRate: sfreq)
    }

    func prepareClusterERP(members: [Dataset], conditionNames: [String]) {
        let data = Self.makeClusterData(members: members, conditionNames: conditionNames)
        clusterSubjects = data.subjects
        clusterBaseline = data.baseline
        clusterSamplingRate = data.samplingRate
    }

    // MARK: - Temporal scree

    func runScree(members: [Dataset], conditionNames: [String],
                  timeIndices: [Int]?, mode: PCAMode) {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            screeAnalysis = nil
            screeError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let report = screeProgress.handler()
        screeProgress.reset()
        screeRunning = true
        screeError = nil
        Task.detached(priority: .userInitiated) {
            let result: Result<ScreeAnalysis, Error>
            do {
                report(0.02, "Assembling data tensor")
                let tensor = EPTensor.build(from: input, timeIndices: timeIndices)
                result = .success(try Scree.analyze(tensor, mode: mode, report: report))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.screeRunning = false
                switch result {
                case .success(let analysis): self.screeAnalysis = analysis
                case .failure(let error):
                    self.screeAnalysis = nil
                    self.screeError = (error as? LocalizedError)?.errorDescription
                        ?? "Scree analysis failed: \(error)"
                }
            }
        }
    }

    // MARK: - Temporal PCA

    func runTemporalPCA(members: [Dataset], conditionNames: [String],
                        timeIndices: [Int]?, timesMS: [Double],
                        rotation: PCARotation, requestedFactors: Int) {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            pcaModel = nil
            pcaError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let report = pcaProgress.handler()
        pcaProgress.reset()
        pcaRunning = true
        pcaError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<TemporalPCAResult, Error>
            do {
                report(0.02, "Assembling data tensor")
                let tensor = EPTensor.build(from: input, timeIndices: timeIndices)
                let nFactors = min(requestedFactors, tensor.variableCount(for: .temporal))
                report(0.05, "Reshaping for temporal PCA")
                let matrix = tensor.reshape(forMode: .temporal)
                let result = try PCACore.doPCA(
                    matrix, mode: .temporal, rotation: rotation, nFactors: nFactors,
                    report: report
                )
                outcome = .success(TemporalPCAResult(result: result, timesMS: timesMS))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.pcaRunning = false
                switch outcome {
                case .success(let model): self.pcaModel = model
                case .failure(let error):
                    self.pcaModel = nil
                    self.pcaError = (error as? LocalizedError)?.errorDescription
                        ?? "Temporal PCA failed: \(error)"
                }
            }
        }
    }

    // MARK: - Dual (two-step) PCA

    func runSpatialScree(members: [Dataset], conditionNames: [String],
                         timeIndices: [Int]?, firstRotation: PCARotation, firstFactors: Int) {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            spatialScree = nil
            spatialScreeError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let report = spatialScreeProgress.handler()
        spatialScreeProgress.reset()
        spatialScreeRunning = true
        spatialScreeError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<ScreeAnalysis, Error>
            do {
                report(0.02, "Assembling data tensor")
                let tensor = EPTensor.build(from: input, timeIndices: timeIndices)
                let analysis = try Scree.analyzeTwoStep(
                    tensor, firstMode: .temporal, secondMode: .spatial,
                    firstFactors: firstFactors, firstRotation: firstRotation, report: report
                )
                outcome = .success(analysis)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.spatialScreeRunning = false
                switch outcome {
                case .success(let analysis): self.spatialScree = analysis
                case .failure(let error):
                    self.spatialScree = nil
                    self.spatialScreeError = (error as? LocalizedError)?.errorDescription
                        ?? "Spatial scree failed: \(error)"
                }
            }
        }
    }

    func runDualPCA(members: [Dataset], conditionNames: [String],
                    timeIndices: [Int]?, timesMS: [Double],
                    firstRotation: PCARotation, secondRotation: PCARotation,
                    firstFactors: Int, spatialFactors: Int,
                    sensorLayout: SensorLayout?, groupID: String, groupLabel: String,
                    store: AnalysisStore) {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            dualModel = nil
            dualError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let subjectNames = snapshot.subjects.map(\.name)
        let nChannels = input.nChannels
        // Gather the per-subject cluster data up front (cheap, copy-on-write) so
        // the detached task never has to touch the Dataset models.
        let clusterData = Self.makeClusterData(members: members, conditionNames: conditionNames)
        let report = dualProgress.handler()
        dualProgress.reset()
        dualRunning = true
        dualError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<TwoStepPCAResult, Error>
            do {
                report(0.02, "Assembling data tensor")
                let tensor = EPTensor.build(from: input, timeIndices: timeIndices)
                let result = try TwoStepPCA.run(
                    tensor: tensor, firstMode: .temporal, secondMode: .spatial,
                    firstFactors: firstFactors, secondFactors: spatialFactors,
                    firstRotation: firstRotation, secondRotation: secondRotation,
                    firstTimesMS: timesMS, report: report
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.dualRunning = false
                switch outcome {
                case .success(let model):
                    self.dualModel = model
                    store.dual = AnalysisStore.DualBundle(
                        result: model, groupID: groupID, groupLabel: groupLabel,
                        conditionNames: conditionNames, subjectNames: subjectNames,
                        sensorLayout: sensorLayout, nChannels: nChannels
                    )
                    self.clusterSubjects = clusterData.subjects
                    self.clusterBaseline = clusterData.baseline
                    self.clusterSamplingRate = clusterData.samplingRate
                case .failure(let error):
                    self.dualModel = nil
                    self.dualError = (error as? LocalizedError)?.errorDescription
                        ?? "Dual PCA failed: \(error)"
                }
            }
        }
    }
}
