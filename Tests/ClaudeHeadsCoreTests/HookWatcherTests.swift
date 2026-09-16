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
        defer { withExtendedLifetime(watcher) {} }

        XCTAssertEqual(watcher.hookScriptPath(), stale.path)
        let contents = try String(contentsOf: stale, encoding: .utf8)
        XCTAssertEqual(contents, HookWatcher.notifyScriptContent, "Stale script must be overwritten on launch")
        let attrs = try FileManager.default.attributesOfItem(atPath: stale.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111, "Script must be executable")
    }

    func testMarkerFileTriggersOnTaskComplete() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
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

    // MARK: Subagent markers (notify.sh)

    private func subagentMarkerPath(_ id: String, agent: String, suffix: String) -> String {
        tempDir.appendingPathComponent("\(id).\(agent).\(suffix)").path
    }

    func testSubagentStartWritesStartMarkerContainingType() throws {
        let id = UUID().uuidString
        let json = """
        {"session_id":"abc","hook_event_name":"SubagentStart","agent_id":"agent-7f3","agent_type":"Explore","cwd":"/tmp"}
        """
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: json)

        XCTAssertEqual(status, 0)
        let path = subagentMarkerPath(id, agent: "agent-7f3", suffix: "start")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "SubagentStart should write <uuid>.<agent>.start")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "Explore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)), "SubagentStart must not write .done")
    }

    func testSubagentStopWritesStopMarker() throws {
        let id = UUID().uuidString
        let json = """
        {
          "hook_event_name": "SubagentStop",
          "agent_id": "a1b2c3",
          "agent_type": "general-purpose"
        }
        """
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: json)

        XCTAssertEqual(status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subagentMarkerPath(id, agent: "a1b2c3", suffix: "stop")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)))
    }

    func testSubagentEventWithoutAgentIDWritesNothing() throws {
        let id = UUID().uuidString
        let status = try runNotifyScript(
            environment: [HookWatcher.instanceIDEnvironmentVariable: id],
            stdin: "{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"Explore\"}"
        )

        XCTAssertEqual(status, 0)
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(entries, ["notify.sh"])
    }

    func testSubagentIDIsSanitisedToSafeCharacters() throws {
        let id = UUID().uuidString
        let status = try runNotifyScript(
            environment: [HookWatcher.instanceIDEnvironmentVariable: id],
            stdin: "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"../x.y/z\"}"
        )

        XCTAssertEqual(status, 0)
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(entries, ["\(id).xyz.stop", "notify.sh"].sorted())
    }

    func testInputWithoutEventNameFallsBackToDoneMarker() throws {
        // Manual/legacy invocation: something on stdin but no hook_event_name.
        let id = UUID().uuidString
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: "not json at all")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath(id)))
    }

    func testOtherNamedEventsWriteNothing() throws {
        // A user routing Notification/PreToolUse to notify.sh must not fake a Stop.
        for event in ["Notification", "PreToolUse", "UserPromptSubmit"] {
            let id = UUID().uuidString
            let status = try runNotifyScript(
                environment: [HookWatcher.instanceIDEnvironmentVariable: id],
                stdin: "{\"hook_event_name\":\"\(event)\"}"
            )
            XCTAssertEqual(status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)), "\(event) must not write .done")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(entries, ["notify.sh"])
    }

    func testEmptyPipedStdinWritesNothing() throws {
        // bash 3.2 discards partial input on read timeout; an empty read must not become a Stop.
        let id = UUID().uuidString
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: "")
        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)))
    }

    func testDeliveryOrderIsChronologicalWithDoneLast() throws {
        let id = UUID().uuidString
        let fm = FileManager.default
        let base = Date(timeIntervalSinceNow: -60)
        func write(_ name: String, at offset: TimeInterval) throws {
            let path = tempDir.appendingPathComponent(name).path
            fm.createFile(atPath: path, contents: Data())
            try fm.setAttributes([.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: path)
        }
        // Filename order would be: .done, .aaa.start, .zzz.start, .zzz.stop -- none of which is what happened.
        try write("\(id).zzz.start", at: 0)
        try write("\(id).zzz.stop", at: 1)
        try write("\(id).aaa.start", at: 2)
        try write("\(id).done", at: 2)   // same instant as aaa.start: done must come after it

        let ordered = HookWatcher.deliveryOrder(try fm.contentsOfDirectory(atPath: tempDir.path), in: tempDir)
        XCTAssertEqual(ordered, ["\(id).zzz.start", "\(id).zzz.stop", "\(id).aaa.start", "\(id).done"])
    }

    // MARK: HookMarker parsing

    func testParseDoneMarker() {
        let id = UUID()
        XCTAssertEqual(HookMarker.parse(filename: "\(id.uuidString).done"), .taskComplete(instance: id))
    }

    func testParseSubagentMarkers() {
        let id = UUID()
        XCTAssertEqual(
            HookMarker.parse(filename: "\(id.uuidString).agent-7f3.start"),
            .subagentStart(instance: id, agentID: "agent-7f3")
        )
        XCTAssertEqual(
            HookMarker.parse(filename: "\(id.uuidString).a1b2c3.stop"),
            .subagentStop(instance: id, agentID: "a1b2c3")
        )
    }

    func testParseRejectsMalformedMarkers() {
        let id = UUID().uuidString
        XCTAssertNil(HookMarker.parse(filename: "notify.sh"))
        XCTAssertNil(HookMarker.parse(filename: "\(id).start"), "start needs an agent id")
        XCTAssertNil(HookMarker.parse(filename: "\(id)..stop"), "empty agent id")
        XCTAssertNil(HookMarker.parse(filename: "\(id).agent.extra.done"), "done takes no agent id")
        XCTAssertNil(HookMarker.parse(filename: "not-a-uuid.agent.start"))
        XCTAssertNil(HookMarker.parse(filename: "\(id).bad/agent.start"))
        XCTAssertNil(HookMarker.parse(filename: "\(id).agent.tmp"), "temp files are not markers")
    }

    func testAgentTypeFromContentsFallsBackAndTrims() {
        XCTAssertEqual(HookMarker.agentType(fromContents: nil), "agent")
        XCTAssertEqual(HookMarker.agentType(fromContents: Data()), "agent")
        XCTAssertEqual(HookMarker.agentType(fromContents: Data(" Explore\n".utf8)), "Explore")
    }

    // MARK: Subagent events (HookWatcher)

    func testStartMarkerTriggersOnSubagentStartWithType() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        let id = UUID()

        let received = expectation(description: "onSubagentStart called")
        var got: (UUID, String, String)?
        watcher.onSubagentStart = { instance, agentID, type in
            got = (instance, agentID, type)
            received.fulfill()
        }
        let notDone = expectation(description: "onTaskComplete must not fire for a start marker")
        notDone.isInverted = true
        watcher.onTaskComplete = { _ in notDone.fulfill() }

        let path = subagentMarkerPath(id.uuidString, agent: "agent-1", suffix: "start")
        try "Explore".write(toFile: path, atomically: true, encoding: .utf8)

        wait(for: [received, notDone], timeout: 5.0)
        XCTAssertEqual(got?.0, id)
        XCTAssertEqual(got?.1, "agent-1")
        XCTAssertEqual(got?.2, "Explore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Marker should be removed after delivery")
    }

    func testStopMarkerTriggersOnSubagentStop() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        let id = UUID()

        let received = expectation(description: "onSubagentStop called")
        var got: (UUID, String)?
        watcher.onSubagentStop = { instance, agentID in
            got = (instance, agentID)
            received.fulfill()
        }

        FileManager.default.createFile(atPath: subagentMarkerPath(id.uuidString, agent: "agent-1", suffix: "stop"), contents: nil)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(got?.0, id)
        XCTAssertEqual(got?.1, "agent-1")
    }

    func testPreExistingMarkersAreSweptWithoutNotifying() throws {
        let staleID = UUID()
        FileManager.default.createFile(atPath: markerPath(staleID.uuidString), contents: nil)

        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }

        let notCalled = expectation(description: "stale marker must not be delivered")
        notCalled.isInverted = true
        watcher.onTaskComplete = { _ in notCalled.fulfill() }

        wait(for: [notCalled], timeout: 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(staleID.uuidString)),
                       "Stale marker should still be cleaned up")
    }

    func testNonUUIDMarkersAreIgnoredButCleanedUp() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }

        let notCalled = expectation(description: "non-UUID marker must not be delivered")
        notCalled.isInverted = true
        watcher.onTaskComplete = { _ in notCalled.fulfill() }

        let bogus = tempDir.appendingPathComponent("not-a-uuid.done").path
        let wrongSuffix = tempDir.appendingPathComponent("\(UUID().uuidString).txt").path
        FileManager.default.createFile(atPath: bogus, contents: nil)
        FileManager.default.createFile(atPath: wrongSuffix, contents: nil)

        wait(for: [notCalled], timeout: 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus), "Malformed .done markers are swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongSuffix), "Files without .done are left alone")
    }

    func testEachMarkerIsDeliveredExactlyOnce() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let ids = [UUID(), UUID(), UUID()]

        let received = expectation(description: "three markers delivered")
        received.expectedFulfillmentCount = ids.count
        var delivered: [UUID] = []
        watcher.onTaskComplete = { uuid in
            delivered.append(uuid)
            received.fulfill()
        }

        for id in ids {
            FileManager.default.createFile(atPath: markerPath(id.uuidString), contents: nil)
        }

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(Set(delivered), Set(ids))
        XCTAssertEqual(delivered.count, ids.count, "No duplicate deliveries")

        // Nothing further arrives once the markers have been consumed.
        let quiet = expectation(description: "no further deliveries")
        quiet.isInverted = true
        watcher.onTaskComplete = { _ in quiet.fulfill() }
        wait(for: [quiet], timeout: 0.5)
    }
}
