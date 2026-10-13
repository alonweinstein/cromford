#!/bin/bash
# tests/failover-drill-demote.bh-2748-test.sh — the demote slice of the
# failover drill (BH-2748, parent #402): fd_promote_back and fd_standby_quiet
# in bin/lib/failover-drill-demote.sh.
#
# Sources the REAL bin/lib/failover-drill-{common,demote}.sh from a scratch
# harness root and runs the REAL bin/hub-lease.sh through them (with the real
# jobs client and fleet.conf registry). Only curl, ssh and sleep are stubbed;
# each appends what it was asked to $T/seq.log. The standby's cron file is the
# REAL bin/standby-install.sh render, and the ssh stub runs the size-read
# command it is handed against $T/sb/logs, so the remote command itself is
# exercised.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/failover-drill-demote.bh-2748-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] contains [$3]" ;; *) ok ;; esac; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/env" "$H/state" "$T/fakebin" "$T/sb/logs" "$T/cron.d"
for f in failover-drill-common failover-drill-demote env-path hub-box; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
for f in hub-lease jobs-client fleet-conf box-name; do
  cp "$DIR/bin/$f.sh" "$H/bin/" || { echo "FAIL: missing bin/$f.sh"; exit 1; }
done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || { echo "FAIL: missing bin/lib/jobs"; exit 1; }
: > "$H/env/global.env"
echo box-hub > "$H/state/box-name"
cat > "$T/fleet.conf" <<'CONF'
# FIXTURE fleet.conf for tests/failover-drill-demote.bh-2748-test.sh
# @standby box-small box-hub hub
demo-os example-org/demo-os - - 3 box-small 192.0.2.10
CONF
unset BOX_NAME HUB_BOX_NAME HUB_LEASE_HOLDER HUB_LEASE_CACHE_S HUB_LEASE_NOW HUB_LEASE_EPOCH_CHECK \
      FAILOVER_DRILL_DEMOTE_SETTLE_S FAILOVER_DRILL_OBSERVE_S
export FLEET_CONF="$T/fleet.conf"

# curl: the jobs worker. GET /api/hub-lease answers the standby as holder until
# a promote POST has been seen; after it, NOT_HELD_POLLS more GETs still name
# the standby (NEVER_HELD=1: all of them), then the hub.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    *) shift ;;
  esac
done
printf 'curl %s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$STUB_DIR/seq.log"
lease() { printf '{"lease":{"holder":"%s","epoch":%s,"expired":false,"expires_at":"2026-09-27T01:00:00Z","updated_at":"2026-09-27T00:00:00Z"}}\n200' "$1" "$2"; }
case "$URL" in
  */api/hub/promote*)
    touch "$STUB_DIR/posted"
    if [ "${PROMOTE_CODE:-200}" = 200 ]; then
      TGT=$(printf '%s' "$BODY" | jq -r '.target // ""')
      printf '{"ok":true,"promoted":true,"lease":{"holder":"%s","epoch":6,"expired":false}}\n200' "$TGT"
    else
      printf '%s\n%s' "${PROMOTE_BODY:-}" "$PROMOTE_CODE"
    fi ;;
  */api/hub-lease*)
    if [ ! -e "$STUB_DIR/posted" ]; then lease box-small 5; exit 0; fi
    n=$(( $(cat "$STUB_DIR/gets" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/gets"
    if [ "${NEVER_HELD:-0}" = 1 ] || [ "$n" -le "${NOT_HELD_POLLS:-0}" ]; then lease box-small 6
    else lease box-hub 6; fi ;;
  *) printf '{}\n404' ;;
esac
EOF
# ssh: the standby. Runs the size-read command against $SB_LOGS; hook.<n>
# runs before size read n, which is how a lane "fires" between the two reads.
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
shift
cmd="$*"
printf 'ssh %s\n' "$cmd" >> "$STUB_DIR/seq.log"
case "$cmd" in
  "/root/harness/bin/hub-lease.sh check") exit "${STANDBY_CHECK_RC:-1}" ;;
  "cat /etc/cron.d/harness-standby")
    [ "${CRON_RC:-0}" = 0 ] || exit "$CRON_RC"
    cat "$CRON_FIXTURE"; exit 0 ;;
  *"stat -c"*)
    n=$(( $(cat "$STUB_DIR/statn" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/statn"
    [ "${SIZE_FAIL_AT:-0}" = "$n" ] && exit 255
    [ -x "$STUB_DIR/hook.$n" ] && "$STUB_DIR/hook.$n"
    out=$(bash -c "${cmd//\/root\/harness\/logs\//$SB_LOGS/}"); rc=$?
    out=${out//$SB_LOGS\//\/root\/harness\/logs\/}
    [ "${SIZE_DROP_AT:-0}" = "$n" ] && out=$(printf '%s\n' "$out" | sed 1d)
    printf '%s\n' "$out"; exit "$rc" ;;
esac
exit 99
EOF
printf '#!/bin/bash\nprintf "sleep %%s\\n" "$*" >> "$STUB_DIR/seq.log"\n' > "$T/fakebin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/pgrep"
chmod +x "$T/fakebin/"*
export STUB_DIR="$T" SB_LOGS="$T/sb/logs" PATH="$T/fakebin:$PATH" HARNESS="$H"
export HARNESS_SECRET=s JOBS_URL=http://stub JOBS_RETRIES=0 JOBS_ALERT=0
export FAILOVER_DRILL_SSH="$T/fakebin/ssh" FAILOVER_DRILL_NOW=1790000000

# ---- the standby's cron file, rendered by the REAL bin/standby-install.sh ----
# The hub crontab carries the shapes the real hub render has: the ungated
# renew, a compound cadence-backstop lane, a /dev/null lane, a lane with no
# redirect, a trailing shell comment that mentions a log, and a lane that
# writes only hub-lease.log (excluded, so unobservable). The installer gates
# EVERY hub line, so the hub's ungated fresh-lane is a gated lane here.
cat > "$T/hub.cron" <<'EOF'
SHELL=/bin/bash
@reboot /root/harness/bin/boot.sh
*/5 * * * * /root/harness/bin/watchdog-ping.sh box-hub
* * * * * /root/harness/bin/hub-lease.sh renew >/dev/null 2>&1
*/5 * * * * /root/harness/bin/hub-lease.sh check && { /root/harness/bin/lib/cadence-backstop.sh merge-conductor; [ $? -ne 3 ]; } && /root/harness/bin/merge-conductor.sh >> /root/harness/logs/merge-conductor-cron.log 2>&1
4,14 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/blocked-resolver.sh >> /root/harness/logs/blocked-resolver-cron.log 2>&1
17 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/harden-state.sh >/dev/null 2>&1 # was >> /root/harness/logs/decoy.log
* * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/wake-loop.sh
3 * * * * /root/harness/bin/hub-lease-audit.sh >>/root/harness/logs/hub-lease.log 2>&1
9 * * * * /root/harness/bin/fresh-lane.sh >>/root/harness/logs/fresh-lane.log 2>&1
EOF
: > "$T/own.cron"
render_standby() { # render_standby <hub-crontab> <own-crontab> <out>
  BACKUP_S3_ENDPOINT=x BACKUP_S3_ACCESS_KEY_ID=x BACKUP_S3_SECRET_ACCESS_KEY=x BACKUP_AGE_IDENTITY_FILE="$T/fleet.conf" \
    bash "$DIR/bin/standby-install.sh" box-small --conf "$T/fleet.conf" --cron-file "$T/cron.d/harness-standby" \
      --hub-crontab "$1" --own-crontab "$2" > "$3"
}
render_standby "$T/hub.cron" "$T/own.cron" "$T/cron.fixture"; eq "setup standby-install rc" "$?" 0
grep -q 'check && /root/harness/bin/merge-conductor' "$T/cron.fixture" && bad "setup: fixture shape changed" || ok
has "setup gated renew" "$(cat "$T/cron.fixture")" "root /root/harness/bin/hub-lease.sh check && /root/harness/bin/hub-lease.sh renew >/dev/null 2>&1"
has "setup stream line" "$(cat "$T/cron.fixture")" "standby-stream.log"

# shellcheck source=bin/lib/failover-drill-common.sh
. "$H/bin/lib/failover-drill-common.sh" || exit 1
# shellcheck source=bin/lib/failover-drill-demote.sh
. "$H/bin/lib/failover-drill-demote.sh" || exit 1

KNOBS="PROMOTE_CODE PROMOTE_BODY NOT_HELD_POLLS NEVER_HELD STANDBY_CHECK_RC CRON_RC SIZE_FAIL_AT SIZE_DROP_AT
       HUB_LEASE_CACHE_S FAILOVER_DRILL_DEMOTE_SETTLE_S FAILOVER_DRILL_OBSERVE_S"
reset() {
  # shellcheck disable=SC2086
  unset $KNOBS FD_T_BACK FD_DEMOTE_DETAIL FD_DEMOTE_VERDICT FD_DEMOTE_UNOBSERVABLE
  rm -f "$T/seq.log" "$T/posted" "$T/gets" "$T/statn" "$T"/hook.* "$H/state/hub-lease.json" "$H/state/hub-lease-failing-since" "$H/flags/"*
  : > "$T/seq.log"; : > "$H/logs/ALERTS.log"
  rm -rf "$T/sb/logs"; mkdir -p "$T/sb/logs"
  printf '%0100d' 0 > "$T/sb/logs/merge-conductor-cron.log"
  printf '%050d' 0 > "$T/sb/logs/blocked-resolver-cron.log"
  printf 'x\n' > "$T/sb/logs/hub-lease.log"; printf 'y\n' > "$T/sb/logs/standby-stream.log"
  printf 'z\n' > "$T/sb/logs/fresh-lane.log"
  export CRON_FIXTURE="$T/cron.fixture"
}
hook() { printf '#!/bin/bash\n%s\n' "$2" > "$T/hook.$1"; chmod +x "$T/hook.$1"; }
alerts() { wc -l < "$H/logs/ALERTS.log"; }
cnt() { grep -c -- "$1" "$T/seq.log"; }
slept() { cnt "^sleep $1\$"; }
promotes() { cnt 'curl POST http://stub/api/hub/promote'; }

# ===== fd_promote_back ========================================================
# P1: promote 200 → rc 0, FD_T_BACK is the pinned clock, the POST carries the
# ticket's reason, target and override flag.
reset
fd_promote_back drill1 box-hub; eq "P1 rc" "$?" 0
eq "P1 FD_T_BACK" "${FD_T_BACK:-<unset>}" 1790000000
eq "P1 detail" "${FD_DEMOTE_DETAIL-<unset>}" ""
eq "P1 one POST" "$(promotes)" 1
post=$(grep 'curl POST http://stub/api/hub/promote' "$T/seq.log")
has "P1 target" "$post" '"target":"box-hub"'
has "P1 override" "$post" '"override_live_lease":true'
has "P1 reason" "$post" '"reason":"failover drill drill1: promote back"'
eq "P1 no alert" "$(alerts)" 0

# P2: the hub's check is not-held twice, then held → rc 0 after exactly 2 sleeps.
reset; export HUB_LEASE_CACHE_S=0 NOT_HELD_POLLS=2
fd_promote_back drill2 box-hub; eq "P2 rc" "$?" 0
eq "P2 check GETs" "$(cat "$T/gets")" 3
eq "P2 sleeps" "$(slept 10)" 2
eq "P2 no alert" "$(alerts)" 0

# P3 (D3): the worker refuses 409 lease_live → rc 1, its words in the detail,
# no FD_T_BACK, no alert, no second promote.
reset; export PROMOTE_CODE=409 PROMOTE_BODY='{"error":"lease_live","holder":"box-small"}'
FD_T_BACK=stale
fd_promote_back drill3 box-hub; eq "P3 rc" "$?" 1
has "P3 detail lease_live" "${FD_DEMOTE_DETAIL:-}" lease_live
has "P3 detail http" "${FD_DEMOTE_DETAIL:-}" "http=409"
eq "P3 no FD_T_BACK" "${FD_T_BACK:-<unset>}" "<unset>"
eq "P3 one POST" "$(promotes)" 1
eq "P3 no alert" "$(alerts)" 0
eq "P3 no settle poll" "$(cnt '^sleep')" 0

# P3b: an unregistered holder is refused by hub-lease.sh (rc 2) → rc 1, its words.
reset
fd_promote_back drill3b nothere; eq "P3b rc" "$?" 1
has "P3b detail" "${FD_DEMOTE_DETAIL:-}" "not the registered hub"
eq "P3b nothing sent" "$(promotes)" 0

# P3c: no hub named → rc 1, nothing sent at all.
reset
fd_promote_back drill3c ""; eq "P3c rc" "$?" 1
eq "P3c detail" "${FD_DEMOTE_DETAIL:-}" "promote-back: no hub named"
eq "P3c no request" "$(cnt '^curl')" 0

# P4: the hub never holds the lease inside a 30 s settle window → rc 1, the
# exact detail, ONE ALERTS line, 3 polls / 2 sleeps, and no second promote.
reset; export HUB_LEASE_CACHE_S=0 NEVER_HELD=1 FAILOVER_DRILL_DEMOTE_SETTLE_S=30
fd_promote_back drill4 box-hub; eq "P4 rc" "$?" 1
eq "P4 detail" "${FD_DEMOTE_DETAIL:-}" "hub not holding the lease after promote-back"
eq "P4 FD_T_BACK still stamped" "${FD_T_BACK:-<unset>}" 1790000000
eq "P4 polls" "$(cat "$T/gets")" 3
eq "P4 sleeps" "$(slept 10)" 2
eq "P4 one alert" "$(alerts)" 1
has "P4 alert text" "$(cat "$H/logs/ALERTS.log")" "failover-drill: run drill4: hub box-hub not holding the lease 30s after promote-back"
eq "P4 one POST" "$(promotes)" 1

# P4b: a non-integer settle knob falls back to 180 s → 18 polls, 17 sleeps.
reset; export HUB_LEASE_CACHE_S=0 NEVER_HELD=1 FAILOVER_DRILL_DEMOTE_SETTLE_S=abc
fd_promote_back drill4b box-hub; eq "P4b rc" "$?" 1
eq "P4b polls" "$(cat "$T/gets")" 18
eq "P4b sleeps" "$(slept 10)" 17

# ===== fd_standby_quiet =======================================================
TB=1790000000; TB_ISO=$(fd_iso "$TB")
# Q1 (D1): nothing grows → OK, rc 0, sleep 600, only the observable logs read.
reset
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q1 rc" "$?" 0
eq "Q1 verdict" "${FD_DEMOTE_VERDICT:-}" OK
has "Q1 detail" "${FD_DEMOTE_DETAIL:-}" "3 hub lane logs unchanged on box-small for 600s after demotion at $TB_ISO"
hasnt "Q1 not a stub" "${FD_DEMOTE_DETAIL:-}" "not implemented"
eq "Q1 slept 600" "$(slept 600)" 1
eq "Q1 two size reads" "$(cnt '^ssh .*stat -c')" 2
reads=$(grep '^ssh .*stat -c' "$T/seq.log" | head -1)
has "Q1 reads merge-conductor" "$reads" /root/harness/logs/merge-conductor-cron.log
has "Q1 reads blocked-resolver" "$reads" /root/harness/logs/blocked-resolver-cron.log
has "Q1 reads the installer-gated lane" "$reads" /root/harness/logs/fresh-lane.log
hasnt "Q1 skips hub-lease.log" "$reads" hub-lease.log
hasnt "Q1 skips stream log" "$reads" standby-stream.log
hasnt "Q1 skips comment decoy" "$reads" decoy.log
eq "Q1 no alert" "$(alerts)" 0
eq "Q1 never promotes" "$(cnt '^curl')" 0

# Q2 (D2): merge-conductor's log grows between the reads → FAIL, rc 1, one alert.
reset; hook 2 "printf '%080d' 0 >> '$T/sb/logs/merge-conductor-cron.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q2 rc" "$?" 1
eq "Q2 verdict" "${FD_DEMOTE_VERDICT:-}" FAIL
eq "Q2 detail" "${FD_DEMOTE_DETAIL:-}" "hub lane /root/harness/logs/merge-conductor-cron.log ran on box-small after demotion"
eq "Q2 one alert" "$(alerts)" 1
has "Q2 alert names log" "$(cat "$H/logs/ALERTS.log")" "merge-conductor-cron.log"
has "Q2 alert names time" "$(cat "$H/logs/ALERTS.log")" "$TB_ISO"
eq "Q2 never promotes" "$(cnt '^curl')" 0

# Q3: the standby still holds the lease → FAIL, no size read at all.
reset; export STANDBY_CHECK_RC=0
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q3 rc" "$?" 1
eq "Q3 verdict" "${FD_DEMOTE_VERDICT:-}" FAIL
has "Q3 detail" "${FD_DEMOTE_DETAIL:-}" "box-small still holds the hub lease after demotion"
eq "Q3 no size read" "$(cnt 'stat -c')" 0
eq "Q3 one alert" "$(alerts)" 1

# Q4: /dev/null and no-redirect lanes are named unobservable, never read.
reset
fd_standby_quiet box-small 10.0.0.2 "$TB"
eq "Q4 unobservable" "${FD_DEMOTE_UNOBSERVABLE:-}" "hub-lease.sh harden-state.sh wake-loop.sh hub-lease-audit.sh"
has "Q4 detail lists them" "${FD_DEMOTE_DETAIL:-}" "unobservable: hub-lease.sh harden-state.sh wake-loop.sh hub-lease-audit.sh"
hasnt "Q4 harden-state not read" "$(grep 'stat -c' "$T/seq.log")" harden-state

# Q5: the standby check is rc 1 but a lane ran anyway → FAIL; Q5b a lane log
# absent on read 1 and present on read 2 is growth too.
reset; hook 2 "printf 'ran\n' >> '$T/sb/logs/blocked-resolver-cron.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q5 rc" "$?" 1
eq "Q5 verdict" "${FD_DEMOTE_VERDICT:-}" FAIL
has "Q5 detail" "${FD_DEMOTE_DETAIL:-}" "hub lane /root/harness/logs/blocked-resolver-cron.log ran on"
reset; rm -f "$T/sb/logs/merge-conductor-cron.log"
hook 2 "printf '%040d' 0 > '$T/sb/logs/merge-conductor-cron.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q5b rc" "$?" 1
eq "Q5b verdict" "${FD_DEMOTE_VERDICT:-}" FAIL
has "Q5b detail" "${FD_DEMOTE_DETAIL:-}" "merge-conductor-cron.log ran on"
# Q5c: two logs grow → the first is named, the rest counted, one alert.
reset; hook 2 "echo a >> '$T/sb/logs/merge-conductor-cron.log'; echo b >> '$T/sb/logs/blocked-resolver-cron.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q5c rc" "$?" 1
has "Q5c more" "${FD_DEMOTE_DETAIL:-}" "(+1 more: /root/harness/logs/blocked-resolver-cron.log)"
eq "Q5c one alert" "$(alerts)" 1

# Q6: ssh transport failure on the check → UNPROVEN, not FAIL, not OK.
reset; export STANDBY_CHECK_RC=255
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q6 rc" "$?" 1
eq "Q6 verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q6 detail" "${FD_DEMOTE_DETAIL:-}" "ssh to box-small failed (rc 255)"
# Q6b: the second size read fails → UNPROVEN; Q6c a path missing from a read.
reset; export SIZE_FAIL_AT=2
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q6b rc" "$?" 1
eq "Q6b verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q6b detail" "${FD_DEMOTE_DETAIL:-}" "size read failed on box-small"
reset; export SIZE_DROP_AT=1
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q6c rc" "$?" 1
eq "Q6c verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
# Q6d: an empty ip is fd_ssh rc 2 → UNPROVEN.
reset
fd_standby_quiet box-small "" "$TB"; eq "Q6d rc" "$?" 1
eq "Q6d verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN

# Q7: the cron file cannot be read, or is empty → UNPROVEN.
reset; export CRON_RC=1
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q7 rc" "$?" 1
eq "Q7 verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q7 detail" "${FD_DEMOTE_DETAIL:-}" "cannot read /etc/cron.d/harness-standby on box-small (rc 1)"
reset; : > "$T/empty.cron"; export CRON_FIXTURE="$T/empty.cron"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q7b rc" "$?" 1
eq "Q7b verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN

# Q8: no gated lines at all (only the stream line) → UNPROVEN, not an empty OK.
reset; grep 'standby-stream' "$T/cron.fixture" > "$T/stream-only.cron"; export CRON_FIXTURE="$T/stream-only.cron"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q8 rc" "$?" 1
eq "Q8 verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q8 detail" "${FD_DEMOTE_DETAIL:-}" "no observable hub lane logs in harness-standby"
# Q8b: gated lines that are all unobservable → UNPROVEN, and they are named.
reset; grep -v -e merge-conductor -e blocked-resolver -e fresh-lane "$T/cron.fixture" > "$T/devnull-only.cron"; export CRON_FIXTURE="$T/devnull-only.cron"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q8b rc" "$?" 1
eq "Q8b verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q8b named" "${FD_DEMOTE_UNOBSERVABLE:-}" harden-state.sh

# Q9: a non-integer observe knob falls back to 600; an integer one is used.
reset; export FAILOVER_DRILL_OBSERVE_S=abc
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q9 rc" "$?" 0
eq "Q9 slept 600" "$(slept 600)" 1
reset; export FAILOVER_DRILL_OBSERVE_S=5
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q9b rc" "$?" 0
eq "Q9b slept 5" "$(slept 5)" 1
has "Q9b detail" "${FD_DEMOTE_DETAIL:-}" "for 5s after demotion"

# Q10: only the excluded logs grow → still OK.
reset; hook 2 "echo more >> '$T/sb/logs/hub-lease.log'; echo more >> '$T/sb/logs/standby-stream.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q10 rc" "$?" 0
eq "Q10 verdict" "${FD_DEMOTE_VERDICT:-}" OK

# Q11: a shrunk log (rotated) is UNPROVEN, never OK.
reset; hook 2 ": > '$T/sb/logs/merge-conductor-cron.log'"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q11 rc" "$?" 1
eq "Q11 verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
has "Q11 detail" "${FD_DEMOTE_DETAIL:-}" "merge-conductor-cron.log shrank on box-small"

# Q12: no promote-back time → UNPROVEN, nothing asked of the standby.
reset
fd_standby_quiet box-small 10.0.0.2 ""; eq "Q12 rc" "$?" 1
eq "Q12 verdict" "${FD_DEMOTE_VERDICT:-}" UNPROVEN
eq "Q12 detail" "${FD_DEMOTE_DETAIL:-}" "no promote-back time"
eq "Q12 no ssh" "$(cnt '^ssh')" 0

# Q13: the REAL hub render (bin/render-crontab.sh hub, minus the standby's own
# lanes) through the REAL installer: quiet logs → OK, with every lane that logs
# nowhere named rather than counted clean.
reset
bash "$DIR/bin/render-crontab.sh" --root "$DIR" hub > "$T/real-hub.cron"; eq "Q13 render hub rc" "$?" 0
bash "$DIR/bin/render-crontab.sh" --root "$DIR" small > "$T/real-own.cron"; eq "Q13 render small rc" "$?" 0
render_standby "$T/real-hub.cron" "$T/real-own.cron" "$T/real.fixture"; eq "Q13 standby-install rc" "$?" 0
export CRON_FIXTURE="$T/real.fixture"
fd_standby_quiet box-small 10.0.0.2 "$TB"; eq "Q13 rc" "$?" 0
eq "Q13 verdict" "${FD_DEMOTE_VERDICT:-}" OK
[ -n "${FD_DEMOTE_UNOBSERVABLE:-}" ] && ok || bad "Q13: the real render has /dev/null lanes, none named"
hasnt "Q13 stream not read" "$(grep 'stat -c' "$T/seq.log")" standby-stream.log

echo "failover-drill-demote.bh-2748: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
