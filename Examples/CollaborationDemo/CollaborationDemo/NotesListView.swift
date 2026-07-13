import SwiftUI

struct NotesListView: View {
    let notes: DemoNotes

    var body: some View {
        if notes.notes.isEmpty {
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "note",
                description: Text("Ask the assistant to create one.")
            )
        } else {
            List(notes.notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(note.title).font(.body.weight(.medium))
                        Spacer()
                        Text(note.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    if !note.body.isEmpty {
                        Text(note.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
