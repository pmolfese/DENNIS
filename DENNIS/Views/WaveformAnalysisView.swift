//
//  WaveformAnalysisView.swift
//  DENNIS
//
//  Interactive ERP measurement windows inspired by EVA's trials workspace.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WaveformAnalysisView: View {
    @Environment(Study.self) private var study
    let groupID: String

    @State private var categories: [WaveformCategory] = []
    @State private var selectedCategoryID: UUID?
    @State private var editingCategoryID: UUID?
    @State private var measureSelection: WaveformMeasureSelection = .adaptiveMean
    @State private var polarity: WaveformPolarity = .positive
    @State private var adaptivePreMS = 12.5
    @State private var adaptivePostMS = 12.5
    @State private var cursorSample = 0
    @State private var topomapCursorSample = 0
    @State private var exportError: String?
    @State private var dragStarts: [UUID: WaveformCategory] = [:]
    @State private var averageLoadState: AverageLoadState = .idle
    @State private var activePlotDrag: PlotDrag?
    @State private var previewSelection = Set<WaveformExportPreviewRow.ID>()
    @State private var previewRowsCache: [WaveformExportPreviewRow] = []
    @State private var previewMetricColumnNames: [String] = []
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var topomapCursorTask: Task<Void, Never>?
    @State private var isPreviewTableLoading = false

    private let plotHeight: CGFloat = 260
    private let palette: [Color] = [.orange, .teal, .purple, .pink, .indigo, .green, .red, .cyan, .mint, .brown]

    private enum AverageLoadState {
        case idle
        case loading
        case loaded(WaveformAnalysis.GroupAverage)
        case unavailable
    }

    private enum PlotDrag {
        case cursor
        case move(UUID)
        case resize(UUID, ResizeEdge)
    }

    private var members: [Dataset] {
        study.datasets(inGroupID: groupID)
    }

    private var conditionNames: [String] {
        study.sharedConditionNames(inGroupID: groupID)
    }

    private var groupLabel: String {
        groupID == "_all" || groupID.isEmpty ? "All Files" : groupID
    }

    private var canExport: Bool {
        !members.isEmpty && !categories.isEmpty
    }

    private var showsAdaptiveControls: Bool {
        measureSelection == .adaptiveMean || measureSelection == .all
    }

    private var factorNames: [String] {
        study.factors.map(\.name)
    }

    private var previewColumns: [WaveformExportColumn] {
        WaveformAnalysis.exportColumns(categories: categories, selection: measureSelection, polarity: polarity)
    }

    private var previewDatasetSnapshots: [WaveformPreviewDatasetSnapshot] {
        members.map { dataset in
            WaveformPreviewDatasetSnapshot(
                id: dataset.id,
                file: dataset.sourceURL.lastPathComponent,
                levels: dataset.levels,
                samplingRate: dataset.samplingRate,
                conditions: dataset.conditions.map { condition in
                    WaveformPreviewConditionSnapshot(
                        name: condition.name,
                        samples: condition.samples,
                        baselineSamples: condition.baselineSamples
                    )
                }
            )
        }
    }

    private var average: WaveformAnalysis.GroupAverage? {
        if case .loaded(let value) = averageLoadState { return value }
        return nil
    }

    private var loadSignature: String {
        let memberPart = members.map { dataset in
            let loaded = dataset.conditions.reduce(0) { partial, condition in
                partial + (condition.samples?.first?.count ?? condition.sampleCount)
            }
            return "\(dataset.id.uuidString):\(loaded):\(dataset.samplingRate):\(dataset.channelCount)"
        }.joined(separator: "|")
        return "\(groupID)#\(conditionNames.joined(separator: ","))#\(memberPart)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch averageLoadState {
                case .idle, .loading:
                    loadingView
                case .loaded(let average):
                    butterflySection(average)
                    controlsSection
                case .unavailable:
                    ContentUnavailableView(
                        "No Loaded ERP Data",
                        systemImage: "waveform.path.ecg.rectangle",
                        description: Text("Load source files for this group before defining waveform windows.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .task(id: loadSignature) {
            await loadAverage()
            refreshPreviewNow()
        }
        .onAppear { refreshPreviewNow() }
        .onDisappear {
            previewRefreshTask?.cancel()
            topomapCursorTask?.cancel()
        }
        .onChange(of: categories) { _, _ in refreshPreviewIfIdle() }
        .onChange(of: measureSelection) { _, _ in refreshPreviewIfIdle() }
        .onChange(of: polarity) { _, _ in refreshPreviewIfIdle() }
        .onChange(of: adaptivePreMS) { _, _ in refreshPreviewIfIdle() }
        .onChange(of: adaptivePostMS) { _, _ in refreshPreviewIfIdle() }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing grand average")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waveform Analysis").font(.largeTitle.bold())
            Text("\(groupLabel) · \(members.count) files · \(conditionNames.count) shared conditions")
                .foregroundStyle(.secondary)
        }
    }

    private func butterflySection(_ average: WaveformAnalysis.GroupAverage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Grand Average ERP", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("Butterfly plot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ERPWaveformView(
                            samples: average.samples,
                            samplingRate: average.samplingRate,
                            baselineSamples: average.baselineSamples,
                            cursorSample: cursorBinding(max: average.sampleCount - 1),
                            centroid: average.centroid
                        )
                        .allowsHitTesting(false)
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                            measurementOverlay(category, color: color(for: index), size: proxy.size)
                                .allowsHitTesting(false)
                        }
                        plotInteractionLayer(average: average, size: proxy.size)
                            .zIndex(1000)
                    }
                }
                .frame(height: plotHeight)

                topomapPanel(average)
                    .frame(width: 320)
            }
        }
    }

    @ViewBuilder
    private func topomapPanel(_ average: WaveformAnalysis.GroupAverage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topography").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let layout = average.sensorLayout {
                let cursor = clampedTopomapCursor(max: average.sampleCount - 1)
                TopomapView(
                    layout: layout,
                    values: average.samples.map { channel in
                        cursor < channel.count ? Double(channel[cursor]) : 0
                    },
                    timeSeconds: average.samplingRate > 0 ? Double(cursor - average.baselineSamples) / average.samplingRate : 0,
                    fixedScale: nil,
                    showsHeader: false,
                    interpolationStep: 7,
                    usesVerticalColorBar: true,
                    canvasMinHeight: 210
                )
                .frame(height: 260)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("The source files do not include a readable sensorLayout.xml.")
                )
                .frame(height: 260)
            }
        }
    }

    private var controlsSection: some View {
        HStack(alignment: .top, spacing: 18) {
            categoryEditor
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            Divider()
                .frame(minHeight: 250)
            analysisControls
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var categoryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                Button { addCategory() } label: {
                    Image(systemName: "plus")
                }
                .frame(width: 28, height: 28)
                .help("Add category")
                Button { removeSelectedCategory() } label: {
                    Image(systemName: "minus")
                }
                .frame(width: 28, height: 28)
                .disabled(selectedCategoryID == nil)
                .help("Remove selected category")
            }
            .buttonStyle(.bordered)

            List(selection: $selectedCategoryID) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    categoryRow(category, color: color(for: index))
                        .tag(category.id)
                }
            }
            .frame(minHeight: 180)

            if categories.isEmpty {
                Text("Press + to add a measurement category.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryRow(_ category: WaveformCategory, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            if editingCategoryID == category.id {
                TextField("Category name", text: nameBinding(for: category.id))
                    .textFieldStyle(.plain)
                    .onSubmit { editingCategoryID = nil }
            } else {
                Text(category.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        selectedCategoryID = category.id
                        editingCategoryID = category.id
                    }
            }
            Text(windowLabel(category))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Measure").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Measure", selection: $measureSelection) {
                        ForEach(WaveformMeasureSelection.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Polarity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Polarity", selection: $polarity) {
                        ForEach(WaveformPolarity.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                Spacer()

                Button {
                    exportCSV()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
                .help("One row per source file with study metadata and one value per category/measure.")
            }

            if let selected = categories.first(where: { $0.id == selectedCategoryID }) {
                selectedCategoryFields(selected)
            } else {
                Text("Select a category to edit its exact window in milliseconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if showsAdaptiveControls {
                adaptiveControls
            }

            Divider()

            exportPreview
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectedCategoryFields(_ category: WaveformCategory) -> some View {
        HStack(spacing: 10) {
            Text("Window (ms)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Start", value: windowStartBinding(for: category.id), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
            Text("to")
                .foregroundStyle(.secondary)
            TextField("End", value: windowEndBinding(for: category.id), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
        }
    }

    private var adaptiveControls: some View {
        HStack(spacing: 10) {
            Text("Adaptive mean around peak (ms)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Before", value: $adaptivePreMS, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
            Text("before")
                .foregroundStyle(.secondary)
            TextField("After", value: $adaptivePostMS, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
            Text("after")
                .foregroundStyle(.secondary)
        }
    }

    private var exportPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if categories.isEmpty {
                Text("Add a category to preview export columns.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ZStack(alignment: .top) {
                    exportPreviewTable
                    if isPreviewTableLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(width: 180)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 14)
                    }
                }
                .frame(minHeight: 140, maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            }
        }
    }

    private var exportPreviewTable: some View {
        WaveformExportPreviewTable(
            rows: previewRowsCache,
            metadataColumns: factorNames,
            metricColumns: previewMetricColumnNames,
            selection: $previewSelection
        )
    }

    private func loadAverage() async {
        averageLoadState = .loading
        await Task.yield()
        let loaded = WaveformAnalysis.groupAverage(datasets: members, conditionNames: conditionNames)
        guard !Task.isCancelled else { return }
        if let loaded {
            averageLoadState = .loaded(loaded)
            if cursorSample <= 0 {
                cursorSample = min(max(loaded.baselineSamples, 0), max(loaded.sampleCount - 1, 0))
            } else {
                cursorSample = clampedCursor(max: loaded.sampleCount - 1)
            }
            topomapCursorSample = cursorSample
        } else {
            averageLoadState = .unavailable
        }
    }

    private func measurementOverlay(_ category: WaveformCategory, color: Color, size: CGSize) -> some View {
        let frame = overlayFrame(for: category, size: size)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(selectedCategoryID == category.id ? 0.24 : 0.16))
            Rectangle()
                .stroke(color.opacity(0.9), lineWidth: selectedCategoryID == category.id ? 2 : 1)
            Text(category.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .lineLimit(1)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            resizeHandle(category, edge: .leading, color: color, size: size)
                .offset(x: 0, y: 0)
            resizeHandle(category, edge: .trailing, color: color, size: size)
                .offset(x: max(0, frame.width - 28), y: 0)
        }
        .frame(width: frame.width, height: size.height)
        .offset(x: frame.minX, y: 0)
    }

    private enum ResizeEdge { case leading, trailing }

    private func resizeHandle(_ category: WaveformCategory, edge: ResizeEdge,
                              color: Color, size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 28)
            Rectangle()
                .fill(color.opacity(0.95))
                .frame(width: 7)
                .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0)
        }
            .frame(width: 28, height: size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        selectedCategoryID = category.id
                        resizeCategory(category.id, edge: edge,
                                       translationX: value.translation.width,
                                       plotWidth: size.width)
                    }
                    .onEnded { _ in
                        dragStarts[category.id] = nil
                    }
            )
            .help(edge == .leading ? "Drag to adjust the start of this window." : "Drag to adjust the end of this window.")
    }

    private func plotInteractionLayer(average: WaveformAnalysis.GroupAverage, size: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let action = activePlotDrag ?? plotDrag(for: value.startLocation, size: size)
                        activePlotDrag = action
                        switch action {
                        case .cursor:
                            let sample = sample(forX: value.location.x, width: size.width,
                                                sampleCount: average.sampleCount)
                            cursorSample = sample
                            scheduleTopomapCursorUpdate(sample, max: average.sampleCount - 1)
                        case .move(let id):
                            previewRefreshTask?.cancel()
                            selectedCategoryID = id
                            moveCategory(id, translationX: value.translation.width, plotWidth: size.width)
                        case .resize(let id, let edge):
                            previewRefreshTask?.cancel()
                            selectedCategoryID = id
                            resizeCategory(id, edge: edge, translationX: value.translation.width,
                                           plotWidth: size.width)
                        }
                    }
                    .onEnded { _ in
                        if case .move(let id) = activePlotDrag {
                            dragStarts[id] = nil
                        } else if case .resize(let id, _) = activePlotDrag {
                            dragStarts[id] = nil
                        }
                        if case .cursor = activePlotDrag {
                            refreshTopomapCursorNow(cursorSample, max: average.sampleCount - 1)
                        } else if activePlotDrag != nil {
                            refreshPreviewNow()
                        }
                        activePlotDrag = nil
                    }
            )
    }

    private func plotDrag(for location: CGPoint, size: CGSize) -> PlotDrag {
        let edgeSlop: CGFloat = 18
        let bodySlop: CGFloat = 2
        for category in categories.reversed() {
            let frame = overlayFrame(for: category, size: size)
            let expanded = frame.insetBy(dx: -bodySlop, dy: 0)
            guard expanded.contains(location) else { continue }
            if abs(location.x - frame.minX) <= edgeSlop {
                return .resize(category.id, .leading)
            }
            if abs(location.x - frame.maxX) <= edgeSlop {
                return .resize(category.id, .trailing)
            }
            return .move(category.id)
        }
        return .cursor
    }

    private func sample(forX x: CGFloat, width: CGFloat, sampleCount: Int) -> Int {
        guard sampleCount > 1, width > 0 else { return 0 }
        let fraction = Swift.max(0, Swift.min(1, x / width))
        return Int((fraction * CGFloat(sampleCount - 1)).rounded())
    }

    // MARK: - Category actions

    private func addCategory() {
        guard let average else { return }
        let range = WaveformAnalysis.timeRange(
            sampleCount: average.samples.first?.count ?? 0,
            samplingRate: average.samplingRate,
            baselineSamples: average.baselineSamples
        )
        let width = max(40, (range.upperBound - range.lowerBound) * 0.15)
        let start = max(range.lowerBound, min(range.upperBound - width, 100 + Double(categories.count) * width * 0.4))
        let category = WaveformCategory(name: "New Category", startMS: start, endMS: start + width)
        categories.append(category)
        selectedCategoryID = category.id
        editingCategoryID = category.id
    }

    private func removeSelectedCategory() {
        guard let selectedCategoryID else { return }
        categories.removeAll { $0.id == selectedCategoryID }
        self.selectedCategoryID = categories.last?.id
    }

    private func moveCategory(_ id: UUID, translationX: CGFloat, plotWidth: CGFloat) {
        guard let average, let current = categories.first(where: { $0.id == id }) else { return }
        let original = dragStarts[id] ?? current
        dragStarts[id] = original
        let range = WaveformAnalysis.timeRange(
            sampleCount: average.samples.first?.count ?? 0,
            samplingRate: average.samplingRate,
            baselineSamples: average.baselineSamples
        )
        let delta = msDelta(for: translationX, plotWidth: plotWidth, range: range)
        let width = original.endMS - original.startMS
        let start = clamp(original.startMS + delta, range.lowerBound, range.upperBound - abs(width))
        updateCategory(id) {
            $0.startMS = start
            $0.endMS = start + width
        }
    }

    private func resizeCategory(_ id: UUID, edge: ResizeEdge, translationX: CGFloat, plotWidth: CGFloat) {
        guard let average, let current = categories.first(where: { $0.id == id }) else { return }
        let original = dragStarts[id] ?? current
        dragStarts[id] = original
        let range = WaveformAnalysis.timeRange(
            sampleCount: average.samples.first?.count ?? 0,
            samplingRate: average.samplingRate,
            baselineSamples: average.baselineSamples
        )
        let delta = msDelta(for: translationX, plotWidth: plotWidth, range: range)
        updateCategory(id) {
            switch edge {
            case .leading:
                $0.startMS = clamp(original.startMS + delta, range.lowerBound, original.endMS - 1)
            case .trailing:
                $0.endMS = clamp(original.endMS + delta, original.startMS + 1, range.upperBound)
            }
        }
    }

    private func updateCategory(_ id: UUID, mutate: (inout WaveformCategory) -> Void) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&categories[index])
    }

    // MARK: - Bindings / geometry

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { categories.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in updateCategory(id) { $0.name = newValue } }
        )
    }

    private func windowStartBinding(for id: UUID) -> Binding<Double> {
        Binding(
            get: { categories.first(where: { $0.id == id })?.startMS ?? 0 },
            set: { newValue in updateCategory(id) { $0.startMS = newValue } }
        )
    }

    private func windowEndBinding(for id: UUID) -> Binding<Double> {
        Binding(
            get: { categories.first(where: { $0.id == id })?.endMS ?? 0 },
            set: { newValue in updateCategory(id) { $0.endMS = newValue } }
        )
    }

    private func cursorBinding(max: Int) -> Binding<Int> {
        Binding(
            get: { clampedCursor(max: max) },
            set: { cursorSample = Swift.min(Swift.max($0, 0), max) }
        )
    }

    private func clampedCursor(max: Int) -> Int {
        min(Swift.max(cursorSample, 0), Swift.max(max, 0))
    }

    private func clampedTopomapCursor(max: Int) -> Int {
        min(Swift.max(topomapCursorSample, 0), Swift.max(max, 0))
    }

    private func scheduleTopomapCursorUpdate(_ sample: Int, max: Int) {
        topomapCursorTask?.cancel()
        topomapCursorTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                topomapCursorSample = Swift.min(Swift.max(sample, 0), Swift.max(max, 0))
                topomapCursorTask = nil
            }
        }
    }

    private func refreshTopomapCursorNow(_ sample: Int, max: Int) {
        topomapCursorTask?.cancel()
        topomapCursorSample = Swift.min(Swift.max(sample, 0), Swift.max(max, 0))
        topomapCursorTask = nil
    }

    private func overlayFrame(for category: WaveformCategory, size: CGSize) -> CGRect {
        guard let average else { return .zero }
        let range = WaveformAnalysis.timeRange(
            sampleCount: average.samples.first?.count ?? 0,
            samplingRate: average.samplingRate,
            baselineSamples: average.baselineSamples
        )
        let start = xPosition(forMS: category.orderedWindow.lowerBound, width: size.width, range: range)
        let end = xPosition(forMS: category.orderedWindow.upperBound, width: size.width, range: range)
        return CGRect(x: min(start, end), y: 0, width: max(8, abs(end - start)), height: size.height)
    }

    private func xPosition(forMS ms: Double, width: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let fraction = (ms - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(max(0, min(1, fraction))) * width
    }

    private func msDelta(for translationX: CGFloat, plotWidth: CGFloat, range: ClosedRange<Double>) -> Double {
        guard plotWidth > 0 else { return 0 }
        return Double(translationX / plotWidth) * (range.upperBound - range.lowerBound)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func color(for index: Int) -> Color {
        palette[index % palette.count]
    }

    private func windowLabel(_ category: WaveformCategory) -> String {
        "\(Int(category.orderedWindow.lowerBound.rounded()))-\(Int(category.orderedWindow.upperBound.rounded())) ms"
    }

    // MARK: - Export

    private func schedulePreviewRefresh(delay: Duration = .zero) {
        guard activePlotDrag == nil else { return }
        previewRefreshTask?.cancel()
        if delay == .zero {
            startPreviewRefresh()
            return
        }
        previewRefreshTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                startPreviewRefresh()
            }
        }
    }

    private func refreshPreviewIfIdle() {
        schedulePreviewRefresh()
    }

    private func refreshPreviewNow() {
        previewRefreshTask?.cancel()
        startPreviewRefresh()
    }

    private func startPreviewRefresh() {
        let columns = previewColumns
        let snapshots = previewDatasetSnapshots
        let currentFactorNames = factorNames
        let currentConditionNames = conditionNames
        let currentAdaptivePreMS = adaptivePreMS
        let currentAdaptivePostMS = adaptivePostMS

        previewMetricColumnNames = columns.map(\.title)
        isPreviewTableLoading = true
        previewRefreshTask = Task.detached(priority: .userInitiated) {
            let rows = Self.makePreviewRows(
                snapshots: snapshots,
                factorNames: currentFactorNames,
                conditionNames: currentConditionNames,
                columns: columns,
                adaptivePreMS: currentAdaptivePreMS,
                adaptivePostMS: currentAdaptivePostMS
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewRowsCache = rows
                previewSelection.formIntersection(Set(rows.map(\.id)))
                isPreviewTableLoading = false
                previewRefreshTask = nil
            }
        }
    }

    nonisolated private static func makePreviewRows(snapshots: [WaveformPreviewDatasetSnapshot],
                                                    factorNames: [String],
                                                    conditionNames: [String],
                                                    columns: [WaveformExportColumn],
                                                    adaptivePreMS: Double,
                                                    adaptivePostMS: Double) -> [WaveformExportPreviewRow] {
        snapshots.map { snapshot in
            let baseline = snapshot.conditions.first(where: { conditionNames.contains($0.name) })?.baselineSamples ?? 0
            let averaged = datasetAverage(snapshot, conditionNames: conditionNames)
            let metadata = Dictionary(uniqueKeysWithValues: factorNames.enumerated().map { index, name in
                (name, index < snapshot.levels.count ? snapshot.levels[index] : "")
            })
            let values = Dictionary(uniqueKeysWithValues: columns.map { column in
                let value: String
                if let averaged,
                   let amplitude = WaveformAnalysis.amplitude(
                    samples: averaged,
                    samplingRate: snapshot.samplingRate,
                    baselineSamples: baseline,
                    category: column.category,
                    measure: column.measure,
                    polarity: column.polarity,
                    adaptivePreMS: adaptivePreMS,
                    adaptivePostMS: adaptivePostMS
                   ) {
                    value = WaveformAnalysis.formatExportValue(amplitude)
                } else {
                    value = ""
                }
                return (column.title, value)
            })
            return WaveformExportPreviewRow(
                id: snapshot.id,
                file: snapshot.file,
                metadata: metadata,
                values: values
            )
        }
    }

    nonisolated private static func datasetAverage(_ snapshot: WaveformPreviewDatasetSnapshot,
                                                   conditionNames: [String]) -> [[Float]]? {
        var sum: [[Double]] = []
        var count = 0
        var channelCount = 0
        var sampleCount = 0

        for name in conditionNames {
            guard let condition = snapshot.conditions.first(where: { $0.name == name }),
                  let samples = condition.samples,
                  let first = samples.first,
                  !samples.isEmpty,
                  !first.isEmpty else { continue }

            if sum.isEmpty {
                channelCount = samples.count
                sampleCount = first.count
                sum = Array(repeating: Array(repeating: 0, count: sampleCount), count: channelCount)
            }

            guard samples.count == channelCount, first.count == sampleCount else { continue }
            for channel in 0..<channelCount where samples[channel].count == sampleCount {
                for sample in 0..<sampleCount {
                    sum[channel][sample] += Double(samples[channel][sample])
                }
            }
            count += 1
        }

        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        return sum.map { channel in channel.map { Float($0 * inv) } }
    }

    private func exportCSV() {
        let text = WaveformAnalysis.exportCSV(
            datasets: members,
            factorNames: factorNames,
            conditionNames: conditionNames,
            categories: categories,
            selection: measureSelection,
            polarity: polarity,
            adaptivePreMS: adaptivePreMS,
            adaptivePostMS: adaptivePostMS
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safe(groupLabel))_waveform_measures.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func safe(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.isEmpty ? "study" : trimmed
        return cleaned.replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
    }
}

private struct WaveformPreviewConditionSnapshot: Sendable {
    let name: String
    let samples: [[Float]]?
    let baselineSamples: Int
}

private struct WaveformPreviewDatasetSnapshot: Identifiable, Sendable {
    let id: UUID
    let file: String
    let levels: [String]
    let samplingRate: Double
    let conditions: [WaveformPreviewConditionSnapshot]
}

private struct WaveformExportPreviewRow: Identifiable, Sendable {
    let id: UUID
    let file: String
    let metadata: [String: String]
    let values: [String: String]

    func field(for columnID: String) -> String {
        if columnID == "file" { return file }
        if columnID.hasPrefix("metadata:") {
            let key = String(columnID.dropFirst("metadata:".count))
            return metadata[key] ?? ""
        }
        if columnID.hasPrefix("metric:") {
            let key = String(columnID.dropFirst("metric:".count))
            return values[key] ?? ""
        }
        return ""
    }
}

private struct WaveformExportPreviewTable: NSViewRepresentable {
    let rows: [WaveformExportPreviewRow]
    let metadataColumns: [String]
    let metricColumns: [String]
    @Binding var selection: Set<WaveformExportPreviewRow.ID>

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = NSTableHeaderView()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.configure(rows: rows, metadataColumns: metadataColumns, metricColumns: metricColumns)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.configure(rows: rows, metadataColumns: metadataColumns, metricColumns: metricColumns)
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.syncSelection(in: tableView)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: Binding<Set<WaveformExportPreviewRow.ID>>
        weak var tableView: NSTableView?
        private var rows: [WaveformExportPreviewRow] = []
        private var sortedRows: [WaveformExportPreviewRow] = []
        private var columnIDs: [String] = []
        private var isSyncingSelection = false

        init(selection: Binding<Set<WaveformExportPreviewRow.ID>>) {
            self.selection = selection
        }

        func configure(rows: [WaveformExportPreviewRow], metadataColumns: [String], metricColumns: [String]) {
            self.rows = rows
            let nextColumnIDs = ["file"]
                + metadataColumns.map { "metadata:\($0)" }
                + metricColumns.map { "metric:\($0)" }

            if nextColumnIDs != columnIDs {
                columnIDs = nextColumnIDs
                rebuildColumns(metadataColumns: metadataColumns, metricColumns: metricColumns)
            }

            sortRows()
            tableView?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sortedRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < sortedRows.count, let tableColumn else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("WaveformExportPreviewCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()

            cell.textField?.stringValue = sortedRows[row].field(for: tableColumn.identifier.rawValue)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            let selectedIDs = tableView.selectedRowIndexes.compactMap { index in
                index < sortedRows.count ? sortedRows[index].id : nil
            }
            selection.wrappedValue = Set(selectedIDs)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            sortRows()
            tableView.reloadData()
            syncSelection(in: tableView)
        }

        func syncSelection(in tableView: NSTableView) {
            isSyncingSelection = true
            tableView.deselectAll(nil)
            let indexes = IndexSet(sortedRows.indices.filter { selection.wrappedValue.contains(sortedRows[$0].id) })
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func rebuildColumns(metadataColumns: [String], metricColumns: [String]) {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            addColumn(id: "file", title: "File", width: 170)
            for column in metadataColumns {
                addColumn(id: "metadata:\(column)", title: column, width: 120)
            }
            for column in metricColumns {
                addColumn(id: "metric:\(column)", title: column, width: 170)
            }
        }

        private func addColumn(id: String, title: String, width: CGFloat) {
            guard let tableView else { return }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 80
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            tableView.addTableColumn(column)
        }

        private func sortRows() {
            guard let tableView, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key else {
                sortedRows = rows
                return
            }

            sortedRows = rows.sorted { left, right in
                let comparison = left.field(for: key).localizedStandardCompare(right.field(for: key))
                if comparison == .orderedSame {
                    return left.file.localizedStandardCompare(right.file) == .orderedAscending
                }
                return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
    }
}
