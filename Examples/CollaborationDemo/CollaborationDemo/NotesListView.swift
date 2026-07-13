import SwiftUI

/// Renders the current contents of a ``DemoNotes`` store live, so a viewer can
/// watch the assistant's tool calls take effect.
struct NotesListView: View {
    let notes: DemoNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                Text("\(notes.notes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear", systemImage: "trash") { notes.removeAll() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(notes.notes.isEmpty)
                    .help("Clear all notes (host-side; the assistant will still remember them until you tell it otherwise).")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary)

            Divider()

            if notes.notes.isEmpty {
                ContentUnavailableView {
                    Label("No Notes Yet", systemImage: "note")
                } description: {
                    Text("Ask the assistant to create a note.")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(notes.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(note.title)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(note.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            if !note.body.isEmpty {
                                Text(note.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
