import Foundation
import SwiftTerm
import SwiftUI

// MARK: - AppState

@Observable
public final class AppState {
    public var heads: [HeadInstance] = []
    var headWindowControllers: [UUID: HeadWindowController] = [:]
    var terminalControllers: [UUID: TerminalWindowController] = [:]
    var settingsWindow: NSWindow?

    let settings = AppSettings.shared
    let processManager = ProcessManager.shared
    let positionManager = PositionManager.shared

    private var fontObservation: NSKeyValueObservation?

    private static var stateFileURL: URL { Constants.stateFilePath }

    public init() {
        restoreHeads()

        // Wire up screen change notifications
        positionManager.onScreenConfigurationChanged = { [weak self] in
            self?.handleScreenChange()
        }

        // Wire up process exit — show wave animation, then remove after delay
        processManager.onProcessExit = { [weak self] pid, _ in
            self?.handleProcessExit(pid: pid)
        }

        // Wire up PTY activity — mark head as running when output flows
        processManager.onProcessActivity = { [weak self] pid in
            self?.handleProcessActivity(pid: pid)
        }

        // Wire up font change notifications
        NotificationCenter.default.addObserver(
            forName: .terminalFontChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyFontToAllTerminals()
        }

        // Wire up head size change notifications
        NotificationCenter.default.addObserver(
            forName: .headSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resizeAllHeads()
        }
    }

    // MARK: - Head Management

    @discardableResult
    func addHead(folderPath: String, extraArgs: [String] = []) -> HeadInstance {
        let folderName = (folderPath as NSString).lastPathComponent
        let head = HeadInstance(
            name: folderName,
            folderPath: folderPath,
            extraArgs: extraArgs,
            position: initialPosition(for: heads.count),
            state: .idle
        )

        if let screen = NSScreen.main {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            head.screenID = screen.deviceDescription[key] as? UInt32 ?? 0
        }

        heads.append(head)

        let (terminalView, bridge) = makeTerminalView()
        let termController = TerminalWindowController(head: head, terminalView: terminalView, appState: self)
        termController.bridge = bridge
        terminalControllers[head.id] = termController

        let pid = processManager.spawnProcess(
            folderPath: folderPath,
            extraArgs: extraArgs,
            terminalView: terminalView,
            bridge: bridge
        )
        if pid > 0 {
            head.processID = pid
            head.state = .running
        } else {
            head.state = .errored
        }

        let headController = HeadWindowController(head: head, appState: self)
        headWindowControllers[head.id] = headController
        headController.showWindow()

        saveState()
        return head
    }

    func removeHead(id: UUID) {
        if let termController = terminalControllers.removeValue(forKey: id) {
            termController.close()
        }
        if let controller = headWindowControllers.removeValue(forKey: id) {
            controller.close()
        }
        if let head = heads.first(where: { $0.id == id }), let pid = head.processID {
            processManager.killProcess(pid: pid)
        }
        heads.removeAll { $0.id == id }
        saveState()
    }

    public func focusHead(id: UUID) {
        headWindowControllers[id]?.bringToFront()
    }

    public func showNewHeadDialog() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project Folder"
        panel.title = "Choose a folder for Claude"
        panel.level = .floating

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.addHead(folderPath: url.path)
            }
        }
    }

    public func showSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
        let controller = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: controller)
        window.title = "Claude Heads Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 720))
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    /// Toggle the terminal panel for a head.
    func toggleTerminal(for headID: UUID) {
        NotificationCenter.default.post(name: .headTapped, object: headID)
        guard let controller = terminalControllers[headID] else { return }
        if controller.isVisible {
            controller.close()
        } else {
            controller.showWindow()
        }

        // Dismiss wave if active
        if let head = heads.first(where: { $0.id == headID }), head.isWaving {
            head.isWaving = false
        }
    }

    /// Reposition the terminal window relative to the head's current position
    func repositionTerminal(for headID: UUID) {
        guard let controller = terminalControllers[headID], controller.isVisible else { return }
        let obstacles = obstacleRects(excluding: headID)
        controller.repositionNearHead(avoiding: obstacles)
    }

    /// Returns rects of all heads and visible terminal windows, excluding the given head's own rects.
    func obstacleRects(excluding headID: UUID) -> [NSRect] {
        var rects: [NSRect] = []

        for head in heads where head.id != headID {
            // Add the head circle as an obstacle
            if let tc = terminalControllers[head.id] {
                rects.append(tc.fullHeadRect())
            }
            // Add visible terminal windows as obstacles
            if let tc = terminalControllers[head.id], tc.isVisible {
                rects.append(tc.panelFrame)
            }
        }

        return rects
    }

    /// Resize all head windows to match the current head size setting
    func resizeAllHeads() {
        for (_, controller) in headWindowControllers {
            controller.resizeToFit()
        }
    }

    /// Apply font settings to all open terminals
    func applyFontToAllTerminals() {
        for (_, controller) in terminalControllers {
            controller.applyFont()
        }
    }

    // MARK: - Process State

    /// Idle timers per head
    private var idleTimers: [UUID: DispatchWorkItem] = [:]
    /// Wave dismiss timers
    private var waveTimers: [UUID: DispatchWorkItem] = [:]
    /// When each head entered .running state — used to filter out brief status line blips
    private var runningStartTimes: [UUID: Date] = [:]
    /// Minimum sustained activity duration (seconds) before a wave is shown on idle
    private let minimumRunningDuration: TimeInterval = 5.0

    private func handleProcessActivity(pid: pid_t) {
        guard let head = heads.first(where: { $0.processID == pid }) else { return }

        // If we were waving, cancel — claude is working again
        if head.isWaving {
            head.isWaving = false
            waveTimers[head.id]?.cancel()
            waveTimers.removeValue(forKey: head.id)
        }

        // Track when running started
        if head.state != .running {
            head.state = .running
            runningStartTimes[head.id] = Date()
        }

        // Reset the idle timer — if no output for 2 seconds, claude is idle
        idleTimers[head.id]?.cancel()
        let work = DispatchWorkItem { [weak self, headID = head.id] in
            guard let self, let head = self.heads.first(where: { $0.id == headID }) else { return }
            if head.state == .running {
                head.state = .idle

                // Only wave if claude was running for long enough (real task, not a status blip)
                let start = self.runningStartTimes[headID] ?? Date()
                let duration = Date().timeIntervalSince(start)
                self.runningStartTimes.removeValue(forKey: headID)

                if duration >= self.minimumRunningDuration {
                    head.isWaving = true
                    let dismiss = DispatchWorkItem {
                        head.isWaving = false
                    }
                    self.waveTimers[headID] = dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: dismiss)
                }
            }
        }
        idleTimers[head.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func handleProcessExit(pid: pid_t) {
        guard let head = heads.first(where: { $0.processID == pid }) else { return }

        // Show finished state with wave animation
        head.state = .finished
        head.isWaving = true
        idleTimers[head.id]?.cancel()
        idleTimers.removeValue(forKey: head.id)

        // Close the terminal window
        terminalControllers[head.id]?.close()

        // Remove the head after a delay so the user sees the wave
        let headID = head.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.removeHead(id: headID)
        }
    }

    // MARK: - Screen Changes

    private func handleScreenChange() {
        positionManager.remapPositions(&heads)
        for head in heads {
            headWindowControllers[head.id]?.syncPosition()
        }
        saveState()
    }

    // MARK: - Persistence

    func restoreHeads() {
        guard FileManager.default.fileExists(atPath: Self.stateFileURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.stateFileURL) else { return }
        guard let savedHeads = try? JSONDecoder().decode([HeadInstance].self, from: data) else { return }

        for head in savedHeads {
            head.state = .idle
            head.processID = nil
            heads.append(head)

            let (terminalView, bridge) = makeTerminalView()
            let termController = TerminalWindowController(head: head, terminalView: terminalView, appState: self)
            termController.bridge = bridge
            terminalControllers[head.id] = termController

            // Start the claude process immediately on restore
            let pid = processManager.spawnProcess(
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

            let headController = HeadWindowController(head: head, appState: self)
            headWindowControllers[head.id] = headController
            headController.showWindow()
        }

        positionManager.remapPositions(&heads)
        for head in heads {
            headWindowControllers[head.id]?.syncPosition()
        }
    }

    func ensureProcessRunning(for headID: UUID) {
        guard let head = heads.first(where: { $0.id == headID }),
              head.processID == nil,
              let termController = terminalControllers[headID],
              let bridge = termController.bridge else { return }

        let pid = processManager.spawnProcess(
            folderPath: head.folderPath,
            extraArgs: head.extraArgs,
            terminalView: termController.terminalView,
            bridge: bridge
        )
        if pid > 0 {
            head.processID = pid
            head.state = .running
        } else {
            head.state = .errored
        }
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(heads) else { return }
        let dir = Self.stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.stateFileURL, options: .atomic)
    }

    public func shutdown() {
        processManager.killAll()
        saveState()
    }

    // MARK: - Private Helpers

    private func initialPosition(for index: Int) -> CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 100, y: 100) }
        let frame = screen.visibleFrame
        let diameter = settings.headSize.diameter
        let spacing: CGFloat = diameter + 10

        // Position horizontally centered on screen, just below the menu bar.
        // visibleFrame.maxY is already below the menu bar.
        let x = frame.midX - diameter / 2
        let y = frame.maxY - CGFloat(index) * spacing - diameter - 10
        return CGPoint(x: x, y: y)
    }
}
