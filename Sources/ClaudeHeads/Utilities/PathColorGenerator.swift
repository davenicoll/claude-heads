import AppKit
import SwiftUI

enum PathColorGenerator {

    /// Deterministic color derived from a folder path string.
    static func color(for path: String) -> Color {
        let (hue, saturation, lightness) = hslComponents(for: path)
        return colorFromHSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// Gradient of two related colors derived from a folder path string.
    static func gradient(for path: String) -> LinearGradient {
        let (first, second) = gradientStops(for: path)

        let color1 = colorFromHSL(hue: first.hue, saturation: first.saturation, lightness: first.lightness)
        let color2 = colorFromHSL(hue: second.hue, saturation: second.saturation, lightness: second.lightness)

        return LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The same two gradient stops as `gradient(for:)`, as AppKit colors for drawing
    /// with `NSGradient` (used by `AvatarGenerator`).
    static func gradientNSColors(for path: String) -> (NSColor, NSColor) {
        let (first, second) = gradientStops(for: path)

        let c1 = nsColorFromHSL(hue: first.hue, saturation: first.saturation, lightness: first.lightness)
        let c2 = nsColorFromHSL(hue: second.hue, saturation: second.saturation, lightness: second.lightness)
        return (c1, c2)
    }

    /// Returns .white or .black depending on which contrasts better with the path's color.
    static func contrastColor(for path: String) -> Color {
        let (hue, saturation, lightness) = hslComponents(for: path)
        // Average lightness of the gradient (second color is darker by 0.08)
        let avgLightness = (lightness + max(0.30, lightness - 0.08)) / 2.0
        // Use white text for dark backgrounds, black for light
        return avgLightness > 0.5 ? .black : .white
    }

    // MARK: - Internal

    private typealias HSL = (hue: Double, saturation: Double, lightness: Double)

    private static func hslComponents(for path: String) -> HSL {
        let hash = deterministicHash(path)

        let hue = Double(hash & 0xFFFF) / Double(0xFFFF)
        let saturation = 0.5 + Double((hash >> 16) & 0xFFFF) / Double(0xFFFF) * 0.2   // 0.5 - 0.7
        let lightness = 0.4 + Double((hash >> 32) & 0xFFFF) / Double(0xFFFF) * 0.15    // 0.4 - 0.55

        return (hue, saturation, lightness)
    }

    /// The two HSL stops of a path's gradient: the base color and a slightly
    /// hue-shifted, darker companion.
    private static func gradientStops(for path: String) -> (HSL, HSL) {
        let base = hslComponents(for: path)

        let hueShift: Double = 0.07
        let hue2 = (base.hue + hueShift).truncatingRemainder(dividingBy: 1.0)
        let lightness2 = max(0.30, base.lightness - 0.08)

        return (base, (hue2, base.saturation, lightness2))
    }

    /// FNV-1a 64-bit hash for deterministic, uniform distribution.
    private static func deterministicHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    /// Convert HSL (all 0-1) to HSB for `Color(hue:saturation:brightness:)` / `NSColor`.
    private static func hsbComponents(hue: Double, saturation: Double, lightness: Double)
        -> (hue: Double, saturation: Double, brightness: Double)
    {
        let brightness: Double
        let sbSaturation: Double

        if lightness <= 0.5 {
            brightness = lightness * (1 + saturation)
        } else {
            brightness = lightness + saturation - lightness * saturation
        }

        if brightness == 0 {
            sbSaturation = 0
        } else {
            sbSaturation = 2.0 * (1.0 - lightness / brightness)
        }

        return (
            max(0, min(1, hue)),
            max(0, min(1, sbSaturation)),
            max(0, min(1, brightness))
        )
    }

    private static func colorFromHSL(hue: Double, saturation: Double, lightness: Double) -> Color {
        let hsb = hsbComponents(hue: hue, saturation: saturation, lightness: lightness)
        return Color(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
    }

    private static func nsColorFromHSL(hue: Double, saturation: Double, lightness: Double) -> NSColor {
        let hsb = hsbComponents(hue: hue, saturation: saturation, lightness: lightness)
        return NSColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness, alpha: 1.0)
    }
}
