import SwiftUI
import UniformTypeIdentifiers
import CollaborationKitUI

struct SessionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let export: SessionExport

    init(export: SessionExport) {
        self.export = export
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.export = try SessionExport.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try export.jsonData())
    }
}
