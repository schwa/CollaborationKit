import CollaborationKit
import SwiftUI
import UniformTypeIdentifiers

/// The pending-attachment thumbnail strip shown above the composer text
/// field, each with a remove button. Tapping a thumbnail opens a popover
/// with the full-size image so the user can verify what they're about to
/// send. Thumbnails are also draggable — drop them into Finder or another
/// app to export the underlying file bytes.
struct ComposerAttachmentsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    @State private var previewID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    thumbnail(for: attachment)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func thumbnail(for attachment: Attachment) -> some View {
        Button {
            previewID = attachment.id
        } label: {
            attachment.image
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .draggable(
            ImageContentTransfer(
                content: attachment.content,
                suggestedName: attachment.filename
            )
        )
        .popover(
            isPresented: Binding(
                get: { previewID == attachment.id },
                set: { if !$0 { previewID = nil } }
            )
        ) {
            ComposerAttachmentPreview(attachment: attachment)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove attachment")
            .accessibilityHint("Remove \(attachment.filename) from the message.")
        }
        .help(attachment.filename)
        .accessibilityLabel("Attachment: \(attachment.filename)")
        .accessibilityHint("View full-size image.")
    }
}

/// Popover preview of a pending composer attachment. Uses the SwiftUI
/// `Image` the ``Attachment`` already built at pick time so decoding
/// happens once. Includes a Save… button that writes the underlying
/// file bytes with the correct extension.
private struct ComposerAttachmentPreview: View {
    let attachment: Attachment

    @State private var isExporting = false

    private var contentType: UTType {
        UTType(mimeType: attachment.content.mediaType) ?? .image
    }

    var body: some View {
        VStack(spacing: 8) {
            attachment.image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480, maxHeight: 480)
                .accessibilityLabel("Attached image: \(attachment.filename)")

            HStack {
                Spacer()
                Button("Save\u{2026}") { isExporting = true }
            }
        }
        .padding()
        .fileExporter(
            isPresented: $isExporting,
            item: ImageContentTransfer(
                content: attachment.content,
                suggestedName: attachment.filename
            ),
            contentTypes: [contentType],
            defaultFilename: attachment.filename
        ) { _ in }
    }
}

#Preview {
    ComposerAttachmentsView(attachments: []) { _ in }
        .padding()
}
