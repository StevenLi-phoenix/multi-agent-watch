#!/usr/bin/env bash
# Fires when a Claude Code session starts. Registers this session and warns
# (banner + desktop notification + injected context) if other sessions are
# already active on the same git repo.
#
# Weight matters here: SessionStart hooks run in parallel and Claude Code waits for the
# slowest one. Keep this to a handful of jq calls and no per-session forks: one jq reads
# the stdin fields, one reads every heartbeat, one writes our entry, one scans the roster,
# one joins native names, one builds banner + context + baseline, one stores the baseline.
set -uo pipefail
export MW_HOOK=SessionStart

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || exit 0
mw_init
mw_tick   # one `date` fork; mw_log / mw_write_session / mw_purge_stale reuse it

input="$(cat)"
session_id="" cwd="" transcript_path="" source_field="startup"
eval "$(printf '%s' "$input" | jq -r '@sh "session_id=\(.session_id // "") cwd=\(.cwd // "") transcript_path=\(.transcript_path // "") source_field=\(.source // "startup")"' 2>/dev/null)"

[ -z "$cwd" ] && cwd="$(pwd)"
if [ -z "$session_id" ]; then
  mw_log "no session_id in stdin; bailing"
  exit 0
fi

mw_log "start session=$session_id cwd=$cwd source=$source_field"
mw_purge_stale

repo_key="$(mw_repo_key "$cwd")"
# Write our entry first; if two sessions race, both writes land before either
# scans, so each correctly sees the other.
mw_write_session "$session_id" "$cwd" "$transcript_path" "$source_field" "$repo_key"

others_json="$(mw_active_for_repo "$repo_key" "$session_id")"
baseline_csv=""

if [ -n "$others_json" ] && [ "$others_json" != "[]" ]; then
  named_json="$(printf '%s' "$others_json" | mw_add_native_names 2>/dev/null)" || named_json="$others_json"
  others_count=0 short="" summary="" final="" csv=""
  # Everything the banner, the injected context and the baseline need, in one jq.
  # Strings come back @sh-quoted so one eval assigns them safely.
  eval "$(printf '%s' "$named_json" | jq -r --arg key "$repo_key" --arg base "${repo_key##*/}" '
    def roster:
      map("  - session=\(.session_id[0:8])"
          + (if (.native_name // "") != "" then " name=\(.native_name)" else "" end)
          + (if (.native_status // "") != "" then " [\(.native_status)]" else "" end)
          + " host=\(.host) pid=\(.pid) cwd=\(.cwd) started=\(.started_at) hb=\(.last_heartbeat)"
          + (if (.summary // "") != "" then "\n      doing: \(.summary)" else "" end))
      | join("\n");
    length as $n
    | roster as $summary
    | "\($n) other Claude Code session(s) active on \($base)" as $short
    | ("multi-agent-watch: \($n) other Claude Code session(s) are concurrently active in this repository (\($key)).\n\nCoordination workflow — do NOT all pile into the same working directory:\n  1. ISOLATE (preferred): give each session its own git worktree — `git worktree add ../<name> -b <branch>` — so concurrent edits never touch the same files. This is the clean fix when everything feels chaotic.\n  2. SHARED-DIR fallback: if you stay in this directory, make additive edits only, never overwrite a file another session is mid-change on, and run `git status` before any broad refactor.\n  3. Commit or stash work-in-progress BEFORE restoring/overwriting any file — another session may have touched it.\n  4. TALK: to coordinate with a sibling, message it with the SendMessage tool, addressed by its name= below.\n\nActive sessions:\n\($summary)") as $context
    | {systemMessage: "multi-agent-watch: \($short) — see stderr for details",
       hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}} as $final
    | @sh "others_count=\($n) short=\($short) summary=\($summary) csv=\(map(.session_id) | sort | join(",")) final=\($final | tojson)"
  ' 2>/dev/null)"
  baseline_csv="$csv"

  if [ "${others_count:-0}" -gt 0 ]; then
    {
      printf '\n'
      printf '!! multi-agent-watch: collision detected\n'
      printf '   repo:  %s\n' "$repo_key"
      printf '   other active sessions (%s):\n' "$others_count"
      printf '%s\n' "$summary"
      printf '\n'
    } >&2

    mw_notify_desktop "Claude Code: multi-agent collision" "$short"   # async

    printf '%s\n' "$final"
  fi
fi

# Establish baseline so monitor.sh only fires on subsequent CHANGES.
mw_set_known_others "$session_id" "$baseline_csv"

exit 0
