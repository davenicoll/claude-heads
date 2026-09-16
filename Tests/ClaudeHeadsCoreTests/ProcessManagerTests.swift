import Foundation
import XCTest

@testable import ClaudeHeadsCore

/// Collects PTY output on the main queue; calls `onBytes` for every chunk received.
private final class CapturingSink: TerminalOutputSink {
    private(set) var received: [UInt8] = []
    var onBytes: (() -> Void)?

    func feed(byteArray: ArraySlice<UInt8>) {
        received.append(contentsOf: byteArray)
        onBytes?()
    }

    var text: String { String(decoding: received, as: UTF8.self) }
}

final class ProcessManagerTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-heads-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: Session directory

    func testSessionDirectorySanitizesPath() {
        let dir = ProcessManager.sessionDirectory(for: "/Users/dave/Source/my.app_v2", home: tempHome)
        XCTAssertEqual(dir.lastPathComponent, "-Users-dave-Source-my-app-v2")
        XCTAssertTrue(dir.path.hasPrefix(tempHome.appendingPathComponent(".claude/projects").path))
    }

    func testSessionDirectorySanitizationIsASCIIOnly() {
        // Claude Code replaces everything outside [a-zA-Z0-9] with "-", including non-ASCII letters.
        let dir = ProcessManager.sessionDirectory(for: "/Users/dave/caf\u{E9}/pr\u{F8}j3kt", home: tempHome)
        XCTAssertEqual(dir.lastPathComponent, "-Users-dave-caf--pr-j3kt")
    }

    func testHasResumableSessionOnlyWhenJSONLExists() throws {
        let folder = "/Users/test/project"
        XCTAssertFalse(ProcessManager.hasResumableSession(for: folder, home: tempHome))

        let dir = ProcessManager.sessionDirectory(for: folder, home: tempHome)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(ProcessManager.hasResumableSession(for: folder, home: tempHome), "Empty dir has no session")

        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        XCTAssertFalse(ProcessManager.hasResumableSession(for: folder, home: tempHome))

        try Data().write(to: dir.appendingPathComponent("abc.jsonl"))
        XCTAssertTrue(ProcessManager.hasResumableSession(for: folder, home: tempHome))
    }

    // MARK: Arguments

    func testBuildArgumentsDropsContinueWithoutSession() {
        let args = ProcessManager.buildArguments(
            executable: "/usr/local/bin/claude",
            folderPath: tempHome.appendingPathComponent("nonexistent-project").path,
            settingsArgs: ["--continue", "--dangerously-skip-permissions"],
            extraArgs: ["--model", "opus"]
        )
        XCTAssertEqual(args, ["/usr/local/bin/claude", "--dangerously-skip-permissions", "--model", "opus"])
    }

    func testBuildArgumentsPreservesQuotesWithoutShellEscaping() {
        let args = ProcessManager.buildArguments(
            executable: "claude",
            folderPath: "/tmp/nowhere-\(UUID().uuidString)",
            settingsArgs: [],
            extraArgs: ["--append-system-prompt", "say \"hi\" and it's fine"]
        )
        XCTAssertEqual(args, ["claude", "--append-system-prompt", "say \"hi\" and it's fine"])
    }

    // MARK: Environment

    func testChildEnvironmentExportsInstanceIDAndExtendsPath() {
        let id = UUID()
        let env = ProcessManager.childEnvironment(
            instanceID: id,
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"]
        )
        XCTAssertEqual(env["CLAUDE_INSTANCE_ID"], id.uuidString)
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")

        let path = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(path.prefix(2)), ["/usr/bin", "/bin"], "Inherited PATH must come first")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains { $0.hasSuffix("/.local/bin") })
        XCTAssertTrue(path.contains { $0.hasSuffix("/.npm-global/bin") })
    }

    func testExtendedPathDoesNotDuplicateEntries() {
        let path = ProcessManager.extendedPath(inherited: "/opt/homebrew/bin:/usr/bin")
        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(entries.first, "/opt/homebrew/bin")
    }

    func testChildEnvironmentKeepsExistingLang() {
        let env = ProcessManager.childEnvironment(instanceID: UUID(), base: ["LANG": "en_GB.UTF-8"])
        XCTAssertEqual(env["LANG"], "en_GB.UTF-8")
    }

    // MARK: Executable resolution

    func testResolveExecutableSearchesPath() {
        XCTAssertEqual(ProcessManager.resolveExecutable("ls", searchPath: "/nonexistent:/bin"), "/bin/ls")
        XCTAssertNil(ProcessManager.resolveExecutable("definitely-not-a-binary-xyz", searchPath: "/bin"))
        XCTAssertEqual(ProcessManager.resolveExecutable("/bin/ls", searchPath: ""), "/bin/ls")
    }

    // MARK: Exit status

    func testDecodeExitStatus() {
        XCTAssertEqual(ProcessManager.decodeExitStatus(0), 0)
        XCTAssertEqual(ProcessManager.decodeExitStatus(3 << 8), 3)
        XCTAssertEqual(ProcessManager.decodeExitStatus(Int32(SIGKILL)), 128 + SIGKILL)
    }

    // MARK: Process lifecycle (real children via the spawn seam)

    private func spawnShell(_ manager: ProcessManager, _ script: String) -> pid_t {
        manager.spawn(
            executable: "/bin/sh",
            arguments: ["sh", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            cwd: "/",
            terminalView: nil,
            bridge: nil
        )
    }

    func testEOFDrivenReapReportsRealExitCode() {
        let manager = ProcessManager()
        let exited = expectation(description: "onProcessExit")
        var reported: (pid_t, Int32)?
        manager.onProcessExit = { pid, code in
            reported = (pid, code)
            exited.fulfill()
        }

        let pid = spawnShell(manager, "exit 3")
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(manager.isProcessRunning(pid: pid) || reported != nil)

        wait(for: [exited], timeout: 5.0)
        XCTAssertEqual(reported?.0, pid)
        XCTAssertEqual(reported?.1, 3)
        XCTAssertNil(manager.session(for: pid), "Session must be removed once reaped")
        XCTAssertFalse(manager.isProcessRunning(pid: pid))
        // The child is already reaped: waitpid must not find it.
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testExecFailureReportsExitCode127() {
        let manager = ProcessManager()
        let exited = expectation(description: "onProcessExit")
        var code: Int32?
        manager.onProcessExit = { _, c in
            code = c
            exited.fulfill()
        }

        let pid = manager.spawn(
            executable: "/nonexistent/binary-\(UUID().uuidString)",
            arguments: ["x"],
            environment: [:],
            cwd: "/",
            terminalView: nil,
            bridge: nil
        )
        XCTAssertGreaterThan(pid, 0, "fork succeeds; only exec fails")
        wait(for: [exited], timeout: 5.0)
        XCTAssertEqual(code, ProcessManager.exitCodeExecFailed)
    }

    func testChdirFailureReportsExitCode126() {
        let manager = ProcessManager()
        let exited = expectation(description: "onProcessExit")
        var code: Int32?
        manager.onProcessExit = { _, c in
            code = c
            exited.fulfill()
        }

        let pid = manager.spawn(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "exit 0"],
            environment: [:],
            cwd: tempHome.appendingPathComponent("does-not-exist").path,
            terminalView: nil,
            bridge: nil
        )
        XCTAssertGreaterThan(pid, 0)
        wait(for: [exited], timeout: 5.0)
        XCTAssertEqual(code, ProcessManager.exitCodeChdirFailed)
    }

    func testKillAllIsBoundedAndReapsChildren() {
        let manager = ProcessManager()
        var exitReported = false
        manager.onProcessExit = { _, _ in exitReported = true }

        // `trap '' HUP` makes the child ignore SIGHUP so killAll has to escalate to SIGKILL.
        let pid1 = spawnShell(manager, "trap '' HUP; sleep 30")
        let pid2 = manager.spawn(
            executable: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: [:],
            cwd: "/",
            terminalView: nil,
            bridge: nil
        )
        XCTAssertGreaterThan(pid1, 0)
        XCTAssertGreaterThan(pid2, 0)
        XCTAssertEqual(Set(manager.activePIDs), [pid1, pid2])

        // Let the shells actually start and install the trap.
        Thread.sleep(forTimeInterval: 0.3)

        let start = Date()
        manager.killAll(timeout: 1.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.5, "killAll must return within roughly the timeout")
        XCTAssertTrue(manager.activePIDs.isEmpty)

        for pid in [pid1, pid2] {
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "pid \(pid) must already be reaped")
            XCTAssertEqual(errno, ECHILD)
            XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) must be gone")
        }

        // The read sources' EOF handlers may still fire; they must not report exits after killAll.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertFalse(exitReported, "killAll owns the shutdown; no exit callbacks expected")
    }

    func testKillAllWithNoSessionsIsNoOp() {
        let manager = ProcessManager()
        let start = Date()
        manager.killAll(timeout: 2.0)
        manager.killAll(timeout: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testChildReceivesArgumentsAndEnvironmentVerbatim() {
        let manager = ProcessManager()
        let outFile = tempHome.appendingPathComponent("out.txt").path
        let exited = expectation(description: "onProcessExit")
        manager.onProcessExit = { _, _ in exited.fulfill() }

        let tricky = "say \"hi\" and it's $HOME fine"
        let pid = manager.spawn(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "printf '%s\\n%s\\n' \"$1\" \"$CLAUDE_INSTANCE_ID\" > \"$2\"", "sh", tricky, outFile],
            environment: ["PATH": "/usr/bin:/bin", "CLAUDE_INSTANCE_ID": "ABC-123"],
            cwd: "/",
            terminalView: nil,
            bridge: nil
        )
        XCTAssertGreaterThan(pid, 0)
        wait(for: [exited], timeout: 5.0)

        let output = try? String(contentsOfFile: outFile, encoding: .utf8)
        XCTAssertEqual(output, "\(tricky)\nABC-123\n")
    }

    // MARK: PTY round trip

    func testPTYRoundTripThroughCatAndEOFExit() throws {
        let manager = ProcessManager()
        let sink = CapturingSink()

        let exited = expectation(description: "onProcessExit")
        var exitCode: Int32?
        manager.onProcessExit = { _, code in
            exitCode = code
            exited.fulfill()
        }
        var activityPIDs: [pid_t] = []
        manager.onProcessActivity = { activityPIDs.append($0) }

        let pid = manager.spawn(
            executable: "/bin/cat",
            arguments: ["cat"],
            environment: ["PATH": "/usr/bin:/bin"],
            cwd: "/",
            terminalView: nil,
            bridge: nil,
            output: sink
        )
        XCTAssertGreaterThan(pid, 0)
        let session = try XCTUnwrap(manager.session(for: pid))

        // The PTY line discipline echoes input and cat writes it back, so the payload must show
        // up at least twice in the output; waiting for the second copy proves cat itself ran.
        let payload = "round-trip-\(UUID().uuidString)"
        let echoed = expectation(description: "payload read back from the PTY")
        sink.onBytes = {
            if sink.text.components(separatedBy: payload).count - 1 >= 2 {
                echoed.fulfill()
                sink.onBytes = nil
            }
        }
        session.write(Array((payload + "\n").utf8))
        wait(for: [echoed], timeout: 5.0)

        XCTAssertTrue(manager.isProcessRunning(pid: pid))
        XCTAssertFalse(activityPIDs.isEmpty)
        XCTAssertTrue(activityPIDs.allSatisfy { $0 == pid })

        // Ctrl-D at the start of a line delivers EOF to cat, which exits 0.
        session.write([0x04])
        wait(for: [exited], timeout: 5.0)

        XCTAssertEqual(exitCode, 0)
        XCTAssertNil(manager.session(for: pid))
        XCTAssertFalse(manager.isProcessRunning(pid: pid))
        XCTAssertTrue(session.isReaped)

        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "Child must already be reaped (no zombie)")
        XCTAssertEqual(errno, ECHILD)
    }

    func testWriteAfterExitIsIgnored() throws {
        let manager = ProcessManager()
        let exited = expectation(description: "onProcessExit")
        manager.onProcessExit = { _, _ in exited.fulfill() }

        let pid = spawnShell(manager, "exit 0")
        let session = try XCTUnwrap(manager.session(for: pid))
        wait(for: [exited], timeout: 5.0)

        // Must not crash or touch the closed fd.
        session.write(Array("late\n".utf8))
        session.resize(cols: 100, rows: 40)
        let settle = expectation(description: "settle")
        session.queue.async { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertTrue(session.isClosed)
    }
}
