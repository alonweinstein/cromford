#!/bin/bash
# tests/queue-batch-reset.bh-5372-test.sh — BH-5372: the conductor names every
# Mergify batch draft that closed because main moved, and says whether the merge
# that moved main could have touched that batch.
#
# WHAT IS PINNED.
#   §1  bres_classify, pure: disjoint, one shared scope, all_scopes either side,
#       _inert vs _inert, empty and unparseable (never `disjoint`).
#   §2  bres_drafts over a stub gh: the exact TSV (a merged draft, a closed one,
#       stacked-on PRs excluded, old drafts and non-batch PRs dropped), and a
#       rate-limited read is rc != 0 with nothing printed.
#   §3  THE WIRING: real bin/merge-conductor.sh ticks. One BATCH_RESET line per
#       reset draft (disjoint, overlap, serial barrier, inert, unreadable), none
#       on a re-tick, none on a rate-limited list (BATCH_RESET_UNREAD instead,
#       and the tick still ends), and no non-GET request ever.
#   §4  D2: the same tick with the bres_tick call removed writes no line.
#
# Scopes come from the REAL qp_impact / qp_scopes_json over a stub
# bin/test-impact.sh that maps fixture files to suites.
# Run from anywhere: tests/queue-batch-reset.bh-5372-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date -u +%s)
SLUG=example-org/demo-os

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/h/config/mergify/repos" "$T/fakebin" "$T/repos"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
[ -f "$DIR/bin/lib/mc-batch-reset.sh" ] && { scratch_install_closure bin/lib/mc-batch-reset.sh "$T/h" >/dev/null || exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$T/h/config/mergify/repos/demo-os.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/jobs-client.sh" <<'EOF'
job_verdict_rebind() { return 0; }
job_ledger_put() { return 0; }
EOF
# The impact map: bin/foo.sh -> tests/foo-test.sh, bin/bar.sh -> tests/bar-test.sh,
# bin/both.sh -> both; every selection carries one always-suite (docs = only that).
cat > "$T/h/bin/test-impact.sh" <<'EOF'
#!/bin/bash
ch=""; while [ $# -gt 0 ]; do [ "$1" = --changed ] && ch="$2"; shift; done
printf 'tests/always-test.sh\talways\n'
while IFS= read -r f; do
  case "$f" in
    bin/foo.sh)  printf 'tests/foo-test.sh\tself\n' ;;
    bin/bar.sh)  printf 'tests/bar-test.sh\tself\n' ;;
    bin/both.sh) printf 'tests/foo-test.sh\tself\ntests/bar-test.sh\tself\n' ;;
  esac
done < "$ch"
EOF
chmod +x "$T/h/bin/test-impact.sh"

# ── the stub gh ──────────────────────────────────────────────────────────────
# closed.json the closed-PR page, commits.json the main history, pr-<n>.json one
# PR, files-<n>.json its file list (absent = 404). closedmode 403 makes the
# closed list rate-limited. Every call is logged to gh-calls.txt.
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: merge\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\n' "$T" "$MGFY_YML" "$SLUG"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
file() { if [ -f "$1" ]; then restpr --raw 200 "$(cat "$1")"; else restpr --raw 404 '{"message":"Not Found"}'; fi; }
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/$SLUG/pulls "*"state=closed"*)
    if [ "$(cat "$T/closedmode" 2>/dev/null)" = 403 ]; then
      restpr --raw 403 '{"message":"API rate limit exceeded for installation."}'
    else file "$T/closed.json"; fi ;;
  *"api -i -X GET repos/$SLUG/pulls -f"*|*"api -i -X GET repos/$SLUG/pulls?"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/commits?"*)
    case "$*" in *"page=1"*) file "$T/commits.json" ;; *) restpr --raw 200 '[]' ;; esac ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"/files"*)
    N=$(sed -n 's|.*/pulls/\([0-9]*\)/files.*|\1|p' <<<"$*")
    case "$*" in *"page=1"*) file "$T/files-$N.json" ;; *) restpr --raw 200 '[]' ;; esac ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*"); file "$T/pr-$N.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
[ -r "$T/h/bin/lib/mc-batch-reset.sh" ] && . "$T/h/bin/lib/mc-batch-reset.sh"
LOG="$T/h/logs/merge-conductor.log"

# ── fixtures ────────────────────────────────────────────────────────────────
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
h40() { printf '%s' "$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1" | cut -c1-40; }
A=5001; B=5002; E=5003; OLD=4999
HA=$(h40 a); HB=$(h40 b); HE=$(h40 e); HO=$(h40 0)
CS=c0ffee0123456789abcdef0123456789abcdef01   # the merge commit of cause #200
M103=$(h40 3)
CA=$(iso $((NOW-1200))); XA=$(iso $((NOW-600)))
CB=$(iso $((NOW-500)));  XB=$(iso $((NOW-400)))
CE=$(iso $((NOW-300)));  XE=$(iso $((NOW-200)))
draft() { # draft <n> <sha> <created> <closed> <title>
  jq -nc --argjson n "$1" --arg s "$2" --arg c "$3" --arg x "$4" --arg t "$5" \
    '{number:$n,title:$t,state:"closed",merged_at:null,created_at:$c,closed_at:$x,updated_at:$x,
      head:{ref:("mergify/merge-queue/"+($n|tostring)),sha:$s},base:{ref:"main"},body:"x"}'
}
{ draft "$E" "$HE" "$CE" "$XE" "merge queue: checking #104 on main (abc1234)"
  draft "$B" "$HB" "$CB" "$XB" "merge queue: checking #103 on main (abc1234)"
  draft "$A" "$HA" "$CA" "$XA" "merge queue: checking #101 + #102 together on main (abc1234), stacked on #99"
  jq -nc --arg x "$(iso $((NOW-650)))" '{number:300,title:"BH-1: x",closed_at:$x,updated_at:$x,created_at:$x,head:{ref:"ticket/bh-1",sha:"f"},merged_at:null}'
  draft "$OLD" "$HO" "$(iso $((NOW-7800)))" "$(iso $((NOW-7200)))" "merge queue: checking #98 on main (abc1234)"
} | jq -sc . > "$T/closed.json"
commit() { # commit <sha> <at> <message> <parent>...
  local s="$1" at="$2" m="$3"; shift 3
  jq -nc --arg s "$s" --arg at "$at" --arg m "$m" '{sha:$s,commit:{message:$m,committer:{date:$at}},parents:($ARGS.positional|map({sha:.}))}' --args "$@"
}
{ commit "$M103" "$(iso $((NOW-370)))" $'Merge pull request #103 from example-org/ticket/bh-103\n\nx' "$(h40 9)" "$(h40 7)"
  commit "$CS" "$(iso $((NOW-900)))" $'Merge pull request #200 from example-org/ticket/bh-200\n\ny' "$(h40 8)" "$(h40 c)"
  commit "$(h40 6)" "$(iso $((NOW-950)))" 'BH-200: a plain commit' "$(h40 5)"
  commit "$(h40 4)" "$(iso $((NOW-1000)))" "Merge branch 'main' into x" "$(h40 5)" "$(h40 2)"
} | jq -sc . > "$T/commits.json"
for n in 101 102 104; do jq -nc --argjson n "$n" '{number:$n,head:{sha:("h"+($n|tostring))}}' > "$T/pr-$n.json"; done
files() { local n="$1"; shift; jq -nc '$ARGS.positional|map({filename:.})' --args "$@" > "$T/files-$n.json"; }
reset_case() {
  : > "$LOG"; : > "$T/gh-calls.txt"; : > "$T/h/state/merge-conductor/attempts.txt"
  rm -rf "$T/h/state/merge-conductor/pr-files" "$T/closedmode" "$T"/files-*.json
  files 101 bin/foo.sh; files 102 docs/x.md; files 200 bin/bar.sh
}
resets() { grep -c "BATCH_RESET draft=$A " "$LOG"; }

# ============================================================================
# §1. bres_classify — pure
# ============================================================================
cl() { command -v bres_classify >/dev/null 2>&1 || { echo "(bres_classify undefined)"; return; }; bres_classify "$@"; }
s() { jq -nc --argjson a "$1" '{scopes:$a,all_scopes:false}'; }
BAR='{"scopes":[],"all_scopes":true}'
[ "$(cl "$(s '["a"]')" "$(s '["b"]')")" = disjoint ] && ok || bad "§1 disjoint sets → disjoint (got $(cl "$(s '["a"]')" "$(s '["b"]')"))"
[ "$(cl "$(s '["a","b"]')" "$(s '["b"]')")" = overlap ] && ok || bad "§1 one shared scope → overlap"
[ "$(cl "$BAR" "$(s '["b"]')")" = overlap ] && ok || bad "§1 barrier left → overlap"
[ "$(cl "$(s '["a"]')" "$BAR")" = overlap ] && ok || bad "§1 barrier right → overlap"
[ "$(cl "$(s '["_inert"]')" "$(s '["_inert"]')")" = overlap ] && ok || bad "§1 _inert vs _inert → overlap"
[ "$(cl "$(s '[]')" "$(s '["a"]')")" = unknown ] && ok || bad "§1 empty scopes left → unknown"
[ "$(cl "$(s '["a"]')" "$(s '[]')")" = unknown ] && ok || bad "§1 empty scopes right → unknown"
for g in '' 'null' '[]' '{"scopes":"x","all_scopes":false}' '{"scopes":[' '{"scopes":["a"]}'; do
  [ "$(cl "$g" "$(s '["b"]')")" = unknown ] && ok || bad "§1 garbage '$g' → unknown (got $(cl "$g" "$(s '["b"]')"))"
  [ "$(cl "$(s '["b"]')" "$g")" = unknown ] && ok || bad "§1 garbage '$g' on the right → unknown"
done
[ "$(cl "$BAR" '{"scopes":[')" = unknown ] && ok || bad "§1 barrier vs garbage → unknown, never disjoint"

# ============================================================================
# §2. bres_drafts — the reader and its TSV contract
# ============================================================================
reset_case
dr() { command -v bres_drafts >/dev/null 2>&1 || { echo "(bres_drafts undefined)"; return 9; }; bres_drafts "$@"; }
OUT=$(dr "$SLUG"); RC=$?
WANT=$(printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$A" closed "$HA" "$CA" "$XA" "101,102" \
  "$B" merged "$HB" "$CB" "$XB" "103" \
  "$E" closed "$HE" "$CE" "$XE" "104")
[ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && ok || bad "§2 drafts TSV (rc=$RC):
--- got
$OUT
--- want
$WANT"
echo 403 > "$T/closedmode"
OUT=$(dr "$SLUG"); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "§2 rate-limited closed list: rc != 0 and nothing printed (rc=$RC out=$OUT)"
rm -f "$T/closedmode"
cp "$T/commits.json" "$T/commits.json.ok"; rm -f "$T/commits.json"
OUT=$(dr "$SLUG"); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "§2 unreadable commit history: rc != 0 and nothing printed (rc=$RC out=$OUT)"
mv "$T/commits.json.ok" "$T/commits.json"

# ============================================================================
# §3. THE WIRING: real conductor ticks
# ============================================================================
CONDUCTOR="$T/h/bin/merge-conductor.sh"
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_REPOS="$T/repos" \
  MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
  MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 \
  bash "$CONDUCTOR" >/dev/null 2>"$T/tick.err" ); TICK_RC=$?; }
writes() { grep -E -- '-X (POST|PUT|PATCH|DELETE)' "$T/gh-calls.txt" | grep -E '/labels|/comments|/queue' ; }

# disjoint: members touch foo + docs, the cause #200 touches bar.
reset_case; tick
[ "$(resets)" = 1 ] && grep -q "BATCH_RESET draft=$A cause=${CS:0:12} verdict=disjoint" "$LOG" && ok \
  || bad "§3 disjoint: exactly one BATCH_RESET draft=$A cause=${CS:0:12} verdict=disjoint (rc=$TICK_RC log: $(grep BATCH "$LOG"); err: $(tail -3 "$T/tick.err"))"
[ "$(grep -c 'BATCH_RESET draft=' "$LOG")" = 1 ] && ok || bad "§3 the merged draft $B and the cause-less draft $E write no line (log: $(grep BATCH "$LOG"))"
[ -z "$(writes)" ] && ok || bad "§3 observe only: no write request (saw: $(writes))"
# second tick on the same state: no new line, and no file read either.
: > "$T/gh-calls.txt"; tick
[ "$(resets)" = 1 ] && ok || bad "§3 second tick: still one line (log: $(grep BATCH "$LOG"))"
grep -q '/files' "$T/gh-calls.txt" && bad "§3 second tick reads no file list (calls: $(grep /files "$T/gh-calls.txt"))" || ok

# overlap: the cause shares tests/foo-test.sh.
reset_case; files 200 bin/both.sh; tick
grep -q "BATCH_RESET draft=$A cause=${CS:0:12} verdict=overlap" "$LOG" && [ "$(resets)" = 1 ] && ok \
  || bad "§3 overlap: verdict=overlap (log: $(grep BATCH "$LOG"))"

# barrier: the cause touches a serial path.
reset_case; files 200 bin/lib/mc/x.sh; tick
grep -q "BATCH_RESET draft=$A cause=${CS:0:12} verdict=overlap" "$LOG" && ok \
  || bad "§3 serial barrier: verdict=overlap (log: $(grep BATCH "$LOG"))"

# inert: both sides docs only.
reset_case; files 101 docs/x.md; files 200 docs/y.md; tick
grep -q "BATCH_RESET draft=$A cause=${CS:0:12} verdict=overlap" "$LOG" && ok \
  || bad "§3 _inert vs _inert: verdict=overlap (log: $(grep BATCH "$LOG"))"

# unreadable: a member's file list 404s.
reset_case; rm -f "$T/files-102.json"; tick
grep -q "BATCH_RESET draft=$A cause=${CS:0:12} verdict=unknown" "$LOG" && ok \
  || bad "§3 unreadable member files: verdict=unknown (log: $(grep BATCH "$LOG"))"
grep -q 'verdict=disjoint' "$LOG" && bad "§3 unreadable is never disjoint" || ok

# rate limited: no verdict line, one UNREAD line, the tick still ends.
reset_case; echo 403 > "$T/closedmode"; tick
grep -q 'BATCH_RESET draft=' "$LOG" && bad "§3 rate limited: no verdict line (log: $(grep BATCH "$LOG"))" || ok
grep -q "$SLUG BATCH_RESET_UNREAD rc=75" "$LOG" && ok || bad "§3 rate limited: one BATCH_RESET_UNREAD rc=75 line (log: $(tail -5 "$LOG"))"
[ "$TICK_RC" = 0 ] && grep -q ' TICK demo-os tick=' "$LOG" && ok || bad "§3 rate limited: the tick ends normally (rc=$TICK_RC, tail: $(tail -3 "$LOG"))"

# not opted in: no queue_mode line, nothing read, nothing written.
reset_case; printf 'slug=%s\n' "$SLUG" > "$T/h/config/mergify/repos/demo-os.conf"; tick
grep -q 'BATCH_RESET' "$LOG" && bad "§3 not opted in: no line (log: $(grep BATCH "$LOG"))" || ok
grep -q 'state=closed' "$T/gh-calls.txt" && bad "§3 not opted in: the closed list is not read" || ok
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$T/h/config/mergify/repos/demo-os.conf"

# ============================================================================
# §4. D2: the call site is what writes the line
# ============================================================================
sed '/bres_tick "\$SLUG"/d' "$T/h/bin/merge-conductor.sh" > "$T/h/bin/mc-nocall.sh"
if cmp -s "$T/h/bin/merge-conductor.sh" "$T/h/bin/mc-nocall.sh"; then
  bad "§4 the conductor carries a bres_tick \"\$SLUG\" call to remove"
else
  CONDUCTOR="$T/h/bin/mc-nocall.sh"; reset_case; tick
  grep -q 'BATCH_RESET draft=' "$LOG" && bad "§4 without the call no line is written" || ok
fi

echo "queue-batch-reset.bh-5372: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
