import Foundation

extension Notification.Name {
    static let terminalFontChanged = Notification.Name("com.claudeheads.terminalFontChanged")
    static let headSizeChanged = Notification.Name("com.claudeheads.headSizeChanged")
    static let headTapped = Notification.Name("com.claudeheads.headTapped")
}

enum Constants {

    // MARK: - Directories & Paths

    static let claudeHeadsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude-heads", isDirectory: true)
    }()

    static let stateFilePath: URL = {
        claudeHeadsDirectory.appendingPathComponent("state.json")
    }()

    static let hooksDirectory: URL = {
        claudeHeadsDirectory.appendingPathComponent("hooks", isDirectory: true)
    }()
}

// MARK: - HeadGeometry

/// Layout metrics for a head window, derived from the circle diameter.
///
/// `HeadView` lays out a circle with a wave-emoji overhang above it and a name label
/// below it. The window that hosts it must be sized to match, and the drag clamping
/// and terminal placement code must know where the circle sits inside that window.
/// All of those callers derive their numbers from here so they cannot drift apart.
struct HeadGeometry {
    /// Wave emoji font size as a fraction of the circle diameter.
    static let emojiScale: CGFloat = 0.52
    /// Vertical window slack reserved above the circle for the emoji, as a fraction
    /// of the emoji size. Must be at least `emojiTopPadding` so the emoji is not clipped.
    static let emojiOverhang: CGFloat = 0.6
    /// Top padding `HeadView` adds above the circle for the emoji, as a fraction of the emoji size.
    static let emojiTopPadding: CGFloat = 0.5
    /// Emoji offset from the circle's top-left corner, as fractions of the emoji size.
    static let emojiOffsetX: CGFloat = -0.3
    static let emojiOffsetY: CGFloat = -0.4
    /// Height reserved for the name label under the circle.
    static let labelHeight: CGFloat = 14
    /// Vertical spacing between the circle stack and the label.
    static let labelSpacing: CGFloat = 2

    let diameter: CGFloat

    init(diameter: CGFloat) {
        self.diameter = diameter
    }

    /// Geometry for the head size currently selected in settings.
    static var current: HeadGeometry {
        HeadGeometry(diameter: AppSettings.shared.headSize.diameter)
    }

    var emojiSize: CGFloat { diameter * Self.emojiScale }

    /// Window width: the circle plus room for the emoji to overhang on the left.
    var totalWidth: CGFloat { diameter + emojiSize }

    /// Height of the circle + emoji stack (above the label).
    var stackHeight: CGFloat { diameter + emojiSize * Self.emojiOverhang }

    /// Full window height including the label.
    var totalHeight: CGFloat { stackHeight + Self.labelHeight }

    var windowSize: CGSize { CGSize(width: totalWidth, height: totalHeight) }

    /// X offset of the circle's left edge inside the window.
    var circleOffsetX: CGFloat { (totalWidth - diameter) / 2 }

    /// Y offset of the circle's bottom edge inside the window (label sits underneath).
    var circleBottomY: CGFloat { Self.labelHeight + Self.labelSpacing }

    /// Y offset of the circle's top edge inside the window.
    var circleTopY: CGFloat { circleBottomY + diameter }

    // MARK: Screen clamping

    /// Clamps a window origin so the whole `size`-sized rect anchored at it stays inside
    /// `rect`. If the rect is larger than `rect`, the origin is pinned to `rect`'s min edge.
    static func clampOrigin(_ origin: CGPoint, size: CGSize, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: max(rect.minX, min(origin.x, rect.maxX - size.width)),
            y: max(rect.minY, min(origin.y, rect.maxY - size.height))
        )
    }

    /// Clamps a head window origin (`HeadInstance.position`) so the full head window
    /// (circle, emoji overhang and name label) stays inside `rect`, normally a screen's
    /// `visibleFrame`. Drag clamping and display remapping both use this so a head that
    /// is legal after a drag is never moved again on relaunch or display change.
    func clampWindowOrigin(_ origin: CGPoint, in rect: CGRect) -> CGPoint {
        Self.clampOrigin(origin, size: windowSize, in: rect)
    }
}
