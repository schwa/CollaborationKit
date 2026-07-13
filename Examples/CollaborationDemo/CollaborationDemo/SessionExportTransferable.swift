import CollaborationKitUI
import CoreTransferable
import UniformTypeIdentifiers

struct SessionExportPayload: Transferable {
    let export: SessionExport
    var suggestedFileName: String = "CollaborationDemo.json"

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { payload in
            try payload.export.jsonData()
        }
        .suggestedFileName { $0.suggestedFileName }
    }
}
