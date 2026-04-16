# Claude Heads - Features

## Chat Heads

- Floating circular avatars on the desktop, always rendered above all other windows
- Each head represents a running `claude` CLI process
- Heads display the folder name the claude instance was started in (e.g. "claude-heads", "~")
- Auto-generated background color/gradient derived deterministically from the full folder path
- Customizable avatar image per instance (falls back to a generated default)
- Heads can be dragged anywhere on screen and remember their position across launches
- Multi-monitor aware: heads reposition gracefully when displays are added, removed, or rearranged
- Heads snap together when dragged near each other, forming clusters; drag apart to unsnap
- Badge count or subtle indicator when there is unread output

## Terminal Overlay

- Single-click a head to reveal its terminal output as a popover/tooltip anchored to the head
- Terminal shows the full PTY output of the claude process (ANSI colors, cursor movement)
- Terminal font is configurable in app settings
- Terminal popover can be pinned open so it stays visible while interacting with other apps
- Pinned terminals remain always-on-top alongside their head
- Scrollback buffer for reviewing history
- Keyboard input is forwarded to the claude process when the terminal is focused

## Process Management

- Launch new claude instances from the app (choose directory, optional extra CLI args)
- Settings allow default extra CLI parameters (e.g. `--dangerously-skip-permissions`)
- Per-instance CLI parameter overrides
- Graceful shutdown: sends SIGINT, waits, then SIGKILL if needed
- Automatically removes head when process exits
- Status indicator on head: running (pulsing), idle, finished, errored

## Task Completion Notification

- Integrates with Claude Code's hook system (`post_tool_use` / session lifecycle hooks)
- When a task finishes, the chat head plays a waving-hand animation to attract attention
- Clicking the animated head dismisses the wave and opens the terminal
- Optional system notification in addition to the wave

## Settings

- Global default CLI arguments for new instances
- Avatar image per instance
- Terminal font family and size
- Head size (small / medium / large)
- Snap distance threshold
- Launch at login toggle
- Menu bar icon with quick access to all heads and settings
