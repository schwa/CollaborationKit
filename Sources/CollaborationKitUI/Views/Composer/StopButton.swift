import SwiftUI

/// A circular stop button with an indeterminate spinning ring around it,
/// matching Xcode's "generating" control. Tap to cancel the in-flight turn.
///
/// Ported from Phosphor.
public struct StopButton: View {
    public var action: () -> Void

    @State private var spinning = false

    private let size: CGFloat = 22
    private let lineWidth: CGFloat = 2.5

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.tint.opacity(0.2), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)

                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.primary)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .accessibilityLabel("Stop")
        .onAppear { spinning = true }
    }
}

#Preview("Stop button") {
    StopButton {}
        .padding()
}
