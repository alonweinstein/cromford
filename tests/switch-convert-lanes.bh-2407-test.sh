#!/bin/bash
# tests/switch-convert-lanes.bh-2407-test.sh — BH-2434 (BH-2407.3): the audit,
# clock, SLO and alerting kill switches are read through lane_switch
# (bin/lib/lane-switch.sh) in `file` mode, so a settings row decides before
# flags/<name> does.
#
# Every case drives the REAL script on a scratch harness that carries the real
# bin/lib/lane-gate.sh and bin/lib/lane-switch.sh, and a stub bin/jobs-client.sh
# whose _jobs_req answers GET /api/settings from $ROWS_FILE (the pattern of
# tests/lane-switch.bh-2320-test.sh).
#
#   C  clock-sync-off             bin/clock-sync.sh
#   F  fleet-slo-off              bin/fleet-slo.sh
#   AT audit-off                  bin/audit-tail.sh
#   AI audit-off                  bin/audit-install.sh (install path + --check)
#   X  fixpr-suppress-off         bin/alert-triage.sh
#   S  alert-state-off            alert_state_enabled in bin/lib/alert-state.sh
#   Q  alert-quarantine-disabled  bin/beat.sh
#
# For each: (i) row switch.<name>=1 and no file stops it; (ii) row =0 with the
# file present runs it and logs/lane-gate.log names the ignored file once;
# (iii) no row: the file stops it, no file runs it. Then the negatives N1-N4,
# the lazy load L1, the --check strings and its no-write promise, and S0.
# Run from anywhere: tests/switch-convert-lanes.bh-2407-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

REG=$(rendered_registry)
export ROWS_FILE="$T/rows.json" CALLS="$T/calls" JOBS_BOX=hub-1

cat > "$T/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "${CALLS:-/dev/null}"
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) [ -n "${JOBS_FIXTURE:-}" ] || return 1; cat "$JOBS_FIXTURE" 2>/dev/null ;;
  esac
}
SH

# mkh <root> — a scratch harness with the real switch libs and the stub worker.
mkh() {
  mkdir -p "$1/bin/lib" "$1/flags" "$1/state" "$1/logs" "$1/env" "$1/locks" "$1/catalog"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
  cp "$REG" "$1/catalog/lanes.json"
  cp "$T/stub-jobs-client.sh" "$1/bin/jobs-client.sh"
  : > "$1/env/global.env"
}
# rows k=v [k=v...] — the settings table the stub worker returns.
rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$ROWS_FILE"
}
# swreset <root> — no row, no flag, no settings cache, no lane-gate log.
swreset() {
  scratch_rm "$1/state/lane-gate"; scratch_rm "$1/state/settings-cache.json"; scratch_rm "$1/logs/lane-gate.log"
  rm -f "$1/flags"/* "$ROWS_FILE"
  : > "$CALLS"
}
gatelines() { # gatelines <root> <switch> — lines naming a file a 0 row beat
  [ -f "$1/logs/lane-gate.log" ] && grep -c "switch $2: row says 0 (switch.$2), flags/$2 ignored" "$1/logs/lane-gate.log" || echo 0
}

# tri <id> <switch> <root> — the three halves. <id>_reset, <id>_run and <id>_ran
# (rc 0 when the thing the switch names DID run) are the case's own.
tri() {
  local id="$1" sw="$2" h="$3"
  "${id}_reset"; rows "switch.$sw=1"; "${id}_run"
  "${id}_ran" && bad "$id (i) row switch.$sw=1 with no file must stop it" || ok
  "${id}_reset"; rows "switch.$sw=0"; touch "$h/flags/$sw"; "${id}_run"
  "${id}_ran" && ok || bad "$id (ii) row switch.$sw=0 must beat flags/$sw"
  eq "$id (ii) one lane-gate.log line names the ignored file" "$(gatelines "$h" "$sw")" 1
  "${id}_reset"; touch "$h/flags/$sw"; "${id}_run"
  "${id}_ran" && bad "$id (iii) no row: flags/$sw must stop it" || ok
  "${id}_reset"; "${id}_run"
  "${id}_ran" && ok || bad "$id (iii) no row and no file: it must run"
}

# ── C: clock-sync ────────────────────────────────────────────────────────────
HC="$T/c"; mkh "$HC"; mkdir -p "$T/cbin"
cp "$DIR/bin/clock-sync.sh" "$HC/bin/"
printf '#!/bin/bash\nexit 1\n' > "$T/cbin/curl"            # no time source
printf '#!/bin/bash\nexit 0\n' > "$T/cbin/pgrep"           # an NTP daemon owns the clock
printf '#!/bin/bash\necho yes\n' > "$T/cbin/timedatectl"
chmod +x "$T/cbin"/*
C_reset() { swreset "$HC"; rm -f "$HC/logs/clock-sync.log"; }
C_run()   { env PATH="$T/cbin:$PATH" HARNESS="$HC" bash "$HC/bin/clock-sync.sh" >/dev/null 2>&1; }
C_ran()   { [ -s "$HC/logs/clock-sync.log" ]; }
tri C clock-sync-off "$HC"

# ── F: fleet-slo ─────────────────────────────────────────────────────────────
HF="$T/f"; mkh "$HF"
cp "$DIR/bin/fleet-slo.sh" "$DIR/bin/result-prefix-ok.sh" "$HF/bin/"
printf 'SLO_REFUSAL_MIN_LAUNCHES 4\n' > "$T/slo.conf"
echo "demo-os example-org/demo-os https://x - 2 box-gone" > "$HF/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$HF/bin/lane-alert.sh"; chmod +x "$HF/bin"/*.sh
echo '{"jobs":[]}' > "$T/jobs.json"
F_reset() { swreset "$HF"; scratch_rm "$HF/state/slo"; FOUT=""; }
F_run()   { FOUT=$(env HARNESS="$HF" SLO_CONF="$T/slo.conf" JOBS_FIXTURE="$T/jobs.json" bash "$HF/bin/fleet-slo.sh" 2>/dev/null); }
F_ran()   { [ -s "$HF/state/slo/status.json" ]; }
tri F fleet-slo-off "$HF"
F_reset; rows switch.fleet-slo-off=1; F_run
grep -qx 'fleet-slo disabled by flag' <<<"$FOUT" && ok || bad "F (i) a row stop still says 'fleet-slo disabled by flag' (got: $FOUT)"
# N2 — a longer name is another switch.
F_reset; touch "$HF/flags/fleet-slo-off-extra"; F_run
F_ran && ok || bad "N2 flags/fleet-slo-off-extra must not stop fleet-slo"
# N3 — another box's row does not reach this box.
F_reset; rows switch.fleet-slo-off.other-box=1; F_run
F_ran && ok || bad "N3 switch.fleet-slo-off.other-box=1 must not stop fleet-slo on hub-1"
F_reset; rows switch.fleet-slo-off.hub-1=1; F_run
F_ran && bad "N3 this box's own row switch.fleet-slo-off.hub-1=1 must stop it" || ok
# N4 — a value nobody can read is no row: the file decides.
F_reset; rows "switch.fleet-slo-off=yes please"; F_run
F_ran && ok || bad "N4 row 'yes please' with no file must run"
F_reset; rows "switch.fleet-slo-off=yes please"; touch "$HF/flags/fleet-slo-off"; F_run
F_ran && bad "N4 row 'yes please' with the file present: the file must stop it" || ok

# ── AT: audit-tail ───────────────────────────────────────────────────────────
HAT="$T/at"; mkh "$HAT"; mkdir -p "$T/atbin"
cp "$DIR/bin/audit-tail.sh" "$HAT/bin/"
printf '#!/bin/bash\nexit 1\n' > "$T/atbin/pgrep"; chmod +x "$T/atbin/pgrep"   # auditd not running
printf '#!/bin/bash\nexit 0\n' > "$HAT/bin/lane-alert.sh"; chmod +x "$HAT/bin/lane-alert.sh"
AT_reset() { swreset "$HAT"; rm -f "$HAT/state"/audit-tail-blind-* "$HAT/logs/audit-tail.log" "$HAT/logs/ALERTS.log"; }
AT_run()   { env PATH="$T/atbin:$PATH" HARNESS="$HAT" bash "$HAT/bin/audit-tail.sh" >/dev/null 2>&1; }
AT_ran()   { [ -s "$HAT/logs/audit-tail.log" ]; }
tri AT audit-off "$HAT"

# ── AI: audit-install ────────────────────────────────────────────────────────
HAI="$T/ai"; mkh "$HAI"; mkdir -p "$T/aibin" "$T/aietc"
cp "$DIR/bin/audit-install.sh" "$HAI/bin/"
for s in apt-get pgrep pkill supervisorctl systemctl augenrules auditd; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/ai.calls"\nexit 1\n' "$s" "$T" > "$T/aibin/$s"
done
chmod +x "$T/aibin"/*
AIENV=(HARNESS="$HAI" AUDIT_RULES_FILE="$T/aietc/harness.rules" AUDITD_CONF="$T/aietc/auditd.conf"
       AUDIT_SUPERVISOR_DIR="$T/nosup" AUDIT_SYSTEMD_DIR="$T/nosys" AUDIT_SBIN_PATH="")
AI_reset() { swreset "$HAI"; rm -f "$HAI/logs/audit-install.log" "$HAI/logs/ALERTS.log" "$HAI/state"/audit-install-* "$T/ai.calls"; }
AI_run()   { env PATH="$T/aibin:/usr/bin:/bin" "${AIENV[@]}" bash "$HAI/bin/audit-install.sh" >/dev/null 2>&1; }
AI_ran()   { [ -s "$HAI/logs/audit-install.log" ]; }
tri AI audit-off "$HAI"
AI_reset; rows switch.audit-off=1; AI_run
[ -f "$T/ai.calls" ] && bad "AI (i) a row stop must not reach apt-get: $(cat "$T/ai.calls")" || ok

# --check names where the answer came from, and still writes nothing: it reads
# the settings cache the install path and every lane keep warm.
warm() { env HARNESS="$HAI" bash -c '. "$HARNESS/bin/lib/lane-switch.sh"; lane_switch audit-off file' >/dev/null 2>&1; }
check() {
  local before after out
  before=$(find "$HAI" | sort; find "$HAI" -type f -exec md5sum {} + | sort)
  out=$(env PATH="$T/aibin:/usr/bin:/bin" "${AIENV[@]}" bash "$HAI/bin/audit-install.sh" --check 2>&1)
  after=$(find "$HAI" | sort; find "$HAI" -type f -exec md5sum {} + | sort)
  [ "$before" = "$after" ] || bad "AI --check wrote under the harness: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  printf '%s' "$out" | grep '^kill switch:'
}
AI_reset; rows switch.audit-off=1; warm
eq "AI --check fleet row" "$(check)" "kill switch: settings switch.audit-off"
AI_reset; rows switch.audit-off.hub-1=1; warm
eq "AI --check box row" "$(check)" "kill switch: settings switch.audit-off.hub-1"
AI_reset; touch "$HAI/flags/audit-off"; warm
eq "AI --check no row, the file" "$(check)" "kill switch: flags/audit-off"
AI_reset; rows switch.audit-off=0; touch "$HAI/flags/audit-off"; warm; rm -f "$HAI/logs/lane-gate.log"
eq "AI --check row 0 beats the file" "$(check)" "kill switch: none"
AI_reset; touch "$HAI/flags/audit-off"
eq "AI --check with no settings cache: the file" "$(check)" "kill switch: flags/audit-off"
AI_reset
eq "AI --check nothing on" "$(check)" "kill switch: none"
AI_reset; rows switch.audit-off=1; warm
eq "AI --check an inherited LANE_SWITCH_SRC names nothing" \
   "$(LANE_SWITCH_SRC=box-row check)" "kill switch: settings switch.audit-off"

# ── X: alert-triage's fix-PR suppression ─────────────────────────────────────
HX="$T/x"; mkh "$HX"; mkdir -p "$T/xstub" "$T/xcalls"
model_routes_fixture "$HX" || bad "X model_routes_fixture failed"
sed "s|/root/harness|$HX|g" "$DIR/bin/alert-triage.sh" > "$HX/bin/alert-triage.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py gh-pr-state.sh; do ln -sf "$DIR/bin/$s" "$HX/bin/$s"; done
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh; do ln -sf "$DIR/bin/lib/$s" "$HX/bin/lib/$s"; done
cat > "$HX/bin/agent-call.sh" <<'STUB'
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
printf 'handled=1 escalated=0 noise=0\n' > "$5"
STUB
printf 'printf "%%s\\n" "$1" >> "%s/xbeats"\nexit 0\n' "$T" > "$HX/bin/beat.sh"
cat > "$T/xstub/gh" <<'STUB'
case "$*" in
  *repos/*/pulls/*) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"state":"open","merged_at":null}\n' ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/xstub/ssh"; printf '#!/bin/sh\nexit 0\n' > "$T/xstub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/xstub/timeout"
chmod +x "$HX/bin"/*.sh "$T/xstub"/*
triage_tick_setup "$HX" || bad "X triage_tick_setup failed"   # BH-5942: dispatch + per-project run
XNOW=$(date -u +%s)
XLINE=$(printf '%s\t{"kind":"fleet_alert","project":"proj-alpha","akey":"akey-alpha","line":"the alpha subsystem is unhappy"}' "$XNOW")
XFAM=$(python3 "$DIR/bin/alert_family.py" family "$(printf 'hub\t%s' "$XLINE")")
X_reset() {
  swreset "$HX"; rm -rf "$T/xcalls"; mkdir -p "$T/xcalls"; triage_tick_reset "$HX"
  : > "$HX/logs/alert-triage.log"; : > "$HX/logs/ALERTS.log"
  echo '{}' > "$HX/state/alert-families.json"; : > "$HX/state/alert-triage-deferred.tsv"
  printf '%s\n' "$XLINE" > "$HX/state/alert-quarantine.jsonl"
  jq -n --arg f "$XFAM" --argjson t "$((XNOW - 3600))" \
    '{($f): {pr_url:"https://github.com/example-org/cromford/pull/573", first_seen:$t, last_checked:$t, suppressed_total:0, beat_day:"", stale_beat_at:0}}' \
    > "$HX/state/alert-fix-prs.json"
}
X_run() {
  HARNESS="$HX" CALLDIR="$T/xcalls" PATH="$T/xstub:$PATH" TRIAGE_NOW="$XNOW" FLEET_CONF="$DIR/fleet.conf" \
    triage_tick "$HX/bin/alert-triage.sh" >/dev/null 2>&1
}
# "Ran" is the suppression: an open fix PR buys no session.
X_ran() { [ "$(ls "$T/xcalls"/prompt-* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && grep -q ANSWERED-PENDING-MERGE "$HX/logs/alert-triage.log"; }
tri X fixpr-suppress-off "$HX"
X_reset; rows switch.fixpr-suppress-off=1; X_run
eq "X (i) the switch buys the session back" "$(ls "$T/xcalls"/prompt-* 2>/dev/null | wc -l | tr -d ' ')" 1

# ── S: alert_state_enabled, and L1 the lazy load ─────────────────────────────
HS="$T/s"; mkh "$HS"
cp "$DIR/bin/lib/alert-state.sh" "$HS/bin/lib/"
# The real bin/jobs-client.sh sets -uo pipefail at its top level; so does this
# one, so L1 proves the caller gets its own options back.
sed -i '1i set -uo pipefail' "$HS/bin/jobs-client.sh"
S_reset() { swreset "$HS"; }
S_run()   { SRC=0; env HARNESS="$HS" bash -c '. "$HARNESS/bin/lib/alert-state.sh" && alert_state_enabled' >/dev/null 2>&1 || SRC=1; }
S_ran()   { [ "$SRC" = 0 ]; }
tri S alert-state-off "$HS"
S_reset; rows switch.alert-state-off=0
L1=$(env HARNESS="$HS" bash -c '
  set +u +o pipefail
  . "$HARNESS/bin/lib/alert-state.sh"
  a=$(declare -F | grep -c " _lg_")
  alert_state_enabled; rc=$?
  b=$(declare -F | grep -c " _lg_")
  echo "before=$a rc=$rc after=$([ "$b" -gt 0 ] && echo some || echo none) opts=$(set -o | awk "\$1==\"nounset\"||\$1==\"pipefail\"{printf \"%s:%s \", \$1, \$2}")"' 2>&1)
eq "L1 sourcing alert-state.sh defines no _lg_*; the switch read loads it; caller options kept" \
   "$L1" "before=0 rc=0 after=some opts=nounset:off pipefail:off "
# The hatch and a fixture alerts.conf load nothing and the file decides, as
# lane_switch's own step 1 does under the hatch.
for xe in LANE_GATE_DISABLE=1 "ALERTS_CONF=$T/fixture-alerts.conf"; do
  S_reset; rows switch.alert-state-off=0; touch "$HS/flags/alert-state-off"
  eq "S $xe: the file decides and no lib is loaded" \
     "$(env HARNESS="$HS" "$xe" bash -c '. "$HARNESS/bin/lib/alert-state.sh"; alert_state_enabled; echo "rc=$? lg=$(declare -F | grep -c " _lg_")"' 2>/dev/null)" "rc=1 lg=0"
  S_reset; rows switch.alert-state-off=1
  eq "S $xe: a row alone does not turn it off" \
     "$(env HARNESS="$HS" "$xe" bash -c '. "$HARNESS/bin/lib/alert-state.sh"; alert_state_enabled; echo "rc=$?"' 2>/dev/null)" "rc=0"
done

# ── Q: beat.sh's quarantine, and N1 ──────────────────────────────────────────
HQ="$T/q"; mkh "$HQ"; mkdir -p "$T/qbin"
cp "$DIR/bin/beat.sh" "$DIR/bin/alert_family.py" "$HQ/bin/"
cp "$DIR/bin/lib/alert-state.sh" "$HQ/bin/lib/"
printf '#!/bin/bash\necho 000\n' > "$T/qbin/curl"; chmod +x "$T/qbin/curl"
QPAY='{"kind":"fleet_alert","project":"proj-q","line":"the q subsystem is unhappy"}'
Q_reset() { swreset "$HQ"; touch "$HQ/flags/remediation-disabled" "$HQ/flags/alert-state-off"; rm -f "$HQ/state/alert-quarantine.jsonl"; }
Q_run()   { env PATH="$T/qbin:$PATH" HARNESS="$HQ" bash "$HQ/bin/beat.sh" "$QPAY" >/dev/null 2>&1; }
Q_ran()   { [ -s "$HQ/state/alert-quarantine.jsonl" ]; }
tri Q alert-quarantine-disabled "$HQ"
# N1 — remediation-disabled (present in every Q case above) is not the switch,
# and a triaged beat never queues whatever the row says.
Q_reset; Q_run
Q_ran && ok || bad "N1 flags/remediation-disabled must not turn quarantine off"
Q_reset; rows switch.alert-quarantine-disabled=0
env PATH="$T/qbin:$PATH" HARNESS="$HQ" bash "$HQ/bin/beat.sh" '{"kind":"fleet_alert","triaged":true,"line":"x"}' >/dev/null 2>&1
Q_ran && bad "Q a triaged beat must never be queued" || ok

# ── S0: no bare file read of these six names is left in bin/ or fly/ ─────────
BARE_RE='\[ -[ef] [^]]*flags/(audit-off|clock-sync-off|fleet-slo-off|alert-state-off|fixpr-suppress-off|alert-quarantine-disabled)\b'
S0=$(grep -rnE "$BARE_RE" "$DIR/bin" "$DIR/fly" 2>/dev/null; grep -rnE '\[ ! -f [^]]*flags/alert-quarantine-disabled' "$DIR/bin" 2>/dev/null)
eq "S0 no bare read of the six switches" "$S0" ""

echo "switch-convert-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
