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

    // MARK: - Head Sizes

    static let headSizeSmall: CGFloat = 40
    static let headSizeMedium: CGFloat = 60
    static let headSizeLarge: CGFloat = 80

    // MARK: - Snap

    static let defaultSnapDistance: CGFloat = 60

    // MARK: - Animation Durations

    static let waveAnimationDuration: TimeInterval = 0.6
    static let springAnimationDuration: TimeInterval = 0.35
    static let expandAnimationDuration: TimeInterval = 0.25
    static let collapseAnimationDuration: TimeInterval = 0.2
    static let snapAnimationDuration: TimeInterval = 0.3
}
