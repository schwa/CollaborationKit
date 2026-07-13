import CollaborationKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A drag/export wrapper around an ``ImageContent`` that carries a suggested
/// filename and the correct on-disk media type.
///
/// Uses `FileRepresentation` writing to a temporary file so the drop target
/// or export panel receives real bytes with a real extension — matching the
/// image's actual `mediaType` — instead of a static, single-type
/// `DataRepresentation` that can't vary at runtime.
struct ImageContentTransfer: Transferable, Sendable {
    let content: ImageContent
    let suggestedName: String

    var data: Data { Data(base64Encoded: content.base64Data) ?? Data() }

    var contentType: UTType {
        // Fall back to .image whenever the MIME lookup fails or returns a
        // dynamic type that isn't recognized as an image (unknown
        // `image/...` MIMEs sometimes yield a dynamic UTType that doesn't
        // conform to .image), so drop targets filtering on .image always
        // accept us.
        if let type = UTType(mimeType: content.mediaType), type.conforms(to: .image) {
            return type
        }
        return .image
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { transfer in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CollaborationKit-Drag", isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let url = dir.appendingPathComponent(transfer.suggestedName)
            try transfer.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.suggestedName }
    }
}

extension ImageContent {
    /// A best-effort filename for exporting/dragging this image, using the
    /// media type's preferred file extension and a caller-supplied index so
    /// multiple attachments in the same message get distinct names.
    func suggestedFilename(index: Int) -> String {
        let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "png"
        return "attachment-\(index + 1).\(ext)"
    }
}
