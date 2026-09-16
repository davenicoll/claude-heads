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
    /// Watches ~/.claude-heads/hooks for `.done` markers written by the Claude Code Stop hook.
    let hookWatcher = HookWatcher()

    private var fontObservation: NSKeyValueObservation?

    private static var stateFileURL: URL { Constants.stateFilePath }

    public init() {
        restoreHeads()

        // Wire up screen change notifications
        positionManager.onScreenConfigurationChanged = { [weak self] in
            self?.handleScreenChange()
        }

        // Wire up process exit — show wave animation, then remove after delay
        processManager.onProcessExit = { [weak self] pid, exitCode in
            self?.handleProcessExit(pid: pid, exitCode: exitCode)
        }

        // Make sure every claude child is stopped and state is saved no matter how the app is
        // asked to quit (Cmd-Q, logout, AppleScript, ...), not only via the menu-bar Quit button.
        // shutdown() is idempotent so running it twice on the menu path is harmless.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdown()
        }

        // Wire up PTY activity — mark head as running when output flows
        processManager.onProcessActivity = { [weak self] pid in
            self?.handleProcessActivity(pid: pid)
        }

        // Wire up Claude Code hook events — the Stop hook writes a marker for the head's UUID
        hookWatcher.onTaskComplete = { [weak self] headID in
            self?.handleHookTaskComplete(headID: headID)
        }
        hookWatcher.onSubagentStart = { [weak self] headID, agentID, agentType in
            self?.handleSubagentStart(headID: headID, agentID: agentID, agentType: agentType)
        }
        hookWatcher.onSubagentStop = { [weak self] headID, agentID in
            self?.handleSubagentStop(headID: headID, agentID: agentID)
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

        let pid = processManager.spawnProcess(head: head, terminalView: terminalView, bridge: bridge)
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
        // Cancel any timers that reference this head so nothing fires after removal.
        cancelPendingRemoval(for: id)
        idleTimers.removeValue(forKey: id)?.cancel()
        waveTimers.removeValue(forKey: id)?.cancel()
        runningStartTimes.removeValue(forKey: id)
        hookIdleAt.removeValue(forKey: id)

        // Tear down the windows for real (close + drop the controllers) so the panels,
        // hosting view and SwiftTerm view can deallocate. Panels use
        // isReleasedWhenClosed = false, so dropping our references is what frees them.
        if let termController = terminalControllers.removeValue(forKey: id) {
            termController.tearDown()
        }
        if let controller = headWindowControllers.removeValue(forKey: id) {
            controller.tearDown()
        }
        if let head = heads.first(where: { $0.id == id }), let pid = head.processID {
            processManager.killProcess(pid: pid)
        }
        heads.removeAll { $0.id == id }
        hookedHeads.remove(id)
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
    /// Heads that have received at least one Claude Code hook event. For these, the
    /// output-silence heuristic no longer triggers waves; the hook is authoritative.
    private var hookedHeads: Set<UUID> = []
    /// When each head was last set to idle by a hook event. Claude Code redraws its prompt
    /// right after the Stop hook fires; that output must not flip the head back to .running.
    private var hookIdleAt: [UUID: Date] = [:]
    /// Output arriving within this window after a hook-driven idle is treated as prompt redraw.
    private let hookIdleGrace: TimeInterval = 1.0

    /// Show the wave on a head and auto-dismiss it after `duration` seconds.
    private func triggerWave(for head: HeadInstance, dismissAfter duration: TimeInterval = 2.0) {
        waveTimers[head.id]?.cancel()
        head.isWaving = true
        let dismiss = DispatchWorkItem { [weak self, headID = head.id] in
            head.isWaving = false
            self?.waveTimers.removeValue(forKey: headID)
        }
        waveTimers[head.id] = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    /// Called when the Claude Code Stop hook fires for a head (via HookWatcher).
    private func handleHookTaskComplete(headID: UUID) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }
        hookedHeads.insert(headID)

        // The hook is authoritative: cancel any pending heuristic idle transition.
        idleTimers[headID]?.cancel()
        idleTimers.removeValue(forKey: headID)
        runningStartTimes.removeValue(forKey: headID)

        if head.state == .running {
            head.state = .idle
        }
        hookIdleAt[headID] = Date()
        // The turn is over, so every subagent it spawned is done too (even if a
        // SubagentStop marker was lost).
        if !head.children.isEmpty {
            head.children.removeAll()
        }
        triggerWave(for: head)
    }

    /// Called when the Claude Code SubagentStart hook fires for a head (via HookWatcher).
    private func handleSubagentStart(headID: UUID, agentID: String, agentType: String) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }
        // Deliberately not marking the head as hooked: a user may have configured only the
        // subagent hooks, and the Stop hook alone decides whether the idle heuristic yields.
        guard !head.children.contains(where: { $0.id == agentID }) else { return }
        head.children.append(SubagentInstance(id: agentID, type: agentType))
    }

    /// Called when the Claude Code SubagentStop hook fires for a head (via HookWatcher).
    private func handleSubagentStop(headID: UUID, agentID: String) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }
        head.children.removeAll { $0.id == agentID }
    }

    private func handleProcessActivity(pid: pid_t) {
        guard let head = heads.first(where: { $0.processID == pid }) else { return }

        // If we were waving, cancel — claude is working again. Skipped for hook-driven heads:
        // Claude Code redraws its prompt right after the Stop hook fires, and that output
        // must not cut the wave short; its dismiss timer handles it instead.
        if head.isWaving, !hookedHeads.contains(head.id) {
            head.isWaving = false
            waveTimers[head.id]?.cancel()
            waveTimers.removeValue(forKey: head.id)
        }

        // Ignore the prompt redraw that immediately follows a hook-driven idle so the
        // state indicator does not flicker idle -> running -> idle after every Stop hook.
        let sinceHookIdle = Date().timeIntervalSince(hookIdleAt[head.id] ?? .distantPast)
        if sinceHookIdle <= hookIdleGrace {
            return
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

                // Fallback only: once a head has received a real hook event, the hook
                // decides when to wave and the silence heuristic just tracks idle state.
                if duration >= self.minimumRunningDuration, !self.hookedHeads.contains(headID) {
                    self.triggerWave(for: head)
                }
            }
        }
        idleTimers[head.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Pending "remove this head after the wave" work items, keyed by head ID.
    private var pendingRemovals: [UUID: DispatchWorkItem] = [:]
    /// Delay between a process exiting and its head being removed.
    private let removalDelay: TimeInterval = 10.0

    private func handleProcessExit(pid: pid_t, exitCode: Int32) {
        guard let head = heads.first(where: { $0.processID == pid }) else { return }

        idleTimers.removeValue(forKey: head.id)?.cancel()
        runningStartTimes.removeValue(forKey: head.id)
        // The process is gone; clearing the pid lets a finished head be relaunched.
        head.processID = nil

        // 126/127 mean claude never actually started (chdir or exec failed). Leave the head and
        // its terminal in place, marked errored, so the diagnostic written to the PTY is visible.
        if exitCode == ProcessManager.exitCodeChdirFailed || exitCode == ProcessManager.exitCodeExecFailed {
            head.state = .errored
            return
        }

        // Show finished state with wave animation. Cancel any in-flight wave dismiss so
        // it cannot cut this final wave short.
        waveTimers.removeValue(forKey: head.id)?.cancel()
        head.state = .finished
        head.isWaving = true
        head.children.removeAll()

        // Close the terminal window
        terminalControllers[head.id]?.close()

        // Remove the head after a delay so the user sees the wave. The work item is
        // stored so it can be cancelled if the head is relaunched or removed first.
        let headID = head.id
        cancelPendingRemoval(for: headID)
        let removal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRemovals.removeValue(forKey: headID)
            // Never delete a head that has picked up a new live process in the meantime.
            guard let head = self.heads.first(where: { $0.id == headID }),
                  head.processID == nil else { return }
            self.removeHead(id: headID)
        }
        pendingRemovals[headID] = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay, execute: removal)
    }

    private func cancelPendingRemoval(for headID: UUID) {
        pendingRemovals.removeValue(forKey: headID)?.cancel()
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
            let pid = processManager.spawnProcess(head: head, terminalView: terminalView, bridge: bridge)
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

        // The user is relaunching a finished head; it must not be swept away by the
        // removal scheduled when the previous process exited.
        cancelPendingRemoval(for: headID)
        head.isWaving = false
        waveTimers.removeValue(forKey: headID)?.cancel()

        let pid = processManager.spawnProcess(
            head: head,
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

    /// Synchronously stops every claude process (SIGHUP, ~2s grace, then SIGKILL) and persists
    /// state. Blocks until all children are reaped so it is safe to call before terminating.
    public func shutdown() {
        saveState()
        processManager.killAll(timeout: 2.0)
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
