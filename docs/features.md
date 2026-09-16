# Claude Heads - Features

This describes what the app does today. Anything not listed here is not implemented.

## Chat Heads

- Floating circular heads on the desktop, rendered above other windows on every Space (including alongside full-screen apps)
- One head per `claude` CLI process spawned by the app; the app does not discover `claude` processes started elsewhere
- Each head shows the name of the folder the session was started in
- Background is a gradient derived deterministically from the full folder path; if `avatarImageData` is present in `state.json` it is drawn instead (there is currently no UI for choosing an avatar)
- An ASCII face on the head cycles through expressions that follow the session's state (working, idle, finished, errored)
- Optional coloured status dot (green idle, blue running, orange finished, red errored), off by default
- Heads can be dragged anywhere; the head (circle and name label) is kept on screen and the position is remembered across launches
- Multi-monitor aware: when displays change, heads on a vanished screen move to the closest remaining screen and every head is clamped fully inside its screen's visible frame
- Magnetic snap: when a drag ends within the snap distance of another head's edge or centre line, the head snaps edge-to-edge. Touching heads are recorded as a snap group. Dragging moves a single head only (groups do not move together)

## Terminal

- Click a head to toggle a floating terminal window attached to the session's pseudo-terminal
- Full terminal emulation via SwiftTerm (ANSI colours, cursor movement, scrollback); resizing the window resizes the PTY
- Keyboard input in the terminal goes to the `claude` process; links open in the browser; copy goes to the clipboard
- The terminal opens next to its head, toward the screen centre, avoiding other heads and open terminals, and follows the head while it is dragged
- Pin button in the terminal title bar: a pinned terminal stays open when you click elsewhere; an unpinned terminal closes when focus moves to another app or a non-terminal window (switching between head terminals keeps both open). Pin state is persisted per head

## Process Management

- Launch a new session from the menu bar ("New Head...", Cmd-N): choose a folder, and `claude` starts in it
- Global Claude Code flags in Settings: `--continue` (with automatic fallback to a fresh session if none exists), `--dangerously-skip-permissions`, `--remote-control`, plus free-form extra arguments (split shell-style: quote arguments that contain spaces, backslash escapes); all are applied to every new session
- Sessions persist: on relaunch the app re-spawns `claude` for every saved head
- Shutdown: on quit, `shutdown()` saves state and calls `killAll`, which sends `SIGHUP` to every child process group, waits up to 2s, then `SIGKILL`s and reaps whatever is left before the app terminates. Removing a head while the app is running uses `killProcess` (`SIGHUP`, then `SIGKILL` after 2s)
- When a process exits the head shows a finished state, waves, closes its terminal and disappears after 10 seconds. Clicking the head before then relaunches `claude` and cancels the removal

## Wave Animation

- The head waves when Claude goes quiet after at least 5 seconds of continuous output (a task finishing), and when the process exits
- Clicking the waving head dismisses the wave and opens the terminal
- With the Claude Code `Stop` hook configured, `HookWatcher` picks up the `<uuid>.done` marker and the head goes idle and waves immediately, overriding the output-idle heuristic. The app installs that hook (and the two subagent hooks below) into `~/.claude/settings.json` itself on launch and removes them on quit; see Hooks
- With the `SubagentStart`/`SubagentStop` hooks configured, `HookWatcher` also picks up `<uuid>.<agent_id>.start`/`.stop` markers and each running subagent is drawn as a small head orbiting its parent (35% of the parent head's diameter, so it follows the head size setting; coloured by agent type)
- Hovering a child shows its label: the task description from the Agent call (trimmed, cut to 24 characters with an ellipsis) when known, else the agent type, else the first 8 characters of the agent id. The tooltip adds the untruncated description and the full type when they differ. `SubagentStart` only carries `agent_type` (sometimes the agent's name, sometimes empty), so descriptions arrive from the `background_tasks` list in later `SubagentStop`/`Stop` payloads and children are relabelled live; running subagents in that list that were never seen starting (e.g. started before the app launched) are added
- Children persist across turns while their agent runs: a child leaves on its own `SubagentStop`, or when the parent's `Stop` payload lists `background_tasks` without it running. A `Stop` without that list removes nothing; the process exiting clears them all
- "Show children for subagents" (Settings, on by default) hides the orbit: the ring is not drawn or animated, the head panel shrinks back to the plain head, and only the parent head is clickable. Subagents are still tracked while hidden, so turning it back on shows the ones currently running

## Hooks

- `HookInstaller` adds `Stop`, `SubagentStart` and `SubagentStop` entries running `~/.claude-heads/hooks/notify.sh` (absolute path) to the global `~/.claude/settings.json` at launch and removes exactly those entries on quit. This is automatic and has no setting; "Show children for subagents" only affects display (children are tracked while hidden, so the subagent hooks stay installed)
- The edit is a minimal splice: everything outside the inserted entries is preserved byte-for-byte (key order, indentation, line endings). Removal deletes only our command entries; a matcher group holding only our command is removed whole, and an event array or `hooks` object that becomes empty is removed with its key. Other hooks and settings are never touched
- A one-time backup is written to `~/.claude-heads/settings.json.claude-heads.bak` before the first modification (kept out of `~/.claude` so it stays out of dotfiles repositories); writes are atomic (0600 temp file + rename) and follow symlinks; a dangling symlink is reported, never replaced; a missing or empty file is created with just the hooks block. `CLAUDE_CONFIG_DIR` is honoured
- Two running instances share the file: quitting one removes the hooks the other needs for heads started afterwards
- Invalid JSON, a non-object `hooks`, or a result that would not parse or would change anything else means nothing is written and Settings shows "Could not update settings.json: <reason>"
- Hooks apply to `claude` sessions started after the write, so the app's own (freshly spawned) heads always see them. After a crash the entries remain harmlessly (`notify.sh` exits 0 without `CLAUDE_INSTANCE_ID`) and the next launch is idempotent
- Settings shows the state ("Installed", "Missing: ...", or the error) and a "Reinstall hooks" button that replaces stale `notify.sh` entries with fresh ones

## Settings

- Head size (small / medium / large), applied live
- Snap distance (20-120pt)
- Show/hide status indicator
- Show/hide children for subagents (the orbit ring), applied live
- Claude Code hook status and "Reinstall hooks" (the hooks themselves are always installed while the app runs)
- The window is a fixed 480pt wide and sizes its height to the form, so every row is visible without scrolling
- Terminal font family (monospace fonts only) and size, applied live to open terminals
- Claude Code flags and extra arguments
- Menu bar icon lists all heads (click to bring one to the front), New Head, Settings, Quit; the app has no Dock icon

## Not implemented

- Launch at login
- System notifications or badge counts
- Custom avatar picker
- Group dragging of snapped heads
- Discovery of externally launched `claude` processes
