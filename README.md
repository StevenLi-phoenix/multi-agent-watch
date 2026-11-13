# multi-agent-watch

Claude Code plugin that detects when multiple Claude Code sessions are working on
the same repository concurrently — and helps them **coordinate**: each session
publishes a one-line self-summary of what it's doing, rosters carry each
sibling's Claude Code name so you can message it with the native `SendMessage`
tool, and you can subscribe to another session's progress.

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
- Each stale session gets one OpenAI-compatible chat-completions call (default **DeepSeek V4.1 Flash via OpenRouter**, `deepseek/deepseek-v4.1-flash`, reasoning off, providers sorted by latency) over a digest of its transcript. Point `MW_SUMMARY_BASE_URL` at any compatible server and set `MW_SUMMARY_API_KEY` for its key. Calls run in parallel and are capped at `MW_SUMMARY_TIMEOUT` seconds, so a read takes about one round-trip (~1–2 s). A call costs about $0.00002.
- **15-minute cache**: a summary younger than `MW_SUMMARY_PERIOD` (900 s) is reused as-is. After that it is regenerated only if the session's transcript changed since, so an idle session never pays again. `MW_SUMMARY_REFRESH=1` forces a regeneration. An atomic lock stops two concurrent reads from paying for the same session.
- The raw API response is saved to `summaries/<session-id>.json` before parsing; cost, latency and failures go to the log. The `/mw-status` footer shows the model, the cache window and a tally (`2 cached, 1 regenerated`).
- Collision banners and `monitor` deltas show the last stored `doing: …` line for each sibling.

### Talking to a sibling: native `SendMessage`
- Claude Code messages between local sessions natively (`SendMessage` / `ListAgents`), addressed by a session name such as `temp-dd`. The plugin's own `/mw-send` was removed in 0.4.0 in favour of it.
- Every roster (collision banner, `monitor` delta, `/mw-status`) prints `name=<native name>` next to each session id, read from Claude Code's live-session registry (`~/.claude/sessions/<pid>.json`, matched by session id). The session that hits a collision can therefore message the sibling it collides with directly.

### Subscriptions (watch a session)
- `/mw-watch <session-id-prefix>` subscribes you to another session. While subscribed you get a notification, injected by the `monitor` hook on your next prompt or tool use, when that session **changes its self-summary** or **ends**.
- Notifications for a session that has left are kept for `MW_INBOX_TTL` (24h), in case it comes back under the same id. After that they are purged and the purge is logged.
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

- `/mw-status` — list all registered sessions grouped by repo, flagging collisions; shows each session's native name, self-summary, watcher count, and any pending (undelivered) watch notifications.
- `/mw-watch <to>` / `/mw-watch --list` / `/mw-watch --stop <to>` — subscribe to a session's summary-change / end events.

## Config (env vars)

| var                  | default                             | meaning                                                            |
| -------------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `MW_STATE`           | `~/.claude/state/multi-agent-watch` | state directory                                                    |
| `MW_STALE_SEC`       | `600`                               | heartbeat staleness threshold (seconds)                            |
| `MW_QUIET`           | `0`                                 | `1` suppresses desktop notification                                |
| `MW_INBOX_TTL`       | `86400`                             | drop an unregistered recipient's inbox this long after its last message |
| `MW_CC_SESSIONS_DIR` | `~/.claude/sessions`                | Claude Code's live-session registry, read for native names         |
| `MW_SUMMARY_BASE_URL` | `https://openrouter.ai/api/v1`     | base URL of the OpenAI-compatible server; `/chat/completions` is appended |
| `MW_SUMMARY_API_KEY` | —                                   | key for the summary call; wins over `OPENROUTER_API_KEY` |
| `OPENROUTER_API_KEY` | —                                   | fallback key for the summary call; no key ⇒ summaries skipped (footer says so) |
| `MW_SUMMARY_MODEL`   | `deepseek/deepseek-v4.1-flash`      | model id sent to the summary endpoint                              |
| `MW_SUMMARY_PERIOD`  | `900`                               | summary cache lifetime in seconds (15 min)                         |
| `MW_SUMMARY_TIMEOUT` | `20`                                | per-call `curl --max-time` (seconds)                               |
| `MW_SUMMARY_REFRESH` | unset                               | `1` ignores the cache and regenerates on this read                 |
| `MW_OPENROUTER_URL`  | unset                               | full endpoint override, beats `MW_SUMMARY_BASE_URL` (tests use a `file://` fixture) |

## Files

- `~/.claude/state/multi-agent-watch/sessions/<session-id>.json` — one per active session (includes `summary`)
- `~/.claude/state/multi-agent-watch/messages/<recipient-sid>/*.json` — queued, undelivered `/mw-watch` notifications
- `~/.claude/state/multi-agent-watch/summaries/<session-id>.json` — raw OpenRouter response of the last summary call
- `~/.claude/state/multi-agent-watch/locks/` — per-session summary locks
- `~/.claude/state/multi-agent-watch/multi-agent-watch.log` — diagnostic log

## Tests

```bash
bash tests/registry.test.sh   # exit 0 = all green
```

Covers atomic writes under concurrency, purge safety (never deletes a fresh
mid-write file), notification send/drain, session resolution, native-name
lookup, the `session-start` and `monitor` hook output, and summary
generation: the 15-minute cache, idle-skip, failure paths, the parallel
refresh, and an end-to-end `/mw-status` run against a `file://` fixture. No
network calls.

## Limitations

- Single machine — sessions on other hosts won't be visible unless `MW_STATE` points at a shared volume (Tailscale fileshare, Dropbox, NFS, etc.).
- Repo identity is `git rev-parse --show-toplevel` or absolute cwd. Sibling subdirs of one repo are treated as the same repo.
- Subagents launched via the `Task` tool share the parent's `session_id` and don't show up as separate sessions (intentional — they aren't independent).
- Self-summaries need a key (`MW_SUMMARY_API_KEY` or `OPENROUTER_API_KEY`) in the environment Claude Code was launched from. Without one they are skipped and collision detection still works. Set them under `env` in `~/.claude/settings.json` so every session gets them.
- Rosters show each session's native name and busy/idle status (`name=temp-aa [busy]`), read from Claude Code's own session registry (the same fields `ListAgents` shows).
- Summaries are only as fresh as the last `/mw-status`. Banners and monitor deltas show whatever was stored by that read.

## Changelog

- **0.4.1** — SessionStart hook 206 ms → ~60 ms (one `jq` per stage instead of one per session/file, async desktop notification); `monitor` / `heartbeat` share the same faster helpers. See CHANGELOG.md.
- **0.4.0** — `/mw-send` removed: Claude Code's native `SendMessage` covers session-to-session chat. Rosters now print each session's native `name=` so you can message the sibling you collide with. See CHANGELOG.md.
- **0.3.1** — purge inboxes of recipients that are gone (24h grace, `MW_INBOX_TTL`); `/mw-status` flags them.
- **0.3.0** — self-summaries move from a `claude -p` Stop hook to read-time generation in `/mw-status`: DeepSeek V4.1 Flash via OpenRouter, parallel, 15-minute cache plus idle-skip. Also fixes `mw_file_mtime` when GNU coreutils shadows `stat`. See CHANGELOG.md.
- **0.2.1** — fix `/mw-send` slash quoting so non-ASCII / glob-char messages no longer trip zsh `no matches found` (message passed as one quoted blob, recipient split in-script); `mw_write_session` now merges onto the existing entry so `summary` / `watchers` / `known_others` survive heartbeat rewrites. Adds subscriptions (`/mw-watch`): get pinged when a watched session changes its summary or ends, auto-unsubscribe on SessionEnd; `/mw-status` shows watcher counts.
- **0.2.0** — atomic registry writes + safer stale-purge (never deletes a file caught mid-write); per-session `claude -p` self-summaries surfaced to siblings; direct inter-session messaging (`/mw-send`); `/mw-status` shows summaries and pending messages; unit + integration tests.
- **0.1.0** — collision detection, monitor deltas, desktop notifications, `/mw-status`.
