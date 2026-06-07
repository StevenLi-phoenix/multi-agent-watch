# multi-agent-watch

Claude Code plugin that detects when multiple Claude Code sessions are working on
the same repository concurrently — and lets them **coordinate**: each session
publishes a one-line self-summary of what it's doing, and you can leave direct
messages for another running session.

## What it does

### Collision detection
- Registers each Claude Code session in `~/.claude/state/multi-agent-watch/sessions/<session-id>.json`.
- On `SessionStart`, scans the registry for other active sessions on the same repo (resolved via `git rev-parse --show-toplevel`, falling back to absolute cwd for non-git directories).
- If a collision is found:
  - Banner printed to stderr (visible in your terminal).
  - Desktop notification (`terminal-notifier` → `osascript` → `notify-send`, whichever is available).
  - Context injected into the new session so Claude knows other agents are active and can edit defensively.
  - `systemMessage` shown by Claude Code's own UI.
- `monitor` (on `UserPromptSubmit` + `PostToolUse`) heartbeats and injects a delta whenever the set of other sessions changes (who joined / who left).
- `Stop` refreshes the heartbeat. Stale entries (>10 min since last heartbeat) are auto-purged on every hook fire. `SessionEnd` removes the entry immediately.

### Self-summary (what each session is doing)
- On `Stop`, an **async** hook (`summarize.sh`) runs `claude -p --model haiku` over a digest of the session's transcript and stores a one-sentence summary in the session's registry entry.
- It is **run-once by default**: the model call fires a single time per session (guarded by an atomic lock + a cached `summary` field). Set `MW_SUMMARY_REFRESH=1` to instead refresh the summary on every `Stop` as the work evolves.
- The call is async, so it never blocks your turn, and it's detached from your context — the spawned `claude` is marked (`MW_SUMMARY_CHILD`) so it doesn't recurse into these hooks.
- Other sessions **read** that summary: collision banners and `monitor` deltas show each sibling's `doing: …` line. N sessions ⇒ N summary calls total (each summarizes itself), not N².

### Direct messages (留言)
- `/mw-send <session-id-prefix | all> <message>` leaves a note for another active session on the same repo.
- The recipient's `monitor` hook delivers the message (and deletes it) into its context on its next prompt or tool use.
- `all` broadcasts to every other session on your repo (you are excluded). A prefix targets specific session(s).
- Sender identity comes from `$CLAUDE_CODE_SESSION_ID`.

## Install

This plugin ships via a local directory marketplace. The source lives in your
plugins-local directory and is installed into the Claude Code plugin cache;
enable it with `multi-agent-watch@local` in `~/.claude/settings.json`
(`enabledPlugins`). Restart Claude Code (or `/plugin`) to reload. Hooks are
auto-registered from `hooks/hooks.json`.

## Slash commands

- `/mw-status` — list all registered sessions grouped by repo, flagging collisions; shows each session's self-summary and any pending (undelivered) messages.
- `/mw-send <to> <message>` — leave a message for another session (`<to>` is an 8-char session-id prefix or `all`).

## Config (env vars)

| var                  | default                             | meaning                                                            |
| -------------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `MW_STATE`           | `~/.claude/state/multi-agent-watch` | state directory                                                    |
| `MW_STALE_SEC`       | `600`                               | heartbeat staleness threshold (seconds)                            |
| `MW_QUIET`           | `0`                                 | `1` suppresses desktop notification                                |
| `MW_CLAUDE_BIN`      | `claude`                            | binary used to generate the self-summary                           |
| `MW_SUMMARY_MODEL`   | `haiku`                             | model passed to `claude -p --model`                                |
| `MW_SUMMARY_TIMEOUT` | `120`                               | seconds before the summary call is killed (`timeout`, if present)  |
| `MW_SUMMARY_REFRESH` | unset                               | `1` regenerates the summary on every `Stop` instead of run-once    |

## Files

- `~/.claude/state/multi-agent-watch/sessions/<session-id>.json` — one per active session (includes `summary`)
- `~/.claude/state/multi-agent-watch/messages/<recipient-sid>/*.json` — queued, undelivered messages
- `~/.claude/state/multi-agent-watch/locks/` — once-only summary locks
- `~/.claude/state/multi-agent-watch/multi-agent-watch.log` — diagnostic log

## Tests

```bash
bash tests/registry.test.sh   # exit 0 = all green
```

Covers atomic writes under concurrency, purge safety (never deletes a fresh
mid-write file), message send/drain, recipient resolution, and run-once summary
generation against a stubbed `claude`.

## Limitations

- Single machine — sessions on other hosts won't be visible unless `MW_STATE` points at a shared volume (Tailscale fileshare, Dropbox, NFS, etc.).
- Repo identity is `git rev-parse --show-toplevel` or absolute cwd. Sibling subdirs of one repo are treated as the same repo.
- Subagents launched via the `Task` tool share the parent's `session_id` and don't show up as separate sessions (intentional — they aren't independent).
- The self-summary requires the `claude` CLI on `PATH`; if it's missing the summary is simply skipped (collision detection still works).

## Changelog

- **0.2.0** — atomic registry writes + safer stale-purge (never deletes a file caught mid-write); per-session `claude -p` self-summaries surfaced to siblings; direct inter-session messaging (`/mw-send`); `/mw-status` shows summaries and pending messages; unit + integration tests.
- **0.1.0** — collision detection, monitor deltas, desktop notifications, `/mw-status`.
