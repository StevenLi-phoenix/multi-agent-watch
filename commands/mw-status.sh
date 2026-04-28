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
        last_heartbeat: .last_heartbeat
      })
    })
  | sort_by(-.count)
' "${files[@]}" | jq -r '
  .[] |
  (if .count > 1 then "!! COLLISION" else "ok           " end) as $marker |
  "\($marker) [\(.count)] \(.repo)\n" +
  (.sessions | map("    - \(.session_id) host=\(.host) pid=\(.pid) cwd=\(.cwd) hb=\(.last_heartbeat)") | join("\n"))
'
