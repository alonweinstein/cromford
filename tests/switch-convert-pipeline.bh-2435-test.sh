#!/bin/bash
# tests/switch-convert-pipeline.bh-2435-test.sh — BH-2435 (BH-2407.4): eight
# build-pipeline kill switches are read through bin/lib/lane-switch.sh's
# lane_switch, so a settings row decides before the file does, and
# bin/fly-trial-kill.sh writes the fly-disabled box row and re-reads it before
# it says the dispatcher is inert.
#
# Every case drives the REAL script or lib function in a scratch harness with
# the real lane-gate.sh and lane-switch.sh copied in, and a stub jobs client
# (below) whose GET /api/settings serves $ROWS_FILE. Per switch:
#   *-1 a row saying 1 with no file turns the switch ON (the new behaviour);
#   *-2 a row saying 0 beats a file on the box, and logs.lane-gate.log says so;
#   *-3 no row and the file: exactly the old answer (legacy parity).
# Plus:
#   BR-4   a row value nobody can read (`2`) is no row, so no file = OFF;
#   CG-4   another box's row does not reach this box;
#   LF-4   LANE_GATE_DISABLE=1 with the file is still `fastpath off`;
#   BD-4   the lib read leaks no function into the caller's shell;
#   NF-1..3 the file-mode sites make zero /api/flags requests;
#   W1..W3, W-fresh  bin/fly-trial-kill.sh's row write, re-read and messages;
#   CG-5, LF-5, BD-5/DV-5, W4  a half-synced bin/: the REAL jobs client with no
#          bin/lib/jobs/ beside it, which `exit 1`s when sourced. The kill file
#          still answers, and fly-trial-kill still stops the machines;
#   S0     no bare file read, flag_on/flag_active read or FASTPATH_OFF of the
#          eight names is left in bin/.
# Run from anywhere: tests/switch-convert-pipeline.bh-2435-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
# Sections that need another suite's fixture run in a subshell, so the tally is
# a file rather than two shell counters.
TALLY="$T/tally"; : > "$TALLY"
ok()  { echo P >> "$TALLY"; }
bad() { echo F >> "$TALLY"; echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

BOX=hub-1
export JOBS_BOX="$BOX" CALLS="$T/calls" ROWS_FILE="$T/rows.json"
unset LANE_GATE_DISABLE LANE_SWITCH_SRC PUT_FAIL STUB_FLAG_ACTIVE

# --- the stub worker ----------------------------------------------------------
# Installed as bin/jobs-client.sh, the path lane-gate's _lg_ensure_client and
# the scripts themselves source. Every request is one `METHOD PATH` line in
# $CALLS. GET /api/settings serves $ROWS_FILE; PUT /api/settings persists the
# row into it unless PUT_FAIL=1 (then HTTP 500). flag_active exists only with
# STUB_FLAG_ACTIVE=1, and it logs the /api/flags read the real one makes, so a
# file-mode site that fell back to flag mode is seen.
cat > "$T/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  JOBS_HTTP=""
  case "$1 $2" in
    "GET /api/settings")
      JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    "PUT /api/settings")
      printf '%s\n' "$3" >> "$CALLS.put"
      if [ "${PUT_FAIL:-}" = 1 ]; then JOBS_HTTP=500; printf '{"error":"boom"}'; return 1; fi
      local cur; cur=$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')
      printf '%s' "$cur" | jq -c --argjson b "$3" 'map(select(.key != $b.key)) + [{key:$b.key,value:$b.value,actor:$b.actor}]' > "$ROWS_FILE"
      JOBS_HTTP=200; printf '{"setting":%s}' "$3" ;;
    *) JOBS_HTTP=404; return 1 ;;
  esac
}
if [ "${STUB_FLAG_ACTIVE:-}" = 1 ]; then
  flag_active() { echo "GET /api/flags/$1" >> "$CALLS"; [ -f "$HARNESS/flags/$1" ]; }
  # BH-2412: lane_switch's no-row flag step reads the pause_flags row itself
  # through _jobs_req (logged above) and needs _flag_epoch, as the real client has.
  _flag_epoch() { date -u -d "$1" +%s 2>/dev/null; }
fi
SH

# mkh <root> — a scratch harness with the two libs, the stub client and the registry.
mkh() {
  mkdir -p "$1/bin/lib" "$1/flags" "$1/state" "$1/logs" "$1/catalog" "$1/env" "$1/locks" || return 1
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$1/bin/lib/" || return 1
  cp "$T/stub-jobs-client.sh" "$1/bin/jobs-client.sh" || return 1
  cp "$(rendered_registry)" "$1/catalog/lanes.json" || return 1
}
# rows k=v [k=v...] — the settings table the stub serves.
rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$ROWS_FILE"
}
# fresh <root> [switch] — no cache, no throttle stamps, no lane-gate log, no calls.
fresh() {
  scratch_rm "$1/state/lane-gate"
  rm -f "$1/state/settings-cache.json" "$1/logs/lane-gate.log" "$CALLS" "$CALLS.put" "$ROWS_FILE"
  [ -n "${2:-}" ] && rm -f "$1/flags/$2"
  : > "$CALLS"
}
lglines() { [ -f "$1/logs/lane-gate.log" ] && grep -c "switch $2: row says 0" "$1/logs/lane-gate.log" || echo 0; }
flagreqs() { grep -c ' /api/flags' "$CALLS" 2>/dev/null || true; }
# halfclient <root> — the real bin/jobs-client.sh with no bin/lib/jobs/ beside
# it: a half-synced bin/. Sourcing it `exit 1`s the sourcing shell.
# stubclient <root> puts the stub back.
halfclient() { scratch_rm "$1/bin/lib/jobs"; cp "$DIR/bin/jobs-client.sh" "$1/bin/jobs-client.sh"; }
stubclient() { cp "$T/stub-jobs-client.sh" "$1/bin/jobs-client.sh"; }

# ════════════════════════════════════════════════════════════════════════════
# BR — the real bin/batch-resolve.sh, batch-resolve-off (flag mode). A gated
# tick with no train logs "<source> — nothing to do" and exits; an ungated one
# goes on to the remote (and stops there: this fixture has no token).
# ════════════════════════════════════════════════════════════════════════════
HB="$T/br"; mkh "$HB" || exit 1
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$HB/bin/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$HB/bin/lib/" || exit 1
mkdir -p "$HB/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$HB/bin/lib/mc/" || exit 1
printf 'demo o/demo https://demo.example - 2 box-demo\n' > "$HB/fleet.conf"
mkdir -p "$T/br-fakebin"
printf '#!/bin/sh\necho "gh $*" >> "%s/br-gh.log"\nexit 1\n' "$T" > "$T/br-fakebin/gh"; chmod +x "$T/br-fakebin/gh"
brun() {
  : > "$HB/logs/batch-resolve.log"
  PATH="$T/br-fakebin:$PATH" HARNESS="$HB" FLEET_CONF="$HB/fleet.conf" bash "$HB/bin/batch-resolve.sh" demo >"$T/br.out" 2>&1
}
brlog() { cat "$HB/logs/batch-resolve.log" 2>/dev/null; }

fresh "$HB" batch-resolve-off; rows "switch.batch-resolve-off.$BOX=1"; brun
grep -q "settings switch.batch-resolve-off.$BOX — nothing to do" <<<"$(brlog)" && ok \
  || bad "BR-1: a box row of 1 with no file must gate, naming the row (log: $(brlog))"
fresh "$HB" batch-resolve-off; rows switch.batch-resolve-off=0; touch "$HB/flags/batch-resolve-off"; brun
grep -q 'nothing to do' <<<"$(brlog)" && bad "BR-2: a row of 0 must beat the file (log: $(brlog))" || ok
[ -n "$(brlog)" ] && ok || bad "BR-2: the ungated tick must go on and log its next step"
eq "BR-2 one lane-gate.log line names the ignored file" "$(lglines "$HB" batch-resolve-off)" 1
fresh "$HB" batch-resolve-off; rows; touch "$HB/flags/batch-resolve-off"; brun
grep -q 'flags/batch-resolve-off — nothing to do' <<<"$(brlog)" && ok \
  || bad "BR-3: no row and the file must gate exactly as before (log: $(brlog))"
fresh "$HB" batch-resolve-off; rows switch.batch-resolve-off=2; brun
grep -q 'nothing to do' <<<"$(brlog)" && bad "BR-4: a row of '2' is no row, and with no file the lane runs (log: $(brlog))" || ok

# ════════════════════════════════════════════════════════════════════════════
# BRS — the real bin/blocked-resolver.sh --fix-here, blocked-resolver-disabled
# (flag mode), in tests/blocked-resolver.bh-594-test.sh's fixture. A subshell,
# because that fixture sets DIR/T/H and PATH as globals.
# ════════════════════════════════════════════════════════════════════════════
(
  . "$DIR/tests/lib/fixture-harness.sh" || exit 1
  ST="$T"; BT="$T/brs"; H="$BT/h"; mkdir -p "$H/bin"
  cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
     "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
     "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
  fx_br_harness "$DIR" "$BT" || exit 1
  [ -d "$H/bin/lib/br" ] || exit 1   # fx_br_harness installs bin/lib/br/ (br_modules_install)
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1
  mrs_fixture "$H" tproj
  fx_br_ladder_git "$DIR" "$BT" || exit 1
  mkdir -p "$H/catalog"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$H/bin/lib/" || exit 1
  cp "$(rendered_registry)" "$H/catalog/lanes.json" || exit 1
  cat "$ST/stub-jobs-client.sh" >> "$H/bin/jobs-client.sh" || exit 1
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 0\n' "$BT" > "$H/bin/agent-call.sh"
  chmod +x "$H/bin/agent-call.sh"
  jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,attempts:[]}' > "$BT/rec-in.json"
  FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$BT/repos" BOX_NAME=box-tproj \
      timeout 120 bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-91 head-not-reapproved \
      "https://github.com/o/tproj/pull/91" - TK-91 < "$BT/rec-in.json" ) 2>>"$BT/run.log"; }
  paused() { grep -c '^FIX_RESULT box-paused ' <<<"$1" || true; }

  fresh "$H" blocked-resolver-disabled; rows "switch.blocked-resolver-disabled.$BOX=1"
  OUT=$(FIXHERE)
  eq "BRS-1 a box row of 1 with no file answers box-paused" "$(paused "$OUT")" 1
  fresh "$H" blocked-resolver-disabled; rows switch.blocked-resolver-disabled=0
  touch "$H/flags/blocked-resolver-disabled"
  OUT=$(FIXHERE)
  eq "BRS-2 a row of 0 beats the file: no box-paused" "$(paused "$OUT")" 0
  eq "BRS-2 one lane-gate.log line names the ignored file" "$(lglines "$H" blocked-resolver-disabled)" 1
  fresh "$H" blocked-resolver-disabled; rows; touch "$H/flags/blocked-resolver-disabled"
  OUT=$(FIXHERE)
  eq "BRS-3 no row and the file answers box-paused as before" "$(paused "$OUT")" 1
) || bad "BRS: the blocked-resolver fixture did not install"

# ════════════════════════════════════════════════════════════════════════════
# CG / SH — the real bin/context-gate.sh (file mode), in
# tests/context-gate-self-heal-test.sh's fixture: a git checkout at origin/main
# and a context-signature stand-in that compares the two bin trees.
# ════════════════════════════════════════════════════════════════════════════
HC="$T/cg"; CK="$T/cg-ck"; mkh "$HC" || exit 1
mkdir -p "$CK/bin" "$T/cg-build"
cp "$DIR/bin/context-gate.sh" "$HC/bin/" || exit 1
git init -q -b main "$CK"
printf '#!/bin/bash\necho canonical\n' > "$CK/bin/queue-line-drop.sh"; chmod +x "$CK/bin/queue-line-drop.sh"
git -C "$CK" add -A; git -C "$CK" -c user.email=t@t -c user.name=t commit -qm init
git -C "$CK" update-ref refs/remotes/origin/main HEAD
printf '#!/bin/bash\necho "fresh %s"\nexit 0\n' "$(git -C "$CK" rev-parse --short HEAD)" > "$HC/bin/harness-sync.sh"
cat > "$HC/bin/context-signature.sh" <<'SIG'
#!/bin/bash
CK="${HARNESS_CHECKOUT:?}"; HH="${HARNESS:?}"
S=true
while IFS= read -r f; do
  [ -n "$f" ] || continue
  cmp -s "$CK/bin/$f" "$HH/bin/$f" || { S=false; break; }
done < <(cd "$CK/bin" && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
printf '{ "harness_bin_in_sync": %s, "machine_rules_in_sync": true }\n' "$S"
SIG
printf '#!/bin/bash\nexit 0\n' > "$HC/bin/lane-alert.sh"
chmod +x "$HC/bin"/*.sh
cgdrift() { printf '#!/bin/bash\necho HOT-PATCHED\n' > "$HC/bin/queue-line-drop.sh"; }
cgsync()  { cp -p "$CK/bin/queue-line-drop.sh" "$HC/bin/"; }
gate() { rm -f "$T/cg-build/context.json"; : > "$HC/logs/agent-rules.log"
  OUT=$(HARNESS="$HC" HARNESS_CHECKOUT="$CK" STUB_FLAG_ACTIVE=1 bash "$HC/bin/context-gate.sh" demo-os "$T/cg-build" "$T/cg-repo" 2>&1); RC=$?; }
NF1=0

cgsync; fresh "$HC" context-gate-disabled; rows "switch.context-gate-disabled.$BOX=1"; gate
[ "$RC" = 0 ] && grep -q "^gate disabled by settings switch.context-gate-disabled.$BOX$" <<<"$OUT" && [ ! -e "$T/cg-build/context.json" ] \
  && ok || bad "CG-1: a box row of 1 with no file must disable the gate and name the row (rc=$RC out=$OUT)"
NF1=$((NF1 + $(flagreqs)))
fresh "$HC" context-gate-disabled; rows switch.context-gate-disabled=0; touch "$HC/flags/context-gate-disabled"; gate
grep -q 'gate disabled' <<<"$OUT" && bad "CG-2: a row of 0 must beat the file (out=$OUT)" || ok
[ -e "$T/cg-build/context.json" ] && ok || bad "CG-2: the gate must run (no context.json written; out=$OUT)"
eq "CG-2 one lane-gate.log line names the ignored file" "$(lglines "$HC" context-gate-disabled)" 1
NF1=$((NF1 + $(flagreqs)))
fresh "$HC" context-gate-disabled; rows; touch "$HC/flags/context-gate-disabled"; gate
[ "$RC" = 0 ] && grep -q '^gate disabled by flags/context-gate-disabled$' <<<"$OUT" && [ ! -e "$T/cg-build/context.json" ] \
  && ok || bad "CG-3: no row and the file must disable the gate as before (rc=$RC out=$OUT)"
NF1=$((NF1 + $(flagreqs)))
fresh "$HC" context-gate-disabled; rows switch.context-gate-disabled.other-box=1; gate
grep -q 'gate disabled' <<<"$OUT" && bad "CG-4: another box's row must not reach this box (out=$OUT)" || ok
NF1=$((NF1 + $(flagreqs)))
# CG-5 — a half-synced bin/: the refresh's client exits, and the file answers.
fresh "$HC" context-gate-disabled; rows; halfclient "$HC"; touch "$HC/flags/context-gate-disabled"; gate
[ "$RC" = 0 ] && grep -q '^gate disabled by flags/context-gate-disabled$' <<<"$OUT" \
  && ok || bad "CG-5: a client that exits when sourced must leave the file to answer (rc=$RC out=$OUT)"
rm -f "$HC/flags/context-gate-disabled"; stubclient "$HC"

cgdrift; fresh "$HC" bin-self-heal-off; rows "switch.bin-self-heal-off.$BOX=1"; gate
[ "$RC" = 1 ] && grep -q 'HOT-PATCHED' "$HC/bin/queue-line-drop.sh" \
  && grep -q "but settings switch.bin-self-heal-off.$BOX is set — refusing instead of healing" "$HC/logs/agent-rules.log" \
  && ok || bad "SH-1: a box row of 1 with no file must refuse and name the row (rc=$RC log=$(cat "$HC/logs/agent-rules.log"))"
NF1=$((NF1 + $(flagreqs)))
cgdrift; fresh "$HC" bin-self-heal-off; rows switch.bin-self-heal-off=0; touch "$HC/flags/bin-self-heal-off"; gate
[ "$RC" = 0 ] && grep -q canonical "$HC/bin/queue-line-drop.sh" && ok \
  || bad "SH-2: a row of 0 must beat the file and heal (rc=$RC out=$OUT)"
eq "SH-2 one lane-gate.log line names the ignored file" "$(lglines "$HC" bin-self-heal-off)" 1
NF1=$((NF1 + $(flagreqs)))
cgdrift; fresh "$HC" bin-self-heal-off; rows; touch "$HC/flags/bin-self-heal-off"; gate
[ "$RC" = 1 ] && grep -q 'HOT-PATCHED' "$HC/bin/queue-line-drop.sh" \
  && grep -q 'but flags/bin-self-heal-off is set — refusing instead of healing' "$HC/logs/agent-rules.log" \
  && ok || bad "SH-3: no row and the file must refuse as before (rc=$RC log=$(cat "$HC/logs/agent-rules.log"))"
NF1=$((NF1 + $(flagreqs)))
rm -f "$HC/flags/bin-self-heal-off"; cgsync
eq "NF-1 context-gate (file mode) makes no /api/flags request" "$NF1" 0

# ════════════════════════════════════════════════════════════════════════════
# FD — the real bin/fly-dispatch.sh, fly-disabled (flag mode).
# ════════════════════════════════════════════════════════════════════════════
HF="$T/fd"; mkh "$HF" || exit 1
cp "$DIR/bin/fly-dispatch.sh" "$HF/bin/" || exit 1
mkdir -p "$HF/bin/lib/jobs" "$HF/state/fly"
: > "$HF/env/fly.env"
fdrun() { : > "$HF/logs/fly-dispatch.log"
  OUT=$(HARNESS="$HF" STUB_FLAG_ACTIVE=1 bash "$HF/bin/fly-dispatch.sh" 2>&1); RC=$?; }
fdlog() { cat "$HF/logs/fly-dispatch.log" 2>/dev/null; }
fresh "$HF" fly-disabled; rows "switch.fly-disabled.$BOX=1"; fdrun
[ "$RC" = 0 ] && grep -q "settings switch.fly-disabled.$BOX present — no-op" <<<"$(fdlog)" && [ ! -e "$HF/locks/fly-dispatch.lock" ] \
  && ok || bad "FD-1: a box row of 1 with no file must no-op before the lock, naming the row (rc=$RC log=$(fdlog))"
fresh "$HF" fly-disabled; rows switch.fly-disabled=0; touch "$HF/flags/fly-disabled"; fdrun
grep -q 'no-op' <<<"$(fdlog)" && bad "FD-2: a row of 0 must beat the file (log=$(fdlog))" || ok
[ -e "$HF/locks/fly-dispatch.lock" ] && ok || bad "FD-2: the run must go past the switch to the tick lock"
eq "FD-2 one lane-gate.log line names the ignored file" "$(lglines "$HF" fly-disabled)" 1
rm -f "$HF/locks/fly-dispatch.lock"
fresh "$HF" fly-disabled; rows; touch "$HF/flags/fly-disabled"; fdrun
grep -q 'flags/fly-disabled present — no-op' <<<"$(fdlog)" && grep -q 'GET /api/flags/fly-disabled' "$CALLS" \
  && ok || bad "FD-3: no row and the file must no-op as before, after a pause_flags read (log=$(fdlog) calls=$(cat "$CALLS"))"
rm -f "$HF/flags/fly-disabled"

# ════════════════════════════════════════════════════════════════════════════
# LF — the real bin/launch-fastpath.sh, fastpath-off (file mode). Past the
# switch the next step is the board check, and this fixture has no fleet-conf.
# ════════════════════════════════════════════════════════════════════════════
HL="$T/lf"; mkh "$HL" || exit 1
cp "$DIR/bin/launch-fastpath.sh" "$HL/bin/" || exit 1
lfrun() { : > "$HL/logs/demo.log"
  HARNESS="$HL" STUB_FLAG_ACTIVE=1 "$@" bash "$HL/bin/launch-fastpath.sh" demo 900 >/dev/null 2>&1; RC=$?
  REASON=$(grep -F 'FASTPATH-DECLINED 900 ::' "$HL/logs/demo.log" 2>/dev/null | tail -1 | sed 's/.*:: //'); }
fresh "$HL" fastpath-off; rows "switch.fastpath-off.$BOX=1"; lfrun env
eq "LF-1 a box row of 1 with no file declines 'fastpath off'" "$REASON" "fastpath off"
NF2=$(flagreqs)
fresh "$HL" fastpath-off; rows switch.fastpath-off=0; touch "$HL/flags/fastpath-off"; lfrun env
[ -n "$REASON" ] && [ "$REASON" != "fastpath off" ] && ok || bad "LF-2: a row of 0 must beat the file (reason '$REASON')"
eq "LF-2 one lane-gate.log line names the ignored file" "$(lglines "$HL" fastpath-off)" 1
NF2=$((NF2 + $(flagreqs)))
fresh "$HL" fastpath-off; rows; touch "$HL/flags/fastpath-off"; lfrun env
eq "LF-3 no row and the file declines as before" "$REASON" "fastpath off"
NF2=$((NF2 + $(flagreqs)))
fresh "$HL" fastpath-off; rows switch.fastpath-off=0; touch "$HL/flags/fastpath-off"; lfrun env LANE_GATE_DISABLE=1
eq "LF-4 LANE_GATE_DISABLE=1 turns the rows off, not the file" "$REASON" "fastpath off"
NF2=$((NF2 + $(flagreqs)))
# LF-5 — a half-synced bin/: the file still declines instead of the script dying.
fresh "$HL" fastpath-off; rows; halfclient "$HL"; touch "$HL/flags/fastpath-off"; lfrun env
eq "LF-5 a client that exits when sourced: the file still declines" "$REASON" "fastpath off"
stubclient "$HL"
rm -f "$HL/flags/fastpath-off"
eq "NF-2 launch-fastpath (file mode) makes no /api/flags request" "$NF2" 0

# ════════════════════════════════════════════════════════════════════════════
# WL — the real bin/wake-loop.sh, fp_on's fastpath-off (file mode), in
# tests/wake-fastpath-test.sh's shape: the real jobs client over a fake curl
# that also serves GET /api/settings from $ROWS_FILE, and a recording
# launch-fastpath.sh. One local-arm issue wake per run.
# ════════════════════════════════════════════════════════════════════════════
(
  HW="$T/wl"
  mkdir -p "$HW/bin/lib/jobs" "$HW/env" "$HW/logs" "$HW/locks" "$HW/state" "$HW/flags" "$HW/calls" "$HW/catalog" || exit 1
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$HW/env/global.env"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/wake-loop.sh" "$DIR/bin/box-for.sh" "$DIR/bin/unblocked-children.sh" "$HW/bin/" || exit 1
  cp "$DIR"/bin/lib/jobs/*.sh "$HW/bin/lib/jobs/" || exit 1
  cp "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
     "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$HW/bin/lib/" || exit 1
  cp "$(rendered_registry)" "$HW/catalog/lanes.json" || exit 1
  # The wake routes (claim / cursor / cooldown / ack, BH-2637) and the real
  # identity scripts: the loop runs AS the hub, which owns project-3 (box=local).
  wcs_install "$HW/bin" && wcs_identity "$HW/bin" || exit 1
  cat > "$HW/bin/fleet-conf.sh" <<'SH'
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3 ;;
  project-3/box) echo local ;;
  project-3/board_prefix) echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
  for s in merge-conductor deploy-train postmerge-qa run-triage; do
    printf 'echo "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$HW/bin/$s.sh"
  done
  printf 'echo "$*" >> "$HARNESS/calls/launch-fastpath"\nexit 0\n' > "$HW/bin/launch-fastpath.sh"
  cat > "$HW/bin/curl" <<'SH'
echo "$*" >> "$HARNESS/calls/curl"
"$(dirname "$0")/wcs-routes" "$@" && exit 0
case "$*" in
  *"/api/settings"*)  printf '{"settings":%s}\n200' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')"; exit 0 ;;
esac
printf '{}\n200'
SH
  printf 'echo "$*" >> "$HARNESS/calls/ssh"\n' > "$HW/bin/ssh"
  printf 'echo "$*" >> "$HARNESS/calls/gh"\necho "[]"\n' > "$HW/bin/gh"
  printf 'exec "$@"\n' > "$HW/bin/setsid"
  printf 'exit 0\n' > "$HW/bin/flock"
  chmod +x "$HW/bin/"*.sh "$HW/bin/curl" "$HW/bin/ssh" "$HW/bin/gh" "$HW/bin/setsid" "$HW/bin/flock"
  export HARNESS="$HW" BOX_NAME="$BOX" HUB_BOX_NAME="$BOX" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 PATH="$HW/bin:$PATH"
  export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
  printf '{"wakes":[{"id":10,"repo":"example-org/project-3","kind":"issue","key":"41","event":"ev","at":"2026-09-12T11:39:04Z"}]}' > "$HW/wakes.json"
  wlrun() {
    scratch_rm "$HW/calls"; scratch_rm "$HW/state"; mkdir -p "$HW/calls" "$HW/state"; : > "$HW/logs/wake-loop.log"
    "$HW/bin/wake-loop.sh" >/dev/null 2>&1
    local i; for i in $(seq 1 40); do [ -s "$HW/calls/launch-fastpath" ] || [ -s "$HW/calls/run-triage" ] && break; sleep 0.1; done
    sleep 0.3
  }
  fpcalls() { [ -f "$HW/calls/launch-fastpath" ] && grep -c . "$HW/calls/launch-fastpath" || echo 0; }
  fresh "$HW" fastpath-off; rows "switch.fastpath-off.$BOX=1"; wlrun
  eq "WL-1 a box row of 1 with no file: launch-fastpath is not called" "$(fpcalls)" 0
  grep -qx project-3 "$HW/calls/run-triage" 2>/dev/null && ok || bad "WL-1: the local arm must still buy its triage tick"
  fresh "$HW" fastpath-off; rows switch.fastpath-off=0; touch "$HW/flags/fastpath-off"; wlrun
  eq "WL-2 a row of 0 beats the file: launch-fastpath is called once" "$(fpcalls)" 1
  eq "WL-2 one lane-gate.log line names the ignored file" "$(lglines "$HW" fastpath-off)" 1
  fresh "$HW" fastpath-off; rows; touch "$HW/flags/fastpath-off"; wlrun
  eq "WL-3 no row and the file: launch-fastpath is not called, as before" "$(fpcalls)" 0
  rm -f "$HW/flags/fastpath-off"
) || bad "WL: the wake-loop fixture did not install"

# ════════════════════════════════════════════════════════════════════════════
# BD / DV — the real lib functions (file mode). $h is the scratch harness and
# $HARNESS points nowhere, so an answer read from $HARNESS is wrong.
# ════════════════════════════════════════════════════════════════════════════
HD="$T/libs"; mkh "$HD" || exit 1
# libcall <fn> — one call in a cold shell with the lib sourced; prints the
# output as `[<bytes>]`, then `leak=<names>` for anything the call left behind.
libcall() {
  env HARNESS=/nonexistent STUB_FLAG_ACTIVE=1 bash -c '
    set -u
    . "$1/bin/lib/builder-direct.sh" || exit 9
    . "$1/bin/lib/dep-verify-lib.sh" || exit 9
    # Called in THIS shell, into a file: a $(...) would be a subshell of its
    # own and hide exactly the leak this checks for.
    "$2" "$3" > "$4"
    printf "[%s] bytes=%s" "$(cat "$4")" "$(wc -c < "$4" | tr -d " ")"
    leak=""
    for f in lane_switch routing_builder flag_active _lg_settings_refresh _jobs_req; do
      command -v "$f" >/dev/null 2>&1 && leak="$leak $f"
    done
    printf " leak=%s" "${leak:-none}"' _ "$DIR" "$1" "$HD" "$T/libcall.out"
}
for pair in builder_direct_on:builder-direct-off:BD dep_verify_on:dep-verify-off:DV; do
  fn=${pair%%:*}; rest=${pair#*:}; sw=${rest%%:*}; tag=${rest#*:}
  fresh "$HD" "$sw"; rows "switch.$sw.$BOX=1"
  eq "$tag-1 a box row of 1 with no file answers exactly 0" "$(libcall "$fn")" "[0] bytes=2 leak=none"
  fresh "$HD" "$sw"; rows "switch.$sw=0"; touch "$HD/flags/$sw"
  eq "$tag-2 a row of 0 beats the file: exactly 1" "$(libcall "$fn")" "[1] bytes=2 leak=none"
  eq "$tag-2 one lane-gate.log line names the ignored file" "$(lglines "$HD" "$sw")" 1
  fresh "$HD" "$sw"; rows; touch "$HD/flags/$sw"
  eq "$tag-3 no row and the file answers 0 as before" "$(libcall "$fn")" "[0] bytes=2 leak=none"
  fresh "$HD" "$sw"; rows
  eq "$tag-3b no row and no file answers 1 as before" "$(libcall "$fn")" "[1] bytes=2 leak=none"
  eq "NF-3 $fn (file mode) makes no /api/flags request" "$(flagreqs)" 0
  rm -f "$HD/flags/$sw"
done
# BD-4 — with no lane-switch lib under $h the answer is the file under $h.
HD0="$T/libs-bare"; mkdir -p "$HD0/flags"
touch "$HD0/flags/builder-direct-off"
eq "BD-4 no lib under \$h: the file under \$h answers" "$(env HARNESS=/nonexistent bash -c '. "$1/bin/lib/builder-direct.sh"; builder_direct_on "$2"' _ "$DIR" "$HD0")" 0
# BD-5 / DV-5 — a half-synced bin/ under $h: the client's `exit 1` must not
# read as "switch on", so the file answers both ways.
halfclient "$HD"
for pair in builder_direct_on:builder-direct-off:BD dep_verify_on:dep-verify-off:DV; do
  fn=${pair%%:*}; rest=${pair#*:}; sw=${rest%%:*}; tag=${rest#*:}
  fresh "$HD" "$sw"; rows; touch "$HD/flags/$sw"
  eq "$tag-5 a client that exits when sourced, and the file: 0" "$(libcall "$fn")" "[0] bytes=2 leak=none"
  fresh "$HD" "$sw"; rows
  eq "$tag-5b a client that exits when sourced, no file: 1" "$(libcall "$fn")" "[1] bytes=2 leak=none"
done
stubclient "$HD"

# ════════════════════════════════════════════════════════════════════════════
# W — the real bin/fly-trial-kill.sh: touch the file, PUT the box row, re-read
# it, and say "inert" only when the re-read says ON.
# ════════════════════════════════════════════════════════════════════════════
KL="$T/k"
kfix() { # kfix [noclient]
  scratch_rm "$KL"; mkh "$KL" || return 1
  mkdir -p "$KL/state/fly"
  printf 'FLY_ORG=o\n' > "$KL/env/fly.env"
  printf '{"app":"pool-p"}\n' > "$KL/state/fly/p.json"
  printf '#!/bin/sh\necho stopped\n' > "$KL/bin/fly-api.sh"
  printf '#!/bin/sh\nexit 0\n' > "$KL/bin/fly-dispatch.sh"
  chmod +x "$KL/bin/fly-api.sh" "$KL/bin/fly-dispatch.sh"
  : > "$KL/flags/builder-fly-p"
  [ "${1:-}" = noclient ] && rm -f "$KL/bin/jobs-client.sh"
  rm -f "$CALLS" "$CALLS.put" "$ROWS_FILE"; : > "$CALLS"
}
krun() { HARNESS="$KL" "$@" bash "$DIR/bin/fly-trial-kill.sh" p > "$T/kill.out" 2>&1; KRC=$?; }
kout() { cat "$T/kill.out"; }

# W1 — the row is PUT, the re-read says ON, "inert", rc 0.
kfix; rows; krun env
[ -e "$KL/flags/fly-disabled" ] && ok || bad "W1: flags/fly-disabled must still be touched"
grep -q '^PUT /api/settings$' "$CALLS" && ok || bad "W1: the kill must PUT /api/settings (calls: $(cat "$CALLS"))"
eq "W1 the PUT body" "$(jq -c '{key,value,actor}' "$CALLS.put" 2>/dev/null)" \
   "{\"key\":\"switch.fly-disabled.$BOX\",\"value\":\"1\",\"actor\":\"fly-trial-kill\"}"
grep -q "wrote switch.fly-disabled.$BOX=1" <<<"$(kout)" && ok || bad "W1: the output must say the row was written ($(kout))"
grep -q "fly-disabled is on (settings switch.fly-disabled.$BOX) — dispatcher + ingest are inert as of now" <<<"$(kout)" \
  && ok || bad "W1: the re-read must name the row and say inert ($(kout))"
eq "W1 rc" "$KRC" 0
grep -q "set switch.fly-disabled.$BOX=0 (PUT /api/settings, or delete the row) AND rm flags/fly-disabled" <<<"$(kout)" \
  && ok || bad "W1: the resume line must name the row AND the file ($(kout))"
[ ! -e "$KL/flags/builder-fly-p" ] && grep -q 'machine stop -> stopped' <<<"$(kout)" && ok || bad "W1: the machines and routing are still handled"

# W2 — the PUT fails and an existing row says 0: NOT in effect, no inert, rc 1,
# and the machine is stopped anyway.
kfix; rows "switch.fly-disabled.$BOX=0"; krun env PUT_FAIL=1
grep -q "row PUT failed (switch.fly-disabled.$BOX)" <<<"$(kout)" && ok || bad "W2: a failed PUT must be said ($(kout))"
grep -q "wrote " <<<"$(kout)" && bad "W2: a failed PUT must never read as written ($(kout))" || ok
grep -q "fly-disabled is NOT in effect: settings switch.fly-disabled.$BOX" <<<"$(kout)" && ok \
  || bad "W2: the re-read must say NOT in effect and name the row ($(kout))"
grep -q 'inert as of now' <<<"$(kout)" && bad "W2: 'inert' must not be claimed ($(kout))" || ok
eq "W2 rc" "$KRC" 1
grep -q 'machine stop -> stopped' <<<"$(kout)" && [ ! -e "$KL/flags/builder-fly-p" ] && ok \
  || bad "W2: the machines are stopped and the routing dropped anyway ($(kout))"

# W3 — no jobs client: the file only, said so; the legacy re-read says ON.
kfix noclient; krun env
grep -q 'row not written (no jobs client), flags/fly-disabled only' <<<"$(kout)" && ok || bad "W3: no client must be said ($(kout))"
[ -e "$KL/flags/fly-disabled" ] && ok || bad "W3: the file must be touched"
grep -q 'fly-disabled is on (flags/fly-disabled) — dispatcher + ingest are inert as of now' <<<"$(kout)" && ok \
  || bad "W3: the legacy re-read says inert ($(kout))"
eq "W3 rc" "$KRC" 0

# W-fresh — a cache filled under the TTL before the PUT holds 0; the PUT
# persists 1. The re-read must fetch again and say inert.
kfix; rows "switch.fly-disabled.$BOX=0"
jq -nc --argjson fa "$(date -u +%s)" --arg k "switch.fly-disabled.$BOX" '{fetched_at:$fa, values:{($k):"0"}, seeded:{}}' \
  > "$KL/state/settings-cache.json"
krun env
grep -q "fly-disabled is on (settings switch.fly-disabled.$BOX)" <<<"$(kout)" && ok \
  || bad "W-fresh: a fresh cache holding 0 must not answer for the PUT ($(kout))"
eq "W-fresh rc" "$KRC" 0

# W4 — a half-synced bin/: the re-read's client exits. The kill must go on to
# stop the machine and drop the routing, say the switch is NOT confirmed and
# why, never claim inert, and exit 1.
kfix; rows; halfclient "$KL"; krun env
[ -e "$KL/flags/fly-disabled" ] && ok || bad "W4: the file must be touched"
grep -q 'fly-disabled is NOT confirmed: the re-read died loading bin/jobs-client.sh' <<<"$(kout)" && ok \
  || bad "W4: the re-read must name the client that did not load ($(kout))"
grep -q 'inert as of now' <<<"$(kout)" && bad "W4: 'inert' must not be claimed ($(kout))" || ok
grep -q 'machine stop -> stopped' <<<"$(kout)" && [ ! -e "$KL/flags/builder-fly-p" ] && ok \
  || bad "W4: the machines are stopped and the routing dropped anyway ($(kout))"
grep -q 'DONE\.' <<<"$(kout)" && ok || bad "W4: the kill must run to the end ($(kout))"
eq "W4 rc" "$KRC" 1

# ════════════════════════════════════════════════════════════════════════════
# S0 — nothing in bin/ still reads one of the eight names as a bare file, via
# flag_on/flag_active, or through FASTPATH_OFF. The file list is guarded, so
# an empty or moved bin/ fails instead of passing.
# ════════════════════════════════════════════════════════════════════════════
NAMES='batch-resolve-off|blocked-resolver-disabled|context-gate-disabled|bin-self-heal-off|fly-disabled|fastpath-off|builder-direct-off|dep-verify-off'
NSCRIPTS=$(find "$DIR/bin" -name '*.sh' | wc -l | tr -d ' ')
[ "$NSCRIPTS" -gt 100 ] && ok || bad "S0: bin/ has $NSCRIPTS scripts — the scan would prove nothing"
S0=$(grep -rnE "\[ +-[ef] +[^]]*flags/($NAMES)[\"' ]|flag_(on|active) +\"?($NAMES)\\b|FASTPATH_OFF" "$DIR/bin" --include='*.sh' 2>/dev/null \
     | grep -vE '^[^:]+:[0-9]+: *#')
[ -z "$S0" ] && ok || bad "S0: a bare read of a converted switch is left:
$S0"

P=$(grep -c P "$TALLY"); F=$(grep -c F "$TALLY")
echo "switch-convert-pipeline.bh-2435: $P passed, $F failed"
[ "$F" -eq 0 ]
