//
//  PLSView.swift
//  DENNIS
//
//  The PLS tab for a selected group. Assembles the group's ERP averages into a
//  brain-data matrix (observations = subject × condition, features = channel ×
//  time), runs a mean-centered (task) PLS, and optionally the permutation /
//  bootstrap inference layer. Mirrors TensorView's shape: parameters on the
//  left, a Run button, and a results summary.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PLSView: View {
    @Environment(Study.self) private var study
    let groupID: String

    @State private var method: PLSMethod = .meanCentered
    @State private var meanCentering: MeanCenteringType = .withinGroupCondition
    @State private var runPermutation = true
    @State private var permIterations = 500
    @State private var runBootstrap = true
    @State private var bootIterations = 500

    // Behavior PLS: per-subject measures loaded from a CSV keyed by dataset name.
    @State private var behaviorMeasures: [String] = []
    @State private var behaviorTable: [String: [Double]] = [:]
    @State private var behaviorFileName: String?
    /// Selected CSV measures (indices into `behaviorMeasures`); nil = all.
    @State private var selectedMeasures: Set<Int>? = nil
    /// Selected behavior-block conditions for multiblock `bscan` (indices into
    /// `commonConditions`); nil = all.
    @State private var selectedConditions: Set<Int>? = nil

    @State private var result: PLSResult?
    /// Row labels for the design saliences (one per group × condition cell),
    /// captured at run time so the readout survives later selection changes.
    @State private var cellLabels: [String] = []
    /// Brain-space metadata captured at run time so saliences can be unfolded
    /// back into channel × time topographies and waveforms.
    @State private var brainMeta: BrainMeta?
    @State private var lvIndex = 0
    @State private var cursorSample = 0
    @State private var showBootstrapMap = false
    @State private var running = false
    @State private var progress = RunProgress()
    @State private var errorText: String?

    /// Everything needed to map a brain salience (length nChannels·nTimes) back
    /// into scalp space and time.
    private struct BrainMeta {
        let nChannels: Int
        let nTimes: Int
        let samplingRate: Double
        let baselineSamples: Int
        let layout: SensorLayout?
    }

    private var members: [Dataset] { study.datasets(inGroupID: groupID) }

    /// A between-subject group in the PLS design.
    private struct PLSGroup { let id: String; let label: String; let datasets: [Dataset] }

    /// The groups this run compares: the immediate child groups of the selected
    /// node, or the node itself when it is a leaf (a single-group run).
    private var plsGroups: [PLSGroup] {
        let children = study.childGroups(ofGroupID: groupID)
        if children.isEmpty {
            return [PLSGroup(id: groupID, label: groupLabel, datasets: members)]
        }
        return children.map { PLSGroup(id: $0.id, label: $0.label, datasets: $0.datasets) }
    }

    private var groupLabel: String {
        groupID.isEmpty ? study.name : (groupID.split(separator: "/").last.map(String.init) ?? groupID)
    }

    /// Methods that need a behavior CSV (behavior block).
    private var needsBehavior: Bool { method == .behavior || method == .multiblock }
    /// Methods with a task block that honors the mean-centering choice.
    private var usesMeanCentering: Bool { method == .meanCentered || method == .multiblock }

    /// Conditions shared by every group (intersection), preserving order.
    private var commonConditions: [String] {
        let lists = plsGroups.map { study.sharedConditionNames(inGroupID: $0.id) }
        guard let first = lists.first else { return [] }
        return lists.dropFirst().reduce(first) { acc, list in acc.filter(list.contains) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if let errorText { Text(errorText).foregroundStyle(.red).font(.callout) }
                if let result { summary(result) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Method", selection: $method) {
                    ForEach(PLSMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                HelpButton(text: Self.methodHelp)
            }
            Text(method.blurb).font(.callout).foregroundStyle(.secondary)

            Text(groupSummary).font(.callout).foregroundStyle(.secondary)

            if usesMeanCentering {
                HStack {
                    Picker("Mean-centering", selection: $meanCentering) {
                        ForEach(MeanCenteringType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    HelpButton(text: Self.meanCenteringHelp)
                }
            }

            if needsBehavior {
                HStack {
                    Button("Load behavior CSV…") { loadBehaviorCSV() }
                    if let behaviorFileName {
                        Text("\(behaviorFileName) — \(behaviorMeasures.count) measure\(behaviorMeasures.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("CSV: first column = dataset name, then one column per measure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HelpButton(text: Self.behaviorHelp)
                }

                if !behaviorMeasures.isEmpty {
                    multiSelect(
                        title: "Behavior measures",
                        labels: behaviorMeasures,
                        selection: $selectedMeasures,
                        help: Self.measureSelectHelp)
                }
                if method == .multiblock {
                    multiSelect(
                        title: "Behavior conditions (bscan)",
                        labels: commonConditions,
                        selection: $selectedConditions,
                        help: Self.bscanHelp)
                }
            }

            Toggle(isOn: $runPermutation) {
                HStack {
                    Text("Permutation test")
                    Stepper("\(permIterations) iters", value: $permIterations, in: 100...5000, step: 100)
                        .fixedSize()
                        .disabled(!runPermutation)
                    HelpButton(text: Self.permutationHelp)
                }
            }
            Toggle(isOn: $runBootstrap) {
                HStack {
                    Text("Bootstrap ratios")
                    Stepper("\(bootIterations) iters", value: $bootIterations, in: 100...5000, step: 100)
                        .fixedSize()
                        .disabled(!runBootstrap)
                    HelpButton(text: Self.bootstrapHelp)
                }
            }

            HStack {
                Button("Run PLS") { run() }
                    .disabled(commonConditions.isEmpty || plsGroups.isEmpty || running)
            }

            if running {
                ProgressView(value: progress.fraction) {
                    Text(progress.stage.isEmpty ? "Working…" : progress.stage)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: 360)
            }
        }
    }

    @ViewBuilder
    private func summary(_ r: PLSResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latent variables").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("LV").bold()
                    Text("Singular value").bold()
                    Text("Cross-block %").bold()
                    if r.permutationP != nil { Text("p (perm)").bold() }
                }
                ForEach(Array(r.s.enumerated()), id: \.offset) { i, sv in
                    GridRow {
                        Text("\(i + 1)")
                        Text(String(format: "%.4g", sv))
                        Text(String(format: "%.1f%%", r.crossblockCovariance[i] * 100))
                        if let p = r.permutationP { Text(String(format: "%.3f", p[i])) }
                    }
                }
            }
            if r.bootstrapRatios != nil {
                Text("Bootstrap ratios computed: \(r.u.rows) features × \(r.u.cols) LVs")
                    .font(.caption).foregroundStyle(.secondary)
            }

            designSaliences(r)
            salienceExplorer(r)
        }
    }

    /// Unfold a latent variable's brain salience (or its bootstrap ratios) back
    /// into scalp space and time: a waveform of every channel's salience over
    /// time with a draggable time cursor, and the topography at that instant.
    @ViewBuilder
    private func salienceExplorer(_ r: PLSResult) -> some View {
        if let meta = brainMeta, r.u.rows == meta.nChannels * meta.nTimes, r.u.cols > 0 {
            let lv = min(lvIndex, r.u.cols - 1)
            let source = (showBootstrapMap ? r.bootstrapRatios : r.u) ?? r.u
            let channelsSamples = Self.reshape(source, lv: lv, meta: meta)
            let cursor = min(max(cursorSample, 0), meta.nTimes - 1)
            let topoValues = (0..<meta.nChannels).map { ch in
                source[ch * meta.nTimes + cursor, lv]
            }
            let scale = topoValues.reduce(0) { Swift.max($0, abs($1)) }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spatiotemporal salience").font(.headline)
                    HelpButton(text: Self.explorerHelp)
                }

                HStack {
                    if r.u.cols > 1 {
                        Picker("LV", selection: $lvIndex) {
                            ForEach(0..<r.u.cols, id: \.self) { Text("LV\($0 + 1)").tag($0) }
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    if r.bootstrapRatios != nil {
                        Toggle("Bootstrap ratios", isOn: $showBootstrapMap)
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }

                ERPWaveformView(
                    samples: channelsSamples,
                    samplingRate: meta.samplingRate,
                    baselineSamples: meta.baselineSamples,
                    cursorSample: cursorBinding(maxSample: meta.nTimes - 1))
                .frame(height: 200)

                Text(String(format: "t = %.0f ms", Self.timeMS(cursor, meta: meta)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()

                if let layout = meta.layout {
                    TopomapView(
                        layout: layout,
                        values: topoValues,
                        timeSeconds: Self.timeMS(cursor, meta: meta) / 1000,
                        fixedScale: scale > 0 ? scale : nil,
                        highlightThreshold: showBootstrapMap ? 2 : nil)
                    .frame(maxWidth: 320)
                } else {
                    Text("No sensor layout available for a topography.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func cursorBinding(maxSample: Int) -> Binding<Int> {
        Binding(
            get: { Swift.min(Swift.max(cursorSample, 0), maxSample) },
            set: { cursorSample = $0 })
    }

    /// `channels × samples` Float view of one LV's column of `matrix`
    /// (`feature = channel * nTimes + time`).
    private static func reshape(_ matrix: Matrix, lv: Int, meta: BrainMeta) -> [[Float]] {
        (0..<meta.nChannels).map { ch in
            (0..<meta.nTimes).map { t in Float(matrix[ch * meta.nTimes + t, lv]) }
        }
    }

    private static func timeMS(_ sample: Int, meta: BrainMeta) -> Double {
        guard meta.samplingRate > 0 else { return Double(sample) }
        return Double(sample - meta.baselineSamples) / meta.samplingRate * 1000
    }

    /// The design saliences `v`: how each group × condition cell weights onto
    /// each latent variable. The readout that gives an LV its meaning.
    @ViewBuilder
    private func designSaliences(_ r: PLSResult) -> some View {
        let lvCount = min(r.v.cols, 5)
        if r.v.rows == cellLabels.count, lvCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Design saliences").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow {
                        Text("Cell").bold()
                        ForEach(0..<lvCount, id: \.self) { l in Text("LV\(l + 1)").bold() }
                    }
                    ForEach(Array(cellLabels.enumerated()), id: \.offset) { row, label in
                        GridRow {
                            Text(label)
                            ForEach(0..<lvCount, id: \.self) { l in
                                Text(String(format: "%.3f", r.v[row, l]))
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// A wrapping grid of checkboxes over `labels`, backed by an optional index
    /// set where `nil` means "all selected". An "All / None" shortcut sits in
    /// the header.
    @ViewBuilder
    private func multiSelect(
        title: String, labels: [String],
        selection: Binding<Set<Int>?>, help: String
    ) -> some View {
        let allOn = selection.wrappedValue == nil || selection.wrappedValue?.count == labels.count
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).bold()
                Button(allOn ? "None" : "All") {
                    selection.wrappedValue = allOn ? [] : nil
                }
                .buttonStyle(.link).font(.caption)
                HelpButton(text: help)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                      alignment: .leading, spacing: 2) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    Toggle(label, isOn: memberBinding(selection, index: i, count: labels.count))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Bind one checkbox to membership in an optional index set (nil = all).
    private func memberBinding(_ selection: Binding<Set<Int>?>, index: Int, count: Int) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue?.contains(index) ?? true },
            set: { on in
                var s = selection.wrappedValue ?? Set(0..<count)
                if on { s.insert(index) } else { s.remove(index) }
                selection.wrappedValue = s
            })
    }

    /// Resolve an optional index set (nil = all) to a sorted concrete list.
    private static func resolve(_ selection: Set<Int>?, count: Int) -> [Int] {
        (selection ?? Set(0..<count)).sorted()
    }

    private var groupSummary: String {
        let groups = plsGroups
        let conds = commonConditions
        let groupPart = groups.count <= 1
            ? "1 group"
            : "\(groups.count) groups (\(groups.map(\.label).joined(separator: ", ")))"
        return "\(groupPart) · \(conds.count) shared condition\(conds.count == 1 ? "" : "s")"
    }

    // MARK: - Run

    private func run() {
        let method = self.method
        let centering = self.meanCentering
        let groups = plsGroups
        let conditions = commonConditions
        guard !conditions.isEmpty else {
            errorText = "No conditions are shared across the selected groups."
            return
        }

        // One ERP snapshot per group at the shared conditions, plus the ordered
        // subject (dataset) names for behavior alignment.
        var snapshots: [EPTensor.Input] = []
        var subjectNames: [[String]] = []
        for g in groups {
            guard let snapshot = EPTensor.snapshot(datasets: g.datasets, conditionNames: conditions) else {
                errorText = "Group \"\(g.label)\" has no subjects sharing all conditions."
                return
            }
            snapshots.append(snapshot.input)
            subjectNames.append(snapshot.subjects.map(\.name))
        }
        // Brain features must align across groups to stack into one matrix.
        guard let ref = snapshots.first else { return }
        guard snapshots.allSatisfy({ $0.nChannels == ref.nChannels && $0.nTimes == ref.nTimes }) else {
            errorText = "Groups differ in channel/time dimensions; cannot combine."
            return
        }
        let meta = BrainMeta(
            nChannels: ref.nChannels, nTimes: ref.nTimes,
            samplingRate: ref.samplingRate, baselineSamples: ref.baselineSamples,
            layout: groups.flatMap(\.datasets).compactMap(\.sensorLayout).first)

        // Behavior / multiblock: validate and assemble the per-observation matrix.
        var behavior: Matrix?
        var activeMeasures: [String] = []
        var bscan: [Int]? = nil
        if needsBehavior {
            guard !behaviorMeasures.isEmpty else {
                errorText = "Load a behavior CSV before running \(method.rawValue) PLS."
                return
            }
            let measureIdx = PLSView.resolve(selectedMeasures, count: behaviorMeasures.count)
            guard !measureIdx.isEmpty else {
                errorText = "Select at least one behavior measure."
                return
            }
            activeMeasures = measureIdx.map { behaviorMeasures[$0] }

            let missing = subjectNames.flatMap { $0 }.filter { behaviorTable[$0] == nil }
            guard missing.isEmpty else {
                errorText = "No behavior data for: \(missing.joined(separator: ", "))"
                return
            }
            behavior = PLSView.makeBehavior(
                groups: snapshots, subjectNames: subjectNames,
                conditions: conditions.count, table: behaviorTable, measureIndices: measureIdx)

            if method == .multiblock {
                let bscanIdx = PLSView.resolve(selectedConditions, count: conditions.count)
                guard !bscanIdx.isEmpty else {
                    errorText = "Select at least one behavior condition (bscan)."
                    return
                }
                bscan = bscanIdx
            }
        }

        var input = PLSView.makeInput(groups: snapshots, behavior: behavior)
        input.bscanConditions = bscan

        // Label every cross-block row in the same order the engine stacks them.
        let multiGroup = groups.count > 1
        let cellLabel: (PLSGroup, String) -> String = { g, cond in
            multiGroup ? "\(g.label) · \(cond)" : cond
        }
        let bscanConditions = (bscan ?? Array(conditions.indices)).map { conditions[$0] }
        let labels: [String]
        switch method {
        case .behavior:
            labels = groups.flatMap { g in
                conditions.flatMap { cond in
                    activeMeasures.map { "\(cellLabel(g, cond)) · \($0)" }
                }
            }
        case .multiblock:
            // Per group: task rows (every condition) then behavior rows
            // (bscan condition × measure) — matching multiblockMatrix's order.
            labels = groups.flatMap { g in
                conditions.map { "\(cellLabel(g, $0)) · task" }
                    + bscanConditions.flatMap { cond in
                        activeMeasures.map { "\(cellLabel(g, cond)) · \($0)" }
                    }
            }
        default:
            labels = groups.flatMap { g in conditions.map { cellLabel(g, $0) } }
        }
        let doPerm = runPermutation, permIters = permIterations
        let doBoot = runBootstrap, bootIters = bootIterations
        let report = progress.handler()

        // Split the bar between the two resampling stages when both run.
        let permSpan = doPerm ? (doBoot ? 0.5 : 0.95) : 0.0
        let bootStart = 0.05 + permSpan

        running = true
        progress.reset()
        errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                report(0.02, "Decomposing…")
                var res = try PLS.decompose(input, method: method, meanCentering: centering)
                if doPerm {
                    res.permutationP = PLS.permutationTest(
                        input, observed: res, meanCentering: centering, iterations: permIters
                    ) { f, stage in report(0.05 + permSpan * f, stage) }
                }
                if doBoot {
                    res.bootstrapRatios = PLS.bootstrapRatios(
                        input, observed: res, meanCentering: centering, iterations: bootIters
                    ) { f, stage in report(bootStart + (0.95 - permSpan) * f, stage) }
                }
                report(1.0, "Done")
                let final = res
                await MainActor.run {
                    self.result = final
                    self.cellLabels = labels
                    self.brainMeta = meta
                    self.lvIndex = 0
                    self.cursorSample = meta.baselineSamples
                    self.showBootstrapMap = final.bootstrapRatios != nil
                    self.running = false
                }
            } catch PLS.PLSError.notImplemented(let m) {
                await MainActor.run {
                    self.errorText = "\(m.rawValue) PLS is not implemented yet."
                    self.running = false
                }
            } catch {
                await MainActor.run { self.errorText = "\(error)"; self.running = false }
            }
        }
    }

    /// Flatten one ERP snapshot per group (`[subject][cell][channel][time]`)
    /// into a combined PLS input: one observation row per subject × condition,
    /// features = channels × times, with global subject indices across groups.
    /// All snapshots are assumed to share `nChannels`, `nTimes`, and conditions.
    private static func makeInput(groups: [EPTensor.Input], behavior: Matrix? = nil) -> PLSInput {
        let ref = groups[0]
        let nConditions = ref.conditionCount
        let nFeatures = ref.nChannels * ref.nTimes
        let totalSubjects = groups.reduce(0) { $0 + $1.subjects.count }
        let nObs = totalSubjects * nConditions

        var data = Matrix(rows: nObs, cols: nFeatures)
        var groupOfRow = [Int](repeating: 0, count: nObs)
        var conditionOfRow = [Int](repeating: 0, count: nObs)
        var subjectOfRow = [Int](repeating: 0, count: nObs)

        var row = 0
        var subjectBase = 0
        for (gIdx, input) in groups.enumerated() {
            for s in 0..<input.subjects.count {
                for cond in 0..<nConditions {
                    let trace = input.subjects[s][cond]   // channels × times
                    var f = 0
                    for ch in 0..<input.nChannels {
                        let times = ch < trace.count ? trace[ch] : []
                        for t in 0..<input.nTimes {
                            data[row, f] = t < times.count ? Double(times[t]) : 0
                            f += 1
                        }
                    }
                    groupOfRow[row] = gIdx
                    conditionOfRow[row] = cond
                    subjectOfRow[row] = subjectBase + s
                    row += 1
                }
            }
            subjectBase += input.subjects.count
        }

        return PLSInput(
            data: data,
            groupOfRow: groupOfRow,
            conditionOfRow: conditionOfRow,
            subjectOfRow: subjectOfRow,
            nGroups: groups.count,
            nConditions: nConditions,
            nSubjects: totalSubjects,
            behavior: behavior,
            contrasts: nil
        )
    }

    /// Behavior matrix aligned to `makeInput`'s row order: one row per subject ×
    /// condition, each subject's measures repeated across conditions. Callers
    /// must have validated that every name in `subjectNames` is in `table`.
    private static func makeBehavior(
        groups: [EPTensor.Input], subjectNames: [[String]],
        conditions: Int, table: [String: [Double]], measureIndices: [Int]
    ) -> Matrix {
        let totalSubjects = groups.reduce(0) { $0 + $1.subjects.count }
        var m = Matrix(rows: totalSubjects * conditions, cols: measureIndices.count)
        var row = 0
        for (gIdx, input) in groups.enumerated() {
            for s in 0..<input.subjects.count {
                let values = table[subjectNames[gIdx][s]] ?? []
                for _ in 0..<conditions {
                    for (col, mi) in measureIndices.enumerated() {
                        m[row, col] = mi < values.count ? values[mi] : .nan
                    }
                    row += 1
                }
            }
        }
        return m
    }

    // MARK: - Help text

    private static let methodHelp = """
    PLS finds latent variables (LVs) — paired brain and design patterns — that \
    capture the most covariance between your ERP data and an experimental \
    design or behavior.

    • Mean-centered task: which spatiotemporal pattern best separates conditions/groups.
    • Behavior: which brain pattern covaries with a behavioral measure.

    Each LV has a singular value (effect size), a brain salience (the pattern), \
    and a design salience (how each condition/group/measure weights onto it).
    """

    private static let meanCenteringHelp = """
    How condition means are centered before the decomposition:

    • Within-group condition: removes each group's overall mean → boosts \
    condition differences (the usual choice).
    • Grand condition: removes the across-group condition mean → boosts group \
    differences.
    • Grand mean: removes one overall mean → full spectrum of effects.
    • Remove main effects: subtracts both group and condition means → pure \
    group × condition interaction.

    The last two are only meaningful with more than one group.
    """

    private static let permutationHelp = """
    Tests whether each LV is stronger than chance. The design labels are \
    reshuffled many times and the decomposition re-run; an LV's p-value is the \
    fraction of permutations whose singular value meets or exceeds the observed \
    one. 500–1000 iterations is typical. Runs in parallel across CPU cores.
    """

    private static let bootstrapHelp = """
    Estimates how reliable each feature's brain salience is. Subjects are \
    resampled with replacement many times; the bootstrap ratio is the salience \
    divided by its bootstrap standard error (like a z-score). |ratio| > ~2 (≈95%) \
    or > ~3 marks stable features. Runs in parallel across CPU cores.
    """

    private static let measureSelectHelp = """
    Choose which columns from the behavior CSV to include. Only the selected \
    measures contribute to the behavior block; deselect ones you don't want in \
    this analysis.
    """

    private static let bscanHelp = """
    bscan — the conditions whose brain × behavior correlations form the behavior \
    block of multiblock PLS. The task block always uses every condition; the \
    behavior block uses only those selected here (the toolbox default is all).
    """

    private static let explorerHelp = """
    A latent variable's brain salience is a value for every channel × time \
    point, so it maps straight back onto the data. The waveform shows each \
    channel's salience over time; drag the cursor to pick an instant and the \
    topography shows the scalp pattern there.

    Switch to bootstrap ratios for the reliable pattern: values are \
    salience ÷ bootstrap SE, and the topography highlights |ratio| > 2 (≈95%).
    """

    private static let behaviorHelp = """
    Behavior PLS needs one row per subject. Provide a CSV whose first column is \
    the dataset name (matching the sidebar) and whose remaining columns are \
    named behavioral measures (RT, accuracy, scores…). Every subject in the \
    selected groups must have a row.
    """

    // MARK: - Behavior CSV

    private func loadBehaviorCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let parsed = PLSView.parseBehaviorCSV(url) else {
            errorText = "Could not parse \(url.lastPathComponent) as a behavior CSV."
            return
        }
        behaviorMeasures = parsed.measures
        behaviorTable = parsed.table
        behaviorFileName = url.lastPathComponent
        selectedMeasures = nil   // default: all measures
        errorText = nil
    }

    /// Parse a CSV whose first column is the dataset name and remaining columns
    /// are named behavioral measures (header row required).
    private static func parseBehaviorCSV(_ url: URL) -> (measures: [String], table: [String: [Double]])? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { return nil }

        let header = lines[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard header.count > 1 else { return nil }
        let measures = Array(header.dropFirst())

        var table: [String: [Double]] = [:]
        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 2 else { continue }
            let name = cols[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            table[name] = (1..<header.count).map { i in
                i < cols.count ? (Double(cols[i].trimmingCharacters(in: .whitespaces)) ?? .nan) : .nan
            }
        }
        return table.isEmpty ? nil : (measures, table)
    }
}
