# Claude Heads - Features

This describes what the app does today. Anything not listed here is not implemented.

## Chat Heads

- Floating circular heads on the desktop, rendered above other windows on every Space (including alongside full-screen apps)
- One head per `claude` CLI process spawned by the app; the app does not discover `claude` processes started elsewhere
- Each head shows the name of the folder the session was started in
- Background is a gradient derived deterministically from the full folder path; if `avatarImageData` is present in `state.json` it is drawn instead (there is currently no UI for choosing an avatar)
- An ASCII face on the head cycles through expressions that follow the session's state (working, idle, finished, errored)
- Optional coloured status dot (green idle, blue running, orange finished, red errored), off by default
- Heads can be dragged anywhere; the circle is kept on screen and the position is remembered across launches
- Multi-monitor aware: when displays change, heads on a vanished screen move to the closest remaining screen and all heads are clamped to visible frames
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
- When a process exits the head shows a finished state, waves, closes its terminal and disappears after 10 seconds

## Wave Animation

- The head waves when Claude goes quiet after at least 5 seconds of continuous output (a task finishing), and when the process exits
- Clicking the waving head dismisses the wave and opens the terminal
- With the Claude Code `Stop` hook configured (see the README Hook Setup section), `HookWatcher` picks up the `<uuid>.done` marker and the head goes idle and waves immediately, overriding the output-idle heuristic
- With the `SubagentStart`/`SubagentStop` hooks configured, `HookWatcher` also picks up `<uuid>.<agent_id>.start`/`.stop` markers and each running subagent is drawn as a small head orbiting its parent (coloured by agent type, hover for the type); they disappear when the subagent stops or the parent's Stop fires

## Settings

- Head size (small / medium / large), applied live
- Snap distance (20-120pt)
- Show/hide status indicator
- Terminal font family (monospace fonts only) and size, applied live to open terminals
- Claude Code flags and extra arguments
- Menu bar icon lists all heads (click to bring one to the front), New Head, Settings, Quit; the app has no Dock icon

## Not implemented

- Launch at login
- System notifications or badge counts
- Custom avatar picker
- Group dragging of snapped heads
- Discovery of externally launched `claude` processes
