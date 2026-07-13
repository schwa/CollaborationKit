import SwiftUI
import CollaborationKit

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Read-only thumbnails of images the user attached to a prompt, shown inside
/// their transcript bubble.
struct AttachmentThumbnailsView: View {
    let images: [ImageContent]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                thumbnail(for: image)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 6))
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
    }
}
