#!/usr/bin/env bash
# multi-agent-watch — registry helpers (sourced by hook scripts).
# State is per-machine; override via MW_STATE for cross-host registries.

MW_STATE="${MW_STATE:-$HOME/.claude/state/multi-agent-watch}"
MW_SESSIONS_DIR="$MW_STATE/sessions"
MW_LOG="$MW_STATE/multi-agent-watch.log"
MW_STALE_SEC="${MW_STALE_SEC:-600}"
MW_QUIET="${MW_QUIET:-0}"

mw_init() {
  mkdir -p "$MW_SESSIONS_DIR" 2>/dev/null || true
  : >> "$MW_LOG" 2>/dev/null || true
}

mw_log() {
  printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${MW_HOOK:-?}" "$*" \
    >> "$MW_LOG" 2>/dev/null || true
}

mw_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
mw_now_epoch() { date -u '+%s'; }

# Repo identity: prefer git toplevel so subdirs of one repo collapse to one key.
mw_repo_key() {
  local cwd="$1" top
  if top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$top"
    return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$cwd" 2>/dev/null || printf '%s' "$cwd"
  else
    printf '%s' "$cwd"
  fi
}

mw_purge_stale() {
  local now stale_threshold hb f
  now="$(mw_now_epoch)"
  stale_threshold=$((now - MW_STALE_SEC))
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    if ! hb="$(jq -r '.last_heartbeat_epoch // 0' "$f" 2>/dev/null)"; then
      mw_log "purge unparseable: $f"
      rm -f "$f"
      continue
    fi
    case "$hb" in
      ''|*[!0-9]*)
        mw_log "purge non-numeric hb: $f"
        rm -f "$f"
        ;;
      *)
        if [ "$hb" -lt "$stale_threshold" ]; then
          mw_log "purge stale: $f hb=$hb threshold=$stale_threshold"
          rm -f "$f"
        fi
        ;;
    esac
  done
  shopt -u nullglob
}

# Print JSON array of registered sessions matching repo_key, excluding session_id ($2).
mw_active_for_repo() {
  local repo_key="$1" exclude_session="${2:-}"
  local out='[]' entry f
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    if ! entry="$(jq -ec --arg key "$repo_key" --arg excl "$exclude_session" \
        'select(.repo_key == $key) | select(.session_id != $excl)' "$f" 2>/dev/null)"; then
      continue
    fi
    [ -z "$entry" ] && continue
    out="$(jq -nc --argjson cur "$out" --argjson new "$entry" '$cur + [$new]' 2>/dev/null || printf '%s' "$out")"
  done
  shopt -u nullglob
  printf '%s' "$out"
}

mw_write_session() {
  local session_id="$1" cwd="$2" transcript="$3" source="$4"
  local repo_key file now now_epoch started host user
  local known_csv="" known_at=""
  repo_key="$(mw_repo_key "$cwd")"
  file="$MW_SESSIONS_DIR/$session_id.json"
  now="$(mw_now)"
  now_epoch="$(mw_now_epoch)"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  user="$(id -un 2>/dev/null || echo unknown)"
  if [ -f "$file" ]; then
    started="$(jq -r '.started_at // ""' "$file" 2>/dev/null || true)"
    known_csv="$(jq -r '.known_others_csv // ""' "$file" 2>/dev/null || true)"
    known_at="$(jq -r '.known_others_at // ""' "$file" 2>/dev/null || true)"
  fi
  [ -z "${started:-}" ] && started="$now"
  jq -n \
    --arg sid "$session_id" \
    --arg cwd "$cwd" \
    --arg key "$repo_key" \
    --argjson pid "$$" \
    --argjson ppid "$PPID" \
    --arg host "$host" \
    --arg user "$user" \
    --arg tt "$transcript" \
    --arg src "$source" \
    --arg started "$started" \
    --arg now "$now" \
    --argjson now_epoch "$now_epoch" \
    --arg known_csv "$known_csv" \
    --arg known_at "$known_at" \
    '{
      session_id: $sid,
      cwd: $cwd,
      repo_key: $key,
      pid: $pid,
      ppid: $ppid,
      host: $host,
      user: $user,
      transcript_path: $tt,
      source: $src,
      started_at: $started,
      last_heartbeat: $now,
      last_heartbeat_epoch: $now_epoch,
      known_others_csv: $known_csv,
      known_others_at: $known_at
    }' > "$file" 2>/dev/null || true
}

# Update only the known_others_csv / known_others_at fields, preserving the rest.
mw_set_known_others() {
  local session_id="$1" csv="$2"
  local file="$MW_SESSIONS_DIR/$session_id.json"
  [ -f "$file" ] || return 0
  local tmp="$file.tmp.$$"
  if jq --arg csv "$csv" --arg now "$(mw_now)" \
      '. + {known_others_csv: $csv, known_others_at: $now}' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

mw_remove_session() {
  rm -f "$MW_SESSIONS_DIR/$1.json"
}

mw_notify_desktop() {
  [ "$MW_QUIET" = "1" ] && return 0
  local title="$1" message="$2"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$message" -group multi-agent-watch \
      >/dev/null 2>&1 || true
  elif [ "$(uname -s)" = "Darwin" ]; then
    osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
      >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$message" >/dev/null 2>&1 || true
  fi
}
