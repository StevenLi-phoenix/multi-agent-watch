# CLAUDE.md — multi-agent-watch

Dev notes for working on this Claude Code plugin. Read this before editing.

## What it is

A Claude Code plugin that detects concurrent sessions on the same repo and lets
them coordinate: collision banners, per-session self-summaries (generated at read
time by `/mw-status` via OpenRouter), direct messages (`/mw-send`), and
subscriptions (`/mw-watch`). Pure bash + `jq` + `curl`, no build.

## ⚠️ Three copies — edit the right ones

This plugin exists in three places; they drift if you forget:

1. **SOURCE (this repo, canonical):** `~/Codes/claude-plugins-local/multi-agent-watch/`
   — the `local` directory-marketplace source (`settings.json` →
   `extraKnownMarketplaces.local`). Git repo. **Commit changes here.**
2. **LIVE (installed, what actually runs):**
   `~/.claude/plugins/cache/local/multi-agent-watch/0.1.0/` — enabled via
   `multi-agent-watch@local`. Edits here take effect immediately for running
   sessions; overwritten on reinstall. (Dir name stays `0.1.0` regardless of
   `plugin.json` version — it's just the install path.)
3. **STALE leftover (ignore):** `~/.claude/plugins/multi-agent-watch/` — old,
   unreferenced.

Workflow: develop in LIVE for instant feedback, then `cp` changed files to SOURCE
and commit. Confirm LIVE is what's running via a registry entry's `source` field
(`monitor` is written only by the cache copy's `monitor.sh`).

## Architecture

- `lib/registry.sh` — all state helpers, sourced by every hook. State lives under
  `$MW_STATE` (default `~/.claude/state/multi-agent-watch/`): `sessions/<sid>.json`
  (one per session), `messages/<sid>/*.json` (inboxes), `summaries/<sid>.json`
  (raw OpenRouter response of the last summary call), `locks/` (per-session
  summary locks), `multi-agent-watch.log`.
- Hooks (`hooks/hooks.json` wires them):
  - `SessionStart` → `session-start.sh`: register + collision banner/notify/context
    + set known-others baseline.
  - `UserPromptSubmit` + `PostToolUse` → `monitor.sh`: heartbeat, purge, **drain
    inbox** (messages + watch pings), inject roster delta + siblings' summaries.
  - `Stop` → `heartbeat.sh` (heartbeat refresh only). `summarize.sh` is a
    deprecated no-op kept for sessions started under the ≤0.2.2 hooks.json.
  - `SessionEnd` → `session-end.sh` → `mw_remove_session`.
- `commands/` — `/mw-status`, `/mw-send`, `/mw-watch` (`.md` = slash command,
  `.sh` = implementation).
- `tests/registry.test.sh` — `bash tests/registry.test.sh` (exit 0 = green). Run it
  after any `registry.sh` change.

## Session entry schema (sessions/<sid>.json)

`session_id, cwd, repo_key, pid, ppid, host, user, transcript_path, source,
started_at, last_heartbeat, last_heartbeat_epoch, known_others_csv,
known_others_at, summary, summary_at, watchers[]`.

## Invariants — don't regress these

- **Atomic writes.** All session-file writes go through `mw_atomic_write` (temp +
  `mv`). Never `jq … > "$file"` directly — a concurrent reader/purger could see a
  truncated file.
- **Merge, don't rebuild.** `mw_write_session` does `. + {…}` onto the existing
  entry so fields set elsewhere (`summary`, `watchers`, `known_others_*`, future
  ones) survive heartbeat rewrites. Rebuilding from `jq -n` silently drops them —
  this was the v0.2.1 bug.
- **Purge is conservative.** `mw_purge_stale` deletes an unparseable file only if
  it's also OLD on disk (mtime), never a fresh mid-write one.
- **Summaries are generated on read only.** The only caller is `/mw-status` →
  `mw_refresh_summaries` (parallel, one `mw_generate_summary` per session). Do not
  add a Stop/monitor trigger. The per-Stop `claude -p` burned tokens on every
  session and was removed in 0.3.0.
- **Cache before cost.** `mw_generate_summary` returns `cached` when the summary
  is younger than `MW_SUMMARY_PERIOD` (900 s). Once expired it returns
  `unchanged` if the transcript mtime is ≤ `summary_at`, i.e. the session is idle.
  It only calls the model past both checks, under an atomic `mkdir` lock.
- **Network is one function.** `mw_llm_post` is the only code that hits
  OpenRouter. Tests override it, or set `MW_OPENROUTER_URL=file://…`, and set a
  fake `OPENROUTER_API_KEY`. The suite must never make a real call.
- **Raw before parse.** `mw_summary_call` writes the raw response to
  `summaries/<sid>.json` before extracting content. The key goes through
  `curl -K <(…)` so it stays out of `ps` argv.
- **Inbox drain before early-exit.** `monitor.sh` drains messages/watch-pings
  *before* the roster-unchanged early return, or messages would only arrive when
  the roster changes.
- **Orphan inboxes have a grace period.** Never delete a recipient's inbox in
  `mw_remove_session`. A stale-purged-while-idle or resumed session re-registers
  under the same id and should still get its mail. `mw_purge_orphan_inboxes`
  (called from `mw_purge_stale`) drops an inbox only when the recipient is
  unregistered **and** its newest message is older than `MW_INBOX_TTL`.
- **Subscriptions:** watchers are stored on the WATCHED entry (`.watchers[]`);
  `mw_set_summary`-change and `mw_remove_session` fan out via `mw_send_message` to
  watcher inboxes. SessionEnd auto-unsubscribes (`mw_unwatch_all`); dead watchers
  are pruned lazily during fan-out.

## Gotchas

- **hooks.json doesn't hot-reload for running sessions.** Editing `monitor.sh`
  content takes effect (re-sourced per fire), but ADDING a hook entry only applies
  to sessions started afterward. Don't expect existing sessions to pick up a new
  Stop/event hook.
- **Slash arg quoting.** Slash commands substitute `$ARGUMENTS` as raw text into a
  shell line. Wrap it as `"$ARGUMENTS"` (one blob) and split inside the script, or
  zsh globs the message (`no matches found` on `* ? [`, non-ASCII). Messages with
  `"` / `$(` / backticks still need the Bash-tool path with manual quoting.
- **macOS bash is 3.2** — no `mapfile`; use `while read` loops.
- **GNU coreutils shadows `stat` on this machine** (gnubin is on PATH). GNU
  `stat -f` means "filesystem status" and exits 0 with junk. `mw_file_mtime`
  therefore tries `stat -c %Y` first and validates that the result is numeric.
  Run the tests under both PATHs:
  `PATH=/usr/bin:/bin:/opt/homebrew/bin bash tests/registry.test.sh`.

## Release

Bump `.claude-plugin/plugin.json` version, update README Changelog, sync LIVE↔SOURCE,
run tests, commit (`feat:`/`fix:`), `git tag -a vX.Y.Z`, push `main` + tag.
Patch (`0.2.x`) = small fix; minor (`0.x.0`) = feature.
