import Foundation

// MARK: - HookMarker

/// A parsed marker file written into the hooks directory by `notify.sh`.
///
/// Filenames are `<uuid>.done`, `<uuid>.<agentid>.start` and `<uuid>.<agentid>.stop`.
/// The `.start` marker's contents hold the subagent type (e.g. `Explore`).
enum HookMarker: Equatable {
    case taskComplete(instance: UUID)
    case subagentStart(instance: UUID, agentID: String)
    case subagentStop(instance: UUID, agentID: String)

    static let doneSuffix = "done"
    static let startSuffix = "start"
    static let stopSuffix = "stop"

    /// Every suffix the watcher treats as one of its own files (and cleans up).
    static let knownSuffixes: Set<String> = [doneSuffix, startSuffix, stopSuffix]

    /// Parses a marker filename. Returns nil for anything that is not a well-formed marker.
    static func parse(filename: String) -> HookMarker? {
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let suffix = parts.last, knownSuffixes.contains(suffix) else { return nil }

        switch (suffix, parts.count) {
        case (doneSuffix, 2):
            guard let uuid = UUID(uuidString: parts[0]) else { return nil }
            return .taskComplete(instance: uuid)

        case (startSuffix, 3), (stopSuffix, 3):
            guard let uuid = UUID(uuidString: parts[0]) else { return nil }
            let agentID = parts[1]
            guard !agentID.isEmpty, Self.isValidAgentID(agentID) else { return nil }
            return suffix == startSuffix
                ? .subagentStart(instance: uuid, agentID: agentID)
                : .subagentStop(instance: uuid, agentID: agentID)

        default:
            return nil
        }
    }

    /// Agent ids are restricted to the same character set `notify.sh` allows through.
    static func isValidAgentID(_ id: String) -> Bool {
        id.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
    }

    /// Reads and sanitises the subagent type stored in a `.start` marker's contents.
    /// Falls back to `"agent"` when the file is empty or unreadable.
    static func agentType(fromContents data: Data?) -> String {
        guard let data, let raw = String(data: data, encoding: .utf8) else { return "agent" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "agent" : String(trimmed.prefix(64))
    }
}

// MARK: - HookWatcher

/// Watches for Claude Code hook signals by monitoring a hooks directory for marker
/// files written by a shell script hook, and fans them out as typed events:
///
/// - `<uuid>.done`               -> `onTaskComplete(uuid)`            (Stop)
/// - `<uuid>.<agent>.start`      -> `onSubagentStart(uuid, agent, type)` (SubagentStart)
/// - `<uuid>.<agent>.stop`       -> `onSubagentStop(uuid, agent)`     (SubagentStop)
///
/// This is the single source of truth for `notify.sh`: the script is rewritten on
/// every launch so stale versions are always replaced.
final class HookWatcher {

    /// Called on the main queue when a task completes, with the instance UUID.
    var onTaskComplete: ((UUID) -> Void)?

    /// Called on the main queue when a subagent starts under the given head.
    var onSubagentStart: ((UUID, _ agentID: String, _ agentType: String) -> Void)?

    /// Called on the main queue when a subagent under the given head stops.
    var onSubagentStop: ((UUID, _ agentID: String) -> Void)?

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
    ///
    /// The event is taken from `hook_event_name` in the stdin JSON. `Stop` (or no/unknown
    /// event, for backwards compatibility) writes `<uuid>.done`; `SubagentStart` writes
    /// `<uuid>.<agent_id>.start` containing `agent_type`; `SubagentStop` writes
    /// `<uuid>.<agent_id>.stop`. Only stock macOS tools are used (bash, sed, tr, mv).
    static let notifyScriptContent = """
    #!/bin/bash
    # Claude Heads hook.
    #
    # Written automatically by Claude Heads on every launch -- local edits will be overwritten.
    #
    # Claude Code calls this with the hook event JSON on stdin and no arguments.
    # The head to notify is identified by $CLAUDE_INSTANCE_ID (set by Claude Heads
    # in the spawned claude process), or by $1 when invoked manually.
    #
    # Markers written into this directory (picked up by HookWatcher):
    #   Stop          -> <uuid>.done
    #   SubagentStart -> <uuid>.<agent_id>.start   (contents: agent_type)
    #   SubagentStop  -> <uuid>.<agent_id>.stop
    #
    # This script must never fail the user's claude session: it always exits 0.

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

    # Read the event JSON from stdin. Skip when stdin is a terminal (manual invocation),
    # and never block for more than a couple of seconds if the writer keeps it open.
    INPUT=""
    if [ ! -t 0 ]; then
        IFS= read -r -t 2 -d '' INPUT 2>/dev/null || true
    fi

    # Extract a top-level string field from the JSON with sed only (no jq/python needed).
    json_field() {
        printf '%s\\n' "${INPUT}" \\
            | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p' \\
            | sed -n '1p'
    }

    EVENT="$(json_field hook_event_name)"

    # Writes $2 into "$1" atomically (temp file + rename) so the watcher never reads a partial file.
    write_marker() {
        TMP="$1.tmp"
        if printf '%s' "$2" > "${TMP}" 2>/dev/null; then
            mv -f "${TMP}" "$1" 2>/dev/null || rm -f "${TMP}" 2>/dev/null
        fi
    }

    case "${EVENT}" in
        SubagentStart|SubagentStop)
            # Agent ids and types are reduced to a safe character set before touching the filesystem.
            AGENT_ID="$(json_field agent_id | tr -cd 'A-Za-z0-9_-')"
            if [ -z "${AGENT_ID}" ]; then
                exit 0
            fi
            AGENT_TYPE="$(json_field agent_type | tr -cd 'A-Za-z0-9 _:./-' | cut -c1-64)"
            if [ "${EVENT}" = "SubagentStart" ]; then
                write_marker "${HOOKS_DIR}/${INSTANCE_ID}.${AGENT_ID}.start" "${AGENT_TYPE:-agent}"
            else
                write_marker "${HOOKS_DIR}/${INSTANCE_ID}.${AGENT_ID}.stop" ""
            fi
            ;;
        *)
            # Stop, or an unknown/missing event name: treat as task completion.
            touch "${HOOKS_DIR}/${INSTANCE_ID}.done" 2>/dev/null || true
            ;;
    esac

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
            self?.scanForMarkers(notify: true)
        }

        let fd = directoryFD
        source.setCancelHandler {
            close(fd)
        }

        // Sweep any markers left over from a previous run (e.g. the app quit while an
        // orphaned claude finished) without notifying. Head UUIDs persist across launches,
        // so replaying them would make a restored head wave at launch for a stale event.
        scanForMarkers(notify: false)

        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        directoryFD = -1
    }

    /// Scans the hooks directory for marker files, parses and deletes them and, when
    /// `notify` is true, delivers each event to the matching callback on the main queue.
    ///
    /// Markers are delivered in filename-sorted order within a scan so that a `.start`
    /// and `.stop` for the same agent written back-to-back arrive in that order.
    private func scanForMarkers(notify: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hooksDirectory.path) else {
            return
        }

        for entry in entries.sorted() {
            guard let suffix = entry.split(separator: ".").last.map(String.init),
                  HookMarker.knownSuffixes.contains(suffix) else { continue }

            let markerPath = hooksDirectory.appendingPathComponent(entry).path
            guard let marker = HookMarker.parse(filename: entry) else {
                // Not a well-formed marker -- clean up so it does not accumulate.
                try? fm.removeItem(atPath: markerPath)
                continue
            }

            // Read the payload (subagent type) before deleting the marker file.
            let contents: Data? = {
                if case .subagentStart = marker { return fm.contents(atPath: markerPath) }
                return nil
            }()
            try? fm.removeItem(atPath: markerPath)

            guard notify else { continue }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch marker {
                case .taskComplete(let instance):
                    self.onTaskComplete?(instance)
                case .subagentStart(let instance, let agentID):
                    self.onSubagentStart?(instance, agentID, HookMarker.agentType(fromContents: contents))
                case .subagentStop(let instance, let agentID):
                    self.onSubagentStop?(instance, agentID)
                }
            }
        }
    }
}
