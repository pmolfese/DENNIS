//
//  HelpButton.swift
//  DENNIS
//
//  Small popover buttons for in-context help: a "?" for a short explanatory
//  blurb, and a "References" button for the published methods a mode rests on
//  (see `References.swift` for the citation list itself).
//

import SwiftUI

struct HelpButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("What is this?")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(width: 320)
        }
    }
}

/// A "References" button that opens the full citation list for one mode, each
/// entry paired with what in DENNIS it supports. Shared by every mode with a
/// published method behind it, so the citations live in one place
/// (`References.swift`) and every pane presents them the same way.
struct ReferencesButton: View {
    let title: String
    let intro: String
    let references: [Reference]
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Label("References", systemImage: "book")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("The published methods this pane implements.")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.headline)
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(references) { reference in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reference.citation)
                                .font(.callout)
                            Text(reference.supports)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(16)
                .frame(width: 460, alignment: .leading)
            }
            .frame(maxHeight: 560)
        }
    }
}
