//
//  PCAExportView.swift
//  DENNIS
//
//  Matrix-export controls for a completed dual PCA: factor scores and temporal /
//  spatial loadings as CSV, with an optional microvolt reconstruction. Hosted at
//  the bottom of the PCA tab. (A future "Send to Statistics" button will hand
//  these tables to the stats module directly.)
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PCAExportView: View {
    @Environment(AnalysisStore.self) private var store
    let bundle: AnalysisStore.DualBundle

    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Matrices").font(.headline)

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
                    save(CSVBuilders.factorScores(
                        bundle, microvolts: store.scaleToMicrovolts,
                        measure: store.microvoltMeasure,
                        windowStartMS: store.windowStartMS, windowEndMS: store.windowEndMS,
                        label: store.label),
                         name: "\(safe(bundle.groupLabel))_factor_scores")
                } label: { Label("Factor Scores", systemImage: "tablecells") }
                .help("One row per subject, one column per factor × condition. "
                      + "Uses labels set in the Statistical Analysis tab.")

                Button {
                    save(CSVBuilders.temporalLoadings(bundle, label: store.label),
                         name: "\(safe(bundle.groupLabel))_temporal_loadings")
                } label: { Label("Temporal Loadings", systemImage: "waveform") }
                .help("One row per time point, one column per temporal factor loading.")

                Button {
                    save(CSVBuilders.spatialLoadings(bundle, label: store.label),
                         name: "\(safe(bundle.groupLabel))_spatial_loadings")
                } label: { Label("Spatial Loadings", systemImage: "circle.grid.cross") }
                .help("One row per channel, one column per combined factor's spatial loading.")
            }
            .buttonStyle(.bordered)
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Save CSV text via a native save panel. Powerbox grants write access to the
    /// chosen file, so this works under the app sandbox.
    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).csv"
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
