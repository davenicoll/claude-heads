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
    /// How much of the emoji extends above the circle, as a fraction of the emoji size.
    static let emojiOverhang: CGFloat = 0.6
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
}
