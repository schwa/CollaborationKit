import Foundation
import Observation
import CollaborationKit

@MainActor
@Observable
@CollaborationTools
final class DemoNotes {
    struct Note: Identifiable, Sendable, Equatable, Codable {
        typealias ID = String
        let id: ID
        var title: String
        var body: String
    }

    private(set) var notes: [Note] = []
    private var nextID: Int = 1

    @CollaborationTool("List every note, oldest first, as a JSON array of {id, title, body}.")
    func list() async -> [Note] {
        notes
    }

    @CollaborationTool("Create a note. Returns the new note's id.")
    func create(title: String, body: String) async -> Note.ID {
        let id: Note.ID = "n\(nextID)"
        nextID += 1
        notes.append(Note(id: id, title: title, body: body))
        return id
    }

    @CollaborationTool("Delete the note with the given id.", requiresApproval: true)
    func delete(id: Note.ID) async throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw ToolError("No note with id \(id).")
        }
        notes.remove(at: index)
    }
}
