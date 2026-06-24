//
//  StatisticalAnalysisView.swift
//  DENNIS
//
//  The "Statistical Analysis" mode. Once a dual PCA has been run, this panel
//  lets the user relabel factors (labels are reused by the matrix exports on the
//  PCA tab). In-app analyses will grow here.
//

import SwiftUI

struct StatisticalAnalysisView: View {
    @Environment(AnalysisStore.self) private var store

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
                                          + "label factors.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func content(_ bundle: AnalysisStore.DualBundle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Statistical Analysis").font(.largeTitle.bold())
            Text("\(bundle.groupLabel) · \(bundle.result.factors.count) factors · "
                 + "\(bundle.subjectNames.count) subjects × \(bundle.conditionNames.count) conditions")
                .foregroundStyle(.secondary)
        }

        factorLabelSection(bundle)
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
