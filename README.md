# Claude Heads (AKA a stupid experiment)

A native macOS app that puts floating chat heads on your desktop, one per running Claude Code instance.

Each head shows the folder name it was launched in, with an auto-generated color derived from the path. Click a head to see its terminal output. When a task finishes, the head waves to get your attention.

## Features

- Floating always-on-top chat heads, one per `claude` CLI process
- Terminal popover with full PTY support (click to view, pin to keep open)
- Auto-generated backgrounds from folder paths, customizable avatars
- Magnetic snap: heads stick together when dragged close
- Multi-monitor aware with position memory
- Wave animation on task completion (via Claude Code hooks)
- Configurable terminal font, head size, default CLI arguments
- Menu bar app (no dock icon)

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code CLI (`claude`) installed and on PATH

## Build

```bash
swift build
```

## Run

```bash
swift run ClaudeHeads
```

Or build a release and copy the binary:

```bash
swift build -c release
cp .build/release/ClaudeHeads /usr/local/bin/
```

## Hook Setup

To get wave-on-completion notifications, add a `Stop` hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-heads/hooks/notify.sh"
          }
        ]
      }
    ]
  }
}
```

Claude Code runs the hook with the event JSON on stdin and no arguments. Claude Heads exports `CLAUDE_INSTANCE_ID` (the head's UUID) into each `claude` process it spawns, and `notify.sh` uses that to tell the app which head finished. When `CLAUDE_INSTANCE_ID` is not set (for example, a `claude` session you started yourself in a normal terminal) the script exits silently, so it is safe to leave the hook configured globally.

The app (re)writes `~/.claude-heads/hooks/notify.sh` on every launch, so do not edit it by hand.
