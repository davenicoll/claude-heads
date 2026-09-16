# Claude Heads - Implementation Notes

This is a description of how the shipped code is put together, organised by area. It replaces the original phased plan; where a planned item was not built, that is stated.

## Build

- Swift Package Manager only. `Package.swift` declares three targets plus tests:
  - `CPTYHelpers` (C): `pty_set_window_size(fd, rows, cols)` wrapping the `TIOCSWINSZ` ioctl, which is not callable from Swift directly
  - `ClaudeHeadsCore` (library, `Sources/ClaudeHeads`): everything except `@main`
  - `ClaudeHeads` (executable, `Sources/ClaudeHeadsApp`): the `App` struct with the `MenuBarExtra`
  - `ClaudeHeadsCoreTests` (XCTest)
- Minimum deployment target macOS 14. There is no Xcode project, code signing setup, or DMG pipeline.

## Floating Heads

- `HeadWindowController` creates a `DraggablePanel` (borderless, non-activating `NSPanel` at `.floating` level) sized from `HeadGeometry.current.windowSize`.
- `PassthroughHostingView` (an `NSHostingView` subclass) forwards `mouseDown`/`mouseDragged`/`mouseUp` to the panel and accepts first mouse, so the SwiftUI content never swallows events.
- `DraggablePanel` distinguishes click from drag with a 3pt threshold. During a drag it clamps the origin so the circle stays within the screen's `visibleFrame`, calls `onDragMoved` (which moves the terminal along), and on release calls `onDragEnded`.
- `onDragEnded` runs `SnapEngine.snapPosition` against `AppState.heads`, moves the panel if a snap applied, runs `SnapEngine.updateSnapGroups`, records the screen ID, and saves state.
- `HeadGeometry` (in `Constants.swift`) is the single source of the layout numbers: emoji scale 0.52, emoji overhang 0.6, label height 14, label spacing 2. `HeadView`, the panel sizing/clamping, and `TerminalWindowController.fullHeadRect()` all use it.
- `HeadView` draws the gradient (or avatar image), an ASCII face from `HeadFace`/`FaceSequencer` ticked every 2s, an optional status dot, the wave emoji when `isWaving`, and the name label.
- `PathColorGenerator` hashes the folder path with FNV-1a and maps it to an HSL gradient; it exposes both SwiftUI `Color`s and `NSColor`s from the same maths. `AvatarGenerator` uses the `NSColor` variant to render an initials image, but nothing in the app calls it yet.

## Process Management and Terminal

- `ProcessManager.spawnProcess` uses `forkpty()`. The child `chdir`s into the project folder, sets `PATH` to include `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin` and a default nvm path (GUI apps do not inherit the shell PATH), sets `TERM=xterm-256color`, resolves `claude` from those locations, and `execvp`s. With `--continue` enabled it runs `claude --continue ... || claude ...` through `/bin/sh -c`.
- The parent puts the master fd in non-blocking mode and reads it from a `DispatchSourceRead`; bytes are fed to the SwiftTerm `TerminalView` on the main queue and `onProcessActivity(pid)` fires.
- Exits are caught two ways: EOF/error on the PTY, and a `SIGCHLD` dispatch source that reaps with `waitpid(-1, WNOHANG)`. Both funnel into `cleanUp`, which cancels the read source (closing the fd) and fires `onProcessExit` on the main queue.
- `TerminalBridge` implements `TerminalViewDelegate`: writes keystrokes to the master fd, propagates size changes via `pty_set_window_size` + `SIGWINCH`, opens links, copies to the clipboard, beeps on bell.
- `TerminalWindowController` owns a `FloatingTerminalPanel` (titled, closable, resizable, non-activating, `.floating`). `showWindow` ensures the process is running, positions the panel near the head avoiding obstacles, and makes the terminal view first responder. Close hides the panel rather than destroying it.
- Pinning: `windowDidResignKey` closes the panel unless `head.isPinned` or the new key window is another `FloatingTerminalPanel`. A pin/unpin `NSButton` is installed as a trailing `NSTitlebarAccessoryViewController`; toggling it flips `isPinned` and saves state.

## State Machine and Wave

- `AppState.handleProcessActivity`: on output, cancel any wave, set `.running` (recording the start time), and (re)arm a 2s idle timer. When the timer fires the head becomes `.idle`; if it had been running for at least 5s it waves for 2s. This filters out status-line blips.
- `AppState.handleProcessExit`: set `.finished`, wave, close the terminal, and schedule removal after 10s as a per-head `DispatchWorkItem`. `ensureProcessRunning` (relaunch on click) and `removeHead` cancel it, and it re-checks the head still exists with `processID == nil` before removing. `removeHead` cancels all per-head timers and calls `tearDown()` on both window controllers so the panels, controllers and SwiftTerm view deallocate.
- `AppState.hookWatcher` (`HookWatcher`) watches `~/.claude-heads/hooks` for `<uuid>.done` markers written by `notify.sh` from the Claude Code `Stop` hook. `handleHookTaskComplete` cancels the heuristic idle timer, sets `.idle`, and waves; output arriving within a 1s grace window afterwards (Claude's prompt redraw) is ignored so the indicator does not flicker. The same watcher parses `<uuid>.<agent_id>.start`/`.stop` markers from the `SubagentStart`/`SubagentStop` hooks into `onSubagentStart`/`onSubagentStop`, which add and remove `SubagentInstance`s on the head (`children`, not persisted); `handleHookTaskComplete` clears them. Children are tracked even while `AppSettings.showSubagentChildren` is off; that setting only affects rendering and hit-testing.
- `AppState.hookInstaller` (`HookInstaller.shared`) installs those three hooks into `~/.claude/settings.json` in `init` (after `hookWatcher` has written `notify.sh`) and removes them in `shutdown()`, both gated on `AppSettings.manageClaudeHooks`. `HookSettingsMerge.install(into:scriptPath:)` / `uninstall(from:)` are pure `String -> Result<String, Failure>` functions: a byte-range JSON scanner (`Document`/`Scanner`/`Node`) locates the root and `"hooks"` containers, `Style` detects the indent unit and CRLF, `insert` splices the new members at the first item's position with a trailing comma (or replaces the inner whitespace of an empty container), and `removalRange` is its exact inverse. `uninstall` loops one splice at a time, rescanning after each, tracking which groups/events/`hooks` it emptied so pre-existing empty containers are left alone. Both validate by re-parsing and comparing `strippedOfOurHooks(original)` with `strippedOfOurHooks(result)` as `NSDictionary`. `parseObject` also runs the strict scanner because `JSONSerialization` accepts trailing commas that Claude Code does not. `HookInstaller.apply` resolves symlinks, writes `settings.json.claude-heads.bak` once, writes a temp file in the same directory and `rename`s it over the target (keeping POSIX permissions), and publishes `status` (`.installed` / `.missing([events])` / `.failed(reason)`) for the Settings row.

## Persistence

- `HeadInstance` is `Codable`; `AppState.saveState()` writes the array to `~/.claude-heads/state.json`, and `restoreHeads()` reads it back on launch and re-spawns each session. `processID` is runtime-only and not encoded.
- `AppSettings` is a singleton persisted as JSON in `UserDefaults` under `com.claudeheads.appSettings` via the `StoredSettings` DTO; fields added after the first release (`showStatusIndicator`, `showSubagentChildren`, the Claude Code flags) are optional there so older settings still decode, and `load()` fills in the default (`showSubagentChildren` defaults to true). It still carries a `launchAtLogin` flag from an earlier design; nothing reads it and the Settings UI no longer shows it. Launch at login is not implemented.
- `PositionManager` also contains an older `SavedHead` save/load path; only its `remapPositions` and screen-change notification are used.

## Settings and Menu Bar

- `SettingsView` is a SwiftUI `Form` shown in an `NSWindow` at `.floating` level: head size, snap distance, status indicator, "Show children for subagents", the "Install Claude Code hooks while running" toggle with the hook status row and "Reinstall hooks" button (the toggle's `onChange` calls `HookInstaller.install()`/`uninstall()` directly), terminal font/size (posting `.terminalFontChanged` / `.headSizeChanged` / `.subagentChildrenVisibilityChanged` notifications that `AppState` applies live), and the Claude Code flags.
- Subagent orbit geometry lives in `OrbitLayout`, always built from the current `HeadGeometry.diameter`: children are `childScale` (35%) of the parent diameter, so they scale with the head size setting. `OrbitLayout.currentPanelInset` is the extra transparent margin every head panel needs for the ring, or zero while "Show children for subagents" is off; `OrbitingHeadRootView` (SwiftUI padding) and `HeadWindowController` (panel frame, hit-testing) both read it. Changing head size or the toggle posts a notification and `AppState.resizeAllHeads()` calls `resizeToFit()` on every controller, which resizes the panel about its centre and refreshes the cursor rect. `HeadView` passes the orbit view an empty child list while the toggle is off, so nothing is drawn and its `TimelineView` stays paused, and `isHittable` ignores children.
- `ClaudeHeadsApp` is a `MenuBarExtra` with a button per head (bring to front), "New Head..." (Cmd-N, `NSOpenPanel`), "Settings..." (Cmd-,), and "Quit" (Cmd-Q, which calls `AppState.shutdown()` first).
- `AppDelegate` sets the `.accessory` activation policy (no Dock icon) and creates `~/.claude-heads/hooks`.

## Not built

- Group dragging / detach gesture (`SnapEngine.moveGroup` exists, unused)
- Launch at login, system notifications, badge counts
- Custom avatar picker (the former `NewInstanceView` dialog was removed in favour of the folder picker)
- Xcode project, signing, distribution packaging
