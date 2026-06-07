#!/usr/bin/env bash
# Removes this session from the registry on graceful exit, /clear, etc.
set -uo pipefail
export MW_HOOK=SessionEnd

# Don't let the detached summarizer's own `claude` recurse into our hooks.
[ -n "${MW_SUMMARY_CHILD:-}" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh" || exit 0
mw_init

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
reason="$(printf '%s' "$input" | jq -r '.reason // ""' 2>/dev/null)"

[ -z "$session_id" ] && exit 0

mw_log "end session=$session_id reason=$reason"
mw_remove_session "$session_id"

exit 0
