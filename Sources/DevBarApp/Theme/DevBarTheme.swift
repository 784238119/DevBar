import AppKit
import SwiftUI

enum DevBarTheme {
    static let background = Color(red: 1.00, green: 0.985, blue: 0.972)
    static let surface = Color.white.opacity(0.72)
    static let textPrimary = Color(red: 0.12, green: 0.11, blue: 0.10)
    static let textSecondary = Color(red: 0.39, green: 0.38, blue: 0.40)
    static let separator = Color(red: 0.89, green: 0.85, blue: 0.82)
    static let accentStart = Color(red: 1.00, green: 0.36, blue: 0.22)
    static let accentMiddle = Color(red: 0.93, green: 0.25, blue: 0.55)
    static let accentEnd = Color(red: 0.66, green: 0.32, blue: 0.96)
    static let accent = LinearGradient(
        colors: [accentStart, accentMiddle, accentEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let majorRadius: CGFloat = 20
    static let controlRadius: CGFloat = 11
    static let panelPadding: CGFloat = 18
    static let surfaceShadow = Color.black.opacity(0.09)
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
