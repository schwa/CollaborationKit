import CollaborationKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A pending image attachment in the composer: the wire-ready
/// ``ImageContent`` plus a thumbnail for display and a filename for
/// accessibility.
struct Attachment: Identifiable {
    let id = UUID()
    let content: ImageContent
    let image: Image
    let filename: String

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        #if canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        self.content = ImageContent(mediaType: mediaType, data: data)
        self.image = Image(nsImage: ns)
        #elseif canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        self.content = ImageContent(mediaType: mediaType, data: data)
        self.image = Image(uiImage: ui)
        #else
        return nil
        #endif
        self.filename = url.lastPathComponent
    }
}

/// Shared, observable holder for pending composer attachments.
///
/// ``ComposerView`` owns one of these by default. When multiple sibling views
/// (e.g. a transcript that accepts image drops) need to add attachments into
/// the composer, the parent supplies a shared instance via the environment.
@MainActor
@Observable
final class ComposerAttachmentBuffer {
    var attachments: [Attachment] = []

    func add(urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let attachment = Attachment(url: url) else { continue }
            attachments.append(attachment)
        }
    }

    func remove(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func clear() {
        attachments.removeAll()
    }
}

extension EnvironmentValues {
    /// Optional external buffer that receives programmatically-added
    /// attachments (e.g. from a transcript drop destination). When set,
    /// ``ComposerView`` reads and writes this buffer instead of its private
    /// one, so drops routed into it appear in the composer's attachment
    /// strip.
    @Entry var composerAttachmentBuffer: ComposerAttachmentBuffer? = nil
}
