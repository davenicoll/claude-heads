import Foundation

// MARK: - HookWatcher

/// Watches for Claude Code task-completion signals by monitoring a hooks directory
/// for `.done` marker files written by a shell script hook.
///
/// This is the single source of truth for `notify.sh`: the script is rewritten on
/// every launch so stale versions are always replaced.
final class HookWatcher {

    /// Called on the main queue when a task completes, with the instance UUID.
    var onTaskComplete: ((UUID) -> Void)?

    /// Name of the environment variable the spawned `claude` process receives so the
    /// hook script can identify which head it belongs to.
    static let instanceIDEnvironmentVariable = "CLAUDE_INSTANCE_ID"

    private let hooksDirectory: URL
    private var directoryFD: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.claudeheads.hookwatcher", qos: .utility)

    // MARK: - Init / Deinit

    init(hooksDirectory: URL = Constants.hooksDirectory) {
        self.hooksDirectory = hooksDirectory

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

    /// The contents of `notify.sh`.
    ///
    /// Claude Code invokes hook commands with the event JSON on stdin and no arguments,
    /// so the instance id is taken from `CLAUDE_INSTANCE_ID` (exported into the child
    /// process by ProcessManager), falling back to `$1` for manual invocation. If neither
    /// is set the script exits 0 silently so it never breaks a user's claude session.
    static let notifyScriptContent = """
    #!/bin/bash
    # Claude Heads task completion hook.
    #
    # Written automatically by Claude Heads on every launch -- local edits will be overwritten.
    #
    # Claude Code calls this with the hook event JSON on stdin and no arguments.
    # The head to notify is identified by $CLAUDE_INSTANCE_ID (set by Claude Heads
    # in the spawned claude process), or by $1 when invoked manually.
    # Creates a "<uuid>.done" marker file that the HookWatcher picks up.

    # Drain stdin so Claude Code never blocks writing the event payload.
    if [ ! -t 0 ]; then
        cat > /dev/null 2>&1 || true
    fi

    INSTANCE_ID="${CLAUDE_INSTANCE_ID:-${1:-}}"

    # Not launched by Claude Heads (or no id available): do nothing, never fail the session.
    if [ -z "${INSTANCE_ID}" ]; then
        exit 0
    fi

    # Only accept a plain UUID so the id can never escape the hooks directory.
    case "${INSTANCE_ID}" in
        *[!A-Za-z0-9-]*|"") exit 0 ;;
    esac

    HOOKS_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -z "${HOOKS_DIR}" ]; then
        exit 0
    fi

    touch "${HOOKS_DIR}/${INSTANCE_ID}.done" 2>/dev/null || true
    exit 0

    """

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

    /// Writes `notify.sh` to the hooks directory, unconditionally overwriting any
    /// existing file so stale scripts from older versions are replaced.
    private func writeNotifyScript() {
        let scriptPath = hooksDirectory.appendingPathComponent("notify.sh")

        do {
            try Self.notifyScriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
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

        let fd = directoryFD
        source.setCancelHandler {
            close(fd)
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
        directoryFD = -1
    }

    /// Scans the hooks directory for `*.done` files, extracts UUIDs, notifies, and cleans up.
    private func scanForCompletedTasks() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hooksDirectory.path) else {
            return
        }

        for entry in entries {
            guard entry.hasSuffix(".done") else { continue }

            let markerPath = hooksDirectory.appendingPathComponent(entry).path
            let basename = String(entry.dropLast(5)) // Remove ".done"
            guard let uuid = UUID(uuidString: basename) else {
                // Not a valid UUID filename -- clean up so it does not accumulate.
                try? fm.removeItem(atPath: markerPath)
                continue
            }

            // Delete the marker file
            try? fm.removeItem(atPath: markerPath)

            // Notify on main queue
            DispatchQueue.main.async { [weak self] in
                self?.onTaskComplete?(uuid)
            }
        }
    }
}
