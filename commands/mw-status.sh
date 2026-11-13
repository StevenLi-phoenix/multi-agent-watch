#!/usr/bin/env bash
# Renders a human-readable summary of the session registry, grouped by repo,
# flagging repos with more than one active session as COLLISION. This read is
# also the ONLY place self-summaries get generated: stale ones are refreshed
# (in parallel, 15-minute cache) right before rendering.
set -uo pipefail
export MW_HOOK=mw-status
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh"
mw_init
mw_purge_stale

shopt -s nullglob
files=("$MW_SESSIONS_DIR"/*.json)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "no active Claude Code sessions registered"
  exit 0
fi

tally="$(mw_refresh_summaries)"

jq -s '.' "${files[@]}" | mw_add_native_names | jq '
  group_by(.repo_key)
  | map({
      repo: .[0].repo_key,
      count: length,
      sessions: map({
        session_id: ((.session_id // "?")[0:8]),
        native_name: (.native_name // ""),
        native_status: (.native_status // ""),
        cwd: .cwd,
        host: .host,
        pid: .pid,
        started_at: .started_at,
        last_heartbeat: .last_heartbeat,
        summary: (.summary // ""),
        summary_at: (.summary_at // ""),
        watchers: ((.watchers // []) | length)
      })
    })
  | sort_by(-.count)
' | jq -r '
  def ago: if . == "" then "" else
      (((now - (. | fromdateiso8601)) / 60) | floor) as $m
      | if $m < 1 then "just now" elif $m < 60 then "\($m)m ago" else "\($m / 60 | floor)h ago" end
    end;
  .[] |
  (if .count > 1 then "!! COLLISION" else "ok           " end) as $marker |
  "\($marker) [\(.count)] \(.repo)\n" +
  (.sessions | map("    - \(.session_id)"
     + (if .native_name != "" then " name=\(.native_name)" else "" end)
     + (if .native_status != "" then " [\(.native_status)]" else "" end)
     + " host=\(.host) pid=\(.pid) cwd=\(.cwd) hb=\(.last_heartbeat)"
     + (if .watchers > 0 then " (watched by \(.watchers))" else "" end)
     + (if .summary != "" then "\n        doing (\(.summary_at | ago)): \(.summary)" else "\n        doing: (no summary yet)" end)) | join("\n"))
'

# Pending (undelivered) /mw-watch pings, grouped by recipient.
shopt -s nullglob
pending=("$MW_MESSAGES_DIR"/*/*.json)
shopt -u nullglob
if [ ${#pending[@]} -gt 0 ]; then
  echo
  echo "pending watch notifications (not yet delivered):"
  for d in "$MW_MESSAGES_DIR"/*/; do
    [ -d "$d" ] || continue
    shopt -s nullglob
    m=("$d"*.json)
    shopt -u nullglob
    [ ${#m[@]} -eq 0 ] && continue
    rid="$(basename "$d")"
    if [ -f "$MW_SESSIONS_DIR/$rid.json" ]; then
      echo "    → ${rid:0:8}: ${#m[@]} notification(s) waiting"
    else
      echo "    → ${rid:0:8}: ${#m[@]} notification(s) waiting — recipient not registered (dropped $((MW_INBOX_TTL / 3600))h after the last message unless it comes back)"
    fi
  done
fi

echo
echo "summaries: $MW_SUMMARY_MODEL @ $(mw_summary_host) · key: $(mw_summary_key_source) · cache $((MW_SUMMARY_PERIOD / 60))m · ${tally:-nothing to do}"
case "$tally" in
  *no-key*) echo "    (no summary key — set MW_SUMMARY_API_KEY or OPENROUTER_API_KEY in the env Claude Code starts from)" ;;
esac
case "$tally" in
  *failed*) echo "    (some summary calls failed — see $MW_LOG)" ;;
esac
