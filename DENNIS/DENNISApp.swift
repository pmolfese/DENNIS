//
//  DENNISApp.swift
//  DENNIS
//
//  Created by Molfese, Peter  [E] on 6/23/26.
//

import SwiftUI

@main
struct DENNISApp: App {
    @State private var study = Study()
    @State private var importer = StudyImporter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(study)
                .environment(importer)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
