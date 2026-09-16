import Foundation
import XCTest

@testable import ClaudeHeadsCore

// MARK: - OrbitLayout Tests

final class OrbitLayoutTests: XCTestCase {

    func testChildIsAboutAThirdOfParentAndRingClearsParent() {
        let layout = OrbitLayout(parentDiameter: 60)
        XCTAssertEqual(layout.childDiameter, 21, accuracy: 0.001)
        XCTAssertGreaterThan(layout.orbitRadius - layout.childRadius, 30, "Children must not overlap the parent")
        XCTAssertEqual(layout.ringOuterRadius, layout.orbitRadius + layout.childRadius, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.panelInset + 30, layout.ringOuterRadius, "Panel inset must contain the ring")
    }

    func testChildDiameterScalesWithEveryHeadSize() {
        // Children are 35% of the parent for every head size setting, so switching
        // small/medium/large rescales the ring rather than leaving fixed-size children.
        var previous: CGFloat = 0
        for size in [HeadSize.small, .medium, .large] {
            let layout = OrbitLayout(parentDiameter: size.diameter)
            XCTAssertEqual(layout.childDiameter, size.diameter * 0.35, accuracy: 0.001, "\(size)")
            XCTAssertGreaterThan(layout.childDiameter, previous, "childDiameter must grow with head size (\(size))")
            XCTAssertGreaterThan(layout.panelInset, 0, "\(size)")
            previous = layout.childDiameter
        }
    }

    func testPanelInsetScalesWithHeadSize() {
        let insets = [HeadSize.small, .medium, .large].map { OrbitLayout(parentDiameter: $0.diameter).panelInset }
        XCTAssertEqual(insets, insets.sorted(), "Panel inset must not shrink as heads grow")
        XCTAssertEqual(Set(insets).count, insets.count, "Each head size needs its own inset")
    }

    func testChildrenAreEvenlySpacedOnTheOrbit() {
        let layout = OrbitLayout(parentDiameter: 80)
        let count = 4
        let offsets = (0..<count).map { layout.offset(index: $0, count: count, phase: 0) }

        for o in offsets {
            XCTAssertEqual(hypot(o.dx, o.dy), layout.orbitRadius, accuracy: 0.001)
        }
        for i in 0..<count {
            let a = layout.angle(index: i, count: count, phase: 0)
            let b = layout.angle(index: (i + 1) % count, count: count, phase: 0)
            let step = ((b - a).truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            XCTAssertEqual(step, .pi / 2, accuracy: 0.0001)
        }
    }

    func testHitTestMatchesOffsets() {
        let layout = OrbitLayout(parentDiameter: 60)
        let phase = 1.234
        let o = layout.offset(index: 1, count: 3, phase: phase)
        XCTAssertTrue(layout.hits(point: CGPoint(x: o.dx, y: o.dy), index: 1, count: 3, phase: phase))
        XCTAssertFalse(layout.hits(point: CGPoint(x: o.dx, y: o.dy), index: 0, count: 3, phase: phase))
        XCTAssertFalse(layout.hits(point: .zero, index: 1, count: 3, phase: phase), "Parent centre is not a child")
    }

    func testPhaseAdvancesWithTimeAndWraps() {
        let now = Date()
        let p0 = OrbitLayout.phase(at: now)
        let p1 = OrbitLayout.phase(at: now.addingTimeInterval(OrbitLayout.rotationPeriod / 4))
        let full = OrbitLayout.phase(at: now.addingTimeInterval(OrbitLayout.rotationPeriod))
        let delta = (p1 - p0 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        XCTAssertEqual(delta, .pi / 2, accuracy: 0.0001)
        // One full period later the ring is back where it started (modulo 2π).
        let wrap = abs(full - p0)
        XCTAssertTrue(wrap < 0.0001 || abs(wrap - 2 * .pi) < 0.0001, "phase should wrap after a full period, got \(wrap)")
    }
}
