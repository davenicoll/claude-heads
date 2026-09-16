import AppKit
import SwiftUI

// MARK: - PassthroughHostingView

/// An NSHostingView subclass that forwards all mouse events to its window
/// instead of letting SwiftUI's gesture system consume them.
/// Also accepts first mouse so the panel responds without needing a focus click.
///
/// The panel is larger than the visible head (it leaves room for the subagent orbit
/// ring), so hit-testing is restricted by `hitRegion`: points outside the parent head
/// and its orbiting children are not claimed by this view, and the transparent panel
/// area lets the click fall through to whatever is underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Returns true when a point (in *window* coordinates, y up) is on a visible,
    /// clickable part of the head. When nil, the whole view is hittable.
    ///
    /// NSHostingView is flipped (y down), so the region is always evaluated in window
    /// space: that is the frame `DraggablePanel.mouseDown` (`event.locationInWindow`)
    /// and `OrbitLayout` use, so both AppKit hit paths agree.
    var hitRegion: ((NSPoint) -> Bool)?

    /// The rect (in *window* coordinates) that should show the arrow cursor.
    var cursorRect: NSRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(cursorRect.map { convert($0, from: nil) } ?? bounds, cursor: .arrow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        if let hitRegion, !hitRegion(convert(local, to: nil)) { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        window?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        window?.mouseUp(with: event)
    }
}

// MARK: - DraggablePanel

/// An NSPanel subclass that handles mouse events for drag-to-reposition.
///
/// The panel frame is the head window (see `HeadGeometry.windowSize`) inflated by
/// `contentInset` on every side to leave room for the subagent orbit ring. All the
/// clamping below reasons about the head circle, not the inflated frame.
final class DraggablePanel: NSPanel {
    private var dragOrigin: CGPoint = .zero
    private var windowOriginAtDragStart: CGPoint = .zero
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onClicked: (() -> Void)?
    /// Returns true when a mouse-down at the given window-local point should start a
    /// press (click or drag). Presses elsewhere on the transparent panel are ignored.
    var hitRegion: ((NSPoint) -> Bool)?
    /// Transparent padding between the panel frame and the head window it contains.
    var contentInset: CGFloat = 0
    private var didDrag = false
    private var pressActive = false

    // Head panels should never steal key/main from the terminal panel
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let local = event.locationInWindow
        if let hitRegion, !hitRegion(local) {
            pressActive = false
            return
        }
        pressActive = true
        dragOrigin = NSEvent.mouseLocation
        windowOriginAtDragStart = frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressActive else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y

        // Only start dragging after a 3pt threshold to avoid accidental drags eating clicks
        if !didDrag && (dx * dx + dy * dy) < 9 { return }
        didDrag = true

        var newOrigin = CGPoint(
            x: windowOriginAtDragStart.x + dx,
            y: windowOriginAtDragStart.y + dy
        )

        newOrigin = clampedToScreen(newOrigin, near: current)

        onDragMoved?(newOrigin)
        setFrameOrigin(newOrigin)
    }

    /// Clamps a panel origin so the head's circle stays fully inside the visible
    /// frame of the screen containing `point` (or this panel's screen). The panel
    /// includes the orbit inset, emoji padding and a label, but only the circle needs
    /// to stay visible.
    func clampedToScreen(_ origin: CGPoint, near point: CGPoint? = nil) -> CGPoint {
        let screen = point.flatMap { p in NSScreen.screens.first(where: { $0.frame.contains(p) }) }
            ?? self.screen ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return origin }
        let g = HeadGeometry.current
        let inset = contentInset
        var clamped = origin
        clamped.x = max(sf.minX - inset - g.circleOffsetX,
                        min(clamped.x, sf.maxX - inset - g.circleOffsetX - g.diameter))
        clamped.y = max(sf.minY - inset - g.circleBottomY,
                        min(clamped.y, sf.maxY - inset - g.circleTopY))
        return clamped
    }

    override func mouseUp(with event: NSEvent) {
        guard pressActive else { return }
        pressActive = false
        if didDrag {
            onDragEnded?(frame.origin)
        } else {
            onClicked?()
        }
    }
}

// MARK: - OrbitingHeadRootView

/// Root SwiftUI view of a head panel: the head itself, padded on every side by the
/// orbit inset so the head window sits at `head.position` while the panel is larger.
struct OrbitingHeadRootView: View {
    let head: HeadInstance

    var body: some View {
        let geometry = HeadGeometry.current
        let inset = OrbitLayout(parentDiameter: geometry.diameter).panelInset
        HeadView(head: head)
            .frame(width: geometry.totalWidth, height: geometry.totalHeight)
            .padding(inset)
    }
}

// MARK: - HeadWindowController

final class HeadWindowController {
    private let head: HeadInstance
    private weak var appState: AppState?
    private let panel: DraggablePanel
    private let hostingView: PassthroughHostingView<OrbitingHeadRootView>

    init(head: HeadInstance, appState: AppState) {
        self.head = head
        self.appState = appState

        let inset = Self.orbitInset()
        let contentRect = NSRect(origin: .zero, size: Self.panelSize(inset: inset))

        panel = DraggablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentInset = inset

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        // We own the panel's lifetime; it is freed when this controller drops it in tearDown().
        panel.isReleasedWhenClosed = false

        hostingView = PassthroughHostingView(rootView: OrbitingHeadRootView(head: head))
        hostingView.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = hostingView

        panel.setFrameOrigin(panelOrigin(forHeadPosition: head.position))

        // Hit-testing: only the parent head (circle + label) and the orbiting children.
        // Both closures receive window-local (y up) points.
        hostingView.hitRegion = { [weak self] point in
            self?.isHittable(point) ?? true
        }
        panel.hitRegion = { [weak self] point in
            self?.isHittable(point) ?? true
        }
        hostingView.cursorRect = headRectInPanel()

        // Click → toggle terminal
        panel.onClicked = { [weak self] in
            guard let self else { return }
            self.appState?.toggleTerminal(for: self.head.id)
        }

        panel.onDragMoved = { [weak self] newOrigin in
            guard let self else { return }
            self.head.position = self.headPosition(forPanelOrigin: newOrigin)
            // Move the terminal window with the head during drag
            self.appState?.repositionTerminal(for: self.head.id)
        }

        panel.onDragEnded = { [weak self] finalOrigin in
            guard let self else { return }
            // Snap first, then re-clamp: SnapEngine knows nothing about screen bounds.
            // Snapping works in head coordinates; clamping in panel coordinates.
            let proposedHead = self.headPosition(forPanelOrigin: finalOrigin)
            let snappedPanel = self.panel.clampedToScreen(
                self.panelOrigin(forHeadPosition: self.snappedOrigin(for: proposedHead))
            )
            self.head.position = self.headPosition(forPanelOrigin: snappedPanel)
            if snappedPanel != finalOrigin {
                self.panel.setFrameOrigin(snappedPanel)
            }
            self.updateSnapGroups()
            if let screen = self.panel.screen {
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                if let screenID = screen.deviceDescription[key] as? UInt32 {
                    self.head.screenID = screenID
                }
            }
            self.appState?.repositionTerminal(for: self.head.id)
            self.appState?.saveState()
        }
    }

    deinit {
        NSLog("[HeadWindowController] deinit for head \(head.id)")
    }

    func showWindow() {
        panel.orderFront(nil)
    }

    /// Hides the panel without destroying it.
    func close() {
        panel.orderOut(nil)
    }

    /// Permanently closes the panel and breaks references so everything can deallocate.
    /// The controller must not be used after this call.
    func tearDown() {
        panel.onClicked = nil
        panel.onDragMoved = nil
        panel.onDragEnded = nil
        panel.hitRegion = nil
        hostingView.hitRegion = nil
        panel.close()
        panel.contentView = nil
    }

    func bringToFront() {
        panel.orderFront(nil)
    }

    func syncPosition() {
        panel.setFrameOrigin(panelOrigin(forHeadPosition: head.position))
    }

    // MARK: - Geometry

    /// `head.position` is the origin of the plain head window (`HeadGeometry.windowSize`),
    /// which is what snapping, persistence and terminal anchoring all use. The panel is
    /// that window grown by the orbit inset on every side.
    private static func orbitInset() -> CGFloat {
        OrbitLayout(parentDiameter: HeadGeometry.current.diameter).panelInset
    }

    private static func panelSize(inset: CGFloat) -> NSSize {
        let w = HeadGeometry.current.windowSize
        return NSSize(width: w.width + inset * 2, height: w.height + inset * 2)
    }

    private func panelOrigin(forHeadPosition p: CGPoint) -> NSPoint {
        NSPoint(x: p.x - panel.contentInset, y: p.y - panel.contentInset)
    }

    private func headPosition(forPanelOrigin o: CGPoint) -> CGPoint {
        CGPoint(x: o.x + panel.contentInset, y: o.y + panel.contentInset)
    }

    /// The plain head window rect in panel-local coordinates.
    private func headRectInPanel() -> NSRect {
        NSRect(origin: NSPoint(x: panel.contentInset, y: panel.contentInset), size: HeadGeometry.current.windowSize)
    }

    /// Centre of the head circle in panel-local coordinates (y up).
    private func circleCentreInPanel() -> NSPoint {
        let g = HeadGeometry.current
        let r = headRectInPanel()
        return NSPoint(x: r.minX + g.circleOffsetX + g.diameter / 2, y: r.minY + g.circleBottomY + g.diameter / 2)
    }

    /// True when a panel-local point is on the parent circle, its name label, or one of
    /// the orbiting subagent heads. Everything else on the panel is transparent and inert.
    private func isHittable(_ point: NSPoint) -> Bool {
        let g = HeadGeometry.current
        let centre = circleCentreInPanel()
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let radius = g.diameter / 2 + 2
        if dx * dx + dy * dy <= radius * radius { return true }

        // Name label strip under the circle.
        let r = headRectInPanel()
        let label = NSRect(x: r.minX + g.circleOffsetX - 5, y: r.minY, width: g.diameter + 10, height: g.circleBottomY)
        if label.contains(point) { return true }

        let children = head.children
        guard !children.isEmpty else { return false }
        let layout = OrbitLayout(parentDiameter: g.diameter)
        let phase = OrbitLayout.phase(at: Date())
        let relative = CGPoint(x: dx, y: dy)
        return children.indices.contains { index in
            layout.hits(point: relative, index: index, count: children.count, phase: phase)
        }
    }

    // MARK: - Snapping

    private let snapEngine = SnapEngine()

    /// Returns where the head should land after a drag: magnetically snapped to a
    /// neighbouring head's edge if one is within the configured snap distance,
    /// otherwise the proposed origin unchanged.
    ///
    /// Head origins all share the same window geometry, so snapping origins
    /// `diameter` apart puts the circles exactly edge-to-edge horizontally. When
    /// snapping vertically the gap is widened by the label strip so the upper
    /// head's name label is not drawn over the lower head's circle.
    private func snappedOrigin(for proposed: CGPoint) -> CGPoint {
        guard let appState else { return proposed }
        let diameter = AppSettings.shared.headSize.diameter
        var snapped = snapEngine.snapPosition(
            for: head.id,
            proposedPosition: proposed,
            allHeads: appState.heads,
            headSize: diameter,
            snapDistance: AppSettings.shared.snapDistance
        )

        if snapped.y != proposed.y {
            let labelStrip = HeadGeometry.labelHeight + HeadGeometry.labelSpacing
            snapped.y += (snapped.y > proposed.y ? 1 : -1) * labelStrip
        }

        // Never snap directly on top of another head (both axes centre-aligned).
        let overlapsOther = appState.heads.contains { other in
            other.id != head.id
                && abs(other.position.x - snapped.x) < 1
                && abs(other.position.y - snapped.y) < 1
        }
        return overlapsOther ? proposed : snapped
    }

    /// Recomputes `snapGroupID` for every head so that touching heads share a group.
    private func updateSnapGroups() {
        guard let appState else { return }
        snapEngine.updateSnapGroups(
            &appState.heads,
            headSize: AppSettings.shared.headSize.diameter,
            snapDistance: AppSettings.shared.snapDistance
        )
    }

    /// Resize the panel and hosting view to match the current head size setting.
    func resizeToFit() {
        let inset = Self.orbitInset()
        let newSize = Self.panelSize(inset: inset)

        var frame = panel.frame
        // Keep the center position stable
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = newSize
        frame.origin = NSPoint(x: oldCenter.x - newSize.width / 2, y: oldCenter.y - newSize.height / 2)
        panel.contentInset = inset
        panel.setFrame(frame, display: true)
        head.position = headPosition(forPanelOrigin: frame.origin)

        hostingView.frame = NSRect(origin: .zero, size: newSize)
        hostingView.cursorRect = headRectInPanel()
        panel.invalidateCursorRects(for: hostingView)
    }
}
