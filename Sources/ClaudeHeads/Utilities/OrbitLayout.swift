import Foundation

// MARK: - OrbitLayout

/// Geometry for the ring of subagent heads that orbit a parent head.
///
/// Both the SwiftUI rendering (`SubagentOrbitView`) and the AppKit hit-testing in
/// `HeadWindowController` derive child positions from here, using the same wall-clock
/// phase, so what you see is what you can click. All offsets are relative to the parent
/// circle's centre in a y-up coordinate system (AppKit); SwiftUI callers negate `dy`.
struct OrbitLayout: Equatable {
    /// Child diameter as a fraction of the parent diameter.
    static let childScale: CGFloat = 0.35
    /// Gap between the parent circle's edge and the nearest edge of a child.
    static let gap: CGFloat = 6
    /// Extra transparent slack kept around the ring inside the panel.
    static let panelSlack: CGFloat = 4
    /// Seconds for one full revolution of the ring.
    static let rotationPeriod: TimeInterval = 24
    /// Shared epoch so every consumer computes the same phase for the same instant.
    private static let epoch = Date()

    let parentDiameter: CGFloat

    init(parentDiameter: CGFloat) {
        self.parentDiameter = parentDiameter
    }

    /// Layout for the head size currently selected in settings, so children scale with
    /// small/medium/large heads.
    static var current: OrbitLayout {
        OrbitLayout(parentDiameter: HeadGeometry.current.diameter)
    }

    /// How much every head panel must grow beyond the plain head window right now: the
    /// ring inset for the current head size, or zero when "Show children for subagents" is
    /// off. `OrbitingHeadRootView` and `HeadWindowController` must agree on this number.
    static var currentPanelInset: CGFloat {
        AppSettings.shared.showSubagentChildren ? current.panelInset : 0
    }

    var childDiameter: CGFloat { parentDiameter * Self.childScale }
    var childRadius: CGFloat { childDiameter / 2 }

    /// Distance from the parent centre to each child's centre.
    var orbitRadius: CGFloat { parentDiameter / 2 + Self.gap + childRadius }

    /// Distance from the parent centre to the outer edge of the ring.
    var ringOuterRadius: CGFloat { orbitRadius + childRadius }

    /// How much the head panel must grow on every side (beyond the plain head window)
    /// so the ring fits inside it.
    var panelInset: CGFloat { ringOuterRadius - parentDiameter / 2 + Self.panelSlack }

    /// Current rotation of the ring, in radians, at `date`.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSince(epoch)
        return (t / rotationPeriod).truncatingRemainder(dividingBy: 1) * 2 * .pi
    }

    /// Angle (radians) of child `index` out of `count`, evenly spaced around the ring.
    /// The first child starts at the top of the ring.
    func angle(index: Int, count: Int, phase: Double) -> Double {
        guard count > 0 else { return phase }
        return phase + .pi / 2 + (2 * .pi * Double(index)) / Double(count)
    }

    /// Offset of child `index`'s centre from the parent centre (y up).
    func offset(index: Int, count: Int, phase: Double) -> CGVector {
        let a = angle(index: index, count: count, phase: phase)
        return CGVector(dx: orbitRadius * CGFloat(cos(a)), dy: orbitRadius * CGFloat(sin(a)))
    }

    /// Whether `point` (relative to the parent centre, y up) lies on child `index`.
    func hits(point: CGPoint, index: Int, count: Int, phase: Double) -> Bool {
        let o = offset(index: index, count: count, phase: phase)
        let dx = point.x - o.dx
        let dy = point.y - o.dy
        return dx * dx + dy * dy <= childRadius * childRadius
    }
}
