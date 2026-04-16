import AppKit
import Foundation

public final class AppDelegate: NSObject, NSApplicationDelegate {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createDirectoryStructure()
        writeHookNotificationScript()
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

    // MARK: - Hook Script

    private func writeHookNotificationScript() {
        let scriptURL = Constants.hooksDirectory.appendingPathComponent("notify.sh")

        // Only write if it doesn't already exist, so user edits are preserved
        guard !FileManager.default.fileExists(atPath: scriptURL.path) else { return }

        let script = """
        #!/bin/bash
        # Claude Heads hook notification script
        # Called by Claude CLI hooks to notify the app of events.
        #
        # Usage: notify.sh <event-type> [payload...]
        # Events: tool_start, tool_end, message, error
        #
        # This script posts a distributed notification that the app listens for.
        # Modify as needed for your workflow.

        EVENT_TYPE="${1:-unknown}"
        HEAD_ID="${2:-}"
        PAYLOAD="${3:-}"

        # Post a macOS distributed notification via osascript
        osascript -e "tell application \\"System Events\\"" \\
                  -e "  do shell script \\"echo $EVENT_TYPE\\"" \\
                  -e "end tell" 2>/dev/null

        # Write event to a log file for the app to pick up
        LOG_DIR="$HOME/.claude-heads/hooks"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$EVENT_TYPE] head=$HEAD_ID $PAYLOAD" >> "$LOG_DIR/events.log"
        """

        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Make executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }
}
