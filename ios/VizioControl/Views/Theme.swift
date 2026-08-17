import SwiftUI

extension Color {
    static let vizioGround = Color(red: 17 / 255, green: 19 / 255, blue: 17 / 255)
    static let vizioSurface = Color(red: 24 / 255, green: 27 / 255, blue: 24 / 255)
    static let vizioRaised = Color(red: 32 / 255, green: 35 / 255, blue: 31 / 255)
    static let vizioText = Color(red: 243 / 255, green: 240 / 255, blue: 232 / 255)
    static let vizioMuted = Color(red: 183 / 255, green: 185 / 255, blue: 175 / 255)
    static let vizioMoss = Color(red: 168 / 255, green: 201 / 255, blue: 107 / 255)
    static let vizioMossStrong = Color(red: 185 / 255, green: 221 / 255, blue: 118 / 255)
    static let vizioDanger = Color(red: 231 / 255, green: 163 / 255, blue: 157 / 255)
}

struct VizioPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.vizioSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct VizioFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Color.vizioText)
            .tint(Color.vizioMossStrong)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color.vizioRaised)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

extension View {
    func vizioPanel() -> some View {
        modifier(VizioPanelModifier())
    }

    func vizioField() -> some View {
        modifier(VizioFieldModifier())
    }

    func minimumControlSize() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.vizioSurface)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .background(configuration.isPressed ? Color.vizioMossStrong : Color.vizioMoss)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct ControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.vizioText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 10)
            .background(configuration.isPressed ? Color.vizioSurface : Color.vizioRaised)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.vizioMossStrong)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(Color.vizioRaised.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct DangerButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.vizioDanger)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(Color.vizioRaised.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}
