#!/usr/bin/env bash
# Refreshes this session's last_heartbeat timestamp so it isn't auto-purged.
# Wired to UserPromptSubmit + Stop.
set -uo pipefail
export MW_HOOK=heartbeat

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

[ -z "$session_id" ] && exit 0
[ -z "$cwd" ] && cwd="$(pwd)"

mw_write_session "$session_id" "$cwd" "$transcript_path" "heartbeat"
mw_purge_stale

exit 0
