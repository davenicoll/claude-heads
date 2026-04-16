import AppKit
import SwiftUI

// MARK: - DraggablePanel

/// An NSPanel subclass that handles mouse events for drag-to-reposition.
final class DraggablePanel: NSPanel {
    private var dragOrigin: CGPoint = .zero
    private var windowOriginAtDragStart: CGPoint = .zero
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOriginAtDragStart = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y
        let newOrigin = CGPoint(
            x: windowOriginAtDragStart.x + dx,
            y: windowOriginAtDragStart.y + dy
        )

        // Consult snap engine callback if provided (may adjust origin in the future)
        onDragMoved?(newOrigin)

        setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?(frame.origin)
    }
}

// MARK: - HeadWindowController

final class HeadWindowController {
    private let head: HeadInstance
    private weak var appState: AppState?
    private let panel: DraggablePanel
    private var popover: NSPopover?

    init(head: HeadInstance, appState: AppState) {
        self.head = head
        self.appState = appState

        let diameter = AppSettings.shared.headSize.diameter
        let contentRect = NSRect(x: 0, y: 0, width: diameter, height: diameter + 20) // extra for label

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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        let headView = HeadView(head: head) { [weak self] in
            self?.handleHeadTapped()
        }
        let hostingView = NSHostingView(rootView: headView)
        hostingView.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = hostingView

        // Apply saved position
        let origin = NSPoint(x: head.position.x, y: head.position.y)
        panel.setFrameOrigin(origin)

        // Drag callbacks
        panel.onDragMoved = { _ in
            // Future: consult SnapEngine here and adjust proposedOrigin
        }

        panel.onDragEnded = { [weak self] finalOrigin in
            guard let self else { return }
            self.head.position = CGPoint(x: finalOrigin.x, y: finalOrigin.y)
            self.appState?.saveState()
        }
    }

    // MARK: - Window Management

    func showWindow() {
        panel.orderFront(nil)
    }

    func close() {
        dismissPopover()
        panel.orderOut(nil)
    }

    func bringToFront() {
        panel.orderFront(nil)
    }

    // MARK: - Popover Management

    func togglePopover() {
        if let existing = popover, existing.isShown {
            dismissPopover()
        } else {
            showPopover()
        }
    }

    func dismissPopover() {
        popover?.performClose(nil)
        popover = nil
    }

    // MARK: - Private

    private func handleHeadTapped() {
        appState?.toggleTerminal(for: head.id)
    }

    private func showPopover() {
        guard let contentView = panel.contentView else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 600, height: 400)
        popover.animates = true

        let terminalView = TerminalPopover(head: head) { [weak self] in
            self?.dismissPopover()
            self?.appState?.pinTerminal(for: self?.head.id ?? UUID())
        }
        popover.contentViewController = NSHostingController(rootView: terminalView)
        popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)

        self.popover = popover
    }
}
