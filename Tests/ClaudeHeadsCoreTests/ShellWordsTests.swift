import Foundation
import XCTest

@testable import ClaudeHeadsCore

final class ShellWordsTests: XCTestCase {

    func testSplitsOnWhitespaceAndCollapsesRuns() {
        XCTAssertEqual(ShellWords.split("  --model   opus\n--verbose\t"), ["--model", "opus", "--verbose"])
        XCTAssertEqual(ShellWords.split(""), [])
        XCTAssertEqual(ShellWords.split("   "), [])
    }

    func testDoubleQuotesKeepSpacesInOneArgument() {
        XCTAssertEqual(
            ShellWords.split("--append-system-prompt \"be terse and kind\" --model opus"),
            ["--append-system-prompt", "be terse and kind", "--model", "opus"]
        )
    }

    func testSingleQuotesAreLiteral() {
        XCTAssertEqual(ShellWords.split("--flag 'a \"quoted\" $thing'"), ["--flag", "a \"quoted\" $thing"])
    }

    func testQuotesAdjacentToWordsConcatenate() {
        XCTAssertEqual(ShellWords.split("--name=\"my project\""), ["--name=my project"])
        XCTAssertEqual(ShellWords.split("a'b c'd"), ["ab cd"])
    }

    func testEmptyQuotedStringIsAnArgument() {
        XCTAssertEqual(ShellWords.split("-p \"\" next"), ["-p", "", "next"])
    }

    func testBackslashEscapes() {
        XCTAssertEqual(ShellWords.split("hello\\ world"), ["hello world"])
        XCTAssertEqual(ShellWords.split("\"say \\\"hi\\\"\""), ["say \"hi\""])
        XCTAssertEqual(ShellWords.split("\"path\\\\to\""), ["path\\to"])
        XCTAssertEqual(ShellWords.split("\"keep \\n literal\""), ["keep \\n literal"])
    }

    func testUnterminatedQuoteRunsToEnd() {
        XCTAssertEqual(ShellWords.split("--prompt \"never closed"), ["--prompt", "never closed"])
    }

    func testCLIArgumentsCombinesFlagsAndSplitExtras() {
        let args = AppSettings.cliArguments(
            continue: true,
            skipPermissions: false,
            remoteControl: true,
            extraArgs: "--append-system-prompt \"two words\""
        )
        XCTAssertEqual(args, ["--continue", "--remote-control", "--append-system-prompt", "two words"])
    }

    func testCLIArgumentsWithNothingEnabledIsEmpty() {
        XCTAssertEqual(
            AppSettings.cliArguments(continue: false, skipPermissions: false, remoteControl: false, extraArgs: " \n "),
            []
        )
    }
}
