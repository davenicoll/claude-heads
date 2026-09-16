import Foundation

// MARK: - HookMarker

/// A parsed marker filename written into the hooks directory by `notify.sh`.
///
/// Filenames are `<uuid>.done`, `<uuid>.<agentid>.start` and `<uuid>.<agentid>.stop`.
/// Every marker's contents are the raw hook event JSON (see `HookPayload`).
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
}

// MARK: - HookPayload

/// The parts of a hook event payload (a marker file's contents) that the app uses.
///
/// `notify.sh` stores stdin verbatim, so this is the JSON object Claude Code handed the
/// hook. Parsing is deliberately lenient: an empty file, a truncated write, a non-object
/// root or missing fields all yield an `.empty` payload and the filename alone drives
/// the event.
struct HookPayload: Equatable {
    /// `agent_type` (may legitimately be empty in Claude Code 2.1.x payloads).
    var agentType: String = ""
    /// A top-level `description`, if a future payload carries one.
    var description: String?
    /// `background_tasks`, or nil when the payload has no such array.
    var backgroundTasks: [BackgroundTask]?

    static let empty = HookPayload()

    static func parse(_ data: Data?) -> HookPayload {
        guard let data, !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }

        var payload = HookPayload()
        payload.agentType = (root["agent_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let description = root["description"] as? String {
            payload.description = description
        }
        if let tasks = root["background_tasks"] as? [Any] {
            payload.backgroundTasks = tasks.compactMap { Self.backgroundTask(from: $0) }
        }
        return payload
    }

    private static func backgroundTask(from any: Any) -> BackgroundTask? {
        guard let dict = any as? [String: Any],
              let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return BackgroundTask(
            id: id,
            type: dict["type"] as? String ?? "",
            description: dict["description"] as? String,
            status: dict["status"] as? String ?? "",
            agentType: dict["agent_type"] as? String
        )
    }
}

// MARK: - HookWatcher

/// Watches for Claude Code hook signals by monitoring a hooks directory for marker
/// files written by a shell script hook, and fans them out as typed events:
///
/// - `<uuid>.done`           -> `onTaskComplete(uuid)`                          (Stop)
/// - `<uuid>.<agent>.start`  -> `onSubagentStart(uuid, agent, type, description)` (SubagentStart)
/// - `<uuid>.<agent>.stop`   -> `onSubagentStop(uuid, agent)`                    (SubagentStop)
/// - any marker whose payload has `background_tasks` -> `onBackgroundTasks(uuid, tasks)`,
///   delivered just before the marker's own event.
///
/// This is the single source of truth for `notify.sh`: the script is rewritten on
/// every launch so stale versions are always replaced.
final class HookWatcher {

    /// Called on the main queue when a task completes, with the instance UUID and the
    /// `background_tasks` list from the Stop payload (nil when the payload had none).
    var onTaskComplete: ((UUID, _ backgroundTasks: [BackgroundTask]?) -> Void)?

    /// Called on the main queue when a subagent starts under the given head. `agentType`
    /// may be empty; `description` is only set when the payload carried one.
    var onSubagentStart: ((UUID, _ agentID: String, _ agentType: String, _ description: String?) -> Void)?

    /// Called on the main queue when a subagent under the given head stops.
    var onSubagentStop: ((UUID, _ agentID: String) -> Void)?

    /// Called on the main queue, before the marker's own event, whenever a payload lists
    /// the session's background tasks.
    var onBackgroundTasks: ((UUID, [BackgroundTask]) -> Void)?

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
    /// The event is taken from `hook_event_name` in the stdin JSON. `Stop` (or no event
    /// name at all, for manual/legacy invocation) writes `<uuid>.done`; `SubagentStart`
    /// writes `<uuid>.<agent_id>.start`; `SubagentStop` writes `<uuid>.<agent_id>.stop`.
    /// Every marker's contents are the stdin JSON verbatim, so the app can read whatever
    /// fields it needs (`agent_type`, `background_tasks`, ...) with a real JSON parser.
    /// Any other named event (Notification, PreToolUse, ...) writes nothing, and so does
    /// a piped stdin that yields no input (e.g. a writer that held the pipe open past the
    /// read timeout), so a stray hook can never fake a Stop. Only stock macOS tools are
    /// used (bash 3.2, sed, tr, mv).
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
    # Markers written into this directory (picked up by HookWatcher); each one
    # contains the stdin JSON verbatim:
    #   Stop          -> <uuid>.done
    #   SubagentStart -> <uuid>.<agent_id>.start
    #   SubagentStop  -> <uuid>.<agent_id>.stop
    #   anything else -> nothing
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
        # bash 3.2 discards partial input on timeout; with nothing to go on, do nothing
        # rather than guess (a guessed Stop would wave the head for no reason).
        if [ -z "${INPUT}" ]; then
            exit 0
        fi
    fi

    # Extract a top-level string field from the JSON with sed only (no jq/python needed).
    # Good enough for routing (hook_event_name, agent_id); the app parses the full JSON.
    json_field() {
        printf '%s\\n' "${INPUT}" \\
            | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p' \\
            | sed -n '1p'
    }

    EVENT="$(json_field hook_event_name)"

    # Writes the raw payload into "$1" atomically (temp file + rename) so the watcher never
    # reads a partial file. printf is a builtin, so payload size is not limited by ARG_MAX.
    write_marker() {
        TMP="$1.tmp"
        if printf '%s' "${INPUT}" > "${TMP}" 2>/dev/null; then
            mv -f "${TMP}" "$1" 2>/dev/null || rm -f "${TMP}" 2>/dev/null
        fi
    }

    case "${EVENT}" in
        SubagentStart|SubagentStop)
            # Agent ids are reduced to a safe character set before touching the filesystem.
            AGENT_ID="$(json_field agent_id | tr -cd 'A-Za-z0-9_-')"
            if [ -z "${AGENT_ID}" ]; then
                exit 0
            fi
            if [ "${EVENT}" = "SubagentStart" ]; then
                write_marker "${HOOKS_DIR}/${INSTANCE_ID}.${AGENT_ID}.start"
            else
                write_marker "${HOOKS_DIR}/${INSTANCE_ID}.${AGENT_ID}.stop"
            fi
            ;;
        Stop|"")
            # Stop, or no event name (manual/legacy invocation): task completion.
            write_marker "${HOOKS_DIR}/${INSTANCE_ID}.done"
            ;;
        *)
            # Some other hook event routed here (Notification, PreToolUse, ...): not ours.
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
    /// Markers coalesced into one scan are delivered chronologically (by modification
    /// date), so a `.start` and `.stop` for the same agent written back-to-back arrive
    /// in that order. When timestamps tie, `.done` markers are delivered after the
    /// subagent markers so a Stop never leaves an orphan child that started just before it.
    private func scanForMarkers(notify: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hooksDirectory.path) else {
            return
        }

        for entry in Self.deliveryOrder(entries, in: hooksDirectory) {
            guard let suffix = entry.split(separator: ".").last.map(String.init),
                  HookMarker.knownSuffixes.contains(suffix) else { continue }

            let markerPath = hooksDirectory.appendingPathComponent(entry).path
            guard let marker = HookMarker.parse(filename: entry) else {
                // Not a well-formed marker -- clean up so it does not accumulate.
                try? fm.removeItem(atPath: markerPath)
                continue
            }

            // Read the payload before deleting the marker file.
            let payload = notify ? HookPayload.parse(fm.contents(atPath: markerPath)) : .empty
            try? fm.removeItem(atPath: markerPath)

            guard notify else { continue }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliver(marker, payload: payload)
            }
        }
    }

    /// Fans one marker out to the callbacks. Runs on the main queue.
    private func deliver(_ marker: HookMarker, payload: HookPayload) {
        let instance: UUID = {
            switch marker {
            case .taskComplete(let instance), .subagentStart(let instance, _), .subagentStop(let instance, _):
                return instance
            }
        }()
        if let tasks = payload.backgroundTasks {
            onBackgroundTasks?(instance, tasks)
        }
        switch marker {
        case .taskComplete:
            onTaskComplete?(instance, payload.backgroundTasks)
        case .subagentStart(_, let agentID):
            onSubagentStart?(instance, agentID, payload.agentType, payload.description)
        case .subagentStop(_, let agentID):
            onSubagentStop?(instance, agentID)
        }
    }

    /// Orders directory entries for delivery: oldest first by modification date, then
    /// `.done` after other markers, then by filename so the order is deterministic.
    static func deliveryOrder(_ entries: [String], in directory: URL) -> [String] {
        let fm = FileManager.default
        func key(_ entry: String) -> (Date, Int, String) {
            let path = directory.appendingPathComponent(entry).path
            let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            let isDone = entry.hasSuffix("." + HookMarker.doneSuffix) ? 1 : 0
            return (date, isDone, entry)
        }
        return entries.map { ($0, key($0)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}
