import AppKit
import SwiftUI

enum AvatarGenerator {

    /// Generate a circular avatar NSImage for a head instance.
    ///
    /// - Parameters:
    ///   - folderName: Short display name (e.g. "claude-heads"), used for initials.
    ///   - folderPath: Full path, used to derive the gradient color.
    ///   - size: Diameter in points. Defaults to 80.
    /// - Returns: A circular NSImage with gradient background and centered initials.
    static func generateAvatar(folderName: String, folderPath: String, size: CGFloat = 80) -> NSImage {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        let image = NSImage(size: rect.size, flipped: false) { drawRect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // -- Circular clip --
            let circlePath = CGPath(ellipseIn: drawRect, transform: nil)
            context.addPath(circlePath)
            context.clip()

            // -- Gradient background --
            let (color1, color2) = gradientNSColors(for: folderPath)
            let gradient = NSGradient(starting: color1, ending: color2)
            gradient?.draw(in: drawRect, angle: -45)

            // -- Initials text --
            let initials = Self.initials(from: folderName)
            let fontSize = size * 0.38
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]

            let attributedString = NSAttributedString(string: initials, attributes: attributes)
            let textSize = attributedString.size()
            let textOrigin = CGPoint(
                x: (drawRect.width - textSize.width) / 2,
                y: (drawRect.height - textSize.height) / 2
            )
            attributedString.draw(at: textOrigin)

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Private

    /// Extract up to 2 meaningful initial characters from a folder name.
    private static func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }

        // For single-char names like "~"
        if trimmed.count == 1 {
            return String(trimmed.prefix(1))
        }

        // Split on common separators and take first char of first two components
        let separators = CharacterSet(charactersIn: "-_. ")
        let components = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }

        if components.count >= 2 {
            let first = components[0].prefix(1).uppercased()
            let second = components[1].prefix(1).uppercased()
            return first + second
        }

        // Fallback: first two characters
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Produce two NSColors for the gradient from a path.
    private static func gradientNSColors(for path: String) -> (NSColor, NSColor) {
        let swiftGradient = PathColorGenerator.gradient(for: path)

        // Resolve gradient colors by re-deriving from the same hash logic
        // (avoids trying to inspect the opaque SwiftUI gradient).
        let hash = fnvHash(path)
        let hue = Double(hash & 0xFFFF) / Double(0xFFFF)
        let saturation = 0.5 + Double((hash >> 16) & 0xFFFF) / Double(0xFFFF) * 0.2
        let lightness = 0.4 + Double((hash >> 32) & 0xFFFF) / Double(0xFFFF) * 0.15

        let hueShift: Double = 0.07
        let hue2 = (hue + hueShift).truncatingRemainder(dividingBy: 1.0)
        let lightness2 = max(0.30, lightness - 0.08)

        let c1 = nsColorFromHSL(hue: hue, saturation: saturation, lightness: lightness)
        let c2 = nsColorFromHSL(hue: hue2, saturation: saturation, lightness: lightness2)
        return (c1, c2)
    }

    private static func fnvHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func nsColorFromHSL(hue: Double, saturation: Double, lightness: Double) -> NSColor {
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

        return NSColor(
            hue: max(0, min(1, hue)),
            saturation: max(0, min(1, sbSaturation)),
            brightness: max(0, min(1, brightness)),
            alpha: 1.0
        )
    }
}
