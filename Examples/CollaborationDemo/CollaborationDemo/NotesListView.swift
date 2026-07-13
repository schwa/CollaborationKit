import SwiftUI

struct NotesListView: View {
    let notes: DemoNotes
    var onSelect: (Note.ID) -> Void
    var onDelete: (Note.ID) -> Void

    var body: some View {
        if notes.notes.isEmpty {
            ContentUnavailableView(
                "No Notes Yet",
                systemImage: "note",
                description: Text("Add one with + or ask the assistant.")
            )
        } else {
            List {
                ForEach(notes.notes) { note in
                    Button {
                        onSelect(note.id)
                    } label: {
                        row(for: note)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") { onSelect(note.id) }
                        Button("Delete", role: .destructive) { onDelete(note.id) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { onDelete(note.id) }
                    }
                }
            }
        }
    }

    private func row(for note: Note) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(color(for: note.color)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                    Spacer()
                    Text(note.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if !note.body.isEmpty {
                    Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let tag = note.tag {
                    Label(tag.rawValue, systemImage: icon(for: tag))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: .capsule)
                }
            }
        }
    }

    private func color(for color: NoteColor?) -> Color {
        switch color {
        case .red:
            .red

        case .orange:
            .orange

        case .yellow:
            .yellow

        case .green:
            .green

        case .blue:
            .blue

        case .purple:
            .purple

        case .pink:
            .pink

        case nil:
            .clear
        }
    }

    private func icon(for tag: Tag) -> String {
        switch tag {
        case .idea:
            "lightbulb"

        case .todo:
            "checklist"

        case .question:
            "questionmark.circle"

        case .journal:
            "book"

        case .followUp:
            "arrow.forward.circle"
        }
    }
}

#Preview("Empty") {
    NotesListView(notes: DemoNotes(), onSelect: { _ in }, onDelete: { _ in })
}

#Preview("Populated") {
    let notes = DemoNotes()
    notes.notes = [
        Note(id: "n1", title: "Groceries", body: "eggs, milk, bread", tag: .todo, color: .green),
        Note(id: "n2", title: "Idea", body: "Notes app that talks back.", tag: .idea, color: .yellow),
        Note(id: "n3", title: "Blocked?", body: "Follow up with Alice.", tag: .followUp, color: .orange)
    ]
    return NotesListView(notes: notes, onSelect: { _ in }, onDelete: { _ in })
}
