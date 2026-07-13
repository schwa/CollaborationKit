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
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(color(for: note.color))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
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
        }
    }

    private func color(for color: NoteColor?) -> Color {
        switch color {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case nil: .clear
        }
    }

    private func icon(for tag: Tag) -> String {
        switch tag {
        case .idea: "lightbulb"
        case .todo: "checklist"
        case .question: "questionmark.circle"
        case .journal: "book"
        case .followUp: "arrow.forward.circle"
        }
    }
}
