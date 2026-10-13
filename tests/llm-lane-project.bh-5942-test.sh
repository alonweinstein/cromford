#!/bin/bash
# tests/llm-lane-project.bh-5942-test.sh — BH-5942: the seam that puts the three
# LLM alert lanes on the per-project runner (bin/lib/llm-lane-project.sh) and
# the account seam in bin/lib/project-account.sh.
#
#   A1-A5  ACCOUNT_PROJECT_FOR_LANE=<word>=<project>: a lookup for the lane word
#          reads the project's pin; any other name is unchanged; a bad project
#          is refused; project_account_exports follows.
#   B1     no argument = dispatch: 3 projects, 3 runs, the dispatcher returns
#          before any run ends, and its line names 3 runs
#   B2     a hand run whose lock is held prints one line and exits 0; another
#          project's hand run proceeds at the same time
#   B3     a name that is not a project name exits 2
#   B4     llp_arm after env/global.env re-arms the project's App token and
#          exports the account map
#   B5     llp_owns / llp_route decision table, with the adversarial negatives
#   B6     LLM_LANE_DISPATCH_SPREAD_SECS=abc dispatches with 300, one log line
#   B7     a lane-off flag on the real watchdog-responder forks zero runs
#   B8     llp_route reads fleet.conf once per process, not once per call
#   B9     a home project that fleet.conf does not name: one log line per
#          dispatch (items with no project would wait with no run)
#
# Run from anywhere: tests/llm-lane-project.bh-5942-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env/accounts.d" "$H/flags"
for L in bin/lib/llm-lane-project.sh bin/lib/project-account.sh bin/project-lane-run.sh bin/fleet-conf.sh \
         bin/lib/gh-app-auth.sh bin/watchdog-responder.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" JOBS_URL="" LANE_GATE_DISABLE=0
export GH_TOKEN="tok-fixture-default"
cat > "$H/fleet.conf" <<'EOF'
projfix-a o/projfix-a - - 2 box-a 192.0.2.1
projfix-b o/projfix-b - - 2 box-b 192.0.2.2
cromford o/cromford - - 2 box-h 192.0.2.3
cromford-x o/cromford-x - - 2 box-x 192.0.2.4
EOF
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }

# ============================================================================
# A. THE ACCOUNT SEAM.
# ============================================================================
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-a\n' > "$H/env/accounts.d/own:fixture-a.env"
acct() { # acct <fn> <name> [ENV=...]
  local fn="$1" n="$2"; shift 2
  env HARNESS="$H" JOBS_URL= ACCOUNT_OWN_PROJECTS="projfix-a=own:fixture-a,projfix-b=own:fixture-b" "$@" \
    bash -c '. "$0"; '"$fn"' "$1"' "$H/bin/lib/project-account.sh" "$n" 2>"$T/acct.err"
}
OUT=$(acct account_label_for_project responder ACCOUNT_PROJECT_FOR_LANE=responder=projfix-a)
[ "$OUT" = own:fixture-a ] && ok || bad "A1: the lane word reads the project's pin (got '$OUT')"
OUT=$(acct account_label_for_project responder)
[ -z "$OUT" ] && ok || bad "A2: no map = the lane word's own (empty) label (got '$OUT')"
OUT=$(acct account_label_for_project projfix-b ACCOUNT_PROJECT_FOR_LANE=responder=projfix-a)
[ "$OUT" = own:fixture-b ] && ok || bad "A3: another name is not remapped (got '$OUT')"
OUT=$(acct account_label_for_project responder-x ACCOUNT_PROJECT_FOR_LANE=responder=projfix-a)
[ -z "$OUT" ] && ok || bad "A3: a name that only starts with the word is not remapped (got '$OUT')"
OUT=$(acct account_label_for_project responder ACCOUNT_PROJECT_FOR_LANE=responder=../x)
[ -z "$OUT" ] && grep -q 'refused ACCOUNT_PROJECT_FOR_LANE' "$T/acct.err" && ok \
  || bad "A4: a project that is not a name is refused and logged (got '$OUT', err: $(cat "$T/acct.err"))"
OUT=$(acct project_account_exports responder ACCOUNT_PROJECT_FOR_LANE=responder=projfix-a); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "export CLAUDE_CODE_OAUTH_TOKEN='tok-fixture-a'" ] && ok \
  || bad "A5: exports follow the map (rc=$RC out=$OUT)"

# ============================================================================
# B. THE LANE ENTRY.
# ============================================================================
# A fixture lane: the real lib, then it records what it was given and waits.
cat > "$H/bin/fake-llm-lane.sh" <<EOF
#!/bin/bash
H="$H"; export HARNESS="\$H"
. "\$H/bin/lib/llm-lane-project.sh" || exit 1
LLP_LOG="\$H/logs/fakellm.log"
llp_enter fakellm fakeword "\${1:-}"
set -a; . "\$H/env/global.env" 2>/dev/null; set +a
llp_arm
own=free; flock -n "\$H/locks/fakellm-\$LLP_PROJECT.lock" true || own=held
printf '%s\t%s\t%s\t%s\t%s\n' "\$LLP_PROJECT" "\$LLP_STATE" "\${GH_TOKEN:-none}" "\${ACCOUNT_PROJECT_FOR_LANE:-none}" "\$own" >> "$T/runs.tsv"
if [ -e "$T/hold" ]; then for i in \$(seq 1 300); do [ -e "$T/release" ] && break; sleep 0.2; done; fi
echo "\$LLP_PROJECT" >> "$T/done.txt"
EOF
chmod +x "$H/bin/fake-llm-lane.sh"
CLEAN() { rm -f "$T/runs.tsv" "$T/done.txt" "$T/hold" "$T/release" "$H/logs/"*.log "$H/env/global.env"; : > "$T/runs.tsv"; : > "$T/done.txt"; }
NRUNS() { grep -c . "$T/runs.tsv" 2>/dev/null; }
NDONE() { grep -c . "$T/done.txt" 2>/dev/null; }
COL() { awk -F'\t' -v p="$1" -v c="$2" '$1 == p {print $c; exit}' "$T/runs.tsv"; }
# The fixture fleet for dispatch: three projects.
FLEET3() { head -3 "$T/fleet.full" > "$H/fleet.conf"; }
cp "$H/fleet.conf" "$T/fleet.full"

# B1 — dispatch.
CLEAN; FLEET3; touch "$T/hold"
OUT=$(LLM_LANE_DISPATCH_SPREAD_SECS=0 bash "$H/bin/fake-llm-lane.sh"); RC=$?
NAT=$(NDONE)
[ "$RC" = 0 ] && ok || bad "B1: dispatch exits 0 (rc=$RC)"
case "$OUT" in "fakellm dispatch: started 3 project run(s) (period 0s, no cap), 0 held:"*) ok ;; *) bad "B1: one dispatch line naming 3 runs: $OUT" ;; esac
[ "$NAT" = 0 ] && ok || bad "B1: the dispatcher returned before any run ended (done: $NAT)"
WAITFOR '[ "$(NRUNS)" -ge 3 ]' && ok || bad "B1: three runs started (runs: $(NRUNS); log: $(tail -3 "$H/logs/fakellm-cron.log" 2>/dev/null))"
grep -q 'fakellm dispatch: started 3' "$H/logs/fakellm.log" && ok || bad "B1: the dispatch line is in LLP_LOG"
[ "$(COL projfix-a 5)" = held ] && [ "$(COL projfix-b 5)" = held ] && ok || bad "B1: each run holds its own lock (a=$(COL projfix-a 5) b=$(COL projfix-b 5))"
[ "$(COL projfix-b 2)" = "$H/state/fakellm/projfix-b" ] && [ -d "$H/state/fakellm/projfix-b" ] && ok \
  || bad "B1: LLP_STATE is the runner's state dir ($(COL projfix-b 2))"
touch "$T/release"
WAITFOR '[ "$(NDONE)" -ge 3 ]' && ok || bad "B1: the runs end after release (done: $(NDONE))"
grep -q 'is not in fleet.conf' "$H/logs/fakellm.log" && bad "B9: a home project in fleet.conf logs no warning" || ok

# B2 — hand runs: a held lock, and another project at the same time.
CLEAN; FLEET3
exec 6>"$H/locks/fakellm-projfix-a.lock"; flock -n 6 || bad "B2 setup: could not take projfix-a's lock"
OUT=$(bash "$H/bin/fake-llm-lane.sh" projfix-a); RC=$?
[ "$RC" = 0 ] && ok || bad "B2: a held hand run exits 0 (rc=$RC)"
case "$OUT" in *"fakellm: a run of projfix-a is still live (locks/fakellm-projfix-a.lock held)"*) ok ;; *) bad "B2: one held line: $OUT" ;; esac
[ "$(NRUNS)" = 0 ] && ok || bad "B2: the held run did nothing (runs: $(NRUNS))"
bash "$H/bin/fake-llm-lane.sh" projfix-b >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(COL projfix-b 1)" = projfix-b ] && [ "$(COL projfix-b 5)" = held ] && ok \
  || bad "B2: projfix-b's hand run proceeds and holds its own lock (rc=$RC lock=$(COL projfix-b 5))"
[ "$(COL projfix-b 2)" = "$H/state/fakellm/projfix-b" ] && ok || bad "B2: a hand run gets state/<lane>/<project> ($(COL projfix-b 2))"
exec 6>&-

# B3 — names that are not project names.
for N in ../x .hidden 'a b'; do
  bash "$H/bin/fake-llm-lane.sh" "$N" >/dev/null 2>"$T/b3.err"; RC=$?
  [ "$RC" = 2 ] && grep -q 'is not a project name' "$T/b3.err" && ok || bad "B3: '$N' exits 2 with one line (rc=$RC)"
done
[ ! -d "$H/state/fakellm/.hidden" ] && ok || bad "B3: a refused name creates no state dir"

# B4 — the credential, re-armed after global.env.
CLEAN
printf '# fixture: no real App key\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
printf 'GH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"
bash "$H/bin/fake-llm-lane.sh" projfix-a >/dev/null
[ "$(COL projfix-a 3)" = ghs_fixture_o_projfix-a ] && ok || bad "B4: GH_TOKEN is the project's App token after global.env (got $(COL projfix-a 3))"
[ "$(COL projfix-a 4)" = fakeword=projfix-a ] && ok || bad "B4: ACCOUNT_PROJECT_FOR_LANE is <word>=<project> (got $(COL projfix-a 4))"
rm -f "$H/env/github-app.env" "$H/bin/gh-token.sh"
CLEAN
printf 'GH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"
bash "$H/bin/fake-llm-lane.sh" projfix-a >/dev/null
[ "$(COL projfix-a 3)" = tok-fixture-env ] && grep -q 'no GitHub App token for projfix-a (o/projfix-a)' "$H/logs/fakellm.log" && ok \
  || bad "B4: no App on the box = GH_TOKEN unchanged, one log line (got $(COL projfix-a 3); log: $(cat "$H/logs/fakellm.log" 2>/dev/null))"

# B5 — the ownership table.
cp "$T/fleet.full" "$H/fleet.conf"
owns() { # owns <run-project> <field> -> yes|no
  ( LLP_PROJECT="$1" bash -c '. "$0"; llp_owns "$1" && echo yes || echo no' "$H/bin/lib/llm-lane-project.sh" "$2" ); }
route() { bash -c '. "$0"; llp_route "$1"' "$H/bin/lib/llm-lane-project.sh" "$1"; }
while IFS='|' read -r RUN FIELD WANT WHY; do
  [ -n "$RUN" ] || continue
  GOT=$(owns "$RUN" "$FIELD")
  [ "$GOT" = "$WANT" ] && ok || bad "B5: run=$RUN field='$FIELD' owns=$GOT, want $WANT ($WHY)"
done <<'EOF'
projfix-a|projfix-a|yes|own project
cromford||yes|no project goes home
cromford|harness|yes|the word harness goes home
cromford|ghost-project|yes|a project not in fleet.conf goes home
projfix-a|projfix-b|no|another project
projfix-a||no|no project is not projfix-a's
projfix-a|harness|no|harness is not projfix-a's
cromford|cromford-x|no|a real fleet project that starts with the home name goes to its own run
cromford-x|cromford-x|yes|its own run
projfix-a|projfix-a-old|no|a longer name never matches
projfix-a| projfix-a|no|a leading space never matches
cromford| projfix-a|yes|a leading space is not a fleet name, so it goes home
cromford|null|yes|a JSON null read as text goes home
EOF
[ "$(route '')" = cromford ] && ok || bad "B5: the home default is cromford ($(route ''))"
[ "$(LLM_LANE_HOME_PROJECT=projfix-b route '')" = projfix-b ] && ok || bad "B5: LLM_LANE_HOME_PROJECT moves home"
[ "$(LLM_LANE_HOME_PROJECT=../x route '')" = cromford ] && ok || bad "B5: a home that is not a name falls back to cromford"
[ "$(owns '' projfix-a)" = no ] && ok || bad "B5: llp_owns with no LLP_PROJECT owns nothing"

# B6 — a spread that is not a number.
CLEAN; FLEET3
OUT=$(LLM_LANE_DISPATCH_SPREAD_SECS=abc bash "$H/bin/fake-llm-lane.sh" --dispatch)
case "$OUT" in "fakellm dispatch: started 3 project run(s) (period 300s, no cap)"*) ok ;; *) bad "B6: a junk spread dispatches with 300: $OUT" ;; esac
[ "$(grep -c "LLM_LANE_DISPATCH_SPREAD_SECS='abc' is not a number of seconds — using 300" "$H/logs/fakellm.log")" = 1 ] && ok \
  || bad "B6: one log line for the junk spread: $(cat "$H/logs/fakellm.log")"
pkill -f "$H/bin/project-lane-run.sh" 2>/dev/null; sleep 0.3
OUT=$(bash "$H/bin/fake-llm-lane.sh" --dispatch)
case "$OUT" in *"(period 300s, no cap)"*) ok ;; *) bad "B6: the default spread is 300: $OUT" ;; esac
pkill -f "$H/bin/project-lane-run.sh" 2>/dev/null; sleep 0.3

# B7 — the lane is off: the real responder's dispatch forks nothing.
CLEAN; FLEET3
touch "$H/flags/lane-off-watchdog-responder"
OUT=$(bash "$H/bin/watchdog-responder.sh" 2>&1); RC=$?
sleep 1
[ "$RC" = 0 ] && ok || bad "B7: a lane that is off exits 0 (rc=$RC: $OUT)"
case "$OUT" in *dispatch*) bad "B7: no dispatch while the lane is off: $OUT" ;; *) ok ;; esac
[ ! -s "$H/logs/watchdog-responder-cron.log" ] && ! ls "$H/locks/watchdog-responder-"*.lock >/dev/null 2>&1 && ok \
  || bad "B7: no project run started ($(cat "$H/logs/watchdog-responder-cron.log" 2>/dev/null))"
rm -f "$H/flags/lane-off-watchdog-responder"
OUT=$(LLM_LANE_DISPATCH_SPREAD_SECS=0 RESPONDER_DRY=1 bash "$H/bin/watchdog-responder.sh" 2>&1)
case "$OUT" in *"watchdog-responder dispatch: started 3 project run(s)"*) ok ;; *) bad "B7: with the flag gone the same call dispatches 3 runs: $OUT" ;; esac
WAITFOR '! pgrep -f "$H/bin/watchdog-responder.sh" >/dev/null' || pkill -f "$H/bin/project-lane-run.sh" 2>/dev/null

# B8 — one fleet.conf read for many routes.
H2="$T/h2"; mkdir -p "$H2/bin"
printf '#!/bin/bash\necho read >> "%s/fc.count"\nprintf "projfix-a\\nprojfix-b\\n"\n' "$T" > "$H2/bin/fleet-conf.sh"
chmod +x "$H2/bin/fleet-conf.sh"; rm -f "$T/fc.count"
OUT=$(HARNESS="$H2" bash -c '. "$0"; for f in projfix-a "" projfix-b harness projfix-c; do llp_route "$f"; echo; done' "$H/bin/lib/llm-lane-project.sh" | tr '\n' ' ')
[ "$OUT" = "projfix-a cromford projfix-b cromford cromford " ] && ok || bad "B8: routes through the stub fleet ($OUT)"
[ "$(grep -c . "$T/fc.count" 2>/dev/null)" = 1 ] && ok || bad "B8: fleet.conf is read once for five routes (reads: $(grep -c . "$T/fc.count" 2>/dev/null))"

# B9 — the home project is not in fleet.conf.
CLEAN; grep -v '^cromford ' "$T/fleet.full" | head -2 > "$H/fleet.conf"
OUT=$(LLM_LANE_DISPATCH_SPREAD_SECS=0 bash "$H/bin/fake-llm-lane.sh")
WAITFOR '[ "$(NDONE)" -ge 2 ]' || bad "B9 setup: two runs end"
[ "$(grep -c "fakellm: the home project 'cromford' (LLM_LANE_HOME_PROJECT) is not in fleet.conf" "$H/logs/fakellm.log")" = 1 ] && ok \
  || bad "B9: one line names the home project that has no run: $(cat "$H/logs/fakellm.log")"

echo "llm-lane-project.bh-5942: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
