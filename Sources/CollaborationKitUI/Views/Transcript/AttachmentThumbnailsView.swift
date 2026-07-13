import CollaborationKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Read-only thumbnails of images the user attached to a prompt, shown inside
/// their transcript bubble.
///
/// Tapping a thumbnail opens a modal preview of the full-size image so the
/// user can inspect what they actually sent — the 64pt thumbnail is usually
/// too small to read screenshots.
struct AttachmentThumbnailsView: View {
    let images: [ImageContent]

    @State private var preview: PreviewItem?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                Button {
                    preview = PreviewItem(index: index, image: image)
                } label: {
                    thumbnail(for: image)
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attached image")
                .accessibilityHint("View full-size image.")
            }
        }
        .sheet(item: $preview) { item in
            AttachmentPreviewView(image: item.image) {
                preview = nil
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

    /// Identity wrapper so `sheet(item:)` can distinguish attachments with
    /// identical bytes at different positions in the same message.
    private struct PreviewItem: Identifiable {
        let index: Int
        let image: ImageContent
        var id: Int { index }
    }
}

/// Full-size attachment preview shown from ``AttachmentThumbnailsView``.
/// Fits the image inside the sheet without cropping and offers a Done button.
private struct AttachmentPreviewView: View {
    let image: ImageContent
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            fullImage
                .frame(minWidth: 320, minHeight: 240)
                .padding()

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(maxWidth: 720, maxHeight: 720)
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
