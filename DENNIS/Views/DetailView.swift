//
//  DetailView.swift
//  DENNIS
//
//  Right-hand pane. Shows a grand-average view for a selected group, the
//  butterfly + topomap for a selected condition, or a summary for a dataset.
//  Scree and factor views will join here once the PCA engine lands.
//

import SwiftUI

struct DetailView: View {
    @Environment(Study.self) private var study
    let selection: SidebarSelection?

    @State private var mode: AppMode = .pca

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            modeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pin the mode bar to the top; without this the whole stack is
        // vertically centered when the content doesn't fill the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modeBar: some View {
        HStack {
            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .pca:
            selectionContent
        case .tensor:
            ContentUnavailableView(
                "Tensor Mode",
                systemImage: "cube.transparent",
                description: Text("Tensor-based analysis is coming soon.")
            )
        case .pls:
            ContentUnavailableView(
                "PLS Mode",
                systemImage: "arrow.triangle.branch",
                description: Text("Partial least squares analysis is coming soon.")
            )
        case .stats:
            StatisticalAnalysisView()
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case .group(let id):
            GroupDetail(groupID: id).id(id)
        case .condition(let id):
            if let (dataset, condition) = findCondition(id) {
                ConditionDetail(dataset: dataset, condition: condition).id(condition.id)
            } else { placeholder }
        case .dataset(let id):
            if let dataset = findDataset(id) {
                DatasetDetail(dataset: dataset)
            } else { placeholder }
        case .none:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "waveform",
            description: Text("Select a group, dataset, or condition from the sidebar.")
        )
    }

    private func findDataset(_ id: UUID) -> Dataset? {
        study.datasets.first { $0.id == id }
    }

    private func findCondition(_ id: UUID) -> (Dataset, Condition)? {
        for dataset in study.datasets {
            if let condition = dataset.conditions.first(where: { $0.id == id }) {
                return (dataset, condition)
            }
        }
        return nil
    }
}

// MARK: - Group detail (info + grand average)

private struct GroupDetail: View {
    @Environment(Study.self) private var study
    @Environment(AnalysisStore.self) private var analysis
    let groupID: String

    enum OverlayMode: String, CaseIterable, Identifiable {
        case single = "Single", subgroups = "Subgroups", conditions = "Conditions"
        var id: String { rawValue }
    }

    @State private var selectedCondition: String?
    @State private var showPlot = false
    @State private var overlayMode: OverlayMode = .single
    @State private var showOverlayCentroid = false
    @State private var compareTopomaps = false
    @State private var cursorSample = 0
    @State private var topomapSample = 0
    @State private var topomapUpdateTask: Task<Void, Never>?

    // Scree / parallel analysis.
    @State private var screeMode: PCAMode = .temporal
    @State private var screeAnalysis: ScreeAnalysis?
    @State private var screeError: String?
    @State private var screeRunning = false

    // Temporal PCA.
    @State private var pcaFactors = 3
    @State private var pcaRotation: PCARotation = .promax
    @State private var pcaModel: TemporalPCAResult?
    @State private var pcaError: String?
    @State private var pcaRunning = false
    @State private var pcaProgress = RunProgress()
    @State private var screeProgress = RunProgress()

    // Dual (two-step) PCA: temporal → spatial.
    @State private var dualSpatialFactors = 3
    @State private var dualSecondRotation: PCARotation = .infomax
    @State private var dualModel: TwoStepPCAResult?
    @State private var dualError: String?
    @State private var dualRunning = false
    @State private var dualProgress = RunProgress()

    // Per-subject ERP + design levels for cluster plots (built when results land).
    @State private var clusterSubjects: [ClusterSubject] = []
    @State private var clusterBaseline = 0
    @State private var clusterSamplingRate = 0.0
    @State private var spatialScree: ScreeAnalysis?
    @State private var spatialScreeError: String?
    @State private var spatialScreeRunning = false
    @State private var spatialScreeProgress = RunProgress()

    // PCA window / preprocessing (milliseconds; auto-populated from the data).
    @State private var trimPre: Double = -100
    @State private var trimPost: Double = 900
    @State private var downsampleFactor: Int = 1
    @State private var windowInitialized = false

    private var members: [Dataset] { study.datasets(inGroupID: groupID) }
    private var conditionNames: [String] { study.sharedConditionNames(inGroupID: groupID) }
    private var children: [Study.ChildGroup] { study.childGroups(ofGroupID: groupID) }
    private var title: String {
        groupID.isEmpty ? study.name : (groupID.split(separator: "/").last.map(String.init) ?? groupID)
    }
    private var loadedCount: Int { members.filter { $0.loadState == .loaded }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoGrid
                Divider()
                grandAverageSection
                Divider()
                preprocessingSection
                Divider()
                temporalRow
                Divider()
                dualPCASection
                if dualModel != nil, let bundle = analysis.dual, bundle.groupID == groupID {
                    Divider()
                    PCAExportView(bundle: bundle)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .onAppear {
            topomapSample = cursorSample
            // Switching app modes (PCA → Stats → PCA) tears down this view and
            // its @State. The completed dual result still lives in the shared
            // AnalysisStore, so restore it here when returning to the same group.
            if dualModel == nil, let bundle = analysis.dual, bundle.groupID == groupID {
                dualModel = bundle.result
            }
            if dualModel != nil && clusterSubjects.isEmpty { prepareClusterERP() }
        }
        .onDisappear {
            topomapUpdateTask?.cancel()
            topomapUpdateTask = nil
        }
        .onChange(of: cursorSample) { _, newValue in
            scheduleTopomapUpdate(sample: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if groupID.isEmpty {
                // The root group is the study itself — let the title be renamed.
                TextField("Study name", text: Binding(
                    get: { study.name },
                    set: { study.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
            } else {
                Text(title).font(.largeTitle.bold())
            }
            Text(groupID.isEmpty ? "All subjects" : groupID.replacingOccurrences(of: "/", with: " › "))
                .foregroundStyle(.secondary)
        }
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            GridRow {
                stat("Subjects", "\(members.count)")
                stat("Loaded", "\(loadedCount)/\(members.count)")
                stat("Conditions", "\(conditionNames.count)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var grandAverageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Grand Average").font(.headline)
                Spacer()
                if !showPlot {
                    Button {
                        if selectedCondition == nil { selectedCondition = conditionNames.first }
                        showPlot = true
                    } label: {
                        Label("Plot Grand Average", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0)
                }
            }

            if conditionNames.isEmpty {
                Text("No shared conditions across these subjects yet (still loading?).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if showPlot {
                Picker("Compare", selection: $overlayMode) {
                    Text("Single").tag(OverlayMode.single)
                    Text(children.isEmpty ? "Subgroups (none)" : "Subgroups").tag(OverlayMode.subgroups)
                    Text("Conditions").tag(OverlayMode.conditions)
                }
                .pickerStyle(.segmented)
                .onChange(of: overlayMode) { _, _ in cursorSample = 0 }

                // The condition picker is only relevant when not overlaying conditions.
                if overlayMode != .conditions {
                    Picker("Condition", selection: $selectedCondition) {
                        ForEach(conditionNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedCondition) { _, _ in cursorSample = 0 }
                }

                content
            }
        }
    }

    // MARK: - PCA window / preprocessing

    /// Sampling rate, baseline length, and time-point count from the first
    /// loaded, shared-condition dataset in this group.
    private var dataTimeInfo: (rate: Double, baseline: Int, nTimes: Int)? {
        for dataset in members {
            if let condition = dataset.conditions.first(where: { conditionNames.contains($0.name) }),
               let samples = condition.samples, let first = samples.first {
                return (dataset.samplingRate, condition.baselineSamples, first.count)
            }
        }
        return nil
    }

    /// A sensor layout for this group, taken from the first member that has one.
    private var groupSensorLayout: SensorLayout? {
        members.first(where: { $0.sensorLayout != nil })?.sensorLayout
    }

    /// The data's natural full window in ms, used to seed the trim boxes.
    private var naturalWindow: (preMS: Double, postMS: Double)? {
        guard let info = dataTimeInfo, info.rate > 0 else { return nil }
        let pre = Double(0 - info.baseline) / info.rate * 1000
        let post = Double(info.nTimes - 1 - info.baseline) / info.rate * 1000
        return (pre, post)
    }

    /// The time axis (retained sample indices + ms) for the current trim and
    /// downsample settings, or nil if the data timing is unknown.
    private func currentTimeAxis() -> EPTensor.TimeAxis? {
        guard let info = dataTimeInfo else { return nil }
        return EPTensor.selectTimeSamples(
            samplingRate: info.rate, baselineSamples: info.baseline, nTimes: info.nTimes,
            preMS: trimPre, postMS: trimPost, downsample: downsampleFactor
        )
    }

    private func initializeWindowIfNeeded() {
        guard !windowInitialized, let window = naturalWindow else { return }
        trimPre = (window.preMS).rounded()
        trimPost = (window.postMS).rounded()
        windowInitialized = true
    }

    @ViewBuilder
    private var preprocessingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PCA Window").font(.headline)

            if let info = dataTimeInfo, info.rate > 0 {
                let axis = currentTimeAxis()
                let effectiveRate = info.rate / Double(max(1, downsampleFactor))
                HStack(alignment: .bottom, spacing: 16) {
                    msField("Pre (ms)", value: $trimPre)
                    msField("Post (ms)", value: $trimPost)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downsample").font(.caption).foregroundStyle(.secondary)
                        Picker("Downsample", selection: $downsampleFactor) {
                            Text("None").tag(1)
                            Text("½ (2×)").tag(2)
                            Text("¼ (4×)").tag(4)
                            Text("⅛ (8×)").tag(8)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("Reset") {
                        if let w = naturalWindow {
                            trimPre = w.preMS.rounded(); trimPost = w.postMS.rounded()
                        }
                        downsampleFactor = 1
                    }
                    .buttonStyle(.bordered)
                }
                Text("\(axis?.indices.count ?? info.nTimes) time points · "
                     + String(format: "%.0f Hz effective", effectiveRate))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Load data with a known sampling rate to set the PCA window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { initializeWindowIfNeeded() }
        .onChange(of: loadedCount) { _, _ in initializeWindowIfNeeded() }
    }

    private func msField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
    }

    // MARK: - Scree / parallel analysis

    @ViewBuilder
    /// Temporal scree and temporal loadings, shown side by side.
    private var temporalRow: some View {
        HStack(alignment: .top, spacing: 20) {
            temporalScreeColumn.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            temporalLoadingsColumn.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var temporalScreeColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Temporal Scree").font(.headline)
                HelpButton(text: "Runs an unrotated PCA on the time dimension and compares its "
                           + "eigenvalues against random data of the same shape, to suggest how many "
                           + "temporal factors to retain.")
                Spacer()
                if let analysis = screeAnalysis {
                    savePNGButton("temporal_scree") { ScreePlotView(analysis: analysis) }
                }
                Button { runScree() } label: { Label("Run", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || screeRunning)
            }
            if screeRunning { progressBar(screeProgress) }
            if conditionNames.isEmpty {
                Text("No shared conditions yet.").font(.caption).foregroundStyle(.secondary)
            } else if let error = screeError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let analysis = screeAnalysis {
                ScreePlotView(analysis: analysis)
            } else {
                Text("Run to estimate the temporal factor count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var temporalLoadingsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Temporal PCA").font(.headline)
                HelpButton(text: "Runs a temporal PCA (time points as variables) and plots each "
                           + "factor's loading as a waveform. Use the scree at left to pick a factor count.")
                Spacer()
                if let model = pcaModel {
                    savePNGButton("temporal_loadings") { TemporalPCAView(model: model) }
                }
            }
            HStack {
                Stepper("Factors: \(pcaFactors)", value: $pcaFactors, in: 1...20).fixedSize()
                Picker("Rotation", selection: $pcaRotation) {
                    Text("Promax").tag(PCARotation.promax)
                    Text("Varimax").tag(PCARotation.varimax)
                    Text("Infomax").tag(PCARotation.infomax)
                    Text("Extended Infomax").tag(PCARotation.extendedInfomax)
                    Text("Unrotated").tag(PCARotation.unrotated)
                }
                .fixedSize()
                Button { runTemporalPCA() } label: { Label("Run", systemImage: "waveform.path.ecg.rectangle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || pcaRunning)
            }
            if pcaRunning { progressBar(pcaProgress) }
            if conditionNames.isEmpty {
                Text("No shared conditions yet.").font(.caption).foregroundStyle(.secondary)
            } else if let error = pcaError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let model = pcaModel {
                TemporalPCAView(model: model)
            } else {
                Text("Run to plot temporal factor loadings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runScree() {
        let mode = screeMode
        // Gather a Sendable snapshot on the main actor; the heavy tensor fill and
        // PCA run in the background.
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            screeAnalysis = nil
            screeError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let timeIndices = currentTimeAxis()?.indices
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
                screeRunning = false
                switch result {
                case .success(let analysis): screeAnalysis = analysis
                case .failure(let error):
                    screeAnalysis = nil
                    screeError = (error as? LocalizedError)?.errorDescription
                        ?? "Scree analysis failed: \(error)"
                }
            }
        }
    }

    private func savePNGButton<V: View>(_ name: String, @ViewBuilder _ view: @escaping () -> V) -> some View {
        Button {
            ImageExport.savePNG(view(), suggestedName: name)
        } label: {
            Label("Save PNG", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func progressBar(_ progress: RunProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fraction)
            Text(progress.stage.isEmpty ? "Working…" : progress.stage)
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Temporal PCA

    @ViewBuilder

    private func runTemporalPCA() {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            pcaModel = nil
            pcaError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let rotation = pcaRotation
        let requestedFactors = pcaFactors
        let axis = currentTimeAxis()
        let timeIndices = axis?.indices
        let timesMS = axis?.timesMS ?? []
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
                pcaRunning = false
                switch outcome {
                case .success(let model): pcaModel = model
                case .failure(let error):
                    pcaModel = nil
                    pcaError = (error as? LocalizedError)?.errorDescription
                        ?? "Temporal PCA failed: \(error)"
                }
            }
        }
    }

    // MARK: - Dual (two-step) PCA

    @ViewBuilder
    private var dualPCASection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Dual PCA (Temporal → Spatial)").font(.headline)
                HelpButton(text: "Runs a temporal PCA, then a spatial PCA on each temporal factor's "
                           + "scores (the ERP Toolkit dual decomposition). The first step uses the "
                           + "temporal rotation above; the second step uses the rotation here. Spatial "
                           + "factors are chosen per temporal factor — run the spatial scree to estimate "
                           + "how many to retain.")
                Spacer()
                Stepper("Spatial factors: \(dualSpatialFactors)", value: $dualSpatialFactors, in: 1...20)
                    .fixedSize()
                Picker("2nd rotation", selection: $dualSecondRotation) {
                    Text("Infomax").tag(PCARotation.infomax)
                    Text("Extended Infomax").tag(PCARotation.extendedInfomax)
                    Text("Promax").tag(PCARotation.promax)
                    Text("Varimax").tag(PCARotation.varimax)
                }
                .fixedSize()
                Button { runSpatialScree() } label: { Label("Spatial Scree", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(.bordered)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || spatialScreeRunning)
                Button { runDualPCA() } label: { Label("Run Dual PCA", systemImage: "square.stack.3d.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditionNames.isEmpty || loadedCount == 0 || dualRunning)
            }

            if spatialScreeRunning { progressBar(spatialScreeProgress) }
            if dualRunning { progressBar(dualProgress) }

            // Combined-factor variance and spatial scree, side by side.
            if dualModel != nil || spatialScree != nil || spatialScreeError != nil {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Combined factors").font(.subheadline.weight(.semibold))
                        if let model = dualModel {
                            CombinedFactorsTable(result: model)
                        } else {
                            Text("Run the dual PCA to see combined-factor variance.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Spatial scree (second step)").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let scree = spatialScree {
                                savePNGButton("spatial_scree") { ScreePlotView(analysis: scree) }
                            }
                        }
                        if let error = spatialScreeError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if let scree = spatialScree {
                            ScreePlotView(analysis: scree)
                        } else {
                            Text("Run the spatial scree to estimate spatial factors.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Temporal-spatial factor maps on their own.
            if conditionNames.isEmpty {
                Text("No shared conditions across these subjects yet (still loading?).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error = dualError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let model = dualModel {
                Divider()
                DualPCAView(result: model, sensorLayout: groupSensorLayout,
                            clusterSubjects: clusterSubjects,
                            clusterConditionNames: conditionNames,
                            clusterFactorNames: study.factors.map(\.name),
                            clusterBaseline: clusterBaseline,
                            clusterSamplingRate: clusterSamplingRate)
            }
        }
    }

    private func runSpatialScree() {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            spatialScree = nil
            spatialScreeError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let firstRotation = pcaRotation
        let firstFactors = pcaFactors
        let timeIndices = currentTimeAxis()?.indices
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
                spatialScreeRunning = false
                switch outcome {
                case .success(let analysis): spatialScree = analysis
                case .failure(let error):
                    spatialScree = nil
                    spatialScreeError = (error as? LocalizedError)?.errorDescription
                        ?? "Spatial scree failed: \(error)"
                }
            }
        }
    }

    /// Gather per-subject ERPs (channels × samples per condition) plus each
    /// subject's design levels, used by the cluster-ERP plots when a factor
    /// topography is clicked. References existing sample arrays (copy-on-write).
    private func prepareClusterERP() {
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
        clusterSubjects = out
        clusterBaseline = baseline
        clusterSamplingRate = sfreq
    }

    private func runDualPCA() {
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else {
            dualModel = nil
            dualError = "No dimension-consistent loaded data to analyze yet."
            return
        }
        let input = snapshot.input
        let subjectNames = snapshot.subjects.map(\.name)
        let conditions = conditionNames
        let layout = groupSensorLayout
        let nChannels = input.nChannels
        let label = title
        let id = groupID
        let firstRotation = pcaRotation
        let secondRotation = dualSecondRotation
        let firstFactors = pcaFactors
        let spatialFactors = dualSpatialFactors
        let axis = currentTimeAxis()
        let timeIndices = axis?.indices
        let timesMS = axis?.timesMS ?? []
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
                dualRunning = false
                switch outcome {
                case .success(let model):
                    dualModel = model
                    analysis.dual = AnalysisStore.DualBundle(
                        result: model, groupID: id, groupLabel: label,
                        conditionNames: conditions, subjectNames: subjectNames,
                        sensorLayout: layout, nChannels: nChannels
                    )
                    prepareClusterERP()
                case .failure(let error):
                    dualModel = nil
                    dualError = (error as? LocalizedError)?.errorDescription
                        ?? "Dual PCA failed: \(error)"
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch overlayMode {
        case .single:
            if let name = selectedCondition,
               let ga = GrandAverage.compute(datasets: members, condition: name) {
                grandAveragePlot(ga, condition: name)
            } else {
                unavailable("Couldn't compute a grand average for this condition.")
            }
        case .subgroups:
            if children.isEmpty {
                unavailable("This group has no sub-folders to compare. Select a parent folder, "
                            + "or use “Conditions”.")
            } else if let name = selectedCondition {
                overlayPlot(traces: subgroupTraces(condition: name),
                            caption: "\(name) · butterfly plot per sub-folder")
            }
        case .conditions:
            overlayPlot(traces: conditionTraces(),
                        caption: "Butterfly plot per condition · \(members.count) subjects")
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Overlay rendering

    @ViewBuilder
    private func overlayPlot(traces: [OverlayTrace], caption: String) -> some View {
        if traces.isEmpty {
            unavailable("Not enough loaded data to plot this comparison yet.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Toggle("Show centroid", isOn: $showOverlayCentroid)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("Compare Topomaps", isOn: $compareTopomaps)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                HStack(alignment: .top, spacing: 16) {
                    OverlayWaveformView(
                        traces: traces,
                        samplingRate: overlaySamplingRate,
                        baselineSamples: overlayBaseline,
                        showsCentroid: showOverlayCentroid,
                        cursorSample: cursorBinding(max: traces.map(\.sampleCount).max() ?? 1)
                    )
                    .frame(minHeight: 320)
                    .frame(maxWidth: .infinity)

                    overlayTopomaps(traces: traces)
                        .frame(width: compareTopomaps ? 340 : 320)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayTopomaps(traces: [OverlayTrace]) -> some View {
        let mappable = traces.filter { $0.sensorLayout != nil }
        if mappable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ContentUnavailableView("No Sensor Layout", systemImage: "circle.dashed")
            }
        } else {
            let scale = overlayTopomapScale(for: mappable)
            if compareTopomaps {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(mappable) { trace in
                            overlayTopomapCard(for: trace, scale: scale)
                        }
                    }
                }
            } else if let combined = combinedTopomapTrace(from: mappable) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    overlayTopomapCard(for: combined, scale: scale)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayTopomapCard(for trace: OverlayTrace, scale: Double) -> some View {
        if let layout = trace.sensorLayout {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Capsule().fill(trace.color).frame(width: 14, height: 3)
                    Text(trace.label).font(.caption.weight(.semibold))
                    Text("n=\(trace.contributing)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "t = %.3f s", overlaySamplingRate > 0 ? Double(topomapSample) / overlaySamplingRate : 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TopomapView(
                    layout: layout,
                    values: trace.samples.map { channel in
                        topomapSample < channel.count ? Double(channel[topomapSample]) : 0
                    },
                    timeSeconds: overlaySamplingRate > 0 ? Double(topomapSample) / overlaySamplingRate : 0,
                    fixedScale: scale,
                    showsHeader: false,
                    interpolationStep: compareTopomaps ? 6 : 7,
                    usesVerticalColorBar: true,
                    canvasMinHeight: compareTopomaps ? 190 : 230
                )
                .frame(height: compareTopomaps ? 250 : 290)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(trace.color.opacity(0.35), lineWidth: 1))
            }
        }
    }

    private func combinedTopomapTrace(from traces: [OverlayTrace]) -> OverlayTrace? {
        guard let first = traces.first else { return nil }
        let channelCount = first.samples.count
        let sampleCount = first.sampleCount
        guard channelCount > 0, sampleCount > 0 else { return nil }

        var weighted = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: channelCount
        )
        var totalWeight = 0
        for trace in traces {
            guard trace.samples.count == channelCount,
                  trace.samples.allSatisfy({ $0.count == sampleCount }) else { continue }
            let weight = max(trace.contributing, 1)
            totalWeight += weight
            for channelIndex in 0..<channelCount {
                for sampleIndex in 0..<sampleCount {
                    weighted[channelIndex][sampleIndex] += Double(trace.samples[channelIndex][sampleIndex]) * Double(weight)
                }
            }
        }
        guard totalWeight > 0 else { return nil }

        let samples = weighted.map { channel in
            channel.map { Float($0 / Double(totalWeight)) }
        }
        var centroid = [Float](repeating: 0, count: sampleCount)
        for sampleIndex in 0..<sampleCount {
            let total = samples.reduce(0.0) { partial, channel in
                partial + Double(channel[sampleIndex])
            }
            centroid[sampleIndex] = Float(total / Double(channelCount))
        }

        return OverlayTrace(
            id: "combined-topomap",
            label: "Combined",
            color: .secondary,
            samples: samples,
            centroid: centroid,
            contributing: totalWeight,
            sensorLayout: first.sensorLayout
        )
    }

    private func overlayTopomapScale(for traces: [OverlayTrace]) -> Double {
        let maxAbs = traces.reduce(0.0) { partial, trace in
            let values = trace.samples.compactMap { channel in
                topomapSample < channel.count ? Double(channel[topomapSample]) : nil
            }
            return max(partial, values.map(abs).max() ?? 0)
        }
        return maxAbs > 0 ? maxAbs : 1
    }

    private func scheduleTopomapUpdate(sample: Int) {
        topomapUpdateTask?.cancel()
        topomapUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                topomapSample = sample
            }
        }
    }

    /// One butterfly plot per immediate sub-folder, for a condition.
    private func subgroupTraces(condition name: String) -> [OverlayTrace] {
        children.enumerated().compactMap { index, child in
            guard let ga = GrandAverage.compute(datasets: child.datasets, condition: name) else { return nil }
            return OverlayTrace(
                id: child.id, label: child.label,
                color: OverlayWaveformView.palette[index % OverlayWaveformView.palette.count],
                samples: ga.samples,
                centroid: ga.centroid,
                contributing: ga.contributing,
                sensorLayout: ga.sensorLayout
            )
        }
    }

    /// One butterfly plot per condition, for this whole group.
    private func conditionTraces() -> [OverlayTrace] {
        conditionNames.enumerated().compactMap { index, name in
            guard let ga = GrandAverage.compute(datasets: members, condition: name) else { return nil }
            return OverlayTrace(
                id: name, label: name,
                color: OverlayWaveformView.palette[index % OverlayWaveformView.palette.count],
                samples: ga.samples,
                centroid: ga.centroid,
                contributing: ga.contributing,
                sensorLayout: ga.sensorLayout
            )
        }
    }

    /// Shared baseline/sfreq for overlays (taken from the first computable GA).
    private var overlayReference: GrandAverage? {
        switch overlayMode {
        case .conditions:
            return conditionNames.lazy.compactMap { GrandAverage.compute(datasets: members, condition: $0) }.first
        default:
            guard let name = selectedCondition else { return nil }
            return children.lazy.compactMap { GrandAverage.compute(datasets: $0.datasets, condition: name) }.first
                ?? GrandAverage.compute(datasets: members, condition: name)
        }
    }
    private var overlayBaseline: Int { overlayReference?.baselineSamples ?? 0 }
    private var overlaySamplingRate: Double { overlayReference?.samplingRate ?? 0 }

    private func grandAveragePlot(_ ga: GrandAverage, condition name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) · grand average of \(ga.contributing) subject\(ga.contributing == 1 ? "" : "s") "
                 + "· centroid shown bold")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                ERPWaveformView(
                    samples: ga.samples,
                    samplingRate: ga.samplingRate,
                    baselineSamples: ga.baselineSamples,
                    cursorSample: cursorBinding(max: ga.sampleCount),
                    centroid: ga.centroid
                )
                .frame(minHeight: 280)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let layout = ga.sensorLayout {
                        TopomapView(
                            layout: layout,
                            values: ga.samples.map { ch in
                                cursorSample < ch.count ? Double(ch[cursorSample]) : 0
                            },
                            timeSeconds: ga.samplingRate > 0 ? Double(cursorSample) / ga.samplingRate : 0,
                            fixedScale: nil,
                            usesVerticalColorBar: true
                        )
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                    } else {
                        ContentUnavailableView("No Sensor Layout", systemImage: "circle.dashed")
                    }
                }
                .frame(width: 300)
            }
        }
    }

    private func cursorBinding(max sampleCount: Int) -> Binding<Int> {
        Binding(
            get: { min(cursorSample, max(sampleCount - 1, 0)) },
            set: { cursorSample = $0 }
        )
    }
}

// MARK: - Condition detail (waveform + topomap)

private struct ConditionDetail: View {
    let dataset: Dataset
    let condition: Condition

    @State private var cursorSample = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let samples = condition.samples, !samples.isEmpty {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Butterfly").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ERPWaveformView(
                            samples: samples,
                            samplingRate: dataset.samplingRate,
                            baselineSamples: condition.baselineSamples,
                            cursorSample: $cursorSample
                        )
                    }
                    .frame(maxWidth: .infinity)

                    topomap(samples: samples)
                        .frame(width: 320)
                }
            } else {
                loadingPlaceholder
            }
        }
        .padding()
        .navigationTitle(condition.name)
        .onAppear { cursorSample = condition.baselineSamples }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(condition.name).font(.largeTitle.bold())
            Text("\(dataset.name) · \(condition.sampleCount) samples · \(dataset.channelCount) channels"
                 + (dataset.samplingRate > 0 ? " · \(Int(dataset.samplingRate)) Hz" : ""))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func topomap(samples: [[Float]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let layout = dataset.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: samples.map { sample in
                        cursorSample < sample.count ? Double(sample[cursorSample]) : 0
                    },
                    timeSeconds: dataset.samplingRate > 0 ? Double(cursorSample) / dataset.samplingRate : 0,
                    fixedScale: nil
                )
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml.")
                )
            }
        }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay { ProgressView("Loading signal…") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dataset detail (summary)

private struct DatasetDetail: View {
    let dataset: Dataset

    var body: some View {
        Form {
            Section("Subject") {
                LabeledContent("Name", value: dataset.name)
                LabeledContent("Source", value: dataset.sourceURL.lastPathComponent)
                LabeledContent("Channels", value: dataset.channelCount > 0 ? "\(dataset.channelCount)" : "—")
                LabeledContent("Sampling rate",
                               value: dataset.samplingRate > 0 ? "\(Int(dataset.samplingRate)) Hz" : "—")
                LabeledContent("Status", value: statusText)
            }
            if !dataset.levels.isEmpty {
                Section("Design") {
                    ForEach(Array(dataset.levels.enumerated()), id: \.offset) { _, level in
                        Text(level.isEmpty ? "—" : level)
                    }
                }
            }
            Section("Conditions") {
                ForEach(dataset.conditions) { condition in
                    LabeledContent(condition.name,
                                   value: condition.sampleCount > 0 ? "\(condition.sampleCount) samples" : "—")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dataset.name)
    }

    private var statusText: String {
        switch dataset.loadState {
        case .pending: "Pending"
        case .loading: "Loading…"
        case .loaded: "Loaded"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
