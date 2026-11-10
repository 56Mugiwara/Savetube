import SwiftUI

struct GlassSurface: View {
    var radius: CGFloat = 100
    var highlighted = false
    var focused = false
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(.clear.tint(theme.accent.opacity(highlighted ? 0.05 : 0.012)).interactive(), in: shape)
            } else {
                shape.fill(LinearGradient(colors: [Color(white: highlighted ? 0.14 : 0.07), Color(white: 0.025), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.fill(theme.accent.opacity(highlighted ? 0.08 : 0.025)))
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06), .white.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
        }
        .overlay(shape.strokeBorder(theme.accent.opacity(focused ? 0.55 : 0), lineWidth: 1.5))
        .shadow(color: theme.accent.opacity(focused ? 0.07 : 0), radius: 9)
    }
}

struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 16) { content() } }
        else { content() }
    }
}

struct GlassPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

/// Size changes precede material application so the system redraws the lens at
/// its expanded geometry instead of stretching a rendered glass texture.
struct SegmentLens: View {
    var width: CGFloat
    var height: CGFloat
    let namespace: Namespace.ID
    var dragging: Bool
    var title: String
    var small: Bool
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        if #available(macOS 26.0, *) {
            Text(title).font(.system(size: small ? 10 : 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: width, height: height)
                .glassEffect(.clear.tint(theme.accent.opacity(dragging ? 0.045 : 0.012)).interactive(), in: .capsule)
                .glassEffectID("selection-lens", in: namespace)
                .glassEffectTransition(.matchedGeometry)
                .shadow(color: .black.opacity(dragging ? 0.32 : 0.1), radius: dragging ? 10 : 3, y: dragging ? 5 : 1)
        } else {
            Text(title).font(.system(size: small ? 10 : 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: width, height: height).background(GlassSurface(highlighted: true))
        }
    }
}

/// Apply material to the content itself: native glass stays behind its labels.
struct ClearGlassControl: ViewModifier {
    var radius: CGFloat = 100
    var prominent = false
    var panel = false
    var focused = false
    @ObservedObject private var theme = ThemeStore.shared
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                content
                    .background { if panel { shape.fill(Color.black.opacity(0.33)) } }
                    .glassEffect(.clear.tint(prominent ? .white.opacity(0.85) : theme.accent.opacity(panel ? 0.035 : 0.012)).interactive(), in: shape)
            } else {
                content.background(GlassSurface(radius: radius, highlighted: prominent))
            }
        }.overlay(shape.strokeBorder(Color.white.opacity(focused ? 0.5 : 0), lineWidth: 1.3))
    }
}

struct ClearGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .modifier(ClearGlassControl())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
