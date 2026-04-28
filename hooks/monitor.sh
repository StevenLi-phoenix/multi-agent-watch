#!/usr/bin/env bash
# Heartbeat + change-detection. Wired to UserPromptSubmit and PostToolUse.
# Compares the current set of OTHER sessions on this repo to the set we last
# reported (stored in our own session file as known_others_csv). When they
# differ, emits a context-injection JSON describing the delta — Claude sees it
# either prepended to the next user prompt or appended after the tool result.
set -uo pipefail
export MW_HOOK=monitor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || exit 0
mw_init

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)"
event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null)"

[ -z "$session_id" ] && exit 0
[ -z "$cwd" ] && cwd="$(pwd)"

mw_write_session "$session_id" "$cwd" "$transcript_path" "monitor"
mw_purge_stale  # before scanning, so departed sessions register as "left"

repo_key="$(mw_repo_key "$cwd")"
others_json="$(mw_active_for_repo "$repo_key" "$session_id")"
current_csv="$(printf '%s' "$others_json" | jq -r 'map(.session_id) | sort | join(",")' 2>/dev/null || printf '')"
prev_csv="$(jq -r '.known_others_csv // ""' "$MW_SESSIONS_DIR/$session_id.json" 2>/dev/null || printf '')"

if [ "$current_csv" = "$prev_csv" ]; then
  exit 0
fi

# Persist new baseline immediately so later hook fires don't re-emit.
mw_set_known_others "$session_id" "$current_csv"

prev_sorted="$(printf '%s\n' "$prev_csv" | tr ',' '\n' | sort -u | grep -v '^$' || true)"
cur_sorted="$(printf '%s\n' "$current_csv" | tr ',' '\n' | sort -u | grep -v '^$' || true)"
joined="$(comm -23 <(printf '%s\n' "$cur_sorted") <(printf '%s\n' "$prev_sorted") | grep -v '^$' || true)"
left="$(comm -13 <(printf '%s\n' "$cur_sorted") <(printf '%s\n' "$prev_sorted") | grep -v '^$' || true)"

joined_count=0; left_count=0
[ -n "$joined" ] && joined_count="$(printf '%s\n' "$joined" | wc -l | tr -d ' ')"
[ -n "$left" ] && left_count="$(printf '%s\n' "$left" | wc -l | tr -d ' ')"

joined_block=""
if [ -n "$joined" ]; then
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    if [ -f "$MW_SESSIONS_DIR/$sid.json" ]; then
      line="$(jq -r '"  + joined: session=\(.session_id[0:8]) host=\(.host) pid=\(.pid) cwd=\(.cwd) started=\(.started_at)"' \
        "$MW_SESSIONS_DIR/$sid.json" 2>/dev/null)"
    else
      line="  + joined: session=${sid:0:8}"
    fi
    joined_block="${joined_block}${line}
"
  done <<< "$joined"
fi

left_block=""
if [ -n "$left" ]; then
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    left_block="${left_block}  - left:   session=${sid:0:8}
"
  done <<< "$left"
fi

current_count="$(printf '%s' "$others_json" | jq 'length' 2>/dev/null || printf 0)"
current_block=""
if [ "${current_count:-0}" -gt 0 ]; then
  current_block="$(printf '%s' "$others_json" | jq -r '
    map("    - session=\(.session_id[0:8]) host=\(.host) pid=\(.pid) cwd=\(.cwd) hb=\(.last_heartbeat)") | join("\n")
  ' 2>/dev/null || true)"
fi

ctx="multi-agent-watch UPDATE: registry changed for repo $repo_key
${joined_block}${left_block}  now active: $current_count other session(s)"
[ -n "$current_block" ] && ctx="${ctx}
${current_block}"

{
  printf '\n!! multi-agent-watch: state change\n%s\n\n' "$ctx"
} >&2

notify_short=""
if [ "$joined_count" -gt 0 ] && [ "$left_count" -gt 0 ]; then
  notify_short="${joined_count} joined / ${left_count} left $(basename "$repo_key")"
elif [ "$joined_count" -gt 0 ]; then
  notify_short="${joined_count} session(s) joined $(basename "$repo_key")"
elif [ "$left_count" -gt 0 ]; then
  notify_short="${left_count} session(s) left $(basename "$repo_key")"
fi
[ -n "$notify_short" ] && mw_notify_desktop "Claude Code: multi-agent" "$notify_short"

mw_log "delta event=$event_name repo=$repo_key joined=$joined_count left=$left_count current=$current_count"

jq -n \
  --arg ev "$event_name" \
  --arg ctx "$ctx" \
  '{
    hookSpecificOutput: {
      hookEventName: $ev,
      additionalContext: $ctx
    }
  }'

exit 0
