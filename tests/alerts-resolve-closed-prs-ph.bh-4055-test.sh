#!/bin/bash
# tests/alerts-resolve-closed-prs-ph.bh-4055-test.sh — bin/alerts-resolve-closed-prs.sh
# closes a pipeline-health row whose `prs=` token names ONLY closed PRs (BH-4055).
# Runs the REAL script with a curl stub serving /api/alerts/open and recording
# the resolve POST, and a jobs-client that records the local alert_resolve ids.
#   C1  the leadunqueued row (real line shape, bin/pipeline-health.sh) + its PR closed -> resolved,
#       local row id ph-leadunqueued_… (the akey minus alert:)
#   C2  a stalepr row prs=o/r#5,o/r#6, both closed -> resolved
#   C3  the same row with only #5 closed -> not resolved
#   C4  prs=o/r#40 with #4 closed -> not resolved; the same number in another repo -> not resolved
#   C5  a ph row naming the PR URL but carrying no prs= -> not resolved
#   C6  a closed ref in another case (O/R#5) -> resolved (D17)
#   C7  the mq-* akey path still resolves; mq-headbound still never does
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/alerts-resolve-closed-prs-ph.bh-4055-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/env" "$T/logs" "$T/flags" "$T/state" "$T/stub" "$T/bin"
export HARNESS="$T" PATH="$T/stub:$PATH" FLEET_CONF="$T/fleet.conf" ALERTS_CONF="$T/alerts.conf"
: > "$T/alerts.conf"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=s\n' > "$T/env/global.env"
printf 'ts o/r - - 5 box-ts 10.0.0.2\n' > "$FLEET_CONF"
touch "$T/flags/alerts-db"
cat > "$T/bin/jobs-client.sh" <<'JC'
alert_resolve() { printf '%s\n' "$@" >> "$HARNESS/local-resolve.log"; echo "$#"; }
JC
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""; url=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && printf '%s\n' "\$a" >> "$T/posts.jsonl"
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */api/alerts/open) cat "$T/open.json" ;;
  */api/alerts/resolve) echo '{"resolved":1}' ;;
  *) echo '{}' ;;
esac
STUB
cat > "$T/stub/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$T/gh.log"; exit 1
STUB
chmod +x "$T/stub/curl" "$T/stub/gh"

# The leadunqueued line exactly as bin/pipeline-health.sh section 13d words it.
LU='[pipeline-health] o/r #5 has lead-verdict success on abcdef123456 for 45m and is not in the merge queue (labels: -); prs=o/r#5; the conductor enqueues a lead-cleared head through mc_enqueue_mergify — check logs/merge-conductor.log for it: https://github.com/o/r/pull/5'
SP='[pipeline-health] ts: harness PR(s) #5,#6 open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert prs=o/r#5,o/r#6'
S40='[pipeline-health] ts: harness PR(s) #40 open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert prs=o/r#40'
SX='[pipeline-health] x: harness PR(s) #5 open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert prs=other/repo#5'
MIG='[pipeline-health] migration owed after the merge of https://github.com/o/r/pull/5 — apply it'
jq -n --arg lu "$LU" --arg sp "$SP" --arg s40 "$S40" --arg sx "$SX" --arg mig "$MIG" '{alerts:[
  {id:1, akey:"alert:ph-leadunqueued_o_r_5_abcdef123456", line:$lu},
  {id:2, akey:"alert:ph-stalepr_ts", line:$sp},
  {id:3, akey:"alert:ph-stalepr_ts40", line:$s40},
  {id:4, akey:"alert:ph-stalepr_x", line:$sx},
  {id:5, akey:"alert:ph-migration_x", line:$mig},
  {id:6, akey:"mq-hb-lander:ts:5", line:"Merge queue: #5 rebase CONFLICTS: https://github.com/o/r/pull/5"},
  {id:7, akey:"mq-headbound:ts:5", line:"Merge queue: #5 head is not the approved sha: https://github.com/o/r/pull/5"}
]}' > "$T/open.json"
reset() { rm -f "$T/posts.jsonl" "$T/gh.log" "$T/local-resolve.log"; : > "$T/logs/alerts-groom.log"; }
ids() { jq -c '.ids' "$T/posts.jsonl" 2>/dev/null; }

echo "--- C1/C2/C4/C5/C7: o/r#5, o/r#6 and o/r#4 closed"
reset
"$DIR/bin/alerts-resolve-closed-prs.sh" "o/r#5" "o/r#6" "o/r#4"; RC=$?
[ "$RC" = 0 ] && ok || bad "rc=$RC"
[ "$(ids)" = "[1,2,6]" ] && ok || bad "resolved $(ids), want [1,2,6]: leadunqueued (C1), stalepr #5,#6 (C2), mq akey (C7) — never #40 (C4), another repo (C4), a URL mention (C5), mq-headbound (C7)"
grep -qxF ph-leadunqueued_o_r_5_abcdef123456 "$T/local-resolve.log" 2>/dev/null \
  && ok || bad "C1: the local row id is not the akey's ph id: $(cat "$T/local-resolve.log" 2>/dev/null)"
grep -qxF ph-stalepr_ts "$T/local-resolve.log" 2>/dev/null && ok || bad "C2: no local resolve for ph-stalepr_ts"
grep -q 'resolve 1 (pr-closed-wake/ph)' "$T/logs/alerts-groom.log" && ok || bad "C1: no (pr-closed-wake/ph) log line: $(cat "$T/logs/alerts-groom.log")"
grep -q 'resolve 6 (pr-closed-wake/akey)' "$T/logs/alerts-groom.log" && ok || bad "C7: the mq row did not resolve on its akey"
[ ! -s "$T/gh.log" ] && ok || bad "GitHub was asked: $(cat "$T/gh.log")"

echo "--- C3: only one of the listed PRs closed"
reset
"$DIR/bin/alerts-resolve-closed-prs.sh" "o/r#6"
[ "$(ids)" = "" ] && ok || bad "C3: resolved $(ids) with o/r#5 still open"

echo "--- C6: the closed ref in another case"
reset
"$DIR/bin/alerts-resolve-closed-prs.sh" "O/R#5"
[ "$(ids)" = "[1,6]" ] && ok || bad "C6: resolved $(ids), want [1,6]"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
