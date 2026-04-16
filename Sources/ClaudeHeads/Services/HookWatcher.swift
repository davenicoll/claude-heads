import Foundation

// MARK: - HookWatcher

/// Watches for Claude Code task-completion signals by monitoring a hooks directory
/// for `.done` marker files written by a shell script hook.
final class HookWatcher {

    /// Called on the main queue when a task completes, with the instance UUID.
    var onTaskComplete: ((UUID) -> Void)?

    private let hooksDirectory: URL
    private var directoryFD: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.claudeheads.hookwatcher", qos: .utility)

    // MARK: - Init / Deinit

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        hooksDirectory = home.appendingPathComponent(".claude-heads/hooks")

        ensureHooksDirectory()
        writeNotifyScript()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Hook Script

    /// Returns the path to the notify shell script that Claude Code should invoke.
    func hookScriptPath() -> String {
        return hooksDirectory.appendingPathComponent("notify.sh").path
    }

    // MARK: - Private: Directory Setup

    private func ensureHooksDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: hooksDirectory.path) {
            do {
                try fm.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
            } catch {
                NSLog("[HookWatcher] Failed to create hooks directory: \(error)")
            }
        }
    }

    /// Writes `notify.sh` to the hooks directory. The script expects a single argument:
    /// the instance UUID. It creates a `<uuid>.done` marker file.
    private func writeNotifyScript() {
        let scriptPath = hooksDirectory.appendingPathComponent("notify.sh")
        let scriptContent = """
        #!/bin/bash
        # Claude Heads task completion hook.
        # Usage: notify.sh <instance-uuid>
        #
        # Creates a marker file that the HookWatcher picks up to signal task completion.

        if [ -z "$1" ]; then
            echo "Usage: notify.sh <instance-uuid>" >&2
            exit 1
        fi

        HOOKS_DIR="$(dirname "$0")"
        touch "${HOOKS_DIR}/${1}.done"
        """

        do {
            try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
            // Make executable: rwxr-xr-x
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptPath.path
            )
        } catch {
            NSLog("[HookWatcher] Failed to write notify script: \(error)")
        }
    }

    // MARK: - Private: File System Watching

    private func startWatching() {
        directoryFD = open(hooksDirectory.path, O_EVTONLY)
        guard directoryFD >= 0 else {
            NSLog("[HookWatcher] Failed to open hooks directory for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: .write,
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.scanForCompletedTasks()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFD, fd >= 0 {
                close(fd)
                self?.directoryFD = -1
            }
        }

        source.resume()
        watchSource = source

        // Do an initial scan in case files were already present before we started watching.
        watchQueue.async { [weak self] in
            self?.scanForCompletedTasks()
        }
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    /// Scans the hooks directory for `*.done` files, extracts UUIDs, notifies, and cleans up.
    private func scanForCompletedTasks() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hooksDirectory.path) else {
            return
        }

        for entry in entries {
            guard entry.hasSuffix(".done") else { continue }

            let basename = String(entry.dropLast(5)) // Remove ".done"
            guard let uuid = UUID(uuidString: basename) else {
                // Not a valid UUID filename -- ignore or clean up
                continue
            }

            // Delete the marker file
            let markerPath = hooksDirectory.appendingPathComponent(entry).path
            try? fm.removeItem(atPath: markerPath)

            // Notify on main queue
            DispatchQueue.main.async { [weak self] in
                self?.onTaskComplete?(uuid)
            }
        }
    }
}
