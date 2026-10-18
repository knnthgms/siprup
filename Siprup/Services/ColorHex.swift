import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Blend toward white (positive) or black (negative).
    func shaded(_ amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let target: CGFloat = amount >= 0 ? 1 : 0
        let t = CGFloat(abs(amount))
        return Color(red: r + (target - r) * t, green: g + (target - g) * t, blue: b + (target - b) * t)
    }
}

/// Picks dark or light text for whatever liquid is behind it, by WCAG contrast ratio.
enum Contrast {
    static func luminance(hex: String) -> Double {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        func lin(_ c: UInt64) -> Double {
            let x = Double(c) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
    }

    /// True when dark text reads better than white on this background.
    static func prefersDarkText(onHex hex: String) -> Bool {
        let l = luminance(hex: hex)
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05)
    }
}

/// Text style that stays legible over moving liquid: colour chosen per background plus a soft halo.
struct LiquidText: ViewModifier {
    let darkText: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(darkText ? Color.black.opacity(0.85) : Color.white)
            .shadow(color: darkText ? .white.opacity(0.7) : .black.opacity(0.55), radius: 3)
            .shadow(color: darkText ? .white.opacity(0.35) : .black.opacity(0.3), radius: 10)
    }
}

extension View {
    func liquidText(dark: Bool) -> some View { modifier(LiquidText(darkText: dark)) }
}
