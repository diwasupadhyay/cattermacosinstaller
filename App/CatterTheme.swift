import SwiftUI

enum CatterTheme {
    static let background = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let surface = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
    static let accent = Color(red: 215 / 255, green: 215 / 255, blue: 215 / 255)
    static let cornerRadius: CGFloat = 18
}

struct CatterWordmark: View {
    var size: CGFloat = 32

    var body: some View {
        HStack(spacing: 9) {
            Image("CatterLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 4))
                .accessibilityHidden(true)
            Text("Catter").font(.headline)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CatterPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(CatterTheme.background)
            .background(CatterTheme.accent, in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
