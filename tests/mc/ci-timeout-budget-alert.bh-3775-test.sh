#!/bin/bash
# tests/mc/ci-timeout-budget-alert.bh-3775-test.sh — ONE PAGE FOR A REPO WHOSE
# CHECK DIES AT ITS timeout-minutes, AND NO RERUN THAT CANNOT SUCCEED
# (BH-3786, the budget slice of BH-3775: AT-2 and AT-3 of the parent).
#
# THE BUG THIS PINS. Three PRs on one repo whose `CI` job dies at its 10-min
# limit each bought a full rerun from the BH-636 flake ladder, and then each
# paged its own CI_FLAKE_TWICE. Nobody saw the one repo-level cause, and a
# fourth PR on the repo bought a fourth doomed rerun. bin/lib/mc-ci-timeout-
# budget.sh now fires a repo-level CI_TIMEOUT_BUDGET once per (repo, check, UTC
# day), withholds reruns whose dead jobs are all TIMEOUT on a firing check, and
# mc_classify says so on the row.
#
# Driven, never grepped: every case runs the real bin/merge-conductor.sh in a
# fresh scratch tree against a fake gh, and asserts on logs/, state/ and the
# recorded gh calls. The scan sibling (BH-3785) is replaced by a scratch
# fixture bin/lib/mc-ci-timeout-scan.sh that reads $T/scan/<head>, so the suite
# is the same with or without the real scan merged.
#   D1-D5 three PRs, PR arm: one page, no CI_FLAKE_TWICE, daily rollover, the
#         firing TSV, the row reason;
#   E1    ledger-seeded siblings: the first tick buys no rerun, NO_RERUN once;
#   E2    one PR, empty ledger, short history: the one BH-636 rerun stays;
#   E3    ratio arm 12/20 at 615s fires (one history read for two PRs);
#   E3b   the same 12 at 40s (supersedes) does not;
#   E4    a firing CI plus a flaking E2E: only E2E is re-run and named at rung 2;
#   E4b   one run with a TIMEOUT job and a FLAKE job keeps its rerun;
#   E5    history read 500: no page, one rerun; E5b scan reports nothing;
#   E6    observe mode: no rerun, no write, still exactly one page.
# CIT_NO_BUDGET=1 runs the suite without the budget part file (the red-first
# check: D1 and E1 must fail).
# Run from anywhere: tests/mc/ci-timeout-budget-alert.bh-3775-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
TODAY=$(date -u -d "@$NOW" +%Y%m%d)
YDAY=$(date -u -d "@$((NOW-86400))" +%Y%m%d)
S=example-org/demo-os
CHECK='Unit tests (incl. Inner Circle parity guard)'
WF=.github/workflows/ci.yml
TA=2026-09-30T10:00:00Z

mkdir -p "$T/fakebin"
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$1 $2 $3 $4 $5" in
  "api -i -X GET repos/"*"/actions/workflows/"*"/runs?status=completed"*)
    [ -f "$T/hist.500" ] && { printf 'HTTP/1.1 500 Server Error\r\n\r\n{"message":"boom"}'; exit 0; }
    F="$T/hist.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F"; exit 0 ;;
  "api -i -X GET repos/"*"/actions/runs?head_sha="*)
    SHA=${5##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F"; exit 0 ;;
esac
case "$*" in
  "run rerun "*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -X PATCH"*) printf '%s\n' "$*" >> "$T/patches.txt"; exit 0 ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
echo '{"workflow_runs":[]}' > "$T/runs-empty.json"

export HARNESS="$T/h"
H="$T/h"
A="$H/state/merge-conductor/attempts.txt"
ROWS="$H/state/merge-conductor/pr-state.tsv"
LEDGER="$H/state/merge-conductor/ci-timeout.tsv"
FIRING="$H/state/merge-conductor/ci-timeout-firing.tsv"
ALOG="$H/logs/ALERTS.log"
CLOG="$H/logs/merge-conductor.log"

# fresh — a new scratch harness and empty fake-gh records for one case.
fresh() {
  local f
  for f in "$H" "$T/scan" "$T/hist.json" "$T/hist.500" "$T"/runs-[0-9a-f]*.json; do
    [ -e "$f" ] && { scratch_rm "$f" || exit 1; }
  done
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" "$T/scan"
  cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
     "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/mc-ci-timeout.sh" "$H/bin/lib/"
  if [ "${CIT_NO_BUDGET:-0}" != 1 ]; then cp "$DIR/bin/lib/mc-ci-timeout-budget.sh" "$H/bin/lib/" 2>/dev/null; fi
  mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
  cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  : > "$H/env/global.env"
  printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$H/fleet.conf"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$H/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/codegraph-ensure.sh"
  chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/codegraph-ensure.sh"
  # The scan fixture (stands in for BH-3785, overwrites any real one). Lines of
  # $T/scan/<head>: run_id check wfpath T run_started_at class duration. Every
  # line goes to the ledger once per (slug, run_id, check), the reuse rule of
  # the real scan; the TIMEOUT ones become CIT_TIMEOUTS.
  { printf 'CITFX=%q\n' "$T/scan"; cat <<'SCAN'
cit_scan() {
  local f="$CITFX/$3" rid chk wf tm st cls dur
  [ -r "$f" ] || return 0
  while IFS=$'\t' read -r rid chk wf tm st cls dur; do
    [ -n "$rid" ] || continue
    awk -F'\t' -v s="$1" -v r="$rid" -v c="$chk" '$2==s && $6==r && $3==c {f=1} END {exit !f}' "$CIT_LEDGER" 2>/dev/null \
      || cit_ledger_put "$(mc_now)" "$1" "$chk" "$2" "$3" "$rid" "$dur" "$tm" "$cls" "$wf" "$st"
    [ "$cls" = TIMEOUT ] || continue
    CIT_TIMEOUTS+="${CIT_TIMEOUTS:+$'\n'}$rid"$'\t'"$chk"$'\t'"$wf"$'\t'"$tm"$'\t'"$st"
  done < "$f"
  return 0
}
SCAN
  } > "$H/bin/lib/mc-ci-timeout-scan.sh"
  : > "$T/gh-calls.txt"; : > "$T/reruns.txt"; : > "$T/gh-writes.txt"; : > "$T/patches.txt"
  touch "$H/flags/merge-conductor-actions" "$ALOG"
}

# runs_for <sha> <spec>... — spec: id|name|conclusion (completed, attempt 1)
runs_for() {
  local sha="$1" spec id n c; shift
  local out='{"workflow_runs":[' first=1
  for spec in "$@"; do
    IFS='|' read -r id n c <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg id "$id" --arg n "$n" --arg c "$c" --arg t "$TA" \
      '{id:($id|tonumber), name:$n, status:"completed", conclusion:$c,
        run_started_at:$t, created_at:$t, run_attempt:1,
        html_url:("https://github.com/example-org/demo-os/actions/runs/"+$id)}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
# scan_line <head> <run_id> <check> <class> <duration> — one dead job the fixture scan reports.
scan_line() { printf '%s\t%s\t%s\t10\t%s\t%s\t%s\n' "$2" "$3" "$WF" "$TA" "$4" "$5" >> "$T/scan/$1"; }
# hist <n-total> <n-dead> <dead-seconds> — the workflow's completed-run history.
hist() {
  jq -nc --argjson n "$1" --argjson d "$2" --argjson s "$3" '
    def ts(x): x | todate;
    {total_count:$n, workflow_runs:[range(0;$n) as $i |
      (1790000000 + $i*3600) as $st |
      if $i < $d then {id:(7000+$i), conclusion:"cancelled", run_started_at:ts($st), updated_at:ts($st+$s)}
      else {id:(7000+$i), conclusion:"success", run_started_at:ts($st), updated_at:ts($st+300)} end]}' > "$T/hist.json"
}
mkrec() { # mkrec <num> <head>
  local d="$H/builds/pool-demo-os-TK-$1-2026093000$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
}
list_row() { # list_row <num> <head>
  printf '{"number":%s,"url":"https://github.com/example-org/demo-os/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1"
}
list_of() { local out="" r; for r in "$@"; do out+="${out:+,}$r"; done; printf '[%s]' "$out" > "$T/list.json"; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$H/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$ROWS" 2>/dev/null; }
# age_reruns — every cirerun mark moves past MC_RED_RERUN_SETTLE_SECS (from NOW).
age_reruns() { awk -v t="$((NOW-400))" '/^cirerun / {$NF=t} {print}' "$A" > "$T/a.tmp" && mv "$T/a.tmp" "$A"; }
budget_n() { grep -c 'CI_TIMEOUT_BUDGET' "$ALOG" 2>/dev/null; }
hist_reads() { grep -c 'actions/workflows/ci.yml/runs?status=completed' "$T/gh-calls.txt"; }

# ============================================================================
# D1-D5 — three PRs on one repo, one check dying at its 10-min limit
# ============================================================================
fresh
H31=31aaaaaaaaaa; H32=32bbbbbbbbbb; H33=33cccccccccc
for n in 31 32 33; do
  v=H$n; h=${!v}
  mkrec "$n" "$h"; runs_for "$h" "9$n|CI|cancelled"; scan_line "$h" "9$n" "$CHECK" TIMEOUT 617
done
list_of "$(list_row 31 "$H31")" "$(list_row 32 "$H32")" "$(list_row 33 "$H33")"
run_tick
age_reruns
run_tick
[ "$(budget_n)" = 1 ] && ok || bad "D1: exactly ONE CI_TIMEOUT_BUDGET page for the repo (got $(budget_n): $(grep -E 'CI_TIMEOUT|CI_FLAKE' "$ALOG"))"
PAGE=$(grep 'CI_TIMEOUT_BUDGET' "$ALOG")
for want in "$S" "\"$CHECK\"" "10-min" "$WF" "#31 #32 #33"; do
  case "$PAGE" in *"$want"*) ok ;; *) bad "D1: the page must name '$want' (got: $PAGE)" ;; esac
done
# D2 — while the budget fires, no PR pages its own CI_FLAKE_TWICE.
[ "$(grep -cE "CI_FLAKE_TWICE.*($H31|$H32|$H33|${H31:0:8}|${H32:0:8}|${H33:0:8})" "$ALOG")" = 0 ] \
  && ok || bad "D2: zero CI_FLAKE_TWICE for the three heads (got: $(grep CI_FLAKE_TWICE "$ALOG"))"
# D5 — the row says why it is waiting.
for n in 31 32 33; do
  k="$S#$n"
  [ "$(state_of "$k")" = WAIT_CI ] && ok || bad "D5: $k stays WAIT_CI (got $(state_of "$k"))"
  case "$(reason_of "$k")" in
    "checks timeout budget — \"$CHECK\" dies at its 10-min limit"*) ok ;;
    *) bad "D5: $k reason must start 'checks timeout budget — \"$CHECK\" dies at its 10-min limit' (got '$(reason_of "$k")')" ;;
  esac
done
# D4 — the firing record names the check and the workflow file.
grep -F "$CHECK" "$FIRING" 2>/dev/null | grep -qF "$WF" \
  && ok || bad "D4: ci-timeout-firing.tsv must carry a line with the check and $WF (got: $(cat "$FIRING" 2>/dev/null))"
[ "$(awk -F'\t' 'END {print NF}' "$FIRING" 2>/dev/null)" = 11 ] && ok || bad "D4: a firing line has the 11 documented fields (got: $(cat "$FIRING" 2>/dev/null))"
# D3 — one page a day: another tick adds nothing; yesterday's marker re-pages once.
run_tick
[ "$(budget_n)" = 1 ] && ok || bad "D3: the same UTC day must not page again (got $(budget_n))"
grep -qE "^citimeout $S [0-9]+ $TODAY\$" "$A" && ok || bad "D3: the daily marker 'citimeout $S <cksum> $TODAY' must be in attempts (got: $(grep citimeout "$A"))"
sed -i "s/^\(citimeout .*\) $TODAY\$/\1 $YDAY/" "$A"
run_tick
[ "$(budget_n)" = 2 ] && ok || bad "D3: a marker from yesterday must re-page exactly once today (got $(budget_n))"
run_tick
[ "$(budget_n)" = 2 ] && ok || bad "D3: and still once a day after that (got $(budget_n))"

# ============================================================================
# E1 — siblings already in the ledger: the FIRST tick buys no rerun
# ============================================================================
fresh
mkrec 31 "$H31"; runs_for "$H31" "931|CI|cancelled"; scan_line "$H31" 931 "$CHECK" TIMEOUT 617
mkdir -p "$H/state/merge-conductor"
{ for n in 32 33; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$S" "$CHECK" "$S#$n" "h$n" "9$n" 619 10 TIMEOUT "$WF" "$TA"; done
  # noise: a MERGED sibling, the same check on another repo, a stale line
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$S" "$CHECK" "$S#34" h34 934 619 10 TIMEOUT "$WF" "$TA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" other/repo "$CHECK" "other/repo#1" o1 801 619 10 TIMEOUT "$WF" "$TA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((NOW-400000))" "$S" "$CHECK" "$S#35" h35 935 619 10 TIMEOUT "$WF" "$TA"
} > "$LEDGER"
{ for n in 32 33; do printf '%s\tWAIT_CI\t%s\th%s\th%s\t0\tchecks flake\thttps://github.com/%s/pull/%s\n' "$S#$n" "$NOW" "$n" "$n" "$S" "$n"; done
  printf '%s\tMERGED\t%s\th34\th34\t0\tmerged\thttps://github.com/%s/pull/34\n' "$S#34" "$NOW" "$S"
} > "$ROWS"
list_of "$(list_row 31 "$H31")"
run_tick
[ ! -s "$T/reruns.txt" ] && ok || bad "E1: a firing budget must buy no rerun (got: $(cat "$T/reruns.txt"))"
grep -q "^cirerun $S#31 " "$A" && bad "E1: no cirerun mark may be spent (attempts: $(grep cirerun "$A"))" || ok
[ "$(grep -c "$S#31 CI_TIMEOUT_NO_RERUN" "$CLOG" 2>/dev/null)" = 1 ] \
  && ok || bad "E1: CI_TIMEOUT_NO_RERUN logged once (got: $(grep -c CI_TIMEOUT_NO_RERUN "$CLOG" 2>/dev/null))"
case "$(grep 'CI_TIMEOUT_BUDGET' "$ALOG")" in
  *"#31 #32 #33"*) ok ;;
  *) bad "E1: the page counts the two open siblings, not the MERGED one, the other repo or the stale line (got: $(grep CI_TIMEOUT_BUDGET "$ALOG"))" ;;
esac
run_tick
[ "$(grep -c "$S#31 CI_TIMEOUT_NO_RERUN" "$CLOG" 2>/dev/null)" = 1 ] \
  && ok || bad "E1: a second tick on the same head must not log NO_RERUN again (got: $(grep -c CI_TIMEOUT_NO_RERUN "$CLOG" 2>/dev/null))"
[ ! -s "$T/reruns.txt" ] && ok || bad "E1: nor buy a rerun (got: $(cat "$T/reruns.txt"))"
# The same fixture with MIN_PRS=4: the MERGED, other-repo and stale lines must
# not make up the difference, so it does NOT fire and the rerun is bought.
fresh
mkrec 31 "$H31"; runs_for "$H31" "931|CI|cancelled"; scan_line "$H31" 931 "$CHECK" TIMEOUT 617
mkdir -p "$H/state/merge-conductor"
{ for n in 32 33; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$S" "$CHECK" "$S#$n" "h$n" "9$n" 619 10 TIMEOUT "$WF" "$TA"; done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$S" "$CHECK" "$S#34" h34 934 619 10 TIMEOUT "$WF" "$TA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" other/repo "$CHECK" "other/repo#1" o1 801 619 10 TIMEOUT "$WF" "$TA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((NOW-400000))" "$S" "$CHECK" "$S#35" h35 935 619 10 TIMEOUT "$WF" "$TA"
} > "$LEDGER"
{ for n in 32 33; do printf '%s\tWAIT_CI\t%s\th%s\th%s\t0\tchecks flake\thttps://github.com/%s/pull/%s\n' "$S#$n" "$NOW" "$n" "$n" "$S" "$n"; done
  printf '%s\tMERGED\t%s\th34\th34\t0\tmerged\thttps://github.com/%s/pull/34\n' "$S#34" "$NOW" "$S"
  printf '%s\tWAIT_CI\t%s\th35\th35\t0\tchecks flake\thttps://github.com/%s/pull/35\n' "$S#35" "$NOW" "$S"
} > "$ROWS"
list_of "$(list_row 31 "$H31")"
run_tick MC_CI_TIMEOUT_MIN_PRS=4
[ "$(grep -c 'run rerun 931' "$T/reruns.txt")" = 1 ] && ok || bad "E1n: at MIN_PRS=4 only 3 PRs count, so the rerun is bought (got: $(cat "$T/reruns.txt"))"
[ "$(budget_n)" = 0 ] && ok || bad "E1n: and nothing pages (got $(budget_n))"

# ============================================================================
# E2 — one PR, empty ledger, short history: the BH-636 rerun stays
# ============================================================================
fresh
H51=51aaaaaaaaaa
mkrec 51 "$H51"; runs_for "$H51" "951|CI|cancelled"; scan_line "$H51" 951 "$CHECK" TIMEOUT 617
hist 3 3 615
list_of "$(list_row 51 "$H51")"
run_tick
[ "$(grep -c 'run rerun 951' "$T/reruns.txt")" = 1 ] && [ "$(wc -l < "$T/reruns.txt")" = 1 ] \
  && ok || bad "E2: a TIMEOUT whose detector is not firing keeps its ONE rerun (got: $(cat "$T/reruns.txt"))"
grep -qE "^cirerun $S#51 $H51 [0-9]+\$" "$A" && ok || bad "E2: the cirerun mark is spent as before (attempts: $(cat "$A"))"
[ "$(budget_n)" = 0 ] && ok || bad "E2: 1 PR and 3 runs (< HISTORY_MIN) never pages (got $(budget_n))"
case "$(reason_of "$S#51")" in *"checks flake"*) ok ;; *) bad "E2: the reason stays 'checks flake' (got '$(reason_of "$S#51")')" ;; esac

# ============================================================================
# E3 — ratio arm: 12 of the last 20 runs died at 615s of a 10-min limit
# ============================================================================
fresh
H52=52aaaaaaaaaa; H53=53aaaaaaaaaa
for n in 52 53; do
  v=H$n; h=${!v}; mkrec "$n" "$h"; runs_for "$h" "9$n|CI|cancelled"; scan_line "$h" "9$n" "$CHECK" TIMEOUT 616
done
hist 20 12 615
list_of "$(list_row 52 "$H52")" "$(list_row 53 "$H53")"
run_tick
[ "$(budget_n)" = 1 ] && ok || bad "E3: the ratio arm must page once for the repo (got $(budget_n))"
case "$(grep 'CI_TIMEOUT_BUDGET' "$ALOG")" in
  *"12 of the last 20 runs"*) ok ;; *) bad "E3: the page says '12 of the last 20 runs' (got: $(grep CI_TIMEOUT_BUDGET "$ALOG"))" ;; esac
[ ! -s "$T/reruns.txt" ] && ok || bad "E3: no rerun while it fires (got: $(cat "$T/reruns.txt"))"
[ "$(hist_reads)" = 1 ] && ok || bad "E3: two PRs on one (repo, workflow) make ONE history read a tick (got $(hist_reads))"
awk -F'\t' 'END {exit !($7==12 && $8==20)}' "$FIRING" 2>/dev/null && ok || bad "E3: the firing line carries X=12 Y=20 (got: $(cat "$FIRING" 2>/dev/null))"
# E3b — the same 12 cancelled at 40s are supersedes, not timeouts.
fresh
mkrec 52 "$H52"; runs_for "$H52" "952|CI|cancelled"; scan_line "$H52" 952 "$CHECK" TIMEOUT 616
hist 20 12 40
list_of "$(list_row 52 "$H52")"
run_tick
[ "$(budget_n)" = 0 ] && ok || bad "E3b: runs cancelled at 40s are not timeouts — no page (got $(budget_n))"
[ "$(grep -c 'run rerun 952' "$T/reruns.txt")" = 1 ] && ok || bad "E3b: the one rerun is bought (got: $(cat "$T/reruns.txt"))"

# ============================================================================
# E4 — a firing CI and a flaking E2E: only E2E is re-run, and only E2E pages
# ============================================================================
fresh
H61=61aaaaaaaaaa
mkrec 61 "$H61"; runs_for "$H61" "961|CI|cancelled" "962|E2E|cancelled"
scan_line "$H61" 961 "$CHECK" TIMEOUT 617; scan_line "$H61" 962 "e2e" FLAKE 95
hist 20 12 615
list_of "$(list_row 61 "$H61")"
run_tick
grep -q 'run rerun 962' "$T/reruns.txt" && ok || bad "E4: the flaking E2E run keeps its rerun (got: $(cat "$T/reruns.txt"))"
grep -q 'run rerun 961' "$T/reruns.txt" && bad "E4: the firing CI run is withheld (got: $(cat "$T/reruns.txt"))" || ok
age_reruns
run_tick
F2=$(grep 'CI_FLAKE_TWICE' "$ALOG")
case "$F2" in *E2E*) ok ;; *) bad "E4: at rung 2 the CI_FLAKE_TWICE names E2E (got: $F2)" ;; esac
case "$F2" in *"CI;"*|*"CI)"*|*"CI cancelled"*) bad "E4: and does not name CI, which the budget owns (got: $F2)" ;; *) ok ;; esac
# E4b — one run with a TIMEOUT job AND a killed-runner job keeps its rerun.
fresh
H62=62aaaaaaaaaa
mkrec 62 "$H62"; runs_for "$H62" "971|CI|cancelled"
scan_line "$H62" 971 "$CHECK" TIMEOUT 617; scan_line "$H62" 971 "Lint" FLAKE 95
hist 20 12 615
list_of "$(list_row 62 "$H62")"
run_tick
[ "$(budget_n)" = 1 ] && ok || bad "E4b: the check still fires the repo page (got $(budget_n))"
[ "$(grep -c 'run rerun 971' "$T/reruns.txt")" = 1 ] && ok || bad "E4b: a run with one FLAKE job is re-run (got: $(cat "$T/reruns.txt"))"

# ============================================================================
# E5 — the history read fails: fail open (no page, the one rerun)
# ============================================================================
fresh
H71=71aaaaaaaaaa
mkrec 71 "$H71"; runs_for "$H71" "981|CI|cancelled"; scan_line "$H71" 981 "$CHECK" TIMEOUT 617
touch "$T/hist.500"
list_of "$(list_row 71 "$H71")"
run_tick
[ "$(budget_n)" = 0 ] && ok || bad "E5: a 500 on the history is not evidence — no page (got $(budget_n))"
[ "$(grep -c 'run rerun 981' "$T/reruns.txt")" = 1 ] && ok || bad "E5: the rerun is bought (got: $(cat "$T/reruns.txt"))"
case "$(reason_of "$S#71")" in *"checks flake"*) ok ;; *) bad "E5: reason 'checks flake' (got '$(reason_of "$S#71")')" ;; esac
[ "$(hist_reads)" = 1 ] && ok || bad "E5: the failed read is made once (got $(hist_reads))"
# E5b — the scan reports nothing: the budget is never asked.
fresh
mkrec 71 "$H71"; runs_for "$H71" "981|CI|cancelled"
touch "$T/hist.500"
list_of "$(list_row 71 "$H71")"
run_tick
[ "$(grep -c 'run rerun 981' "$T/reruns.txt")" = 1 ] && ok || bad "E5b: no TIMEOUT, the BH-636 rerun (got: $(cat "$T/reruns.txt"))"
[ "$(hist_reads)" = 0 ] && [ "$(budget_n)" = 0 ] && ok || bad "E5b: no history read and no page (reads $(hist_reads), pages $(budget_n))"

# ============================================================================
# E6 — observe mode: nothing written to GitHub, the page still goes once
# ============================================================================
fresh
rm -f "$H/flags/merge-conductor-actions"
H81=81aaaaaaaaaa
mkrec 81 "$H81"; runs_for "$H81" "991|CI|cancelled"; scan_line "$H81" 991 "$CHECK" TIMEOUT 617
hist 20 12 615
list_of "$(list_row 81 "$H81")"
run_tick
run_tick
[ ! -s "$T/reruns.txt" ] && [ ! -s "$T/patches.txt" ] && ok || bad "E6: observe mode writes nothing (reruns: $(cat "$T/reruns.txt"); patches: $(cat "$T/patches.txt"))"
[ "$(budget_n)" = 1 ] && ok || bad "E6: the page is not a GitHub write — exactly one in observe mode (got $(budget_n))"
[ "$(grep -c "$S#81 CI_TIMEOUT_NO_RERUN" "$CLOG" 2>/dev/null)" = 2 ] && ok || bad "E6: observe logs NO_RERUN every tick (got $(grep -c CI_TIMEOUT_NO_RERUN "$CLOG" 2>/dev/null))"
grep -q "^citskip " "$A" 2>/dev/null && bad "E6: observe mode writes no citskip mark" || ok

echo "ci-timeout-budget-alert.bh-3775: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
