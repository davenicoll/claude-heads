import AppKit
import Foundation

public final class AppDelegate: NSObject, NSApplicationDelegate {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyApplicationIcon()
        createDirectoryStructure()
    }

    // MARK: - App Icon

    /// Sets the application icon so it shows in the About panel and Cmd-Tab if the
    /// app is ever activated. When running as ClaudeHeads.app the icon comes from
    /// Contents/Resources; under `swift run` it falls back to the SwiftPM resource bundle.
    private func applyApplicationIcon() {
        guard let url = appIconURL(),
              let image = NSImage(contentsOf: url),
              image.isValid else { return }
        NSApplication.shared.applicationIconImage = image
    }

    private func appIconURL() -> URL? {
        let iconName = "AppIcon"
        let iconExtension = "icns"

        // 1. Running as ClaudeHeads.app: scripts/bundle.sh copies the icon into Contents/Resources.
        if let url = Bundle.main.url(forResource: iconName, withExtension: iconExtension) {
            return url
        }

        // 2. Running via `swift run`: SwiftPM places the resource bundle next to the executable,
        //    which is where the generated Bundle.module accessor looks. Bundle.module traps if
        //    the bundle is missing (e.g. a bare binary copied out of .build), so check first.
        let moduleBundleName = "ClaudeHeads_ClaudeHeadsCore.bundle"
        let sidecar = Bundle.main.bundleURL.appendingPathComponent(moduleBundleName)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return Bundle.module.url(forResource: iconName, withExtension: iconExtension)
        }

        // 3. Resource bundle copied into Contents/Resources by scripts/bundle.sh. Bundle.module
        //    does not search there, so load it explicitly.
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent(moduleBundleName)) {
            return bundle.url(forResource: iconName, withExtension: iconExtension)
        }

        return nil
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
