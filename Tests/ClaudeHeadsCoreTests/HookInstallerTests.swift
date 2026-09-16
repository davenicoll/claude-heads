import Foundation
import XCTest

@testable import ClaudeHeadsCore

// MARK: - HookSettingsMerge (pure text) tests

final class HookSettingsMergeTests: XCTestCase {

    private let script = "/Users/someone/.claude-heads/hooks/notify.sh"

    // MARK: Fixtures

    /// (a) no "hooks" key, non-empty object
    private let noHooks = """
    {
      "model": "opus",
      "permissions": {
        "allow": ["Bash(ls:*)", "Read"],
        "deny": []
      },
      "env": { "FOO": "a{b}c\\"[]" }
    }
    """

    /// (b) existing hooks with only SessionEnd
    private let sessionEndOnly = """
    {
      "permissions": { "allow": [] },
      "hooks": {
        "SessionEnd": [
          {
            "hooks": [
              { "type": "command", "command": "/usr/local/bin/bye.sh" }
            ]
          }
        ]
      },
      "model": "sonnet"
    }
    """

    /// (c) all three already present pointing at notify.sh (via ~ path, as in the old README)
    private let allPresent = """
    {
      "hooks": {
        "Stop": [
          { "hooks": [ { "type": "command", "command": "~/.claude-heads/hooks/notify.sh" } ] }
        ],
        "SubagentStart": [
          { "hooks": [ { "type": "command", "command": "~/.claude-heads/hooks/notify.sh" } ] }
        ],
        "SubagentStop": [
          { "hooks": [ { "type": "command", "command": "~/.claude-heads/hooks/notify.sh" } ] }
        ]
      }
    }
    """

    /// (d) one of three present
    private let onePresent = """
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              { "type": "command", "command": "/Users/x/.claude-heads/hooks/notify.sh", "timeout": 5 }
            ]
          }
        ]
      }
    }
    """

    /// (e) empty object
    private let empty = "{}"

    /// (f) 4-space indentation
    private let fourSpaces = """
    {
        "model": "opus",
        "hooks": {
            "Notification": [
                {
                    "hooks": [
                        { "type": "command", "command": "say hi" }
                    ]
                }
            ]
        }
    }
    """

    /// (g) invalid JSON (trailing comma, a comment)
    private let invalid = """
    {
      // not allowed in strict JSON
      "model": "opus",
    }
    """

    // MARK: Helpers

    private func parse(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func installed(_ text: String) throws -> String {
        switch HookSettingsMerge.install(into: text, scriptPath: script) {
        case .success(let out): return out
        case .failure(let failure): throw failure
        }
    }

    private func uninstalled(_ text: String) throws -> String {
        switch HookSettingsMerge.uninstall(from: text) {
        case .success(let out): return out
        case .failure(let failure): throw failure
        }
    }

    /// Our entries in `text`, as parsed dictionaries keyed by event.
    private func ourGroups(in text: String) throws -> [String: [[String: Any]]] {
        let root = try parse(text)
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var result: [String: [[String: Any]]] = [:]
        for event in HookSettingsMerge.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            result[event] = groups.filter { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    HookSettingsMerge.isOurs(command: $0["command"])
                }
            }
        }
        return result
    }

    /// Asserts the install result parses, has exactly one entry of ours per event with the
    /// absolute path and timeout, that every other setting is unchanged and (when
    /// `singleInsertion`) that the edit was one contiguous insertion, i.e. the original text
    /// with the inserted block cut out is byte-identical to the input.
    private func assertInstalled(_ output: String, from original: String, singleInsertion: Bool = true,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try parse(output)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any], file: file, line: line)
        for event in HookSettingsMerge.events {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], "\(event) missing", file: file, line: line)
            let ours = groups.filter { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { HookSettingsMerge.isOurs(command: $0["command"]) }
            }
            XCTAssertEqual(ours.count, 1, "\(event) should have exactly one entry of ours", file: file, line: line)
        }
        let originalRoot = try parse(original)
        XCTAssertTrue(
            NSDictionary(dictionary: HookSettingsMerge.strippedOfOurHooks(originalRoot))
                .isEqual(to: HookSettingsMerge.strippedOfOurHooks(root)),
            "other settings changed", file: file, line: line)
        if singleInsertion {
            XCTAssertTrue(isSingleInsertion(original: original, result: output),
                          "expected one contiguous insertion", file: file, line: line)
        }
        XCTAssertGreaterThan(output.utf8.count, original.utf8.count, file: file, line: line)
        XCTAssertTrue(output.contains("\"command\": \"\(script)\""), file: file, line: line)
        XCTAssertTrue(output.contains("\"timeout\": 5"), file: file, line: line)
    }

    /// True when `result` is `original` with one contiguous block inserted: the bytes the two
    /// share as a common prefix plus common suffix cover the whole original.
    private func isSingleInsertion(original: String, result: String) -> Bool {
        let a = Array(original.utf8), b = Array(result.utf8)
        guard b.count > a.count else { return false }
        var prefix = 0
        while prefix < a.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return prefix + suffix >= a.count
    }

    // MARK: Install fixtures

    func testInstallIntoFileWithoutHooksKey() throws {
        let out = try installed(noHooks)
        try assertInstalled(out, from: noHooks)
        XCTAssertTrue(out.hasPrefix("{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\","))
        XCTAssertTrue(out.contains("\n  },\n  \"model\": \"opus\","), "block ends with a comma before the first original key")
        XCTAssertTrue(out.contains("\"env\": { \"FOO\": \"a{b}c\\\"[]\" }"), "braces and escaped quotes inside strings untouched")
    }

    func testInstallAlongsideSessionEnd() throws {
        let out = try installed(sessionEndOnly)
        try assertInstalled(out, from: sessionEndOnly)
        XCTAssertTrue(out.contains("\"hooks\": {\n    \"Stop\": ["), "inserted right after the hooks brace")
        XCTAssertTrue(out.contains("    ],\n    \"SessionEnd\": ["), "trailing comma joins the existing member")
        XCTAssertTrue(out.contains("/usr/local/bin/bye.sh"))
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionEnd", "Stop", "SubagentStart", "SubagentStop"])
    }

    func testInstallIsNoOpWhenAllPresent() throws {
        XCTAssertEqual(try installed(allPresent), allPresent)
        XCTAssertEqual(HookSettingsMerge.missingEvents(in: allPresent), .success([]))
    }

    func testInstallAddsOnlyMissingEvents() throws {
        let out = try installed(onePresent)
        try assertInstalled(out, from: onePresent)
        XCTAssertFalse(out.contains("\"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"\(script)\""),
                       "the existing Stop entry must not be duplicated")
        XCTAssertEqual(HookSettingsMerge.missingEvents(in: onePresent), .success(["SubagentStart", "SubagentStop"]))
        XCTAssertTrue(out.contains("\"hooks\": {\n    \"SubagentStart\": [\n"))
        XCTAssertTrue(out.contains("\n    ],\n    \"Stop\": ["))
    }

    func testInstallIntoEmptyObject() throws {
        let out = try installed(empty)
        try assertInstalled(out, from: empty)
        XCTAssertTrue(out.hasPrefix("{\n  \"hooks\": {\n"))
        XCTAssertTrue(out.hasSuffix("\n  }\n}"), "no trailing comma and the closing brace on its own line")
    }

    func testInstallDetectsFourSpaceIndent() throws {
        let out = try installed(fourSpaces)
        try assertInstalled(out, from: fourSpaces)
        XCTAssertTrue(out.contains("    \"hooks\": {\n        \"Stop\": [\n            {\n                \"hooks\": [\n                    {\n                        \"type\": \"command\","))
        XCTAssertTrue(out.contains("        ],\n        \"Notification\": ["))
        XCTAssertFalse(out.contains("\n  \"Stop\""), "no two-space lines introduced")
    }

    func testInstallRefusesInvalidJSON() throws {
        switch HookSettingsMerge.install(into: invalid, scriptPath: script) {
        case .success: XCTFail("invalid JSON must not be merged")
        case .failure(let failure):
            guard case .invalidJSON = failure else { return XCTFail("unexpected failure \(failure)") }
        }
        switch HookSettingsMerge.uninstall(from: invalid) {
        case .success: XCTFail("invalid JSON must not be edited")
        case .failure: break
        }
    }

    func testInstallRefusesHooksThatIsNotAnObject() {
        XCTAssertEqual(HookSettingsMerge.install(into: "{ \"hooks\": [] }", scriptPath: script), .failure(.hooksNotAnObject))
        XCTAssertEqual(HookSettingsMerge.install(into: "{ \"hooks\": { \"Stop\": {} } }", scriptPath: script),
                       .failure(.eventNotAnArray("Stop")))
        XCTAssertEqual(HookSettingsMerge.install(into: "[1, 2]", scriptPath: script), .failure(.notAnObject))
    }

    func testInstallIntoExistingEmptyEventArray() throws {
        let text = "{\n  \"hooks\": {\n    \"Stop\": [],\n    \"SubagentStop\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"echo\" } ] }\n    ]\n  }\n}"
        let out = try installed(text)
        try assertInstalled(out, from: text, singleInsertion: false)
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 1, "reuses the empty Stop array")
        XCTAssertEqual((hooks["SubagentStop"] as? [Any])?.count, 2, "prepends to the existing array")
        XCTAssertTrue(out.contains("\"SubagentStop\": [\n      {\n        \"hooks\": [\n"), "new group indented for the array's depth")
        XCTAssertTrue(out.contains("      },\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"echo\" } ] }"))
    }

    func testInstallPreservesCRLFAndTabs() throws {
        let text = "{\r\n\t\"model\": \"opus\"\r\n}"
        let out = try installed(text)
        try assertInstalled(out, from: text)
        XCTAssertTrue(out.hasPrefix("{\r\n\t\"hooks\": {\r\n\t\t\"Stop\": [\r\n\t\t\t{\r\n"))
        XCTAssertFalse(out.contains("  "), "tabs, not spaces")
        XCTAssertFalse(out.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every newline is CRLF")
    }

    func testInstallPreservesBOM() throws {
        let text = "\u{FEFF}{\n  \"model\": \"opus\"\n}"
        let out = try installed(text)
        XCTAssertTrue(out.hasPrefix("\u{FEFF}{\n  \"hooks\": {"))
        XCTAssertEqual(try uninstalled(out), text)
    }

    func testInstallEscapesScriptPath() throws {
        let odd = "/Users/o\"dd\\name/.claude-heads/hooks/notify.sh"
        switch HookSettingsMerge.install(into: empty, scriptPath: odd) {
        case .failure(let failure): XCTFail("\(failure)")
        case .success(let out):
            let groups = try ourGroups(in: out)
            let command = (groups["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
            XCTAssertEqual(command, odd)
        }
    }

    // MARK: Uninstall fixtures

    func testUninstallOurEntryAlongsideAnotherHookInSameEvent() throws {
        let text = """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/bin/other.sh" } ] },
              { "hooks": [ { "type": "command", "command": "/Users/x/.claude-heads/hooks/notify.sh" } ] }
            ]
          }
        }
        """
        let expected = """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/bin/other.sh" } ] }
            ]
          }
        }
        """
        XCTAssertEqual(try uninstalled(text), expected)
    }

    func testUninstallOurCommandFromSharedGroup() throws {
        let text = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  { "type": "command", "command": "/Users/x/.claude-heads/hooks/notify.sh" },
                  { "type": "command", "command": "/usr/bin/other.sh" }
                ]
              }
            ]
          }
        }
        """
        let expected = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  { "type": "command", "command": "/usr/bin/other.sh" }
                ]
              }
            ]
          }
        }
        """
        XCTAssertEqual(try uninstalled(text), expected)
    }

    func testUninstallOurEntryAloneRemovesHooksKey() throws {
        let text = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "~/.claude-heads/hooks/notify.sh" } ] }
            ]
          }
        }
        """
        XCTAssertEqual(try uninstalled(text), "{\n  \"model\": \"opus\"\n}")
    }

    func testUninstallOurEntryInObjectWithOtherEvents() throws {
        let text = """
        {
          "hooks": {
            "SessionEnd": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/bye.sh" } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/Users/x/.claude-heads/hooks/notify.sh" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "lint" } ] }
            ]
          }
        }
        """
        let expected = """
        {
          "hooks": {
            "SessionEnd": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/bye.sh" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "lint" } ] }
            ]
          }
        }
        """
        XCTAssertEqual(try uninstalled(text), expected)
    }

    func testUninstallIsNoOpWithoutOurEntries() throws {
        XCTAssertEqual(try uninstalled(noHooks), noHooks)
        XCTAssertEqual(try uninstalled(sessionEndOnly), sessionEndOnly)
        XCTAssertEqual(try uninstalled(empty), empty)
    }

    func testUninstallLeavesPreexistingEmptyContainersAlone() throws {
        let text = "{\n  \"hooks\": {\n    \"Stop\": [],\n    \"SubagentStop\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"~/.claude-heads/hooks/notify.sh\" } ] }\n    ]\n  }\n}"
        XCTAssertEqual(try uninstalled(text), "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}")
    }

    func testInstallThenUninstallRoundTripsByteForByte() throws {
        for fixture in [noHooks, sessionEndOnly, empty, fourSpaces,
                        "{\r\n\t\"model\": \"opus\"\r\n}",
                        "{\"a\":1,\"b\":{\"c\":[1,2]}}"] {
            let installedText = try installed(fixture)
            XCTAssertNotEqual(installedText, fixture)
            XCTAssertEqual(try uninstalled(installedText), fixture, "round trip changed: \(fixture)")
        }
        // (c) and (d) already contain entries of ours, so removal strips those too and
        // leaves a bare object; the install of (d) then round-trips to that.
        XCTAssertEqual(try uninstalled(allPresent), "{}")
        XCTAssertEqual(try uninstalled(try installed(onePresent)), "{}")
    }

    func testUninstallMiddleItemKeepsNeighboursAndCommas() throws {
        let text = """
        {
          "hooks": {
            "SessionEnd": [ { "hooks": [ { "type": "command", "command": "a" } ] } ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "first" } ] },
              { "hooks": [ { "type": "command", "command": "/x/.claude-heads/hooks/notify.sh" } ] },
              { "hooks": [ { "type": "command", "command": "last" } ] }
            ],
            "Notification": [ { "hooks": [ { "type": "command", "command": "b" } ] } ]
          }
        }
        """
        let expected = """
        {
          "hooks": {
            "SessionEnd": [ { "hooks": [ { "type": "command", "command": "a" } ] } ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "first" } ] },
              { "hooks": [ { "type": "command", "command": "last" } ] }
            ],
            "Notification": [ { "hooks": [ { "type": "command", "command": "b" } ] } ]
          }
        }
        """
        XCTAssertEqual(try uninstalled(text), expected)

        // Our event key in the middle of the hooks object.
        let middleEvent = "{\n  \"hooks\": {\n    \"A\": [],\n    \"Stop\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"~/.claude-heads/hooks/notify.sh\" } ] } ],\n    \"B\": []\n  }\n}"
        XCTAssertEqual(try uninstalled(middleEvent), "{\n  \"hooks\": {\n    \"A\": [],\n    \"B\": []\n  }\n}")
    }

    func testDuplicateKeysAreRefused() {
        XCTAssertEqual(HookSettingsMerge.install(into: "{\"a\": 1, \"a\": 2}", scriptPath: script), .failure(.duplicateKey("a")))
        XCTAssertEqual(HookSettingsMerge.install(into: "{\"hooks\": {}, \"hooks\": {}}", scriptPath: script), .failure(.duplicateKey("hooks")))
        XCTAssertEqual(HookSettingsMerge.install(into: "{\"hooks\": {\"Stop\": [], \"Stop\": []}}", scriptPath: script), .failure(.duplicateKey("Stop")))
        XCTAssertEqual(HookSettingsMerge.uninstall(from: "{\"hooks\": {\"Stop\": [], \"Stop\": []}}"), .failure(.duplicateKey("Stop")))
        XCTAssertEqual(HookSettingsMerge.missingEvents(in: "{\"a\": 1, \"a\": 2}"), .failure(.duplicateKey("a")))
    }

    func testIsOursMatchesWrappedAndFlaggedCommands() {
        XCTAssertTrue(HookSettingsMerge.isOurs(command: "/x/.claude-heads/hooks/notify.sh"))
        XCTAssertTrue(HookSettingsMerge.isOurs(command: "bash /x/.claude-heads/hooks/notify.sh"))
        XCTAssertTrue(HookSettingsMerge.isOurs(command: "/x/.claude-heads/hooks/notify.sh --flag"))
        XCTAssertTrue(HookSettingsMerge.isOurs(command: "\"/Users/o d/.claude-heads/hooks/notify.sh\""))
        XCTAssertFalse(HookSettingsMerge.isOurs(command: "/x/.claude-heads/hooks/notify.sh.bak"))
        XCTAssertFalse(HookSettingsMerge.isOurs(command: "echo notify.sh"))
        XCTAssertFalse(HookSettingsMerge.isOurs(command: 5))
        XCTAssertFalse(HookSettingsMerge.isOurs(command: nil))
        // Fixture: a wrapped invocation counts as installed and is removed.
        let wrapped = "{\n  \"hooks\": {\n    \"Stop\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"bash /x/.claude-heads/hooks/notify.sh\" } ] } ]\n  }\n}"
        XCTAssertEqual(HookSettingsMerge.missingEvents(in: wrapped), .success(["SubagentStart", "SubagentStop"]))
        XCTAssertEqual(HookSettingsMerge.uninstall(from: wrapped), .success("{}"))
    }

    func testWhitespaceOnlyContainersCollapseOnRoundTrip() throws {
        // "{ }" and {"hooks": {}} carry no configuration; the empty container's inner
        // whitespace is replaced on install and it collapses to "{}" on uninstall.
        XCTAssertEqual(try uninstalled(try installed("{ }")), "{}")
        XCTAssertEqual(try uninstalled(try installed("{\n}")), "{}")
        XCTAssertEqual(try uninstalled(try installed("{\"hooks\": {}}")), "{}")
        XCTAssertEqual(try uninstalled(try installed("{\n  \"a\": 1,\n  \"hooks\": {}\n}")), "{\n  \"a\": 1\n}")
        XCTAssertEqual(try uninstalled(try installed("{\n  \"hooks\": {},\n  \"a\": 1\n}")), "{\n  \"a\": 1\n}")
    }

    func testMixedLineEndingsRoundTrip() throws {
        let mixed = "{\r\n  \"a\": 1,\n  \"b\": {\n    \"c\": 2\r\n  }\n}"
        let out = try installed(mixed)
        try assertInstalled(out, from: mixed)
        XCTAssertTrue(out.hasPrefix("{\r\n  \"hooks\": {\r\n"), "CRLF wins when the file mixes endings")
        XCTAssertEqual(try uninstalled(out), mixed)
    }

    func testRoundTripDropsPreexistingEmptyEventArrayWeReused() throws {
        // Installing into an existing empty "Stop": [] reuses it; removing our only group
        // then empties it, and an event array we emptied is removed with its key. The empty
        // array carried no configuration, so the file is equivalent but not byte-identical.
        let text = "{\n  \"hooks\": {\n    \"Stop\": [],\n    \"SubagentStop\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"echo\" } ] }\n    ]\n  }\n}"
        XCTAssertEqual(try uninstalled(try installed(text)),
                       "{\n  \"hooks\": {\n    \"SubagentStop\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"echo\" } ] }\n    ]\n  }\n}")
    }
}

// MARK: - HookInstaller (file) tests

final class HookInstallerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-heads-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let script = "/Users/someone/.claude-heads/hooks/notify.sh"

    private func makeInstaller(file: URL) -> HookInstaller {
        HookInstaller(settingsFileURL: file, backupDirectory: tempDir.appendingPathComponent("backups"), scriptPath: script)
    }

    func testCreatesFileWhenMissingWithoutBackup() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let installer = makeInstaller(file: file)
        XCTAssertEqual(installer.status, .missing(HookSettingsMerge.events))

        XCTAssertTrue(installer.install())
        XCTAssertEqual(installer.status, .installed)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{\n  \"hooks\": {\n"))
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.backupFileURL.path),
                       "no backup for a file we created")

        XCTAssertTrue(installer.uninstall())
        XCTAssertEqual(installer.status, .missing(HookSettingsMerge.events))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{}\n")
    }

    func testEmptyOrWhitespaceFileIsTreatedAsEmptyObject() throws {
        for blank in ["", "  \n\n"] {
            let file = tempDir.appendingPathComponent("settings-\(blank.count).json")
            try blank.write(to: file, atomically: true, encoding: .utf8)
            let installer = makeInstaller(file: file)
            XCTAssertEqual(installer.status, .missing(HookSettingsMerge.events))
            XCTAssertTrue(installer.install())
            XCTAssertEqual(installer.status, .installed)
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("{\n  \"hooks\": {"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: installer.backupFileURL.path), "blank file needs no backup")
        }
    }

    func testDanglingSymlinkIsRefused() throws {
        let link = tempDir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tempDir.appendingPathComponent("nowhere/settings.json"))
        let installer = makeInstaller(file: link)
        XCTAssertFalse(installer.install())
        guard case .failed(let reason) = installer.status else { return XCTFail("expected failed, got \(installer.status)") }
        XCTAssertTrue(reason.contains("symlink"), reason)
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "the link must not be replaced by a file")
    }

    func testBackupIsWrittenOnceAndFollowsSymlinks() throws {
        // ~/.claude is a symlink into a dotfiles repo for many users: the real file must be
        // rewritten in place and the link left intact.
        let realDir = tempDir.appendingPathComponent("dotfiles/claude")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("settings.json")
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try original.write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realFile.path)
        let linkDir = tempDir.appendingPathComponent(".claude")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let linkFile = linkDir.appendingPathComponent("settings.json")

        let installer = makeInstaller(file: linkFile)
        XCTAssertTrue(installer.install())
        XCTAssertEqual(installer.status, .installed)

        let linkAttrs = try FileManager.default.attributesOfItem(atPath: linkDir.path)
        XCTAssertEqual(linkAttrs[.type] as? FileAttributeType, .typeSymbolicLink, "symlink replaced by a directory")
        let realAttrs = try FileManager.default.attributesOfItem(atPath: realFile.path)
        XCTAssertEqual(realAttrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((realAttrs[.posixPermissions] as? Int), 0o600, "permissions preserved across the atomic rename")

        let backup = installer.backupFileURL
        XCTAssertEqual(backup.lastPathComponent, "settings.json.claude-heads.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: realDir.path).contains { $0.contains(".bak") },
                       "backup lives outside the settings directory")

        // A second modification must not overwrite the backup.
        XCTAssertTrue(installer.uninstall())
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), original)
        XCTAssertTrue(installer.install())
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realDir.path).filter { $0.contains(".tmp") }, [],
                       "no temp files left behind")
    }

    func testInvalidFileIsReportedAndLeftUntouched() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let broken = "{ \"model\": \"opus\", }"
        try broken.write(to: file, atomically: true, encoding: .utf8)
        let installer = makeInstaller(file: file)
        guard case .failed(let reason) = installer.status else { return XCTFail("expected failed, got \(installer.status)") }
        XCTAssertTrue(reason.contains("not valid JSON"), reason)

        XCTAssertFalse(installer.install())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.backupFileURL.path))
        XCTAssertFalse(installer.reinstall())
        XCTAssertFalse(installer.uninstall())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    func testReinstallReplacesStalePath() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let stale = """
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/old/home/.claude-heads/hooks/notify.sh" } ] }
            ]
          }
        }
        """
        try stale.write(to: file, atomically: true, encoding: .utf8)
        let installer = makeInstaller(file: file)
        XCTAssertEqual(installer.status, .missing(["SubagentStart", "SubagentStop"]))

        XCTAssertTrue(installer.reinstall())
        XCTAssertEqual(installer.status, .installed)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("/old/home/"))
        XCTAssertEqual(text.components(separatedBy: script).count - 1, 3)

        XCTAssertTrue(installer.uninstall())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{}")
    }
}
