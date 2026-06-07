# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
