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
    │   ├── AppDelegate.swift          # Accessory activation policy, creates ~/.claude-heads dirs
    │   └── AppState.swift             # Owns heads + window controllers, spawns processes, saves/restores state
    ├── Models/
    │   ├── HeadInstance.swift         # @Observable head model (position, screenID, isPinned, snapGroupID, state...)
    │   └── AppSettings.swift          # Settings singleton (font, head size, snap distance, subagent children, CLI flags)
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
    │   └── HookWatcher.swift          # Watches ~/.claude-heads/hooks for <uuid>.done and <uuid>.<agent>.start/.stop markers
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
3. `ProcessManager.spawnProcess` does all the Swift work in the parent: it builds the child environment (`PATH`, `TERM`, `CLAUDE_INSTANCE_ID`), resolves the `claude` binary on that `PATH`, and builds argv via `buildArguments` from `AppSettings.effectiveCLIArgs` (split shell-style by `ShellWords`) plus per-head extra args, dropping `--continue` when `hasResumableSession` finds no `~/.claude/projects/<sanitized-folder>/*.jsonl`. It then calls `forkpty()`; the child branch only uses async-signal-safe calls (`chdir`, `execve`, `write`, `_exit`) and exits 127 if `execve` fails.
4. In the parent, a `DispatchSourceRead` on the PTY master feeds bytes to `TerminalView.feed` on the main queue and fires `onProcessActivity`.
5. `AppState` maps activity to head state: any output marks the head `.running`; 2s of silence marks it `.idle`. If the running stretch lasted at least 5s, the head waves for 2s.
6. Child exit is detected by EOF on the PTY master; the read source then closes the fd and reaps the child with `waitpid` on the session queue (exit code, or 128 + signal). The head becomes `.finished`, waves, its terminal closes, and the head is removed 10s later. The removal is a cancellable work item: clicking the head (which relaunches `claude`) or removing it explicitly cancels it, and it re-checks that the head still exists with no live process before removing. Removal tears down both panels so the controllers and the SwiftTerm view deallocate.
7. On quit, `AppState.shutdown()` saves state and calls `ProcessManager.killAll`, which sends `SIGHUP` to every child process group, waits up to 2s, then `SIGKILL`s and reaps the rest before the app terminates. `killProcess` (used when a head is removed while the app is running) sends `SIGHUP` and escalates to `SIGKILL` after 2s.
8. On launch, `AppState.restoreHeads()` reads `state.json` and re-spawns `claude` for every saved head.

## Hook Integration

`HookWatcher` is a file-system watcher (`DispatchSource.makeFileSystemObjectSource`) on `~/.claude-heads/hooks` that looks for `<uuid>.done` marker files, deletes them and calls `onTaskComplete(uuid)`. It also parses `<uuid>.<agent_id>.start` (contents: `agent_type`) and `<uuid>.<agent_id>.stop` markers from the `SubagentStart`/`SubagentStop` hooks into `onSubagentStart`/`onSubagentStop`, which `AppState` uses to maintain each head's orbiting `children`; a Stop event clears them. It is the single source of truth for `notify.sh`, which it rewrites on every launch; the script reads `CLAUDE_INSTANCE_ID` (exported into each spawned `claude`) and touches the marker. `AppState` owns the watcher and routes `onTaskComplete` to `handleHookTaskComplete`, which is authoritative over the PTY-activity heuristic (see Process Lifecycle). Without the hook configured, the wave still fires from PTY idle detection. See the Hook Setup section of the README for configuration. `OrbitLayout` derives the ring from the current head diameter (children are 35% of it), and the "Show children for subagents" setting (`AppSettings.showSubagentChildren`) hides the ring and shrinks the head panel without affecting tracking.

## Position Management

- Each head stores `position` (window origin in screen coordinates) and `screenID` (`NSScreen.deviceDescription["NSScreenNumber"]`).
- During a drag, `DraggablePanel` clamps the origin so the full head window (circle, emoji overhang and label, but not the transparent orbit inset) stays inside the screen's `visibleFrame`, using `HeadGeometry.clampWindowOrigin`.
- On `NSApplication.didChangeScreenParametersNotification`, `PositionManager.remapPositions` moves heads whose screen vanished to the closest remaining screen and clamps every head window to its screen's visible frame with the same `HeadGeometry` rule, so a head that was legal after a drag is not moved again.
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
