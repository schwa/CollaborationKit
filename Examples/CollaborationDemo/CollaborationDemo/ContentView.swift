import SwiftUI
import CollaborationKit
import CollaborationKitUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials
    @State private var notes = DemoNotes()
    @State private var session: LLMSession?
    @State private var store: ConversationStore?
    @State private var buildError: String?
    @State private var showAssistant: Bool = true

    var body: some View {
        NotesListView(notes: notes)
            .navigationTitle("Notes")
            .inspector(isPresented: $showAssistant) { assistant }
            .toolbar {
                Button {
                    showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
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
        session = nil
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
                blue, purple, pink). Use the list, search, create, setTag, setColor, and delete tools. \
                Prefer setTag and setColor to make notes visually distinct when it helps the user scan them.
                """,
                tools: notes.collaborationTools
            )
            self.session = session
            self.store = ConversationStore(session: session)
        } catch {
            buildError = error.localizedDescription
        }
    }
}
