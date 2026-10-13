#!/bin/bash
# tests/cost-rollup-db-first.bh-2312-test.sh — COST-ROLLUP TAKES THE PR BINDING
# FROM THE LEDGER (BH-2351, slice 4 of BH-2312).
#
# bin/cost-rollup.sh used to learn which PR a build dir produced by tarring every
# box's builds/*/RESULT over ssh and grepping it. The binding is in the jobs
# ledger; bin/lib/builds-of-record.sh reads it. Since BH-2527 no box is reached
# at all: another box's build is the cost_rows rows carrying its dir in run_id,
# and the ledger is the ONLY thing that binds it to a PR. This suite runs the
# REAL bin/cost-rollup.sh (WINDOWS_ONLY=1, so no beats and no PR stamping) in a
# scratch $HARNESS with the REAL libs. The stubs are the edges only:
#   - bin/jobs-client.sh defines job_artifact_feed from fixture TSV files, with
#     rc 1 per project on demand (the shape tests/builds-of-record.bh-2312-test.sh
#     feeds the real client: job_id, ref, box, ticket_id, updated_at, detail),
#     and _jobs_req answers GET /api/metrics/cost-rows from a fixture;
#   - `ssh` on PATH records its argv (it must never be called);
#   - bin/fleet-conf.sh answers a tailnet ip for two boxes; gh/curl fail.
#
#   A  pool- run_id with NO RESULT anywhere, ledger pr_url -> a row with its dollars
#   A2 ledger pr_url `-`, URL only in result_line -> a row
#   A3 fly- run_id resolves to the bare ledger name
#   B  every project rc 0 / 2 -> no ssh session at all
#   C  one BOXPROJ project rc 1 -> the log names it, the others still bind
#   C2 a project only in fleet.conf rc 1 -> the log names it
#   D  a hub dir the ledger does not name -> its RESULT still binds; a remote
#      run_id the ledger does not name -> NOT attributed (no RESULT is read)
#   E  a dir the ledger names with no URL -> no row, even next to a RESULT with one
#   F  a truncated feed (BOR_LIMIT=1) -> the log says so
#   G  no builds-of-record lib at all -> hub dirs bind from RESULT, nothing crashes
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-rollup-db-first.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account"
row() { printf '2026-09-20T10:00:00Z,box,project-1,%s,claude,claude-opus-5,0,60,10,20,0,0,%s,subscription,fp1,acct\n' "$1" "$2"; }
# mk <dir> <cost...> — a build dir with a cost.csv, one row per cost (stage
# names differ so the union's sort -u never collapses two of them).
mk() {
  local d="$1" i=0; shift
  mkdir -p "$d"
  { echo "$HDR"; for c in "$@"; do i=$((i+1)); row "s$i-$(basename "$d")" "$c"; done; } > "$d/cost.csv"
}

# rrow <run_id> <cost...> — the cost_rows rows another box pushed for one build
# dir, as JSON lines (stage names differ so no two rows collapse).
rrow() {
  local run="$1" i=0; shift
  for c in "$@"; do i=$((i+1))
    printf '{"ts":"%s","box":"project-1","host":"box","project":"project-1","stage":"s%s-%s","runner":"claude","model":"claude-opus-5","rc":0,"duration_s":60,"input_toks":10,"output_toks":20,"cache_read":0,"cache_write":0,"cost_usd":%s,"billing_mode":"subscription","auth_fp":"fp1","auth_account":"acct","run_id":"%s","row_hash":"%s-%s"}\n' \
      "$NOWTS" "$i" "$run" "$c" "$run" "$run" "$i"
  done
}
NOWTS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/ssh" "$T/fakebin/gh" "$T/fakebin/curl"

# res <job> <ref> <build_dir> <key> / prl <job> <url> — feed TSV rows.
res() { printf '%s\t%s\tbox1\t%s\t2026-09-20T10:00:00Z\t{"build_dir":"%s","key":"%s","job_status":"done"}\n' "$1" "$2" "$4" "$3" "$4"; }
prl() { printf '%s\t%s\tbox1\t-\t2026-09-20T10:00:00Z\t-\n' "$1" "$2"; }

# setup <name> — a fresh scratch harness; sets H, FIX.
setup() {
  H="$T/$1/h"; FIX="$T/$1/fix"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/builds" "$H/state/cost" "$H/env" "$FIX"
  cp "$DIR/bin/cost-rollup.sh" "$H/bin/cost-rollup.sh"
  cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
  cp "$DIR/bin/lib/builds-of-record.sh" "$H/bin/lib/builds-of-record.sh"
  cp "$DIR/bin/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"
  cat > "$H/bin/jobs-client.sh" <<'JC'
# stub ledger client: job_artifact_feed from $FIX/<project>.<kind>
job_artifact_feed() {
  local kind="$1" p="$2" since="${3:-}" limit="${4:-100}"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$p" "$since" "$limit" >> "$FIX/feed.log"
  [ -f "$FIX/$p.rc" ] && return "$(cat "$FIX/$p.rc")"
  [ -f "$FIX/$p.$kind" ] && head -n "$limit" "$FIX/$p.$kind"
  return 0
}
_jobs_req() {
  case "$2" in /api/metrics/cost-rows*) cat "$FIX/cost-rows.json" ;; *) return 1 ;; esac
}
JC
  printf '#!/bin/bash\n[ "$1" = --tailnet-ip ] || exit 1\ncase "$2" in project-1|project-2) echo "ip-$2" ;; *) exit 1 ;; esac\n' > "$H/bin/fleet-conf.sh"
  chmod +x "$H/bin/fleet-conf.sh"
  printf '# project slug\nproject-1 -\nproject-2 -\n\nextra-os -\nold-redirect -\n' > "$H/fleet.conf"

  # The project-1 box's builds, as cost_rows carries them (no RESULT exists
  # anywhere the rollup can see).
  { rrow pool-project-1-BH-9-x 1.25 2.50                   # A
    rrow project-1-BH-10-x 4.00                            # A2
    rrow fly-project-1-BH-13-x 0.50                        # A3
    rrow project-1-BH-14-x 7.00                            # D (remote)
    rrow project-1-BH-15-x 8.00                            # E (remote)
  } | jq -sc '{cost_rows: .}' > "$FIX/cost-rows.json"
  # Hub-local dirs (read in place, no ssh).
  mk "$H/builds/project-1-BH-11-x" 3.00                    # D (hub)
  echo "PR_CREATED https://github.com/o/r/pull/11" > "$H/builds/project-1-BH-11-x/RESULT"
  mk "$H/builds/project-1-BH-12-x" 6.00                    # E (hub)
  echo "PR_CREATED https://github.com/o/r/pull/12" > "$H/builds/project-1-BH-12-x/RESULT"

  { res j9  "PR_CREATED"                                   project-1-BH-9-x  BH-9
    res j10 "PR_CREATED https://github.com/o/r/pull/10"    project-1-BH-10-x BH-10
    res j13 "PR_CREATED"                                   fly-project-1-BH-13-x BH-13
    res j12 "BUILD_FAILED no pr"                           project-1-BH-12-x BH-12
    res j15 "PLAN_BLOCKED"                                 project-1-BH-15-x BH-15
  } > "$FIX/project-1.result"
  { prl j9 https://github.com/o/r/pull/9
    prl j13 https://github.com/o/r/pull/13
  } > "$FIX/project-1.pr_url"
}

# run [VAR=val...] — the real script, as cron runs it, against $H.
run() {
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" SSH_LOG="$H/ssh.log" FIX="$FIX" \
      COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 \
      HARNESS_SECRET= "$@" bash "$H/bin/cost-rollup.sh" > "$H/run.out" 2>&1
  echo $? > "$H/run.rc"
}
CSV() { printf '%s\n' "$H/state/cost/cost-per-pr.csv"; }
cost_of() { # cost_of <pr-no> -> cost_usd of that PR's row, or empty
  python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["pr_url"] == "https://github.com/o/r/pull/" + sys.argv[2]: print(r["cost_usd"])' "$(CSV)" "$1" 2>/dev/null
}
ssh_calls() { cat "$H/ssh.log" 2>/dev/null | grep -c . || true; }

# ===========================================================================
# 1. every project answered (rc 0 or 2): A, A2, A3, B, D(hub), E(hub)
# ===========================================================================
setup s1
run
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "s1: rollup exited $(cat "$H/run.rc"): $(tail -5 "$H/run.out")"
[ -s "$(CSV)" ] && ok || bad "s1: no cost-per-pr.csv written"
[ "$(cost_of 9)" = 3.75 ] && ok || bad "A: pool- dir with no RESULT should bill /pull/9 3.75 from the ledger pr_url, got '$(cost_of 9)'"
[ "$(cost_of 10)" = 4.00 ] && ok || bad "A2: a URL only in result_line should bind /pull/10, got '$(cost_of 10)'"
[ "$(cost_of 13)" = 0.50 ] && ok || bad "A3: fly- dir should resolve to the bare ledger name (/pull/13), got '$(cost_of 13)'"
[ "$(cost_of 11)" = 3.00 ] && ok || bad "D: a hub dir the ledger does not name still binds from its RESULT (/pull/11), got '$(cost_of 11)'"
[ -z "$(cost_of 12)" ] && ok || bad "E: a hub dir the ledger names with no URL must not bind from RESULT, got /pull/12 row '$(cost_of 12)'"
[ -z "$(cost_of 15)" ] && ok || bad "E: a remote run_id the ledger names with no URL must not bind, got /pull/15 '$(cost_of 15)'"
[ -z "$(cost_of 14)" ] && ! grep -q 'BH-14' "$(CSV)" && ok \
  || bad "D: a remote run_id the ledger does not name must not be attributed (no RESULT is read), got '$(cost_of 14)'"
[ "$(ssh_calls)" = 0 ] && ok || bad "B: no box is reached over ssh: $(head -2 "$H/ssh.log")"
[ ! -e "$H/state/cost/remote-builds" ] && ok || bad "B: nothing is mirrored into state/cost/remote-builds any more"
grep -q 'ledger answered for all' "$H/logs/agent-rules.log" && ok || bad "B: no agent-rules line saying the ledger answered"
# The window reaches the feed: both kinds for every project, with a since.
for P in project-1 project-2 extra-os project-4 project-8; do
  [ "$(awk -F'\t' -v p="$P" '$2==p && $3!=""' "$FIX/feed.log" | wc -l)" = 2 ] \
    && ok || bad "B: expected 2 feed calls with a since for $P: $(grep -c "$P" "$FIX/feed.log")"
done
grep -q 'old-redirect' "$FIX/feed.log" && bad "a *redirect* fleet.conf line was asked for as a project" || ok

# ===========================================================================
# 2. one BOXPROJ project's feed is down (rc 1): C, D(mirror), E(mirror)
# ===========================================================================
setup s2
echo 1 > "$FIX/project-2.rc"
run
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "s2: rollup exited $(cat "$H/run.rc"): $(tail -5 "$H/run.out")"
[ "$(ssh_calls)" = 0 ] && ok || bad "C: a feed outage must not reach a box: $(head -2 "$H/ssh.log")"
grep 'ledger' "$H/logs/agent-rules.log" | grep -q 'project-2' \
  && ok || bad "C: agent-rules.log does not name the project whose feed failed: $(grep ledger "$H/logs/agent-rules.log")"
[ "$(cost_of 9)" = 3.75 ] && ok || bad "C: the projects that did answer still bind from the ledger (/pull/9), got '$(cost_of 9)'"
[ "$(cost_of 11)" = 3.00 ] && ok || bad "D: a hub dir the ledger does not name still binds from its RESULT (/pull/11), got '$(cost_of 11)'"
[ -z "$(cost_of 15)" ] && ok || bad "E: a run_id the ledger names with no URL must not bind, got /pull/15 '$(cost_of 15)'"

# ===========================================================================
# 3. a project known only to fleet.conf is down: C2
# ===========================================================================
setup s3
echo 1 > "$FIX/extra-os.rc"
run
[ "$(ssh_calls)" = 0 ] && ok || bad "C2: a feed outage must not reach a box: $(head -2 "$H/ssh.log")"
grep 'ledger' "$H/logs/agent-rules.log" | grep -q 'extra-os' && ok || bad "C2: the log does not name extra-os"

# ===========================================================================
# 4. a truncated feed: F
# ===========================================================================
setup s4
run BOR_LIMIT=1
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "s4: rollup exited $(cat "$H/run.rc")"
[ "$(ssh_calls)" = 0 ] && ok || bad "F: a capped feed must not reach a box: $(head -2 "$H/ssh.log")"
grep 'ledger' "$H/logs/agent-rules.log" | grep -q 'truncated' && ok || bad "F: the log does not say the feed was truncated"

# ===========================================================================
# 5. no builds-of-record lib on the box: G
# ===========================================================================
setup s5
rm -f "$H/bin/lib/builds-of-record.sh"
# The sibling-first source would still find the checkout's copy, so run a copy
# of the script that lives beside no lib at all ($H/bin/lib still has the
# cost_rows reader, so the fleet is read).
mkdir -p "$T/s5/alone"; cp "$DIR/bin/cost-rollup.sh" "$T/s5/alone/cost-rollup.sh"
env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" SSH_LOG="$H/ssh.log" FIX="$FIX" \
    COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 \
    HARNESS_SECRET= bash "$T/s5/alone/cost-rollup.sh" > "$H/run.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "G: rollup exited $RC without the lib: $(tail -5 "$H/run.out")"
[ "$(ssh_calls)" = 0 ] && ok || bad "G: no reader, and still no box reached: $(head -2 "$H/ssh.log")"
[ "$(cost_of 11)" = 3.00 ] && [ "$(cost_of 12)" = 6.00 ] && ok \
  || bad "G: with no ledger every hub dir binds from its RESULT as before (/pull/11 '$(cost_of 11)', /pull/12 '$(cost_of 12)')"
[ -z "$(cost_of 9)" ] && ok || bad "G: with no ledger a remote run_id cannot be bound, got /pull/9 '$(cost_of 9)'"

printf 'cost-rollup-db-first.bh-2312: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
