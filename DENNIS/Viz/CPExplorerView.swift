//
//  CPExplorerView.swift
//  DENNIS
//
//  Mode-aware component explorer for a PARAFAC (CP) decomposition. Each mode is
//  rendered by its type — channels as a scalp topography, time/frequency as a
//  line, condition as bars, subject as bars grouped by the between-subject design
//  — so it serves the ERP 4-way tensor and every time-frequency structure alike.
//

import SwiftUI
import Charts

nonisolated struct CPObservedContext: Sendable {
    let subjects: [ClusterSubject]
    let baselineSamples: Int
    let samplingRate: Double
}

nonisolated struct CPTensorDecodingRequest: Sendable {
    let selectedComponent: Int
    let componentScope: AnalysisStore.TensorComponentScope
    let output: AnalysisStore.DerivedReconstructionOutput
    let positiveChannels: [Int]
    let negativeChannels: [Int]
    let loadingThreshold: Double
}

struct CPExplorerView: View {
    let result: CPResult
    let modeTypes: [TFModeType]
    let layout: SensorLayout?
    let timesMS: [Double]
    let freqs: [Double]
    let conditionNames: [String]
    /// Between-subject factor levels per subject, aligned with the subject mode.
    let subjectLevels: [[String]]
    let factorNames: [String]
    let conditionMetadata: ConditionModeMetadata
    var coreConsistency: Double? = nil
    var observedContext: CPObservedContext? = nil
    var onSendToDecoding: ((CPTensorDecodingRequest) -> Void)? = nil

    @State private var groupBy = "Subject"
    @State private var selectedComponent = 0
    @State private var selectedCondition = 0
    @State private var selectedFrequency = 0
    @State private var selectedFixedTime = 0
    @State private var selectedChannel = 0
    @State private var reconstructionCursor = 0
    @State private var subjectScaleGrouping = "Subject"
    @State private var selectedSubjectGroupLevel = ""
    @State private var subjectReference: SubjectReference = .typicalAbs
    @State private var conditionScaleGrouping = "Condition"
    @State private var selectedConditionGroupLevel = ""
    @State private var spatialFootprintFraction = 0.55
    @State private var traceFootprintFraction = 0.55
    @State private var observedGroupBy: Set<String> = [Self.conditionDimension]
    @State private var showObservedSE = false
    @State private var observedCursorSample = 0
    @State private var observedPosTraces: [OverlayTrace] = []
    @State private var observedNegTraces: [OverlayTrace] = []
    @State private var observedCellOrder: [String] = []
    @State private var observedRebuilding = false
    @State private var observedRebuildGeneration = 0
    @State private var observedRebuildTask: Task<Void, Never>?
    @State private var showingSendOptions = false
    @State private var sendComponentScope: AnalysisStore.TensorComponentScope = .selected
    @State private var sendOutput: AnalysisStore.DerivedReconstructionOutput = .clusterAverages

    private static let conditionDimension = "Condition"

    private var channelMode: Int? { modeTypes.firstIndex(of: .channel) }
    private var subjectMode: Int? { modeTypes.firstIndex(of: .subject) }
    private var conditionMode: Int? { modeTypes.firstIndex(of: .condition) }
    private var timeMode: Int? { modeTypes.firstIndex(of: .time) }
    private var frequencyMode: Int? { modeTypes.firstIndex(of: .frequency) }
    private var traceMode: Int? { timeMode ?? frequencyMode }
    private var middleModes: [Int] {
        modeTypes.indices.filter { modeTypes[$0] != .channel && modeTypes[$0] != .subject }
    }
    private var hasFootprintControls: Bool {
        channelMode != nil || traceMode != nil
    }
    private var observedDimensions: [String] {
        [Self.conditionDimension] + factorNames
    }
    private var groupingOptions: [String] {
        var options = ["Subject"] + factorNames
        if factorNames.count > 1 {
            for i in 0..<(factorNames.count - 1) {
                for j in (i + 1)..<factorNames.count {
                    options.append(interactionName(factorNames[i], factorNames[j]))
                }
            }
        }
        return options
    }
    private var conditionScaleOptions: [String] {
        ["Condition"] + conditionGroupingOptions
    }
    private var conditionGroupingOptions: [String] {
        var options = conditionMetadata.factorNames
        if conditionMetadata.factorNames.count > 1 {
            for i in 0..<(conditionMetadata.factorNames.count - 1) {
                for j in (i + 1)..<conditionMetadata.factorNames.count {
                    options.append(interactionName(conditionMetadata.factorNames[i], conditionMetadata.factorNames[j]))
                }
            }
        }
        return options
    }
    private var selectedR: Int { clamped(selectedComponent, upperBound: result.rank - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "Fit %.1f%% · %d iterations · %d/%d starts at best · max congruence %.2f",
                        result.fit * 100, result.iterations, result.bestStartCount, result.nStarts,
                        result.maxCongruence)
                 + (coreConsistency.map { String(format: " · core consistency %.0f%%", $0) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if result.maxCongruence > 0.85 {
                Label("Components are nearly collinear — the solution may be degenerate. Try fewer components.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if subjectMode != nil && !factorNames.isEmpty {
                Picker("Group subjects by", selection: $groupBy) {
                    ForEach(groupingOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            if hasFootprintControls {
                loadingFootprintPanel
            }
            if channelMode != nil && traceMode != nil {
                reconstructionPanel
            }
            ForEach(0..<result.rank, id: \.self) { card($0) }
        }
        .onAppear {
            if observedCursorSample == 0 { observedCursorSample = observedContext?.baselineSamples ?? 0 }
            rebuildObservedFootprint()
        }
        .onChange(of: selectedComponent) { _, _ in rebuildObservedFootprint() }
        .onChange(of: spatialFootprintFraction) { _, _ in rebuildObservedFootprint() }
        .onChange(of: observedGroupBy) { _, _ in rebuildObservedFootprint() }
        .onChange(of: subjectScaleGrouping) { _, _ in selectedSubjectGroupLevel = "" }
        .onChange(of: conditionScaleGrouping) { _, _ in selectedConditionGroupLevel = "" }
        .onDisappear {
            observedRebuildTask?.cancel()
            observedRebuildTask = nil
        }
    }

    private func card(_ r: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Component \(r + 1)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f%% · λ=%.3g", result.componentShare[r] * 100, result.weights[r]))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                if let cm = channelMode { topography(mode: cm, r).frame(width: 190) }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(middleModes, id: \.self) { modeChart(mode: $0, r) }
                }
                .frame(maxWidth: .infinity)
            }
            if let sm = subjectMode { subjectLoadings(mode: sm, r) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(r == selectedR ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedComponent = r }
    }

    @ViewBuilder
    private func topography(mode: Int, _ r: Int) -> some View {
        VStack(spacing: 4) {
            Text("Topography").font(.caption2).foregroundStyle(.secondary)
            if let layout {
                let threshold = mode == channelMode ? channelThresholdValue(component: r) : nil
                TopomapView(layout: layout, values: result.factors[mode].column(r),
                            timeSeconds: 0, fixedScale: nil, showsHeader: false, canvasMinHeight: 150,
                            highlightThreshold: threshold)
                    .frame(height: 175)
                if mode == channelMode {
                    Text(channelFootprintLabel(component: r))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            } else {
                ContentUnavailableView("No layout", systemImage: "circle.dashed").font(.caption)
            }
        }
    }

    private struct AxisPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }
    private struct NamedLoad: Identifiable { let id = UUID(); let name: String; let value: Double }
    private struct ReconstructionPoint: Identifiable { let id: Int; let x: Double; let y: Double }
    private struct RangeBand: Identifiable { let id = UUID(); let lower: Double; let upper: Double }

    private enum SubjectReference: String, CaseIterable, Identifiable {
        case typicalAbs = "Typical |subject|"
        case unit = "Pattern"
        case mean = "Mean subject"
        case maxPositive = "Strongest +"
        case maxNegative = "Strongest -"
        var id: String { rawValue }
    }

    // MARK: - Loading footprint

    private var loadingFootprintPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Loading footprint").font(.headline)
                Picker("Component", selection: $selectedComponent) {
                    ForEach(0..<result.rank, id: \.self) { Text("C\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if channelMode != nil {
                    footprintSlider(
                        "Channels",
                        value: $spatialFootprintFraction,
                        threshold: channelThresholdValue(component: selectedR),
                        summary: channelFootprintLabel(component: selectedR)
                    )
                    .frame(width: 250)
                }
                if let tm = traceMode {
                    footprintSlider(
                        traceThresholdLabel(mode: tm),
                        value: $traceFootprintFraction,
                        threshold: traceThresholdValue(component: selectedR, mode: tm),
                        summary: traceFootprintLabel(component: selectedR, mode: tm)
                    )
                    .frame(width: 250)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 18) {
                if channelMode != nil {
                    footprintTopomap
                        .frame(width: 245)
                }
                if traceMode != nil {
                    footprintTraceChart
                        .frame(maxWidth: .infinity)
                }
            }
            observedFootprintSection
        }
        .padding(12)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func footprintSlider(_ title: String, value: Binding<Double>,
                                 threshold: Double, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.05)
            HStack {
                Text(String(format: "|loading| ≥ %.3f", threshold))
                Spacer()
                Text(summary)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var footprintTopomap: some View {
        if let cm = channelMode {
            VStack(spacing: 4) {
                Text("Channel loading topomap").font(.caption2).foregroundStyle(.secondary)
                if let layout {
                    TopomapView(
                        layout: layout,
                        values: result.factors[cm].column(selectedR),
                        timeSeconds: 0,
                        fixedScale: nil,
                        showsHeader: false,
                        canvasMinHeight: 185,
                        highlightThreshold: channelThresholdValue(component: selectedR)
                    )
                    .frame(height: 210)
                } else {
                    ContentUnavailableView("No layout", systemImage: "circle.dashed").font(.caption)
                        .frame(height: 210)
                }
            }
        }
    }

    @ViewBuilder
    private var footprintTraceChart: some View {
        if let tm = traceMode {
            let values = result.factors[tm].column(selectedR)
            let threshold = traceThresholdValue(component: selectedR, mode: tm)
            let bands = loadingRanges(mode: tm, component: selectedR, threshold: threshold)
            let points = axisPoints(values: values, mode: tm)
            let yDomain = symmetricDomain(values)
            let xLabel = traceThresholdLabel(mode: tm)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(xLabel) loading").font(.caption2).foregroundStyle(.secondary)
                Chart {
                    ForEach(bands) { band in
                        RectangleMark(
                            xStart: .value(xLabel, band.lower),
                            xEnd: .value(xLabel, band.upper),
                            yStart: .value("Lower", yDomain.lowerBound),
                            yEnd: .value("Upper", yDomain.upperBound)
                        )
                        .foregroundStyle(Color.yellow.opacity(0.16))
                    }
                    RuleMark(y: .value("Threshold", threshold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                    RuleMark(y: .value("Threshold", -threshold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                    ForEach(points) { p in
                        LineMark(x: .value(xLabel, p.x), y: .value("Loading", p.y))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXAxisLabel(axisLabel(mode: tm))
                .frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private var observedFootprintSection: some View {
        if let context = observedContext, channelMode != nil, timeMode != nil {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Observed ERP footprint").font(.subheadline.weight(.semibold))
                    Toggle("± Std. error", isOn: $showObservedSE)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    observedGroupSelector
                    Spacer()
                }
                observedPlot(
                    title: "Positive channels",
                    channels: positiveFootprintChannels(component: selectedR),
                    sign: "+",
                    traces: observedPosTraces,
                    context: context
                )
                observedPlot(
                    title: "Negative channels",
                    channels: negativeFootprintChannels(component: selectedR),
                    sign: "-",
                    traces: observedNegTraces,
                    context: context
                )
            }
        }
    }

    private var observedGroupSelector: some View {
        HStack(spacing: 8) {
            Text("Group by:").font(.caption).foregroundStyle(.secondary)
            ForEach(observedDimensions, id: \.self) { dim in
                let on = observedGroupBy.contains(dim)
                Button {
                    if on { observedGroupBy.remove(dim) } else { observedGroupBy.insert(dim) }
                } label: {
                    Text(dim)
                        .font(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.18)
                                                       : Color.secondary.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func observedPlot(title: String, channels: [Int], sign: String,
                              traces: [OverlayTrace], context: CPObservedContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(channels.count) ch \(sign)\(String(format: "%.3f", channelThresholdValue(component: selectedR)))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if channels.isEmpty {
                Text("No channels at the current threshold.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: 150, alignment: .center)
            } else if observedRebuilding {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 150, alignment: .center)
            } else if traces.isEmpty {
                Text("No observed traces for this footprint.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: 150, alignment: .center)
            } else {
                OverlayWaveformView(
                    traces: traces,
                    samplingRate: context.samplingRate,
                    baselineSamples: context.baselineSamples,
                    showsCentroid: true,
                    cursorSample: $observedCursorSample,
                    showsStandardError: showObservedSE,
                    shadedMSRanges: temporalFootprintRanges(component: selectedR)
                )
                .frame(height: 180)
            }
        }
    }

    // MARK: - Component reconstruction

    private var reconstructionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Component reconstruction").font(.headline)
                Picker("Component", selection: $selectedComponent) {
                    ForEach(0..<result.rank, id: \.self) { Text("C\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if let mode = conditionMode {
                    conditionScaleControls(mode: mode)
                }
                if let mode = frequencyMode, mode != traceMode {
                    pickerForFrequency(mode: mode)
                }
                if let mode = timeMode, mode != traceMode {
                    pickerForFixedTime(mode: mode)
                }
                if subjectMode != nil {
                    subjectScaleControls
                }
                Spacer()
                if onSendToDecoding != nil {
                    Button {
                        showingSendOptions = true
                    } label: {
                        Label("Send to Decoding", systemImage: "checkerboard.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .popover(isPresented: $showingSendOptions, arrowEdge: .top) {
                        sendOptionsPopover
                    }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                reconstructionTopomap
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 8) {
                    channelControl
                    traceChart
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sendOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Derived Dataset")
                .font(.headline)
            Text("Component \(selectedR + 1)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Picker("Components", selection: $sendComponentScope) {
                Text("Selected").tag(AnalysisStore.TensorComponentScope.selected)
                Text("All retained").tag(AnalysisStore.TensorComponentScope.retained)
            }
            .pickerStyle(.segmented)

            Picker("Electrodes", selection: $sendOutput) {
                Text("Separate").tag(AnalysisStore.DerivedReconstructionOutput.includedChannels)
                Text("+ / - averages").tag(AnalysisStore.DerivedReconstructionOutput.clusterAverages)
            }
            .pickerStyle(.segmented)

            Button {
                let request = CPTensorDecodingRequest(
                    selectedComponent: selectedR,
                    componentScope: sendComponentScope,
                    output: sendOutput,
                    positiveChannels: positiveFootprintChannels(component: selectedR),
                    negativeChannels: negativeFootprintChannels(component: selectedR),
                    loadingThreshold: channelThresholdValue(component: selectedR)
                )
                showingSendOptions = false
                onSendToDecoding?(request)
            } label: {
                Label("Create and Open in Decoding", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sendOutput == .clusterAverages
                      && positiveFootprintChannels(component: selectedR).isEmpty
                      && negativeFootprintChannels(component: selectedR).isEmpty)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func conditionScaleControls(mode: Int) -> some View {
        Group {
            if conditionGroupingOptions.isEmpty {
                pickerForCondition(mode: mode)
            } else {
                Picker("Condition scale", selection: $conditionScaleGrouping) {
                    ForEach(conditionScaleOptions, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                if conditionScaleGrouping == "Condition" {
                    pickerForCondition(mode: mode)
                } else {
                    Picker("Level", selection: conditionLevelBinding(grouping: conditionScaleGrouping)) {
                        ForEach(conditionGroupLevels(for: conditionScaleGrouping), id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var subjectScaleControls: some View {
        Group {
            if factorNames.isEmpty {
                Picker("Subject scale", selection: $subjectReference) {
                    ForEach(SubjectReference.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            } else {
                Picker("Subject scale", selection: $subjectScaleGrouping) {
                    ForEach(groupingOptions, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                if subjectScaleGrouping == "Subject" {
                    Picker("Reference", selection: $subjectReference) {
                        ForEach(SubjectReference.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                } else {
                    Picker("Level", selection: subjectLevelBinding(grouping: subjectScaleGrouping)) {
                        ForEach(subjectGroupLevels(for: subjectScaleGrouping), id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func pickerForCondition(mode: Int) -> some View {
        let rows = max(result.factors[mode].rows, 1)
        return Picker("Condition", selection: $selectedCondition) {
            ForEach(0..<rows, id: \.self) { index in
                Text(index < conditionNames.count ? conditionNames[index] : "c\(index + 1)").tag(index)
            }
        }
        .fixedSize()
    }

    private func pickerForFrequency(mode: Int) -> some View {
        let rows = max(result.factors[mode].rows, 1)
        return Picker("Frequency", selection: $selectedFrequency) {
            ForEach(0..<rows, id: \.self) { index in
                Text(index < freqs.count ? String(format: "%.1f Hz", freqs[index]) : "f\(index + 1)").tag(index)
            }
        }
        .fixedSize()
    }

    private func pickerForFixedTime(mode: Int) -> some View {
        let rows = max(result.factors[mode].rows, 1)
        return Picker("Time", selection: $selectedFixedTime) {
            ForEach(0..<rows, id: \.self) { index in
                Text(index < timesMS.count ? String(format: "%.0f ms", timesMS[index]) : "t\(index + 1)").tag(index)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var reconstructionTopomap: some View {
        VStack(spacing: 4) {
            Text(reconstructionMapTitle).font(.caption2).foregroundStyle(.secondary)
            if let layout, let _ = channelMode {
                TopomapView(layout: layout, values: reconstructionTopomapValues(),
                            timeSeconds: reconstructionCursorValue / 1000,
                            fixedScale: nil, showsHeader: false, canvasMinHeight: 210,
                            highlightThreshold: reconstructionTopomapHighlightThreshold())
                    .frame(height: 235)
            } else {
                ContentUnavailableView("No layout", systemImage: "circle.dashed").font(.caption)
            }
        }
    }

    private var channelControl: some View {
        let channelCount = channelMode.map { result.factors[$0].rows } ?? 1
        return Stepper("Channel \(clamped(selectedChannel, upperBound: channelCount - 1) + 1)",
                       value: $selectedChannel, in: 0...max(channelCount - 1, 0))
            .fixedSize()
    }

    private var traceChart: some View {
        let points = reconstructionTracePoints()
        let yDomain = symmetricDomain(points.map(\.y))
        let xTitle = traceAxisLabel
        let cursorX = reconstructionCursorValue
        return VStack(alignment: .leading, spacing: 2) {
            Text(reconstructionTraceTitle).font(.caption2).foregroundStyle(.secondary)
            Chart {
                if let tm = traceMode {
                    let threshold = traceThresholdValue(component: selectedR, mode: tm)
                    ForEach(loadingRanges(mode: tm, component: selectedR, threshold: threshold)) { band in
                        RectangleMark(
                            xStart: .value(xTitle, band.lower),
                            xEnd: .value(xTitle, band.upper),
                            yStart: .value("Lower", yDomain.lowerBound),
                            yEnd: .value("Upper", yDomain.upperBound)
                        )
                        .foregroundStyle(Color.yellow.opacity(0.14))
                    }
                }
                ForEach(points) { point in
                    LineMark(x: .value(xTitle, point.x), y: .value("Contribution", point.y))
                        .foregroundStyle(Color.accentColor)
                    if point.id == clamped(reconstructionCursor, upperBound: points.count - 1) {
                        PointMark(x: .value(xTitle, point.x), y: .value("Contribution", point.y))
                            .foregroundStyle(Color.yellow)
                    }
                }
                RuleMark(x: .value(xTitle, cursorX))
                    .foregroundStyle(Color.yellow.opacity(0.9))
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel(xTitle)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = value.location.x - frame.origin.x
                                    guard x >= 0, x <= frame.width,
                                          let axisValue = proxy.value(atX: x, as: Double.self) else { return }
                                    reconstructionCursor = nearestTraceIndex(to: axisValue)
                                }
                        )
                }
            }
            .frame(height: 170)
            Text(reconstructionCursorLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var traceAxisLabel: String {
        guard let mode = traceMode else { return "Index" }
        switch modeTypes[mode] {
        case .time: return "Time (ms)"
        case .frequency: return "Frequency (Hz)"
        default: return result.modeNames.indices.contains(mode) ? result.modeNames[mode] : "Index"
        }
    }

    private var reconstructionCursorValue: Double {
        guard let mode = traceMode else { return Double(reconstructionCursor) }
        let index = clamped(reconstructionCursor, upperBound: result.factors[mode].rows - 1)
        switch modeTypes[mode] {
        case .time:
            return index < timesMS.count ? timesMS[index] : Double(index)
        case .frequency:
            return index < freqs.count ? freqs[index] : Double(index)
        default:
            return Double(index)
        }
    }

    private var reconstructionCursorLabel: String {
        guard let mode = traceMode else { return "\(reconstructionCursor)" }
        switch modeTypes[mode] {
        case .time: return String(format: "%.0f ms", reconstructionCursorValue)
        case .frequency: return String(format: "%.1f Hz", reconstructionCursorValue)
        default: return "\(clamped(reconstructionCursor, upperBound: result.factors[mode].rows - 1) + 1)"
        }
    }

    private var reconstructionMapTitle: String {
        "Scalp contribution at \(reconstructionCursorLabel)"
    }

    private var reconstructionTraceTitle: String {
        "Channel \(selectedChannel + 1) contribution"
    }

    private func reconstructionTracePoints() -> [ReconstructionPoint] {
        guard let cm = channelMode, let tm = traceMode else { return [] }
        let r = selectedR
        let channel = clamped(selectedChannel, upperBound: result.factors[cm].rows - 1)
        let scale = reconstructionScale(component: r, excluding: [cm, tm])
        return (0..<result.factors[tm].rows).map { index in
            let x: Double
            switch modeTypes[tm] {
            case .time: x = index < timesMS.count ? timesMS[index] : Double(index)
            case .frequency: x = index < freqs.count ? freqs[index] : Double(index)
            default: x = Double(index)
            }
            let y = scale * result.factors[cm][channel, r] * result.factors[tm][index, r]
            return ReconstructionPoint(id: index, x: x, y: y)
        }
    }

    private func reconstructionTopomapValues() -> [Double] {
        guard let cm = channelMode, let tm = traceMode else { return [] }
        let r = selectedR
        let traceIndex = clamped(reconstructionCursor, upperBound: result.factors[tm].rows - 1)
        let scale = reconstructionScale(component: r, excluding: [cm, tm])
            * result.factors[tm][traceIndex, r]
        return (0..<result.factors[cm].rows).map { channel in
            scale * result.factors[cm][channel, r]
        }
    }

    private func reconstructionTopomapHighlightThreshold() -> Double? {
        guard let cm = channelMode, let tm = traceMode else { return nil }
        let r = selectedR
        let traceIndex = clamped(reconstructionCursor, upperBound: result.factors[tm].rows - 1)
        let scale = abs(
            reconstructionScale(component: r, excluding: [cm, tm])
            * result.factors[tm][traceIndex, r]
        )
        let threshold = scale * channelThresholdValue(component: r)
        return threshold > 0 ? threshold : nil
    }

    private func reconstructionScale(component r: Int, excluding excludedModes: Set<Int>) -> Double {
        var scale = result.weights[r]
        for mode in result.factors.indices where !excludedModes.contains(mode) {
            scale *= selectedMultiplier(mode: mode, component: r)
        }
        return scale
    }

    private func selectedMultiplier(mode: Int, component r: Int) -> Double {
        switch modeTypes[mode] {
        case .condition:
            return conditionMultiplier(mode: mode, component: r)
        case .frequency:
            return result.factors[mode][clamped(selectedFrequency, upperBound: result.factors[mode].rows - 1), r]
        case .time:
            return result.factors[mode][clamped(selectedFixedTime, upperBound: result.factors[mode].rows - 1), r]
        case .subject:
            return subjectMultiplier(component: r)
        case .channel, .feature:
            return 1
        }
    }

    private func conditionMultiplier(mode: Int, component r: Int) -> Double {
        guard conditionScaleGrouping != "Condition",
              !conditionGroupingOptions.isEmpty else {
            return result.factors[mode][clamped(selectedCondition, upperBound: result.factors[mode].rows - 1), r]
        }
        let level = resolvedConditionGroupLevel(for: conditionScaleGrouping)
        let indices = conditionIndices(grouping: conditionScaleGrouping, level: level)
        guard !indices.isEmpty else {
            return result.factors[mode][clamped(selectedCondition, upperBound: result.factors[mode].rows - 1), r]
        }
        let values = indices
            .filter { $0 < result.factors[mode].rows }
            .map { result.factors[mode][$0, r] }
        guard !values.isEmpty else { return 1 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func subjectMultiplier(component r: Int) -> Double {
        guard let mode = subjectMode else { return 1 }
        let values = result.factors[mode].column(r)
        guard !values.isEmpty else { return 1 }
        if subjectScaleGrouping != "Subject", !factorNames.isEmpty {
            let level = resolvedSubjectGroupLevel(for: subjectScaleGrouping)
            let indices = subjectIndices(grouping: subjectScaleGrouping, level: level)
            let groupValues = indices.compactMap { $0 < values.count ? values[$0] : nil }
            guard !groupValues.isEmpty else { return 1 }
            return groupValues.reduce(0, +) / Double(groupValues.count)
        }
        switch subjectReference {
        case .typicalAbs:
            return values.map(abs).reduce(0, +) / Double(values.count)
        case .unit:
            return 1
        case .mean:
            return values.reduce(0, +) / Double(values.count)
        case .maxPositive:
            return values.max() ?? 1
        case .maxNegative:
            return values.min() ?? -1
        }
    }

    private func conditionLevelBinding(grouping: String) -> Binding<String> {
        Binding(
            get: { resolvedConditionGroupLevel(for: grouping) },
            set: { selectedConditionGroupLevel = $0 }
        )
    }

    private func subjectLevelBinding(grouping: String) -> Binding<String> {
        Binding(
            get: { resolvedSubjectGroupLevel(for: grouping) },
            set: { selectedSubjectGroupLevel = $0 }
        )
    }

    private func resolvedConditionGroupLevel(for grouping: String) -> String {
        let levels = conditionGroupLevels(for: grouping)
        if levels.contains(selectedConditionGroupLevel) { return selectedConditionGroupLevel }
        return levels.first ?? ""
    }

    private func resolvedSubjectGroupLevel(for grouping: String) -> String {
        let levels = subjectGroupLevels(for: grouping)
        if levels.contains(selectedSubjectGroupLevel) { return selectedSubjectGroupLevel }
        return levels.first ?? ""
    }

    private func symmetricDomain(_ values: [Double]) -> ClosedRange<Double> {
        let maxAbs = values.map(abs).max() ?? 1
        let bound = max(maxAbs, 1e-9)
        return -bound...bound
    }

    private func clamped(_ value: Int, upperBound: Int) -> Int {
        min(max(value, 0), max(upperBound, 0))
    }

    private func nearestTraceIndex(to xValue: Double) -> Int {
        guard let mode = traceMode else { return 0 }
        let count = result.factors[mode].rows
        guard count > 1 else { return 0 }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for index in 0..<count {
            let distance = abs(axisValue(mode: mode, index: index) - xValue)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    private func subjectGroupLevels(for grouping: String) -> [String] {
        let factorIndices = indices(for: grouping)
        guard !factorIndices.isEmpty else { return [] }
        var order: [String] = []
        var seen = Set<String>()
        for subject in subjectLevels.indices {
            let level = groupLevel(subject: subject, factorIndices: factorIndices)
            if seen.insert(level).inserted { order.append(level) }
        }
        return order
    }

    private func subjectIndices(grouping: String, level: String) -> [Int] {
        let factorIndices = indices(for: grouping)
        guard !factorIndices.isEmpty else { return [] }
        return subjectLevels.indices.filter { subject in
            groupLevel(subject: subject, factorIndices: factorIndices) == level
        }
    }

    private func conditionGroupLevels(for grouping: String) -> [String] {
        let factorIndices = conditionFactorIndices(for: grouping)
        guard !factorIndices.isEmpty else { return [] }
        var order: [String] = []
        var seen = Set<String>()
        for condition in conditionNames.indices {
            let level = conditionLevel(condition: condition, factorIndices: factorIndices)
            if seen.insert(level).inserted { order.append(level) }
        }
        return order
    }

    private func conditionIndices(grouping: String, level: String) -> [Int] {
        let factorIndices = conditionFactorIndices(for: grouping)
        guard !factorIndices.isEmpty else { return [] }
        return conditionNames.indices.filter { condition in
            conditionLevel(condition: condition, factorIndices: factorIndices) == level
        }
    }

    private func conditionFactorIndices(for grouping: String) -> [Int] {
        if let index = conditionMetadata.factorNames.firstIndex(of: grouping) { return [index] }
        let parts = grouping.components(separatedBy: " × ")
        guard parts.count == 2 else { return [] }
        return parts.compactMap { conditionMetadata.factorNames.firstIndex(of: $0) }
    }

    private func conditionLevel(condition: Int, factorIndices: [Int]) -> String {
        factorIndices.map { factorIndex in
            if condition < conditionMetadata.levelsByCondition.count,
               factorIndex < conditionMetadata.levelsByCondition[condition].count,
               !conditionMetadata.levelsByCondition[condition][factorIndex].isEmpty {
                return conditionMetadata.levelsByCondition[condition][factorIndex]
            }
            return "Unassigned"
        }
        .joined(separator: " × ")
    }

    private func axisLabel(mode: Int) -> String {
        switch modeTypes[mode] {
        case .time: return "Time (ms)"
        case .frequency: return "Frequency (Hz)"
        default: return result.modeNames.indices.contains(mode) ? result.modeNames[mode] : "Index"
        }
    }

    private func traceThresholdLabel(mode: Int) -> String {
        switch modeTypes[mode] {
        case .time: return "Time"
        case .frequency: return "Frequency"
        default: return "Trace"
        }
    }

    private func axisValue(mode: Int, index: Int) -> Double {
        switch modeTypes[mode] {
        case .time:
            return index < timesMS.count ? timesMS[index] : Double(index)
        case .frequency:
            return index < freqs.count ? freqs[index] : Double(index)
        default:
            return Double(index)
        }
    }

    private func axisPoints(values: [Double], mode: Int) -> [AxisPoint] {
        values.enumerated().map { AxisPoint(x: axisValue(mode: mode, index: $0.offset), y: $0.element) }
    }

    private func loadingMaxAbs(mode: Int, component r: Int) -> Double {
        guard result.factors.indices.contains(mode), r >= 0, r < result.rank else { return 0 }
        return result.factors[mode].column(r).map(abs).max() ?? 0
    }

    private func channelThresholdValue(component r: Int) -> Double {
        guard let cm = channelMode else { return 0 }
        return loadingMaxAbs(mode: cm, component: r) * spatialFootprintFraction
    }

    private func traceThresholdValue(component r: Int, mode: Int) -> Double {
        loadingMaxAbs(mode: mode, component: r) * traceFootprintFraction
    }

    private func positiveFootprintChannels(component r: Int) -> [Int] {
        guard let cm = channelMode else { return [] }
        let threshold = channelThresholdValue(component: r)
        return result.factors[cm].column(r).indices.filter { result.factors[cm][$0, r] >= threshold }
    }

    private func negativeFootprintChannels(component r: Int) -> [Int] {
        guard let cm = channelMode else { return [] }
        let threshold = channelThresholdValue(component: r)
        return result.factors[cm].column(r).indices.filter { result.factors[cm][$0, r] <= -threshold }
    }

    private func channelFootprintLabel(component r: Int) -> String {
        let pos = positiveFootprintChannels(component: r).count
        let neg = negativeFootprintChannels(component: r).count
        return "+\(pos) / -\(neg)"
    }

    private func traceFootprintLabel(component r: Int, mode: Int) -> String {
        let threshold = traceThresholdValue(component: r, mode: mode)
        let count = result.factors[mode].column(r).filter { abs($0) >= threshold }.count
        return "\(count) pts"
    }

    private func loadingRanges(mode: Int, component r: Int, threshold: Double) -> [RangeBand] {
        guard result.factors.indices.contains(mode), r >= 0, r < result.rank else { return [] }
        let values = result.factors[mode].column(r)
        guard !values.isEmpty else { return [] }
        var ranges: [RangeBand] = []
        var start: Int?
        for i in values.indices {
            let above = abs(values[i]) >= threshold
            if above, start == nil { start = i }
            if !above, let s = start {
                ranges.append(rangeBand(mode: mode, start: s, end: i - 1))
                start = nil
            }
        }
        if let s = start { ranges.append(rangeBand(mode: mode, start: s, end: values.count - 1)) }
        return ranges
    }

    private func rangeBand(mode: Int, start: Int, end: Int) -> RangeBand {
        let count = result.factors[mode].rows
        let startCenter = axisValue(mode: mode, index: start)
        let endCenter = axisValue(mode: mode, index: end)
        let lowerHalf: Double
        if start > 0 {
            lowerHalf = abs(startCenter - axisValue(mode: mode, index: start - 1)) / 2
        } else if count > 1 {
            lowerHalf = abs(axisValue(mode: mode, index: min(start + 1, count - 1)) - startCenter) / 2
        } else {
            lowerHalf = 0.5
        }
        let upperHalf: Double
        if end + 1 < count {
            upperHalf = abs(axisValue(mode: mode, index: end + 1) - endCenter) / 2
        } else if end > 0 {
            upperHalf = abs(endCenter - axisValue(mode: mode, index: end - 1)) / 2
        } else {
            upperHalf = lowerHalf
        }
        let lower = min(startCenter - lowerHalf, endCenter + upperHalf)
        let upper = max(startCenter - lowerHalf, endCenter + upperHalf)
        return RangeBand(lower: lower, upper: upper)
    }

    private func temporalFootprintRanges(component r: Int) -> [ClosedRange<Double>] {
        guard let tm = timeMode else { return [] }
        let threshold = traceThresholdValue(component: r, mode: tm)
        return loadingRanges(mode: tm, component: r, threshold: threshold).map { $0.lower...$0.upper }
    }

    private func rebuildObservedFootprint() {
        guard let context = observedContext, channelMode != nil, timeMode != nil else {
            observedPosTraces = []
            observedNegTraces = []
            observedCellOrder = []
            observedRebuilding = false
            observedRebuildTask?.cancel()
            observedRebuildTask = nil
            return
        }

        let generation = observedRebuildGeneration + 1
        observedRebuildGeneration = generation
        observedRebuilding = true
        if observedCursorSample == 0 { observedCursorSample = context.baselineSamples }

        let input = ClusterERPTraceBuilder.Input(
            groupBy: observedGroupBy,
            conditionDimension: Self.conditionDimension,
            factorNames: factorNames,
            subjects: context.subjects,
            conditionNames: conditionNames,
            positiveChannels: positiveFootprintChannels(component: selectedR),
            negativeChannels: negativeFootprintChannels(component: selectedR)
        )

        observedRebuildTask?.cancel()
        observedRebuildTask = Task.detached(priority: .userInitiated) {
            let result = ClusterERPTraceBuilder.build(input)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == observedRebuildGeneration else { return }
                observedCellOrder = result.cellOrder
                observedPosTraces = result.positive.map(observedOverlayTrace)
                observedNegTraces = result.negative.map(observedOverlayTrace)
                observedRebuilding = false
            }
        }
    }

    private func observedOverlayTrace(_ trace: ClusterERPTraceBuilder.TraceData) -> OverlayTrace {
        OverlayTrace(
            id: trace.label,
            label: trace.label,
            color: OverlayWaveformView.palette[trace.colorIndex % OverlayWaveformView.palette.count],
            samples: [],
            centroid: trace.mean,
            contributing: trace.n,
            sensorLayout: nil,
            centroidSE: trace.se
        )
    }

    @ViewBuilder
    private func modeChart(mode: Int, _ r: Int) -> some View {
        let column = result.factors[mode].column(r)
        switch modeTypes[mode] {
        case .time:
            lineChart(column, mode: mode, r: r, title: "Time course")
        case .frequency:
            lineChart(column, mode: mode, r: r, title: "Spectrum")
        case .condition:
            VStack(alignment: .leading, spacing: 2) {
                Text("Condition loadings").font(.caption2).foregroundStyle(.secondary)
                Chart(column.enumerated().map {
                    NamedLoad(name: $0.offset < conditionNames.count ? conditionNames[$0.offset] : "c\($0.offset)",
                              value: $0.element)
                }) { item in
                    BarMark(x: .value("Condition", item.name), y: .value("Loading", item.value))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 90)
            }
        case .feature:
            VStack(alignment: .leading, spacing: 2) {
                Text("Feature loadings").font(.caption2).foregroundStyle(.secondary)
                Chart(column.enumerated().map {
                    NamedLoad(name: "f\($0.offset + 1)", value: $0.element)
                }) { item in
                    BarMark(x: .value("Feature", item.name), y: .value("Loading", item.value))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 90)
                .chartXAxis(.hidden)
            }
        case .channel, .subject:
            EmptyView()
        }
    }

    private func lineChart(_ values: [Double], mode: Int, r: Int, title: String) -> some View {
        let pts = axisPoints(values: values, mode: mode)
        let threshold = traceThresholdValue(component: r, mode: mode)
        let bands = loadingRanges(mode: mode, component: r, threshold: threshold)
        let domain = symmetricDomain(values)
        let xLabel = axisLabel(mode: mode)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(bands) { band in
                    RectangleMark(
                        xStart: .value(xLabel, band.lower),
                        xEnd: .value(xLabel, band.upper),
                        yStart: .value("Lower", domain.lowerBound),
                        yEnd: .value("Upper", domain.upperBound)
                    )
                    .foregroundStyle(Color.yellow.opacity(0.12))
                }
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
                RuleMark(y: .value("Threshold", -threshold))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
                ForEach(pts) { p in
                    LineMark(x: .value(xLabel, p.x), y: .value("Loading", p.y))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxisLabel(xLabel)
            .frame(height: 120)
        }
    }

    // MARK: - Subject loadings (per subject, or grouped by design with mean ± SE)

    private struct SubjectLoad: Identifiable { let id = UUID(); let index: Int; let value: Double }
    private struct GroupStat: Identifiable {
        let id = UUID(); let level: String; let mean: Double; let se: Double; let n: Int
    }

    @ViewBuilder
    private func subjectLoadings(mode: Int, _ r: Int) -> some View {
        let column = result.factors[mode].column(r)
        VStack(alignment: .leading, spacing: 2) {
            Text(groupBy == "Subject" ? "Subject loadings" : "Subject loadings by \(groupBy)")
                .font(.caption2).foregroundStyle(.secondary)
            if groupBy == "Subject" {
                Chart(column.enumerated().map { SubjectLoad(index: $0.offset + 1, value: $0.element) }) { item in
                    BarMark(x: .value("Subject", item.index), y: .value("Loading", item.value))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                }
                .chartXAxisLabel("Subject")
                .frame(height: 80)
            } else {
                Chart(groupStats(column, grouping: groupBy)) { stat in
                    BarMark(x: .value("Group", stat.level), y: .value("Mean loading", stat.mean))
                        .foregroundStyle(Color.accentColor)
                    RuleMark(x: .value("Group", stat.level),
                             yStart: .value("lo", stat.mean - stat.se),
                             yEnd: .value("hi", stat.mean + stat.se))
                        .foregroundStyle(.primary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .frame(height: 110)
            }
        }
    }

    private func groupStats(_ column: [Double], grouping: String) -> [GroupStat] {
        let factorIndices = indices(for: grouping)
        guard !factorIndices.isEmpty else { return [] }
        var order: [String] = []
        var buckets: [String: [Double]] = [:]
        for (i, value) in column.enumerated() {
            let level = groupLevel(subject: i, factorIndices: factorIndices)
            if buckets[level] == nil { order.append(level) }
            buckets[level, default: []].append(value)
        }
        return order.map { level in
            let values = buckets[level] ?? []
            let n = values.count
            let mean = values.reduce(0, +) / Double(max(n, 1))
            let se: Double = n > 1
                ? (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)).squareRoot() / Double(n).squareRoot()
                : 0
            return GroupStat(level: level, mean: mean, se: se, n: n)
        }
    }

    private func indices(for grouping: String) -> [Int] {
        if let index = factorNames.firstIndex(of: grouping) { return [index] }
        let parts = grouping.components(separatedBy: " × ")
        guard parts.count == 2 else { return [] }
        return parts.compactMap { factorNames.firstIndex(of: $0) }
    }

    private func groupLevel(subject: Int, factorIndices: [Int]) -> String {
        factorIndices.map { factorIndex in
            if subject < subjectLevels.count,
               factorIndex < subjectLevels[subject].count,
               !subjectLevels[subject][factorIndex].isEmpty {
                return subjectLevels[subject][factorIndex]
            }
            return "Unassigned"
        }
        .joined(separator: " × ")
    }

    private func interactionName(_ a: String, _ b: String) -> String {
        "\(a) × \(b)"
    }
}
