import SwiftUI

/// Full-window text editor backed by ``DemoDoc``. The user can freely
/// type; the assistant edits the same buffer through the DemoDoc
/// tools. Assistant edits stay highlighted until the user edits
/// (which invalidates the highlight offsets).
struct DocumentEditorView: View {
    @Bindable var doc: DemoDoc

    /// Attributed mirror of ``DemoDoc.text``. Rebuilt when the doc
    /// text or highlight set changes.
    @State private var attributed = AttributedString()

    var body: some View {
        TextEditor(text: $attributed)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .task(id: docSignature) {
                rebuild()
            }
            .onAppear { rebuild() }
            .onChange(of: attributed) { _, new in
                let plain = String(new.characters)
                if plain != doc.text {
                    doc.userEdit(newText: plain)
                }
            }
    }

    /// Cheap fingerprint of doc state that should force a rebuild.
    /// AttributedString equality is expensive; a length+highlight-id
    /// summary is enough to know a tool edit landed.
    private var docSignature: String {
        var out = "\(doc.text.count):\(doc.highlights.count)"
        if let last = doc.highlights.last {
            out += ":\(last.id.uuidString)"
        }
        return out
    }

    private func rebuild() {
        var attr = AttributedString(doc.text)
        for highlight in doc.highlights {
            guard let range = range(in: attr, offset: highlight.offset, length: highlight.length) else { continue }
            attr[range].backgroundColor = Color.yellow.opacity(0.55)
        }
        // Skip writes when nothing changed — avoids caret jumps.
        if attr == attributed { return }
        attributed = attr
    }

    private func range(
        in attr: AttributedString,
        offset: Int,
        length: Int
    ) -> Range<AttributedString.Index>? {
        let chars = attr.characters
        let total = chars.count
        guard offset >= 0, offset <= total else { return nil }
        let clampedLength = max(length, 1)
        let end = min(total, offset + clampedLength)
        guard end > offset else { return nil }
        let start = chars.index(chars.startIndex, offsetBy: offset)
        let stop = chars.index(chars.startIndex, offsetBy: end)
        return start..<stop
    }
}

#Preview {
    DocumentEditorView(doc: DemoDoc())
        .frame(width: 720, height: 520)
}
