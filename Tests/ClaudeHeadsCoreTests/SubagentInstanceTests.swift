import Foundation
import XCTest

@testable import ClaudeHeadsCore

// MARK: - SubagentInstance label / tooltip / colour

final class SubagentInstanceLabelTests: XCTestCase {

    func testLabelPrefersDescriptionOverType() {
        let child = SubagentInstance(id: "af7589e59f71169d7", type: "general-purpose", description: "Settings height")
        XCTAssertEqual(child.label, "Settings height")
    }

    func testLabelFallsBackToTypeWhenDescriptionIsMissingOrBlank() {
        XCTAssertEqual(SubagentInstance(id: "af7589e59f71169d7", type: "Explore").label, "Explore")
        XCTAssertEqual(SubagentInstance(id: "af7589e59f71169d7", type: "Explore", description: "   \n").label, "Explore")
        XCTAssertEqual(SubagentInstance(id: "af7589e59f71169d7", type: " payload-probe ").label, "payload-probe")
    }

    func testLabelFallsBackToIDPrefixWhenTypeIsEmpty() {
        XCTAssertEqual(SubagentInstance(id: "af7589e59f71169d7", type: "").label, "af7589e5")
        XCTAssertEqual(SubagentInstance(id: "abc", type: "  ").label, "abc", "short ids are not padded")
    }

    func testLabelTrimsDescription() {
        let child = SubagentInstance(id: "a1", type: "x", description: "  Run tests\n")
        XCTAssertEqual(child.label, "Run tests")
    }

    func testLabelTruncatesLongDescriptionWithEllipsis() {
        let long = "Settings height and hook gating for the orbit ring"
        let child = SubagentInstance(id: "a1", type: "general-purpose", description: long)
        XCTAssertEqual(child.label.count, SubagentInstance.labelLimit)
        XCTAssertTrue(child.label.hasSuffix("\u{2026}"))
        XCTAssertEqual(child.label, "Settings height and hoo\u{2026}")
    }

    func testLabelAtExactLimitIsNotTruncated() {
        let exact = String(repeating: "a", count: SubagentInstance.labelLimit)
        XCTAssertEqual(SubagentInstance(id: "a1", type: "", description: exact).label, exact)
    }

    func testTruncationCountsGraphemeClustersNotBytes() {
        // Each flag is two scalars (8 UTF-8 bytes) but one Character; 30 of them must cut to 23 + ellipsis.
        let flags = String(repeating: "\u{1F1EC}\u{1F1E7}", count: 30)
        let truncated = SubagentInstance.truncate(flags, to: 24)
        XCTAssertEqual(truncated.count, 24)
        XCTAssertEqual(truncated, String(repeating: "\u{1F1EC}\u{1F1E7}", count: 23) + "\u{2026}")

        // Family emoji with ZWJs is a single grapheme cluster and is never split.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(SubagentInstance.truncate(family + "abc", to: 2), family + "\u{2026}")
    }

    func testTruncationDropsTrailingSpaceBeforeEllipsis() {
        XCTAssertEqual(SubagentInstance.truncate("abcd efgh", to: 6), "abcd\u{2026}")
        XCTAssertEqual(SubagentInstance.truncate("abc", to: 0), "")
    }

    func testTooltipAddsDescriptionAndTypeOnlyWhenTheyDiffer() {
        let long = "Settings height and hook gating for the orbit ring"
        let full = SubagentInstance(id: "a1", type: "general-purpose", description: long)
        XCTAssertEqual(full.tooltip, "Settings height and hoo\u{2026}\n\(long)\nType: general-purpose")

        let short = SubagentInstance(id: "a1", type: "Explore", description: "Find tests")
        XCTAssertEqual(short.tooltip, "Find tests\nType: Explore", "untruncated description equals the label")

        let typeOnly = SubagentInstance(id: "a1", type: "Explore")
        XCTAssertEqual(typeOnly.tooltip, "Explore")

        let idOnly = SubagentInstance(id: "af7589e59f71169d7", type: "")
        XCTAssertEqual(idOnly.tooltip, "af7589e5")
    }

    func testColorKeyDerivesFromTypeAndFallsBackToLabel() {
        let a = SubagentInstance(id: "a1", type: "Explore", description: "Find tests")
        let b = SubagentInstance(id: "b2", type: "explore", description: "Something else")
        XCTAssertEqual(a.colorKey, b.colorKey, "same kind, same colour regardless of description or case")

        let noType = SubagentInstance(id: "c3", type: "", description: "Find tests")
        XCTAssertEqual(noType.colorKey, "subagent:find tests")
        XCTAssertEqual(SubagentInstance(id: "af7589e59f71169d7", type: "").colorKey, "subagent:af7589e5")
    }
}

// MARK: - background_tasks merge / Stop reconcile

final class SubagentInstanceMergeTests: XCTestCase {

    private func task(
        _ id: String,
        type: String = "subagent",
        status: String = "running",
        description: String? = nil,
        agentType: String? = "general-purpose"
    ) -> BackgroundTask {
        BackgroundTask(id: id, type: type, description: description, status: status, agentType: agentType)
    }

    func testMergeRelabelsExistingChildrenByID() {
        let children = [SubagentInstance(id: "a1", type: ""), SubagentInstance(id: "b2", type: "Explore")]
        let merged = SubagentInstance.merging(children, with: [
            task("a1", description: "Settings height", agentType: "general-purpose"),
            task("b2", description: "  Find tests  ", agentType: ""),
        ])
        XCTAssertEqual(merged.map(\.id), ["a1", "b2"], "order is preserved")
        XCTAssertEqual(merged[0].type, "general-purpose")
        XCTAssertEqual(merged[0].description, "Settings height")
        XCTAssertEqual(merged[1].type, "Explore", "an empty agent_type never erases a known type")
        XCTAssertEqual(merged[1].description, "Find tests")
        XCTAssertEqual(merged[0].startedAt, children[0].startedAt)
    }

    func testMergeAddsUnknownRunningSubagentsAtTheEnd() {
        let children = [SubagentInstance(id: "a1", type: "Explore")]
        let merged = SubagentInstance.merging(children, with: [
            task("new1", description: "Started before launch", agentType: "Plan"),
            task("a1"),
        ])
        XCTAssertEqual(merged.map(\.id), ["a1", "new1"], "existing children keep their orbit slot")
        XCTAssertEqual(merged[1].type, "Plan")
        XCTAssertEqual(merged[1].description, "Started before launch")
    }

    func testMergeIgnoresTeammatesFinishedTasksAndBlankIDs() {
        let children = [SubagentInstance(id: "a1", type: "Explore")]
        let merged = SubagentInstance.merging(children, with: [
            task("tksfpzdbj", type: "teammate", description: "Run sleep", agentType: nil),
            task("done1", status: "completed"),
            task("", description: "no id"),
        ])
        XCTAssertEqual(merged, children, "no positive evidence of a new subagent")
    }

    func testMergeNeverRemovesChildren() {
        let children = [SubagentInstance(id: "a1", type: "Explore"), SubagentInstance(id: "b2", type: "Plan")]
        XCTAssertEqual(SubagentInstance.merging(children, with: []), children)
        XCTAssertEqual(SubagentInstance.merging(children, with: [task("other")]).map(\.id), ["a1", "b2", "other"])
    }

    func testMergeHandlesDuplicateAndCollidingIDs() {
        let merged = SubagentInstance.merging([], with: [
            task("x", description: "first"),
            task("x", description: "second"),
            task("x", type: "teammate", description: "teammate with same id", agentType: nil),
        ])
        XCTAssertEqual(merged.count, 1, "one child per id")
        XCTAssertEqual(merged[0].description, "first")
    }

    func testMergeReturnsSameArrayWhenNothingChanges() {
        let children = [SubagentInstance(id: "a1", type: "Explore", description: "Find tests")]
        let merged = SubagentInstance.merging(children, with: [task("a1", description: "Find tests", agentType: "Explore")])
        XCTAssertEqual(merged, children)
    }

    func testStopReconcileKeepsListedRunningChildrenAndDropsTheRest() {
        let children = [
            SubagentInstance(id: "a1", type: "Explore"),
            SubagentInstance(id: "b2", type: ""),
            SubagentInstance(id: "c3", type: "Plan"),
        ]
        let reconciled = SubagentInstance.reconciling(children, withStopTasks: [
            task("b2", description: "Settings height", agentType: "general-purpose"),
            task("c3", status: "completed"),
            task("d4", description: "New one"),
            task("tm", type: "teammate", agentType: nil),
        ])
        XCTAssertEqual(reconciled.map(\.id), ["b2", "d4"], "unlisted a1 and finished c3 go; running d4 is added")
        XCTAssertEqual(reconciled[0].type, "general-purpose")
        XCTAssertEqual(reconciled[0].description, "Settings height")
    }

    func testStopReconcileWithoutListKeepsEveryChild() {
        let children = [SubagentInstance(id: "a1", type: "Explore"), SubagentInstance(id: "b2", type: "")]
        XCTAssertEqual(SubagentInstance.reconciling(children, withStopTasks: nil), children)
    }

    func testStopReconcileWithEmptyListClearsChildren() {
        let children = [SubagentInstance(id: "a1", type: "Explore")]
        XCTAssertEqual(SubagentInstance.reconciling(children, withStopTasks: []), [])
    }
}
