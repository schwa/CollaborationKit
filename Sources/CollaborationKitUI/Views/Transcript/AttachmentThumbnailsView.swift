import CollaborationKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Read-only thumbnails of images the user attached to a prompt, shown inside
/// their transcript bubble.
///
/// Tapping a thumbnail opens a popover anchored to that thumbnail with the
/// full-size image so the user can inspect what they actually sent — the
/// 64pt thumbnail is usually too small to read screenshots.
struct AttachmentThumbnailsView: View {
    let images: [ImageContent]

    @State private var previewIndex: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                Button {
                    previewIndex = index
                } label: {
                    thumbnail(for: image)
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attached image")
                .accessibilityHint("View full-size image.")
                .draggable(
                    ImageContentTransfer(
                        content: image,
                        suggestedName: image.suggestedFilename(index: index)
                    )
                )
                .popover(
                    isPresented: Binding(
                        get: { previewIndex == index },
                        set: { if !$0 { previewIndex = nil } }
                    )
                ) {
                    AttachmentPreviewView(
                        image: image,
                        suggestedName: image.suggestedFilename(index: index)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for image: ImageContent) -> some View {
        #if canImport(AppKit)
        if let data = Data(base64Encoded: image.base64Data),
           let ns = NSImage(data: data) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
        #elseif canImport(UIKit)
        if let data = Data(base64Encoded: image.base64Data),
           let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Image unavailable")
    }

}

/// Full-size attachment preview shown from ``AttachmentThumbnailsView`` as a
/// popover. Fits the image inside a bounded frame; the popover chrome
/// provides its own dismissal (tap outside / Esc). A Save… button lets the
/// user export the underlying file bytes.
private struct AttachmentPreviewView: View {
    let image: ImageContent
    let suggestedName: String

    @State private var isExporting = false

    private var contentType: UTType {
        UTType(mimeType: image.mediaType) ?? .image
    }

    var body: some View {
        VStack(spacing: 8) {
            fullImage
                .frame(minWidth: 320, minHeight: 240)
                .frame(maxWidth: 720, maxHeight: 720)

            HStack {
                Spacer()
                Button("Save\u{2026}") { isExporting = true }
            }
        }
        .padding()
        .fileExporter(
            isPresented: $isExporting,
            item: ImageContentTransfer(content: image, suggestedName: suggestedName),
            contentTypes: [contentType],
            defaultFilename: suggestedName
        ) { _ in }
    }

    @ViewBuilder
    private var fullImage: some View {
        #if canImport(AppKit)
        if let data = Data(base64Encoded: image.base64Data),
           let ns = NSImage(data: data) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Attached image")
        } else {
            unavailable
        }
        #elseif canImport(UIKit)
        if let data = Data(base64Encoded: image.base64Data),
           let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Attached image")
        } else {
            unavailable
        }
        #else
        unavailable
        #endif
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Image unavailable",
            systemImage: "photo",
            description: Text("The attachment couldn't be decoded.")
        )
    }
}

#Preview {
    AttachmentThumbnailsView(images: [])
        .padding()
}
