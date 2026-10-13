#!/bin/bash
# tests/main-red-pr-pair.bh-997-test.sh — BH-997: `--explain` is READ-ONLY.
#
#   THE PROPERTY UNDER TEST: an operator's dry run must cost the lane nothing.
#   Before this, `bin/main-red-pr-pair.sh --explain` took the lane's dedupe
#   lock (so a dry run and the */10 tick silenced each other), pruned the
#   pr-errors ledger, and wrote a TERMINAL verdict row per unledgered head
#   using whatever MAIN_RED_ERR_RE happened to be in the operator's shell —
#   a row the cron lane then trusts for 14 days.
#
#   So: explain takes no lock, creates no state dir, prunes nothing, writes no
#   ledger row; it READS the rows that exist (its output matches what the lane
#   would say) and prints WOULD RECORD for the heads it would have persisted.
#   The last case is the control: a plain tick still does all of it.
#
# Every timestamp here is a literal. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$DIR/bin/main-red-pr-pair.sh" ] || {
  echo "FAIL: bin/main-red-pr-pair.sh does not exist — there is nothing to test"
  echo "main-red-pr-pair-bh-997: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair.bh-997-test: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-pr-pair.sh" "$T/bin/"
# TEST-CHANGE (BH-782): bin/lib/gh-pr-list.sh reads REST through the contract
# lib now; without gh-rest.sh beside it every list answers 75 "no contract lib
# on this box" and this suite would be measuring a missing file.
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim, same contract as the sibling suite: the open PR list from
# $T/pulls.json, the runs of one head from $T/runs-<sha>.json, the failing job
# of a run from $T/jobs-<runid>.txt, one job's log from $T/joblog-<jobid>.txt.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      # TEST-CHANGE (BH-782): the REST list goes through
                              # bin/lib/gh-rest.sh, which runs `gh api -i` and
                              # parses the status line. Same fixture body, with
                              # the status line the library now reads.
                              case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
MARKS="$T/state/main-red/pairs/o-r"
LEDGER="$T/state/main-red/pr-errors/o-r"
LOCK="$T/locks/main-red-pr-pair.lock"
LOG="$T/logs/main-red-pr-pair.log"

pulls() {
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}

head_runs() {
  local sha="$1"; shift
  local out='{"workflow_runs":[' first=1 spec n p c t id s
  for spec in "$@"; do
    IFS='|' read -r n p c t id s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" \
      --argjson id "$id" --arg c "$c" \
      '{name:$n, path:$p, status:$s,
        conclusion:(if $c=="null" then null else $c end),
        created_at:$t, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
job_of()  { printf '%s\t%s\n' "$2" "$3" > "$T/jobs-$1.txt"; }
joblog()  { printf '%s\n' "$2"          > "$T/joblog-$1.txt"; }

drive() { # drive [args...] — one tick; stdout in $T/out.txt
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
out()     { cat "$T/out.txt" 2>/dev/null; }
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
# the ledger as bytes: path, size, mtime of every file, plus their contents
snap()    { { find "$LEDGER" -type f -printf '%p %s %T@\n' 2>/dev/null | sort
              find "$LEDGER" -type f 2>/dev/null | sort | xargs -r sha256sum; } ; }

reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"
  scratch_rm "$T/state/main-red"; rm -f "$LOCK" "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt
}

# the fixture every case runs against: two open PRs failing the same job with
# the same first error, well inside one window.
fixture() {
  pulls "1:aaaa111:2026-09-18T10:00:00Z" "2:bbbb222:2026-09-18T10:10:00Z"
  head_runs aaaa111 "Harness CI|$CI|failure|2026-09-18T10:00:00Z|9001"
  head_runs bbbb222 "Harness CI|$CI|failure|2026-09-18T10:10:00Z|9002"
  job_of 9001 "decisions" 8001; joblog 8001 "2026-09-18T10:01:02Z FAIL: scratch.sh: No such file"
  job_of 9002 "decisions" 8002; joblog 8002 "2026-09-18T10:11:02Z FAIL: scratch.sh: No such file"
}

# 1. THE LOCK IS NOT THE DRY RUN'S TO TAKE. A tick holding it must not silence
#    --explain, and --explain must not touch the file the tick is holding.
reset_case; fixture
printf 'held by the tick\n' > "$LOCK"
lock_before=$(stat -c '%s' "$LOCK")
exec 9>>"$LOCK"
if command -v flock >/dev/null 2>&1 && flock -n 9; then
  drive --explain o/r
  case "$(out)" in
    *"WOULD ALERT"*) ok ;;
    *) bad "1: --explain printed nothing while the lane lock was held: $(out)" ;;
  esac
  case "$(out)" in
    *"skipping this one"*) bad "1: --explain was skipped by a held lane lock" ;;
    *) ok ;;
  esac
  [ "$(stat -c '%s' "$LOCK")" = "$lock_before" ] && ok \
    || bad "1: --explain truncated the lock file ($lock_before bytes -> $(stat -c '%s' "$LOCK"))"
  flock -u 9
else
  echo "1: flock unavailable — lock cases not run"; ok; ok; ok
fi
exec 9>&-

# 2. no lock file on a fresh tree, and --explain creates neither the file nor
#    the locks/ directory itself.
reset_case; fixture
scratch_rm "$T/locks"
drive --explain o/r
[ -e "$LOCK" ] && bad "2: --explain created $LOCK" || ok
[ -d "$T/locks" ] && bad "2: --explain created the locks/ directory" || ok
mkdir -p "$T/locks"

# 3. THE LEDGER IS BYTES. A seeded row survives unchanged, an aged row is not
#    pruned, no new row is written, nothing is sent, no marker appears.
reset_case; fixture
mkdir -p "$LEDGER"
printf 'decisions\tFAIL: seeded text\t2026-09-18T10:00:00Z\n' > "$LEDGER/aaaa111.tsv"
printf 'decisions\tFAIL: old and aged out\t2026-08-01T00:00:00Z\n' > "$LEDGER/old.tsv"
touch -d '2026-08-01 00:00:00Z' "$LEDGER/old.tsv"
before=$(snap)
drive --explain o/r
[ "$(snap)" = "$before" ] && ok || bad "3: --explain changed the ledger:
$(diff <(printf '%s\n' "$before") <(snap))"
[ -e "$LEDGER/old.tsv" ] && ok || bad "3: --explain pruned the aged row old.tsv"
[ -e "$LEDGER/bbbb222.tsv" ] && bad "3: --explain wrote a verdict row for bbbb222" || ok
[ "$(alerts)" = 0 ] && ok || bad "3: --explain sent an alert: $(cat "$T/alerts.txt")"
[ -z "$(ls -A "$MARKS" 2>/dev/null)" ] && ok || bad "3: --explain wrote a marker: $(ls -A "$MARKS")"

# 4. WOULD RECORD names the row it did not write — and the row that EXISTS is
#    read, not recomputed: the seeded error differs from the log, so a recompute
#    would group the two PRs and print WOULD ALERT. It must not.
case "$(out)" in
  *"WOULD RECORD o/r bbbb222 :: decisions"*) ok ;;
  *) bad "4: no WOULD RECORD line for the unledgered head: $(out)" ;;
esac
case "$(out)" in
  *"WOULD RECORD o/r aaaa111"*) bad "4: --explain recomputed a head that already has a ledger row" ;;
  *"WOULD ALERT"*) bad "4: --explain ignored the seeded row and grouped on a fresh recompute: $(out)" ;;
  *) ok ;;
esac

# 5. the operator's MAIN_RED_ERR_RE override must never reach the real ledger.
reset_case; fixture
mkdir -p "$LEDGER"
printf 'decisions\tFAIL: seeded text\t2026-09-18T10:00:00Z\n' > "$LEDGER/aaaa111.tsv"
before=$(snap)
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
         ALERT_SINK="$T/alerts.txt" MAIN_RED_ERR_RE='NEVERMATCHES'; unset GH_TOKEN
  bash "$T/bin/main-red-pr-pair.sh" --explain o/r >"$T/out.txt" 2>"$T/err.txt" )
[ "$(snap)" = "$before" ] && ok || bad "5: an ERR_RE override reached the ledger:
$(diff <(printf '%s\n' "$before") <(snap))"
grep -rq '(unavailable)' "$LEDGER" 2>/dev/null \
  && bad "5: a shell-only verdict was persisted: $(grep -r '(unavailable)' "$LEDGER")" || ok

# 6. --explain creates no state dir at all.
reset_case; fixture
drive --explain o/r
[ -d "$T/state/main-red/pr-errors" ] && bad "6: --explain created state/main-red/pr-errors" || ok
[ -d "$T/state/main-red/pairs" ] && bad "6: --explain created state/main-red/pairs" || ok
[ -d "$T/state/main-red" ] && bad "6: --explain created state/main-red" || ok

# 7. CONTROL: the real tick still does every one of those things. Without this
#    case, "explain writes nothing" could be passing because nothing works.
reset_case; fixture
mkdir -p "$LEDGER"
printf 'decisions\tFAIL: scratch.sh: No such file\t2026-09-18T10:00:00Z\n' > "$LEDGER/aaaa111.tsv"
printf 'decisions\tFAIL: old and aged out\t2026-08-01T00:00:00Z\n' > "$LEDGER/old.tsv"
touch -d '2026-08-01 00:00:00Z' "$LEDGER/old.tsv"
drive o/r
[ -s "$LEDGER/bbbb222.tsv" ] && ok || bad "7: a real tick did not record bbbb222"
[ -e "$LEDGER/old.tsv" ] && bad "7: a real tick did not prune the aged row" || ok
[ -e "$LOCK" ] && ok || bad "7: a real tick did not take the lane lock"
[ "$(alerts)" = 1 ] && ok || bad "7: a real tick sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
case "$(out)" in
  *"WOULD "*) bad "7: a real tick printed WOULD: $(out)" ;;
  *) ok ;;
esac

# 8. no scratch dir outlives the run.
[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'main-red-explain.*' -print -quit 2>/dev/null)" ] && ok \
  || bad "8: an --explain scratch dir was left behind: $(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'main-red-explain.*')"

echo "main-red-pr-pair-bh-997: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
