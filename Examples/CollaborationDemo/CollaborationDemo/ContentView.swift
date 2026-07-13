import CollaborationKit
import CollaborationKitUI
import SwiftUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self)
    private var credentials
    @State private var notes = DemoNotes()
    @State private var store: ConversationStore?
    @State private var buildError: String?
    @State private var showAssistant: Bool = true
    @State private var editing: EditingNote?
    @State private var approvals = ApprovalGate()

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
            if let store {
                ShareLink(
                    item: SessionExportPayload(
                        export: store.buildExport(model: credentials.selectedModel),
                        suggestedFileName: "CollaborationDemo-\(Int(Date().timeIntervalSince1970)).json"
                    ),
                    preview: SharePreview("Session Log", image: Image(systemName: "doc.text"))
                ) {
                    Label("Export Log", systemImage: "square.and.arrow.up")
                }
            }
        }
        .alert(
            "Allow tool call?",
            isPresented: Binding(
                get: { approvals.pending != nil },
                set: { presented in
                    // Dismissing without picking a button = deny.
                    if !presented { approvals.resolve(.deny) }
                }
            ),
            presenting: approvals.pending
        ) { _ in
            Button("Allow") { approvals.resolve(.allow) }
            Button("Deny", role: .destructive) { approvals.resolve(.deny) }
        } message: { pending in
            Text("The assistant wants to run “\(pending.use.name)” with input:\n\n\(prettyInput(pending.use.input))")
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
        .task(id: "\(credentials.backend.id)-\(credentials.hasCredentials)") { rebuild() }
    }

    @ViewBuilder private var assistant: some View {
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
                IMPORTANT: You're an app called "DemoApp".
                You help the user manage a small list of notes. Notes have a title, body, optional tag \
                (idea, todo, question, journal, follow-up), and optional color (red, orange, yellow, green, \
                blue, purple, pink). Use the list, search, create, edit, setTag, setColor, and delete tools. \
                Prefer setTag and setColor to make notes visually distinct when it helps the user scan them.
                """,
                tools: notes.collaborationTools,
                approval: { [approvals] use in
                    await approvals.request(use)
                }
            )
            self.store = ConversationStore(session: session)
        } catch {
            buildError = error.localizedDescription
        }
    }
}

// MARK: - Approval formatting

/// Pretty-prints a tool's JSON input for the approval alert. Uses
/// JSONEncoder with pretty printing when possible; falls back to the
/// default reflection description if encoding fails (shouldn't happen
/// for well-formed JSONValues, but the alert must never crash).
private func prettyInput(_ input: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(input),
          let string = String(data: data, encoding: .utf8) else {
        return String(describing: input)
    }
    return string
}

#Preview {
    ContentView()
        .environment(CollaborationCredentials())
        .frame(width: 720, height: 520)
}
