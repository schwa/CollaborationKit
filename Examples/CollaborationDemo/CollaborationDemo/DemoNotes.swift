import Foundation
import Observation
import CollaborationKit

struct Note: Identifiable, Sendable, Equatable, Codable {
    typealias ID = String
    let id: ID
    var title: String
    var body: String
    var tag: Tag?
    var color: NoteColor?
}

enum Tag: String, Codable, CollaborationSchemaConvertible, CaseIterable, Sendable {
    case idea, todo, question, journal, followUp = "follow-up"

    static let collaborationSchema: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(allCases.map { .string($0.rawValue) })
    ])
}

enum NoteColor: String, Codable, CollaborationSchemaConvertible, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    static let collaborationSchema: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(allCases.map { .string($0.rawValue) })
    ])
}

@MainActor
@Observable
@CollaborationTools
final class DemoNotes {
    var notes: [Note] = []
    var nextID: Int = 1

    private func mutate(_ id: Note.ID, _ change: (inout Note) -> Void) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw ToolError("No note with id \(id).")
        }
        change(&notes[index])
    }

    @CollaborationTool("List every note, oldest first, as an array.")
    func list() async -> [Note] {
        notes
    }

    @CollaborationTool("Create a note. Returns the new note's id.")
    func create(title: String, body: String, tag: Tag?) async -> Note.ID {
        let id: Note.ID = "n\(nextID)"
        nextID += 1
        notes.append(Note(id: id, title: title, body: body, tag: tag, color: nil))
        return id
    }

    @CollaborationTool("Case-insensitive substring search over title and body.")
    func search(query: String) async -> [Note] {
        let needle = query.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(needle) || $0.body.lowercased().contains(needle)
        }
    }

    @CollaborationTool("Edit an existing note. Nil fields leave the value unchanged.")
    func edit(id: Note.ID, title: String?, body: String?) async throws {
        try mutate(id) { note in
            if let title { note.title = title }
            if let body { note.body = body }
        }
    }

    @CollaborationTool("Set or clear a note's tag. Pass null to clear.")
    func setTag(id: Note.ID, tag: Tag?) async throws {
        try mutate(id) { $0.tag = tag }
    }

    @CollaborationTool("Set or clear a note's color. Pass null to clear.")
    func setColor(id: Note.ID, color: NoteColor?) async throws {
        try mutate(id) { $0.color = color }
    }

    @CollaborationTool("Delete the note with the given id.", requiresApproval: true)
    func delete(id: Note.ID) async throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw ToolError("No note with id \(id).")
        }
        notes.remove(at: index)
    }
}
