//
//  HelpButton.swift
//  DENNIS
//
//  A small circular "?" button that reveals an explanatory blurb in a popover,
//  keeping section descriptions out of the main layout.
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
