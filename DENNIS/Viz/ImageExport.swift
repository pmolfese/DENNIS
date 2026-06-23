//
//  ImageExport.swift
//  DENNIS
//
//  Renders a SwiftUI view to a PNG and saves it via the system save panel. Used
//  to export plots (scree, factor loadings, topographies) as images.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImageExport {
    /// Render `view` to a PNG at `scale`× and prompt the user for a destination.
    static func savePNG<V: View>(_ view: V, suggestedName: String, scale: CGFloat = 2) {
        let renderer = ImageRenderer(
            content: view
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = scale
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}
