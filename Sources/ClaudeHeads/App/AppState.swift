import Foundation
import SwiftUI

// MARK: - AppState

@Observable
final class AppState {
    var heads: [HeadInstance] = []
    var windowControllers: [UUID: HeadWindowController] = [:]
    var terminalWindowControllers: [UUID: TerminalWindowController] = [:]

    let settings = AppSettings.shared
    let processManager = ProcessManager.shared

    // Service stubs — will be fleshed out in later phases
    // let positionManager = PositionManager()
    // let snapEngine = SnapEngine()
    // let hookWatcher = HookWatcher()

    private static var stateFileURL: URL { Constants.stateFilePath }

    init() {
        restoreHeads()
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
        heads.append(head)

        let controller = HeadWindowController(head: head, appState: self)
        windowControllers[head.id] = controller
        controller.showWindow()

        saveState()
        return head
    }

    func removeHead(id: UUID) {
        // Tear down terminal window if open
        if let termController = terminalWindowControllers.removeValue(forKey: id) {
            termController.close()
        }

        // Tear down head window
        if let controller = windowControllers.removeValue(forKey: id) {
            controller.close()
        }

        // Kill process if running
        if let head = heads.first(where: { $0.id == id }), let pid = head.processID {
            processManager.killProcess(pid: pid)
        }

        heads.removeAll { $0.id == id }
        saveState()
    }

    func focusHead(id: UUID) {
        guard let controller = windowControllers[id] else { return }
        controller.bringToFront()
    }

    func showNewHeadDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project Folder"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.addHead(folderPath: url.path)
            }
        }
    }

    func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleTerminal(for headID: UUID) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }

        if head.isPinned {
            togglePinnedTerminal(for: head)
        } else {
            togglePopoverTerminal(for: head)
        }
    }

    func pinTerminal(for headID: UUID) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }
        head.isPinned = true

        // Close any existing popover-style display handled by HeadWindowController
        windowControllers[headID]?.dismissPopover()

        // Create or show the pinned terminal window
        if terminalWindowControllers[headID] == nil {
            let controller = TerminalWindowController(head: head, appState: self)
            terminalWindowControllers[headID] = controller
        }
        terminalWindowControllers[headID]?.showWindow()
        saveState()
    }

    func unpinTerminal(for headID: UUID) {
        guard let head = heads.first(where: { $0.id == headID }) else { return }
        head.isPinned = false

        if let controller = terminalWindowControllers.removeValue(forKey: headID) {
            controller.close()
        }
        saveState()
    }

    // MARK: - Persistence

    func restoreHeads() {
        guard FileManager.default.fileExists(atPath: Self.stateFileURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.stateFileURL) else { return }
        guard let savedHeads = try? JSONDecoder().decode([HeadInstance].self, from: data) else { return }

        for head in savedHeads {
            // Restore without starting processes; user can start them manually
            head.state = .idle
            head.processID = nil
            heads.append(head)

            let controller = HeadWindowController(head: head, appState: self)
            windowControllers[head.id] = controller
            controller.showWindow()
        }
    }

    func saveState() {
        guard let data = try? JSONEncoder().encode(heads) else { return }
        try? data.write(to: Self.stateFileURL, options: .atomic)
    }

    func shutdown() {
        processManager.killAll()
        saveState()
    }

    // MARK: - Private Helpers

    private func initialPosition(for index: Int) -> CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 100, y: 100) }
        let frame = screen.visibleFrame
        let spacing: CGFloat = settings.headSize.diameter + 10
        let x = frame.maxX - settings.headSize.diameter - 20
        let y = frame.maxY - CGFloat(index) * spacing - settings.headSize.diameter - 20
        return CGPoint(x: x, y: y)
    }

    private func togglePinnedTerminal(for head: HeadInstance) {
        if let controller = terminalWindowControllers[head.id] {
            if controller.isVisible {
                controller.close()
            } else {
                controller.showWindow()
            }
        } else {
            let controller = TerminalWindowController(head: head, appState: self)
            terminalWindowControllers[head.id] = controller
            controller.showWindow()
        }
    }

    private func togglePopoverTerminal(for head: HeadInstance) {
        windowControllers[head.id]?.togglePopover()
    }
}
