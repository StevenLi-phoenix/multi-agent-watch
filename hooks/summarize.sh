#!/usr/bin/env bash
# Stop-hook worker: generate this session's one-line self-summary via
# `claude -p --model haiku` so sibling sessions can read what we're doing.
#
# Wired as an ASYNC Stop hook (see hooks.json) so the model call never blocks
# the turn. It fires every Stop, but only runs `claude -p` when (a) this session
# has loaded the multi-agent-watch skill (ran a /mw-* command) and (b) the
# stored summary is older than MW_SUMMARY_PERIOD seconds. MW_SUMMARY_REFRESH=1
# forces a refresh; MW_SUMMARY_REQUIRE_SKILL=0 drops the skill gate.
#
# Invocation: receives the hook JSON on stdin (session_id, transcript_path).
# Also accepts positional args ("$1" sid, "$2" transcript) for direct/testing.
set -uo pipefail
export MW_HOOK=summarize

# If we are already running inside a summarizer's own `claude`, do nothing —
# this is what prevents the spawned model call from recursing into our hooks.
[ -n "${MW_SUMMARY_CHILD:-}" ] && exit 0
# Mark the `claude` we are about to launch so ITS multi-agent-watch hooks no-op.
export MW_SUMMARY_CHILD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || exit 0
mw_init

sid="${1:-}"
tt="${2:-}"
if [ -z "$sid" ]; then
  input="$(cat 2>/dev/null || printf '')"
  sid="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
  tt="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)"
fi
[ -z "$sid" ] && exit 0

# Only summarize when this session actually loaded the multi-agent-watch skill
# (ran a /mw-* command). Skips the `claude -p` cost for sessions that never
# engaged the plugin. Set MW_SUMMARY_REQUIRE_SKILL=0 to summarize every session.
if [ "$MW_SUMMARY_REQUIRE_SKILL" != "0" ] && ! mw_skill_engaged "$tt"; then
  mw_log "summary skipped sid=$sid: skill not loaded"
  exit 0
fi

mw_generate_summary "$sid" "$tt"
exit 0
