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
- Subagent orbit: with the `SubagentStart`/`SubagentStop` hooks configured, each Claude Code subagent appears as a small head (35% of the parent's size, coloured by agent type, hover for the agent type) orbiting its parent until it finishes; turn it off with "Show children for subagents" in Settings
- Configurable terminal font, head size, snap distance, subagent children on/off, and default CLI flags/arguments
- Installs the Claude Code hooks it needs into `~/.claude/settings.json` on launch and removes them on quit, with a minimal text edit that preserves everything outside its own entries byte-for-byte (see Hook Setup)
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

Claude Heads configures the Claude Code hooks it needs by itself; there is no setting for it. On every launch it rewrites `~/.claude-heads/hooks/notify.sh` and adds `Stop`, `SubagentStart` and `SubagentStop` entries to your global `~/.claude/settings.json` that run that script. All three are installed while the app runs, and when you quit the app it removes exactly those entries again. "Show children for subagents" in Settings only affects display: the subagent hooks stay installed while it is off so that children keep being tracked and appear the moment it is turned back on. Hooks apply to `claude` sessions started after they were written; the app starts a fresh `claude` for every head, so its own heads always pick them up.

What it writes, for each of the three events (with the absolute path of your home directory; the file itself is never touched with `~`):

```json
{
  "hooks": [
    {
      "type": "command",
      "command": "/Users/you/.claude-heads/hooks/notify.sh",
      "timeout": 5
    }
  ]
}
```

How it edits the file:

- The edit is a minimal textual splice, not a rewrite: the missing entries are inserted at the start of the existing `"hooks"` object (or a new `"hooks"` block at the start of the file if there is none), using the file's own indentation and line endings. Every other byte, key order and comment-free formatting is preserved, so a `settings.json` that lives in a dotfiles git repository shows only the added lines in `git diff`.
- Removal is the inverse splice: only command entries that invoke `.claude-heads/hooks/notify.sh` are removed. A matcher group that contained only our command is removed whole, and an event array or `"hooks"` object that becomes empty is removed with its key. Everything outside those entries is preserved byte-for-byte, so installing and then quitting normally returns the file to exactly its original bytes.
- Before the first modification a one-time backup of the original is written to `~/.claude-heads/settings.json.claude-heads.bak` (outside `~/.claude`, so it does not show up in a dotfiles repository); it is never overwritten. If the file is missing or empty it is created with just the hooks block (and no backup).
- The settings file is `$CLAUDE_CONFIG_DIR/settings.json` when Claude Code's `CLAUDE_CONFIG_DIR` is set in the app's environment, otherwise `~/.claude/settings.json`.
- Two running copies of Claude Heads share the file: quitting one removes the hooks the other still needs for heads it starts afterwards (use "Reinstall hooks" or relaunch to put them back).
- Writes are atomic (temp file plus rename in the same directory) and follow symlinks, so a `~/.claude` that is a symlink into a repository is left as a symlink and the real file is updated in place.
- If the file is not strict JSON, `"hooks"` is not an object, or the edited result would not parse or would change anything but our entries, nothing is written and the Settings window shows "Could not update settings.json: <reason>".
- If the app crashes, the entries stay in the file harmlessly: `notify.sh` exits 0 when `CLAUDE_INSTANCE_ID` is not set, so a `claude` you run in a normal terminal is unaffected, and the next launch is idempotent (an event that already invokes `notify.sh` is left alone).

The Settings window shows the current state ("Installed", "Missing: SubagentStart, SubagentStop", or the error above) next to a "Reinstall hooks" button, which strips any stale `notify.sh` entries (for example from a previous home directory) and writes fresh ones in a single edit.

### Manual setup

If the Settings window reports that the app could not update `settings.json` (for example because the file is not strict JSON), add the entries yourself. Note that the app removes any entry pointing at `notify.sh` on quit and re-adds its own on the next launch, so hand-written entries only need to last until the file is fixed. `~/.claude/settings.json` should contain `Stop`, `SubagentStart` and `SubagentStop` hooks all pointing at the same script:

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
