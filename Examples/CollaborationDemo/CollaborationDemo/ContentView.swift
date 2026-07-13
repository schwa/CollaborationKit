import SwiftUI
import CollaborationKit
import CollaborationKitUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials
    @State private var chat: ChatSession?
    @State private var buildError: String?
    @State private var notes = DemoNotes()
    @State private var inspectorShown: Bool = true

    var body: some View {
        NotesListView(notes: notes)
            .frame(minWidth: 320, minHeight: 400)
            .inspector(isPresented: $inspectorShown) {
                assistantInspector
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 640)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        inspectorShown.toggle()
                    } label: {
                        Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .help("Show or hide the assistant.")
                }
            }
            .task(id: taskKey) { rebuildChat() }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var assistantInspector: some View {
        if let chat {
            CollaborationChatView(store: chat.store)
        } else if let buildError {
            ContentUnavailableView {
                Label("Couldn't Start Chat", systemImage: "exclamationmark.triangle")
            } description: {
                Text(buildError)
            }
        } else {
            ContentUnavailableView {
                Label("Sign in to Chat", systemImage: "key.horizontal")
            } description: {
                Text("Add credentials for \(credentials.backend.displayName) in Settings (⌘,).")
            } actions: {
                #if os(macOS)
                SettingsLink { Text("Open Settings…") }
                #endif
            }
        }
    }

    // MARK: - Chat lifecycle

    private var taskKey: String {
        "\(credentials.backend.rawValue)-\(credentials.hasCredentials)"
    }

    private func rebuildChat() {
        chat = nil
        buildError = nil
        guard credentials.hasCredentials else { return }
        do {
            chat = try ChatSession(credentials: credentials, notes: notes)
        } catch {
            buildError = error.localizedDescription
        }
    }
}

/// Holds the `LLMSession` + `ConversationStore` for one chat window so both
/// stay alive together. Wires the `DemoNotes` tools into the session so the
/// assistant can list, create, delete, and count notes.
@MainActor
private final class ChatSession {
    let session: LLMSession
    let store: ConversationStore

    init(credentials: CollaborationCredentials, notes: DemoNotes) throws {
        let provider = try credentials.makeProvider(maxTokens: 4_096)
        self.session = LLMSession(
            provider: provider,
            system: """
            You are a helpful assistant collaborating with the user through a small notes app. \
            Use the `list`, `create`, `delete`, and `count` tools to manage the user's notes. \
            Always confirm what you did in a short reply.
            """,
            tools: notes.collaborationTools
        )
        self.store = ConversationStore(session: session)
    }
}
