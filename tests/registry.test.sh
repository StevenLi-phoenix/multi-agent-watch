#!/usr/bin/env bash
# multi-agent-watch — registry + messaging unit tests.
# Runs against a throwaway MW_STATE so it never touches the real registry.
# Usage: bash tests/registry.test.sh   (exit 0 = all green)
set -uo pipefail

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mw-test.XXXXXX")"
export MW_STATE="$TMP"
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

echo "== broadcast reaches others, skips self =="
while IFS= read -r t; do [ -n "$t" ] && mw_send_message "$t" "alpha-1" "/repo/x" "bcast"; done \
  < <(mw_resolve_sids all /repo/x alpha-1)
ok "broadcast hit alpha-2"  '[ "$(mw_inbox_count alpha-2)" = "1" ]'
ok "broadcast skipped self" '[ "$(mw_inbox_count alpha-1)" = "0" ]'

echo "== summary: lock is once-only =="
ok "first lock acquired"  'mw_try_lock lk-1'
ok "second lock refused"  '! mw_try_lock lk-1'
mw_unlock lk-1
ok "lock reusable after unlock" 'mw_try_lock lk-1'; mw_unlock lk-1

echo "== summary: generate via stubbed claude, exactly once =="
calls="$TMP/claude.calls"
: > "$calls"
cat > "$TMP/fake-claude" <<EOF
#!/usr/bin/env bash
echo call >> "$calls"
echo "editing lib/registry.sh: adding messaging + summary"
EOF
chmod +x "$TMP/fake-claude"
export MW_CLAUDE_BIN="$TMP/fake-claude"
tt="$TMP/t.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"fix the registry concurrency bug"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"editing registry.sh now"}]}}' \
  > "$tt"
mw_write_session "sum-1" "/repo/z" "$tt" startup
ok "digest non-empty"        '[ -n "$(mw_transcript_digest "$tt")" ]'
mw_generate_summary "sum-1" "$tt"
ok "summary stored"          '[ -n "$(mw_summary_value sum-1)" ]'
ok "claude called once"      '[ "$(wc -l < "$calls" | tr -d " ")" = "1" ]'
mw_generate_summary "sum-1" "$tt"
ok "run-once: not called again" '[ "$(wc -l < "$calls" | tr -d " ")" = "1" ]'
MW_SUMMARY_REFRESH=1 mw_generate_summary "sum-1" "$tt"
ok "refresh mode re-calls"   '[ "$(wc -l < "$calls" | tr -d " ")" = "2" ]'
unset MW_CLAUDE_BIN

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

# summary change notifies the watcher
export MW_CLAUDE_BIN="$TMP/fake-claude"   # reuse stub from earlier
mw_generate_summary "target-1" "$tt"
ok "summary-change pinged watcher" '[ "$(mw_inbox_count watcher-1)" -ge 1 ]'
ok "ping mentions target"          'mw_drain_inbox watcher-1 | grep -q "target-1"'
unset MW_CLAUDE_BIN

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

echo "----------------------------------------"
echo "$pass passed, $fail failed"
rm -rf "$TMP"
[ "$fail" -eq 0 ]
