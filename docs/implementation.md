# Claude Heads - Implementation Plan

## Phase 1: Project Skeleton & Floating Heads

**Goal:** Get circular floating heads visible on screen that can be dragged around.

1. Create Swift Package / Xcode project with SwiftUI lifecycle
2. Set up `NSPanel`-based floating window (non-activating, always-on-top, transparent)
3. Implement `HeadView` — circular SwiftUI view with name label and generated background color
4. Implement `PathColorGenerator` — deterministic HSL color from a folder path hash
5. Implement drag-to-reposition via `NSPanel` mouse event handling
6. Persist head positions to disk; restore on launch
7. Multi-monitor awareness: listen for screen config changes, remap positions

## Phase 2: Process Management & Terminal

**Goal:** Each head spawns and manages a real `claude` CLI process with terminal I/O.

1. Add SwiftTerm as a Swift Package dependency
2. Implement `ProcessManager` — forks a PTY, execs `claude` with configurable args and working directory
3. Implement `TerminalEmulator` bridge — feed PTY bytes into SwiftTerm's `Terminal`, expose the terminal view
4. Implement `TerminalPopover` — click a head to show/hide a terminal panel anchored to the head
5. Forward keyboard input from the terminal view back to the PTY
6. Implement pin behavior — toggle that keeps the terminal panel open and floating

## Phase 3: Hook Integration & Wave Animation

**Goal:** Detect task completion and animate the head.

1. Create the hook script that writes a marker file on task completion
2. Implement `HookWatcher` — file system watcher on the markers directory
3. Design the wave animation (hand emoji overlay with spring animation on the head)
4. Wire up: marker detected → head state = `.finished` → wave animation plays
5. Click on waving head → dismiss animation, open terminal

## Phase 4: Snap Behavior

**Goal:** Heads magnetically snap together and move as groups.

1. Implement `SnapEngine` — distance checks during drag, magnetic pull
2. Group management — track which heads are snapped together
3. Group dragging — moving one snapped head moves the cluster
4. Detach gesture — fast flick or drag beyond threshold separates a head

## Phase 5: Settings & Polish

**Goal:** User-facing configuration and app polish.

1. Implement `SettingsView` — terminal font, head size, snap distance, default CLI args, launch at login
2. Implement `NewInstanceView` — directory picker, optional CLI args, optional avatar
3. Custom avatar support — image picker, stored per instance
4. Menu bar icon with dropdown: list of heads, new instance, settings, quit
5. App icon and About window
6. Error handling: process crash recovery, permission prompts for accessibility if needed

## Build & Distribution

- Xcode project, minimum deployment target macOS 14 (Sonoma)
- Code-sign with Developer ID for distribution outside the App Store
- DMG or direct .app distribution via GitHub Releases
