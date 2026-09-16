import AppKit
import SwiftUI

// MARK: - PassthroughHostingView

/// An NSHostingView subclass that forwards all mouse events to its window
/// instead of letting SwiftUI's gesture system consume them.
/// Also accepts first mouse so the panel responds without needing a focus click.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
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
final class DraggablePanel: NSPanel {
    private var dragOrigin: CGPoint = .zero
    private var windowOriginAtDragStart: CGPoint = .zero
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onClicked: (() -> Void)?
    private var didDrag = false

    // Head panels should never steal key/main from the terminal panel
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOriginAtDragStart = frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
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

        // Clamp so the circle stays on screen. The window includes emoji padding
        // and a label, but only the circle needs to stay visible.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(current) }) ?? NSScreen.main {
            let sf = screen.visibleFrame
            let g = HeadGeometry.current

            newOrigin.x = max(sf.minX - g.circleOffsetX, min(newOrigin.x, sf.maxX - g.circleOffsetX - g.diameter))
            newOrigin.y = max(sf.minY - g.circleBottomY, min(newOrigin.y, sf.maxY - g.circleTopY))
        }

        onDragMoved?(newOrigin)
        setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?(frame.origin)
        } else {
            onClicked?()
        }
    }
}

// MARK: - HeadWindowController

final class HeadWindowController {
    private let head: HeadInstance
    private weak var appState: AppState?
    private let panel: DraggablePanel

    init(head: HeadInstance, appState: AppState) {
        self.head = head
        self.appState = appState

        let contentRect = NSRect(origin: .zero, size: HeadGeometry.current.windowSize)

        panel = DraggablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        let headView = HeadView(head: head)
        let hostingView = PassthroughHostingView(rootView: headView)
        hostingView.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = hostingView

        let origin = NSPoint(x: head.position.x, y: head.position.y)
        panel.setFrameOrigin(origin)

        // Click → toggle terminal
        panel.onClicked = { [weak self] in
            guard let self else { return }
            self.appState?.toggleTerminal(for: self.head.id)
        }

        panel.onDragMoved = { [weak self] newOrigin in
            guard let self else { return }
            self.head.position = CGPoint(x: newOrigin.x, y: newOrigin.y)
            // Move the terminal window with the head during drag
            self.appState?.repositionTerminal(for: self.head.id)
        }

        panel.onDragEnded = { [weak self] finalOrigin in
            guard let self else { return }
            let snapped = self.snappedOrigin(for: finalOrigin)
            self.head.position = snapped
            if snapped != finalOrigin {
                self.panel.setFrameOrigin(snapped)
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

    func showWindow() {
        panel.orderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    func bringToFront() {
        panel.orderFront(nil)
    }

    func syncPosition() {
        panel.setFrameOrigin(NSPoint(x: head.position.x, y: head.position.y))
    }

    // MARK: - Snapping

    private let snapEngine = SnapEngine()

    /// Returns where the head should land after a drag: magnetically snapped to a
    /// neighbouring head's edge if one is within the configured snap distance,
    /// otherwise the proposed origin unchanged.
    ///
    /// Head origins all share the same window geometry, so snapping origins
    /// `diameter` apart puts the circles exactly edge-to-edge.
    private func snappedOrigin(for proposed: CGPoint) -> CGPoint {
        guard let appState else { return proposed }
        let diameter = AppSettings.shared.headSize.diameter
        let snapped = snapEngine.snapPosition(
            for: head.id,
            proposedPosition: proposed,
            allHeads: appState.heads,
            headSize: diameter,
            snapDistance: AppSettings.shared.snapDistance
        )

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
        let newSize = HeadGeometry.current.windowSize

        var frame = panel.frame
        // Keep the center position stable
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = newSize
        frame.origin = NSPoint(x: oldCenter.x - newSize.width / 2, y: oldCenter.y - newSize.height / 2)
        panel.setFrame(frame, display: true)

        if let hostingView = panel.contentView {
            hostingView.frame = NSRect(origin: .zero, size: newSize)
        }
    }
}
