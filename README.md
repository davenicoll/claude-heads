# Claude Heads (AKA a stupid experiment)

A native macOS app that puts floating chat heads on your desktop, one per Claude Code session you launch from the app.

Pick a project folder from the menu bar and Claude Heads spawns `claude` in that folder inside a pseudo-terminal, then shows a head for it. Each head shows the folder name, with an auto-generated color derived from the path. Click a head to see its terminal. When Claude goes quiet after a stretch of work, the head waves to get your attention.

Heads are only created for sessions started from the app; it does not discover `claude` processes launched elsewhere (e.g. from your own terminal).

## Features

- Floating always-on-top chat heads, one per `claude` CLI process spawned by the app
- Click a head to open a floating terminal (SwiftTerm) attached to the session's PTY; keyboard input goes straight to `claude`
- Pin a terminal from its title bar to keep it open when you click away; unpinned terminals close when focus moves to another app or a non-terminal window (switching between head terminals keeps them open)
- Auto-generated gradient backgrounds derived from the folder path
- Magnetic snap: drop a head near another and it snaps edge-to-edge
- Multi-monitor aware with position memory across launches
- Wave animation when Claude goes idle after working
- Subagent orbit: with the `SubagentStart`/`SubagentStop` hooks configured, each Claude Code subagent appears as a small head (coloured by agent type, hover for the agent type) orbiting its parent until it finishes
- Configurable terminal font, head size, snap distance, and default CLI flags/arguments
- Menu bar app (no dock icon)

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code CLI (`claude`) installed and on PATH

## Build

For a quick development build:

```bash
swift build
```

To produce a proper app bundle (release build, `Info.plist`, app icon, SwiftPM
resource bundles, ad-hoc code signature):

```bash
./scripts/bundle.sh
```

This writes `dist/ClaudeHeads.app`. The script is idempotent; re-running it
rebuilds and replaces the bundle. The bundle is ad-hoc signed so it launches
locally without Gatekeeper complaints, but it is not notarized, so it is not
suitable for distributing to other machines as-is. It is also built for the
host architecture only (Apple silicon or Intel, whichever ran the script).

## Run

For development:

```bash
swift run ClaudeHeads
```

Note that `swift run` launches a bare executable, not an app bundle, so macOS
stores its preferences under the executable name (`ClaudeHeads`) rather than the
bundle identifier (`com.davenicoll.claude-heads`). Settings saved this way will
not carry over to the bundled app.

To run the bundled app:

```bash
./scripts/bundle.sh
open dist/ClaudeHeads.app
```

Or drag `dist/ClaudeHeads.app` into `/Applications`. The app is a menu bar
agent (`LSUIElement`), so it has no Dock icon; look for it in the menu bar.

## Hook Setup

To get wave-on-completion notifications and the subagent orbit, add `Stop`, `SubagentStart` and `SubagentStop` hooks to `~/.claude/settings.json`, all pointing at the same script:

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
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-heads/hooks/notify.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
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

Claude Code runs the hook with the event JSON on stdin and no arguments. Claude Heads exports `CLAUDE_INSTANCE_ID` (the head's UUID) into each `claude` process it spawns, and `notify.sh` reads `hook_event_name` from stdin to tell the app which head finished (`Stop`) or which subagent started or stopped under it (`SubagentStart`/`SubagentStop`, using `agent_id` and `agent_type`). Only the `Stop` hook is needed for waves; the two subagent hooks are optional and only power the orbit. When `CLAUDE_INSTANCE_ID` is not set (for example, a `claude` session you started yourself in a normal terminal) the script exits silently, so it is safe to leave the hooks configured globally.

The app (re)writes `~/.claude-heads/hooks/notify.sh` on every launch, so do not edit it by hand.
