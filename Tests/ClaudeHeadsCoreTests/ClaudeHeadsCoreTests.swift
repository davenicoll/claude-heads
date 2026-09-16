import Foundation
import XCTest

@testable import ClaudeHeadsCore

// MARK: - PathColorGenerator Tests

final class PathColorGeneratorTests: XCTestCase {

    func testSamePathAlwaysGivesSameColor() {
        // Call color(for:) multiple times with the same path -- should be deterministic
        let path = "/Users/test/projects/my-app"
        let color1 = PathColorGenerator.color(for: path)
        let color2 = PathColorGenerator.color(for: path)

        // SwiftUI Color doesn't conform to Equatable in a useful way for direct comparison,
        // so we verify determinism by checking the description strings match
        XCTAssertEqual(
            String(describing: color1),
            String(describing: color2),
            "Same path should produce the same color"
        )
    }

    func testDifferentPathsGiveDifferentColors() {
        let color1 = PathColorGenerator.color(for: "/Users/test/project-a")
        let color2 = PathColorGenerator.color(for: "/Users/test/project-b")

        XCTAssertNotEqual(
            String(describing: color1),
            String(describing: color2),
            "Different paths should produce different colors"
        )
    }

    func testGradientReturnsDeterministicResult() {
        let path = "/Users/test/some-project"
        let gradient1 = PathColorGenerator.gradient(for: path)
        let gradient2 = PathColorGenerator.gradient(for: path)

        XCTAssertEqual(
            String(describing: gradient1),
            String(describing: gradient2),
            "Same path should produce the same gradient"
        )
    }

    func testEmptyPathDoesNotCrash() {
        // Should handle empty string without crashing
        _ = PathColorGenerator.color(for: "")
        _ = PathColorGenerator.gradient(for: "")
    }

    func testVeryLongPathDoesNotCrash() {
        let longPath = String(repeating: "/very-long-segment", count: 500)
        _ = PathColorGenerator.color(for: longPath)
        _ = PathColorGenerator.gradient(for: longPath)
    }
}

// MARK: - SnapEngine Tests

final class SnapEngineTests: XCTestCase {

    let engine = SnapEngine()

    func testSnapPositionWithNoOtherHeads() {
        let headID = UUID()
        let proposed = CGPoint(x: 100, y: 200)
        let head = HeadInstance(id: headID, name: "test", folderPath: "/tmp", position: proposed)

        let result = engine.snapPosition(
            for: headID,
            proposedPosition: proposed,
            allHeads: [head],
            headSize: 60,
            snapDistance: 60
        )

        // No other heads to snap to, so position should be unchanged
        XCTAssertEqual(result.x, proposed.x, accuracy: 0.001)
        XCTAssertEqual(result.y, proposed.y, accuracy: 0.001)
    }

    func testSnapPositionSnapsToRightEdge() {
        let headA = HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100))
        let headB = HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 200, y: 200))

        // Propose a position that is close to headA's right edge (100 + 60 = 160)
        let proposed = CGPoint(x: 155, y: 100)

        let result = engine.snapPosition(
            for: headB.id,
            proposedPosition: proposed,
            allHeads: [headA, headB],
            headSize: 60,
            snapDistance: 60
        )

        // Should snap to headA's right edge: x = 100 + 60 = 160
        XCTAssertEqual(result.x, 160, accuracy: 0.001, "Should snap to the right edge of headA")
    }

    func testSnapPositionSnapsToLeftEdge() {
        let headA = HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 200, y: 100))
        let headB = HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 100, y: 100))

        // Propose a position that is close to headA's left edge (200 - 60 = 140)
        let proposed = CGPoint(x: 145, y: 100)

        let result = engine.snapPosition(
            for: headB.id,
            proposedPosition: proposed,
            allHeads: [headA, headB],
            headSize: 60,
            snapDistance: 60
        )

        // Should snap to headA's left edge: x = 200 - 60 = 140
        XCTAssertEqual(result.x, 140, accuracy: 0.001, "Should snap to the left edge of headA")
    }

    func testSnapPositionDoesNotSnapWhenFarAway() {
        let headA = HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100))
        let headB = HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 500, y: 500))

        let proposed = CGPoint(x: 500, y: 500)

        let result = engine.snapPosition(
            for: headB.id,
            proposedPosition: proposed,
            allHeads: [headA, headB],
            headSize: 60,
            snapDistance: 60
        )

        // Too far away to snap
        XCTAssertEqual(result.x, 500, accuracy: 0.001)
        XCTAssertEqual(result.y, 500, accuracy: 0.001)
    }

    func testUpdateSnapGroupsCreatesGroupForTouchingHeads() {
        var heads = [
            HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100)),
            HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 160, y: 100)),
        ]

        engine.updateSnapGroups(&heads, headSize: 60, snapDistance: 60)

        // Heads are exactly headSize apart on X (|160-100| = 60), same Y -> should be grouped
        XCTAssertNotNil(heads[0].snapGroupID, "Touching heads should have a snap group")
        XCTAssertNotNil(heads[1].snapGroupID, "Touching heads should have a snap group")
        XCTAssertEqual(heads[0].snapGroupID, heads[1].snapGroupID, "Touching heads should share the same group")
    }

    func testUpdateSnapGroupsNoGroupForDistantHeads() {
        var heads = [
            HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100)),
            HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 500, y: 500)),
        ]

        engine.updateSnapGroups(&heads, headSize: 60, snapDistance: 60)

        XCTAssertNil(heads[0].snapGroupID, "Distant heads should not be grouped")
        XCTAssertNil(heads[1].snapGroupID, "Distant heads should not be grouped")
    }

    func testUpdateSnapGroupsTransitiveGrouping() {
        // A touches B, B touches C => all three should be in the same group
        var heads = [
            HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100)),
            HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 160, y: 100)),
            HeadInstance(name: "C", folderPath: "/c", position: CGPoint(x: 220, y: 100)),
        ]

        engine.updateSnapGroups(&heads, headSize: 60, snapDistance: 60)

        XCTAssertNotNil(heads[0].snapGroupID)
        XCTAssertEqual(heads[0].snapGroupID, heads[1].snapGroupID)
        XCTAssertEqual(heads[1].snapGroupID, heads[2].snapGroupID)
    }

    func testMoveGroupMovesAllGroupMembers() {
        let groupID = UUID()
        var heads = [
            HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100), snapGroupID: groupID),
            HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 160, y: 100), snapGroupID: groupID),
            HeadInstance(name: "C", folderPath: "/c", position: CGPoint(x: 500, y: 500)),
        ]

        let delta = CGVector(dx: 50, dy: 30)
        engine.moveGroup(anchorID: heads[0].id, delta: delta, heads: &heads)

        // A and B should both have moved by delta
        XCTAssertEqual(heads[0].position.x, 150, accuracy: 0.001)
        XCTAssertEqual(heads[0].position.y, 130, accuracy: 0.001)
        XCTAssertEqual(heads[1].position.x, 210, accuracy: 0.001)
        XCTAssertEqual(heads[1].position.y, 130, accuracy: 0.001)

        // C is not in the group, should be unchanged
        XCTAssertEqual(heads[2].position.x, 500, accuracy: 0.001)
        XCTAssertEqual(heads[2].position.y, 500, accuracy: 0.001)
    }

    func testMoveGroupDoesNothingForUngroupedHead() {
        var heads = [
            HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100)),
        ]

        engine.moveGroup(anchorID: heads[0].id, delta: CGVector(dx: 50, dy: 50), heads: &heads)

        // No group, so nothing should move
        XCTAssertEqual(heads[0].position.x, 100, accuracy: 0.001)
        XCTAssertEqual(heads[0].position.y, 100, accuracy: 0.001)
    }
}

// MARK: - HeadInstance Codable Tests

final class HeadInstanceCodableTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let groupID = UUID()
        let original = HeadInstance(
            name: "my-project",
            folderPath: "/Users/test/my-project",
            extraArgs: ["--model", "opus"],
            avatarImageData: Data([0x89, 0x50, 0x4E, 0x47]),
            position: CGPoint(x: 123.5, y: 456.7),
            screenID: 42,
            isPinned: true,
            state: .running,
            isWaving: true,
            snapGroupID: groupID
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HeadInstance.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.folderPath, original.folderPath)
        XCTAssertEqual(decoded.extraArgs, original.extraArgs)
        XCTAssertEqual(decoded.avatarImageData, original.avatarImageData)
        XCTAssertEqual(decoded.position.x, original.position.x, accuracy: 0.001)
        XCTAssertEqual(decoded.position.y, original.position.y, accuracy: 0.001)
        XCTAssertEqual(decoded.screenID, original.screenID)
        XCTAssertEqual(decoded.isPinned, original.isPinned)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertEqual(decoded.isWaving, original.isWaving)
        XCTAssertEqual(decoded.snapGroupID, original.snapGroupID)

        // processID should not be persisted
        XCTAssertNil(decoded.processID)
    }

    func testDecodingWithMissingOptionalFields() throws {
        // Minimal JSON -- only required fields
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "name": "test",
            "folderPath": "/tmp",
            "position": [100, 200],
            "screenID": 1
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(HeadInstance.self, from: data)

        XCTAssertEqual(decoded.name, "test")
        XCTAssertEqual(decoded.folderPath, "/tmp")
        XCTAssertEqual(decoded.extraArgs, [])
        XCTAssertNil(decoded.avatarImageData)
        XCTAssertEqual(decoded.isPinned, false)
        XCTAssertEqual(decoded.state, .idle)
        XCTAssertEqual(decoded.isWaving, false)
        XCTAssertNil(decoded.snapGroupID)
    }

    func testEncodingExcludesProcessID() throws {
        let head = HeadInstance(
            name: "test",
            folderPath: "/tmp",
            processID: 12345
        )

        let data = try JSONEncoder().encode(head)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertFalse(jsonString.contains("processID"), "processID should not be encoded")
    }

    func testArrayCodableRoundTrip() throws {
        let heads = [
            HeadInstance(name: "a", folderPath: "/a", position: CGPoint(x: 10, y: 20)),
            HeadInstance(name: "b", folderPath: "/b", position: CGPoint(x: 30, y: 40)),
        ]

        let data = try JSONEncoder().encode(heads)
        let decoded = try JSONDecoder().decode([HeadInstance].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "a")
        XCTAssertEqual(decoded[1].name, "b")
        XCTAssertEqual(decoded[0].id, heads[0].id)
        XCTAssertEqual(decoded[1].id, heads[1].id)
    }
}

// MARK: - HeadState Tests

final class HeadStateTests: XCTestCase {

    func testCodableRoundTrip() throws {
        for state in [HeadState.idle, .running, .finished, .errored] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(HeadState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }
}

// MARK: - HeadGeometry Tests

final class HeadGeometryTests: XCTestCase {

    func testWindowSizeIncludesEmojiOverhangAndLabel() {
        let g = HeadGeometry(diameter: 60)
        XCTAssertEqual(g.emojiSize, 60 * HeadGeometry.emojiScale, accuracy: 0.001)
        XCTAssertEqual(g.totalWidth, 60 + g.emojiSize, accuracy: 0.001)
        XCTAssertEqual(g.stackHeight, 60 + g.emojiSize * HeadGeometry.emojiOverhang, accuracy: 0.001)
        XCTAssertEqual(g.totalHeight, g.stackHeight + HeadGeometry.labelHeight, accuracy: 0.001)
        XCTAssertEqual(g.windowSize.width, g.totalWidth, accuracy: 0.001)
        XCTAssertEqual(g.windowSize.height, g.totalHeight, accuracy: 0.001)
    }

    func testCircleIsCentredHorizontallyAndSitsAboveLabel() {
        let g = HeadGeometry(diameter: 80)
        XCTAssertEqual(g.circleOffsetX * 2 + g.diameter, g.totalWidth, accuracy: 0.001)
        XCTAssertEqual(g.circleBottomY, HeadGeometry.labelHeight + HeadGeometry.labelSpacing, accuracy: 0.001)
        XCTAssertEqual(g.circleTopY, g.circleBottomY + 80, accuracy: 0.001)
        XCTAssertLessThanOrEqual(g.circleTopY, g.totalHeight, "Circle must fit inside the window")
    }
}

// MARK: - StoredSettings Tests

final class StoredSettingsTests: XCTestCase {

    /// Settings JSON written before "Show children for subagents" existed has no such key;
    /// it must still decode, and `AppSettings.load()` then defaults the flag to true.
    func testDecodesSettingsWrittenBeforeShowSubagentChildrenExisted() throws {
        let legacy = """
        {"defaultExtraArgs":"","terminalFontName":"Menlo","terminalFontSize":12,
         "headSize":"medium","snapDistance":60,"launchAtLogin":false,
         "showStatusIndicator":true,"claudeContinue":true}
        """
        let stored = try JSONDecoder().decode(StoredSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(stored.showSubagentChildren, "missing key must decode as nil, not fail or default here")
        XCTAssertEqual(stored.showStatusIndicator, true)
    }

    func testShowSubagentChildrenRoundTrips() throws {
        let stored = StoredSettings(
            defaultExtraArgs: "", terminalFontName: "Menlo", terminalFontSize: 12,
            headSize: .large, snapDistance: 60, launchAtLogin: false,
            showStatusIndicator: false, showSubagentChildren: false,
            claudeContinue: true, claudeSkipPermissions: false, claudeRemoteControl: false
        )
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: data)
        XCTAssertEqual(decoded.showSubagentChildren, false)
    }
}

// MARK: - HeadSize Tests

final class HeadSizeTests: XCTestCase {

    func testCodableRoundTrip() throws {
        for size in HeadSize.allCases {
            let data = try JSONEncoder().encode(size)
            let decoded = try JSONDecoder().decode(HeadSize.self, from: data)
            XCTAssertEqual(decoded, size)
        }
    }
}

// MARK: - SavedHead Tests

final class SavedHeadTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let groupID = UUID()
        let original = SavedHead(
            id: UUID(),
            name: "test-project",
            folderPath: "/Users/test/project",
            extraArgs: ["--verbose"],
            avatarImageData: Data([1, 2, 3]),
            position: CGPoint(x: 50, y: 60),
            screenID: 7,
            isPinned: true,
            snapGroupID: groupID
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedHead.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.folderPath, original.folderPath)
        XCTAssertEqual(decoded.extraArgs, original.extraArgs)
        XCTAssertEqual(decoded.avatarImageData, original.avatarImageData)
        XCTAssertEqual(decoded.position.x, original.position.x, accuracy: 0.001)
        XCTAssertEqual(decoded.position.y, original.position.y, accuracy: 0.001)
        XCTAssertEqual(decoded.screenID, original.screenID)
        XCTAssertEqual(decoded.isPinned, original.isPinned)
        XCTAssertEqual(decoded.snapGroupID, original.snapGroupID)
    }

    func testCodableWithNilOptionals() throws {
        let original = SavedHead(
            id: UUID(),
            name: "minimal",
            folderPath: "/tmp",
            extraArgs: [],
            avatarImageData: nil,
            position: .zero,
            screenID: 0,
            isPinned: false,
            snapGroupID: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedHead.self, from: data)

        XCTAssertNil(decoded.avatarImageData)
        XCTAssertNil(decoded.snapGroupID)
    }
}

// MARK: - AvatarGenerator Tests

final class AvatarGeneratorTests: XCTestCase {

    func testGenerateAvatarReturnsCorrectSize() {
        let size: CGFloat = 80
        let image = AvatarGenerator.generateAvatar(
            folderName: "test-project",
            folderPath: "/Users/test/project",
            size: size
        )

        XCTAssertEqual(image.size.width, size, accuracy: 0.001)
        XCTAssertEqual(image.size.height, size, accuracy: 0.001)
    }

    func testGenerateAvatarWithCustomSize() {
        let size: CGFloat = 120
        let image = AvatarGenerator.generateAvatar(
            folderName: "my-app",
            folderPath: "/tmp/my-app",
            size: size
        )

        XCTAssertEqual(image.size.width, size, accuracy: 0.001)
        XCTAssertEqual(image.size.height, size, accuracy: 0.001)
    }

    func testGenerateAvatarWithEmptyName() {
        // Should not crash with empty name
        let image = AvatarGenerator.generateAvatar(
            folderName: "",
            folderPath: "/tmp",
            size: 60
        )
        XCTAssertEqual(image.size.width, 60, accuracy: 0.001)
    }

    func testGenerateAvatarWithSingleCharName() {
        let image = AvatarGenerator.generateAvatar(
            folderName: "~",
            folderPath: "/Users/test",
            size: 60
        )
        XCTAssertEqual(image.size.width, 60, accuracy: 0.001)
    }
}

// MARK: - HeadInstance Equality Tests

final class HeadInstanceEqualityTests: XCTestCase {

    func testEqualityBasedOnID() {
        let id = UUID()
        let a = HeadInstance(id: id, name: "a", folderPath: "/a")
        let b = HeadInstance(id: id, name: "b", folderPath: "/b")

        XCTAssertEqual(a, b, "HeadInstances with the same ID should be equal")
    }

    func testInequalityForDifferentIDs() {
        let a = HeadInstance(name: "same", folderPath: "/same")
        let b = HeadInstance(name: "same", folderPath: "/same")

        XCTAssertNotEqual(a, b, "HeadInstances with different IDs should not be equal")
    }

    func testHashConsistency() {
        let id = UUID()
        let head = HeadInstance(id: id, name: "test", folderPath: "/test")

        var set = Set<HeadInstance>()
        set.insert(head)
        set.insert(head) // duplicate

        XCTAssertEqual(set.count, 1, "Set should deduplicate by ID")
    }
}

// MARK: - Integration: SnapEngine + HeadInstance

final class SnapEngineIntegrationTests: XCTestCase {

    func testVerticalSnapAlignment() {
        let engine = SnapEngine()

        let headA = HeadInstance(name: "A", folderPath: "/a", position: CGPoint(x: 100, y: 100))
        let headB = HeadInstance(name: "B", folderPath: "/b", position: CGPoint(x: 200, y: 200))

        // Propose B directly below A (within snap distance on X)
        let proposed = CGPoint(x: 102, y: 162)

        let result = engine.snapPosition(
            for: headB.id,
            proposedPosition: proposed,
            allHeads: [headA, headB],
            headSize: 60,
            snapDistance: 60
        )

        // Should snap Y to exactly headA.y + headSize = 160, and X to centre-align at 100
        XCTAssertEqual(result.y, 160, accuracy: 0.001, "Should snap to bottom edge of headA")
        XCTAssertEqual(result.x, 100, accuracy: 0.001, "Should centre-align with headA")
    }

    func testSnapGroupCycleDoesNotCrash() {
        // Ensure BFS-based grouping handles various configurations without issues
        let engine = SnapEngine()
        var heads = (0..<10).map { i in
            HeadInstance(
                name: "H\(i)",
                folderPath: "/h\(i)",
                position: CGPoint(x: CGFloat(i) * 60, y: 100)
            )
        }

        // All are in a row touching each other
        engine.updateSnapGroups(&heads, headSize: 60, snapDistance: 60)

        // All should be in the same group
        let groupID = heads[0].snapGroupID
        XCTAssertNotNil(groupID)
        for head in heads {
            XCTAssertEqual(head.snapGroupID, groupID)
        }
    }
}

// MARK: - PositionManager Clamp Tests

final class PositionManagerClampTests: XCTestCase {

    let manager = PositionManager.shared
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let size = NSSize(width: 100, height: 120)

    func testPointInsideIsUnchanged() {
        let p = manager.clampPosition(CGPoint(x: 300, y: 300), size: size, to: screen)
        XCTAssertEqual(p, CGPoint(x: 300, y: 300))
    }

    func testFullRectKeptInsideRightAndTopEdges() {
        // Origin is on-screen but the rect would hang off the right/top edges.
        let p = manager.clampPosition(CGPoint(x: 990, y: 790), size: size, to: screen)
        XCTAssertEqual(p.x, screen.maxX - size.width, accuracy: 0.001)
        XCTAssertEqual(p.y, screen.maxY - size.height, accuracy: 0.001)
    }

    func testClampsToLeftAndBottomEdges() {
        let p = manager.clampPosition(CGPoint(x: -50, y: -50), size: size, to: screen)
        XCTAssertEqual(p, CGPoint(x: 0, y: 0))
    }

    func testOversizedRectPinsToMinEdge() {
        let huge = NSSize(width: 2000, height: 2000)
        let p = manager.clampPosition(CGPoint(x: 500, y: 500), size: huge, to: screen)
        XCTAssertEqual(p, CGPoint(x: screen.minX, y: screen.minY))
    }

    func testHeadGeometryClampUsesFullWindowSize() {
        // The remap clamp and the drag clamp share this rule: the whole head window
        // (circle + emoji overhang + label) must stay inside the screen.
        let g = HeadGeometry(diameter: 80)
        let p = g.clampWindowOrigin(CGPoint(x: 990, y: 790), in: screen)
        XCTAssertEqual(p.x, screen.maxX - g.windowSize.width, accuracy: 0.001)
        XCTAssertEqual(p.y, screen.maxY - g.windowSize.height, accuracy: 0.001)
        XCTAssertEqual(
            manager.clampPosition(CGPoint(x: 990, y: 790), size: g.windowSize, to: screen), p)
    }
}
