import Foundation
import XCTest

@testable import ClaudeHeadsCore

// MARK: - HookWatcher Tests

final class HookWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-heads-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private func markerPath(_ id: String) -> String {
        tempDir.appendingPathComponent("\(id).done").path
    }

    /// Writes notify.sh into the temp dir the same way HookWatcher does and runs it.
    @discardableResult
    private func runNotifyScript(
        environment: [String: String] = [:],
        arguments: [String] = [],
        stdin: String? = "{\"hook_event_name\":\"Stop\"}"
    ) throws -> Int32 {
        let scriptURL = tempDir.appendingPathComponent("notify.sh")
        try HookWatcher.notifyScriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: HookWatcher.instanceIDEnvironmentVariable)
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        if let stdin, let data = stdin.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: notify.sh

    func testScriptWritesMarkerFromEnvironmentVariable() throws {
        let id = UUID().uuidString
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath(id)),
                      "CLAUDE_INSTANCE_ID should produce a <uuid>.done marker")
    }

    func testScriptFallsBackToFirstArgument() throws {
        let id = UUID().uuidString
        let status = try runNotifyScript(arguments: [id])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath(id)),
                      "$1 should be used when CLAUDE_INSTANCE_ID is unset")
    }

    func testEnvironmentVariableTakesPrecedenceOverArgument() throws {
        let envID = UUID().uuidString
        let argID = UUID().uuidString
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: envID], arguments: [argID])

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath(envID)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(argID)))
    }

    func testScriptExitsZeroSilentlyWithoutInstanceID() throws {
        let status = try runNotifyScript()

        XCTAssertEqual(status, 0, "Script must never fail the user's claude session")
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(entries, ["notify.sh"], "No marker should be written without an id")
    }

    func testScriptRejectsPathTraversalInInstanceID() throws {
        let status = try runNotifyScript(
            environment: [HookWatcher.instanceIDEnvironmentVariable: "../escaped"]
        )

        XCTAssertEqual(status, 0)
        let escaped = tempDir.deletingLastPathComponent().appendingPathComponent("escaped.done").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped))
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(entries, ["notify.sh"])
    }

    func testScriptDoesNotHangWhenStdinIsLeftOpen() throws {
        // Run without writing or closing stdin from a pipe: the script must not block reading it.
        let scriptURL = tempDir.appendingPathComponent("notify.sh")
        try HookWatcher.notifyScriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env[HookWatcher.instanceIDEnvironmentVariable] = UUID().uuidString
        process.environment = env
        let openPipe = Pipe()
        process.standardInput = openPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = expectation(description: "script exits without stdin being closed")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()

        wait(for: [exited], timeout: 5.0)
        XCTAssertEqual(process.terminationStatus, 0)
        try? openPipe.fileHandleForWriting.close()
    }

    // MARK: HookWatcher

    func testInitWritesExecutableNotifyScript() throws {
        let stale = tempDir.appendingPathComponent("notify.sh")
        try "#!/bin/sh\necho stale\n".write(to: stale, atomically: true, encoding: .utf8)

        let watcher = HookWatcher(hooksDirectory: tempDir)

        XCTAssertEqual(watcher.hookScriptPath(), stale.path)
        let contents = try String(contentsOf: stale, encoding: .utf8)
        XCTAssertEqual(contents, HookWatcher.notifyScriptContent, "Stale script must be overwritten on launch")
        let attrs = try FileManager.default.attributesOfItem(atPath: stale.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "Script must be executable")
    }

    func testMarkerFileTriggersOnTaskComplete() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        let id = UUID()

        let received = expectation(description: "onTaskComplete called")
        var receivedID: UUID?
        watcher.onTaskComplete = { uuid in
            receivedID = uuid
            received.fulfill()
        }

        FileManager.default.createFile(atPath: markerPath(id.uuidString), contents: nil)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(receivedID, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id.uuidString)),
                       "Marker should be removed after delivery")
    }

    func testPreExistingMarkersAreSweptWithoutNotifying() throws {
        let staleID = UUID()
        FileManager.default.createFile(atPath: markerPath(staleID.uuidString), contents: nil)

        let watcher = HookWatcher(hooksDirectory: tempDir)

        let notCalled = expectation(description: "stale marker must not be delivered")
        notCalled.isInverted = true
        watcher.onTaskComplete = { _ in notCalled.fulfill() }

        wait(for: [notCalled], timeout: 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(staleID.uuidString)),
                       "Stale marker should still be cleaned up")
    }
}
