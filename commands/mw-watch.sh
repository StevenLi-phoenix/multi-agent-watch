#!/usr/bin/env bash
# Subscribe to another Claude Code session on this repo. While subscribed, you
# get a message (delivered by your monitor hook) when the watched session
# changes its self-summary or ends. Subscriptions auto-clear on SessionEnd.
#
#   mw-watch.sh <session-id-prefix>   subscribe to a session
#   mw-watch.sh --list                show who you're watching
#   mw-watch.sh --stop <prefix>       unsubscribe
#
# Args may arrive as one quoted blob (slash command) or separate (Bash tool);
# both are handled. Watch targets are plain session-id tokens, so no globbing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || { echo "mw-watch: cannot load registry lib" >&2; exit 1; }
mw_init
mw_purge_stale

self="${CLAUDE_CODE_SESSION_ID:-unknown}"

# Normalize args into a token vector (handles the single-blob slash form).
args=()
if [ "$#" -eq 1 ]; then
  # split the one blob on whitespace, no globbing
  set -f
  # shellcheck disable=SC2206
  args=($1)
  set +f
else
  args=("$@")
fi
cmd="${args[0]:-}"

list_watching() {
  echo "you (${self:0:8}) are watching:"
  local f found=0
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    if jq -e --arg w "$self" '((.watchers // []) | index($w)) != null' "$f" >/dev/null 2>&1; then
      jq -r '"  \(.session_id[0:8])  doing: \(if (.summary // "")=="" then "(no summary yet)" else .summary end)"' "$f"
      found=1
    fi
  done
  shopt -u nullglob
  [ "$found" -eq 0 ] && echo "  (none — subscribe with: mw-watch <session-id-prefix>)"
}

list_targets() {
  echo "active sessions you can watch:" >&2
  shopt -s nullglob
  local f
  for f in "$MW_SESSIONS_DIR"/*.json; do
    jq -r '"  \(.session_id[0:8])  cwd=\(.cwd)" + (if (.summary // "")!="" then "  doing: \(.summary)" else "" end)' "$f" 2>/dev/null
  done
  shopt -u nullglob
}

case "$cmd" in
  --list|"")
    list_watching
    ;;
  --stop|--unwatch)
    spec="${args[1]:-}"
    if [ -z "$spec" ]; then echo "usage: mw-watch --stop <session-id-prefix>" >&2; exit 1; fi
    n=0
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      mw_remove_watch "$self" "$t" && { echo "✗ unsubscribed from ${t:0:8}"; n=$((n+1)); }
    done < <(mw_resolve_sids "$spec" "" "$self")
    [ "$n" -eq 0 ] && echo "mw-watch: no matching session for '$spec'"
    ;;
  *)
    n=0
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      if mw_add_watch "$self" "$t"; then
        echo "👁  subscribed to ${t:0:8} — you'll be pinged when it updates its summary or ends"
        n=$((n+1))
      fi
    done < <(mw_resolve_sids "$cmd" "" "$self")
    if [ "$n" -eq 0 ]; then
      echo "mw-watch: no matching active session for '$cmd'" >&2
      list_targets
      exit 1
    fi
    ;;
esac
exit 0
