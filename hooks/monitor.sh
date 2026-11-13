#!/usr/bin/env bash
# Heartbeat + change-detection + watch-ping delivery. Wired to UserPromptSubmit
# and PostToolUse. On each fire it:
#   1. refreshes our heartbeat and purges stale entries,
#   2. drains any /mw-watch pings addressed to us and injects them,
#   3. compares the current set of OTHER sessions to the set we last reported
#      and, when it changed, injects the delta plus each sibling's self-summary
#      and native name (what Claude Code's SendMessage addresses it by).
# Summaries are GENERATED only when someone runs /mw-status (read-time, cached);
# this hook just reads whatever siblings' entries currently hold.
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

# --- watch pings addressed to us (checked every fire, independent of roster) ---
msg_block="$(mw_drain_inbox "$session_id")"
msg_count=0
[ -n "$msg_block" ] && msg_count="$(printf '%s\n' "$msg_block" | grep -c '✉' || printf 0)"

repo_key="$(mw_repo_key "$cwd")"
others_json="$(mw_active_for_repo "$repo_key" "$session_id")"
current_csv="$(printf '%s' "$others_json" | jq -r 'map(.session_id) | sort | join(",")' 2>/dev/null || printf '')"
prev_csv="$(jq -r '.known_others_csv // ""' "$MW_SESSIONS_DIR/$session_id.json" 2>/dev/null || printf '')"

roster_changed=0
[ "$current_csv" != "$prev_csv" ] && roster_changed=1

# Nothing new to report (roster unchanged AND no pings) -> stay quiet.
if [ "$roster_changed" -eq 0 ] && [ -z "$msg_block" ]; then
  exit 0
fi

delta_block=""
joined_count=0; left_count=0
if [ "$roster_changed" -eq 1 ]; then
  # Persist new baseline immediately so later hook fires don't re-emit.
  mw_set_known_others "$session_id" "$current_csv"

  prev_sorted="$(printf '%s\n' "$prev_csv" | tr ',' '\n' | sort -u | grep -v '^$' || true)"
  cur_sorted="$(printf '%s\n' "$current_csv" | tr ',' '\n' | sort -u | grep -v '^$' || true)"
  joined="$(comm -23 <(printf '%s\n' "$cur_sorted") <(printf '%s\n' "$prev_sorted") | grep -v '^$' || true)"
  left="$(comm -13 <(printf '%s\n' "$cur_sorted") <(printf '%s\n' "$prev_sorted") | grep -v '^$' || true)"

  [ -n "$joined" ] && joined_count="$(printf '%s\n' "$joined" | wc -l | tr -d ' ')"
  [ -n "$left" ] && left_count="$(printf '%s\n' "$left" | wc -l | tr -d ' ')"

  named_json="$(printf '%s' "$others_json" | mw_add_native_names 2>/dev/null)" || named_json="$others_json"

  joined_block=""
  if [ -n "$joined" ]; then
    while IFS= read -r sid; do
      [ -z "$sid" ] && continue
      line="$(printf '%s' "$named_json" | jq -r --arg s "$sid" '.[] | select(.session_id == $s)
        | "  + joined: session=\(.session_id[0:8])"
          + (if (.native_name // "") != "" then " name=\(.native_name)" else "" end)
          + (if (.native_status // "") != "" then " [\(.native_status)]" else "" end)
          + " host=\(.host) pid=\(.pid) cwd=\(.cwd) started=\(.started_at)"
          + (if (.summary // "") != "" then "\n      doing: \(.summary)" else "" end)' 2>/dev/null)"
      [ -z "$line" ] && line="  + joined: session=${sid:0:8}"
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
    current_block="$(printf '%s' "$named_json" | jq -r '
      map("    - session=\(.session_id[0:8])"
          + (if (.native_name // "") != "" then " name=\(.native_name)" else "" end)
          + (if (.native_status // "") != "" then " [\(.native_status)]" else "" end)
          + " host=\(.host) pid=\(.pid) cwd=\(.cwd) hb=\(.last_heartbeat)"
          + (if (.summary // "") != "" then "\n        doing: \(.summary)" else "" end)) | join("\n")
    ' 2>/dev/null || true)"
  fi

  delta_block="multi-agent-watch UPDATE: registry changed for repo $repo_key
${joined_block}${left_block}  now active: $current_count other session(s)"
  [ -n "$current_block" ] && delta_block="${delta_block}
${current_block}"
  if printf '%s' "$named_json" | jq -e 'any(.[]; (.native_name // "") != "")' >/dev/null 2>&1; then
    delta_block="${delta_block}
  To coordinate with a sibling, message it with the SendMessage tool, addressed by its name=."
  fi
fi

# --- assemble injected context ---
ctx=""
if [ -n "$msg_block" ]; then
  ctx="multi-agent-watch: $msg_count watch notification(s) for you:
${msg_block%$'\n'}"
fi
if [ -n "$delta_block" ]; then
  if [ -n "$ctx" ]; then ctx="${ctx}

${delta_block}"; else ctx="$delta_block"; fi
fi

{
  printf '\n!! multi-agent-watch: %s\n%s\n\n' \
    "$([ -n "$msg_block" ] && printf 'watch notification(s) + ' ; printf 'state')" "$ctx"
} >&2

notify_short=""
if [ "$msg_count" -gt 0 ]; then
  notify_short="${msg_count} watch notification(s) on $(basename "$repo_key")"
elif [ "$joined_count" -gt 0 ] && [ "$left_count" -gt 0 ]; then
  notify_short="${joined_count} joined / ${left_count} left $(basename "$repo_key")"
elif [ "$joined_count" -gt 0 ]; then
  notify_short="${joined_count} session(s) joined $(basename "$repo_key")"
elif [ "$left_count" -gt 0 ]; then
  notify_short="${left_count} session(s) left $(basename "$repo_key")"
fi
[ -n "$notify_short" ] && mw_notify_desktop "Claude Code: multi-agent" "$notify_short"

mw_log "monitor event=$event_name repo=$repo_key pings=$msg_count joined=$joined_count left=$left_count roster_changed=$roster_changed"

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
