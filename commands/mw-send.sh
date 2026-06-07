#!/usr/bin/env bash
# Leave a message for another active Claude Code session on this repo. The
# recipient's monitor hook delivers it (and deletes it) on their next prompt or
# tool use.
#
#   mw-send.sh <session-id-prefix | all> <message...>
#
# Sender identity comes from $CLAUDE_CODE_SESSION_ID when available, so `all`
# excludes yourself and recipients see who it's from.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || { echo "mw-send: cannot load registry lib" >&2; exit 1; }
mw_init
mw_purge_stale

# Accept two calling shapes:
#   - separate args:  mw-send.sh <to> <message words...>   (direct / Bash tool)
#   - one blob arg:   mw-send.sh "<to> <message...>"        (slash command, where
#     the .md wraps "$ARGUMENTS" in quotes so zsh won't glob/split the message —
#     non-ASCII and glob chars like * ? [ no longer trigger `no matches found`).
# In the blob case we split recipient (first token) from message here, in-script.
to_spec=""
text=""
if [ "$#" -ge 2 ]; then
  to_spec="$1"; shift; text="$*"
elif [ "$#" -eq 1 ]; then
  to_spec="${1%%[[:space:]]*}"
  case "$1" in
    *[[:space:]]*) text="${1#*[[:space:]]}" ;;
    *) text="" ;;
  esac
fi
from_sid="${CLAUDE_CODE_SESSION_ID:-unknown}"
from_cwd="$(pwd)"
repo_key="$(mw_repo_key "$from_cwd")"

list_recipients() {
  echo "active sessions you can message:" >&2
  shopt -s nullglob
  local f
  for f in "$MW_SESSIONS_DIR"/*.json; do
    jq -r '"  \(.session_id[0:8])  cwd=\(.cwd)" + (if (.summary // "") != "" then "  doing: \(.summary)" else "" end)' \
      "$f" 2>/dev/null
  done
  shopt -u nullglob
}

if [ -z "$to_spec" ] || [ -z "$text" ]; then
  echo "usage: mw-send <session-id-prefix | all> <message...>" >&2
  list_recipients
  exit 1
fi

# Resolve recipients.
targets=()
if [ "$to_spec" = "all" ]; then
  while IFS= read -r line; do [ -n "$line" ] && targets+=("$line"); done \
    < <(mw_resolve_sids all "$repo_key" "$from_sid")
else
  while IFS= read -r line; do [ -n "$line" ] && targets+=("$line"); done \
    < <(mw_resolve_sids "$to_spec" "" "$from_sid")
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "mw-send: no matching active session for '$to_spec'" >&2
  list_recipients
  exit 1
fi

n=0
for t in "${targets[@]}"; do
  [ -z "$t" ] && continue
  if mw_send_message "$t" "$from_sid" "$from_cwd" "$text"; then
    echo "→ queued for ${t:0:8}"
    n=$((n+1))
  else
    echo "mw-send: failed to queue for ${t:0:8}" >&2
  fi
done

echo "mw-send: delivered to $n session(s); they'll see it on their next prompt or tool use."
exit 0
