import Darwin
import Foundation
import SwiftTerm

// MARK: - PTYInfo

/// Holds the resources associated with a running PTY-backed process.
struct PTYInfo {
    let masterFD: Int32
    let pid: pid_t
    let readSource: DispatchSourceRead
    weak var terminalView: TerminalView?
    weak var bridge: TerminalBridge?
}

// MARK: - ProcessManager

final class ProcessManager {
    static let shared = ProcessManager()

    /// Active processes keyed by child PID.
    private var processes: [pid_t: PTYInfo] = [:]
    private let lock = NSLock()

    /// Called on the main queue when a child process exits.
    var onProcessExit: ((pid_t, Int32) -> Void)?

    /// Called on the main queue when PTY output is received (process is active).
    var onProcessActivity: ((pid_t) -> Void)?

    private init() {
        startSIGCHLDMonitor()
    }

    // MARK: - Spawn

    /// Spawns a `claude` CLI process inside a pseudo-terminal.
    ///
    /// - Parameters:
    ///   - folderPath: Working directory for the child process.
    ///   - extraArgs: Additional arguments passed to `claude`.
    ///   - terminalView: The SwiftTerm view that will display output.
    ///   - bridge: The terminal bridge that writes user input back to the PTY.
    /// - Returns: The child PID, or -1 on failure.
    @discardableResult
    func spawnProcess(
        folderPath: String,
        extraArgs: [String],
        terminalView: TerminalView,
        bridge: TerminalBridge
    ) -> pid_t {
        var masterFD: Int32 = 0
        var winSize = winsize()

        let terminal = terminalView.getTerminal()
        let cols = max(terminal.cols, 80)
        let rows = max(terminal.rows, 24)
        winSize.ws_col = UInt16(cols)
        winSize.ws_row = UInt16(rows)
        winSize.ws_xpixel = 0
        winSize.ws_ypixel = 0

        let childPID = forkpty(&masterFD, nil, nil, &winSize)

        guard childPID >= 0 else {
            perror("forkpty")
            return -1
        }

        if childPID == 0 {
            // ---- Child process ----
            if chdir(folderPath) != 0 {
                perror("chdir")
                _exit(1)
            }

            // GUI apps don't inherit the user's shell PATH, so set it up.
            // Include common locations where claude and its dependencies live.
            let home = String(cString: getenv("HOME") ?? strdup("/tmp"))
            let path = [
                "\(home)/.local/bin",
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "\(home)/.nvm/versions/node/default/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ].joined(separator: ":")
            setenv("PATH", path, 1)
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("LANG", "en_US.UTF-8", 1)

            // Resolve claude's full path
            let claudePaths = [
                "\(home)/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
            let claudeBin = claudePaths.first { access($0, X_OK) == 0 } ?? "claude"

            // Build argv — separate --continue from other args so we can fall back
            let settingsArgs = AppSettings.shared.effectiveCLIArgs
            let wantsContinue = settingsArgs.contains("--continue")
            let otherArgs = settingsArgs.filter { $0 != "--continue" } + extraArgs

            if wantsContinue {
                // Try --continue first via shell; if it fails (no session), start fresh
                let allArgs = ([claudeBin, "--continue"] + otherArgs)
                    .map { "'\($0)'" }.joined(separator: " ")
                let freshArgs = ([claudeBin] + otherArgs)
                    .map { "'\($0)'" }.joined(separator: " ")
                let script = "\(allArgs) || \(freshArgs)"
                let shellArgs = ["/bin/sh", "-c", script]
                let cArgs = shellArgs.map { strdup($0) } + [nil]
                execvp("/bin/sh", cArgs)
            } else {
                let args = [claudeBin] + otherArgs
                let cArgs = args.map { strdup($0) } + [nil]
                execvp(claudeBin, cArgs)
            }

            // If execvp returns, it failed
            perror("execvp")
            _exit(127)
        }

        // ---- Parent process ----

        // Configure the bridge to write to this master fd
        bridge.masterFD = masterFD
        bridge.childPID = childPID

        // Set master fd to non-blocking
        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        // Create a dispatch source to read PTY output and feed it to the terminal
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        readSource.setEventHandler { [weak self, weak terminalView] in
            guard let terminalView = terminalView else {
                self?.cleanUp(pid: childPID)
                return
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(masterFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Array(buffer[0..<bytesRead])
                DispatchQueue.main.async { [weak self] in
                    terminalView.feed(byteArray: ArraySlice(data))
                    self?.onProcessActivity?(childPID)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EINTR) {
                // EOF or unrecoverable error -- the child likely exited
                self?.cleanUp(pid: childPID)
            }
        }

        readSource.setCancelHandler {
            close(masterFD)
        }

        readSource.resume()

        let info = PTYInfo(
            masterFD: masterFD,
            pid: childPID,
            readSource: readSource,
            terminalView: terminalView,
            bridge: bridge
        )

        lock.lock()
        processes[childPID] = info
        lock.unlock()

        return childPID
    }

    // MARK: - Kill

    /// Sends SIGINT to the process, then SIGKILL after 3 seconds if still alive.
    func killProcess(pid: pid_t) {
        guard isProcessRunning(pid: pid) else { return }

        kill(pid, SIGINT)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, self.isProcessRunning(pid: pid) else { return }
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Status

    /// Returns `true` if the given PID is still a running process.
    func isProcessRunning(pid: pid_t) -> Bool {
        // kill with signal 0 checks existence without sending a signal
        return kill(pid, 0) == 0
    }

    // MARK: - Resource Cleanup

    private func cleanUp(pid: pid_t) {
        lock.lock()
        guard let info = processes.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        lock.unlock()

        info.readSource.cancel()

        // Reap the child
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)

        DispatchQueue.main.async { [weak self] in
            self?.onProcessExit?(pid, status)
        }
    }

    // MARK: - SIGCHLD Monitoring

    /// Monitors for child exits via a background thread calling waitpid.
    private func startSIGCHLDMonitor() {
        // Use a SIGCHLD dispatch source to detect child exits without blocking.
        let sigSource = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: .global(qos: .utility))
        signal(SIGCHLD, SIG_IGN) // Let the dispatch source handle it

        sigSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Reap all exited children
            while true {
                var status: Int32 = 0
                let pid = waitpid(-1, &status, WNOHANG)
                if pid <= 0 { break }
                self.cleanUp(pid: pid)
            }
        }

        sigSource.resume()

        // Keep the source alive for the lifetime of the manager.
        // Since ProcessManager is a singleton, this is fine.
        objc_setAssociatedObject(self, "sigchldSource", sigSource, .OBJC_ASSOCIATION_RETAIN)
    }

    // MARK: - Accessors

    /// Returns the PTYInfo for a given pid, if it exists.
    func info(for pid: pid_t) -> PTYInfo? {
        lock.lock()
        defer { lock.unlock() }
        return processes[pid]
    }

    /// Returns all active PIDs.
    var activePIDs: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(processes.keys)
    }

    /// Kills all active processes.
    func killAll() {
        let pids = activePIDs
        for pid in pids {
            killProcess(pid: pid)
        }
    }
}
