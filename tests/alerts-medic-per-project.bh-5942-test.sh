#!/bin/bash
# tests/alerts-medic-per-project.bh-5942-test.sh — BH-5942 (C2): alerts-medic
# runs on the per-project runner (bin/lib/llm-lane-project.sh over BH-5913's
# bin/lib/project-lanes.sh).
#
# The REAL bin/alerts-medic.sh runs end to end: no argument = dispatch, which
# grooms once and starts bin/project-lane-run.sh per fleet.conf project, which
# runs `alerts-medic.sh <project>`. Stubbed: curl (the console's
# /api/alerts/open and the jobs worker), bin/agent-call.sh (records the prompt,
# its env and can block), bin/alerts-groom.sh (counts calls) and bin/gh-token.sh
# (a fixture App token per repo).
#
#   M0  the lane is off: the dispatch forks no run and grooms nothing
#   M1  two projects run in parallel: A blocks in its agent call, B finishes;
#       A holds only locks/alerts-medic-projfix-a.lock, the old global
#       locks/alerts-medic.lock is not held
#   M2  a run reads only its own rows, from the console AND from the alerts
#       table (TSV column 4); an empty project goes to the cromford run;
#       the claim carries only the run's own ids; adversarial negatives from
#       the plan's invariant (c)
#   M3  the shared medic-seen.txt is read (an id seen before the change is not
#       examined again), never written; the run's own seen file gets the new id;
#       families and parks are seeded from the shared files by copy
#   M4  the groom runs once per dispatch, never in a project run
#   M5  MEDIC_MAX_FAMILIES=1 applies per project run
#   M6  each run's ACCOUNT_PROJECT_FOR_LANE is medic=<project>, its GH_TOKEN is
#       its own App token (not the global.env one)
#   M7  the backlog alert is per project and deduped per project per day
#   M8  an escalation parks its family in every run, whatever its project field
#       says: another project's name or an empty field (lead BLOCK at 897dab888,
#       the model picks that field)
#
# Run from anywhere: tests/alerts-medic-per-project.bh-5942-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v pgrep >/dev/null || { echo "pgrep missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/fakebin" "$T/calls"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" || { echo "setup: model_routes_fixture failed"; exit 1; }
for L in bin/alerts-medic.sh bin/lib/llm-lane-project.sh bin/project-lane-run.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/triage-map.sh bin/box-for.sh bin/alert_family.py; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# The lane hard-codes its root, as every medic suite handles it.
sed "s|/root/harness|$H|g" "$DIR/bin/alerts-medic.sh" > "$H/bin/alerts-medic.sh"
chmod +x "$H/bin/"*.sh
cat > "$H/fleet.conf" <<'EOF'
projfix-a o/projfix-a - - 2 box-a 192.0.2.1
projfix-b o/projfix-b - - 2 box-b 192.0.2.2
cromford o/cromford - - 2 box-h 192.0.2.3
EOF
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" LLM_LANE_DISPATCH_SPREAD_SECS=0
unset LLP_PROJECT LLP_LANE LLP_STATE PL_LANE PL_PROJECT PL_LOCK_FD PL_STATE_DIR PL_SLUG ACCOUNT_PROJECT_FOR_LANE
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=secret-fixture\nJOBS_RETRIES=0\nGH_TOKEN=tok-fixture-env\n' \
  > "$H/env/global.env"
# The project's App token: bin/lib/gh-app-auth.sh mints through bin/gh-token.sh
# when env/github-app.env exists (the BH-5913 suite's fixture).
printf '# fixture: no real App key\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
# The groom: one line per call.
printf '#!/bin/sh\necho groom >> "%s/groom.log"\nexit 0\n' "$T" > "$H/bin/alerts-groom.sh"
chmod +x "$H/bin/alerts-groom.sh"

# --- stubs -------------------------------------------------------------------
# curl: the console's open list from $T/console.json; the jobs worker in the
# jobs-client wire shape (body, then a status line). Every jobs request is
# appended to $T/req.log as "<run project> METHOD URL BODY".
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
case "$URL" in
  *jobs.invalid*)
    printf '%s %s %s %s\n' "${LLP_PROJECT:-none}" "$METHOD" "$URL" "$BODY" >> "$FIX/req.log"
    case "$METHOD $URL" in
      "GET "*/api/ledger*)           printf '{"ledgers":[],"as_of":"x"}\n200\n' ;;
      "PUT "*/api/ledger)            printf '{"ledger":{}}\n200\n' ;;
      "POST "*/api/alerts/claim)
        printf '%s\n200\n' "$(jq -c '{alerts: [(.ids // [])[] | {id:., family:"f", box:"hub", project:"", state:"claimed", count:1, first_seen:"x", last_seen:"x", claimed_by:"medic@hub", claimed_at:"x", notified_at:"", severity:"warn", line:"x"}]}' <<<"$BODY")" ;;
      "GET "*/api/alerts/families*)  printf '{"families":[]}\n200\n' ;;
      "GET "*/api/alerts\?*state=new*)
        if [ -f "$FIX/dbrows.json" ]; then printf '%s\n200\n' "$(cat "$FIX/dbrows.json")"; else printf '{"alerts":[]}\n200\n'; fi ;;
      "GET "*/api/alerts*)           printf '{"alerts":[]}\n200\n' ;;
      "PATCH "*/api/alerts/state)    printf '{"alert":{"state":"set"}}\n200\n' ;;
      *)                             printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/alerts/open) cat "$FIX/console.json" ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# agent-call.sh: records the prompt and the run's env per project; blocks while
# $T/hold-<project> exists and $T/release does not.
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CALLEOF'
P="${LLP_PROJECT:-none}"
N=$(ls "$FIX/calls/$P".*.prompt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$FIX/calls/$P.$N.prompt"
printf 'word=%s\nacct=%s\ngh=%s\n' "$2" "${ACCOUNT_PROJECT_FOR_LANE:-none}" "${GH_TOKEN:-none}" > "$FIX/calls/$P.$N.env"
if [ -e "$FIX/hold-$P" ]; then
  touch "$FIX/started-$P"
  for _ in $(seq 1 300); do [ -e "$FIX/release" ] && break; sleep 0.2; done
fi
touch "$FIX/done-$P"
echo "handled=1" > "$5"
exit 0
CALLEOF
} > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }
busy() { pgrep -f "$H/bin/(project-lane-run|alerts-medic)\.sh" >/dev/null 2>&1; }
fresh() {
  pkill -f "$H/bin/(project-lane-run|alerts-medic)\.sh" 2>/dev/null; WAITFOR '! busy'
  rm -rf "$T/calls" "$H/state/alerts-medic" "$H/state/medic-"* "$H/flags/"* "$T/hold-"* "$T/started-"* "$T/done-"* \
         "$T/release" "$T/dbrows.json" "$T/groom.log"
  mkdir -p "$T/calls"; : > "$T/req.log"; : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"
  rm -f "$H/logs/alerts-medic-cron.log"
}
# dispatch [ENV=...] — the cron tick: no argument. Returns its rc.
dispatch() { env PATH="$T/fakebin:$PATH" "$@" bash "$H/bin/alerts-medic.sh" > "$T/dispatch.out" 2>&1; }
# tick [ENV=...] — a dispatch, then wait until every run it started ended.
tick() { dispatch "$@"; local rc=$?; sleep 0.3; WAITFOR '! busy' || bad "a run did not end"; return "$rc"; }
# hand <project> [ENV=...] — a run started by hand.
hand() { local p="$1"; shift; env PATH="$T/fakebin:$PATH" "$@" bash "$H/bin/alerts-medic.sh" "$p" > "$T/hand.out" 2>&1; }
ncalls() { ls "$T/calls/$1".*.prompt 2>/dev/null | wc -l | tr -d ' '; }
envof() { sed -n "s/^$2=//p" "$T/calls/$1.0.env" 2>/dev/null; }
held() { ! flock -n "$1" true 2>/dev/null; }
# row <id> <project-json> <line> — one console row, past the 20-minute cutoff.
row() { jq -nc --arg id "$1" --argjson p "$2" --arg l "$3" \
          '{id:$id, akey:("alert:" + $id), project:$p, createdAt:"2026-09-24T01:00:00Z", line:$l}'; }
console() { { printf '{"alerts":['; local i=0 r; for r in "$@"; do [ "$i" -gt 0 ] && printf ','; printf '%s' "$r"; i=$((i+1)); done; printf ']}\n'; } > "$T/console.json"; }

# ============================================================================
# M0 — the lane is off: no fork, no groom.
# ============================================================================
fresh
console "$(row fx-a1 '"projfix-a"' 'alpha disk full on box-a mark-a1')"
touch "$H/flags/lane-off-alerts-medic"
tick; RC=$?
[ "$RC" = 0 ] && ok || bad "M0: a lane that is off exits 0 (rc=$RC)"
! grep -q dispatch "$T/dispatch.out" && [ ! -s "$H/logs/alerts-medic-cron.log" ] && [ ! -s "$T/groom.log" ] && ok \
  || bad "M0: off = no dispatch, no run, no groom (out: $(cat "$T/dispatch.out"); groom: $(wc -l < "$T/groom.log" 2>/dev/null))"

# ============================================================================
# M1 + M4 + M6 — two projects in parallel, own locks, groom once, own account.
# ============================================================================
fresh
console "$(row fx-a1 '"projfix-a"' 'alpha disk full on box-a mark-a1')" \
        "$(row fx-b1 '"projfix-b"' 'bravo board poll failing mark-b1')"
touch "$T/hold-projfix-a"
dispatch; RC=$?
[ "$RC" = 0 ] && ok || bad "M1: the dispatch exits 0 (rc=$RC: $(cat "$T/dispatch.out"))"
case "$(cat "$T/dispatch.out")" in *"alerts-medic dispatch: started 3 project run(s)"*) ok ;;
  *) bad "M1: one dispatch line naming 3 runs: $(cat "$T/dispatch.out")" ;; esac
WAITFOR '[ -e "$T/started-projfix-a" ] && [ -e "$T/done-projfix-b" ]' && ok \
  || bad "M1: run B finished its agent call while run A blocks (cron log: $(tail -5 "$H/logs/alerts-medic-cron.log" 2>/dev/null))"
[ ! -e "$T/done-projfix-a" ] && ok || bad "M1: run A is still inside its agent call"
held "$H/locks/alerts-medic-projfix-a.lock" && ok || bad "M1: run A holds locks/alerts-medic-projfix-a.lock"
! held "$H/locks/alerts-medic.lock" && ok || bad "M1: the old global locks/alerts-medic.lock is not held"
WAITFOR '! held "$H/locks/alerts-medic-projfix-b.lock"' && ok || bad "M1: run B's lock is free once B ended (A still blocks)"
touch "$T/release"
WAITFOR '! busy' && ok || bad "M1: the runs end after release"
[ "$(ncalls projfix-a)" = 1 ] && [ "$(ncalls projfix-b)" = 1 ] && [ "$(ncalls cromford)" = 0 ] && ok \
  || bad "M1: one session for A, one for B, none for cromford (a=$(ncalls projfix-a) b=$(ncalls projfix-b) h=$(ncalls cromford))"
# M4 — the groom: once for the dispatch, never in a project run.
[ "$(grep -c . "$T/groom.log" 2>/dev/null)" = 1 ] && ok || bad "M4: one groom per dispatch (got $(grep -c . "$T/groom.log" 2>/dev/null))"
hand projfix-a; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c . "$T/groom.log" 2>/dev/null)" = 1 ] && ok \
  || bad "M4: a project run does not groom (rc=$RC groom=$(grep -c . "$T/groom.log" 2>/dev/null))"
tick
[ "$(grep -c . "$T/groom.log" 2>/dev/null)" = 2 ] && ok || bad "M4: a second dispatch grooms once more (got $(grep -c . "$T/groom.log" 2>/dev/null))"
# M6 — the account word and the GitHub credential of each run.
[ "$(envof projfix-a acct)" = medic=projfix-a ] && [ "$(envof projfix-b acct)" = medic=projfix-b ] && ok \
  || bad "M6: ACCOUNT_PROJECT_FOR_LANE is medic=<project> (a=$(envof projfix-a acct) b=$(envof projfix-b acct))"
[ "$(envof projfix-a word)" = medic ] && ok || bad "M6: the agent-call PROJECT arg stays the lane word medic (got $(envof projfix-a word))"
[ "$(envof projfix-a gh)" = ghs_fixture_o_projfix-a ] && [ "$(envof projfix-b gh)" = ghs_fixture_o_projfix-b ] && ok \
  || bad "M6: GH_TOKEN is the run's own App token, not global.env's (a=$(envof projfix-a gh) b=$(envof projfix-b gh))"
grep -q 'medic pass: 1 alert(s) across 1 famil(ies) — one session each project=projfix-a' "$H/logs/medic.log" && ok \
  || bad "M1: the tick line names project=projfix-a: $(grep 'medic pass' "$H/logs/medic.log")"
[ -f "$H/logs/medic-run.projfix-a.txt" ] && [ ! -e "$H/logs/medic-run.txt" ] && ok \
  || bad "M1: the run output is logs/medic-run.<project>.txt"

# ============================================================================
# M2 — each run reads only its own rows (console + table), claims only its ids.
# ============================================================================
fresh
touch "$H/flags/alerts-db"
console "$(row fx-a1 '"projfix-a"' 'alpha disk full on box-a mark-a1')" \
        "$(row fx-b1 '"projfix-b"' 'bravo board poll failing mark-b1')" \
        "$(row fx-h1 '""' 'charlie fleet heartbeat late mark-home0')" \
        "$(row fx-o1 '"projfix-a-old"' 'delta retired repo stale mark-old')" \
        "$(row fx-s1 '" projfix-a"' 'echo spaced project tag mark-space')" \
        "$(row fx-n1 'null' 'foxtrot null project field mark-null')" \
        "$(row fx-t1 '"projfix-b"' 'golf projfix-a named in text only mark-text')"
# The table: one unclaimed row per project, columns as bin/lib/jobs/alerts.sh reads them.
jq -nc '{alerts: [
  {id:"db-a", family:"f1", box:"box-a", project:"projfix-a", state:"new", count:1, first_seen:"x", last_seen:"x", claimed_by:"", claimed_at:"", notified_at:"", severity:"warn", line:"hotel table row for a mark-dba"},
  {id:"db-b", family:"f2", box:"box-b", project:"projfix-b", state:"new", count:1, first_seen:"x", last_seen:"x", claimed_by:"", claimed_at:"", notified_at:"", severity:"warn", line:"india table row for b mark-dbb"},
  {id:"db-0", family:"f3", box:"hub",   project:"",          state:"new", count:1, first_seen:"x", last_seen:"x", claimed_by:"", claimed_at:"", notified_at:"", severity:"warn", line:"juliet table row no project mark-db0"}]}' > "$T/dbrows.json"
tick MEDIC_MAX_FAMILIES=10
# grep the files, not `prompts | grep -q`: under pipefail an early grep exit
# SIGPIPEs cat and the pipeline reads as "not found".
has()  { grep -qs -- "$2" "$T/calls/$1".*.prompt; }
want() { local p="$1"; shift; local m; for m in "$@"; do has "$p" "$m" && ok || bad "M2: run $p was not handed $m"; done; }
deny() { local p="$1"; shift; local m; for m in "$@"; do ! has "$p" "$m" && ok || bad "M2: run $p was handed $m (not its row)"; done; }
want projfix-a mark-a1 mark-dba
deny projfix-a mark-b1 mark-home0 mark-old mark-space mark-null mark-text mark-dbb mark-db0
want projfix-b mark-b1 mark-text mark-dbb
deny projfix-b mark-a1 mark-home0 mark-dba mark-db0
want cromford mark-home0 mark-old mark-space mark-null mark-db0
deny cromford mark-a1 mark-b1 mark-text mark-dba mark-dbb
# The claim: each run asks only for its own ids.
claims() { awk -v p="$1" '$1==p && $2=="POST" && $3 ~ /\/api\/alerts\/claim$/' "$T/req.log" | cut -d' ' -f4- | jq -r '.ids[]' 2>/dev/null | sort -u; }
CA=$(claims projfix-a); CB=$(claims projfix-b); CH=$(claims cromford)
grep -qx db-a <<<"$CA" && [ "$(grep -c . <<<"$CA")" = 2 ] && ok || bad "M2: run A claims its 2 rows only (got: $(tr '\n' ' ' <<<"$CA"))"
! grep -qx -e db-b -e db-0 <<<"$CA" && ok || bad "M2: run A claims no other project's row ($(tr '\n' ' ' <<<"$CA"))"
grep -qx db-b <<<"$CB" && ! grep -qx -e db-a -e db-0 <<<"$CB" && [ "$(grep -c . <<<"$CB")" = 3 ] && ok \
  || bad "M2: run B claims its 3 rows only (got: $(tr '\n' ' ' <<<"$CB"))"
grep -qx db-0 <<<"$CH" && ! grep -qx -e db-a -e db-b <<<"$CH" && [ "$(grep -c . <<<"$CH")" = 5 ] && ok \
  || bad "M2: the cromford run claims the 5 home rows only (got: $(tr '\n' ' ' <<<"$CH"))"
grep -qx fx-a1 "$H/state/alerts-medic/projfix-a/medic-seen.txt" 2>/dev/null \
  && ! grep -qx fx-b1 "$H/state/alerts-medic/projfix-a/medic-seen.txt" && ok \
  || bad "M2: run A's seen file holds its id and not B's"

# ============================================================================
# M3 — the shared seen file is read, never written; families/parks are seeded.
# ============================================================================
fresh
printf 'fx-1\nfx-old\n' > "$H/state/medic-seen.txt"
NOWS=$(date -u +%s)
printf '{"famfix-shared": %s}\n' "$NOWS" > "$H/state/medic-families.json"
printf '{"parkfix-shared": {"since": %s, "ids": ["fx-zz"], "line": "parked fixture"}}\n' "$NOWS" > "$H/state/medic-parked.json"
SUM_SEEN=$(cksum < "$H/state/medic-seen.txt"); SUM_FAM=$(cksum < "$H/state/medic-families.json"); SUM_PARK=$(cksum < "$H/state/medic-parked.json")
console "$(row fx-1 '"projfix-a"' 'kilo seen before the change mark-seen')" \
        "$(row fx-2 '"projfix-a"' 'lima never seen mark-new')"
hand projfix-a; RC=$?
[ "$RC" = 0 ] && ok || bad "M3: the run exits 0 (rc=$RC: $(cat "$T/hand.out"))"
! has projfix-a mark-seen && ok || bad "M3: an id in the shared seen file is not examined again"
has projfix-a mark-new && ok || bad "M3: the unseen id is examined"
[ "$(cksum < "$H/state/medic-seen.txt")" = "$SUM_SEEN" ] && ok || bad "M3: the shared seen file is byte-identical after the run"
[ "$(cksum < "$H/state/medic-families.json")" = "$SUM_FAM" ] && [ "$(cksum < "$H/state/medic-parked.json")" = "$SUM_PARK" ] && ok \
  || bad "M3: the shared families and parked files are byte-identical after the run"
grep -qx fx-2 "$H/state/alerts-medic/projfix-a/medic-seen.txt" 2>/dev/null && ok || bad "M3: the run's own seen file holds fx-2"
jq -e 'has("famfix-shared")' "$H/state/alerts-medic/projfix-a/medic-families.json" >/dev/null 2>&1 && ok \
  || bad "M3: the run's families file was seeded from the shared one ($(cat "$H/state/alerts-medic/projfix-a/medic-families.json" 2>/dev/null))"
jq -e 'has("parkfix-shared")' "$H/state/alerts-medic/projfix-a/medic-parked.json" >/dev/null 2>&1 && ok \
  || bad "M3: the run's parked file was seeded from the shared one ($(cat "$H/state/alerts-medic/projfix-a/medic-parked.json" 2>/dev/null))"
# A seed happens once: a project file that exists is never re-seeded.
mkdir -p "$H/state/alerts-medic/projfix-a"; echo '{}' > "$H/state/alerts-medic/projfix-a/medic-parked.json"
console "$(row fx-3 '"projfix-a"' 'mike third alert mark-third')"
hand projfix-a
! jq -e 'has("parkfix-shared")' "$H/state/alerts-medic/projfix-a/medic-parked.json" >/dev/null 2>&1 && ok \
  || bad "M3: an existing project parked file is not re-seeded from the shared one"

# ============================================================================
# M5 — MEDIC_MAX_FAMILIES=1 per project run.
# ============================================================================
fresh
console "$(row fx-a1 '"projfix-a"' 'november alpha first family mark-a1')" \
        "$(row fx-a2 '"projfix-a"' 'oscar alpha second family mark-a2')" \
        "$(row fx-b1 '"projfix-b"' 'papa bravo first family mark-b1')" \
        "$(row fx-b2 '"projfix-b"' 'quebec bravo second family mark-b2')"
tick MEDIC_MAX_FAMILIES=1
[ "$(ncalls projfix-a)" = 1 ] && [ "$(ncalls projfix-b)" = 1 ] && ok \
  || bad "M5: each project run buys exactly 1 session (a=$(ncalls projfix-a) b=$(ncalls projfix-b))"

# ============================================================================
# M7 — the backlog alert: one per project, deduped per project per day.
# ============================================================================
fresh
console "$(row fx-a1 '"projfix-a"' 'romeo alpha one mark-a1')" "$(row fx-a2 '"projfix-a"' 'sierra alpha two mark-a2')" \
        "$(row fx-a3 '"projfix-a"' 'tango alpha three mark-a3')" \
        "$(row fx-b1 '"projfix-b"' 'uniform bravo one mark-b1')" "$(row fx-b2 '"projfix-b"' 'victor bravo two mark-b2')" \
        "$(row fx-b3 '"projfix-b"' 'whiskey bravo three mark-b3')"
tick MEDIC_MAX_FAMILIES=1 MEDIC_BACKLOG_ALERT=0
NB() { grep -c "DEFERRAL BACKLOG: .*project $1" "$H/logs/ALERTS.log"; }
[ "$(NB projfix-a)" = 1 ] && [ "$(NB projfix-b)" = 1 ] && [ "$(grep -c 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log")" = 2 ] && ok \
  || bad "M7: the first tick writes one backlog line per project (a=$(NB projfix-a) b=$(NB projfix-b): $(cat "$H/logs/ALERTS.log"))"
ls "$H/flags/"alerted-medic-backlog-projfix-a-* >/dev/null 2>&1 && ls "$H/flags/"alerted-medic-backlog-projfix-b-* >/dev/null 2>&1 && ok \
  || bad "M7: a per-project daily flag ($(ls "$H/flags"))"
tick MEDIC_MAX_FAMILIES=1 MEDIC_BACKLOG_ALERT=0
[ "$(ncalls projfix-a)" = 2 ] && ok || bad "M7: the second tick ran a session and still deferred (a=$(ncalls projfix-a))"
grep -q 'deferred 1 famil(ies)' "$H/logs/medic.log" && ok || bad "M7: the second tick deferred again"
[ "$(grep -c 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log")" = 2 ] && ok \
  || bad "M7: the second tick on the same day writes no new backlog line ($(grep -c 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log"))"

# ============================================================================
# M8 — an escalation parks its family whatever project the model wrote on it.
# ============================================================================
famof() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from alert_family import family; print(family(sys.argv[2]))' "$H/bin" "$1"; }
for escp in '"projfix-b"' '""'; do
  fresh
  L='xray alpha build wedged on box-a mark-x1'
  esc=$(jq -nc --arg a "medic:$(famof "$L")" --argjson p "$escp" \
    '{id:"esc-x1", akey:$a, project:$p, createdAt:"2026-09-24T01:00:00Z", line:"ESCALATED: needs a person"}')
  console "$(row fx-x1 '"projfix-a"' "$L")" "$esc"
  hand projfix-a
  [ "$(ncalls projfix-a)" = 0 ] && ok || bad "M8 (escalation project $escp): the escalated family must park in projfix-a's run, not buy a session ($(ncalls projfix-a) call(s))"
  jq -e --arg k "$(famof "$L")" 'has($k)' "$H/state/alerts-medic/projfix-a/medic-parked.json" >/dev/null 2>&1 && ok \
    || bad "M8 (escalation project $escp): projfix-a's parked file names the family"
done

pkill -f "$H/bin/(project-lane-run|alerts-medic)\.sh" 2>/dev/null
echo "alerts-medic-per-project: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
