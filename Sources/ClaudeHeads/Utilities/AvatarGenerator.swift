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
            let (color1, color2) = PathColorGenerator.gradientNSColors(for: folderPath)
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
}
