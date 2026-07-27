//
//  DecodingView.swift
//  DENNIS
//
//  First-pass condition decoding for averaged ERP data.
//

import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum DecodingViewSource: Hashable {
    case group(String)
    case derived(UUID)
}

struct DecodingView: View {
    @Environment(Study.self) private var study
    @Environment(AnalysisStore.self) private var store
    let source: DecodingViewSource

    @State private var selectedConditions = Set<String>()
    @State private var selectedTargetID = DecodingTargetOption.conditionName.id
    @State private var trimPre: Double = -100
    @State private var trimPost: Double = 900
    @State private var downsample = 2
    @State private var featureMode: DecodingFeatureMode = .wholeWindow
    @State private var slidingWindowMS: Double = 50
    @State private var slidingStepMS: Double = 25
    @State private var classifier: DecodingClassifier = .shrinkageLDA
    @State private var usesMultithreading = true
    @State private var runPermutations = false
    @State private var permutationCount = 100
    @State private var result: DecodingResult?
    @State private var windowResults: [DecodingWindowResult] = []
    @State private var temporalResult: TemporalGeneralizationResult?
    @State private var permutationResult: DecodingPermutationResult?
    @State private var isRunning = false
    @State private var progressFraction = 0.0
    @State private var progressStatus = "Idle."
    @State private var error: String?

    private var groupID: String? {
        if case .group(let id) = source { id } else { nil }
    }
    private var derivedItem: AnalysisStore.DerivedDataItem? {
        if case .derived(let id) = source { store.derivedItem(id: id) } else { nil }
    }
    private var members: [Dataset] { groupID.map { study.datasets(inGroupID: $0) } ?? [] }
    private var conditionNames: [String] { derivedItem?.conditionNames ?? groupID.map { study.sharedConditionNames(inGroupID: $0) } ?? [] }
    private var conditionMetadata: ConditionModeMetadata { derivedItem?.conditionMetadata ?? study.conditionMetadata(for: conditionNames) }
    private var factorNames: [String] { derivedItem?.factorNames ?? study.factors.map(\.name) }
    private var subjectInfos: [DecodingSubjectInfo] {
        if let item = derivedItem {
            return item.subjectNames.enumerated().map { index, name in
                DecodingSubjectInfo(name: name, levels: item.subjectLevels.indices.contains(index) ? item.subjectLevels[index] : [])
            }
        }
        return members.map { DecodingSubjectInfo(name: $0.name, levels: $0.levels) }
    }
    private var loadedCount: Int { derivedItem?.subjectNames.count ?? members.filter { $0.loadState == .loaded }.count }
    private var title: String {
        if let item = derivedItem { return item.name }
        let id = groupID ?? ""
        return id.isEmpty || id == "_all" ? "All Subjects" : id
    }

    private var loadSignature: String {
        let targets = targetOptions.map(\.id).joined(separator: ",")
        return "\(source)#\(conditionNames.joined(separator: ","))#\(targets)#\(loadedCount)#\(members.count)"
    }

    private var targetOptions: [DecodingTargetOption] {
        var options: [DecodingTargetOption] = [.conditionName]
        options += conditionMetadata.factorNames.enumerated().map { index, name in
            .conditionFactor(name: name, index: index)
        }
        options += factorNames.enumerated().map { index, name in
            .betweenFactor(name: name, index: index)
        }
        return options
    }

    private var selectedTarget: DecodingTargetOption {
        targetOptions.first { $0.id == selectedTargetID } ?? .conditionName
    }

    private var selectedConditionRequirement: Int {
        selectedTarget.kind == .betweenFactor ? 1 : 2
    }

    private var classSectionTitle: String {
        selectedTarget.kind == .betweenFactor ? "Predictor Conditions" : "Classes"
    }

    private var classSectionHelp: DecodingHelpTopic {
        selectedTarget.kind == .betweenFactor ? .predictorConditions : .classes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if sourceInput == nil || conditionNames.isEmpty {
                    ContentUnavailableView(
                        "No Decodable Data",
                        systemImage: "checkerboard.shield",
                        description: Text("Select original or derived data with at least one shared condition.")
                    )
                    .padding(.top, 60)
                } else {
                    controls
                    Divider()
                    if isRunning {
                        progressPanel
                    } else if let result {
                        results(result)
                    } else {
                        ContentUnavailableView(
                            "Ready To Decode",
                            systemImage: "brain.head.profile",
                            description: Text("Choose classes and an ERP window, then run condition decoding.")
                        )
                        .padding(.top, 40)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .task(id: loadSignature) {
            initializeConditions()
            initializeTarget()
            result = nil
        }
        .alert("Decoding Failed", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · decoding").font(.largeTitle.bold())
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        guard let input = sourceInput else {
            return "\(members.count) files · \(conditionNames.count) shared conditions · no loaded ERP tensor"
        }
        let times = currentTimeAxis(input)?.indices.count ?? input.nTimes
        let prefix = derivedItem == nil ? "" : "derived · "
        return "\(prefix)\(subjectInfos.count) subj × \(conditionNames.count) cond · \(input.nChannels) ch × \(times) time"
    }

    private var sourceInput: EPTensor.Input? {
        if let item = derivedItem { return item.input }
        guard let snapshot = EPTensor.snapshot(datasets: members, conditionNames: conditionNames) else { return nil }
        return snapshot.input
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(classSectionTitle).font(.headline)
                    helpButton(classSectionHelp)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(conditionNames, id: \.self) { condition in
                        Toggle(condition, isOn: Binding(
                            get: { selectedConditions.contains(condition) },
                            set: { enabled in
                                if enabled { selectedConditions.insert(condition) }
                                else { selectedConditions.remove(condition) }
                                result = nil
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Target", help: .target)
                    Picker("Target", selection: $selectedTargetID) {
                        ForEach(targetOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    .onChange(of: selectedTargetID) { _, _ in result = nil }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Mode", help: .mode)
                    Picker("Mode", selection: $featureMode) {
                        ForEach(DecodingFeatureMode.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 185)
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Classifier", help: .classifier)
                    Picker("Classifier", selection: $classifier) {
                        ForEach(DecodingClassifier.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("ERP window", help: .erpWindow)
                    HStack(spacing: 8) {
                        TextField("pre", value: $trimPre, format: .number)
                            .frame(width: 66)
                            .textFieldStyle(.roundedBorder)
                        Text("to").foregroundStyle(.secondary)
                        TextField("post", value: $trimPost, format: .number)
                            .frame(width: 66)
                            .textFieldStyle(.roundedBorder)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Downsample", help: .downsample)
                    Stepper("x\(downsample)", value: $downsample, in: 1...32)
                        .fixedSize()
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                if featureMode == .slidingWindow {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Sliding window", help: .slidingWindow)
                        HStack(spacing: 8) {
                            TextField("width", value: $slidingWindowMS, format: .number)
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                            Text("ms width,").foregroundStyle(.secondary)
                            TextField("step", value: $slidingStepMS, format: .number)
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                            Text("ms step").foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Workers", help: .multithread)
                    Toggle("Multithread", isOn: $usesMultithreading)
                        .toggleStyle(.checkbox)
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Inference", help: .permutation)
                    Toggle("Permutation test", isOn: $runPermutations)
                        .toggleStyle(.checkbox)
                }

                if runPermutations {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Permutations", help: .permutationCount)
                        Stepper("\(permutationCount)", value: $permutationCount, in: 10...5_000, step: 10)
                            .fixedSize()
                    }
                }

                Spacer()

                Button {
                    runDecoding()
                } label: {
                    Label("Run Decoding", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedConditions.count < selectedConditionRequirement || isRunning)
            }
        }
    }

    private func fieldLabel(_ title: String, help: DecodingHelpTopic) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            helpButton(help)
        }
    }

    private func helpButton(_ topic: DecodingHelpTopic) -> some View {
        DecodingHelpButton(topic: topic)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Running Decoding", systemImage: "waveform.path.badge.plus")
                    .font(.headline)
                Spacer()
                Text(progressFraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressFraction, total: 1)
                .progressViewStyle(.linear)
            Text(progressStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
    }

    private func results(_ result: DecodingResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 28) {
                metric("Balanced accuracy", value: result.balancedAccuracy)
                metric("Accuracy", value: result.accuracy)
                metric("Chance", value: result.chance)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Classifier")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.classifier.rawValue)
                        .font(.title3.weight(.semibold))
                }
            }

            HStack(alignment: .top, spacing: 24) {
                confusionMatrix(result)
                    .frame(minWidth: 300, alignment: .topLeading)
                predictionsTable(result)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            exportSection(result)
            if let permutationResult {
                permutationSection(permutationResult)
            }
            if !windowResults.isEmpty {
                windowCurveSection(windowResults)
                decodingButterflySection(windowResults)
            }
            if let temporalResult {
                temporalGeneralizationSection(temporalResult)
            }
        }
    }

    private func exportSection(_ result: DecodingResult) -> some View {
        HStack(spacing: 10) {
            Button {
                saveCSV(Decoding.predictionsCSV(result), name: "decoding_predictions")
            } label: {
                Label("Predictions CSV", systemImage: "square.and.arrow.down")
            }
            Button {
                saveCSV(Decoding.confusionCSV(result), name: "decoding_confusion")
            } label: {
                Label("Confusion CSV", systemImage: "square.and.arrow.down")
            }
            if !windowResults.isEmpty {
                Button {
                    saveCSV(Decoding.curveCSV(windowResults), name: "decoding_curve")
                } label: {
                    Label("Curve CSV", systemImage: "square.and.arrow.down")
                }
            }
            if let temporalResult {
                Button {
                    saveCSV(Decoding.temporalGeneralizationCSV(temporalResult), name: "temporal_generalization")
                } label: {
                    Label("Temporal Matrix CSV", systemImage: "square.and.arrow.down")
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func permutationSection(_ permutation: DecodingPermutationResult) -> some View {
        HStack(spacing: 28) {
            metric("Permutation p", value: permutation.pValue)
            metric("Observed", value: permutation.observed)
            VStack(alignment: .leading, spacing: 4) {
                Text("Null runs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(permutation.nullDistribution.count)")
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
        }
    }

    private func windowCurveSection(_ windows: [DecodingWindowResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(featureMode == .timeResolved ? "Time-Resolved Decoding" : "Sliding-Window Decoding")
                .font(.headline)
            Chart(windows) { point in
                LineMark(
                    x: .value("Time (ms)", point.centerMS),
                    y: .value("Balanced accuracy", point.balancedAccuracy)
                )
                PointMark(
                    x: .value("Time (ms)", point.centerMS),
                    y: .value("Balanced accuracy", point.balancedAccuracy)
                )
                RuleMark(y: .value("Chance", point.result.chance))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxisLabel("Time (ms)")
            .chartYAxisLabel("Balanced accuracy")
            .frame(minHeight: 240)
        }
    }

    @ViewBuilder
    private func decodingButterflySection(_ windows: [DecodingWindowResult]) -> some View {
        if let input = sourceInput {
            let samples = butterflySamples(from: input)
            if !samples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Decoding Overlay Butterfly").font(.headline)
                        Spacer()
                        HStack(spacing: 12) {
                            Label("above chance", systemImage: "square.fill")
                                .foregroundStyle(.green)
                            Label("at/below chance", systemImage: "square.fill")
                                .foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                    DecodingButterflyOverlayView(
                        samples: samples,
                        samplingRate: input.samplingRate,
                        baselineSamples: input.baselineSamples,
                        windows: windows
                    )
                    .frame(minHeight: 230)
                }
            }
        }
    }

    private func temporalGeneralizationSection(_ temporal: TemporalGeneralizationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temporal Generalization").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Text("Train \\ Test")
                            .font(.caption.weight(.semibold))
                            .frame(width: 80)
                        ForEach(Array(temporal.testTimesMS.enumerated()), id: \.offset) { _, time in
                            Text(Decoding.format(time))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 48)
                        }
                    }
                    ForEach(Array(temporal.trainTimesMS.enumerated()), id: \.offset) { row, train in
                        GridRow {
                            Text(Decoding.format(train))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 80)
                            ForEach(Array(temporal.balancedAccuracy[row].enumerated()), id: \.offset) { _, value in
                                Text(value.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: 48, height: 26)
                                    .background(temporalCellColor(value))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
        }
    }

    private func metric(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.formatted(.percent.precision(.fractionLength(1))))
                .font(.title2.monospacedDigit().weight(.semibold))
        }
    }

    private func confusionMatrix(_ result: DecodingResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confusion Matrix").font(.headline)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(result.labels, id: \.self) { label in
                        Text(label).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
                ForEach(result.labels.indices, id: \.self) { row in
                    GridRow {
                        Text(result.labels[row])
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        ForEach(result.labels.indices, id: \.self) { col in
                            Text("\(result.confusion[row][col])")
                                .font(.callout.monospacedDigit())
                                .frame(width: 44, height: 30)
                                .background(cellColor(row: row, col: col, value: result.confusion[row][col]))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private func predictionsTable(_ result: DecodingResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Held-Out Predictions").font(.headline)
            Table(result.predictions) {
                TableColumn("Fold") { prediction in
                    Text("\(prediction.fold)").monospacedDigit()
                }
                .width(48)
                TableColumn("Subject", value: \.subjectName)
                TableColumn("Actual", value: \.actual)
                TableColumn("Predicted", value: \.predicted)
                TableColumn("Result") { prediction in
                    Image(systemName: prediction.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(prediction.isCorrect ? .green : .red)
                }
                .width(54)
            }
            .frame(minHeight: 220)
        }
    }

    private func cellColor(row: Int, col: Int, value: Int) -> Color {
        if row == col { return Color.green.opacity(value > 0 ? 0.22 : 0.08) }
        return Color.red.opacity(value > 0 ? 0.18 : 0.06)
    }

    private func temporalCellColor(_ value: Double) -> Color {
        let clipped = min(1, max(0, value))
        return Color.accentColor.opacity(0.08 + clipped * 0.42)
    }

    private func initializeConditions() {
        if selectedConditions.isEmpty || !selectedConditions.isSubset(of: Set(conditionNames)) {
            selectedConditions = Set(conditionNames)
        }
    }

    private func initializeTarget() {
        guard targetOptions.contains(where: { $0.id == selectedTargetID }) else {
            selectedTargetID = DecodingTargetOption.conditionName.id
            return
        }
    }

    private func currentTimeAxis(_ input: EPTensor.Input) -> EPTensor.TimeAxis? {
        EPTensor.selectTimeSamples(
            samplingRate: input.samplingRate,
            baselineSamples: input.baselineSamples,
            nTimes: input.nTimes,
            preMS: trimPre,
            postMS: trimPost,
            downsample: downsample
        )
    }

    private func runDecoding() {
        result = nil
        windowResults = []
        temporalResult = nil
        permutationResult = nil
        progressFraction = 0
        progressStatus = "Gathering the selected group's loaded averaged ERP data and checking target labels for \(selectedTarget.title)."
        guard let input = sourceInput else {
            error = "No loaded ERP data is available for this selection."
            return
        }
        progressFraction = 0.04
        progressStatus = "Selecting ERP samples from \(trimPre.formatted()) to \(trimPost.formatted()) ms with downsample x\(downsample)."
        guard let axis = currentTimeAxis(input), !axis.indices.isEmpty else {
            error = "The selected time window contains no samples."
            return
        }
        progressFraction = 0.08
        progressStatus = "Building the decoding matrix for \(selectedTarget.title): rows are held out by subject, columns are ERP features."
        guard let dataset = makeSelectedDataset(
            input: input,
            subjects: subjectInfos,
            timeIndices: axis.indices,
            timesMS: axis.timesMS
        ) else {
            error = "Could not build a decoding dataset for \(selectedTarget.title). Check that at least two target labels are represented."
            return
        }

        isRunning = true
        progressFraction = 0.1
        progressStatus = "Prepared \(dataset.observations.count) observations across \(dataset.labels.count) target labels with \(dataset.featureCount.formatted()) features each; launching \(featureMode.rawValue.lowercased())."
        let selectedClassifier = classifier
        let mode = featureMode
        let concurrent = usesMultithreading
        let permutationsEnabled = runPermutations
        let permutations = permutationCount
        let target = selectedTarget
        let metadata = conditionMetadata
        let windowDatasets = buildWindowDatasets(
            input: input,
            subjects: subjectInfos,
            axis: axis,
            target: target,
            metadata: metadata
        )
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try runDecodingAnalysis(
                        dataset: dataset,
                        windowDatasets: windowDatasets,
                        mode: mode,
                        classifier: selectedClassifier,
                        concurrent: concurrent,
                        runPermutations: permutationsEnabled,
                        permutations: permutations
                    ) { update in
                        Task { @MainActor in
                            progressFraction = 0.1 + 0.85 * update.fraction
                            progressStatus = update.message
                        }
                    }
                }.value
                await MainActor.run {
                    progressFraction = 1
                    progressStatus = "Finished decoding: reporting held-out predictions and summary metrics."
                    result = output.whole
                    windowResults = output.windows
                    temporalResult = output.temporal
                    permutationResult = output.permutation
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    private func buildWindowDatasets(
        input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        axis: EPTensor.TimeAxis,
        target: DecodingTargetOption,
        metadata: ConditionModeMetadata
    ) -> [DecodingDataset] {
        switch featureMode {
        case .wholeWindow:
            return []
        case .timeResolved, .temporalGeneralization:
            return axis.indices.compactMap { originalIndex in
                makeSelectedDataset(
                    input: input,
                    subjects: subjects,
                    target: target,
                    metadata: metadata,
                    timeIndices: [originalIndex],
                    timesMS: fullTimesMS(input)
                )
            }
        case .slidingWindow:
            let fullTimes = fullTimesMS(input)
            let width = max(1, slidingWindowMS)
            let step = max(1, slidingStepMS)
            let start = min(trimPre, trimPost)
            let end = max(trimPre, trimPost)
            var windows: [DecodingDataset] = []
            var center = start + width / 2
            while center <= end - width / 2 + 1e-6 {
                let lo = center - width / 2
                let hi = center + width / 2
                let indices = axis.indices.filter { index in
                    index < fullTimes.count && fullTimes[index] >= lo && fullTimes[index] <= hi
                }
                if !indices.isEmpty,
                   let dataset = makeSelectedDataset(
                    input: input,
                    subjects: subjects,
                    target: target,
                    metadata: metadata,
                    timeIndices: indices,
                    timesMS: fullTimes
                   ) {
                    windows.append(dataset)
                }
                center += step
            }
            return windows
        }
    }

    private func makeSelectedDataset(
        input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        timeIndices: [Int],
        timesMS: [Double]?
    ) -> DecodingDataset? {
        makeSelectedDataset(
            input: input,
            subjects: subjects,
            target: selectedTarget,
            metadata: conditionMetadata,
            timeIndices: timeIndices,
            timesMS: timesMS
        )
    }

    private func makeSelectedDataset(
        input: EPTensor.Input,
        subjects: [DecodingSubjectInfo],
        target: DecodingTargetOption,
        metadata: ConditionModeMetadata,
        timeIndices: [Int],
        timesMS: [Double]?
    ) -> DecodingDataset? {
        switch target.kind {
        case .conditionName:
            return Decoding.makeConditionDataset(
                from: input,
                subjects: subjects,
                conditionNames: conditionNames,
                selectedConditions: selectedConditions,
                timeIndices: timeIndices,
                timesMS: timesMS
            )
        case .conditionFactor:
            guard let factorIndex = target.factorIndex else { return nil }
            return Decoding.makeConditionFactorDataset(
                from: input,
                subjects: subjects,
                conditionNames: conditionNames,
                conditionMetadata: metadata,
                factorIndex: factorIndex,
                selectedConditions: selectedConditions,
                timeIndices: timeIndices,
                timesMS: timesMS
            )
        case .betweenFactor:
            guard let factorIndex = target.factorIndex else { return nil }
            return Decoding.makeBetweenSubjectDataset(
                from: input,
                subjects: subjects,
                conditionNames: conditionNames,
                selectedConditions: selectedConditions,
                factorIndex: factorIndex,
                timeIndices: timeIndices,
                timesMS: timesMS
            )
        }
    }

    private func butterflySamples(from input: EPTensor.Input) -> [[Float]] {
        guard input.nChannels > 0, input.nTimes > 0 else { return [] }
        let selectedIndices = conditionNames.indices.filter { selectedConditions.contains(conditionNames[$0]) }
        guard !selectedIndices.isEmpty else { return [] }
        var sums = Array(repeating: Array(repeating: 0.0, count: input.nTimes), count: input.nChannels)
        var count = 0

        for subject in input.subjects {
            for conditionIndex in selectedIndices where conditionIndex < subject.count {
                let samples = subject[conditionIndex]
                guard samples.count == input.nChannels else { continue }
                for channelIndex in 0..<input.nChannels where samples[channelIndex].count == input.nTimes {
                    for timeIndex in 0..<input.nTimes {
                        sums[channelIndex][timeIndex] += Double(samples[channelIndex][timeIndex])
                    }
                }
                count += 1
            }
        }

        guard count > 0 else { return [] }
        let scale = 1.0 / Double(count)
        return sums.map { channel in channel.map { Float($0 * scale) } }
    }

    private func fullTimesMS(_ input: EPTensor.Input) -> [Double] {
        (0..<input.nTimes).map { index in
            input.samplingRate > 0 ? Double(index - input.baselineSamples) / input.samplingRate * 1000 : Double(index)
        }
    }

    private func saveCSV(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(name).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.error = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    DecodingView(source: .group(""))
        .environment(Study())
        .environment(AnalysisStore())
}

nonisolated private enum DecodingTargetKind: String, Sendable {
    case conditionName
    case conditionFactor
    case betweenFactor
}

nonisolated private struct DecodingTargetOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: DecodingTargetKind
    let factorIndex: Int?

    static let conditionName = DecodingTargetOption(
        id: "condition-name",
        title: "Condition name",
        kind: .conditionName,
        factorIndex: nil
    )

    static func conditionFactor(name: String, index: Int) -> DecodingTargetOption {
        DecodingTargetOption(
            id: "condition-factor-\(index)",
            title: "Condition: \(name)",
            kind: .conditionFactor,
            factorIndex: index
        )
    }

    static func betweenFactor(name: String, index: Int) -> DecodingTargetOption {
        DecodingTargetOption(
            id: "between-factor-\(index)",
            title: "Subject: \(name)",
            kind: .betweenFactor,
            factorIndex: index
        )
    }
}

private enum DecodingHelpTopic: String, Identifiable {
    case target
    case classes
    case predictorConditions
    case mode
    case classifier
    case erpWindow
    case downsample
    case slidingWindow
    case multithread
    case permutation
    case permutationCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .target: "Prediction Target"
        case .classes: "Classes"
        case .predictorConditions: "Predictor Conditions"
        case .mode: "Feature Mode"
        case .classifier: "Classifier"
        case .erpWindow: "ERP Window"
        case .downsample: "Downsample"
        case .slidingWindow: "Sliding Window"
        case .multithread: "Workers"
        case .permutation: "Permutation Test"
        case .permutationCount: "Permutation Count"
        }
    }

    var message: String {
        switch self {
        case .target:
            "Choose what DENNIS should predict. Condition name decodes ERP condition labels. Condition targets decode within-subject condition metadata. Subject targets decode between-subject design-factor levels from each subject's ERP pattern."
        case .classes:
            "Select the condition cells included as target classes. Leave-one-subject-out validation holds out every selected condition for one subject at a time."
        case .predictorConditions:
            "Select which condition ERPs should be used as predictors for a subject-level target. DENNIS concatenates these condition patterns into one feature row per subject."
        case .mode:
            "Choose how ERP samples become features: one whole window, one model per time point, sliding windows, or train-time by test-time temporal generalization."
        case .classifier:
            "Shrinkage LDA is the default for high-dimensional ERP data. Nearest centroid is simpler and useful as a transparent baseline."
        case .erpWindow:
            "Set the time range, in milliseconds relative to stimulus onset, used to extract ERP features."
        case .downsample:
            "Use every Nth sample in the selected window. Higher values reduce feature count and speed up decoding."
        case .slidingWindow:
            "Set the width and step of moving time windows. Each window is decoded separately to estimate when information is available."
        case .multithread:
            "Run independent folds, windows, permutations, or temporal-generalization cells in parallel. DENNIS caps workers at N-1 active processors so the system keeps one processor free."
        case .permutation:
            "Shuffle target labels and rerun decoding to estimate how often chance labelings reach the observed balanced accuracy."
        case .permutationCount:
            "More permutations give a more stable p-value but take longer. The smallest possible p-value is 1 divided by permutations plus 1."
        }
    }
}

private struct DecodingHelpButton: View {
    let topic: DecodingHelpTopic
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(topic.title)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.title)
                        .font(.headline)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
                }
                Text(topic.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}

private struct DecodingButterflyOverlayView: View {
    let samples: [[Float]]
    let samplingRate: Double
    let baselineSamples: Int
    let windows: [DecodingWindowResult]

    private var sampleCount: Int { samples.first?.count ?? 0 }
    private var amplitudeBound: Double {
        let maxAbs = samples.flatMap { $0 }.map { Double(abs($0)) }.max() ?? 0
        return maxAbs > 0 ? maxAbs : 1
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas(rendersAsynchronously: true) { context, size in
                draw(in: &context, size: size)
            }
            .overlay(alignment: .topTrailing) {
                Text(String(format: "±%.1f µV", amplitudeBound))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                HStack {
                    Text(timeLabel(forSample: 0))
                    Spacer()
                    Text(timeLabel(forSample: max(0, sampleCount - 1)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .frame(width: proxy.size.width)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard sampleCount > 1, size.width > 0, size.height > 0 else { return }
        let plotRect = CGRect(x: 0, y: 8, width: size.width, height: max(1, size.height - 26))
        drawDecodingBands(in: &context, rect: plotRect)

        let midY = plotRect.midY
        let yScale = (plotRect.height / 2 - 6) / amplitudeBound
        let xScale = plotRect.width / CGFloat(sampleCount - 1)

        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: plotRect.minX, y: midY))
        zeroLine.addLine(to: CGPoint(x: plotRect.maxX, y: midY))
        context.stroke(zeroLine, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)

        if baselineSamples > 0, baselineSamples < sampleCount {
            let zeroX = plotRect.minX + CGFloat(baselineSamples) * xScale
            var onset = Path()
            onset.move(to: CGPoint(x: zeroX, y: plotRect.minY))
            onset.addLine(to: CGPoint(x: zeroX, y: plotRect.maxY))
            context.stroke(onset, with: .color(.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        for channel in samples where channel.count == sampleCount {
            context.stroke(
                path(for: channel, midY: midY, xScale: xScale, yScale: yScale, xOffset: plotRect.minX),
                with: .color(.primary.opacity(0.28)),
                lineWidth: 0.65
            )
        }
    }

    private func drawDecodingBands(in context: inout GraphicsContext, rect: CGRect) {
        let sorted = windows.sorted { $0.centerMS < $1.centerMS }
        guard !sorted.isEmpty else { return }
        for (index, window) in sorted.enumerated() {
            let interval = bandInterval(for: index, windows: sorted)
            let x0 = xPosition(forMS: interval.start, width: rect.width) + rect.minX
            let x1 = xPosition(forMS: interval.end, width: rect.width) + rect.minX
            let band = CGRect(
                x: min(x0, x1),
                y: rect.minY,
                width: max(1, abs(x1 - x0)),
                height: rect.height
            )
            let succeeds = window.balancedAccuracy > window.result.chance
            context.fill(
                Path(band),
                with: .color((succeeds ? Color.green : Color.red).opacity(0.32))
            )
        }
    }

    private func bandInterval(for index: Int, windows: [DecodingWindowResult]) -> (start: Double, end: Double) {
        let window = windows[index]
        if window.endMS > window.startMS {
            return (window.startMS, window.endMS)
        }
        let previousGap = index > 0 ? abs(window.centerMS - windows[index - 1].centerMS) : nil
        let nextGap = index + 1 < windows.count ? abs(windows[index + 1].centerMS - window.centerMS) : nil
        let sampleGap = samplingRate > 0 ? 1000 / samplingRate : 1
        let width = max(1, min(previousGap ?? nextGap ?? sampleGap, nextGap ?? previousGap ?? sampleGap))
        return (window.centerMS - width / 2, window.centerMS + width / 2)
    }

    private func path(for channel: [Float], midY: CGFloat, xScale: CGFloat, yScale: Double, xOffset: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: xOffset, y: midY - CGFloat(channel[0]) * yScale))
        for index in 1..<channel.count {
            path.addLine(to: CGPoint(
                x: xOffset + CGFloat(index) * xScale,
                y: midY - CGFloat(channel[index]) * yScale
            ))
        }
        return path
    }

    private func xPosition(forMS ms: Double, width: CGFloat) -> CGFloat {
        guard sampleCount > 1 else { return 0 }
        let sample = Double(baselineSamples) + ms / 1000 * samplingRate
        let clipped = min(Double(sampleCount - 1), max(0, sample))
        return CGFloat(clipped / Double(sampleCount - 1)) * width
    }

    private func timeLabel(forSample sample: Int) -> String {
        guard samplingRate > 0 else { return "\(sample)" }
        let ms = Double(sample - baselineSamples) / samplingRate * 1000
        return String(format: "%.0f ms", ms)
    }
}

nonisolated private struct DecodingAnalysisOutput: Sendable {
    let whole: DecodingResult
    let windows: [DecodingWindowResult]
    let temporal: TemporalGeneralizationResult?
    let permutation: DecodingPermutationResult?
}

nonisolated private func runDecodingAnalysis(
    dataset: DecodingDataset,
    windowDatasets: [DecodingDataset],
    mode: DecodingFeatureMode,
    classifier: DecodingClassifier,
    concurrent: Bool,
    runPermutations: Bool,
    permutations: Int,
    progress: @escaping @Sendable (DecodingProgress) -> Void
) throws -> DecodingAnalysisOutput {
    switch mode {
    case .wholeWindow:
        let whole = try Decoding.leaveOneSubjectOut(dataset, classifier: classifier, concurrent: concurrent, progress: progress)
        let permutation = runPermutations
            ? try Decoding.permutationTest(dataset: dataset, classifier: classifier, observed: whole, permutations: permutations, concurrent: concurrent, progress: progress)
            : nil
        return DecodingAnalysisOutput(whole: whole, windows: [], temporal: nil, permutation: permutation)

    case .timeResolved, .slidingWindow:
        let windows = try Decoding.timeResolved(datasets: windowDatasets, classifier: classifier, concurrent: concurrent, progress: progress)
        let best: DecodingResult
        if let windowBest = windows.max(by: { $0.balancedAccuracy < $1.balancedAccuracy })?.result {
            best = windowBest
        } else {
            best = try Decoding.leaveOneSubjectOut(dataset, classifier: classifier, concurrent: concurrent, progress: progress)
        }
        let permutation = runPermutations
            ? try Decoding.permutationTest(dataset: dataset, classifier: classifier, observed: best, permutations: permutations, concurrent: concurrent, progress: progress)
            : nil
        return DecodingAnalysisOutput(whole: best, windows: windows, temporal: nil, permutation: permutation)

    case .temporalGeneralization:
        let temporal = try Decoding.temporalGeneralization(datasets: windowDatasets, classifier: classifier, concurrent: concurrent, progress: progress)
        let diagonalWindows = try Decoding.timeResolved(datasets: windowDatasets, classifier: classifier, concurrent: concurrent, progress: progress)
        let best: DecodingResult
        if let windowBest = diagonalWindows.max(by: { $0.balancedAccuracy < $1.balancedAccuracy })?.result {
            best = windowBest
        } else {
            best = try Decoding.leaveOneSubjectOut(dataset, classifier: classifier, concurrent: concurrent, progress: progress)
        }
        let permutation = runPermutations
            ? try Decoding.permutationTest(dataset: dataset, classifier: classifier, observed: best, permutations: permutations, concurrent: concurrent, progress: progress)
            : nil
        return DecodingAnalysisOutput(whole: best, windows: diagonalWindows, temporal: temporal, permutation: permutation)
    }
}
