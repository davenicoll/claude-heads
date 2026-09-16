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
        watcher.onTaskComplete = { uuid, _ in
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

    func testSubagentStartWritesStartMarkerContainingRawPayload() throws {
        let id = UUID().uuidString
        let json = """
        {"session_id":"abc","hook_event_name":"SubagentStart","agent_id":"agent-7f3","agent_type":"Explore","cwd":"/tmp"}
        """
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: json)

        XCTAssertEqual(status, 0)
        let path = subagentMarkerPath(id, agent: "agent-7f3", suffix: "start")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "SubagentStart should write <uuid>.<agent>.start")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), json, "marker holds stdin verbatim")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)), "SubagentStart must not write .done")
    }

    func testSubagentStopWritesStopMarkerContainingRawPayload() throws {
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
        let path = subagentMarkerPath(id, agent: "a1b2c3", suffix: "stop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), json, "multi-line JSON is kept intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id)))
    }

    func testStopWritesDoneMarkerContainingRawPayload() throws {
        let id = UUID().uuidString
        // Real 2.1.x shape: nested background_tasks, escaped quotes, newlines and non-ASCII text.
        let json = """
        {"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"He said \\"agent_id\\": done \\u00e9 \\n \\ud83d\\ude80 caf\u{00E9} 🚀","background_tasks":[{"id":"af7589e59f71169d7","type":"subagent","status":"running","description":"Settings height","agent_type":"general-purpose"}],"session_crons":[]}
        """
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: json)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOfFile: markerPath(id), encoding: .utf8), json)
        let payload = HookPayload.parse(FileManager.default.contents(atPath: markerPath(id)))
        XCTAssertEqual(payload.backgroundTasks?.map(\.id), ["af7589e59f71169d7"], "round-trips through the script")
    }

    func testLargePayloadIsWrittenIntact() throws {
        let id = UUID().uuidString
        let filler = String(repeating: "x", count: 600_000)
        let json = "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"big1\",\"last_assistant_message\":\"\(filler)\"}"
        let status = try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: json)

        XCTAssertEqual(status, 0)
        let path = subagentMarkerPath(id, agent: "big1", suffix: "stop")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), json)
    }

    func testRoutingUsesTheFirstOccurrenceOfAKey() throws {
        // Nested arrays (session_crons, background_tasks) repeat key names; a later nested
        // "agent_id" or "hook_event_name" must not hijack the filename or the event.
        let id = UUID().uuidString
        let nestedAgentID = """
        {"hook_event_name":"SubagentStop","agent_id":"real1","session_crons":[{"agent_id":"cronX"}]}
        """
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id], stdin: nestedAgentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subagentMarkerPath(id, agent: "real1", suffix: "stop")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subagentMarkerPath(id, agent: "cronX", suffix: "stop")))

        let id2 = UUID().uuidString
        let nestedEvent = """
        {"hook_event_name":"SubagentStop","agent_id":"a1","background_tasks":[{"id":"t","hook_event_name":"Stop","status":"running"}]}
        """
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id2], stdin: nestedEvent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subagentMarkerPath(id2, agent: "a1", suffix: "stop")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(id2)), "a nested Stop must not fake the parent's Stop")
    }

    func testNoTempFilesAreLeftBehind() throws {
        let id = UUID().uuidString
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id],
                            stdin: "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"t1\"}")
        try runNotifyScript(environment: [HookWatcher.instanceIDEnvironmentVariable: id])
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(entries, ["\(id).done", "\(id).t1.start", "notify.sh"].sorted())
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

    // MARK: HookPayload parsing

    func testPayloadParsesAgentTypeAndTrims() {
        let payload = HookPayload.parse(Data("{\"agent_id\":\"a.1\",\"agent_type\":\" Explore \"}".utf8))
        XCTAssertEqual(payload.agentID, "a.1", "raw id, not the filename-sanitised one")
        XCTAssertEqual(payload.agentType, "Explore")
        XCTAssertNil(payload.description)
        XCTAssertNil(payload.backgroundTasks, "no background_tasks key means nil, not an empty list")
    }

    func testPayloadWithEmptyAgentTypeYieldsEmptyString() {
        let payload = HookPayload.parse(Data("{\"agent_id\":\"a1\",\"agent_type\":\"\"}".utf8))
        XCTAssertEqual(payload.agentType, "")
    }

    func testPayloadFallsBackToEmptyOnBadContent() {
        XCTAssertEqual(HookPayload.parse(nil), .empty)
        XCTAssertEqual(HookPayload.parse(Data()), .empty)
        XCTAssertEqual(HookPayload.parse(Data("Explore".utf8)), .empty, "legacy plain-text contents")
        XCTAssertEqual(HookPayload.parse(Data("{\"agent_type\":\"Ex".utf8)), .empty, "truncated JSON")
        XCTAssertEqual(HookPayload.parse(Data("[1,2,3]".utf8)), .empty, "non-object root")
        XCTAssertEqual(HookPayload.parse(Data("\"str\"".utf8)), .empty, "scalar root")
        XCTAssertEqual(HookPayload.parse(Data("{\"agent_type\":42}".utf8)), .empty, "wrong field type")
        XCTAssertEqual(HookPayload.parse(Data([0xFF, 0xFE, 0x00])), .empty, "binary garbage")
    }

    func testPayloadParsesBackgroundTasksIncludingTeammates() {
        let json = """
        {"hook_event_name":"SubagentStop","agent_id":"a6f7","agent_type":"","background_tasks":[
          {"id":"af7589e59f71169d7","type":"subagent","status":"running","description":"Settings height and hook gating","agent_type":"general-purpose"},
          {"id":"tksfpzdbj","type":"teammate","status":"running","description":"Run `sleep 5` and return..."},
          {"id":"","type":"subagent","status":"running"},
          "not an object",
          {"type":"subagent","status":"running"}
        ],"session_crons":[]}
        """
        let payload = HookPayload.parse(Data(json.utf8))
        XCTAssertEqual(payload.agentType, "")
        XCTAssertEqual(payload.backgroundTasks, [
            BackgroundTask(id: "af7589e59f71169d7", type: "subagent", description: "Settings height and hook gating",
                           status: "running", agentType: "general-purpose"),
            BackgroundTask(id: "tksfpzdbj", type: "teammate", description: "Run `sleep 5` and return...",
                           status: "running", agentType: nil),
        ], "entries without an id or that are not objects are dropped; teammates keep a nil agent_type")
    }

    func testPayloadWithEmptyBackgroundTasksIsAnEmptyListNotNil() {
        let payload = HookPayload.parse(Data("{\"hook_event_name\":\"Stop\",\"background_tasks\":[]}".utf8))
        XCTAssertEqual(payload.backgroundTasks, [])
    }

    // MARK: Subagent events (HookWatcher)

    func testStartMarkerTriggersOnSubagentStartWithType() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let received = expectation(description: "onSubagentStart called")
        var got: (UUID, String, String, String?)?
        watcher.onSubagentStart = { instance, agentID, type, description in
            got = (instance, agentID, type, description)
            received.fulfill()
        }
        // Every callback for one marker is delivered in the same main-queue block, so by
        // the time onSubagentStart has run these would already have fired if they were going to.
        var doneFired = false
        var tasksFired = false
        watcher.onTaskComplete = { _, _ in doneFired = true }
        watcher.onBackgroundTasks = { _, _ in tasksFired = true }

        let path = subagentMarkerPath(id.uuidString, agent: "agent-1", suffix: "start")
        try "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"agent-1\",\"agent_type\":\"Explore\"}"
            .write(toFile: path, atomically: true, encoding: .utf8)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(got?.0, id)
        XCTAssertEqual(got?.1, "agent-1")
        XCTAssertEqual(got?.2, "Explore")
        XCTAssertNil(got?.3)
        XCTAssertFalse(doneFired, "onTaskComplete must not fire for a start marker")
        XCTAssertFalse(tasksFired, "onBackgroundTasks must not fire without the key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Marker should be removed after delivery")
    }

    func testStartMarkerPrefersRawAgentIDFromPayload() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let received = expectation(description: "onSubagentStart called")
        var agentID: String?
        watcher.onSubagentStart = { _, got, _, _ in
            agentID = got
            received.fulfill()
        }

        // notify.sh sanitises "a.b" to "ab" for the filename; the payload keeps the raw id.
        let path = subagentMarkerPath(id.uuidString, agent: "ab", suffix: "start")
        try "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"a.b\",\"agent_type\":\"Explore\"}"
            .write(toFile: path, atomically: true, encoding: .utf8)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(agentID, "a.b")
    }

    func testStartMarkerWithEmptyTypeDeliversEmptyType() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let received = expectation(description: "onSubagentStart called")
        var type: String?
        watcher.onSubagentStart = { _, _, agentType, _ in
            type = agentType
            received.fulfill()
        }

        let path = subagentMarkerPath(id.uuidString, agent: "agent-1", suffix: "start")
        try "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"agent-1\",\"agent_type\":\"\"}"
            .write(toFile: path, atomically: true, encoding: .utf8)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(type, "")
    }

    func testStartMarkerWithMalformedContentFallsBackToFilename() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let received = expectation(description: "onSubagentStart called")
        var got: (String, String)?
        watcher.onSubagentStart = { _, agentID, agentType, _ in
            got = (agentID, agentType)
            received.fulfill()
        }

        let path = subagentMarkerPath(id.uuidString, agent: "agent-1", suffix: "start")
        try "{\"hook_event_name\":\"SubagentSta".write(toFile: path, atomically: true, encoding: .utf8)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(got?.0, "agent-1")
        XCTAssertEqual(got?.1, "")
    }

    func testStopMarkerTriggersOnSubagentStop() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
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

    func testStopMarkerWithBackgroundTasksDeliversTasksBeforeStop() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let stop = expectation(description: "onSubagentStop called")
        let tasks = expectation(description: "onBackgroundTasks called")
        var order: [String] = []
        var gotTasks: [BackgroundTask]?
        watcher.onBackgroundTasks = { instance, list in
            XCTAssertEqual(instance, id)
            gotTasks = list
            order.append("tasks")
            tasks.fulfill()
        }
        watcher.onSubagentStop = { _, _ in
            order.append("stop")
            stop.fulfill()
        }

        let json = """
        {"hook_event_name":"SubagentStop","agent_id":"a6f7","agent_type":"","background_tasks":[{"id":"af75","type":"subagent","status":"running","description":"Settings height","agent_type":"general-purpose"}]}
        """
        try json.write(toFile: subagentMarkerPath(id.uuidString, agent: "a6f7", suffix: "stop"), atomically: true, encoding: .utf8)

        wait(for: [tasks, stop], timeout: 5.0)
        XCTAssertEqual(order, ["tasks", "stop"])
        XCTAssertEqual(gotTasks?.map(\.description), ["Settings height"])
    }

    func testDoneMarkerPassesBackgroundTasksToOnTaskComplete() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }
        let id = UUID()

        let received = expectation(description: "onTaskComplete called")
        var got: [BackgroundTask]??
        watcher.onTaskComplete = { _, tasks in
            got = .some(tasks)
            received.fulfill()
        }

        let json = """
        {"hook_event_name":"Stop","background_tasks":[{"id":"af75","type":"subagent","status":"running","agent_type":"Explore"}]}
        """
        try json.write(toFile: markerPath(id.uuidString), atomically: true, encoding: .utf8)

        wait(for: [received], timeout: 5.0)
        XCTAssertEqual(got??.map(\.id), ["af75"])
    }

    func testPreExistingMarkersAreSweptWithoutNotifying() throws {
        let staleID = UUID()
        FileManager.default.createFile(atPath: markerPath(staleID.uuidString), contents: nil)

        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }

        let notCalled = expectation(description: "stale marker must not be delivered")
        notCalled.isInverted = true
        watcher.onTaskComplete = { _, _ in notCalled.fulfill() }

        wait(for: [notCalled], timeout: 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath(staleID.uuidString)),
                       "Stale marker should still be cleaned up")
    }

    func testNonUUIDMarkersAreIgnoredButCleanedUp() throws {
        let watcher = HookWatcher(hooksDirectory: tempDir)
        defer { withExtendedLifetime(watcher) {} }

        let notCalled = expectation(description: "non-UUID marker must not be delivered")
        notCalled.isInverted = true
        watcher.onTaskComplete = { _, _ in notCalled.fulfill() }

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
        watcher.onTaskComplete = { uuid, _ in
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
        watcher.onTaskComplete = { _, _ in quiet.fulfill() }
        wait(for: [quiet], timeout: 0.5)
    }
}
