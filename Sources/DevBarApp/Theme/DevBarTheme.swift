import AppKit
import SwiftUI

enum DevBarTheme {
    static let interactionAnimation = Animation.easeOut(duration: 0.12)
    static let stateAnimation = Animation.smooth(duration: 0.24)
    static let background = adaptive(
        light: NSColor(srgbRed: 0.973, green: 0.988, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.027, green: 0.063, blue: 0.098, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.76),
        dark: NSColor(srgbRed: 0.055, green: 0.125, blue: 0.195, alpha: 0.88)
    )
    static let surfaceStrong = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9),
        dark: NSColor(srgbRed: 0.075, green: 0.16, blue: 0.24, alpha: 0.94)
    )
    static let surfaceSubtle = adaptive(
        light: NSColor(srgbRed: 0.925, green: 0.97, blue: 1, alpha: 0.76),
        dark: NSColor(srgbRed: 0.04, green: 0.105, blue: 0.17, alpha: 0.82)
    )
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let separator = adaptive(
        light: NSColor(srgbRed: 0.76, green: 0.86, blue: 0.94, alpha: 1),
        dark: NSColor(srgbRed: 0.16, green: 0.29, blue: 0.40, alpha: 1)
    )
    static let accentStart = Color(red: 0.22, green: 0.65, blue: 1.0)
    static let accentMiddle = Color(red: 0.12, green: 0.46, blue: 0.96)
    static let accentEnd = Color(red: 0.20, green: 0.72, blue: 0.68)
    static let auroraBlue = adaptive(
        light: NSColor(srgbRed: 0.48, green: 0.78, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.10, green: 0.48, blue: 0.88, alpha: 1)
    )
    static let auroraMint = adaptive(
        light: NSColor(srgbRed: 0.50, green: 0.92, blue: 0.86, alpha: 1),
        dark: NSColor(srgbRed: 0.12, green: 0.67, blue: 0.62, alpha: 1)
    )
    static let accent = LinearGradient(
        colors: [accentStart, accentMiddle, accentEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let majorRadius: CGFloat = 18
    static let controlRadius: CGFloat = 9
    static let panelPadding: CGFloat = 16
    static let surfaceShadow = adaptive(
        light: NSColor(srgbRed: 0.06, green: 0.28, blue: 0.48, alpha: 0.10),
        dark: NSColor.black.withAlphaComponent(0.30)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Gives custom plain buttons immediate tactile feedback without delaying their action.
struct DevBarPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : DevBarTheme.interactionAnimation,
                value: configuration.isPressed
            )
    }
}

struct DevBarIcon: View {
    let size: CGFloat

    private static let image: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon-master", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return NSApp.applicationIconImage }
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Color {
    init(devBarHex value: String, fallback: Color = DevBarTheme.accentMiddle) {
        let text = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard text.count == 6, let number = UInt64(text, radix: 16) else {
            self = fallback
            return
        }
        self = Color(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
        )
    }
}
