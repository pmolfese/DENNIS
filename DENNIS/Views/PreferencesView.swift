//
//  PreferencesView.swift
//  DENNIS
//
//  App settings for visible analysis tabs.
//

import SwiftUI

struct PreferencesView: View {
    @Environment(AnalysisStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(AppMode.allCases) { mode in
                    Toggle(isOn: Binding(
                        get: { store.isModeVisible(mode) },
                        set: { store.setMode(mode, visible: $0) }
                    )) {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                }
                Button("Restore Defaults") {
                    store.resetVisibleModes()
                }
            } header: {
                Text("Analysis Tabs")
            } footer: {
                Text("Shown tabs appear in the main workspace selector. At least one tab stays visible.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420, height: 360)
    }
}

#Preview {
    PreferencesView()
        .environment(AnalysisStore())
}
