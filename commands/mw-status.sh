#!/usr/bin/env bash
# Renders a human-readable summary of the session registry, grouped by repo,
# flagging repos with more than one active session as COLLISION.
set -uo pipefail
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

jq -s '
  group_by(.repo_key)
  | map({
      repo: .[0].repo_key,
      count: length,
      sessions: map({
        session_id: ((.session_id // "?")[0:8]),
        cwd: .cwd,
        host: .host,
        pid: .pid,
        started_at: .started_at,
        last_heartbeat: .last_heartbeat,
        summary: (.summary // "")
      })
    })
  | sort_by(-.count)
' "${files[@]}" | jq -r '
  .[] |
  (if .count > 1 then "!! COLLISION" else "ok           " end) as $marker |
  "\($marker) [\(.count)] \(.repo)\n" +
  (.sessions | map("    - \(.session_id) host=\(.host) pid=\(.pid) cwd=\(.cwd) hb=\(.last_heartbeat)"
     + (if .summary != "" then "\n        doing: \(.summary)" else "\n        doing: (no summary yet)" end)) | join("\n"))
'

# Pending (undelivered) messages, grouped by recipient.
shopt -s nullglob
pending=("$MW_MESSAGES_DIR"/*/*.json)
shopt -u nullglob
if [ ${#pending[@]} -gt 0 ]; then
  echo
  echo "pending messages (not yet delivered):"
  for d in "$MW_MESSAGES_DIR"/*/; do
    [ -d "$d" ] || continue
    shopt -s nullglob
    m=("$d"*.json)
    shopt -u nullglob
    [ ${#m[@]} -eq 0 ] && continue
    rid="$(basename "$d")"
    echo "    → ${rid:0:8}: ${#m[@]} message(s) waiting"
  done
fi
