import AppKit
import Foundation

// MARK: - SavedHead

/// Lightweight struct representing a persisted head's spatial state.
struct SavedHead: Codable {
    let id: UUID
    let name: String
    let folderPath: String
    let extraArgs: [String]
    let avatarImageData: Data?
    let position: CGPoint
    let screenID: UInt32
    let isPinned: Bool
    let snapGroupID: UUID?
}

// MARK: - PositionManager

/// Persists head positions to disk and remaps them when the display configuration changes.
final class PositionManager {
    static let shared = PositionManager()

    private let stateFileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateFileURL = home
            .appendingPathComponent(".claude-heads")
            .appendingPathComponent("state.json")

        subscribeToScreenChanges()
    }

    // MARK: - Save

    /// Serializes the current head positions to `~/.claude-heads/state.json`.
    func savePositions(_ heads: [HeadInstance]) {
        let saved = heads.map { head in
            SavedHead(
                id: head.id,
                name: head.name,
                folderPath: head.folderPath,
                extraArgs: head.extraArgs,
                avatarImageData: head.avatarImageData,
                position: head.position,
                screenID: head.screenID,
                isPinned: head.isPinned,
                snapGroupID: head.snapGroupID
            )
        }

        do {
            let dir = stateFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(saved)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            NSLog("[PositionManager] Failed to save positions: \(error)")
        }
    }

    // MARK: - Load

    /// Loads persisted head positions from disk.
    func loadPositions() -> [SavedHead] {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: stateFileURL)
            return try JSONDecoder().decode([SavedHead].self, from: data)
        } catch {
            NSLog("[PositionManager] Failed to load positions: \(error)")
            return []
        }
    }

    // MARK: - Remap

    /// Remaps head positions after a display configuration change. If a head's screen is no
    /// longer available, it is moved to the nearest edge of the closest remaining screen.
    /// All positions are clamped to be within screen visible frames.
    func remapPositions(_ heads: inout [HeadInstance]) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let screenIDs = Set(screens.compactMap { screen -> UInt32? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return screen.deviceDescription[key] as? UInt32
        })

        for head in heads {
            if !screenIDs.contains(head.screenID) {
                // Screen is gone -- find the closest screen
                let closestScreen = closestScreen(to: head.position, screens: screens)
                let frame = closestScreen.visibleFrame

                head.screenID = screenIDForScreen(closestScreen)
                head.position = clampPosition(head.position, to: frame)
            } else {
                // Screen still exists -- just clamp to its current visible frame
                if let screen = screenForID(head.screenID, screens: screens) {
                    head.position = clampPosition(head.position, to: screen.visibleFrame)
                }
            }
        }
    }

    // MARK: - Screen Change Notification

    private var screenChangeObserver: NSObjectProtocol?

    /// Called when the user needs to handle screen changes. Set this to trigger a remap.
    var onScreenConfigurationChanged: (() -> Void)?

    private func subscribeToScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenConfigurationChanged?()
        }
    }

    // MARK: - Helpers

    /// Returns the screen closest to the given point.
    private func closestScreen(to point: CGPoint, screens: [NSScreen]) -> NSScreen {
        var bestScreen = screens[0]
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for screen in screens {
            let frame = screen.visibleFrame
            let clampedX = max(frame.minX, min(point.x, frame.maxX))
            let clampedY = max(frame.minY, min(point.y, frame.maxY))
            let dx = point.x - clampedX
            let dy = point.y - clampedY
            let distance = dx * dx + dy * dy

            if distance < bestDistance {
                bestDistance = distance
                bestScreen = screen
            }
        }

        return bestScreen
    }

    /// Clamps a point to be within the given rectangle.
    private func clampPosition(_ point: CGPoint, to rect: NSRect) -> CGPoint {
        CGPoint(
            x: max(rect.minX, min(point.x, rect.maxX)),
            y: max(rect.minY, min(point.y, rect.maxY))
        )
    }

    /// Extracts the display ID from an NSScreen.
    private func screenIDForScreen(_ screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? UInt32 ?? 0
    }

    /// Finds an NSScreen matching the given display ID.
    private func screenForID(_ id: UInt32, screens: [NSScreen]) -> NSScreen? {
        screens.first { screen in
            screenIDForScreen(screen) == id
        }
    }
}
