import CollaborationKit
import CollaborationKitUI
import SwiftUI

struct ContentView: View {
    @Environment(CollaborationCredentials.self)
    private var credentials
    @State private var notes = DemoNotes()
    @State private var sketch = DemoSketch()
    // Per-tab stores keep each surface's tool set isolated so tool names
    // (list, delete, …) can't collide across DemoNotes and DemoSketch —
    // Anthropic rejects a request whose tools[] contains duplicates.
    @State private var notesStore: ConversationStore?
    @State private var sketchStore: ConversationStore?
    @State private var buildError: String?
    @State private var showAssistant: Bool = true
    @State private var editing: EditingNote?
    @State private var approvals = ApprovalGate()
    @State private var selectedTab: DemoTab = .notes

    private struct EditingNote: Identifiable {
        let id: Note.ID
    }

    enum DemoTab: Hashable {
        case notes
        case sketch
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NotesListView(
                notes: notes,
                onSelect: { editing = EditingNote(id: $0) },
                onDelete: { id in notes.notes.removeAll { $0.id == id } }
            )
            .tabItem { Label("Notes", systemImage: "note.text") }
            .tag(DemoTab.notes)

            SketchCanvasView(sketch: sketch)
                .tabItem { Label("Sketch", systemImage: "scribble") }
                .tag(DemoTab.sketch)
        }
        .navigationTitle(selectedTab == .notes ? "Notes" : "Sketch")
        .inspector(isPresented: $showAssistant) { assistant }
        .toolbar {
            if selectedTab == .notes {
                Button {
                    let id: Note.ID = "n\(notes.nextID)"
                    notes.nextID += 1
                    notes.notes.append(Note(id: id, title: "", body: "", tag: nil, color: nil))
                    editing = EditingNote(id: id)
                } label: {
                    Label("New Note", systemImage: "plus")
                }
            }
            Button {
                showAssistant.toggle()
            } label: {
                Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
            }
            if let store = activeStore {
                ShareLink(
                    item: SessionExportPayload(
                        export: store.buildExport(model: credentials.selectedModel),
                        suggestedFileName: "CollaborationDemo-\(selectedTab.exportSlug)-\(Int(Date().timeIntervalSince1970)).json"
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

    private var activeStore: ConversationStore? {
        switch selectedTab {
        case .notes: notesStore
        case .sketch: sketchStore
        }
    }

    @ViewBuilder private var assistant: some View {
        if let store = activeStore {
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
        notesStore = nil
        sketchStore = nil
        buildError = nil
        guard credentials.hasCredentials else { return }
        do {
            let provider = try credentials.makeProvider()
            let approve: @Sendable (ToolUse) async -> ToolApprovalDecision = { [approvals] use in
                await approvals.request(use)
            }

            let notesSession = LLMSession(
                provider: provider,
                system: """
                IMPORTANT: You're the Notes surface of an app called "DemoApp". The user keeps a \
                small list of notes with title, body, optional tag (idea, todo, question, journal, \
                follow-up), and optional color (red, orange, yellow, green, blue, purple, pink). \
                Use the list, search, create, edit, setTag, setColor, and delete tools. Prefer \
                setTag and setColor to make notes visually distinct when it helps the user scan them.
                """,
                tools: notes.collaborationTools,
                approval: approve
            )
            notesStore = ConversationStore(session: notesSession)

            let sketchSession = LLMSession(
                provider: provider,
                system: """
                IMPORTANT: You're the Sketch surface of an app called "DemoApp". The user has a \
                square canvas they can draw on freehand. You can add shapes (addLine, addRectangle, \
                addEllipse, addPath), change the background (setBackground), inspect the current \
                shapes (list), undo the last shape, delete one by id, or clear the whole canvas. \
                All canvas coordinates are in the 0–1 unit square with the top-left as the origin. \
                Prefer thin strokes (width 0.003–0.008) unless the user asks for something bold.
                """,
                tools: sketch.collaborationTools,
                approval: approve
            )
            sketchStore = ConversationStore(session: sketchSession)
        } catch {
            buildError = error.localizedDescription
        }
    }
}

private extension ContentView.DemoTab {
    var exportSlug: String {
        switch self {
        case .notes: "notes"
        case .sketch: "sketch"
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
