#!/usr/bin/env bash
# Stop-hook worker: generate this session's one-line self-summary via
# `claude -p --model haiku` so sibling sessions can read what we're doing.
#
# Wired as an ASYNC Stop hook (see hooks.json) so the model call never blocks
# the turn. It fires every Stop, but mw_generate_summary is run-once by default
# (skips if a summary already exists), so `claude -p` actually executes only
# once per session unless MW_SUMMARY_REFRESH=1 is set.
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

mw_generate_summary "$sid" "$tt"
exit 0
