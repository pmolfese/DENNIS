//
//  StatisticalAnalysisView.swift
//  DENNIS
//
//  The "Statistical Analysis" mode. Once a dual PCA has been run, this panel
//  lets the user relabel factors, optionally scale factor scores toward
//  microvolts, and export the standard PCA tables (factor scores and loadings)
//  as CSV for external statistical software. In-app analyses will grow here.
//

import SwiftUI
import UniformTypeIdentifiers

/// A trivial CSV document for `.fileExporter`.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct StatisticalAnalysisView: View {
    @Environment(AnalysisStore.self) private var store

    @State private var exportDoc: CSVDocument?
    @State private var exportName = "export"
    @State private var showExporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let bundle = store.dual {
                    content(bundle)
                } else {
                    ContentUnavailableView(
                        "No PCA Results Yet",
                        systemImage: "tablecells",
                        description: Text("Run a Dual PCA in the PCA tab, then return here to "
                                          + "label factors and export tables.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .commaSeparatedText,
            defaultFilename: exportName
        ) { _ in }
    }

    @ViewBuilder
    private func content(_ bundle: AnalysisStore.DualBundle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Statistical Analysis").font(.largeTitle.bold())
            Text("\(bundle.groupLabel) · \(bundle.result.factors.count) factors · "
                 + "\(bundle.subjectNames.count) subjects × \(bundle.conditionNames.count) conditions")
                .foregroundStyle(.secondary)
        }

        exportSection(bundle)
        Divider()
        factorLabelSection(bundle)
    }

    // MARK: - Export

    @ViewBuilder
    private func exportSection(_ bundle: AnalysisStore.DualBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.headline)

            Toggle("Reconstruct factor scores in microvolts (var_sd-scaled loadings)",
                   isOn: Binding(get: { store.scaleToMicrovolts },
                                 set: { store.scaleToMicrovolts = $0 }))
                .toggleStyle(.checkbox)
                .font(.callout)

            if store.scaleToMicrovolts {
                HStack(spacing: 12) {
                    Picker("Measure", selection: Binding(
                        get: { store.microvoltMeasure },
                        set: { store.microvoltMeasure = $0 })) {
                        ForEach(AnalysisStore.MicrovoltMeasure.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    if store.microvoltMeasure == .meanWindow {
                        Text("Window (ms):").font(.caption).foregroundStyle(.secondary)
                        TextField("start", value: Binding(get: { store.windowStartMS },
                                                          set: { store.windowStartMS = $0 }),
                                  format: .number)
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("–").foregroundStyle(.secondary)
                        TextField("end", value: Binding(get: { store.windowEndMS },
                                                        set: { store.windowEndMS = $0 }),
                                  format: .number)
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.leading, 20)
            }

            HStack(spacing: 12) {
                Button {
                    present(CSVBuilders.factorScores(
                        bundle, microvolts: store.scaleToMicrovolts,
                        measure: store.microvoltMeasure,
                        windowStartMS: store.windowStartMS, windowEndMS: store.windowEndMS,
                        label: store.label),
                            name: "\(safe(bundle.groupLabel))_factor_scores")
                } label: { Label("Factor Scores", systemImage: "tablecells") }

                Button {
                    present(CSVBuilders.temporalLoadings(bundle, label: store.label),
                            name: "\(safe(bundle.groupLabel))_temporal_loadings")
                } label: { Label("Temporal Loadings", systemImage: "waveform") }

                Button {
                    present(CSVBuilders.spatialLoadings(bundle, label: store.label),
                            name: "\(safe(bundle.groupLabel))_spatial_loadings")
                } label: { Label("Spatial Loadings", systemImage: "circle.grid.cross") }
            }
            .buttonStyle(.bordered)

            Text("Factor scores are exported as one row per subject, one column per "
                 + "factor × condition. Loadings export time points (temporal) and channels "
                 + "(spatial) against each factor.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func present(_ text: String, name: String) {
        exportDoc = CSVDocument(text: text)
        exportName = name
        showExporter = true
    }

    private func safe(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.isEmpty ? "study" : trimmed
        return cleaned.replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
    }

    // MARK: - Relabeling

    @ViewBuilder
    private func factorLabelSection(_ bundle: AnalysisStore.DualBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Factor Labels").font(.headline)
            Text("Rename factors (e.g. \"P300\") — labels are used in exports.")
                .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Factor").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Label").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Variance").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(bundle.result.factors.enumerated()), id: \.offset) { _, factor in
                    GridRow {
                        Text(factor.name).font(.callout.monospaced())
                        TextField("Label", text: Binding(
                            get: { store.factorLabels[factor.name] ?? "" },
                            set: { store.factorLabels[factor.name] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        Text(String(format: "%.1f%%", factor.variance * 100))
                            .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }
}
