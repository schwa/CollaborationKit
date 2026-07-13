import SwiftUI

struct NoteEditor: View {
    @Binding var note: Note
    var onDelete: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $note.title)
                TextField("Body", text: $note.body, axis: .vertical)
                    .lineLimit(4...12)
            }
            Section("Tag") {
                Picker("Tag", selection: $note.tag) {
                    Text("None").tag(Tag?.none)
                    ForEach(Tag.allCases, id: \.self) { tag in
                        Text(tag.rawValue).tag(Tag?.some(tag))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Color") {
                Picker("Color", selection: $note.color) {
                    Text("None").tag(NoteColor?.none)
                    ForEach(NoteColor.allCases, id: \.self) { color in
                        Text(color.rawValue).tag(NoteColor?.some(color))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive, action: onDelete)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
    }
}
