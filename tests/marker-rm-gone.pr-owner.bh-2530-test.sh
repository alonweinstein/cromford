#!/bin/bash
# tests/marker-rm-gone.pr-owner.bh-2530-test.sh — BH-2673 (BH-2530.3):
# bin/pr-owner-sweep.sh's hand-back is the ledgers(kind=commented) row and
# nothing else. No ssh to any box, no second local rm, no file fallback.
#
# WHY DRIVEN. Every case runs the REAL sweep over one ORPHAN PR (#909, key
# TK-909 on example-org/project-5) and reads what it did: the ledger PUT bodies
# the curl shim recorded, the ssh shim's call log, the stamp file on disk and
# the sweep's own summary line (handed-back= / held=), which is where the
# caller turns handback's rc into an outcome.
#   C1   worker up: the row is cleared, the local stamp is gone, 0 ssh,
#        handed-back=#909(TK-909), and the success line says nothing of ssh
#   C2   worker down, remote box whose tailnet_ip fleet.conf DOES answer (so the
#        old ssh path would have fired): 0 ssh, the named line, and
#        held=#909:handback-failed
#   C2l  worker down, locally owned: the same rc 1, and the stamp still goes
#   C3   DRY-RUN: no ledger PUT for the key, 0 ssh
#   C4   the handback body (comments dropped) has no ssh and no rm -f, and the
#        script names neither SSH_CMD nor --tailnet-ip. An empty lift FAILS.
# gh, curl and ssh are PATH shims (no network, no secrets).
# Run from anywhere: tests/marker-rm-gone.pr-owner.bh-2530-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

SWEEP="${SWEEP_SRC:-$DIR/bin/pr-owner-sweep.sh}"
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
cp "$SWEEP"                     "$H/bin/pr-owner-sweep.sh"; chmod +x "$H/bin/pr-owner-sweep.sh"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp -R "$DIR/bin/lib/pr-owner" "$H/bin/lib/"; cp "$DIR/bin/lib/pr-health.sh" "$H/bin/lib/"  # TEST-CHANGE: BH-3932 — the sweep sources its hook libs with || exit 1
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box
cp "$DIR/bin/jobs-client.sh"    "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh     "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/"
# The real registry: project-5's box has a tailnet_ip, so the old ssh
# fallback had an address to fire at. That is what C2 must prove is gone.
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
[ -n "$("$H/bin/fleet-conf.sh" --tailnet-ip project-5 2>/dev/null)" ] && ok \
  || bad "precondition: fleet.conf must give project-5 a tailnet_ip, or C2 proves nothing"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$H/env/github-admin.env"
export GH_TOKEN=defaulttok GH_BUDGET_TTL_S=0 JOBS_RETRY_SLEEP=0

printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_BOX:-box-project-5-1}"\n' > "$H/bin/box-for.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit")
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$now" "$now"
    exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   cat "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *) exit 1 ;;
esac
SH
# curl: reads from fixtures; every PUT /api/ledger body is recorded, and
# LEDGER_DOWN=1 fails only that write, so the sweep still classifies the repo.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift ;; --data-binary) BODY="$2"; shift ;; esac
  shift
done
case "$METHOD $URL" in
  "PUT "*/api/ledger*)
    printf '%s\n' "$BODY" >> "$HARNESS/ledger-puts.log"
    [ "${LEDGER_DOWN:-0}" = 1 ] && exit 7
    printf '{"ok":true}\n200\n' ;;
  *" "*/api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *" "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  *)                printf '{"ok":true}\n200\n' ;;
esac
SH
# ssh: records the call and drains stdin like the real one.
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/ssh-calls.log"
cat > /dev/null
exit 0
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl" "$T/fakebin/ssh"
export PATH="$T/fakebin:$PATH"

NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }
D=86400
STAMP="$H/state/blocked-commented-project-5-TK-909-202609151200"
reset() {
  scratch_rm "$H/state/pr-owners"; scratch_rm "$H/state/gh-budget"; scratch_rm "$H/logs"
  mkdir -p "$H/state/pr-owners" "$H/state/gh-budget" "$H/logs"
  rm -f "$H/ledger-puts.log" "$H/ssh-calls.log"
  cat > "$H/fixture/open.json" <<JSON
[{"number":909,"title":"TK-909: the plain orphan","headRefName":"ticket/TK-909","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/909","isDraft":false}]
JSON
  echo '{"jobs":[{"id":"build-project-5-TK-909-0","ticket_id":"TK-909","kind":"build","status":"failed","updated_at":"'"$(NOWISO 90000)"'","meta":"{\"key\":\"TK-909\"}"}]}' \
    > "$H/fixture/jobs.json"
  : > "$H/state/merge-conductor/pr-state.tsv"
  touch "$STAMP"
}
run() { "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>&1; }
LOGF="$H/logs/pr-owner-sweep.log"
summary() { grep -o "$SLUG: open=.*" "$LOGF" 2>/dev/null | tail -1; }
sshlog() { cat "$H/ssh-calls.log" 2>/dev/null; }
cleared_put() { grep -F '"key":"blocked project-5 TK-909"' "$H/ledger-puts.log" 2>/dev/null | grep -qF '"status":"cleared"'; }

# ---------- C1 worker up -----------------------------------------------------
reset
run
cleared_put && ok || bad "C1: the hand-back must PUT the row 'blocked project-5 TK-909' as cleared: $(cat "$H/ledger-puts.log" 2>/dev/null)"
[ ! -e "$STAMP" ] && ok || bad "C1: the local stamp must be gone (cm_clear's glob)"
[ ! -s "$H/ssh-calls.log" ] && ok || bad "C1: a hand-back must not ssh anywhere: $(sshlog)"
grep -q 'handed-back=#909(TK-909)' <<<"$(summary)" && ok || bad "C1: the summary must record the hand-back: $(summary)"
HBLINE=$(grep -F "project-5/TK-909: cleared row commented 'blocked project-5 TK-909'" "$LOGF" 2>/dev/null)
[ -n "$HBLINE" ] && ok || bad "C1: the sweep must say which row it cleared: $(cat "$LOGF" 2>/dev/null)"
grep -qi 'ssh' <<<"$HBLINE" && bad "C1: the success line still talks about ssh: $HBLINE" || ok

# ---------- C2 worker down, remote box with a known address ------------------
reset
LEDGER_DOWN=1 run
[ ! -s "$H/ssh-calls.log" ] && ok || bad "C2: a DB outage must not fall back to ssh: $(sshlog)"
grep -qF 'project-5/TK-909: row not written; jobs DB unreachable; the hand-back is retried next sweep' "$LOGF" 2>/dev/null && ok \
  || bad "C2: the outage must be named in one line: $(cat "$LOGF" 2>/dev/null)"
grep -q 'held=#909:handback-failed' <<<"$(summary)" && ok || bad "C2: an unwritten row is a failed hand-back (rc 1): $(summary)"
grep -q 'handed-back=#909' <<<"$(summary)" && bad "C2: nothing was handed back, the summary must not say so: $(summary)" || ok

# ---------- C2l worker down, locally owned -----------------------------------
reset
FAKE_BOX=local LEDGER_DOWN=1 run
grep -q 'held=#909:handback-failed' <<<"$(summary)" && ok \
  || bad "C2l: a local project with the row unwritten is still not handed back: $(summary)"
[ ! -e "$STAMP" ] && ok || bad "C2l: the hub's own stamp is still removed by cm_clear"
[ ! -s "$H/ssh-calls.log" ] && ok || bad "C2l: no ssh: $(sshlog)"

# ---------- C3 DRY-RUN -------------------------------------------------------
reset
PR_OWNER_DRY_RUN=1 run
grep -qF 'blocked project-5' "$H/ledger-puts.log" 2>/dev/null && bad "C3: DRY-RUN must write no row: $(cat "$H/ledger-puts.log")" || ok
[ ! -s "$H/ssh-calls.log" ] && ok || bad "C3: DRY-RUN must not ssh: $(sshlog)"
[ -e "$STAMP" ] && ok || bad "C3: DRY-RUN must remove no stamp"
DRYLINE=$(grep -F 'DRY-RUN would: clear row blocked project-5 TK-909' "$LOGF" 2>/dev/null)
[ -n "$DRYLINE" ] && ok || bad "C3: DRY-RUN must name the row it would clear: $(cat "$LOGF" 2>/dev/null)"
grep -qi 'ssh' <<<"$DRYLINE" && bad "C3: the DRY-RUN line still talks about ssh: $DRYLINE" || ok

# ---------- C4 the source shape ----------------------------------------------
BODY=$(awk '/^handback\(\)/,/^}/' "$SWEEP" | grep -v '^[[:space:]]*#')
if [ -z "$BODY" ]; then
  bad "C4: could not lift handback() out of $SWEEP — an empty lift is not a pass"
else
  grep -nE 'ssh|rm -f' <<<"$BODY" && bad "C4: handback still has an ssh or its own rm -f" || ok
fi
grep -n 'SSH_CMD\|tailnet-ip' "$SWEEP" && bad "C4: SSH_CMD / --tailnet-ip must be gone from the sweep" || ok

echo "marker-rm-gone.pr-owner.bh-2530-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
