import SwiftUI

enum PathColorGenerator {

    /// Deterministic color derived from a folder path string.
    static func color(for path: String) -> Color {
        let (hue, saturation, lightness) = hslComponents(for: path)
        return colorFromHSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// Gradient of two related colors derived from a folder path string.
    static func gradient(for path: String) -> LinearGradient {
        let (hue, saturation, lightness) = hslComponents(for: path)

        let hueShift: Double = 0.07
        let hue2 = (hue + hueShift).truncatingRemainder(dividingBy: 1.0)
        let lightness2 = max(0.30, lightness - 0.08)

        let color1 = colorFromHSL(hue: hue, saturation: saturation, lightness: lightness)
        let color2 = colorFromHSL(hue: hue2, saturation: saturation, lightness: lightness2)

        return LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Internal

    private static func hslComponents(for path: String) -> (hue: Double, saturation: Double, lightness: Double) {
        let hash = deterministicHash(path)

        let hue = Double(hash & 0xFFFF) / Double(0xFFFF)
        let saturation = 0.5 + Double((hash >> 16) & 0xFFFF) / Double(0xFFFF) * 0.2   // 0.5 - 0.7
        let lightness = 0.4 + Double((hash >> 32) & 0xFFFF) / Double(0xFFFF) * 0.15    // 0.4 - 0.55

        return (hue, saturation, lightness)
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

    /// Convert HSL (all 0-1) to SwiftUI Color.
    private static func colorFromHSL(hue: Double, saturation: Double, lightness: Double) -> Color {
        // Convert HSL to HSB for SwiftUI's Color(hue:saturation:brightness:)
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

        return Color(
            hue: hue,
            saturation: max(0, min(1, sbSaturation)),
            brightness: max(0, min(1, brightness))
        )
    }
}
