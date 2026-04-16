# Claude Heads - Architecture

## Overview

Claude Heads is a native macOS application built with Swift and SwiftUI. It manages floating overlay windows (chat heads) that each wrap a `claude` CLI process running in a pseudo-terminal.

## Technology Stack

- **Language:** Swift 6
- **UI Framework:** SwiftUI + AppKit (NSWindow/NSPanel for overlay windows)
- **Terminal Emulation:** SwiftTerm (embedded as Swift Package dependency)
- **Process Management:** POSIX `forkpty()` / `Foundation.Process` with PTY
- **Persistence:** UserDefaults + Codable for settings; JSON file for instance state
- **Build System:** Xcode project via Swift Package Manager

## Application Structure

```
ClaudeHeads/
├── App/
│   ├── ClaudeHeadsApp.swift          # App entry point, menu bar setup
│   └── AppDelegate.swift             # NSApplicationDelegate for lifecycle
├── Models/
│   ├── HeadInstance.swift            # Data model for a single claude head
│   ├── HeadPosition.swift            # Position + monitor identity
│   └── AppSettings.swift             # Global settings model
├── Views/
│   ├── HeadView.swift                # The circular floating head (SwiftUI)
│   ├── TerminalPopover.swift         # Terminal overlay view
│   ├── SettingsView.swift            # Settings window
│   └── NewInstanceView.swift         # Dialog to launch a new instance
├── Windows/
│   ├── HeadWindowController.swift    # NSPanel wrapper for a single head
│   └── TerminalWindowController.swift# NSPanel for pinned terminal
├── Services/
│   ├── ProcessManager.swift          # Spawns and manages claude PTY processes
│   ├── TerminalEmulator.swift        # SwiftTerm integration bridge
│   ├── HookWatcher.swift             # Monitors claude hook events for task completion
│   ├── PositionManager.swift         # Persists/restores head positions, monitor awareness
│   └── SnapEngine.swift              # Magnetic snap logic between heads
├── Utilities/
│   ├── PathColorGenerator.swift      # Deterministic color from folder path
│   ├── AvatarGenerator.swift         # Default avatar generation
│   └── Constants.swift               # App-wide constants
└── Resources/
    └── Assets.xcassets                # App icon, default avatars
```

## Window Architecture

Each chat head is an `NSPanel` configured as:
- `.nonactivatingPanel` style — does not steal focus from other apps
- `level: .floating` — renders above normal windows
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]` — visible on all Spaces
- Transparent background with a circular SwiftUI view as content

Terminal popovers are separate `NSPanel` instances anchored to their head's position. When pinned, they adopt the same floating level.

## Process Lifecycle

1. User clicks "New Head" (menu bar or context menu)
2. `ProcessManager` calls `forkpty()` to create a PTY, then `execvp("claude", args)` in the child
3. Parent reads PTY output on a background thread, feeding bytes to `SwiftTerm.Terminal`
4. `HookWatcher` monitors for task-completion signals (file-based or exit-code based)
5. On task completion, the head's state transitions to `.finished` and the wave animation triggers
6. On process exit, the head shows a "done" state; user can dismiss or restart

## Hook Integration

Claude Code supports hooks via `~/.claude/settings.json`. The app installs a hook script that writes a completion marker to a known path:

```
~/.claude-heads/hooks/<instance-id>.done
```

`HookWatcher` uses `DispatchSource.makeFileSystemObjectSource` to watch this directory for new files, mapping them back to head instances.

## Position Management

- Each head stores its position as `(x, y, screenID)` where `screenID` is the `NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`
- On screen configuration change (`NSApplication.didChangeScreenParametersNotification`), `PositionManager` remaps heads: if a head's screen disappeared, it migrates to the nearest available screen edge
- Positions persist to `~/.claude-heads/state.json`

## Snap Behavior

`SnapEngine` runs during drag operations:
- Computes distance between the dragged head and all other heads
- If distance < threshold (default 60pt), applies a magnetic pull toward the nearest snap point
- Snapped heads form a group; dragging any head in the group moves all of them
- Dragging with velocity > threshold detaches a head from its group

## Data Flow

```
User Interaction
       │
       ▼
   HeadView (SwiftUI)
       │
       ├──▶ HeadWindowController (position, drag, snap)
       │         │
       │         ▼
       │    PositionManager / SnapEngine
       │
       ├──▶ TerminalPopover (show/hide/pin)
       │         │
       │         ▼
       │    TerminalEmulator (SwiftTerm)
       │         │
       │         ▼
       │    ProcessManager (PTY read/write)
       │
       └──▶ HookWatcher (task completion → wave animation)
```
