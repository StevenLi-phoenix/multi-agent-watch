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
- Generated **on read only**: running `/mw-status` refreshes every session's one-sentence summary right before rendering it. Nothing runs on `Stop` or in the background, so sessions that never look at the roster cost nothing.
- Each stale session gets one call to **DeepSeek V4.1 Flash via OpenRouter** (`deepseek/deepseek-v4.1-flash`, reasoning off, providers sorted by latency) over a digest of its transcript. Calls run in parallel and are capped at `MW_SUMMARY_TIMEOUT` seconds, so a read takes about one round-trip (~1–2 s). A call costs about $0.00002.
- **15-minute cache**: a summary younger than `MW_SUMMARY_PERIOD` (900 s) is reused as-is. After that it is regenerated only if the session's transcript changed since, so an idle session never pays again. `MW_SUMMARY_REFRESH=1` forces a regeneration. An atomic lock stops two concurrent reads from paying for the same session.
- The raw API response is saved to `summaries/<session-id>.json` before parsing; cost, latency and failures go to the log. The `/mw-status` footer shows the model, the cache window and a tally (`2 cached, 1 regenerated`).
- Collision banners and `monitor` deltas show the last stored `doing: …` line for each sibling.

### Direct messages (留言)
- `/mw-send <session-id-prefix | all> <message>` leaves a note for another active session on the same repo.
- The recipient's `monitor` hook delivers the message (and deletes it) into its context on its next prompt or tool use.
- Mail for a session that has left is kept for `MW_INBOX_TTL` (24h) after its last message, in case the session comes back under the same id. After that it is purged and the purge is logged.
- `all` broadcasts to every other session on your repo (you are excluded). A prefix targets specific session(s).
- Sender identity comes from `$CLAUDE_CODE_SESSION_ID`.

### Subscriptions (watch a session)
- `/mw-watch <session-id-prefix>` subscribes you to another session. While subscribed you get a message (delivered through the same monitor drain) when that session **changes its self-summary** or **ends**.
- `/mw-watch --list` shows who you're watching; `/mw-watch --stop <prefix>` unsubscribes.
- Watchers are stored on the watched session's entry and fan out on summary-change / removal (including stale-purge). Subscriptions **auto-clear on SessionEnd** and dead watchers are pruned lazily.
- Turns polling into push — e.g. waiting for a sibling to finish a prerequisite instead of re-reading a coordination file.

## Install

This plugin ships via a local directory marketplace. The source lives in your
plugins-local directory and is installed into the Claude Code plugin cache;
enable it with `multi-agent-watch@local` in `~/.claude/settings.json`
(`enabledPlugins`). Restart Claude Code (or `/plugin`) to reload. Hooks are
auto-registered from `hooks/hooks.json`.

## Slash commands

- `/mw-status` — list all registered sessions grouped by repo, flagging collisions; shows each session's self-summary, watcher count, and any pending (undelivered) messages.
- `/mw-send <to> <message>` — leave a message for another session (`<to>` is an 8-char session-id prefix or `all`).
- `/mw-watch <to>` / `/mw-watch --list` / `/mw-watch --stop <to>` — subscribe to a session's summary-change / end events.

## Config (env vars)

| var                  | default                             | meaning                                                            |
| -------------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `MW_STATE`           | `~/.claude/state/multi-agent-watch` | state directory                                                    |
| `MW_STALE_SEC`       | `600`                               | heartbeat staleness threshold (seconds)                            |
| `MW_QUIET`           | `0`                                 | `1` suppresses desktop notification                                |
| `MW_INBOX_TTL`       | `86400`                             | drop an unregistered recipient's inbox this long after its last message |
| `OPENROUTER_API_KEY` | —                                   | key for the summary call; unset ⇒ summaries skipped (footer says so) |
| `MW_SUMMARY_MODEL`   | `deepseek/deepseek-v4.1-flash`      | OpenRouter model slug used for self-summaries                      |
| `MW_SUMMARY_PERIOD`  | `900`                               | summary cache lifetime in seconds (15 min)                         |
| `MW_SUMMARY_TIMEOUT` | `20`                                | per-call `curl --max-time` (seconds)                               |
| `MW_SUMMARY_REFRESH` | unset                               | `1` ignores the cache and regenerates on this read                 |
| `MW_OPENROUTER_URL`  | OpenRouter chat-completions URL     | endpoint override (tests point it at a `file://` fixture)          |

## Files

- `~/.claude/state/multi-agent-watch/sessions/<session-id>.json` — one per active session (includes `summary`)
- `~/.claude/state/multi-agent-watch/messages/<recipient-sid>/*.json` — queued, undelivered messages
- `~/.claude/state/multi-agent-watch/summaries/<session-id>.json` — raw OpenRouter response of the last summary call
- `~/.claude/state/multi-agent-watch/locks/` — per-session summary locks
- `~/.claude/state/multi-agent-watch/multi-agent-watch.log` — diagnostic log

## Tests

```bash
bash tests/registry.test.sh   # exit 0 = all green
```

Covers atomic writes under concurrency, purge safety (never deletes a fresh
mid-write file), message send/drain, recipient resolution, and summary
generation: the 15-minute cache, idle-skip, failure paths, the parallel
refresh, and an end-to-end `/mw-status` run against a `file://` fixture. No
network calls.

## Limitations

- Single machine — sessions on other hosts won't be visible unless `MW_STATE` points at a shared volume (Tailscale fileshare, Dropbox, NFS, etc.).
- Repo identity is `git rev-parse --show-toplevel` or absolute cwd. Sibling subdirs of one repo are treated as the same repo.
- Subagents launched via the `Task` tool share the parent's `session_id` and don't show up as separate sessions (intentional — they aren't independent).
- Self-summaries need `OPENROUTER_API_KEY` in the environment Claude Code was launched from. Without it they are skipped and collision detection still works.
- Summaries are only as fresh as the last `/mw-status`. Banners and monitor deltas show whatever was stored by that read.

## Changelog

- **0.3.1** — purge inboxes of recipients that are gone (24h grace, `MW_INBOX_TTL`); `/mw-status` flags them.
- **0.3.0** — self-summaries move from a `claude -p` Stop hook to read-time generation in `/mw-status`: DeepSeek V4.1 Flash via OpenRouter, parallel, 15-minute cache plus idle-skip. Also fixes `mw_file_mtime` when GNU coreutils shadows `stat`. See CHANGELOG.md.
- **0.2.1** — fix `/mw-send` slash quoting so non-ASCII / glob-char messages no longer trip zsh `no matches found` (message passed as one quoted blob, recipient split in-script); `mw_write_session` now merges onto the existing entry so `summary` / `watchers` / `known_others` survive heartbeat rewrites. Adds subscriptions (`/mw-watch`): get pinged when a watched session changes its summary or ends, auto-unsubscribe on SessionEnd; `/mw-status` shows watcher counts.
- **0.2.0** — atomic registry writes + safer stale-purge (never deletes a file caught mid-write); per-session `claude -p` self-summaries surfaced to siblings; direct inter-session messaging (`/mw-send`); `/mw-status` shows summaries and pending messages; unit + integration tests.
- **0.1.0** — collision detection, monitor deltas, desktop notifications, `/mw-status`.
