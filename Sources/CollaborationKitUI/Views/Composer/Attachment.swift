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
