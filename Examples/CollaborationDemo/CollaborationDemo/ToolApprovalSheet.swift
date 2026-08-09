import CollaborationKit
import SwiftUI

/// The tool-approval confirmation, presented as a sheet instead of a stock
/// `.alert`.
///
/// An alert can only show a single `Text` body, which forced a raw escaped
/// JSON dump into the message (#108). A sheet can lay the call out properly:
/// the tool name in the title, one row per argument with the value in
/// monospaced text, and the payload scrolled rather than allowed to grow the
/// dialog without bound.
struct ToolApprovalSheet: View {
    let use: ToolUse
    let onAllow: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            arguments
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .frame(maxHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow tool call?")
                    .font(.headline)
                Text("The assistant wants to run \(Text(use.name).font(.body.monospaced())).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var arguments: some View {
        if argumentRows.isEmpty {
            Text("No arguments.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(argumentRows, id: \.key) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.key)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.4)
                            Text(row.value)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }

    private var buttons: some View {
        HStack {
            Button("Deny", role: .destructive) { onDeny() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Always Allow") { onAllowAlways() }
            Button("Allow") { onAllow() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// One row per top-level key of an object input; a single unnamed row
    /// for scalar or array inputs, which the built-in tools don't use but
    /// a host tool might.
    private var argumentRows: [(key: String, value: String)] {
        guard case .object(let fields) = use.input else {
            let rendered = Self.render(use.input)
            return rendered.isEmpty ? [] : [(key: "input", value: rendered)]
        }
        return fields
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: Self.render($0.value)) }
    }

    /// Renders a value for display: strings unquoted and unescaped (the
    /// whole point — the alert used to show `\"…\n…\"`), everything else
    /// as pretty JSON.
    static func render(_ value: JSONValue) -> String {
        switch value {
        case .string(let text):
            return text

        case .null:
            return "null"

        case .bool(let flag):
            return flag ? "true" : "false"

        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)

        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value),
                  let string = String(data: data, encoding: .utf8) else {
                return String(describing: value)
            }
            return string
        }
    }
}

#Preview {
    ToolApprovalSheet(
        use: ToolUse(
            id: "preview",
            name: "rewrite",
            input: .object([
                "path": .string("notes/standup.md"),
                "contents": .string("# Standup\n\n- shipped the approval sheet\n- next: token readout")
            ])
        ),
        onAllow: {},
        onAllowAlways: {},
        onDeny: {}
    )
}
