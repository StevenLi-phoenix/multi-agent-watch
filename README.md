![multi-agent-watch banner](./banner.png)

# multi-agent-watch

Claude Code plugin that detects and notifies when multiple Claude Code sessions are working on the same repository concurrently — so two of you don't silently overwrite each other.

## What it does

- Registers each Claude Code session in `~/.claude/state/multi-agent-watch/sessions/<session-id>.json`.
- On `SessionStart`, scans the registry for other active sessions on the same repo (resolved via `git rev-parse --show-toplevel`, falling back to absolute cwd for non-git directories).
- If a collision is found:
  - Banner printed to stderr (visible in your terminal).
  - Desktop notification (`terminal-notifier` → `osascript` → `notify-send`, whichever is available).
  - Context injected into the new session so Claude knows other agents are active and can edit defensively.
  - `systemMessage` shown by Claude Code's own UI.
- Heartbeats on `UserPromptSubmit` and `Stop` keep the entry fresh.
- Stale entries (>10 min since last heartbeat) auto-purged on every hook fire.
- `SessionEnd` removes the entry immediately.

## Install

Inside Claude Code, add this repo as a marketplace and install the plugin:

```text
/plugin marketplace add StevenLi-phoenix/multi-agent-watch
/plugin install multi-agent-watch@multi-agent-watch
```

Or open the interactive picker with `/plugin` and add `StevenLi-phoenix/multi-agent-watch` from the **Marketplaces** tab.

To pin a specific version:

```text
/plugin marketplace add StevenLi-phoenix/multi-agent-watch@v0.1.0
```

To update later:

```text
/plugin marketplace update multi-agent-watch
```

Hooks are auto-registered from `hooks/hooks.json`.

### Manual install (fallback)

```bash
git clone https://github.com/StevenLi-phoenix/multi-agent-watch.git ~/.claude/plugins/multi-agent-watch
```

Then restart Claude Code.

## Slash commands

- `/mw-status` — list all currently registered sessions, grouped by repo, flagging collisions.

## Config (env vars)

| var            | default                             | meaning                                 |
| -------------- | ----------------------------------- | --------------------------------------- |
| `MW_STATE`     | `~/.claude/state/multi-agent-watch` | state directory                         |
| `MW_STALE_SEC` | `600`                               | heartbeat staleness threshold (seconds) |
| `MW_QUIET`     | `0`                                 | `1` suppresses desktop notification     |

## Files

- `~/.claude/state/multi-agent-watch/sessions/<session-id>.json` — one per active session
- `~/.claude/state/multi-agent-watch/multi-agent-watch.log` — diagnostic log

## Limitations

- Single machine — sessions on other hosts won't be visible unless `MW_STATE` points at a shared volume (Tailscale fileshare, Dropbox, NFS, etc.).
- Repo identity is `git rev-parse --show-toplevel` or absolute cwd. Sibling subdirs of one repo are treated as the same repo.
- Subagents launched via the `Task` tool share the parent's `session_id` and don't show up as separate sessions (intentional — they aren't independent).

## License

MIT
