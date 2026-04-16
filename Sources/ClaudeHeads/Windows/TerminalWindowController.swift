import AppKit
import SwiftTerm
import SwiftUI

// MARK: - TerminalWindowController

/// NSPanel-based controller for a pinned terminal window anchored to a head.
final class TerminalWindowController {
    private let head: HeadInstance
    private weak var appState: AppState?
    private let panel: NSPanel
    private let terminalView: TerminalView
    private let bridge: TerminalBridge

    private static let defaultSize = NSSize(width: 600, height: 400)

    var isVisible: Bool {
        panel.isVisible
    }

    init(head: HeadInstance, appState: AppState) {
        self.head = head
        self.appState = appState

        // Create a terminal view and its PTY bridge via the shared factory
        let (tv, br) = makeTerminalView(
            frame: NSRect(origin: .zero, size: Self.defaultSize)
        )
        self.terminalView = tv
        self.bridge = br

        // Compute panel position anchored below the head
        let settings = AppSettings.shared
        let headDiameter = settings.headSize.diameter
        let panelOrigin = NSPoint(
            x: head.position.x - Self.defaultSize.width / 2 + headDiameter / 2,
            y: head.position.y - Self.defaultSize.height - 10
        )
        let contentRect = NSRect(origin: panelOrigin, size: Self.defaultSize)

        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.title = "Claude \u{2014} \(head.name)"
        panel.minSize = NSSize(width: 320, height: 200)

        // Build the content: toolbar + terminal
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizesSubviews = true

        let toolbar = makeToolbar(width: Self.defaultSize.width)
        toolbar.frame.origin = NSPoint(x: 0, y: Self.defaultSize.height - toolbar.frame.height)
        toolbar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(toolbar)

        let terminalFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.defaultSize.width,
            height: Self.defaultSize.height - toolbar.frame.height
        )
        terminalView.frame = terminalFrame
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        panel.contentView = container
    }

    // MARK: - Window Management

    func showWindow() {
        repositionNearHead()
        panel.orderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: - Process Integration

    /// Spawns a claude process and connects it to this terminal.
    /// Call this after showing the window to start the CLI session.
    func startProcess() {
        guard let appState else { return }
        let pid = appState.processManager.spawnProcess(
            folderPath: head.folderPath,
            extraArgs: head.extraArgs,
            terminalView: terminalView,
            bridge: bridge
        )
        if pid > 0 {
            head.processID = pid
            head.state = .running
        } else {
            head.state = .errored
        }
    }

    // MARK: - Private

    private func repositionNearHead() {
        let settings = AppSettings.shared
        let headDiameter = settings.headSize.diameter
        let x = head.position.x - panel.frame.width / 2 + headDiameter / 2
        let y = head.position.y - panel.frame.height - 10
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makeToolbar(width: CGFloat) -> NSView {
        let height: CGFloat = 28
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor

        let unpinButton = NSButton(frame: NSRect(x: width - 80, y: 2, width: 72, height: 24))
        unpinButton.title = "Unpin"
        unpinButton.bezelStyle = .accessoryBarAction
        unpinButton.target = self
        unpinButton.action = #selector(unpinTapped)
        unpinButton.autoresizingMask = [.minXMargin]
        bar.addSubview(unpinButton)

        let label = NSTextField(labelWithString: head.name)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 8, y: 4, width: width - 90, height: 20)
        label.autoresizingMask = [.width]
        bar.addSubview(label)

        return bar
    }

    @objc private func unpinTapped() {
        appState?.unpinTerminal(for: head.id)
    }
}
