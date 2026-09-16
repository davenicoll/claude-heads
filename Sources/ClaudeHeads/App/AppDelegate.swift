import AppKit
import Foundation

public final class AppDelegate: NSObject, NSApplicationDelegate {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createDirectoryStructure()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // AppState handles saving positions and killing processes via shutdown(),
        // but we guard against it not being called by the menu-bar quit path.
        // The @main App's ClaudeHeadsApp already calls appState.shutdown()
        // before NSApplication.shared.terminate, so this is a safety net.
    }

    // MARK: - Directory Setup

    private func createDirectoryStructure() {
        let fm = FileManager.default
        let baseDir = Constants.claudeHeadsDirectory
        let hooksDir = Constants.hooksDirectory

        for dir in [baseDir, hooksDir] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
