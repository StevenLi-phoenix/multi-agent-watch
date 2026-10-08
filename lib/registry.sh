#!/usr/bin/env bash
# multi-agent-watch — registry helpers (sourced by hook scripts).
# State is per-machine; override via MW_STATE for cross-host registries.

MW_STATE="${MW_STATE:-$HOME/.claude/state/multi-agent-watch}"
MW_SESSIONS_DIR="$MW_STATE/sessions"
MW_MESSAGES_DIR="$MW_STATE/messages"
MW_LOCKS_DIR="$MW_STATE/locks"
MW_LOG="$MW_STATE/multi-agent-watch.log"
MW_STALE_SEC="${MW_STALE_SEC:-600}"
# An inbox whose recipient is no longer registered is dropped once its newest
# message is older than this (24h). The grace period keeps mail for a session
# that was stale-purged while idle (or resumed) and re-registers under its id.
MW_INBOX_TTL="${MW_INBOX_TTL:-86400}"
MW_QUIET="${MW_QUIET:-0}"

# Session self-summary (so sibling sessions learn what each other is doing).
# Generated ON READ — only when /mw-status runs — via one OpenRouter call per
# stale session (key: $OPENROUTER_API_KEY). Nothing runs on Stop or in the
# background.
MW_SUMMARY_MODEL="${MW_SUMMARY_MODEL:-deepseek/deepseek-v4.1-flash}"
MW_SUMMARY_TIMEOUT="${MW_SUMMARY_TIMEOUT:-20}"
# Cache: a summary younger than this many seconds (15 min) is reused as-is.
# Past that it is regenerated only if the session's transcript changed since.
# MW_SUMMARY_REFRESH=1 forces a regeneration regardless.
MW_SUMMARY_PERIOD="${MW_SUMMARY_PERIOD:-900}"
MW_OPENROUTER_URL="${MW_OPENROUTER_URL:-https://openrouter.ai/api/v1/chat/completions}"
MW_SUMMARIES_DIR="$MW_STATE/summaries"   # raw API response per session

mw_init() {
  mkdir -p "$MW_SESSIONS_DIR" "$MW_MESSAGES_DIR" "$MW_LOCKS_DIR" "$MW_SUMMARIES_DIR" 2>/dev/null || true
  : >> "$MW_LOG" 2>/dev/null || true
}

# Atomically replace $1 with content read from stdin (write tmp + rename).
# Rename is atomic within a filesystem, so a concurrent reader/purger never
# observes a half-written file.
mw_atomic_write() {
  local dest="$1" tmp="$1.tmp.$$.${RANDOM:-0}"
  if cat > "$tmp" 2>/dev/null; then
    if mv -f "$tmp" "$dest" 2>/dev/null; then return 0; fi
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
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

# File mtime as epoch seconds (GNU `stat -c`, macOS `stat -f`, else now).
# GNU goes first: GNU `stat -f` is "filesystem status" and exits 0 with junk,
# which broke arithmetic when coreutils' gnubin shadows /usr/bin/stat.
mw_file_mtime() {
  local m
  m="$(stat -c '%Y' "$1" 2>/dev/null)" || m="$(stat -f '%m' "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) mw_now_epoch ;; *) printf '%s' "$m" ;; esac
}

mw_purge_stale() {
  local now stale_threshold hb f mtime
  now="$(mw_now_epoch)"
  stale_threshold=$((now - MW_STALE_SEC))
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    hb="$(jq -r '.last_heartbeat_epoch // ""' "$f" 2>/dev/null || printf '')"
    case "$hb" in
      ''|*[!0-9]*)
        # Unparseable or missing heartbeat. This can be a genuinely corrupt
        # file OR a file caught mid-write by a racing writer. Only delete it if
        # it's also OLD on disk — a fresh one is almost certainly mid-write and
        # will be valid a moment later. (Atomic writes make this rare; this is
        # the belt to that suspenders.)
        mtime="$(mw_file_mtime "$f")"
        if [ $((now - mtime)) -gt "$MW_STALE_SEC" ]; then
          mw_log "purge corrupt (old): $f"
          mw_remove_session "$(basename "$f" .json)"
        else
          mw_log "skip corrupt (fresh, likely mid-write): $f"
        fi
        ;;
      *)
        if [ "$hb" -lt "$stale_threshold" ]; then
          mw_log "purge stale: $f hb=$hb threshold=$stale_threshold"
          mw_remove_session "$(basename "$f" .json)"  # notifies watchers it ended
        fi
        ;;
    esac
  done
  shopt -u nullglob
  mw_purge_orphan_inboxes
}

# Drop inboxes of recipients that are no longer registered once their newest
# message is older than MW_INBOX_TTL (empty leftover dirs go immediately).
mw_purge_orphan_inboxes() {
  local now d sid f m newest cnt
  now="$(mw_now_epoch)"
  shopt -s nullglob
  for d in "$MW_MESSAGES_DIR"/*/; do
    sid="$(basename "$d")"
    [ -f "$MW_SESSIONS_DIR/$sid.json" ] && continue
    newest=0; cnt=0
    for f in "$d"*.json; do
      m="$(mw_file_mtime "$f")"
      [ "$m" -gt "$newest" ] && newest="$m"
      cnt=$((cnt+1))
    done
    if [ $((now - newest)) -gt "$MW_INBOX_TTL" ]; then
      rm -rf "$d"
      mw_log "purge orphan inbox: $sid ($cnt undelivered message(s), recipient gone)"
    fi
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
  local repo_key file now now_epoch started host user base
  repo_key="$(mw_repo_key "$cwd")"
  file="$MW_SESSIONS_DIR/$session_id.json"
  now="$(mw_now)"
  now_epoch="$(mw_now_epoch)"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  user="$(id -un 2>/dev/null || echo unknown)"
  # Merge onto the existing entry so fields written by other functions
  # (summary, known_others_*, and anything added later) are preserved. Rebuild
  # from {} only when there's no parseable prior entry.
  base="$(jq -c '.' "$file" 2>/dev/null)" || base=""
  [ -z "$base" ] && base='{}'
  started="$(printf '%s' "$base" | jq -r '.started_at // ""' 2>/dev/null || true)"
  [ -z "${started:-}" ] && started="$now"
  printf '%s' "$base" | jq \
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
    '. + {
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
      last_heartbeat_epoch: $now_epoch
    }' 2>/dev/null | mw_atomic_write "$file" || true
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
  local sid="$1"
  mw_notify_watchers "$sid" "ended" "session closed — its files may be mid-change"
  mw_unwatch_all "$sid"   # this session is no longer watching anyone
  rm -f "$MW_SESSIONS_DIR/$sid.json" "$MW_SUMMARIES_DIR/$sid.json"
}

# ---------------------------------------------------------------------------
# Inter-session messaging ("留言"): leave a note for another live session.
# One file per message under messages/<recipient_full_sid>/, drained (and
# deleted) by the recipient's monitor hook on its next prompt / tool use.
# ---------------------------------------------------------------------------

mw_inbox_dir() { printf '%s/%s' "$MW_MESSAGES_DIR" "$1"; }

# Resolve a recipient spec to full session_ids, one per line.
#   spec="all"  -> every registered session; if $2 (repo_key) is non-empty,
#                  restricted to that repo. $3 (exclude sid) is dropped.
#   spec=<pfx>  -> sessions whose id starts with <pfx> (repo_key ignored).
mw_resolve_sids() {
  local spec="$1" repo_key="${2:-}" exclude="${3:-}" f sid rk
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    sid="$(basename "$f" .json)"
    [ -n "$exclude" ] && [ "$sid" = "$exclude" ] && continue
    if [ "$spec" = "all" ]; then
      if [ -n "$repo_key" ]; then
        rk="$(jq -r '.repo_key // ""' "$f" 2>/dev/null || printf '')"
        [ "$rk" = "$repo_key" ] || continue
      fi
      printf '%s\n' "$sid"
    else
      case "$sid" in "$spec"*) printf '%s\n' "$sid" ;; esac
    fi
  done
  shopt -u nullglob
}

# Queue one message for a recipient session id. Returns non-zero on failure.
mw_send_message() {
  local to_sid="$1" from_sid="$2" from_cwd="$3" text="$4"
  local dir file
  dir="$(mw_inbox_dir "$to_sid")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$dir/$(mw_now_epoch)-${from_sid:0:8}-$$.${RANDOM:-0}.json"
  jq -n \
    --arg from "$from_sid" \
    --arg fc "$from_cwd" \
    --arg text "$text" \
    --arg ts "$(mw_now)" \
    --argjson te "$(mw_now_epoch)" \
    '{from:$from, from_cwd:$fc, text:$text, ts:$ts, ts_epoch:$te}' 2>/dev/null \
    | mw_atomic_write "$file"
}

# Number of undelivered messages waiting for a session id.
mw_inbox_count() {
  local dir m
  dir="$(mw_inbox_dir "$1")"
  shopt -s nullglob
  m=("$dir"/*.json)
  shopt -u nullglob
  printf '%s' "${#m[@]}"
}

# Print a formatted block of a session's unread messages (oldest first), then
# delete exactly the files read. Empty output (and rc 0) when the inbox is empty.
mw_drain_inbox() {
  local sid="$1" dir f line block="" cnt=0
  dir="$(mw_inbox_dir "$sid")"
  [ -d "$dir" ] || return 0
  shopt -s nullglob
  local files=("$dir"/*.json)
  shopt -u nullglob
  [ ${#files[@]} -eq 0 ] && return 0
  local sorted=()
  while IFS= read -r f; do [ -n "$f" ] && sorted+=("$f"); done \
    < <(printf '%s\n' "${files[@]}" | sort)
  for f in "${sorted[@]}"; do
    line="$(jq -r '"  ✉ from \(.from[0:8]) at \(.ts) (cwd \(.from_cwd)):\n      \(.text)"' "$f" 2>/dev/null)" || { rm -f "$f"; continue; }
    [ -z "$line" ] && { rm -f "$f"; continue; }
    block="${block}${line}
"
    cnt=$((cnt+1))
    rm -f "$f"
  done
  # Drop the inbox dir if we emptied it (keeps messages/ tidy).
  rmdir "$dir" 2>/dev/null || true
  [ "$cnt" -gt 0 ] && printf '%s' "$block"
  return 0
}

# ---------------------------------------------------------------------------
# Self-summary: a one-line "what this session is doing", generated ON READ.
# /mw-status calls mw_refresh_summaries, which re-summarizes (in parallel) every
# session whose cached summary is missing or stale. Observers elsewhere (banner,
# monitor) just read the stored field.
# ---------------------------------------------------------------------------

mw_summary_value() {
  jq -r '.summary // ""' "$MW_SESSIONS_DIR/$1.json" 2>/dev/null || printf ''
}

# Epoch seconds of the stored summary_at, or empty if never summarized.
mw_summary_at_epoch() {
  local iso
  iso="$(jq -r '.summary_at // ""' "$MW_SESSIONS_DIR/$1.json" 2>/dev/null)"
  [ -z "$iso" ] && return 0
  # macOS/BSD date first, then GNU date.
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
    || date -u -d "$iso" '+%s' 2>/dev/null || printf ''
}

mw_set_summary() {
  local sid="$1" text="$2" file="$MW_SESSIONS_DIR/$1.json"
  [ -f "$file" ] || return 0
  jq --arg s "$text" --arg now "$(mw_now)" \
     '. + {summary:$s, summary_at:$now}' "$file" 2>/dev/null \
     | mw_atomic_write "$file"
}

# Once-only guard. mkdir is atomic across processes: the first caller wins
# (rc 0), everyone else gets rc 1. Used so two concurrent /mw-status reads
# never pay for the same session twice.
mw_try_lock() {
  mkdir -p "$MW_LOCKS_DIR" 2>/dev/null || true
  mkdir "$MW_LOCKS_DIR/$1" 2>/dev/null
}
mw_unlock() { rmdir "$MW_LOCKS_DIR/$1" 2>/dev/null || true; }

# Compact, recent slice of a transcript .jsonl for summarization.
mw_transcript_digest() {
  local tt="$1"
  [ -f "$tt" ] || return 1
  tail -n 400 "$tt" 2>/dev/null | jq -r '
    select(.type=="user" or .type=="assistant")
    | (.message.content // empty) as $c
    | (if ($c|type)=="string" then $c
       else ([$c[]? | select(.type=="text") | .text] | join(" ")) end)
    | select(. != null and (. | length) > 0)
    | .[0:300]
  ' 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 40
}

# POST the JSON body on stdin to OpenRouter; raw response on stdout. The key
# rides in a curl config on a pipe, so it never appears in `ps` argv. This is
# the only function that touches the network — tests stub it, or point
# MW_OPENROUTER_URL at a file:// fixture.
mw_llm_post() {
  curl -sS --max-time "$MW_SUMMARY_TIMEOUT" -X POST "$MW_OPENROUTER_URL" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$OPENROUTER_API_KEY") \
    -H 'Content-Type: application/json' \
    -H 'X-Title: multi-agent-watch' \
    --data-binary @- 2>/dev/null
}

# One summary call for $sid. Saves the raw response to summaries/<sid>.json
# BEFORE parsing (a parse failure never loses a paid call), then prints the
# model's text. Reasoning is off and providers are sorted by latency: this is
# a 25-word label, not a think-hard task.
mw_summary_call() {
  local sid="$1" prompt="$2" raw="$MW_SUMMARIES_DIR/$1.json"
  jq -n --arg m "$MW_SUMMARY_MODEL" --arg p "$prompt" '{
      model: $m,
      max_tokens: 120,
      temperature: 0.2,
      reasoning: {effort: "none"},
      provider: {sort: "latency"},
      messages: [{role: "user", content: $p}]
    }' | mw_llm_post | mw_atomic_write "$raw" || return 1
  jq -r '.choices[0].message.content // empty' "$raw" 2>/dev/null
}

# Bring $sid's summary up to date and print one status word:
#   cached        summary younger than MW_SUMMARY_PERIOD — reused, no call
#   unchanged     cache expired but the transcript hasn't changed since — no call
#   regenerated   called the model and stored a new summary
#   failed        the call errored or returned nothing (reason in the log)
#   no-key / no-transcript / in-flight   skipped without a call
mw_generate_summary() {
  local sid="$1" tt="$2" prev at now digest prompt out stored t0 cost err
  prev="$(mw_summary_value "$sid")"
  if [ -z "${MW_SUMMARY_REFRESH:-}" ] && [ -n "$prev" ]; then
    at="$(mw_summary_at_epoch "$sid")"
    now="$(mw_now_epoch)"
    if [ -n "$at" ]; then
      if [ $((now - at)) -lt "$MW_SUMMARY_PERIOD" ]; then echo cached; return 0; fi
      # Expired, but an idle session's label can't have changed — don't pay
      # to regenerate it until its transcript moves again.
      if [ -f "$tt" ] && [ "$(mw_file_mtime "$tt")" -le "$at" ]; then
        echo unchanged; return 0
      fi
    fi
  fi
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    mw_log "summary skipped sid=$sid: OPENROUTER_API_KEY not set"
    echo no-key; return 0
  fi
  digest="$(mw_transcript_digest "$tt" 2>/dev/null || printf '')"
  [ -z "$digest" ] && { echo no-transcript; return 0; }
  mw_try_lock "summary-$sid" || { echo in-flight; return 0; }
  prompt="You are labeling a Claude Code coding session so sibling sessions in the same repo can avoid conflicts. In ONE sentence (max 25 words, no preamble, no quotes), state concretely what this session is doing: the files, feature, or task. Transcript digest (oldest to newest):
$digest"
  t0="$(mw_now_epoch)"
  out="$(mw_summary_call "$sid" "$prompt")"
  out="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  if [ -n "$out" ]; then
    stored="${out:0:280}"
    mw_set_summary "$sid" "$stored"
    cost="$(jq -r '.usage.cost // "?"' "$MW_SUMMARIES_DIR/$sid.json" 2>/dev/null)"
    mw_log "summary set sid=$sid model=$MW_SUMMARY_MODEL $(( $(mw_now_epoch) - t0 ))s cost=\$${cost}: ${stored:0:80}"
    # Notify subscribers only when the summary actually changed.
    [ "$stored" != "$prev" ] && mw_notify_watchers "$sid" "updated" "${stored:0:200}"
    echo regenerated
  else
    err="$(jq -r '.error.message // empty' "$MW_SUMMARIES_DIR/$sid.json" 2>/dev/null)"
    mw_log "summary FAILED sid=$sid model=$MW_SUMMARY_MODEL: ${err:-empty/unparseable response}"
    echo failed
  fi
  mw_unlock "summary-$sid"
}

# Read-time refresh: bring every registered session's summary up to date in
# parallel (each call capped by MW_SUMMARY_TIMEOUT), then print a tally such
# as "2 cached, 1 regenerated".
mw_refresh_summaries() {
  local f sid tt dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/mw-sum.XXXXXX")" || return 0
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    sid="$(basename "$f" .json)"
    tt="$(jq -r '.transcript_path // ""' "$f" 2>/dev/null)"
    mw_generate_summary "$sid" "$tt" > "$dir/$sid" 2>/dev/null &
  done
  shopt -u nullglob
  wait
  cat "$dir"/* 2>/dev/null | sort | uniq -c \
    | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 } END { if (NR) print "" }'
  rm -rf "$dir"
  return 0
}

# ---------------------------------------------------------------------------
# Subscriptions: a session can WATCH another and get a message when the watched
# session changes its summary or ends. Watchers are stored on the WATCHED
# session's entry (.watchers[]) — preserved across heartbeats by the merge in
# mw_write_session — so whoever changes/removes it can fan out. Delivery reuses
# the inbox, so watch notifications surface through the same monitor drain.
# ---------------------------------------------------------------------------

mw_watchers() {
  jq -r '(.watchers // [])[]' "$MW_SESSIONS_DIR/$1.json" 2>/dev/null || printf ''
}

# Subscribe watcher -> target. rc 1 if target missing or self-watch.
mw_add_watch() {
  local watcher="$1" target="$2" file="$MW_SESSIONS_DIR/$2.json"
  [ "$watcher" = "$target" ] && return 1
  [ -f "$file" ] || return 1
  jq --arg w "$watcher" '.watchers = ((.watchers // []) + [$w] | unique)' "$file" 2>/dev/null \
    | mw_atomic_write "$file"
}

# Unsubscribe watcher from a single target.
mw_remove_watch() {
  local watcher="$1" target="$2" file="$MW_SESSIONS_DIR/$2.json"
  [ -f "$file" ] || return 0
  jq --arg w "$watcher" '.watchers = ((.watchers // []) - [$w])' "$file" 2>/dev/null \
    | mw_atomic_write "$file"
}

# Remove a watcher from EVERY session's watcher list (SessionEnd auto-unsub).
mw_unwatch_all() {
  local watcher="$1" f
  shopt -s nullglob
  for f in "$MW_SESSIONS_DIR"/*.json; do
    if jq -e --arg w "$watcher" '((.watchers // []) | index($w)) != null' "$f" >/dev/null 2>&1; then
      jq --arg w "$watcher" '.watchers = ((.watchers // []) - [$w])' "$f" 2>/dev/null | mw_atomic_write "$f"
    fi
  done
  shopt -u nullglob
}

# Push a notification to every still-present watcher of <sid>; lazily prune
# watchers whose session is gone. event/detail describe what happened.
mw_notify_watchers() {
  local sid="$1" event="$2" detail="$3" w tcwd
  tcwd="$(jq -r '.cwd // ""' "$MW_SESSIONS_DIR/$sid.json" 2>/dev/null || printf '')"
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    if [ -f "$MW_SESSIONS_DIR/$w.json" ]; then
      mw_send_message "$w" "watch:${sid:0:8}" "$tcwd" "🔔 watched session ${sid:0:8} ${event}: ${detail}"
    else
      mw_remove_watch "$w" "$sid"
    fi
  done <<< "$(mw_watchers "$sid")"
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
