# Claude Heads - Architecture

## Overview

Claude Heads is a native macOS application built with Swift, SwiftUI and AppKit. It manages floating overlay windows (chat heads) that each wrap a `claude` CLI process the app spawned in a pseudo-terminal. Heads exist only for sessions launched from the app; there is no discovery of externally started `claude` processes.

## Technology Stack

- **Language:** Swift (Swift tools 5.10, builds with the Swift 6 toolchain)
- **UI Framework:** SwiftUI for view content, AppKit `NSPanel` for the floating windows, `MenuBarExtra` for the menu bar item
- **Terminal Emulation:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (Swift Package dependency)
- **Process Management:** POSIX `forkpty()` + `execvp()` (no `Foundation.Process`); a tiny C target (`CPTYHelpers`) wraps the `TIOCSWINSZ` ioctl
- **Persistence:** `UserDefaults` (JSON-encoded `AppSettings`) for settings; `~/.claude-heads/state.json` for head state
- **Build System:** Swift Package Manager only (`Package.swift`); there is no Xcode project

## Package Layout

```
Package.swift
Sources/
├── CPTYHelpers/                       # C: pty_set_window_size() ioctl wrapper
├── ClaudeHeadsApp/
│   └── ClaudeHeadsApp.swift           # @main App: MenuBarExtra (heads list, New Head, Settings, Quit)
└── ClaudeHeads/                       # ClaudeHeadsCore library
    ├── App/
    │   ├── AppDelegate.swift          # Accessory activation policy, creates ~/.claude-heads dirs, writes hooks/notify.sh
    │   └── AppState.swift             # Owns heads + window controllers, spawns processes, saves/restores state
    ├── Models/
    │   ├── HeadInstance.swift         # @Observable head model (position, screenID, isPinned, snapGroupID, state...)
    │   └── AppSettings.swift          # Settings singleton (font, head size, snap distance, CLI flags)
    ├── Views/
    │   ├── HeadView.swift             # Circular head: gradient/avatar, ASCII face, wave emoji, name label
    │   └── SettingsView.swift         # Settings form
    ├── Windows/
    │   ├── HeadWindowController.swift # DraggablePanel (non-activating NSPanel), drag, clamp, snap
    │   └── TerminalWindowController.swift # Floating NSPanel hosting the SwiftTerm view; pin button; placement
    ├── Services/
    │   ├── ProcessManager.swift       # forkpty/execvp claude, PTY read loop, SIGCHLD reaping, kill
    │   ├── TerminalEmulator.swift     # TerminalBridge: TerminalViewDelegate -> PTY writes, SIGWINCH
    │   ├── PositionManager.swift      # Screen-change notifications, remap/clamp positions
    │   ├── SnapEngine.swift           # Pure snap maths: snapPosition, updateSnapGroups, moveGroup
    │   └── HookWatcher.swift          # Watches ~/.claude-heads/hooks for <uuid>.done markers
    ├── Utilities/
    │   ├── Constants.swift            # Paths, notification names, HeadGeometry (shared head layout metrics)
    │   ├── HeadFace.swift             # ASCII faces + FaceSequencer state machine
    │   ├── PathColorGenerator.swift   # FNV-1a hash -> HSL gradient (SwiftUI + NSColor variants)
    │   └── AvatarGenerator.swift      # Draws an initials-on-gradient NSImage (not currently called by the app)
    └── Resources/                     # AppIcon.icns/.png, Assets.xcassets
Tests/ClaudeHeadsCoreTests/            # XCTest: SnapEngine, PathColorGenerator, HeadGeometry, Codable models
```

## Window Architecture

Each chat head is a `DraggablePanel` (`NSPanel` subclass) configured as:
- `[.borderless, .nonactivatingPanel]` — never steals focus; `canBecomeKey`/`canBecomeMain` return `false`
- `level: .floating`, `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- Transparent, shadowless, hosting `HeadView` in a `PassthroughHostingView` that forwards mouse events to the panel so clicks and drags are handled in AppKit rather than SwiftUI gestures

The head panel's size comes from `HeadGeometry` (circle diameter + wave-emoji overhang + 14pt name label). `HeadView`, `HeadWindowController` (sizing and drag clamping) and `TerminalWindowController.fullHeadRect()` all read the same struct.

Each head also owns a `FloatingTerminalPanel` (`NSPanel`, `[.titled, .closable, .resizable, .nonactivatingPanel]`, `level: .floating`) containing a SwiftTerm `TerminalView`. It is created when the head is created, hidden by default, and shown/hidden with `orderFront`/`orderOut` rather than being destroyed, so the scrollback survives toggling. Its title bar has a pin button (`NSTitlebarAccessoryViewController`).

## Process Lifecycle

1. The user picks "New Head..." in the menu bar; `AppState.showNewHeadDialog()` shows an `NSOpenPanel` for a folder.
2. `AppState.addHead` creates a `HeadInstance`, a `TerminalView` + `TerminalBridge`, and a `TerminalWindowController`, then calls `ProcessManager.spawnProcess`.
3. `ProcessManager` calls `forkpty()`. In the child it `chdir`s to the folder, sets `PATH`/`TERM`, resolves the `claude` binary from a few well-known locations, and `execvp`s it with the flags from `AppSettings.effectiveCLIArgs` plus per-head extra args. If `--continue` is enabled it runs `claude --continue ... || claude ...` via `/bin/sh` so a missing session falls back to a fresh one.
4. In the parent, a `DispatchSourceRead` on the PTY master feeds bytes to `TerminalView.feed` on the main queue and fires `onProcessActivity`.
5. `AppState` maps activity to head state: any output marks the head `.running`; 2s of silence marks it `.idle`. If the running stretch lasted at least 5s, the head waves for 2s.
6. Child exit is detected by EOF on the PTY or a `SIGCHLD` dispatch source (children are reaped with `waitpid`). The head becomes `.finished`, waves, its terminal closes, and the head is removed 10s later.
7. On quit, `AppState.shutdown()` saves state and sends `SIGINT` to every child, escalating to `SIGKILL` after 3s.
8. On launch, `AppState.restoreHeads()` reads `state.json` and re-spawns `claude` for every saved head.

## Hook Integration

`HookWatcher` is a file-system watcher (`DispatchSource.makeFileSystemObjectSource`) on `~/.claude-heads/hooks` that looks for `<uuid>.done` marker files, deletes them and calls `onTaskComplete(uuid)`. It also writes a `notify.sh` that touches such a marker. `AppDelegate` separately writes a `notify.sh` that appends to `events.log`. In the current code nothing instantiates `HookWatcher` and nothing consumes `onTaskComplete`; the wave animation is driven entirely by PTY activity (see Process Lifecycle). See the Hook Setup section of the README for the user-facing status.

## Position Management

- Each head stores `position` (window origin in screen coordinates) and `screenID` (`NSScreen.deviceDescription["NSScreenNumber"]`).
- During a drag, `DraggablePanel` clamps the origin so the circle itself (not the emoji padding or label) stays inside the screen's `visibleFrame`.
- On `NSApplication.didChangeScreenParametersNotification`, `PositionManager.remapPositions` moves heads whose screen vanished to the closest remaining screen and clamps every position to its screen's visible frame.
- State (including positions, pin state and snap groups) is written to `~/.claude-heads/state.json` by `AppState.saveState()` after every drag, pin toggle, add or remove.

## Snap Behaviour

`SnapEngine` is a pure value type with no AppKit dependencies; `HeadWindowController` calls it when a drag ends:
- `snapPosition` compares the dropped origin against every other head. If an edge (left/right/above/below) or centre axis of another head is within `AppSettings.snapDistance` (default 60pt), the corresponding axis snaps to it. Because all head windows share the same geometry, origins `diameter` apart put the circles exactly edge-to-edge.
- The controller refuses a snap that would land exactly on top of another head.
- `updateSnapGroups` then recomputes `snapGroupID` for all heads: touching heads (connected components) share a UUID, isolated heads get `nil`.
- `moveGroup` exists and is tested but is not wired to dragging: dragging a head moves only that head. Dragging a head away from its neighbours simply dissolves the group on the next `updateSnapGroups`.

## Terminal Placement and Pinning

`TerminalWindowController.repositionNearHead` places the terminal like a tooltip: it tries below/above/right/left of the head in order of which direction points toward the screen centre, rejecting candidates that overlap other heads or visible terminals (`AppState.obstacleRects`), then nudges horizontally, then falls back to a clamped position. The terminal is re-placed continuously while its head is dragged.

Clicking a head toggles its terminal. When the terminal panel resigns key (the user clicks another window or app) it closes unless `HeadInstance.isPinned` is `true`. The pin button in the title bar toggles `isPinned` and persists it.

## Data Flow

```
Menu bar "New Head..." ──▶ NSOpenPanel ──▶ AppState.addHead
                                              │
                    ┌─────────────────────────┼──────────────────────────┐
                    ▼                         ▼                          ▼
        HeadWindowController      TerminalWindowController         ProcessManager
        (DraggablePanel)          (FloatingTerminalPanel)          forkpty/execvp claude
             │                          │                                │
             │ click ──▶ toggleTerminal │                                │ PTY bytes
             │ drag  ──▶ SnapEngine     │ TerminalView ◀── feed ─────────┤
             │           saveState      │ TerminalBridge ── write ───────┘
             ▼                          ▼                                │
          HeadView                 pin button                onProcessActivity / onProcessExit
   (face, wave, gradient)        (isPinned)                             │
             ▲                                                          ▼
             └──────────────── HeadInstance.state / isWaving ◀── AppState idle timers
```
