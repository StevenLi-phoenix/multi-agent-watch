#!/usr/bin/env bash
# Fires when a Claude Code session starts. Registers this session and warns
# (banner + desktop notification + injected context) if other sessions are
# already active on the same git repo.
set -uo pipefail
export MW_HOOK=SessionStart

# Don't let the detached summarizer's own `claude` recurse into our hooks.
[ -n "${MW_SUMMARY_CHILD:-}" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || exit 0
mw_init

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)"
source_field="$(printf '%s' "$input" | jq -r '.source // "startup"' 2>/dev/null)"

[ -z "$cwd" ] && cwd="$(pwd)"
if [ -z "$session_id" ]; then
  mw_log "no session_id in stdin; bailing"
  exit 0
fi

mw_log "start session=$session_id cwd=$cwd source=$source_field"
mw_purge_stale

# Write our entry first; if two sessions race, both writes land before either
# scans, so each correctly sees the other.
mw_write_session "$session_id" "$cwd" "$transcript_path" "$source_field"

repo_key="$(mw_repo_key "$cwd")"
others_json="$(mw_active_for_repo "$repo_key" "$session_id")"
others_count="$(printf '%s' "$others_json" | jq 'length' 2>/dev/null || echo 0)"

if [ "${others_count:-0}" -gt 0 ]; then
  summary="$(printf '%s' "$others_json" | jq -r '
    map("  - session=\(.session_id[0:8]) host=\(.host) pid=\(.pid) cwd=\(.cwd) started=\(.started_at) hb=\(.last_heartbeat)"
        + (if (.summary // "") != "" then "\n      doing: \(.summary)" else "" end))
    | join("\n")
  ' 2>/dev/null || printf '  (unparseable)')"

  short="$others_count other Claude Code session(s) active on $(basename "$repo_key")"

  {
    printf '\n'
    printf '!! multi-agent-watch: collision detected\n'
    printf '   repo:  %s\n' "$repo_key"
    printf '   other active sessions (%s):\n' "$others_count"
    printf '%s\n' "$summary"
    printf '\n'
  } >&2

  mw_notify_desktop "Claude Code: multi-agent collision" "$short"

  context="$(printf 'multi-agent-watch: %s other Claude Code session(s) are concurrently active in this repository (%s). Coordinate carefully — avoid stomping on changes from other sessions, prefer additive edits, and check `git status` before broad refactors. Active sessions:\n%s' "$others_count" "$repo_key" "$summary")"

  jq -n \
    --arg sm "multi-agent-watch: $short — see stderr for details" \
    --arg ctx "$context" \
    '{
      systemMessage: $sm,
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
      }
    }'
fi

# Establish baseline so monitor.sh only fires on subsequent CHANGES.
baseline_csv="$(printf '%s' "$others_json" | jq -r 'map(.session_id) | sort | join(",")' 2>/dev/null || printf '')"
mw_set_known_others "$session_id" "$baseline_csv"

exit 0
