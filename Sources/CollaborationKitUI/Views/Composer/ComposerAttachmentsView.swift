import SwiftUI

/// The pending-attachment thumbnail strip shown above the composer text
/// field, each with a remove button.
struct ComposerAttachmentsView: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachment.image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(.rect(cornerRadius: 6))
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
                }
            }
            .padding(.vertical, 2)
        }
    }
}
