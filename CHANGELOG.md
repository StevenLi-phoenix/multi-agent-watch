# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.1] - 2026-10-07 — Orphan inbox cleanup

### Fixed
- Messages addressed to a session that ended before draining them stayed in `messages/<sid>/` forever, and `/mw-status` kept listing them as "waiting". `mw_purge_stale` now drops an inbox when its recipient is no longer registered and its newest message is older than `MW_INBOX_TTL` (default 24h). Empty leftover dirs are dropped right away. The grace period keeps mail for a session that was stale-purged while idle, or resumed, and comes back under the same id. Each drop is logged.
  Files: lib/registry.sh (new `mw_purge_orphan_inboxes`)
- `/mw-status` now marks the pending inboxes whose recipient isn't registered, and says when they will be dropped.
  Files: commands/mw-status.sh

### Tests
- Orphan purge: an old orphan is dropped and logged, an empty dir is dropped, a fresh orphan is kept during the grace period, a live recipient's old mail is kept, and `/mw-status` flags orphans. 75 checks.
  Files: tests/registry.test.sh

## [0.3.0] - 2026-10-07 — Summaries on read

### Changed
- Self-summaries are now generated only when `/mw-status` runs. Before rendering, the command refreshes every session's summary in parallel. Nothing summarizes on `Stop` or in the background anymore.
  Files: commands/mw-status.sh, lib/registry.sh (new `mw_refresh_summaries`)
- Summaries now come from DeepSeek V4.1 Flash via OpenRouter (`deepseek/deepseek-v4.1-flash`) instead of `claude -p --model haiku`, called with `curl`. Reasoning is off and providers are sorted by latency, so a call takes ~1–2 s and costs ~$0.00002. The model can be overridden with `MW_SUMMARY_MODEL`, and the key comes from `OPENROUTER_API_KEY`.
  Files: lib/registry.sh (new `mw_llm_post`, `mw_summary_call`)
- Summary cache is now 15 minutes (`MW_SUMMARY_PERIOD` default 900, was 300). Once it expires, a session whose transcript hasn't changed since its last summary is skipped instead of re-billed. `MW_SUMMARY_TIMEOUT` default is 20 s (was 120).
  Files: lib/registry.sh
- `/mw-status` shows each summary's age (`doing (4m ago): …`) and a footer with the model, the cache window and a tally (`2 cached, 1 regenerated`). The footer also says when the key is missing or a call failed.
  Files: commands/mw-status.sh
- The raw API response is saved to `summaries/<sid>.json` before parsing, and is removed with the session. Every call logs its cost and latency, and every failure logs its reason.
  Files: lib/registry.sh

### Removed
- The async `Stop` summarize hook, the `/mw-*` skill-engaged gate (`mw_skill_engaged`, `MW_SUMMARY_REQUIRE_SKILL`), `MW_CLAUDE_BIN`, and the `MW_SUMMARY_CHILD` recursion guards, which became dead code once no `claude` child process is spawned. `hooks/summarize.sh` remains as a no-op so sessions started under the old hooks.json don't error on every Stop.
  Files: hooks/hooks.json, hooks/summarize.sh, hooks/heartbeat.sh, hooks/monitor.sh, hooks/session-start.sh, hooks/session-end.sh, lib/registry.sh

### Fixed
- `mw_file_mtime` returned junk when GNU coreutils shadows `/usr/bin/stat`, because GNU `stat -f` succeeds with filesystem info. When that happened, `mw_purge_stale` aborted with `unbound variable` on a corrupt session file. It now tries GNU `stat -c` first and validates the result.
  Files: lib/registry.sh

### Tests
- Rewrote the summary suite against a stubbed `mw_llm_post`, covering the request body (model, reasoning off), the 15-minute cache, idle-skip, forced refresh, missing key, API error (raw response kept, failure logged, lock released), missing transcript, the parallel refresh tally, and an end-to-end `/mw-status` run against a `file://` fixture. 68 checks pass under both GNU and BSD `stat`/`date`.
  Files: tests/registry.test.sh

## [0.2.2] - 2026-07-02 — Cheaper, fresher summaries

### Changed
- Self-summaries now refresh on a period instead of running exactly once. When the Stop hook fires and the stored summary is older than `MW_SUMMARY_PERIOD` seconds (default 300), it re-summarizes so long-running sessions keep an up-to-date label. Within the period it still no-ops, so cost stays bounded. `MW_SUMMARY_REFRESH=1` forces a refresh; `MW_SUMMARY_PERIOD=0` always refreshes.
  Files: lib/registry.sh
- Summaries are now gated on the multi-agent-watch skill actually being loaded: the Stop hook only runs `claude -p` for sessions whose transcript shows a `/mw-*` command was used. Sessions that never engaged the plugin no longer pay the haiku call. Set `MW_SUMMARY_REQUIRE_SKILL=0` to restore unconditional summarizing.
  Files: hooks/summarize.sh, lib/registry.sh (new `mw_skill_engaged`, `mw_summary_at_epoch`)

### Tests
- Added coverage for period expiry (stale → re-call, fresh → skip) and the skill-engaged gate.
  Files: tests/registry.test.sh

## [0.2.1] - 2026-06-07 — Messaging quoting fix + subscriptions

### Added
- Subscriptions: `/mw-watch <id>` pings you (via the normal monitor drain) when a watched session changes its self-summary or ends; `--list` / `--stop` manage them; auto-unsubscribe on `SessionEnd`; dead watchers pruned lazily. `/mw-status` shows watcher counts.
  Files: lib/registry.sh, commands/mw-watch.sh, commands/mw-watch.md, commands/mw-status.sh, hooks/session-end.sh
- Project docs: `CLAUDE.md` (architecture, invariants, three-copy layout) and this `CHANGELOG.md`.
  Files: CLAUDE.md, CHANGELOG.md

### Fixed
- `/mw-send` slash command globbed messages under zsh — non-ASCII or `* ? [` text tripped `no matches found`. Args are now passed as one quoted blob and the recipient is split in-script; direct multi-arg calls still work.
  Files: commands/mw-send.md, commands/mw-send.sh
- `mw_write_session` rebuilt entries from scratch and wiped fields set elsewhere (`summary`, `watchers`, `known_others_*`); it now merges onto the existing entry so they survive heartbeat rewrites.
  Files: lib/registry.sh

## [0.2.0] - 2026-06-07 — Coordinate, not just detect

### Added
- Per-session self-summaries: an async `Stop` hook runs `claude -p --model haiku` over the transcript and publishes a one-line "what I'm doing" that siblings read in collision/monitor injections. Run-once by default (`MW_SUMMARY_REFRESH=1` to refresh), with an `MW_SUMMARY_CHILD` guard against hook recursion.
  Files: hooks/summarize.sh, hooks/hooks.json, lib/registry.sh
- Direct inter-session messaging: `/mw-send <id|all> <msg>` queues a note the recipient's monitor hook delivers (and deletes) on its next prompt/tool use.
  Files: commands/mw-send.sh, commands/mw-send.md, hooks/monitor.sh, lib/registry.sh
- `/mw-status` now shows each session's summary and pending message counts; `tests/registry.test.sh` unit/integration suite.
  Files: commands/mw-status.sh, tests/registry.test.sh

### Fixed
- Registry writes are now atomic (temp + rename), so a concurrent purge can no longer delete a session file caught mid-write.
  Files: lib/registry.sh
- `mw_purge_stale` deletes an unparseable file only when it is also old on disk, never a fresh mid-write one.
  Files: lib/registry.sh

## [0.1.0] - 2026-04-27 — Initial release

### Added
- Collision detection across concurrent Claude Code sessions on the same repo: per-session registry, `SessionStart` collision banner + desktop notification + context injection, `monitor` deltas on join/leave, heartbeats, stale auto-purge, and the `/mw-status` slash command.
  Files: lib/registry.sh, hooks/*, commands/mw-status.sh, .claude-plugin/plugin.json
