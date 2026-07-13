import SwiftUI

/// A soft, multicolor gradient border reminiscent of Xcode's Coding
/// Intelligence prompt field. The gradient slowly rotates; when `active` it
/// becomes brighter/thicker and grows a subtle glow to signal focus.
///
/// Opt-in per ``ComposerView`` via `borderStyle: .glow`, or applied by hosts
/// directly through ``SwiftUICore/View/glowingPromptBorder(cornerRadius:active:)``.
///
/// Ported from Phosphor.
public struct GlowingPromptBorder: ViewModifier {
    public var cornerRadius: CGFloat
    public var active: Bool

    @State private var rotation: Angle = .zero

    @Environment(\.colorScheme)
    private var colorScheme

    public init(cornerRadius: CGFloat = 16, active: Bool = false) {
        self.cornerRadius = cornerRadius
        self.active = active
    }

    private var palette: [Color] {
        [.pink, .purple, .blue, .teal, .green, .orange, .pink]
    }

    public func body(content: Content) -> some View {
        content
            .background(fieldBackground, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: active ? 2 : 1)
            }
            .shadow(color: glowColor.opacity(active ? 0.35 : 0), radius: active ? 10 : 0)
            .animation(.easeInOut(duration: 0.25), value: active)
            .onAppear {
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
            }
    }

    private var border: AngularGradient {
        AngularGradient(
            colors: active ? palette : palette.map { $0.opacity(0.45) },
            center: .center,
            angle: rotation
        )
    }

    private var glowColor: Color { .purple }

    /// A high-contrast text-entry background that stands out from the
    /// surrounding composer material in both light and dark mode.
    private var fieldBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.55) : Color.white
    }
}

extension View {
    /// Wraps the view in an Xcode-style glowing multicolor prompt border.
    ///
    /// Set `active` to `true` on focus to brighten the border and add a
    /// subtle glow.
    public func glowingPromptBorder(cornerRadius: CGFloat = 16, active: Bool = false) -> some View {
        modifier(GlowingPromptBorder(cornerRadius: cornerRadius, active: active))
    }
}
