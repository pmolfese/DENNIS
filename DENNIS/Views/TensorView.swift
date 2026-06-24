//
//  TensorView.swift
//  DENNIS
//
//  The Tensor tab for a selected group. A "Source" dropdown switches between the
//  ERP tensor (channels × time × condition × subject) and a time-frequency tensor
//  (computed internally; Morlet or windowed FFT, with three structures and raw or
//  dB power). Both feed the same per-mode scree, fit/CORCONDIA sweep, split-half
//  reliability, PARAFAC decomposition, mode-aware explorer, and export.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

nonisolated enum TensorSource: String, CaseIterable { case erp = "ERP", timeFrequency = "Time-frequency" }
nonisolated enum TensorAlgorithm: String, CaseIterable {
    case parafac = "PARAFAC"
    case parafac2 = "PARAFAC2"
}

struct TensorView: View {
    @Environment(Study.self) private var study
    let groupID: String

    @State private var source: TensorSource = .erp
    /// Pool conditions (drop the condition mode) → channels × time × subject etc.
    @State private var poolConditions = false

    // ERP preprocessing + window.
    @State private var centerSubjects = false
    @State private var centerTime = false
    @State private var scaleChannels = false
    @State private var trimPre: Double = -100
    @State private var trimPost: Double = 900
    @State private var downsample = 2
    @State private var windowInitialized = false

    // Time-frequency parameters.
    @State private var tfMethod: TFConfig.Method = .morlet
    @State private var tfFreqMin: Double = 2
    @State private var tfFreqMax: Double = 40
    @State private var tfNFreqs = 30
    @State private var tfSpacing: TFConfig.Spacing = .log
    @State private var tfCyclesMin: Double = 3
    @State private var tfCyclesMax: Double = 10
    @State private var tfWindowMS: Double = 200
    @State private var tfStepMS: Double = 25
    @State private var tfStructure: TFStructure = .collapseTime
    @State private var tfTransform: TFTransform = .logBaseline
    @State private var tfTimeStride = 4
    @State private var tfCollapseStartMS: Double = 0
    @State private var tfCollapseEndMS: Double = 800
    @State private var tfBandLow: Double = 4
    @State private var tfBandHigh: Double = 8
    @State private var preview: TFRepresentation?

    // Diagnostics.
    @State private var parallelAnalysis = true
    @State private var parallelReps = 5
    @State private var modeScrees: [ModeScree]?
    @State private var recommendedRank = 3
    @State private var diagRunning = false
    @State private var diagError: String?
    @State private var diagProgress = RunProgress()

    // PARAFAC + mode metadata of the current result.
    @State private var algorithm: TensorAlgorithm = .parafac
    @State private var rank = 3
    @State private var nStarts = 10
    @State private var cpResult: CPResult?
    @State private var cpCoreConsistency: Double?
    @State private var cpModeTypes: [TFModeType] = []
    @State private var cpFreqs: [Double] = []
    @State private var cpTimesMS: [Double] = []
    @State private var cpRunning = false
    @State private var cpError: String?
    @State private var cpProgress = RunProgress()

    // Component-count diagnostics.
    @State private var sweepMaxRank = 8
    @State private var sweepPoints: [MultiwayDiagnostics.RankPoint]?
    @State private var sweepRunning = false
    @State private var sweepProgress = RunProgress()
    @State private var splitHalf: MultiwayDiagnostics.SplitHalf?
    @State private var splitRunning = false
    @State private var diagnosticsError: String?
    @State private var exportError: String?

    private var members: [Dataset] { study.datasets(inGroupID: groupID) }
    private var conditionNames: [String] { study.sharedConditionNames(inGroupID: groupID) }
    private var loadedCount: Int { members.filter { $0.loadState == .loaded }.count }
    private var groupSensorLayout: SensorLayout? { members.compactMap(\.sensorLayout).first }
    private var title: String {
        groupID.isEmpty ? study.name : (groupID.split(separator: "/").last.map(String.init) ?? groupID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(spacing: 14) {
                    Picker("Source", selection: $source) {
                        ForEach(TensorSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Toggle("Average over conditions", isOn: $poolConditions).toggleStyle(.checkbox)
                    HelpButton(text: "Drops the condition mode by averaging each subject's conditions "
                               + "together — e.g. ERP becomes a channels × time × subject decomposition "
                               + "(the classic topographic components model). You lose condition loadings "
                               + "but keep the subject loadings and the between-subject design grouping; "
                               + "fewer modes often give a more stable, identifiable solution.")
                }
                Divider()
                if source == .erp { erpPreprocessingSection } else { tfSection }
                Divider()
                diagnosticsSection
                Divider()
                componentCountSection
                Divider()
                parafacSection
                if let result = cpResult {
                    Divider()
                    exportSection(result)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .onAppear(perform: initializeWindowIfNeeded)
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · tensor").font(.largeTitle.bold())
            if let summary = dimsSummary { Text(summary).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    private var dimsSummary: String? {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else { return nil }
        let input = snapshot.input
        let nTimes = currentTimeAxis()?.indices.count ?? input.nTimes
        let nCond = poolConditions ? 1 : input.conditionCount
        let nSubj = snapshot.subjects.count
        let elements = input.nChannels * nTimes * nCond * nSubj
        return "\(input.nChannels) ch × \(nTimes) time × \(nCond) cond × \(nSubj) subj"
            + "  ·  \(elements.formatted()) elements"
    }

    // MARK: - ERP preprocessing

    private var erpPreprocessingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Preprocessing & window").font(.headline)
                HelpButton(text: "Preprocessing is off by default — PARAFAC then decomposes the raw "
                           + "averaged ERP. Centering across subjects models between-subject variation; "
                           + "centering across time removes a per-channel DC offset; scaling within "
                           + "channels stops high-amplitude channels from dominating. Trimming and "
                           + "downsampling keep the tensor small.")
            }
            Toggle("Center across subjects", isOn: $centerSubjects).toggleStyle(.checkbox)
            Toggle("Center across time", isOn: $centerTime).toggleStyle(.checkbox)
            Toggle("Scale within channels", isOn: $scaleChannels).toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Text("Window (ms):").font(.caption).foregroundStyle(.secondary)
                TextField("pre", value: $trimPre, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("–").foregroundStyle(.secondary)
                TextField("post", value: $trimPost, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Stepper("Downsample ×\(downsample)", value: $downsample, in: 1...16).fixedSize()
            }
        }
        .font(.callout)
    }

    // MARK: - Time-frequency configuration + preview

    private var tfSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Time-frequency").font(.headline)
                HelpButton(text: "Computed internally on the averaged ERP (evoked, phase-locked power). "
                           + "Morlet keeps full time resolution; the cycle ramp trades time vs frequency "
                           + "resolution. Windowed FFT slides a Hann window. Structure picks which modes "
                           + "enter the tensor; raw power uses nonnegative PARAFAC, dB normalizes to the "
                           + "pre-stimulus baseline.")
                Spacer()
                Button { runPreview() } label: { Label("Preview", systemImage: "eye") }
                    .buttonStyle(.bordered).disabled(loadedCount == 0)
            }
            HStack(spacing: 12) {
                Picker("Method", selection: $tfMethod) {
                    ForEach(TFConfig.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Text("Freq:").font(.caption).foregroundStyle(.secondary)
                TextField("min", value: $tfFreqMin, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                Text("–").foregroundStyle(.secondary)
                TextField("max", value: $tfFreqMax, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                Stepper("\(tfNFreqs) freqs", value: $tfNFreqs, in: 4...80).fixedSize()
                Picker("Spacing", selection: $tfSpacing) {
                    ForEach(TFConfig.Spacing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
            }
            if tfMethod == .morlet {
                HStack(spacing: 12) {
                    Text("Cycles:").font(.caption).foregroundStyle(.secondary)
                    TextField("min", value: $tfCyclesMin, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                    Text("–").foregroundStyle(.secondary)
                    TextField("max", value: $tfCyclesMax, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                }
            } else {
                HStack(spacing: 12) {
                    Text("Window/step (ms):").font(.caption).foregroundStyle(.secondary)
                    TextField("win", value: $tfWindowMS, format: .number).frame(width: 55).textFieldStyle(.roundedBorder)
                    TextField("step", value: $tfStepMS, format: .number).frame(width: 55).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 12) {
                Picker("Structure", selection: $tfStructure) {
                    ForEach(TFStructure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Picker("Power", selection: $tfTransform) {
                    ForEach(TFTransform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                if tfStructure == .fiveWay {
                    Stepper("Time ÷\(tfTimeStride)", value: $tfTimeStride, in: 1...20).fixedSize()
                }
            }
            if tfStructure == .collapseTime {
                HStack(spacing: 12) {
                    Text("Window (ms):").font(.caption).foregroundStyle(.secondary)
                    TextField("start", value: $tfCollapseStartMS, format: .number).frame(width: 55).textFieldStyle(.roundedBorder)
                    TextField("end", value: $tfCollapseEndMS, format: .number).frame(width: 55).textFieldStyle(.roundedBorder)
                }
            } else if tfStructure == .collapseFrequency {
                HStack(spacing: 12) {
                    Text("Band (Hz):").font(.caption).foregroundStyle(.secondary)
                    TextField("low", value: $tfBandLow, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                    TextField("high", value: $tfBandHigh, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                }
            }
            if let preview {
                SpectrogramView(freqs: preview.freqs, timesMS: preview.sampleTimes,
                                power: preview.power, isSigned: tfTransform == .logBaseline)
            }
        }
        .font(.callout)
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Per-mode scree").font(.headline)
                HelpButton(text: "The singular spectrum of each mode (the multilinear SVD). Parallel "
                           + "analysis compares each mode against random tensors of the same shape; the "
                           + "smallest per-mode count above the noise floor is the recommended rank.")
                Spacer()
                Toggle("Parallel analysis", isOn: $parallelAnalysis).toggleStyle(.checkbox).font(.caption)
                if parallelAnalysis {
                    Stepper("reps \(parallelReps)", value: $parallelReps, in: 2...30).fixedSize().font(.caption)
                }
                Button { runDiagnostics() } label: { Label("Run Diagnostics", systemImage: "chart.dots.scatter") }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || diagRunning)
            }
            if diagRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: diagProgress.fraction)
                    Text(diagProgress.stage.isEmpty ? "Assembling tensor and computing mode spectra…" : diagProgress.stage)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let error = diagError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let modes = modeScrees {
                Text("Recommended rank: \(recommendedRank)").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                ModeScreeView(modes: modes)
            } else {
                Text("Run to see how much structure each mode carries before choosing a component count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Component count

    @ViewBuilder
    private var componentCountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Component count").font(.headline)
                HelpButton(text: """
                    Choosing the number of components, using the three tools together:

                    • Per-mode scree (above) brackets the range — parallel analysis flags components \
                    above the noise floor; treat its recommendation as a ceiling.

                    • CORCONDIA (core consistency) tells you whether the CP model is still valid: \
                    ~90–100% = clean, keep it; ~50–90% = borderline; below ~50% (or negative) = a \
                    component is breaking trilinearity — too many. Take the LARGEST rank whose \
                    CORCONDIA is still high while the fit curve has flattened.

                    • Split-half reliability confirms: components that replicate across subject halves \
                    score near 1.
                    """)
                Spacer()
                Stepper("Max rank \(sweepMaxRank)", value: $sweepMaxRank, in: 2...16).fixedSize()
                Button { runSweep() } label: { Label("Fit / CORCONDIA sweep", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(.bordered).disabled(conditionNames.isEmpty || loadedCount == 0 || sweepRunning)
                Button { runSplitHalf() } label: { Label("Split-half", systemImage: "rectangle.split.2x1") }
                    .buttonStyle(.bordered).disabled(conditionNames.isEmpty || loadedCount == 0 || splitRunning)
            }
            if sweepRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: sweepProgress.fraction)
                    Text(sweepProgress.stage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let error = diagnosticsError { Text(error).font(.caption).foregroundStyle(.red) }
            if let points = sweepPoints { RankSweepView(points: points) }
            if splitRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Decomposing subject halves at rank \(rank)…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let split = splitHalf {
                Text(String(format: "Split-half reliability (rank %d): mean congruence %.2f", rank, split.meanCongruence))
                    .font(.callout.weight(.medium))
                Text("per component: " + split.perComponent.map { String(format: "%.2f", $0) }.joined(separator: ", "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tensor model

    private var parafacSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Tensor model").font(.headline)
                HelpButton(text: "PARAFAC estimates one loading per mode. PARAFAC2 slices by subject "
                           + "and allows the time mode to vary by subject, which can capture ERP latency "
                           + "or waveform-shape differences. In PARAFAC2, non-time modes are folded into "
                           + "one feature mode and CORCONDIA is not reported.")
                Spacer()
                Picker("Algorithm", selection: $algorithm) {
                    ForEach(TensorAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .onChange(of: algorithm) { _, _ in clearModelResult() }
                Stepper("Rank \(rank)", value: $rank, in: 1...20).fixedSize()
                Stepper("Starts \(nStarts)", value: $nStarts, in: 1...50).fixedSize()
                Button { runTensorModel() } label: { Label("Run", systemImage: "cube") }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || cpRunning)
            }
            if cpRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: cpProgress.fraction)
                    Text(cpProgress.stage.isEmpty ? "Running…" : cpProgress.stage)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let error = cpError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let result = cpResult {
                CPExplorerView(
                    result: result, modeTypes: cpModeTypes, layout: groupSensorLayout,
                    timesMS: cpTimesMS, freqs: cpFreqs, conditionNames: conditionNames,
                    subjectLevels: subjectLevels(), factorNames: study.factors.map(\.name),
                    coreConsistency: cpCoreConsistency)
            } else {
                Text("Run the diagnostics first to get a recommended rank, then decompose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Export

    private func exportSection(_ result: CPResult) -> some View {
        let names = EPTensor.snapshot(datasets: members, conditionNames: conditionNames)?.subjects.map(\.name) ?? []
        let levels = subjectLevels()
        let factorNames = study.factors.map(\.name)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Export Loadings").font(.headline)
            HStack(spacing: 12) {
                if let m = cpModeTypes.firstIndex(of: .subject) {
                    Button {
                        save(CPCSVBuilders.subjectLoadings(result, subjectMode: m, subjectNames: names,
                                                           subjectLevels: levels, factorNames: factorNames),
                             name: "\(safe(title))_cp_subject_loadings")
                    } label: { Label("Subject", systemImage: "person.3") }
                        .help("One row per subject with design columns and a component per column — for ANOVA / mixed models.")
                }
                if let m = cpModeTypes.firstIndex(of: .condition) {
                    Button {
                        save(CPCSVBuilders.modeLoadings(result, mode: m, rowLabel: "Condition",
                                                        names: { $0 < conditionNames.count ? conditionNames[$0] : "c\($0 + 1)" }),
                             name: "\(safe(title))_cp_condition_loadings")
                    } label: { Label("Condition", systemImage: "square.grid.3x1.below.line.grid.1x2") }
                }
                if let m = cpModeTypes.firstIndex(of: .time) {
                    Button {
                        save(CPCSVBuilders.modeLoadings(result, mode: m, rowLabel: "Time_ms",
                                                        names: { $0 < cpTimesMS.count ? String(format: "%.0f", cpTimesMS[$0]) : "\($0)" }),
                             name: "\(safe(title))_cp_temporal_loadings")
                    } label: { Label("Temporal", systemImage: "waveform") }
                }
                if let m = cpModeTypes.firstIndex(of: .frequency) {
                    Button {
                        save(CPCSVBuilders.modeLoadings(result, mode: m, rowLabel: "Frequency_Hz",
                                                        names: { $0 < cpFreqs.count ? String(format: "%.2f", cpFreqs[$0]) : "\($0)" }),
                             name: "\(safe(title))_cp_spectral_loadings")
                    } label: { Label("Spectral", systemImage: "waveform.path") }
                }
                if let m = cpModeTypes.firstIndex(of: .channel) {
                    Button {
                        save(CPCSVBuilders.modeLoadings(result, mode: m, rowLabel: "Channel", names: { "\($0 + 1)" }),
                             name: "\(safe(title))_cp_spatial_loadings")
                    } label: { Label("Spatial", systemImage: "circle.grid.cross") }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Shared helpers

    private func subjectLevels() -> [[String]] {
        EPTensor.snapshot(datasets: members, conditionNames: conditionNames)?.subjects.map(\.levels) ?? []
    }

    private func currentTimeAxis() -> EPTensor.TimeAxis? {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else { return nil }
        let input = snapshot.input
        return EPTensor.selectTimeSamples(
            samplingRate: input.samplingRate, baselineSamples: input.baselineSamples,
            nTimes: input.nTimes, preMS: trimPre, postMS: trimPost, downsample: downsample)
    }

    private func initializeWindowIfNeeded() {
        guard !windowInitialized,
              let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else { return }
        let input = snapshot.input
        if input.samplingRate > 0 {
            trimPre = Double(-input.baselineSamples) / input.samplingRate * 1000
            trimPost = Double(input.nTimes - input.baselineSamples) / input.samplingRate * 1000
        }
        windowInitialized = true
    }

    private func tfConfig() -> TFConfig {
        TFConfig(method: tfMethod, freqMin: tfFreqMin, freqMax: tfFreqMax, nFreqs: tfNFreqs, spacing: tfSpacing,
                 cyclesMin: tfCyclesMin, cyclesMax: tfCyclesMax, windowMS: tfWindowMS, stepMS: tfStepMS)
    }

    private func tfParameters() -> TFTensorBuilder.Parameters {
        TFTensorBuilder.Parameters(
            config: tfConfig(), structure: tfStructure, transform: tfTransform, timeStride: tfTimeStride,
            windowStartMS: tfCollapseStartMS, windowEndMS: tfCollapseEndMS, bandLow: tfBandLow, bandHigh: tfBandHigh)
    }

    /// A Sendable description of the tensor to assemble + its mode metadata.
    private struct Assembly: Sendable {
        let tensor: MultiwayTensor
        let modeNames: [String]
        let modeTypes: [TFModeType]
        let freqs: [Double]
        let timesMS: [Double]
        let nonnegative: Bool
    }

    private static func assemble(source: TensorSource, input: EPTensor.Input, timeIndices: [Int]?,
                                 preprocessing: (subjects: Bool, time: Bool, channels: Bool),
                                 tfParams: TFTensorBuilder.Parameters, poolConditions: Bool,
                                 report: PCAProgressHandler? = nil) -> Assembly {
        let base: Assembly
        switch source {
        case .erp:
            let ep = EPTensor.build(from: input, timeIndices: timeIndices)
            var tensor = MultiwayTensor.erp4Way(from: ep)
            if preprocessing.subjects { tensor = tensor.centeredAcross(mode: 3) }
            if preprocessing.time { tensor = tensor.centeredAcross(mode: 1) }
            if preprocessing.channels { tensor = tensor.scaledWithin(mode: 0) }
            let indices = timeIndices ?? Array(0..<input.nTimes)
            let timesMS = indices.map { (Double($0) - Double(input.baselineSamples)) / input.samplingRate * 1000 }
            base = Assembly(tensor: tensor, modeNames: MultiwayTensor.erp4WayModeNames,
                            modeTypes: [.channel, .time, .condition, .subject],
                            freqs: [], timesMS: timesMS, nonnegative: false)
        case .timeFrequency:
            let tf = TFTensorBuilder.build(from: input, parameters: tfParams, report: report)
            base = Assembly(tensor: tf.tensor, modeNames: tf.modeNames, modeTypes: tf.modeTypes,
                            freqs: tf.freqs, timesMS: tf.timesMS, nonnegative: tf.nonnegative)
        }

        // Optionally average over conditions and drop that mode.
        guard poolConditions, let conditionMode = base.modeTypes.firstIndex(of: .condition) else { return base }
        var modeNames = base.modeNames; modeNames.remove(at: conditionMode)
        var modeTypes = base.modeTypes; modeTypes.remove(at: conditionMode)
        return Assembly(tensor: base.tensor.meanCollapsing(mode: conditionMode),
                        modeNames: modeNames, modeTypes: modeTypes,
                        freqs: base.freqs, timesMS: base.timesMS, nonnegative: base.nonnegative)
    }

    /// Gather the Sendable inputs for an off-actor assembly.
    private func assemblyInputs() -> (EPTensor.Input, [Int]?, (Bool, Bool, Bool), TFTensorBuilder.Parameters)? {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else { return nil }
        return (snapshot.input, currentTimeAxis()?.indices,
                (centerSubjects, centerTime, scaleChannels), tfParameters())
    }

    // MARK: - Runs

    private func runPreview() {
        guard let (input, _, _, params) = assemblyInputs() else { return }
        Task.detached(priority: .utility) {
            // Grand-average a representative midline channel across subjects (cell 0).
            let ch = input.nChannels / 2
            var mean = [Float](repeating: 0, count: input.nTimes)
            var n = 0
            for cells in input.subjects where !cells.isEmpty && ch < cells[0].count {
                let trace = cells[0][ch]
                guard trace.count == input.nTimes else { continue }
                for i in 0..<input.nTimes { mean[i] += trace[i] }
                n += 1
            }
            if n > 0 { for i in mean.indices { mean[i] /= Float(n) } }
            let raw = TimeFrequency.transform(signal: mean, sfreq: input.samplingRate, config: params.config)
            let mask = raw.sampleTimes.map { $0 < Double(input.baselineSamples) }
            let power = Self.applyTransform(raw.power, transform: params.transform, baselineMask: mask)
            let result = TFRepresentation(freqs: raw.freqs, sampleTimes: raw.times(input: input),
                                          power: power)
            await MainActor.run { preview = result }
        }
    }

    /// dB-vs-baseline or raw, mirroring the builder (kept here for the preview).
    private static func applyTransform(_ power: [[Double]], transform: TFTransform, baselineMask: [Bool]) -> [[Double]] {
        guard transform == .logBaseline else { return power }
        return power.map { row in
            var sum = 0.0, k = 0
            for t in row.indices where t < baselineMask.count && baselineMask[t] { sum += row[t]; k += 1 }
            let base = k > 0 ? sum / Double(k) : 0
            guard base > 0 else { return row.map { _ in 0 } }
            return row.map { 10 * Foundation.log10(max($0, 1e-20) / base) }
        }
    }

    private func runDiagnostics() {
        guard let (input, timeIndices, pre, tfP) = assemblyInputs() else {
            modeScrees = nil; diagError = "No dimension-consistent loaded data to analyze yet."; return
        }
        let reps = parallelAnalysis ? parallelReps : 0
        let src = source
        let pool = poolConditions
        let report = diagProgress.handler()
        diagProgress.reset()
        diagRunning = true; diagError = nil
        Task.detached(priority: .utility) {
            let outcome: Result<[ModeScree], Error>
            do {
                report(0.02, src == .timeFrequency ? "Assembling time-frequency tensor…" : "Assembling ERP tensor…")
                let a = Self.assemble(
                    source: src, input: input, timeIndices: timeIndices, preprocessing: pre,
                    tfParams: tfP, poolConditions: pool) { fraction, stage in
                        report(0.02 + 0.28 * fraction, stage)
                    }
                report(0.30, "Computing mode spectra…")
                outcome = .success(try MultiwayDiagnostics.perModeScree(
                    a.tensor, modeNames: a.modeNames, parallelReps: reps) { fraction, stage in
                        report(0.30 + 0.68 * fraction, stage)
                    })
            } catch { outcome = .failure(error) }
            await MainActor.run {
                diagRunning = false
                switch outcome {
                case .success(let scree):
                    modeScrees = scree
                    recommendedRank = MultiwayDiagnostics.recommendedRank(from: scree)
                    rank = recommendedRank
                case .failure(let error):
                    modeScrees = nil
                    diagError = (error as? LocalizedError)?.errorDescription ?? "Diagnostics failed: \(error)"
                }
            }
        }
    }

    private func runTensorModel() {
        guard let (input, timeIndices, pre, tfP) = assemblyInputs() else {
            cpResult = nil; cpError = "No dimension-consistent loaded data to analyze yet."; return
        }
        let options0 = PARAFAC.Options(rank: rank, nStarts: nStarts)
        let report = cpProgress.handler()
        let src = source
        let pool = poolConditions
        let model = algorithm
        cpProgress.reset(); cpRunning = true; cpError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<(CPResult, Double, [TFModeType], [Double], [Double]), Error>
            do {
                report(0.02, "Assembling tensor")
                let a = Self.assemble(source: src, input: input, timeIndices: timeIndices, preprocessing: pre, tfParams: tfP, poolConditions: pool)
                switch model {
                case .parafac:
                    var options = options0; options.nonnegative = a.nonnegative
                    let result = try await PARAFAC.decompose(a.tensor, modeNames: a.modeNames, options: options, report: report)
                    report(0.99, "Core consistency")
                    let cc = MultiwayDiagnostics.coreConsistency(tensor: a.tensor, result: result)
                    outcome = .success((result, cc, a.modeTypes, a.freqs, a.timesMS))
                case .parafac2:
                    guard let subjectMode = a.modeTypes.firstIndex(of: .subject),
                          let varyingMode = a.modeTypes.firstIndex(of: .time) ?? a.modeTypes.firstIndex(of: .frequency) else {
                        throw PARAFAC2.PARAFAC2Error.invalidModes
                    }
                    let options = PARAFAC2.Options(rank: options0.rank, nStarts: options0.nStarts, seed: options0.seed)
                    let result = try await PARAFAC2.decompose(
                        a.tensor, modeNames: a.modeNames, varyingMode: varyingMode,
                        sliceMode: subjectMode, options: options, report: report)
                    let varyingType = a.modeTypes[varyingMode]
                    let times = varyingType == .time ? a.timesMS : []
                    let freqs = varyingType == .frequency ? a.freqs : []
                    outcome = .success((result, .nan, [varyingType, .feature, .subject], freqs, times))
                }
            } catch { outcome = .failure(error) }
            await MainActor.run {
                cpRunning = false
                switch outcome {
                case .success(let (result, cc, types, freqs, times)):
                    cpResult = result; cpCoreConsistency = cc.isNaN ? nil : cc
                    cpModeTypes = types; cpFreqs = freqs; cpTimesMS = times
                case .failure(let error):
                    cpResult = nil; cpCoreConsistency = nil
                    cpError = (error as? LocalizedError)?.errorDescription ?? "Tensor model failed: \(error)"
                }
            }
        }
    }

    private func runSweep() {
        guard let (input, timeIndices, pre, tfP) = assemblyInputs() else { return }
        let maxRank = sweepMaxRank
        let report = sweepProgress.handler()
        let src = source
        let pool = poolConditions
        sweepProgress.reset(); sweepRunning = true; diagnosticsError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<[MultiwayDiagnostics.RankPoint], Error>
            do {
                let a = Self.assemble(source: src, input: input, timeIndices: timeIndices, preprocessing: pre, tfParams: tfP, poolConditions: pool)
                outcome = .success(try await MultiwayDiagnostics.rankSweep(
                    a.tensor, modeNames: a.modeNames, maxRank: maxRank, nonnegative: a.nonnegative, report: report))
            } catch { outcome = .failure(error) }
            await MainActor.run {
                sweepRunning = false
                switch outcome {
                case .success(let points): sweepPoints = points
                case .failure(let error):
                    diagnosticsError = (error as? LocalizedError)?.errorDescription ?? "Sweep failed: \(error)"
                }
            }
        }
    }

    private func runSplitHalf() {
        guard let (input, timeIndices, pre, tfP) = assemblyInputs() else { return }
        let r = rank
        let src = source
        let pool = poolConditions
        splitRunning = true; diagnosticsError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<MultiwayDiagnostics.SplitHalf, Error>
            do {
                let a = Self.assemble(source: src, input: input, timeIndices: timeIndices, preprocessing: pre, tfParams: tfP, poolConditions: pool)
                let subjectMode = a.modeTypes.firstIndex(of: .subject) ?? (a.tensor.order - 1)
                outcome = .success(try await MultiwayDiagnostics.splitHalfReliability(
                    a.tensor, subjectMode: subjectMode, modeNames: a.modeNames, rank: r, nonnegative: a.nonnegative))
            } catch { outcome = .failure(error) }
            await MainActor.run {
                splitRunning = false
                switch outcome {
                case .success(let split): splitHalf = split
                case .failure(let error):
                    diagnosticsError = (error as? LocalizedError)?.errorDescription ?? "Split-half failed: \(error)"
                }
            }
        }
    }

    // MARK: - Save

    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }

    private func safe(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? "tensor" : trimmed).replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
    }

    private func clearModelResult() {
        cpResult = nil
        cpCoreConsistency = nil
        cpError = nil
        cpModeTypes = []
        cpFreqs = []
        cpTimesMS = []
    }
}

private extension TFRepresentation {
    /// The preview's time axis in ms relative to stimulus onset.
    func times(input: EPTensor.Input) -> [Double] {
        sampleTimes.map { (($0) - Double(input.baselineSamples)) / input.samplingRate * 1000 }
    }
}
