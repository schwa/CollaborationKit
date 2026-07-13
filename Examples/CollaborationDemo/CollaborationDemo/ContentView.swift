import SwiftUI
import CollaborationKit
import CollaborationKitUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials
    @State private var notes = DemoNotes()
    @State private var store: ConversationStore?
    @State private var buildError: String?
    @State private var showAssistant: Bool = true
    @State private var editing: EditingNote?

    private struct EditingNote: Identifiable {
        let id: Note.ID
    }

    var body: some View {
        NotesListView(
            notes: notes,
            onSelect: { editing = EditingNote(id: $0) },
            onDelete: { id in notes.notes.removeAll { $0.id == id } }
        )
        .navigationTitle("Notes")
        .inspector(isPresented: $showAssistant) { assistant }
        .toolbar {
            Button {
                let id: Note.ID = "n\(notes.nextID)"
                notes.nextID += 1
                notes.notes.append(Note(id: id, title: "", body: "", tag: nil, color: nil))
                editing = EditingNote(id: id)
            } label: {
                Label("New Note", systemImage: "plus")
            }
            Button {
                showAssistant.toggle()
            } label: {
                Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .sheet(item: $editing) { editing in
            if let index = notes.notes.firstIndex(where: { $0.id == editing.id }) {
                NoteEditor(
                    note: $notes.notes[index],
                    onDelete: {
                        notes.notes.remove(at: index)
                        self.editing = nil
                    },
                    onDismiss: { self.editing = nil }
                )
            }
        }
        .task(id: "\(credentials.backend.rawValue)-\(credentials.hasCredentials)") { rebuild() }
    }

    @ViewBuilder
    private var assistant: some View {
        if let store {
            CollaborationChatView(store: store, composerBorderStyle: .glow)
        } else if let buildError {
            ContentUnavailableView("Couldn't Start Chat", systemImage: "exclamationmark.triangle", description: Text(buildError))
        } else {
            ContentUnavailableView {
                Label("Sign in to Chat", systemImage: "key.horizontal")
            } description: {
                Text("Add credentials in Settings (⌘,).")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        }
    }

    private func rebuild() {
        store = nil
        buildError = nil
        guard credentials.hasCredentials else { return }
        do {
            let provider = try credentials.makeProvider()
            let session = LLMSession(
                provider: provider,
                system: """
                You help the user manage a small list of notes. Notes have a title, body, optional tag \
                (idea, todo, question, journal, follow-up), and optional color (red, orange, yellow, green, \
                blue, purple, pink). Use the list, search, create, edit, setTag, setColor, and delete tools. \
                Prefer setTag and setColor to make notes visually distinct when it helps the user scan them.
                """,
                tools: notes.collaborationTools
            )
            self.store = ConversationStore(session: session)
        } catch {
            buildError = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .environment(CollaborationCredentials())
        .frame(width: 720, height: 520)
}
