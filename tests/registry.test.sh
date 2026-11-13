#!/usr/bin/env bash
# multi-agent-watch — registry + inbox unit tests.
# Runs against a throwaway MW_STATE and Claude Code session dir, so it never
# touches the real registries.
# Usage: bash tests/registry.test.sh   (exit 0 = all green)
set -uo pipefail

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mw-test.XXXXXX")"
export MW_STATE="$TMP"
export MW_CC_SESSIONS_DIR="$TMP/cc-sessions"   # stands in for ~/.claude/sessions
export MW_QUIET=1          # no desktop notifications during tests
export MW_STALE_SEC=600

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$HERE/../lib/registry.sh"
mw_init

pass=0; fail=0
ok() {  # ok "<desc>" "<bash test expr>"
  if eval "$2"; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else               printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi
}

echo "== write / read roundtrip =="
mw_write_session "sid-aaaa" "/repo/x" "/t/a.jsonl" "startup"
ok "session file created"  '[ -f "$MW_SESSIONS_DIR/sid-aaaa.json" ]'
ok "valid json"            'jq -e . "$MW_SESSIONS_DIR/sid-aaaa.json" >/dev/null'
ok "repo_key recorded"     '[ "$(jq -r .repo_key "$MW_SESSIONS_DIR/sid-aaaa.json")" = "/repo/x" ]'
ok "source recorded"       '[ "$(jq -r .source "$MW_SESSIONS_DIR/sid-aaaa.json")" = "startup" ]'

echo "== started_at + known_others preserved across rewrites =="
started1="$(jq -r .started_at "$MW_SESSIONS_DIR/sid-aaaa.json")"
mw_set_known_others "sid-aaaa" "x,y"
mw_write_session "sid-aaaa" "/repo/x" "/t/a.jsonl" "monitor"
ok "started_at stable"     '[ "$(jq -r .started_at "$MW_SESSIONS_DIR/sid-aaaa.json")" = "'"$started1"'" ]'
ok "known_others kept"     '[ "$(jq -r .known_others_csv "$MW_SESSIONS_DIR/sid-aaaa.json")" = "x,y" ]'

# Regression: a heartbeat rewrite must not wipe the summary field.
mw_set_summary "sid-aaaa" "doing the thing"
mw_write_session "sid-aaaa" "/repo/x" "/t/a.jsonl" "monitor"
ok "summary survives rewrite" '[ "$(mw_summary_value sid-aaaa)" = "doing the thing" ]'

echo "== atomic write under concurrency (no corruption, no temp leak) =="
i=0
while [ "$i" -lt 60 ]; do
  ( mw_write_session "sid-race" "/repo/x" "/t/r.jsonl" "monitor" ) &
  ( mw_purge_stale ) &
  i=$((i+1))
done
wait
ok "raced file is valid json" 'jq -e . "$MW_SESSIONS_DIR/sid-race.json" >/dev/null 2>&1'
ok "no temp files leaked"     'shopt -s nullglob; t=("$MW_SESSIONS_DIR"/*.tmp*); [ ${#t[@]} -eq 0 ]'

echo "== purge: keep fresh, drop stale =="
mw_write_session "sid-fresh" "/repo/x" "" "monitor"
jq -n '{session_id:"sid-old",repo_key:"/repo/x",last_heartbeat_epoch:1}' > "$MW_SESSIONS_DIR/sid-old.json"
mw_purge_stale
ok "fresh kept"   '[ -f "$MW_SESSIONS_DIR/sid-fresh.json" ]'
ok "stale dropped" '[ ! -f "$MW_SESSIONS_DIR/sid-old.json" ]'

echo "== purge: never nuke a fresh-but-corrupt (mid-write) file; drop only old corrupt =="
printf '{ truncated' > "$MW_SESSIONS_DIR/sid-mid.json"          # fresh mtime, unparseable
mw_purge_stale
ok "fresh corrupt kept" '[ -f "$MW_SESSIONS_DIR/sid-mid.json" ]'
printf '{ truncated' > "$MW_SESSIONS_DIR/sid-oldcorrupt.json"
touch -t 200001010000 "$MW_SESSIONS_DIR/sid-oldcorrupt.json"   # backdate -> genuinely stale
mw_purge_stale
ok "old corrupt dropped" '[ ! -f "$MW_SESSIONS_DIR/sid-oldcorrupt.json" ]'
rm -f "$MW_SESSIONS_DIR/sid-mid.json"

echo "== recipient resolution: prefix / all / exclude self =="
rm -f "$MW_SESSIONS_DIR"/*.json
mw_write_session "alpha-1" "/repo/x" "" m
mw_write_session "alpha-2" "/repo/x" "" m
mw_write_session "beta-1"  "/repo/y" "" m
ok "prefix matches"          '[ "$(mw_resolve_sids alpha | sort | tr "\n" ,)" = "alpha-1,alpha-2," ]'
ok "all on repo x excl self" '[ "$(mw_resolve_sids all /repo/x alpha-1 | sort | tr "\n" ,)" = "alpha-2," ]'
ok "all cross-repo excl self" '[ "$(mw_resolve_sids all "" alpha-1 | sort | tr "\n" ,)" = "alpha-2,beta-1," ]'
ok "no match -> empty"       '[ -z "$(mw_resolve_sids zzz)" ]'

echo "== send -> drain roundtrip =="
mw_send_message "alpha-2" "alpha-1" "/repo/x" "hello from a1"
ok "inbox count 1"          '[ "$(mw_inbox_count alpha-2)" = "1" ]'
out="$(mw_drain_inbox alpha-2)"
ok "drain has text"         'printf "%s" "$out" | grep -q "hello from a1"'
ok "drain has sender"       'printf "%s" "$out" | grep -q "alpha-1"'
ok "inbox empty after drain" '[ "$(mw_inbox_count alpha-2)" = "0" ]'
ok "second drain empty"     '[ -z "$(mw_drain_inbox alpha-2)" ]'

echo "== orphan inboxes: dropped only after the recipient is gone AND past MW_INBOX_TTL =="
ok "default inbox TTL is 24h"  '[ "$MW_INBOX_TTL" = "86400" ]'
mw_send_message "gone-old"   "alpha-1" "/repo/x" "nobody will read this"
mw_send_message "gone-fresh" "alpha-1" "/repo/x" "recipient may re-register"
mw_send_message "alpha-1"    "alpha-2" "/repo/x" "live recipient, old mail"
touch -t 200001010000 "$MW_MESSAGES_DIR"/gone-old/*.json "$MW_MESSAGES_DIR"/alpha-1/*.json
mkdir -p "$MW_MESSAGES_DIR/gone-empty"
mw_purge_stale
ok "old orphan inbox dropped"       '[ ! -d "$MW_MESSAGES_DIR/gone-old" ]'
ok "drop is logged"                 'grep -q "orphan inbox: gone-old" "$MW_LOG"'
ok "empty orphan dir dropped"       '[ ! -d "$MW_MESSAGES_DIR/gone-empty" ]'
ok "fresh orphan kept (grace)"      '[ "$(mw_inbox_count gone-fresh)" = "1" ]'
ok "live recipient keeps old mail"  '[ "$(mw_inbox_count alpha-1)" = "1" ]'
mw_drain_inbox alpha-1 >/dev/null
out="$(bash "$HERE/../commands/mw-status.sh")"
ok "status flags orphan inbox"      'printf "%s" "$out" | grep "gone-fre" | grep -q "recipient not registered"'
rm -rf "$MW_MESSAGES_DIR/gone-fresh"

echo "== summary: lock is once-only =="
ok "first lock acquired"  'mw_try_lock lk-1'
ok "second lock refused"  '! mw_try_lock lk-1'
mw_unlock lk-1
ok "lock reusable after unlock" 'mw_try_lock lk-1'; mw_unlock lk-1

# Stub the network: mw_llm_post is the only function that talks to OpenRouter.
# It records each call + the request body and replies with a canned response.
export OPENROUTER_API_KEY="sk-test-not-a-real-key"
calls="$TMP/llm.calls"; body="$TMP/llm.body.json"; resp="$TMP/llm.resp.json"
: > "$calls"
jq -n '{choices:[{message:{content:"editing lib/registry.sh:\n adding  messaging"}}],usage:{cost:0.00002}}' > "$resp"
mw_llm_post() { cat > "$body"; echo call >> "$calls"; cat "$resp"; }
ncalls() { wc -l < "$calls" | tr -d " "; }
# Push a session's summary_at back by $2 seconds (simulate the cache aging).
age_summary() {
  local f="$MW_SESSIONS_DIR/$1.json" iso
  iso="$(date -u -r $(( $(date -u '+%s') - $2 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
         || date -u -d '@'"$(( $(date -u '+%s') - $2 ))" '+%Y-%m-%dT%H:%M:%SZ')"
  jq --arg t "$iso" '.summary_at=$t' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

echo "== summary: generated via OpenRouter (stubbed) =="
tt="$TMP/t.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"fix the registry concurrency bug"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"editing registry.sh now"}]}}' \
  > "$tt"
mw_write_session "sum-1" "/repo/z" "$tt" startup
ok "digest non-empty"         '[ -n "$(mw_transcript_digest "$tt")" ]'
st="$(mw_generate_summary "sum-1" "$tt")"
ok "status = regenerated"     '[ "$st" = "regenerated" ]'
ok "summary stored, one line" '[ "$(mw_summary_value sum-1)" = "editing lib/registry.sh: adding messaging" ]'
ok "called once"              '[ "$(ncalls)" = "1" ]'
ok "raw response saved"       'jq -e ".usage.cost" "$MW_SUMMARIES_DIR/sum-1.json" >/dev/null'
ok "model = deepseek v4.1 flash" '[ "$(jq -r .model "$body")" = "deepseek/deepseek-v4.1-flash" ]'
ok "reasoning disabled"       '[ "$(jq -r .reasoning.effort "$body")" = "none" ]'
ok "prompt carries digest"    'jq -r ".messages[0].content" "$body" | grep -q "registry concurrency bug"'

echo "== summary: 15-minute cache =="
ok "default period is 900s"   '[ "$MW_SUMMARY_PERIOD" = "900" ]'
st="$(mw_generate_summary "sum-1" "$tt")"
ok "fresh summary ⇒ cached"   '[ "$st" = "cached" ] && [ "$(ncalls)" = "1" ]'
age_summary sum-1 600
st="$(mw_generate_summary "sum-1" "$tt")"
ok "10 min old ⇒ still cached" '[ "$st" = "cached" ] && [ "$(ncalls)" = "1" ]'
st="$(MW_SUMMARY_REFRESH=1 mw_generate_summary "sum-1" "$tt")"
ok "MW_SUMMARY_REFRESH=1 forces" '[ "$st" = "regenerated" ] && [ "$(ncalls)" = "2" ]'

echo "== summary: expired cache re-generates only if the session moved on =="
age_summary sum-1 1000
touch -t 200001010000 "$tt"                  # transcript untouched since summary
st="$(mw_generate_summary "sum-1" "$tt")"
ok "expired + idle transcript ⇒ unchanged, no call" '[ "$st" = "unchanged" ] && [ "$(ncalls)" = "2" ]'
touch "$tt"                                  # session wrote more since
st="$(mw_generate_summary "sum-1" "$tt")"
ok "expired + new activity ⇒ regenerated" '[ "$st" = "regenerated" ] && [ "$(ncalls)" = "3" ]'

echo "== summary: no key / API error / no transcript =="
mw_write_session "sum-2" "/repo/z" "$tt" startup
st="$(OPENROUTER_API_KEY= mw_generate_summary "sum-2" "$tt")"
ok "no key ⇒ no-key, no call" '[ "$st" = "no-key" ] && [ "$(ncalls)" = "3" ]'
jq -n '{error:{code:402,message:"Insufficient credits"}}' > "$resp"
st="$(mw_generate_summary "sum-2" "$tt")"
ok "API error ⇒ failed"       '[ "$st" = "failed" ] && [ -z "$(mw_summary_value sum-2)" ]'
ok "error raw kept on disk"   'jq -e ".error.code == 402" "$MW_SUMMARIES_DIR/sum-2.json" >/dev/null'
ok "failure logged"           'grep -q "Insufficient credits" "$MW_LOG"'
ok "lock released after failure" 'mw_try_lock summary-sum-2'; mw_unlock summary-sum-2
mw_write_session "sum-3" "/repo/z" "/nope/missing.jsonl" startup
st="$(mw_generate_summary "sum-3" "/nope/missing.jsonl")"
ok "missing transcript ⇒ no-transcript" '[ "$st" = "no-transcript" ]'
jq -n '{choices:[{message:{content:"editing lib/registry.sh"}}],usage:{cost:0.00002}}' > "$resp"

echo "== summary: refresh-on-read covers every session, in parallel =="
rm -f "$MW_SESSIONS_DIR"/*.json; : > "$calls"
for n in 1 2 3; do mw_write_session "par-$n" "/repo/p" "$tt" startup; done
tally="$(mw_refresh_summaries)"
ok "each session called once" '[ "$(ncalls)" = "3" ]'
ok "all three summarized"     '[ -n "$(mw_summary_value par-1)" ] && [ -n "$(mw_summary_value par-3)" ]'
ok "tally reports regenerated" 'printf "%s" "$tally" | grep -q "3 regenerated"'
tally="$(mw_refresh_summaries)"
ok "second read is all cache" '[ "$(ncalls)" = "3" ] && printf "%s" "$tally" | grep -q "3 cached"'
mw_remove_session "par-3"
ok "raw response removed with its session" '[ ! -f "$MW_SUMMARIES_DIR/par-3.json" ]'

echo "== /mw-status end-to-end (file:// fixture stands in for OpenRouter) =="
fixture="$TMP/fixture.json"
jq -n '{choices:[{message:{content:"wiring the e2e fixture"}}],usage:{cost:0}}' > "$fixture"
rm -f "$MW_SESSIONS_DIR"/*.json
mw_write_session "e2e-1" "/repo/e" "$tt" startup
mw_write_session "e2e-2" "/repo/e" "$tt" startup
out="$(MW_OPENROUTER_URL="file://$fixture" bash "$HERE/../commands/mw-status.sh")"
ok "status shows collision"   'printf "%s" "$out" | grep -q "COLLISION"'
ok "status shows new summary" 'printf "%s" "$out" | grep -q "wiring the e2e fixture"'
ok "status shows summary age" 'printf "%s" "$out" | grep -q "just now"'
ok "status footer: model + endpoint + key source + cache" 'printf "%s" "$out" | grep -q "deepseek/deepseek-v4.1-flash @ file://(fixture) · key: OPENROUTER_API_KEY · cache 15m · 2 regenerated"'
out="$(OPENROUTER_API_KEY= MW_OPENROUTER_URL="file://$fixture" bash "$HERE/../commands/mw-status.sh")"
ok "second read served from cache" 'printf "%s" "$out" | grep -q "2 cached"'

echo "== subscriptions: watch / notify-on-summary-change / leave / auto-unsub =="
rm -f "$MW_SESSIONS_DIR"/*.json
rm -rf "$MW_MESSAGES_DIR"/*
mw_write_session "watcher-1" "/repo/w" "" m
mw_write_session "target-1"  "/repo/w" "" m
ok "self-watch refused"      '! mw_add_watch target-1 target-1'
ok "watch missing target -> 1" '! mw_add_watch watcher-1 nope-9'
mw_add_watch "watcher-1" "target-1"
ok "watcher recorded"        '[ "$(mw_watchers target-1)" = "watcher-1" ]'
ok "watch is idempotent"     'mw_add_watch watcher-1 target-1; [ "$(mw_watchers target-1 | wc -l | tr -d " ")" = "1" ]'

# summary change notifies the watcher (network still stubbed via mw_llm_post)
mw_generate_summary "target-1" "$tt" >/dev/null
ok "summary-change pinged watcher" '[ "$(mw_inbox_count watcher-1)" -ge 1 ]'
ok "ping mentions target"          'mw_drain_inbox watcher-1 | grep -q "target-1"'

# unsubscribe
mw_remove_watch "watcher-1" "target-1"
ok "unsubscribed"            '[ -z "$(mw_watchers target-1)" ]'

# target leaving pings the watcher
mw_add_watch "watcher-1" "target-1"
mw_remove_session "target-1"
ok "target gone"            '[ ! -f "$MW_SESSIONS_DIR/target-1.json" ]'
ok "leave pinged watcher"   'mw_drain_inbox watcher-1 | grep -q "ended"'

# SessionEnd of a watcher auto-unsubscribes it everywhere
mw_write_session "target-2" "/repo/w" "" m
mw_add_watch "watcher-1" "target-2"
ok "watching target-2"      '[ "$(mw_watchers target-2)" = "watcher-1" ]'
mw_remove_session "watcher-1"      # watcher leaves
ok "auto-unsub on leave"    '[ -z "$(mw_watchers target-2)" ]'

echo "== native names: what Claude Code's SendMessage addresses a session by =="
rm -f "$MW_SESSIONS_DIR"/*.json
rm -rf "$MW_MESSAGES_DIR"/*
mkdir -p "$MW_CC_SESSIONS_DIR"
set_ppid() { jq --argjson p "$2" '.ppid = $p' "$MW_SESSIONS_DIR/$1.json" | mw_atomic_write "$MW_SESSIONS_DIR/$1.json"; }
cc_entry() { jq -n --argjson pid "$1" --arg s "$2" --arg n "$3" '{pid:$pid, sessionId:$s, name:$n}' > "$MW_CC_SESSIONS_DIR/$1.json"; }
mw_write_session "nm-1" "/repo/n" "" m; set_ppid nm-1 111; cc_entry 111 nm-1 temp-aa
mw_write_session "nm-2" "/repo/n" "" m; set_ppid nm-2 222; cc_entry 222 someone-else temp-bb
mw_write_session "nm-3" "/repo/n" "" m; set_ppid nm-3 333
ok "name read via ppid"           '[ "$(mw_native_name nm-1)" = "temp-aa" ]'
ok "recycled pid -> no name"      '[ -z "$(mw_native_name nm-2)" ]'
ok "no CC entry -> no name"       '[ -z "$(mw_native_name nm-3)" ]'
named="$(mw_active_for_repo /repo/n "" | mw_add_native_names)"
ok "array annotated"              '[ "$(printf "%s" "$named" | jq -r "map(select(.session_id==\"nm-1\"))[0].native_name")" = "temp-aa" ]'
ok "unknown names are empty"      '[ "$(printf "%s" "$named" | jq "map(select(.native_name==\"\")) | length")" = "2" ]'
ok "empty array passes through"   '[ "$(printf "[]" | mw_add_native_names | jq -c .)" = "[]" ]'
out="$(OPENROUTER_API_KEY= bash "$HERE/../commands/mw-status.sh")"
ok "status shows name"            'printf "%s" "$out" | grep -q "nm-1 name=temp-aa host="'

echo "== /mw-send is gone: chat goes through native SendMessage =="
ok "no /mw-send command"          '[ ! -e "$HERE/../commands/mw-send.md" ] && [ ! -e "$HERE/../commands/mw-send.sh" ]'

echo "== session-start: collision context names siblings =="
rm -f "$MW_SESSIONS_DIR"/*.json
mw_write_session "mon-peer" "/repo/m" "" m; set_ppid mon-peer 444; cc_entry 444 mon-peer temp-peer
out="$(printf '{"session_id":"ss-new","cwd":"/repo/m"}' | bash "$HERE/../hooks/session-start.sh" 2>/dev/null)"
ctx="$(printf "%s" "$out" | jq -r .hookSpecificOutput.additionalContext)"
ok "start context names sibling"  'printf "%s" "$ctx" | grep -q "session=mon-peer name=temp-peer"'
ok "start context -> SendMessage" 'printf "%s" "$ctx" | grep -q "SendMessage"'
rm -f "$MW_SESSIONS_DIR/ss-new.json"

echo "== monitor: roster delta names siblings; watch pings carry no reply hint =="
mw_write_session "mon-self" "/repo/m" "" m
mw_send_message "mon-self" "watch:mon-peer" "/repo/m" "🔔 watched session mon-peer ended: done"
out="$(printf '{"session_id":"mon-self","cwd":"/repo/m","hook_event_name":"PostToolUse"}' | bash "$HERE/../hooks/monitor.sh" 2>/dev/null)"
ctx="$(printf "%s" "$out" | jq -r .hookSpecificOutput.additionalContext)"
ok "delta names sibling"          'printf "%s" "$ctx" | grep -q "session=mon-peer name=temp-peer"'
ok "delta -> SendMessage"         'printf "%s" "$ctx" | grep -q "SendMessage tool, addressed by its name="'
ok "watch ping delivered"         'printf "%s" "$ctx" | grep -q "1 watch notification(s) for you"'
ok "no /mw-send reply hint"       '! printf "%s" "$ctx" | grep -q "mw-send"'
ok "ping drained"                 '[ "$(mw_inbox_count mon-self)" = "0" ]'
out="$(printf '{"session_id":"mon-self","cwd":"/repo/m","hook_event_name":"PostToolUse"}' | bash "$HERE/../hooks/monitor.sh" 2>/dev/null)"
ok "quiet when nothing changed"   '[ -z "$out" ]'

echo "== fast paths: one jq for the roster, per-file fallback on corrupt data =="
rm -f "$MW_SESSIONS_DIR"/*.json
rm -rf "$MW_MESSAGES_DIR"/*
rm -f "$MW_CC_SESSIONS_DIR"/*.json
mw_write_session "fp-1" "/repo/f" "" m; set_ppid fp-1 501; cc_entry 501 fp-1 temp-f1
mw_write_session "fp-2" "/repo/f" "" m
mw_write_session "fp-other" "/repo/g" "" m
ok "active: repo filter + self exclusion"  '[ "$(mw_active_for_repo /repo/f fp-2 | jq -r "map(.session_id) | join(\",\")")" = "fp-1" ]'
ok "active: no sessions -> []"             '[ "$(MW_SESSIONS_DIR=$TMP/none mw_active_for_repo /repo/f "")" = "[]" ]'
printf '{not json' > "$MW_SESSIONS_DIR/fp-bad.json"
ok "active: corrupt file skipped, others kept" '[ "$(mw_active_for_repo /repo/f "" | jq -r "map(.session_id) | sort | join(\",\")")" = "fp-1,fp-2" ]'
touch -t 200001010000 "$MW_SESSIONS_DIR/fp-bad.json"
mw_purge_stale
ok "purge: corrupt+old removed, healthy kept"  '[ ! -e "$MW_SESSIONS_DIR/fp-bad.json" ] && [ -e "$MW_SESSIONS_DIR/fp-1.json" ]'
old_hb=$(( $(date -u +%s) - MW_STALE_SEC - 60 ))
jq --argjson h "$old_hb" '.last_heartbeat_epoch = $h' "$MW_SESSIONS_DIR/fp-2.json" | mw_atomic_write "$MW_SESSIONS_DIR/fp-2.json"
mw_purge_stale
ok "purge: stale heartbeat removed (single-jq path)"  '[ ! -e "$MW_SESSIONS_DIR/fp-2.json" ] && [ -e "$MW_SESSIONS_DIR/fp-1.json" ]'
ok "names: single-jq join matches"         '[ "$(mw_active_for_repo /repo/f "" | mw_add_native_names | jq -r ".[0].native_name")" = "temp-f1" ]'
ok "names: entry without ppid falls back to the session file" '[ "$(printf "[{\"session_id\":\"fp-1\"}]" | mw_add_native_names | jq -r ".[0].native_name")" = "temp-f1" ]'
rm -f "$MW_CC_SESSIONS_DIR"/*.json
ok "names: no CC session files -> empty names" '[ "$(mw_active_for_repo /repo/f "" | mw_add_native_names | jq -r ".[0].native_name")" = "" ]'
mw_write_session "fp-key" "/repo/f/sub/dir" "" m "/forced/key"
ok "write_session: explicit repo key (5th arg) wins" '[ "$(jq -r .repo_key "$MW_SESSIONS_DIR/fp-key.json")" = "/forced/key" ]'
mw_tick
ok "tick: mw_now / mw_now_epoch reuse one clock" '[ "$(mw_now)" = "$MW_TICK_ISO" ] && [ "$(mw_now_epoch)" = "$MW_TICK_EPOCH" ]'
unset MW_TICK_EPOCH MW_TICK_ISO

echo "== desktop notification never blocks the hook =="
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nsleep 3\n' > "$TMP/fakebin/terminal-notifier"; chmod +x "$TMP/fakebin/terminal-notifier"
mw_write_session "an-peer" "/repo/an" "" m
t0=$(date -u +%s)
printf '{"session_id":"an-new","cwd":"/repo/an","source":"startup"}' | MW_QUIET=0 PATH="$TMP/fakebin:$PATH" bash "$HERE/../hooks/session-start.sh" >/dev/null 2>&1
t1=$(date -u +%s)
ok "session-start returns while the notifier still sleeps (<=1s vs 3s)" '[ $((t1 - t0)) -le 1 ]'

echo "== summary endpoint + key: baseurl, custom key, precedence, no key leak =="
(
  unset MW_OPENROUTER_URL MW_SUMMARY_API_KEY
  MW_SUMMARY_BASE_URL="https://llm.example.test/v1/" OPENROUTER_API_KEY=or-key
  ok "endpoint derives from base url (trailing slash trimmed)" '[ "$(mw_summary_url)" = "https://llm.example.test/v1/chat/completions" ]'
  ok "host shown without path or userinfo" '[ "$(MW_SUMMARY_BASE_URL="https://u:p@llm.example.test:8443/v1" mw_summary_host)" = "https://llm.example.test:8443" ]'
  ok "key falls back to OPENROUTER_API_KEY" '[ "$(mw_summary_key)" = "or-key" ] && [ "$(mw_summary_key_source)" = OPENROUTER_API_KEY ]'
  MW_SUMMARY_API_KEY=custom-key
  ok "MW_SUMMARY_API_KEY wins over OPENROUTER_API_KEY" '[ "$(mw_summary_key)" = "custom-key" ] && [ "$(mw_summary_key_source)" = MW_SUMMARY_API_KEY ]'
  MW_OPENROUTER_URL="file:///fixture.json"
  ok "MW_OPENROUTER_URL still overrides the derived endpoint" '[ "$(mw_summary_url)" = "file:///fixture.json" ]'
  unset MW_SUMMARY_API_KEY OPENROUTER_API_KEY MW_OPENROUTER_URL
  ok "no key -> source none" '[ "$(mw_summary_key_source)" = none ] && [ -z "$(mw_summary_key)" ]'
)

echo "== native status: busy/idle read from Claude Code's own registry =="
rm -f "$MW_SESSIONS_DIR"/*.json; rm -f "$MW_CC_SESSIONS_DIR"/*.json
mw_write_session "st-1" "/repo/st" "" startup
mw_write_session "st-2" "/repo/st" "" startup
set_ppid st-1 7001; set_ppid st-2 7002
printf '{"pid":7001,"sessionId":"st-1","name":"temp-aa","status":"busy"}' > "$MW_CC_SESSIONS_DIR/7001.json"
printf '{"pid":7002,"sessionId":"st-2","name":"temp-bb","status":"idle"}' > "$MW_CC_SESSIONS_DIR/7002.json"
joined="$(jq -s '.' "$MW_SESSIONS_DIR"/st-1.json "$MW_SESSIONS_DIR"/st-2.json | mw_add_native_names)"
ok "fast path: status joined with name" '[ "$(printf "%s" "$joined" | jq -r ".[] | select(.session_id==\"st-1\") | .native_status")" = busy ]'
ok "fast path: idle sibling" '[ "$(printf "%s" "$joined" | jq -r ".[] | select(.session_id==\"st-2\") | .native_name + \"/\" + .native_status")" = "temp-bb/idle" ]'
printf 'not json' > "$MW_CC_SESSIONS_DIR/7002.json"
fallback="$(jq -s '.' "$MW_SESSIONS_DIR"/st-1.json "$MW_SESSIONS_DIR"/st-2.json | mw_add_native_names)"
ok "fallback path: corrupt sibling file does not drop the busy status" '[ "$(printf "%s" "$fallback" | jq -r ".[] | select(.session_id==\"st-1\") | .native_status")" = busy ]'

echo "----------------------------------------"
echo "$pass passed, $fail failed"
rm -rf "$TMP"
[ "$fail" -eq 0 ]
