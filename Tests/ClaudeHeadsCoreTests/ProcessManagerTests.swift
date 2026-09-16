import Foundation
import XCTest

@testable import ClaudeHeadsCore

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
}
