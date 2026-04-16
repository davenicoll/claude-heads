import AppKit
import SwiftTerm
import SwiftUI

// MARK: - FloatingTerminalPanel

final class FloatingTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - TerminalWindowController

final class TerminalWindowController: NSObject, NSWindowDelegate {
    private let head: HeadInstance
    private weak var appState: AppState?
    private let panel: FloatingTerminalPanel
    let terminalView: TerminalView

    /// Strong reference to the bridge so it doesn't get garbage collected.
    var bridge: TerminalBridge?

    private static let defaultSize = NSSize(width: 800, height: 500)

    var isVisible: Bool {
        panel.isVisible
    }

    /// The panel's current frame, for collision detection by other windows.
    var panelFrame: NSRect {
        panel.frame
    }

    init(head: HeadInstance, terminalView: TerminalView, appState: AppState) {
        self.head = head
        self.appState = appState
        self.terminalView = terminalView

        let contentRect = NSRect(origin: .zero, size: Self.defaultSize)

        panel = FloatingTerminalPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.title = "Claude — \(head.name)"
        panel.minSize = NSSize(width: 400, height: 300)
        panel.isReleasedWhenClosed = false

        let container = NSView()
        panel.contentView = container

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    // MARK: - Window Management

    func showWindow() {
        appState?.ensureProcessRunning(for: head.id)

        let obstacles = appState?.obstacleRects(excluding: head.id) ?? []
        repositionNearHead(avoiding: obstacles)

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(terminalView)
    }

    func close() {
        panel.orderOut(nil)
    }

    func applyFont() {
        let settings = AppSettings.shared
        if let font = NSFont(name: settings.terminalFontName, size: settings.terminalFontSize) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    // MARK: - Positioning

    /// Computes the on-screen rect of the full head (circle + label + padding).
    /// This is the rect that the terminal must not overlap.
    func fullHeadRect() -> NSRect {
        let d = AppSettings.shared.headSize.diameter
        let emojiSize = d * 0.52
        let totalSize = d + emojiSize
        let zstackHeight = d + emojiSize * 0.6
        let labelHeight: CGFloat = 14
        let fullHeight = zstackHeight + labelHeight
        return NSRect(x: head.position.x, y: head.position.y, width: totalSize, height: fullHeight)
    }

    /// Tooltip-style positioning: opens toward the screen center, avoids all obstacles.
    ///
    /// Strategy:
    /// 1. Determine which direction points toward the screen center from this head
    /// 2. Try cardinal directions in priority order: toward-center first, then alternatives
    /// 3. For each candidate, check it doesn't overlap any obstacle rect
    /// 4. If all candidates collide, nudge the best one until clear
    func repositionNearHead(avoiding obstacles: [NSRect]) {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: head.position.x + 30, y: head.position.y + 30))
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let sf = screen.visibleFrame
        let cr = fullHeadRect()
        let pw = panel.frame.width
        let ph = panel.frame.height
        let gap: CGFloat = 12
        let screenCenter = NSPoint(x: sf.midX, y: sf.midY)

        // Direction from head toward screen center
        let dx = screenCenter.x - cr.midX
        let dy = screenCenter.y - cr.midY

        // Build candidates in priority order: toward center first
        // Each candidate is an origin point for the terminal
        enum Dir: CaseIterable { case below, above, right, left }

        // Sort directions: primary = toward center, secondary = perpendicular, last = away
        let prioritized: [Dir] = {
            var dirs: [(Dir, CGFloat)] = []
            // Score each direction by how much it aligns with the toward-center vector
            // Below = -Y, Above = +Y, Right = +X, Left = -X
            dirs.append((.below, -dy))  // below aligns with negative dy
            dirs.append((.above, dy))   // above aligns with positive dy
            dirs.append((.right, dx))   // right aligns with positive dx
            dirs.append((.left, -dx))   // left aligns with negative dx
            dirs.sort { $0.1 > $1.1 }   // highest alignment score first
            return dirs.map(\.0)
        }()

        func originFor(_ dir: Dir) -> NSPoint {
            switch dir {
            case .below:
                return NSPoint(x: cr.midX - pw / 2, y: cr.minY - ph - gap)
            case .above:
                return NSPoint(x: cr.midX - pw / 2, y: cr.maxY + gap)
            case .right:
                return NSPoint(x: cr.maxX + gap, y: cr.midY - ph / 2)
            case .left:
                return NSPoint(x: cr.minX - pw - gap, y: cr.midY - ph / 2)
            }
        }

        func fitsOnScreen(_ origin: NSPoint) -> Bool {
            origin.x >= sf.minX + 4
                && origin.y >= sf.minY + 4
                && origin.x + pw <= sf.maxX - 4
                && origin.y + ph <= sf.maxY - 4
        }

        func overlapsAny(_ origin: NSPoint) -> Bool {
            let rect = NSRect(origin: origin, size: NSSize(width: pw, height: ph))
            // Check against own head circle (with gap)
            let headRect = cr.insetBy(dx: -gap, dy: -gap)
            if rect.intersects(headRect) { return true }
            // Check against all obstacle rects
            for obs in obstacles {
                if rect.intersects(obs.insetBy(dx: -4, dy: -4)) { return true }
            }
            return false
        }

        func clamp(_ origin: NSPoint) -> NSPoint {
            NSPoint(
                x: max(sf.minX + 4, min(origin.x, sf.maxX - pw - 4)),
                y: max(sf.minY + 4, min(origin.y, sf.maxY - ph - 4))
            )
        }

        // Try each direction in priority order
        var bestOrigin: NSPoint?

        for dir in prioritized {
            let origin = clamp(originFor(dir))
            if fitsOnScreen(origin) && !overlapsAny(origin) {
                bestOrigin = origin
                break
            }
        }

        // If no clean placement found, try adjusting horizontal position for vertical placements
        if bestOrigin == nil {
            for dir in prioritized {
                var origin = clamp(originFor(dir))
                if fitsOnScreen(origin) {
                    // Try nudging horizontally to avoid overlaps
                    for nudge in stride(from: 0.0, through: sf.width, by: 50) {
                        var shifted = origin
                        shifted.x = clamp(NSPoint(x: origin.x + nudge, y: origin.y)).x
                        if !overlapsAny(shifted) {
                            bestOrigin = shifted
                            break
                        }
                        shifted.x = clamp(NSPoint(x: origin.x - nudge, y: origin.y)).x
                        if !overlapsAny(shifted) {
                            bestOrigin = shifted
                            break
                        }
                    }
                    if bestOrigin != nil { break }
                }
            }
        }

        // Final fallback: use the toward-center direction, clamped, accept possible overlap
        if bestOrigin == nil {
            bestOrigin = clamp(originFor(prioritized[0]))
        }

        panel.setFrameOrigin(bestOrigin!)
    }
}
