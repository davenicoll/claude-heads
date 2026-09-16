import CPTYHelpers
import Darwin
import Foundation
import SwiftTerm

// MARK: - TerminalOutputSink

/// Receives raw bytes read from a PTY. `TerminalView` conforms directly; tests supply a stub so
/// the PTY read path can be exercised without a GUI.
protocol TerminalOutputSink: AnyObject {
    func feed(byteArray: ArraySlice<UInt8>)
}

extension TerminalView: TerminalOutputSink {}

// MARK: - PTYSession

/// Owns the master side of a PTY and the child process attached to it.
///
/// All reads, writes, resizes and the final close of the master fd are serialized on
/// `queue`, and every operation checks `isClosed` first, so nothing can touch the fd
/// after it has been closed.
final class PTYSession {
    let pid: pid_t
    let masterFD: Int32
    let queue: DispatchQueue

    weak var output: TerminalOutputSink?

    /// Set once the fd is scheduled for close. Guarded by `stateLock`.
    private var _isClosed = false
    /// Set once the child has been reaped with waitpid. Guarded by `stateLock`.
    private var _isReaped = false
    private let stateLock = NSLock()

    fileprivate var readSource: DispatchSourceRead?

    /// Longest a single write will wait for the child to drain the PTY input buffer before
    /// giving up, so a stopped child can never wedge the session queue (and thus `killAll`).
    static let writeTimeout: TimeInterval = 1.0

    init(pid: pid_t, masterFD: Int32, output: TerminalOutputSink?) {
        self.pid = pid
        self.masterFD = masterFD
        self.output = output
        self.queue = DispatchQueue(label: "com.claudeheads.pty.\(pid)", qos: .userInteractive)
    }

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isClosed
    }

    var isReaped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isReaped
    }

    /// Marks the session closed. Returns `false` if it was already closed.
    fileprivate func markClosed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if _isClosed { return false }
        _isClosed = true
        return true
    }

    fileprivate func markReaped() {
        stateLock.lock(); defer { stateLock.unlock() }
        _isReaped = true
    }

    // MARK: I/O (serialized on `queue`)

    /// Writes user input to the child. Safe to call from any thread.
    ///
    /// The write is bounded: it re-checks `isClosed` on every retry and abandons the input
    /// after `writeTimeout` of the child not reading, so it can never block the queue forever.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard !isClosed else { return }
            let deadline = Date().addingTimeInterval(Self.writeTimeout)
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var total = 0
                while total < bytes.count {
                    if isClosed { return }
                    let written = Darwin.write(masterFD, base.advanced(by: total), bytes.count - total)
                    if written < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN {
                            if Date() >= deadline { return }
                            // Non-blocking fd is full; wait briefly for the child to drain it.
                            var pfd = pollfd(fd: masterFD, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&pfd, 1, 50)
                            continue
                        }
                        return
                    }
                    total += written
                }
            }
        }
    }

    /// Updates the PTY window size and notifies the child. Safe to call from any thread.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        queue.async { [self] in
            guard !isClosed else { return }
            pty_set_window_size(masterFD, UInt16(clamping: rows), UInt16(clamping: cols))
            kill(pid, SIGWINCH)
        }
    }
}

// MARK: - ProcessManager

final class ProcessManager {
    static let shared = ProcessManager()

    /// Exit code reported when the child could not `chdir` into the project folder.
    static let exitCodeChdirFailed: Int32 = 126
    /// Exit code reported when `execve` failed (the executable could not be started).
    static let exitCodeExecFailed: Int32 = 127

    /// Active sessions keyed by child PID.
    private var sessions: [pid_t: PTYSession] = [:]
    private let lock = NSLock()

    /// Called on the main queue when a child process exits. The second argument is the
    /// exit code (or 128 + signal number if the child was killed by a signal).
    var onProcessExit: ((pid_t, Int32) -> Void)?

    /// Called on the main queue when PTY output is received (process is active).
    var onProcessActivity: ((pid_t) -> Void)?

    /// Extra directories appended to the inherited PATH so `claude` can be found from a GUI app.
    private static let extraPathEntries: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ]
    }()

    /// `init` is internal (not private) so tests can use an isolated instance.
    init() {}

    // MARK: - Spawn

    /// Spawns a `claude` CLI process inside a pseudo-terminal for the given head.
    ///
    /// Everything that needs Swift runtime support (argument/environment construction,
    /// settings, path lookup) happens in the parent before `forkpty`. The child branch only
    /// calls async-signal-safe functions (`chdir`, `execve`, `write`, `_exit`).
    ///
    /// - Returns: The child PID, or -1 on failure.
    @discardableResult
    func spawnProcess(
        head: HeadInstance,
        terminalView: TerminalView,
        bridge: TerminalBridge
    ) -> pid_t {
        let folderPath = head.folderPath
        let environment = Self.childEnvironment(instanceID: head.id)
        let searchPath = environment["PATH"] ?? ""

        guard let claudeBin = Self.resolveExecutable("claude", searchPath: searchPath) else {
            let message = "claude-heads: could not find `claude` in PATH.\r\n"
                + "Searched: \(searchPath)\r\n"
                + "Install Claude Code (https://claude.ai/code) or add it to your PATH, then restart the head.\r\n"
            fputs(message, stderr)
            terminalView.feed(text: message)
            return -1
        }

        let argv = Self.buildArguments(
            executable: claudeBin,
            folderPath: folderPath,
            settingsArgs: AppSettings.shared.effectiveCLIArgs,
            extraArgs: head.extraArgs
        )

        return spawn(
            executable: claudeBin,
            arguments: argv,
            environment: environment,
            cwd: folderPath,
            terminalView: terminalView,
            bridge: bridge
        )
    }

    /// Forks a child attached to a new PTY and execs `executable` with the given argv/env.
    ///
    /// `arguments` must include argv[0]. This is the seam used by `spawnProcess` and by tests;
    /// the terminal view and bridge are optional so children can be driven headlessly. PTY output
    /// is delivered to `output` when given, otherwise to `terminalView`.
    ///
    /// - Returns: The child PID, or -1 on failure.
    @discardableResult
    func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        terminalView: TerminalView?,
        bridge: TerminalBridge?,
        output: TerminalOutputSink? = nil
    ) -> pid_t {
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()

        // Build every C buffer the child needs *before* forking so the child never allocates.
        let cArgv = CStringArray(arguments)
        let cEnvp = CStringArray(envp)
        let cPath = CStringArray([executable])
        let cCwd = CStringArray([cwd])
        let cChdirError = CStringArray(["claude-heads: cannot change to directory \(cwd)\r\n"])
        let cExecError = CStringArray(["claude-heads: failed to start \(executable)\r\n"])

        var winSize = Self.initialWindowSize(for: terminalView)
        var masterFD: Int32 = 0

        // Hoist every pointer the child will touch into locals and pin the owning objects for
        // the whole fork/exec sequence. Without `withExtendedLifetime`, ARC is free to release
        // the arrays right after the last pointer load, which would run `free()` in the child.
        let childPID: pid_t = withExtendedLifetime((cArgv, cEnvp, cPath, cCwd, cChdirError, cExecError)) {
            let argvPtr = cArgv.pointer
            let envpPtr = cEnvp.pointer
            let pathPtr = cPath.pointer[0]!
            let cwdPtr = cCwd.pointer[0]!
            let chdirErrPtr = cChdirError.pointer[0]!
            let chdirErrLen = strlen(chdirErrPtr)
            let execErrPtr = cExecError.pointer[0]!
            let execErrLen = strlen(execErrPtr)

            let pid = forkpty(&masterFD, nil, nil, &winSize)

            if pid == 0 {
                // ---- Child process: async-signal-safe calls only ----
                if chdir(cwdPtr) != 0 {
                    _ = Darwin.write(STDERR_FILENO, chdirErrPtr, chdirErrLen)
                    _exit(Self.exitCodeChdirFailed)
                }
                execve(pathPtr, argvPtr, envpPtr)
                _ = Darwin.write(STDERR_FILENO, execErrPtr, execErrLen)
                _exit(Self.exitCodeExecFailed)
            }
            return pid
        }

        guard childPID > 0 else {
            perror("forkpty")
            terminalView?.feed(text: "claude-heads: forkpty failed (\(String(cString: strerror(errno))))\r\n")
            return -1
        }

        // ---- Parent process ----

        // Set master fd to non-blocking so reads/writes never stall the I/O queue.
        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        let session = PTYSession(pid: childPID, masterFD: masterFD, output: output ?? terminalView)
        bridge?.session = session

        let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: session.queue)
        readSource.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleReadable(session)
        }
        readSource.setCancelHandler {
            close(masterFD)
        }
        session.readSource = readSource

        lock.lock()
        sessions[childPID] = session
        lock.unlock()

        readSource.resume()
        return childPID
    }

    // MARK: - Reading / EOF-driven reaping

    /// Runs on the session queue whenever the master fd is readable.
    private func handleReadable(_ session: PTYSession) {
        guard !session.isClosed else { return }

        var buffer = [UInt8](repeating: 0, count: 16384)
        var sawEOF = false
        let pid = session.pid

        // Drain everything currently available. Output is always forwarded to the view, even
        // when EOF follows in the same pass: feeding the view never touches the fd, and the
        // child's final bytes must not be lost just because the session closed afterwards.
        while true {
            let n = read(session.masterFD, &buffer, buffer.count)
            if n > 0 {
                let data = Array(buffer[0..<n])
                DispatchQueue.main.async { [weak self, weak sink = session.output] in
                    sink?.feed(byteArray: ArraySlice(data))
                    self?.onProcessActivity?(pid)
                }
                continue
            }
            if n == 0 {
                sawEOF = true
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                // Nothing more for now.
            } else {
                // EIO (slave side closed) or another unrecoverable error.
                sawEOF = true
            }
            break
        }

        guard sawEOF else { return }
        finishSession(session, notify: true)
    }

    /// Closes the fd, reaps the child and (optionally) reports the exit. Must run on `session.queue`.
    private func finishSession(_ session: PTYSession, notify: Bool) {
        guard session.markClosed() else { return }
        session.readSource?.cancel()

        lock.lock()
        sessions.removeValue(forKey: session.pid)
        lock.unlock()

        let status = reap(session, gracePeriod: 2.0)

        if notify {
            let pid = session.pid
            DispatchQueue.main.async { [weak self] in
                self?.onProcessExit?(pid, status)
            }
        }
    }

    /// Reaps the child, polling `waitpid(WNOHANG)` for up to `gracePeriod` seconds. If the child
    /// is somehow still alive after that (it closed its terminal but kept running) it is killed.
    /// Returns the decoded exit code.
    @discardableResult
    private func reap(_ session: PTYSession, gracePeriod: TimeInterval) -> Int32 {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(gracePeriod)

        while true {
            let result = waitpid(session.pid, &status, WNOHANG)
            if result == session.pid {
                session.markReaped()
                return Self.decodeExitStatus(status)
            }
            if result < 0 {
                if errno == EINTR { continue }
                // ECHILD: already reaped elsewhere.
                session.markReaped()
                return -1
            }
            if Date() >= deadline { break }
            usleep(10_000)
        }

        Self.signalGroup(pid: session.pid, SIGKILL)
        while waitpid(session.pid, &status, 0) < 0 && errno == EINTR {}
        session.markReaped()
        return Self.decodeExitStatus(status)
    }

    /// Converts a raw `waitpid` status into an exit code (128 + signal for signalled children).
    static func decodeExitStatus(_ status: Int32) -> Int32 {
        let termSignal = status & 0x7f
        if termSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + termSignal
    }

    // MARK: - Kill

    /// Asks the process to hang up, then force-kills it after 2 seconds if it is still around.
    /// The PTY read source observes EOF and performs the actual reaping.
    func killProcess(pid: pid_t) {
        guard let session = session(for: pid) else { return }

        Self.signalGroup(pid: pid, SIGHUP)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self, weak session] in
            guard let self, let session, !session.isReaped else { return }
            Self.signalGroup(pid: pid, SIGKILL)
            // If the child ignored SIGHUP and kept the slave open, the read source never saw EOF.
            // SIGKILL closes the slave, which delivers EOF on the master and reaps normally; as a
            // backstop, finish explicitly if that has not happened shortly afterwards.
            session.queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak session] in
                guard let self, let session else { return }
                self.finishSession(session, notify: true)
            }
        }
    }

    /// Synchronously terminates every active process. Sends SIGHUP to each process group, waits
    /// up to `timeout` seconds for them to exit, then SIGKILLs and reaps whatever is left.
    /// Returns only once every child has been reaped, so it is safe to call right before
    /// `NSApplication.terminate`. Idempotent: calling it with no sessions is a no-op.
    func killAll(timeout: TimeInterval = 2.0) {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        guard !all.isEmpty else { return }

        // Mark every session closed *without* waiting on its queue: a pending write loop or an
        // in-flight reap must not be able to extend the shutdown deadline. Pending I/O blocks
        // observe `isClosed` and bail out; the cancel handler closes the fd once they have.
        for session in all where session.markClosed() {
            session.queue.async { [session] in
                session.readSource?.cancel()
            }
        }

        for session in all where !session.isReaped {
            Self.signalGroup(pid: session.pid, SIGHUP)
        }

        var pending = all.filter { !$0.isReaped }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0

        while !pending.isEmpty && Date() < deadline {
            pending.removeAll { session in
                let result = waitpid(session.pid, &status, WNOHANG)
                if result == session.pid || (result < 0 && errno != EINTR) {
                    session.markReaped()
                    return true
                }
                return false
            }
            if !pending.isEmpty { usleep(20_000) }
        }

        for session in pending {
            Self.signalGroup(pid: session.pid, SIGKILL)
            while waitpid(session.pid, &status, 0) < 0 && errno == EINTR {}
            session.markReaped()
        }
    }

    /// Signals the child's process group (forkpty makes the child a session and group leader),
    /// falling back to the pid alone if the group no longer exists.
    private static func signalGroup(pid: pid_t, _ sig: Int32) {
        if kill(-pid, sig) != 0 {
            kill(pid, sig)
        }
    }

    // MARK: - Status

    /// Returns `true` if the given PID belongs to an active, un-reaped session.
    func isProcessRunning(pid: pid_t) -> Bool {
        guard let session = session(for: pid) else { return false }
        return !session.isReaped
    }

    // MARK: - Accessors

    func session(for pid: pid_t) -> PTYSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[pid]
    }

    /// Returns all active PIDs.
    var activePIDs: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.keys)
    }

    // MARK: - Argument / environment construction (parent side)

    /// Builds the argv for `claude`. `--continue` is only passed when a resumable session exists
    /// for the folder, so the tracked pid is always `claude` itself (no shell wrapper).
    static func buildArguments(
        executable: String,
        folderPath: String,
        settingsArgs: [String],
        extraArgs: [String]
    ) -> [String] {
        var args = [executable]
        let wantsContinue = settingsArgs.contains("--continue") || extraArgs.contains("--continue")
        if wantsContinue && hasResumableSession(for: folderPath) {
            args.append("--continue")
        }
        args.append(contentsOf: settingsArgs.filter { $0 != "--continue" })
        args.append(contentsOf: extraArgs.filter { $0 != "--continue" })
        return args
    }

    /// Claude Code stores sessions under `~/.claude/projects/<sanitized path>/*.jsonl`, where every
    /// character outside `[a-zA-Z0-9]` in the absolute project path is replaced with `-`.
    /// The check is ASCII-only on purpose to match Claude Code's regex exactly.
    static func sessionDirectory(for folderPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let sanitized = String(folderPath.map { ch -> Character in
            ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-"
        })
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(sanitized, isDirectory: true)
    }

    static func hasResumableSession(for folderPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let dir = sessionDirectory(for: folderPath, home: home)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return entries.contains { $0.hasSuffix(".jsonl") }
    }

    /// The child's environment: the parent's, with PATH extended, terminal variables set and
    /// `CLAUDE_INSTANCE_ID` exported so hooks can identify the head.
    static func childEnvironment(
        instanceID: UUID,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["PATH"] = extendedPath(inherited: base["PATH"])
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        env["CLAUDE_INSTANCE_ID"] = instanceID.uuidString
        return env
    }

    /// Inherits the parent's PATH and appends common install locations that are missing.
    static func extendedPath(inherited: String?) -> String {
        var entries = (inherited ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if entries.isEmpty {
            entries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }
        for extra in extraPathEntries where !entries.contains(extra) {
            entries.append(extra)
        }
        return entries.joined(separator: ":")
    }

    /// Finds an executable by searching `searchPath`.
    static func resolveExecutable(_ name: String, searchPath: String) -> String? {
        if name.contains("/") {
            return access(name, X_OK) == 0 ? name : nil
        }
        for dir in searchPath.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Initial window size

    /// Uses the terminal's current grid if the view has laid out; otherwise derives the grid from
    /// the view's frame and cell metrics so claude does not start at 80x24 and then get resized.
    private static func initialWindowSize(for terminalView: TerminalView?) -> winsize {
        var ws = winsize()
        var cols = 0
        var rows = 0

        if let terminalView {
            // Force any pending Auto Layout so SwiftTerm has computed cols/rows for its real frame
            // (TerminalWindowController lays the view out at the panel's configured size).
            terminalView.superview?.layoutSubtreeIfNeeded()

            let bounds = terminalView.bounds
            if bounds.width > 0, bounds.height > 0 {
                let terminal = terminalView.getTerminal()
                cols = terminal.cols
                rows = terminal.rows
            }
        }

        if cols <= 0 || rows <= 0 {
            cols = 80
            rows = 24
        }

        ws.ws_col = UInt16(clamping: cols)
        ws.ws_row = UInt16(clamping: rows)
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        return ws
    }
}

// MARK: - CStringArray

/// A NULL-terminated array of `strdup`'d C strings suitable for `execve`. Built in the parent so
/// the child never has to allocate after `fork`.
final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for (i, s) in strings.enumerated() {
            pointer[i] = strdup(s)
        }
        pointer[count] = nil
    }

    deinit {
        for i in 0..<count {
            free(pointer[i])
        }
        pointer.deallocate()
    }
}
