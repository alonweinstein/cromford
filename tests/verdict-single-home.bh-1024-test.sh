#!/bin/bash
# tests/verdict-single-home.bh-1024-test.sh — ONE HOME FOR THE REVIEWED SHA AND
# THE VERDICT, AND A FLAG THAT MAKES THE LEDGER THE FIRST READER.
#
# THE DEFECT (BH-1024). The same two facts — "what did a reviewer say" and
# "which sha did they say it about" — live in four places: the verdict artifact,
# a build record's `reviewed-sha` file, the `apverdict` lines in the merge
# conductor's attempts.txt, and `.sha` in state/<project>.pr-reviews.json. Three
# of those are files on one box, so a lane on another box cannot see them, and a
# stale one costs a second paid review or a parked PR. This slice adds the
# LEDGER as the first reader behind a settings flag (`verdict_single_home`), and
# gives bin/review-prs.sh a ledger write it never had, while every file write
# and every file read stays exactly where it is as the write-through cache.
#
# WHAT THIS SUITE PINS — real blocks and real client functions, never restated
# logic:
#   §0  the three new bin/jobs-client.sh readers against a stub worker:
#       verdict_single_home_on (on / off / no row / env fallback / an outage is
#       never cached / one settings request per process), job_verdict_covers
#       (match, provisional, old sha, a PREFIX of the head, a missing source, a
#       404, an outage) and job_verdict_history.
#   §1  a rebase that moves the head MOVES THE ARTIFACT: job_verdict_rebind's
#       real PUT body, and bin/rebase-train.sh's own `# >>> head-bound approval`
#       block calling it beside the file write. GREEN BEFORE THIS TICKET — a
#       regression pin on behaviour the ticket requires and main already has.
#   §2  a sweep tick with a STALE reviewed-sha file and a FRESH ledger sha must
#       NOT park: bin/merge-sweep.sh's own `# >>> head-bound approval` block,
#       driven both ways. GREEN BEFORE THIS TICKET — the second regression pin.
#   §3  bin/review-autopilot.sh, driven as the real script: a ledger verdict
#       bound to this head and written by review-prs stands it down with no
#       agent call; a BUILD's verdict row (no `source`) does NOT; with the flag
#       off the JSON file decides exactly as it does today. Since BH-3930 the
#       ledger answer comes from a review_bought stub and no flag gates it.
#   §4  bin/review-prs.sh's `# >>> review verdict ledger` block: pr_url then
#       verdict, bound to the reviewed sha, REQUEST_CHANGES recorded as BLOCK,
#       a refused job_open logged and nothing else written, flag off = silent.
#   §5  mc_ap_consumed: an APPROVE bound to this head answers first, a BLOCK
#       bound to it does NOT (parking it below is free, a re-review is not), the
#       attempts.txt line is the fallback, and an outage falls back rather than
#       claiming "consumed".
#   §6  THE NEGATIVE THE WHOLE SLICE RESTS ON: with the flag off, none of the
#       three blocks makes any request beyond the one settings read.
#
# TEST-CHANGE (BH-782, rebase onto main): the §3 fixture's open-PR list moved to
# a REST read through bin/lib/gh-rest.sh (`gh api -i -X GET ...`) underneath
# this ticket. The fixture now copies that module too and the `gh` stub answers
# the pulls list with the status line the library parses, the same fix main's
# own review-autopilot suites carry for the same change.
#
# Run from anywhere: bash tests/verdict-single-home.bh-1024-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# ONE clock read for the whole file (bin/test-determinism-lint.sh): nothing below
# compares times — it only ages a PR fixture past the autopilot's 12h cutoff and
# keeps fixture names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these blocks"; exit 1; }
# A real credential in the runner's environment must never reach a fixture, and
# a real operator flag must never decide what this suite proves.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID \
      VERDICT_SINGLE_HOME HARNESS_PR_AUTHORS

marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

# ── the stub worker ──────────────────────────────────────────────────────────
# One fixture file per route, and EVERY request is recorded, so "the flag off
# makes no second request" is an assertion about traffic rather than about an
# implementation detail. Missing fixture = 404, which jobs-client reads as a
# REAL answer (rc 2) and never as an outage.
mkdir -p "$T/fakebin" "$T/h/bin" "$T/fix"
FIX="$T/fix"
# BH-1194: bin/jobs-client.sh is a SHIM that sources bin/lib/jobs/*.sh and
# `exit 1`s when a module is missing, so a fixture that copies the client alone
# gets a client that refuses to load. The modules come with it, here and in §3.
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\t%s\t%s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
[ "${WORKER_DOWN:-0}" = 1 ] && exit 7
case "$METHOD $URL" in
  "POST "*/api/jobs)            F="$FIX/jobopen" ;;
  *"/api/jobs/"*"/artifacts")   printf '{"artifact":{}}\n200\n'; exit 0 ;;
  *"/api/jobs/"*"/heartbeat")   printf '{"ok":true}\n200\n'; exit 0 ;;
  "PATCH "*/api/jobs/*)         if [ "${JOBPATCH_FAIL:-0}" = 1 ]
                                then printf '{"error":"boom"}\n500\n'
                                else printf '{"job":{}}\n200\n'; fi; exit 0 ;;
  *"/api/verdict/history"*)     F="$FIX/history" ;;
  *"/api/verdict"*)             F="$FIX/verdict" ;;
  *"/api/settings/"*)           F="$FIX/setting" ;;
  *)                            F="" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then
  CODE=200; [ -f "$F.code" ] && CODE=$(cat "$F.code")
  printf '%s\n%s\n' "$(cat "$F")" "$CODE"; exit 0
fi
printf '{"error":"not found"}\n404\n'
STUB
chmod +x "$T/fakebin/curl"

REQ_SINK="$T/req.txt"; : > "$REQ_SINK"
flag_on()  { printf '%s' '{"setting":{"key":"verdict_single_home","value":"1"}}' > "$FIX/setting"; }
flag_off() { printf '%s' '{"setting":{"key":"verdict_single_home","value":"0"}}' > "$FIX/setting"; }
flag_norow() { rm -f "$FIX/setting"; }

client() { # client <shell snippet> — runs it with the REAL jobs-client loaded
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$REQ_SINK" WORKER_DOWN="${WORKER_DOWN:-0}" \
           VERDICT_SINGLE_HOME="${VERDICT_SINGLE_HOME_V-}"
    unset JOB_ID JOB_PHASE_ID
    [ -n "${VERDICT_SINGLE_HOME_V-}" ] || unset VERDICT_SINGLE_HOME
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh"; eval "$1" )
}
# `grep -c` prints 0 and exits 1 on no match, so the count is read from stdout
# and never from an `|| echo 0` that would print a SECOND zero.
reqs() { local n; n=$(grep -c "$1" "$REQ_SINK" 2>/dev/null); printf '%s' "${n:-0}"; }
# TEST-CHANGE (BH-1510.1): /api/model-routes/ is excluded as well. It is the
# reviewer's MODEL lookup (review_model -> the build.review route), made on every
# tick whatever this flag says, so it is not part of what the flag may cost; the
# ledger requests §6 pins are still counted, all of them.
# /api/flags/pr-state-rows is not a ledger read either: since BH-1387 the
# apverdict file miss goes through mc_attempt_has, which resolves the BH-1385
# pr-state-rows flag (once per process) before it would ask pr_attempts.
other_reqs() { local n; n=$(grep -v '/api/model-routes/' "$1" 2>/dev/null | grep -v '/api/flags/pr-state-rows' | grep -cv '/api/settings/'); printf '%s' "${n:-0}"; }

PR=https://github.com/example-org/demo-os/pull/12
HEAD_NEW=cafebabe1234cafebabe1234cafebabe12345678
HEAD_OLD=deadbeef9999deadbeef9999deadbeef99999999

# verdict_row <reviewed_sha> <settled true|false> [source] [word] — the
# /api/verdict body. The word defaults to APPROVE because that is what almost
# every case here is about; BLOCK is the one that proves "bound to this head" and
# "approved" are different questions.
verdict_row() {
  local rsha="$1" settled="$2" src="${3:-}" word="${4:-APPROVE}"
  local detail
  detail=$(jq -nc --arg s "$rsha" --argjson st "$settled" --arg src "$src" \
    '{tier:"2",provenance:"claude",served_by:"claude",reviewed_sha:$s,settled:$st}
     + (if $src == "" then {} else {source:$src} end)')
  jq -nc --arg s "$rsha" --arg d "$detail" --arg w "$word" \
    '{verdict:$w,tier:"2",provenance:"claude",job_id:"build-x",reviewed_sha:$s,
      artifacts:[{artifact_kind:"verdict",artifact_ref:$w,detail:$d}]}' > "$FIX/verdict"
}

# ═════════════════════════════════════════════════════════════════════════════
# §0 — the three readers
# ═════════════════════════════════════════════════════════════════════════════
client 'type verdict_single_home_on >/dev/null 2>&1' \
  && ok || bad "§0: the jobs client has no verdict_single_home_on — nothing can land dark behind the flag row"
client 'type job_verdict_covers >/dev/null 2>&1' \
  && ok || bad "§0: the jobs client has no job_verdict_covers — no lane can ask the ledger 'is this head already covered'"
client 'type job_verdict_history >/dev/null 2>&1' \
  && ok || bad "§0: the jobs client has no job_verdict_history"

flag_on
client 'verdict_single_home_on'; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: the settings row '1' must read as ON (rc 0), got $RC"
flag_off
client 'verdict_single_home_on'; RC=$?
[ "$RC" != 0 ] && ok || bad "§0: the settings row '0' must read as OFF, got rc $RC"
flag_norow
client 'verdict_single_home_on'; RC=$?
[ "$RC" != 0 ] && ok || bad "§0: NO settings row and no env must read as OFF — today's behaviour is the default, got rc $RC"
VERDICT_SINGLE_HOME_V=1 client 'verdict_single_home_on'; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: with no row, \$VERDICT_SINGLE_HOME=1 is the documented fallback and must read ON, got rc $RC"

# ONE settings request per process, the job_for_record memo rule.
flag_on
: > "$REQ_SINK"
client 'verdict_single_home_on && verdict_single_home_on && verdict_single_home_on'; RC=$?
{ [ "$RC" = 0 ] && [ "$(reqs '/api/settings/verdict_single_home')" = 1 ]; } \
  && ok || bad "§0: three asks in one process must cost ONE settings request (rc $RC, $(reqs '/api/settings/verdict_single_home') requests)"

# An OUTAGE is never cached and never reads as ON.
: > "$REQ_SINK"
OUT=$(WORKER_DOWN=1 client 'verdict_single_home_on; echo "rc=$?"; verdict_single_home_on; echo "rc=$?"')
[ "$OUT" = "$(printf 'rc=1\nrc=1')" ] \
  && ok || bad "§0: an outage must read as OFF on every call (today's behaviour), got '$OUT'"
[ "$(reqs '/api/settings/verdict_single_home')" = 2 ] \
  && ok || bad "§0: an outage must NOT be cached — two asks, two requests, got $(reqs '/api/settings/verdict_single_home')"

# job_verdict_covers — the whole point is that silence is never "covered".
verdict_row "$HEAD_NEW" true review-prs
client "job_verdict_covers '$PR' '$HEAD_NEW' review-prs"; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: a settled row bound to this head and written by review-prs IS covered, got rc $RC"
client "job_verdict_covers '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: with no source filter the same row is covered, got rc $RC"
client "job_verdict_covers '$PR' '$HEAD_OLD' review-prs"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a row bound to the PREVIOUS sha is NOT covered (rc 2), got $RC"
client "job_verdict_covers '$PR' '${HEAD_NEW}ff' review-prs"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a reviewed_sha that is a PREFIX of the head is not a match (rc 2), got $RC"
client "job_verdict_covers '$PR' '${HEAD_NEW:0:12}' review-prs"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: an abbreviated head is not the reviewed sha — exact equality only (rc 2), got $RC"
verdict_row "$HEAD_NEW" false review-prs
client "job_verdict_covers '$PR' '$HEAD_NEW' review-prs"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a PROVISIONAL row covers nothing — the demoters have not run (rc 2), got $RC"
verdict_row "$HEAD_NEW" true ""
client "job_verdict_covers '$PR' '$HEAD_NEW' review-prs"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a row with NO source must not satisfy a review-prs filter (rc 2), got $RC"
client "job_verdict_covers '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: the same sourceless row IS covered when no source is asked for, got rc $RC"

# The verdict WORD filter. "Bound to this head" and "approved" are different
# facts, and a caller that skips work on the first when it meant the second has
# skipped it on a reviewer saying NO.
verdict_row "$HEAD_NEW" true "" APPROVE
client "job_verdict_covers '$PR' '$HEAD_NEW' '' APPROVE"; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: an APPROVE bound to this head satisfies an APPROVE filter, got rc $RC"
verdict_row "$HEAD_NEW" true "" BLOCK
client "job_verdict_covers '$PR' '$HEAD_NEW' '' APPROVE"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a settled BLOCK bound to this head must NOT satisfy an APPROVE filter (rc 2), got $RC"
client "job_verdict_covers '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 0 ] && ok || bad "§0: the same BLOCK row IS 'covered' when no word is asked for — the filter is the caller's choice, got rc $RC"

rm -f "$FIX/verdict"
client "job_verdict_covers '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: no row at all is a real 'not covered' (rc 2), got $RC"
verdict_row "$HEAD_NEW" true review-prs
WORKER_DOWN=1 client "job_verdict_covers '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 1 ] && ok || bad "§0: an outage is rc 1, NEVER 'covered' and never 'not covered' (D11), got $RC"

# job_verdict_history — the rounds, oldest first.
jq -nc '{pr:"x",job_id:"rv-2",rounds:[
  {verdict:"BLOCK",reviewed_sha:"aaa",tier:"2",provenance:"claude",source:"run-build",created_at:"2026-09-19T01:00:00Z",job_id:"rv-1"},
  {verdict:"APPROVE",reviewed_sha:"bbb",tier:"1",provenance:"claude",source:"run-build",created_at:"2026-09-19T02:00:00Z",job_id:"rv-2"}]}' > "$FIX/history"
OUT=$(client "job_verdict_history '$PR'"); RC=$?
{ [ "$RC" = 0 ] && [ "$(wc -l <<<"$OUT")" = 2 ] \
  && [ "$(head -1 <<<"$OUT" | cut -f1,2)" = "$(printf 'BLOCK\taaa')" ] \
  && [ "$(tail -1 <<<"$OUT" | cut -f1,2)" = "$(printf 'APPROVE\tbbb')" ]; } \
  && ok || bad "§0: job_verdict_history must print one TSV row per round, oldest first, got rc $RC: $OUT"
# EVERY ROUND NAMES ITS JOB. The rounds are keyed on the PR, not on one job, so
# a re-reviewed PR's history spans two `review-verdict` jobs — a TSV that did not
# say which is one an operator cannot read.
{ [ "$(head -1 <<<"$OUT" | cut -f7)" = rv-1 ] && [ "$(tail -1 <<<"$OUT" | cut -f7)" = rv-2 ]; } \
  && ok || bad "§0: each history row must carry its job_id as the last column, got: $OUT"
rm -f "$FIX/history"
client "job_verdict_history '$PR' >/dev/null"; RC=$?
[ "$RC" = 2 ] && ok || bad "§0: a PR the ledger has no history for is rc 2, got $RC"

# ═════════════════════════════════════════════════════════════════════════════
# §1 — a rebase that moves the head must move the artifact  (GREEN BEFORE BH-1024)
# ═════════════════════════════════════════════════════════════════════════════
# A regression pin, said plainly: main already rebinds at all seven movers. The
# ticket names it as an acceptance test, so it is one — and this is the case
# that goes red the day somebody drops the rebind beside a file write.
verdict_row "$HEAD_OLD" true ""
: > "$REQ_SINK"
client "job_verdict_rebind '$PR' '$HEAD_NEW'"; RC=$?
[ "$RC" = 0 ] && ok || bad "§1: job_verdict_rebind must move a row that names a reviewed sha, got rc $RC"
PUTB=$(awk -F'\t' '$1=="PUT" && $2 ~ /\/artifacts$/ {print $3}' "$REQ_SINK" | tail -1)
PUTD=$(jq -r '.detail // ""' <<<"$PUTB" 2>/dev/null)
[ "$(jq -r '.reviewed_sha' <<<"$PUTD" 2>/dev/null)" = "$HEAD_NEW" ] \
  && ok || bad "§1: the rebind PUT must carry the NEW sha, got: $PUTD"
{ [ "$(jq -r '.tier' <<<"$PUTD" 2>/dev/null)" = 2 ] \
  && [ "$(jq -r '.provenance' <<<"$PUTD" 2>/dev/null)" = claude ] \
  && [ "$(jq -r '.settled' <<<"$PUTD" 2>/dev/null)" = true ]; } \
  && ok || bad "§1: the rebind must rewrite every other field VERBATIM — an upsert that dropped tier/provenance erases the sweep's inputs. Got: $PUTD"

TRAIN="$T/train.sh"
marked '# >>> head-bound approval' '# <<< head-bound approval' "$DIR/bin/rebase-train.sh" > "$TRAIN"
[ -s "$TRAIN" ] && ok || bad "§1: bin/rebase-train.sh carries no '# >>> head-bound approval' block"
TD="$T/train-rec-$NOW"; mkdir -p "$TD/repo"
echo "$HEAD_OLD" > "$TD/reviewed-sha"
( cd "$TD/repo" && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one ) >/dev/null 2>&1
TSINK="$T/train-sink-$NOW"; : > "$TSINK"
( cd "$TD/repo" && D="$TD" PR="$PR" LOG="$TD/log" PROJECT=demo-os SINK="$TSINK" \
  bash -c '
    STAMP(){ echo "2026-09-19 00:00:00Z"; }
    job_verdict_rebind(){ printf "%s\t%s\n" "$1" "$2" >> "$SINK"; return 0; }
    . '"$TRAIN"'' ) >/dev/null 2>&1
TREAL=$( cd "$TD/repo" && git rev-parse HEAD )
[ "$(cut -f1 "$TSINK")" = "$PR" ] && [ "$(cut -f2 "$TSINK")" = "$TREAL" ] \
  && ok || bad "§1: the train block must rebind the LEDGER too, with (PR, new head). Got: $(cat "$TSINK")"
[ "$(head -1 "$TD/reviewed-sha")" = "$TREAL" ] \
  && ok || bad "§1: the file follows the ledger — it is the cache, and it must still be written. Got: $(cat "$TD/reviewed-sha")"

# ═════════════════════════════════════════════════════════════════════════════
# §2 — a stale file next to a fresh ledger sha must NOT park  (GREEN BEFORE BH-1024)
# ═════════════════════════════════════════════════════════════════════════════
# The second regression pin. The sweep reads LEDGER_RSHA first and the record's
# reviewed-sha file only when the ledger has nothing; a `continue` inside the
# block is legal only inside a loop, so the block runs inside a one-pass `for`.
SWEEP="$T/sweep.sh"
marked '# >>> head-bound approval' '# <<< head-bound approval' "$DIR/bin/merge-sweep.sh" > "$SWEEP"
[ -s "$SWEEP" ] && ok || bad "§2: the sweep carries no '# >>> head-bound approval' block"
sweep_case() { # sweep_case <case> <LEDGER_RSHA> <file-sha> <head>
  SD="$T/sweep-$1-$NOW"; mkdir -p "$SD/rec" "$SD/logs"
  mkdir -p "$SD/bin" && cp "$DIR/bin/alert-line.sh" "$SD/bin/"
  printf '%s\n' "$3" > "$SD/rec/reviewed-sha"
  : > "$SD/log"; : > "$SD/hbalert"; : > "$SD/logs/ALERTS.log"
  ( export H="$SD" D="$SD/rec" LOG="$SD/log" HBALERT="$SD/hbalert" \
           LEDGER_RSHA="$2" PHEAD="$4" PR="$PR"
    bash -c '
      STAMP(){ echo "2026-09-19 00:00:00Z"; }
      for _ in once; do
        . '"$SWEEP"'
      done' )
}
sweep_case fresh "$HEAD_NEW" "$HEAD_OLD" "$HEAD_NEW"
{ ! grep -q 'parked:' "$T/sweep-fresh-$NOW/log" && [ ! -s "$T/sweep-fresh-$NOW/logs/ALERTS.log" ]; } \
  && ok || bad "§2: a STALE reviewed-sha file beside a FRESH ledger sha must not park. Log: $(cat "$T/sweep-fresh-$NOW/log"); alerts: $(cat "$T/sweep-fresh-$NOW/logs/ALERTS.log")"
sweep_case stale "" "$HEAD_OLD" "$HEAD_NEW"
{ grep -q 'parked:' "$T/sweep-stale-$NOW/log" && [ -s "$T/sweep-stale-$NOW/logs/ALERTS.log" ]; } \
  && ok || bad "§2: with NO ledger sha the stale file still parks — the fallback is unchanged. Log: $(cat "$T/sweep-stale-$NOW/log")"

# ═════════════════════════════════════════════════════════════════════════════
# §3 — bin/review-autopilot.sh reads the ledger before it spends
# ═════════════════════════════════════════════════════════════════════════════
HA="$T/ha"
mkdir -p "$HA/bin/lib" "$HA/logs" "$HA/locks" "$HA/state/review-autopilot" "$HA/env" "$T/apbin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$HA/bin/"
# TEST-CHANGE (BH-782): the open-PR list is a REST read through
# bin/lib/gh-rest.sh now (`gh api -i -X GET ...`), so the fixture copies that
# module too and the stub answers with the status line the library parses.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$HA/bin/lib/"
mkdir -p "$HA/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$HA/bin/lib/jobs/"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$HA/fleet.conf"
: > "$HA/env/global.env"
# BH-1510.1: the reviewer's model is a model_routes row, read through review_model.
# The worker stub 404s /api/model-routes/* (its catch-all) — the resolver's
# "worker unreachable" — so the lane serves this box's cache of #1507's table.
cp "$DIR/bin/lib/review-model.sh" "$HA/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$HA" demo-os
cat > "$HA/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent-calls.txt"
printf 'static review\nVERDICT: MERGE — fine\n' > "\$5"
exit 0
EOF
chmod +x "$HA/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$HA/bin/beat.sh"; chmod +x "$HA/bin/beat.sh"
# TEST-CHANGE (BH-3930, spec change): the autopilot's ledger skip asks
# bin/lib/review-bought.sh's review_bought now, not job_verdict_covers behind
# the verdict_single_home flag. This is a STUB of that lib, answering from
# $T/rb-answer (`hit <source> <WORD>` | `miss`), never the real one: once the
# real reads land they would make ledger requests §6 counts.
cat > "$HA/bin/lib/review-bought.sh" <<EOF
#!/bin/bash
RB_SOURCE=""; RB_WORD=""; RB_CLASS=""
review_dedupe_on() { [ "\${REVIEW_DEDUPE:-1}" != 0 ]; }
review_bought() {
  RB_SOURCE=""; RB_WORD=""; RB_CLASS=""
  local a s w; read -r a s w < "$T/rb-answer"
  [ "\$a" = hit ] || return 2
  RB_SOURCE=\$s; RB_WORD=\$w; RB_CLASS=approve; return 0
}
review_fp() { printf 'review:%s#%s@%s' "\$1" "\$2" "\$3"; }
review_skip_log() { printf 'review_skip_unchanged %s#%s lane=%s by=%s/%s\n' "\$2" "\$3" "\$5" "\$RB_SOURCE" "\$RB_WORD" >> "\$1"; }
EOF
echo miss > "$T/rb-answer"
AP_NUM=12
AP_SHA=$HEAD_NEW
# 13h old: past the autopilot's own 12h cutoff, derived from this file's one clock read.
AP_CREATED=$(date -u -d "@$((NOW - 46800))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
             || date -u -r "$((NOW - 46800))" '+%Y-%m-%dT%H:%M:%SZ')
jq -nc --arg s "$AP_SHA" --arg c "$AP_CREATED" --argjson n "$AP_NUM" \
  '[{number:$n,html_url:"https://github.com/example-org/demo-os/pull/12",title:"a built ticket",
     body:"harness build",head:{sha:$s,ref:"ticket/x"},base:{ref:"main"},draft:false,
     user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,merged_at:null,state:"open"}]' > "$T/pulls.json"
cat > "$T/apbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
Q=""; ARGS=()
while [ \$# -gt 0 ]; do
  case "\$1" in -q|--jq) Q="\$2"; shift 2 ;; *) ARGS+=("\$1"); shift ;; esac
done
A="\${ARGS[*]}"
answer() { if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi; }
case "\$A" in
  *"pulls?state=open"*"page=1"*) case "\$A" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac; answer "$T/pulls.json" ;;
  *"repos/"*"/pulls?"*)          echo "[]" ;;
  *"pr diff"*)                   printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"pr view"*"--json body"*)     echo "harness build" ;;
  *"pr view"*)                   echo "mergeable=MERGEABLE mergeState=CLEAN checks=" ;;
  *"pr comment"*)                printf '%s\n' "\$A" >> "$T/ap-comments.txt"; exit 0 ;;
  *)                             echo "" ;;
esac
exit 0
EOF
chmod +x "$T/apbin/gh"

ap_run() { # ap_run <case> — one whole review-autopilot.sh tick
  rm -f "$HA/state/review-autopilot/"* 2>/dev/null
  : > "$T/agent-calls.txt"; : > "$T/gh-calls.txt"; : > "$T/ap-comments.txt"
  : > "$HA/logs/review-autopilot.log"
  REQ_SINK="$T/req-ap-$1"; : > "$REQ_SINK"
  # FLEET_CONF explicitly: bin/fleet-conf.sh prefers /root/harness/fleet.conf
  # over the copy beside it, so on the hub a scratch registry is never read
  # unless the documented override says so.
  ( export PATH="$T/apbin:$T/fakebin:$PATH" HARNESS="$HA" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$REQ_SINK" REVIEW_AUTOPILOT_DAILY_CAP=0 FLEET_CONF="$HA/fleet.conf"
    unset JOB_ID JOB_PHASE_ID VERDICT_SINGLE_HOME
    bash "$HA/bin/review-autopilot.sh" ) >/dev/null 2>&1
  REQ_SINK="$T/req.txt"
}
APKEY="$HA/state/review-autopilot/example-org-demo-os-$AP_NUM-${AP_SHA:0:12}"

# (a) the ledger holds a review-prs verdict bound to this head.
# TEST-CHANGE (BH-3930): since BH-3930 the ledger speaks to the autopilot
# through review_bought, and the verdict_single_home flag no longer gates it,
# so the hit is the stub's answer. The flag stays on so §3 still reads as it did.
flag_on; verdict_row "$AP_SHA" true review-prs; echo "hit review-prs APPROVE" > "$T/rb-answer"
ap_run covered
[ ! -s "$T/agent-calls.txt" ] \
  && ok || bad "§3: a ledger verdict bound to this head must stand the autopilot down BEFORE it spends. agent-call: $(cat "$T/agent-calls.txt")"
grep -q '(ledger)' "$APKEY" 2>/dev/null \
  && ok || bad "§3: the skip marker must say the LEDGER answered, got: $(cat "$APKEY" 2>/dev/null)"
grep -q 'ledger verdict bound to this head' "$HA/logs/review-autopilot.log" \
  && ok || bad "§3: the log must name why it stood down, got: $(cat "$HA/logs/review-autopilot.log")"

# (b) THE NEGATIVE: a BUILD's own verdict row (no `source`) must NOT stand the
#     adversarial >12h review down — that review is the whole point of this lane.
# TEST-CHANGE (BH-3930): a builder-only round is what `--except-builder` misses,
# so the stub answers miss. The real builder-row negative is proven in
# tests/review-bought.bh-3930-test.sh once the reads land.
flag_on; verdict_row "$AP_SHA" true ""; echo miss > "$T/rb-answer"
ap_run build
[ -s "$T/agent-calls.txt" ] \
  && ok || bad "§3: a row this lane did not write (a build's own verdict) must NOT skip the adversarial review"

# (c) the flag OFF: the JSON state file decides, exactly as it does today.
# BH-3930: the flag no longer gates the autopilot's ledger read; with a miss
# from review_bought the file is still the fallback, word for word.
flag_off; echo miss > "$T/rb-answer"
printf '{"%s":{"sha":"%s","verdict":"APPROVE"}}' "$AP_NUM" "$AP_SHA" > "$HA/state/demo-os.pr-reviews.json"
ap_run fileskip
[ ! -s "$T/agent-calls.txt" ] \
  && ok || bad "§3: with the flag off the pr-reviews.json sha must still stand it down (the cache is unchanged)"
{ grep -q 'already reviewed by review-prs' "$HA/logs/review-autopilot.log" \
  && ! grep -q '(ledger)' "$HA/logs/review-autopilot.log"; } \
  && ok || bad "§3: the flag-off path must be today's line, word for word. Got: $(cat "$HA/logs/review-autopilot.log")"
rm -f "$HA/state/demo-os.pr-reviews.json"

# ═════════════════════════════════════════════════════════════════════════════
# §4 — bin/review-prs.sh writes the verdict into the ledger
# ═════════════════════════════════════════════════════════════════════════════
RPB="$T/review-prs-ledger.sh"
marked '# >>> review verdict ledger' '# <<< review verdict ledger' "$DIR/bin/review-prs.sh" > "$RPB"
[ -s "$RPB" ] \
  && ok || bad "§4: bin/review-prs.sh carries no '# >>> review verdict ledger' block — an external PR it reviewed is still invisible to job_verdict"

printf '%s' '{"job":{"id":"rv-1","status":"running"}}' > "$FIX/jobopen"; rm -f "$FIX/jobopen.code"
rp_block() { # rp_block <case> <VERDICT> — runs the block with the REAL client
  RPLOG="$T/rp-log-$1"; : > "$RPLOG"
  REQ_SINK="$T/req-rp-$1"; : > "$REQ_SINK"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$REQ_SINK" PROJECT=demo-os SLUG=example-org/demo-os NUM=12 \
           SHA="$HEAD_NEW" VERDICT="$2" TIER=2 SERVED=claude LOG="$RPLOG" \
           JOBPATCH_FAIL="${JOBPATCH_FAIL:-0}"
    unset JOB_ID JOB_PHASE_ID VERDICT_SINGLE_HOME
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh"
    STAMP(){ echo "2026-09-19 00:00:00Z"; }
    rp_prov_is_claude(){ [ "${1:-}" = claude ]; }
    # shellcheck source=/dev/null
    . "$RPB" )
  RPREQ="$T/req-rp-$1"
  REQ_SINK="$T/req.txt"
}
art_body() { # art_body <sink> <kind> — the PUT body for one artifact kind
  awk -F'\t' '$1=="PUT" && $2 ~ /\/artifacts$/ {print $3}' "$1" \
    | jq -c --arg k "$2" 'select(.artifact_kind == $k)' 2>/dev/null | head -1
}

flag_on
rp_block approve APPROVE
[ "$(awk -F'\t' '$1=="PUT" && $2 ~ /\/artifacts$/' "$RPREQ" | wc -l)" = 2 ] \
  && ok || bad "§4: the block must write BOTH artifacts (pr_url, then verdict), got: $(awk -F'\t' '$1=="PUT"' "$RPREQ")"
[ "$(awk -F'\t' '$1=="PUT" && $2 ~ /\/artifacts$/ {print $3}' "$RPREQ" | jq -r '.artifact_kind' | head -1)" = pr_url ] \
  && ok || bad "§4: pr_url must be written FIRST — /api/verdict?pr= resolves through it, and a verdict row nothing can reach is not a home"
VB=$(art_body "$RPREQ" verdict)
VD=$(jq -r '.detail // ""' <<<"$VB")
[ "$(jq -r '.artifact_ref' <<<"$VB")" = APPROVE ] \
  && ok || bad "§4: an APPROVE review records APPROVE, got: $VB"
[ "$(jq -r '.reviewed_sha' <<<"$VD" 2>/dev/null)" = "$HEAD_NEW" ] \
  && ok || bad "§4: the row must be BOUND to the sha that was reviewed, got: $VD"
{ [ "$(jq -r '.settled' <<<"$VD")" = true ] \
  && [ "$(jq -r '.source' <<<"$VD")" = review-prs ] \
  && [ "$(jq -r '.tier' <<<"$VD")" = 2 ] \
  && [ "$(jq -r '.provenance' <<<"$VD")" = claude ] \
  && [ "$(jq -r '.served_by' <<<"$VD")" = claude ]; } \
  && ok || bad "§4: the detail must carry settled/source/tier/provenance/served_by, got: $VD"
grep -q 'recorded in the ledger' "$RPLOG" \
  && ok || bad "§4: a successful ledger write says so once in the log, got: $(cat "$RPLOG")"

rp_block block REQUEST_CHANGES
[ "$(jq -r '.artifact_ref' <<<"$(art_body "$T/req-rp-block" verdict)")" = BLOCK ] \
  && ok || bad "§4: REQUEST_CHANGES is BLOCK in the ledger's vocabulary — that is the word every reader compares against"

# A FAILED CLOSE IS NAMED. The row is opened on the lane key
# (project, <slug>#<num>, review-verdict) — per PR, not per head; leaving it
# `running` means the NEXT review of this PR resolves against it, and one
# generic line would say nothing about why. The close is still best-effort —
# the tick must carry on — but silence about it is what makes the consequence
# unreadable an hour later.
JOBPATCH_FAIL=1 rp_block closefail APPROVE
grep -q "review-verdict job rv-1 NOT closed" "$RPLOG" \
  && ok || bad "§4: a failed job_update close must be one log line naming the job, not a swallowed || true. Got: $(cat "$RPLOG")"
# AND IT MUST NAME THE RIGHT CONSEQUENCE. The worker's double-build guard hands
# the SAME box its own open row back (`200 {resumed:true}`) and only 409s another
# box, so "the next review is refused" was true for a box that is not this one
# and false for the one that actually ticks this lane — an operator reading it
# would go looking for a refusal that never comes.
grep -q 'reuses this row from this box, and is refused from any other' "$RPLOG" \
  && ok || bad "§4: the failed-close line must say what actually happens next — this box RESUMES the row, another box is refused. Got: $(cat "$RPLOG")"
grep -q 'recorded in the ledger' "$RPLOG" \
  && ok || bad "§4: a failed CLOSE must not un-say the write that succeeded — both lines belong in the log. Got: $(cat "$RPLOG")"
grep -q 'NOT closed' "$T/rp-log-approve" \
  && bad "§4: a successful close must say nothing — a line every tick is a line nobody reads" || ok

# A REFUSED job_open is one log line and nothing else: the state file stays the
# only copy this tick, and the tick carries on.
printf '%s' '{"refused":true,"scope":"lane","reason":"a concurrency rule"}' > "$FIX/jobopen"
echo 409 > "$FIX/jobopen.code"
rp_block refused APPROVE
[ "$(awk -F'\t' '$1=="PUT" && $2 ~ /\/artifacts$/' "$RPREQ" | wc -l)" = 0 ] \
  && ok || bad "§4: a refused job_open must write NO artifact, got: $(cat "$RPREQ")"
{ grep -q 'ledger verdict NOT written' "$RPLOG" \
  && grep -q 'REFUSED lane :: a concurrency rule' "$RPLOG"; } \
  && ok || bad "§4: a refused job_open must be named in the log WITH the rule's own reason, never swallowed and never a stale one, got: $(cat "$RPLOG")"
printf '%s' '{"job":{"id":"rv-1","status":"running"}}' > "$FIX/jobopen"; rm -f "$FIX/jobopen.code"

# ═════════════════════════════════════════════════════════════════════════════
# §5 — the conductor's consumed check reads the ledger first
# ═════════════════════════════════════════════════════════════════════════════
# WHAT THIS FUNCTION IS FOR, AND WHAT IT IS NOT. Its only caller is the
# HEAD_MOVED arm, which mc_classify reaches only when the verdict IT read was
# not an APPROVE bound to this head — so on a tick whose classification and this
# read see the same row, the ledger arm answers "no" by construction and the
# `apverdict` line decides exactly as it did before this ticket. The ledger arm
# is the answer where the two DISAGREE: mc_verdict fell back to the record's
# reviewed-sha file because its own ledger read failed, or another lane bound an
# approval to this head between that read and this one. The cases below pin the
# function's own contract — what it answers for a given row — and the APPROVE
# filter, which is the difference between "somebody judged this head" and
# "somebody approved it".
mc() { # mc <attempts-content> <head> — mc_ap_consumed's true exit code
  local att="$T/att-$NOW.txt"
  printf '%s' "$1" > "$att"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$REQ_SINK" WORKER_DOWN="${WORKER_DOWN:-0}"
    unset JOB_ID JOB_PHASE_ID VERDICT_SINGLE_HOME
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    # AFTER the source: the lib sets MC_ATTEMPTS itself at source time, so an
    # export here would be silently replaced by the live hub's path.
    MC_ATTEMPTS="$att"
    type mc_ap_consumed >/dev/null 2>&1 || exit 3
    mc_ap_consumed 'example-org/demo-os#12' "$2" "$PR" )
  return $?
}
MCKEY='example-org/demo-os#12'
flag_on; verdict_row "$HEAD_NEW" true review-prs
mc "" "$HEAD_NEW"; RC=$?
[ "$RC" = 0 ] && ok || bad "§5: an approval already bound to THIS head is the fact the apverdict line stood in for — consumed with an EMPTY attempts file (rc 0), got $RC"
mc "" "$HEAD_OLD"; RC=$?
[ "$RC" != 0 ] && ok || bad "§5: a ledger row bound to the OLD sha consumes nothing — today's read is still bought, got rc $RC"
mc "apverdict $MCKEY $HEAD_OLD"$'\n' "$HEAD_OLD"; RC=$?
[ "$RC" = 0 ] && ok || bad "§5: the attempts.txt line remains the fallback (rc 0), got $RC"
# A BLOCK BOUND TO THIS HEAD IS NOT "CONSUMED". Answering rc 0 there would skip
# the caller's free park (hb_block_park) and send it on to buy a paid
# re-review — a worse answer than the line this read is standing in for.
verdict_row "$HEAD_NEW" true "" BLOCK
mc "" "$HEAD_NEW"; RC=$?
[ "$RC" != 0 ] && ok || bad "§5: a settled BLOCK bound to this head must NOT read as consumed — the park below is free and a re-review is not, got rc $RC"
mc "apverdict $MCKEY $HEAD_NEW"$'\n' "$HEAD_NEW"; RC=$?
[ "$RC" = 0 ] && ok || bad "§5: with a BLOCK in the ledger the attempts.txt line still decides, exactly as today (rc 0), got $RC"
verdict_row "$HEAD_NEW" true review-prs
flag_off
mc "" "$HEAD_NEW"; RC=$?
[ "$RC" != 0 ] && ok || bad "§5: with the flag OFF only the file line decides — the ledger must not be read, got rc $RC"
mc "apverdict $MCKEY $HEAD_NEW"$'\n' "$HEAD_NEW"; RC=$?
[ "$RC" = 0 ] && ok || bad "§5: flag off + the line present is today's answer (rc 0), got $RC"
flag_on
WORKER_DOWN=1 mc "" "$HEAD_NEW"; RC=$?
[ "$RC" != 0 ] && ok || bad "§5: an OUTAGE must fall back to the file, never claim 'consumed' (D11), got rc $RC"

# ═════════════════════════════════════════════════════════════════════════════
# §6 — with the flag off, nothing costs a second request
# ═════════════════════════════════════════════════════════════════════════════
# "Land dark" means byte-for-byte today's behaviour, and the cheapest proof of
# that is traffic: one settings read, and not one request more.
flag_off
rp_block dark APPROVE
[ "$(other_reqs "$RPREQ")" = 0 ] \
  && ok || bad "§6: with the flag off the review-prs block must make NO request beyond the settings read, got: $(cat "$RPREQ")"
[ ! -s "$RPLOG" ] \
  && ok || bad "§6: with the flag off the block must log nothing at all, got: $(cat "$RPLOG")"
: > "$T/req-mc-dark"
REQ_SINK="$T/req-mc-dark" mc "" "$HEAD_NEW" >/dev/null 2>&1
[ "$(other_reqs "$T/req-mc-dark")" = 0 ] \
  && ok || bad "§6: with the flag off mc_ap_consumed must not read the ledger, got: $(cat "$T/req-mc-dark")"
flag_norow
ap_run dark
[ "$(other_reqs "$T/req-ap-dark")" = 0 ] \
  && ok || bad "§6: with NO flag row the autopilot must make no ledger request at all, got: $(cat "$T/req-ap-dark")"

echo "verdict-single-home.bh-1024-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
