@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing
import UniformTypeIdentifiers

/// Tests for the drag/export data helpers added for #84.
@Suite("ImageContent drag/export helpers (#84)")
struct ImageContentTransferTests {
    @Test("Round-trips base64 data unchanged for drag export")
    func transferDataMatchesOriginalBytes() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let content = ImageContent(mediaType: "image/png", data: bytes)
        let transfer = ImageContentTransfer(content: content, suggestedName: "x.png")
        #expect(transfer.data == bytes)
    }

    @Test("Content type maps a known MIME type to the matching UTType")
    func contentTypePng() {
        let content = ImageContent(mediaType: "image/png", data: Data())
        let transfer = ImageContentTransfer(content: content, suggestedName: "x.png")
        #expect(transfer.contentType == .png)
    }

    @Test("Content type conforms to .image for an unknown MIME type")
    func contentTypeUnknownConformsToImage() {
        // Unknown MIMEs may synthesize a dynamic UTType that doesn't
        // conform to .image; the transfer type clamps the result so drop
        // targets filtering on .image always accept us.
        let content = ImageContent(mediaType: "image/x-not-real", data: Data())
        let transfer = ImageContentTransfer(content: content, suggestedName: "x.bin")
        #expect(transfer.contentType.conforms(to: .image))
    }

    @Test("suggestedFilename uses the media type's preferred extension and a 1-based index")
    func suggestedFilenameUsesMediaTypeExtension() {
        let png = ImageContent(mediaType: "image/png", data: Data())
        #expect(png.suggestedFilename(index: 0) == "attachment-1.png")
        let jpg = ImageContent(mediaType: "image/jpeg", data: Data())
        #expect(jpg.suggestedFilename(index: 2) == "attachment-3.jpeg")
    }

    @Test("suggestedFilename falls back to .png for unknown media types")
    func suggestedFilenameUnknownFallsBackToPng() {
        let unknown = ImageContent(mediaType: "image/x-not-real", data: Data())
        #expect(unknown.suggestedFilename(index: 0) == "attachment-1.png")
    }
}
