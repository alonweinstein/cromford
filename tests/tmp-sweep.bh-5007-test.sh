#!/bin/bash
# tests/tmp-sweep.bh-5007-test.sh — BH-5007: the /tmp sweep on every box, every
# 15 min since BH-5608 (that ticket's own cases: tests/tmp-sweep.bh-5608-test.sh).
#
# The shipped bin/tmp-sweep.sh is installed with its source closure into a
# scratch harness and DRIVEN against a fixture /tmp under $T, with real live
# processes holding entries through their cwd, an open fd and an argv argument
# (the real /proc), a PATH-first df that answers what the case says, and a
# lane-alert stub that records its argv. What is proved:
#   A1  the ticket's case: an old unowned dir and an old dir with an immutable
#       file are removed; an old dir a live process sits in and a fresh dir
#       are kept; the counts say so;
#   A2  an argv argument naming the dir holds it; A3 so does an open fd;
#   A4  one fresh file deep inside keeps an old tree;
#   A5  a name outside TMP_SWEEP_PATTERNS is never touched;
#   A6  a symlink is never followed or unlinked;
#   A7  one summary line per run with freed KB and the /tmp reading, and one
#       `removed <path> <kb> KB age_min=<n>` line per removed dir;
#   A8  MIN_AGE_MIN from the env and from a settings row moves the age line,
#       and abc / 0 skip the sweep; the registry default is 180 (BH-5608);
#   A9  /tmp over 85% raises tmp-high-<host> warn, 85% resolves it, an
#       unreadable df does neither, --dry-run calls lane-alert not at all;
#   A10 the off switch and a held lock stop the run;
#   A11 --dry-run deletes nothing and says what it would remove;
#   A12 the hand-made stopgap /etc/cron.d/tmp-sweep is retired only when it is
#       exactly the stopgap, never a symlink, never on a dry run;
#   A13 registry and cron wiring: every disk-guard box runs it every 15 min, and the
#       deletion scope is not settable from a page;
#   A14 a fixture /proc with broken cmdline entries: the run finishes and every
#       holder it names still holds. Every run is bounded by `timeout`.
# Run from anywhere: tests/tmp-sweep.bh-5007-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset MIN_AGE_MIN TMP_ALERT_PCT TMP_SWEEP_SCAN_TIMEOUT_S TMP_SWEEP_RUN_DEADLINE_S TMP_SWEEP_PATTERNS \
      TMP_SWEEP_ROOT TMP_SWEEP_PROC TMP_SWEEP_NOW TMP_SWEEP_STOPGAP_FILE 2>/dev/null || true
HOST=$(hostname)

# Every background holder dies before the scratch tree is removed, and the
# fixture's immutable files are cleared so a red run never leaks $T.
HOLDERS=()
# A holder's own children (the sleep a bash -c or flock forked) die first: an
# orphaned sleep keeps the fd, and flock's keeps the lock.
stop_holders() {
  local p
  for p in "${HOLDERS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  HOLDERS=()
}
__bh5007_exit() {
  local rc=$?
  stop_holders
  chattr -R -ia "$T" 2>/dev/null
  chmod -R u+w "$T" 2>/dev/null
  (exit "$rc"); __rendered_exit_trap
}
trap __bh5007_exit EXIT

# ── the scratch harness ──────────────────────────────────────────────────────
scratch_install_closure bin/tmp-sweep.sh "$T/h" >/dev/null || { echo "FAIL: cannot install bin/tmp-sweep.sh's closure"; exit 1; }
mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/catalog" "$T/h/env" "$T/fx/cron.d" "$T/outside"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
cat > "$T/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TS_ALERTS"
SH
chmod +x "$T/h/bin/lane-alert.sh"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
H='Filesystem     1024-blocks     Used Available Capacity Mounted on'
case "${FAKE_DF_PCT:-50}" in
  fail) exit 1 ;;
  *)    printf '%s\ntmpfs 8388608 7000000 1048576 %s%% /tmp\n' "$H" "${FAKE_DF_PCT:-50}" ;;
esac
SH
chmod +x "$T/fakebin/df"

# ── the immutable fixture: real chattr where it works, else a stub ───────────
probe="$T/probe"; : > "$probe"
if chattr +i "$probe" 2>/dev/null; then
  chattr -i "$probe"; IMM=real
else
  IMM=stub
  cat > "$T/fakebin/chattr" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TS_CHATTR"
for last; do :; done
chmod -R u+w -- "$last" 2>/dev/null
exit 0
SH
  chmod +x "$T/fakebin/chattr"
fi
rm -f "$probe"
echo "tmp-sweep.bh-5007: immutable fixture variant: $IMM"
FPATH="$T/fakebin:$PATH"

NOW=1790000000
OLD=$((NOW - 7 * 3600))
FX="$T/fx/tmp"
STOPGAP="$T/fx/cron.d/tmp-sweep"
LOG="$T/h/logs/tmp-sweep.log"
export TS_ALERTS="$T/alerts.log" TS_CHATTR="$T/chattr.log"

age() { find "$1" -exec touch -h -d "@$2" {} + 2>/dev/null; }
reset_fx() {
  stop_holders
  chattr -R -ia "$T/fx" 2>/dev/null; chmod -R u+w "$T/fx" 2>/dev/null
  scratch_rm "$FX"; mkdir -p "$FX"
  rm -f "$LOG" "$TS_ALERTS" "$TS_CHATTR"
}
mkold() { # mkold <name> — a dir with a 64 KB file, every mtime 7 h ago
  mkdir -p "$FX/$1/d"
  head -c 65536 /dev/zero > "$FX/$1/d/blob"
  age "$FX/$1" "$OLD"
}
immutable() { # immutable <name> — an old dir rm -rf cannot finish without chattr
  mkdir -p "$FX/$1/sub"; echo x > "$FX/$1/sub/f"
  age "$FX/$1" "$OLD"
  if [ "$IMM" = real ]; then chattr +i "$FX/$1/sub/f"; else chmod 0555 "$FX/$1/sub"; fi
}
holder() { # holder <cmd...> — start a live process, wait until /proc shows it
  local p _
  "$@" & p=$!; HOLDERS+=("$p")
  # every holder ends in a sleep: it is in place once that sleep runs, either
  # as the holder itself (exec) or as its child (after the cd / argv / fd)
  for _ in $(seq 1 200); do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = sleep ] && break
    pgrep -P "$p" >/dev/null 2>&1 && break
    sleep 0.05
  done
}
# run [VAR=val ...] [-- args] — drive the shipped script
run() {
  local -a envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  # bounded: a sweep that hangs (BH-5007's first held_set spun on a cmdline
  # read error) is a red case here, never a suite that never ends
  local rc
  timeout 120 env PATH="$FPATH" HARNESS_ROOT="$T/h" HARNESS="$T/h" HOME="$T" \
      TMP_SWEEP_ROOT="$FX" TMP_SWEEP_NOW="$NOW" TMP_SWEEP_STOPGAP_FILE="$STOPGAP" \
      "${envs[@]}" bash "$T/h/bin/tmp-sweep.sh" "${args[@]}"
  rc=$?
  [ "$rc" = 124 ] && bad "a run of bin/tmp-sweep.sh did not finish in 120 s (${envs[*]} ${args[*]})" >&2
  return "$rc"
}
summary() { grep -E ' tmp-sweep(: dry-run)? removed=' "$LOG" 2>/dev/null; }
field() { summary | tail -1 | grep -oE "(^| )$1=[^ ]*" | cut -d= -f2; }

# ══ A1 the ticket's acceptance test ══════════════════════════════════════════
reset_fx
mkold scratch.AAAAAA
mkold bh1-proto
mkdir -p "$FX/impact-gate.BBBBBB"; echo y > "$FX/impact-gate.BBBBBB/f"; age "$FX/impact-gate.BBBBBB" $((NOW - 600))
immutable rules-pack.CCCCCC
holder bash -c 'cd "$0" && exec sleep 120' "$FX/bh1-proto"   # determinism: ok race-sleep the sleep is the background holder's lifetime; holder() polls /proc for readiness
# the holder's argv names the dir too; the cwd case must stand alone, so the
# argv-only and fd-only holders are A2 and A3
holder2_pid=${HOLDERS[-1]}
run FAKE_DF_PCT=40 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A1 rc must be 0 (got $RC)"
[ ! -e "$FX/scratch.AAAAAA" ] && ok || bad "A1 the old unowned scratch.AAAAAA must be removed"
[ ! -e "$FX/rules-pack.CCCCCC" ] && ok || bad "A1 the old rules-pack.CCCCCC with an immutable file must be removed ($IMM chattr)"
[ -d "$FX/bh1-proto" ] && ok || bad "A1 bh1-proto, a live process's cwd, must be kept"
[ -d "$FX/impact-gate.BBBBBB" ] && ok || bad "A1 the 10-minute-old impact-gate.BBBBBB must be kept"
for kv in removed=2 skipped_held=1 skipped_fresh=1 unlocked=1 failed=0 skipped_unreadable=0 left=0; do
  [ "$(field "${kv%%=*}")" = "${kv#*=}" ] && ok || bad "A1 summary must carry $kv ($(summary))"
done
if [ "$IMM" = stub ]; then
  grep -q -- '^-R -ia -- ' "$TS_CHATTR" 2>/dev/null && ok || bad "A1 the chattr stub must be called with -R -ia ($(cat "$TS_CHATTR" 2>/dev/null))"
fi
[ "$(readlink "/proc/$holder2_pid/cwd" 2>/dev/null)" = "$FX/bh1-proto" ] && ok \
  || bad "A1 fixture: the holder's cwd must really be bh1-proto"

# ══ A7 the summary line (from A1's run) ══════════════════════════════════════
[ "$(summary | wc -l)" = 1 ] && ok || bad "A7 exactly one summary line per run (got $(summary | wc -l))"
fk=$(field freed_kb)
[ -n "$fk" ] && [ "$fk" -gt 0 ] && ok || bad "A7 freed_kb must be > 0 after removing two dirs (got '$fk')"
[ "$(field min_age_min)" = 180 ] && ok || bad "A7 min_age_min=180 (default) in the summary ($(summary))"
[ "$(field tmp_use)" = 40% ] && ok || bad "A7 tmp_use must be the df reading 40% ($(summary))"
[ "$(field tmp_avail_mb)" = 1024 ] && ok || bad "A7 tmp_avail_mb must be df's Available in MB, 1024 ($(summary))"
[ "$(grep -cE " removed $FX/[^ ]+ [0-9]+ KB age_min=[0-9]+$" "$LOG")" = 2 ] && ok \
  || bad "A7 one 'removed <path> <kb> KB age_min=<n>' line per removed dir ($(grep ' removed /' "$LOG"))"
grep -q " removed $FX/scratch.AAAAAA [0-9]* KB" "$LOG" && ok || bad "A7 the removed line names scratch.AAAAAA"

# ══ A2 argv-held, A3 fd-held, A4 fresh inside, A5 pattern scope, A6 symlink ═
reset_fx
mkold pb1-proto
mkold pb2-sg
mkold bh2-rp; touch -d "@$((NOW - 300))" "$FX/bh2-rp/d/blob"
mkold keepme-old
mkold mysql.sock.d
mkdir -p "$T/outside/inner"; echo z > "$T/outside/inner/f"; age "$T/outside" "$OLD"
ln -s "$T/outside" "$FX/scratch.LLLLLL"; touch -h -d "@$OLD" "$FX/scratch.LLLLLL"
holder bash -c 'sleep 120; :' holder "$FX/pb1-proto/x"   # determinism: ok race-sleep the sleep is the background holder's lifetime; holder() polls /proc for readiness
holder env F="$FX/pb2-sg/d/blob" bash -c 'exec 7<"$F"; sleep 120; :'   # determinism: ok race-sleep the sleep is the background holder's lifetime; holder() polls /proc for readiness
run FAKE_DF_PCT=40 >/dev/null 2>&1
[ -d "$FX/pb1-proto" ] && ok || bad "A2 pb1-proto, named in a live process's argv, must be kept"
[ -d "$FX/pb2-sg" ] && ok || bad "A3 pb2-sg, an open fd of a live process, must be kept"
[ "$(field skipped_held)" = 2 ] && ok || bad "A2/A3 skipped_held=2 ($(summary))"
[ -d "$FX/bh2-rp" ] && ok || bad "A4 bh2-rp, old at the top but one file 5 min old, must be kept"
[ "$(field skipped_fresh)" = 1 ] && ok || bad "A4 skipped_fresh=1 ($(summary))"
[ -d "$FX/keepme-old" ] && [ -d "$FX/mysql.sock.d" ] && ok || bad "A5 names outside TMP_SWEEP_PATTERNS must be untouched"
[ -L "$FX/scratch.LLLLLL" ] && [ -f "$T/outside/inner/f" ] && ok || bad "A6 a scratch.* symlink and its target must both survive"
[ "$(field removed)" = 0 ] && ok || bad "A2-A6 nothing in this fixture is removable ($(summary))"
stop_holders
# with the holders gone, the same two dirs go: the holders were the only reason
run FAKE_DF_PCT=40 >/dev/null 2>&1
[ ! -e "$FX/pb1-proto" ] && [ ! -e "$FX/pb2-sg" ] && ok || bad "A2/A3 once the holders exit, pb1-proto and pb2-sg are removed"

# ══ A8 the age knob ══════════════════════════════════════════════════════════
reset_fx; mkold scratch.AAAAAA
run FAKE_DF_PCT=40 MIN_AGE_MIN=600 >/dev/null 2>&1
[ -d "$FX/scratch.AAAAAA" ] && [ "$(field min_age_min)" = 600 ] && ok \
  || bad "A8 MIN_AGE_MIN=600 keeps a 7 h dir ($(summary))"
for junk in abc 0 29; do
  rm -f "$LOG"
  run FAKE_DF_PCT=40 MIN_AGE_MIN=$junk >/dev/null 2>&1
  [ -d "$FX/scratch.AAAAAA" ] && grep -q "MIN_AGE_MIN invalid ($junk) - sweep skipped" "$LOG" && [ -z "$(summary)" ] && ok \
    || bad "A8 MIN_AGE_MIN=$junk skips the sweep with a log line ($(cat "$LOG" 2>/dev/null))"
done
[ "$(jq -r '.knobs[]|select(.env=="MIN_AGE_MIN").default' "$DIR/catalog/lanes.d/tmp-sweep.json")" = 180 ] && ok \
  || bad "A8 the registry default of MIN_AGE_MIN must be 180 (BH-5608)"
knob() { env HARNESS="$T/h" LANE_GATE_NOW="$NOW" bash -c '. "$HARNESS/bin/lib/lane-gate.sh"; lane_knob tmp-sweep "$0"' "$1" 2>/dev/null; }
[ "$(knob MIN_AGE_MIN)" = 180 ] && ok || bad "A8 lane_knob answers the registry default 180 (got '$(knob MIN_AGE_MIN)')"
printf '{"fetched_at":%s,"values":{"lane.tmp-sweep.min_age_min":"600"},"seeded":{}}' "$NOW" > "$T/h/state/settings-cache.json"
[ "$(knob MIN_AGE_MIN)" = 600 ] && ok || bad "A8 a settings row lane.tmp-sweep.min_age_min=600 resolves (got '$(knob MIN_AGE_MIN)')"
rm -f "$LOG"
run FAKE_DF_PCT=40 LANE_GATE_NOW="$NOW" >/dev/null 2>&1
[ -d "$FX/scratch.AAAAAA" ] && [ "$(field min_age_min)" = 600 ] && ok \
  || bad "A8 the settings row reaches the shipped lane: 7 h dir kept at 600 ($(summary))"
rm -f "$T/h/state/settings-cache.json"

# ══ A9 the /tmp warn ═════════════════════════════════════════════════════════
reset_fx
run FAKE_DF_PCT=86 >/dev/null 2>&1
grep -q "^--id tmp-high-$HOST --severity warn tmp-sweep /tmp on $HOST at 86% after the sweep (1024 MB free, warn over 85%)" "$TS_ALERTS" 2>/dev/null \
  && ok || bad "A9 86% raises tmp-high-$HOST warn naming the reading ($(cat "$TS_ALERTS" 2>/dev/null))"
grep -q -- '--critical\|--severity critical' "$TS_ALERTS" 2>/dev/null && bad "A9 the /tmp alert is a warn, never a page" || ok
grep -q -- '—' "$TS_ALERTS" 2>/dev/null && bad "A9 the alert text carries no em dash" || ok
rm -f "$TS_ALERTS"
run FAKE_DF_PCT=85 >/dev/null 2>&1
[ "$(grep -c -- '--severity' "$TS_ALERTS" 2>/dev/null)" = 0 ] && [ "$(grep -c "^--resolve --id tmp-high-$HOST tmp-sweep " "$TS_ALERTS" 2>/dev/null)" = 1 ] \
  && ok || bad "A9 85% is not over 85%: no warn, one resolve ($(cat "$TS_ALERTS" 2>/dev/null))"
rm -f "$TS_ALERTS"
run FAKE_DF_PCT=fail >/dev/null 2>&1
[ ! -s "$TS_ALERTS" ] && ok || bad "A9 an unreadable df raises and resolves nothing ($(cat "$TS_ALERTS"))"
[ "$(field tmp_use)" = unknown% ] && ok || bad "A9 an unreadable df reads tmp_use=unknown% ($(summary))"
rm -f "$TS_ALERTS"
run FAKE_DF_PCT=97 -- --dry-run >/dev/null 2>&1
[ ! -e "$TS_ALERTS" ] && ok || bad "A9 --dry-run calls lane-alert not at all ($(cat "$TS_ALERTS"))"
rm -f "$TS_ALERTS"
run FAKE_DF_PCT=90 TMP_ALERT_PCT=95 >/dev/null 2>&1
grep -q -- '--severity' "$TS_ALERTS" 2>/dev/null && bad "A9 TMP_ALERT_PCT=95 moves the line: 90% does not warn" || ok

# ══ A10 the off switch and the lock ══════════════════════════════════════════
reset_fx; mkold scratch.AAAAAA
: > "$T/h/flags/lane-off-tmp-sweep"
run FAKE_DF_PCT=97 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ -d "$FX/scratch.AAAAAA" ] && [ -z "$(summary)" ] && [ ! -e "$TS_ALERTS" ] && ok \
  || bad "A10 flags/lane-off-tmp-sweep: rc 0, nothing removed, no summary, no alert (rc=$RC)"
rm -f "$T/h/flags/lane-off-tmp-sweep"
mkdir -p "$T/h/locks"
holder flock "$T/h/locks/tmp-sweep.lock" sleep 120
run FAKE_DF_PCT=40 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ -d "$FX/scratch.AAAAAA" ] && [ -z "$(summary)" ] && ok \
  || bad "A10 a held lock: rc 0 and nothing removed (rc=$RC, $(summary))"
stop_holders

# ══ A11 dry run ══════════════════════════════════════════════════════════════
reset_fx; mkold scratch.AAAAAA
printf '23 * * * * root /root/bhfix-lane/tmp-sweep.sh 360\n' > "$STOPGAP"
out=$(run FAKE_DF_PCT=40 -- --dry-run 2>&1)
[[ $out == *"would remove $FX/scratch.AAAAAA ("*" KB)"* ]] && ok || bad "A11 --dry-run prints would remove scratch.AAAAAA ('$out')"
[ -d "$FX/scratch.AAAAAA" ] && ok || bad "A11 --dry-run deletes nothing"
summary | grep -q ' tmp-sweep: dry-run removed=0 .*would_remove=1 ' && ok || bad "A11 the dry-run summary shows would_remove=1 ($(summary))"
[ -f "$STOPGAP" ] && ok || bad "A12 a dry run never retires the stopgap"
out=$(run -- --bogus 2>&1); RC=$?
[ "$RC" = 2 ] && [[ $out == usage:* ]] && ok || bad "A11 an unknown argument is a usage line and rc 2 (rc=$RC '$out')"

# ══ A12 stopgap retirement ═══════════════════════════════════════════════════
reset_fx
printf '# BH-5007 stopgap until the repo lane lands\n23 * * * * root /root/bhfix-lane/tmp-sweep.sh 360\n' > "$STOPGAP"
run FAKE_DF_PCT=40 MIN_AGE_MIN=abc >/dev/null 2>&1
[ -f "$STOPGAP" ] && ok || bad "A12 a run whose sweep was skipped never retires the stopgap"
run FAKE_DF_PCT=40 >/dev/null 2>&1
[ ! -e "$STOPGAP" ] && grep -q "retired stopgap $STOPGAP (repo lane tmp-sweep now owns this)" "$LOG" && ok \
  || bad "A12 the exact stopgap is retired with a log line ($(cat "$LOG"))"
rm -f "$LOG"
printf '23 * * * * root /usr/local/bin/something-else.sh\n' > "$STOPGAP"
run FAKE_DF_PCT=40 >/dev/null 2>&1; run FAKE_DF_PCT=40 >/dev/null 2>&1
[ -f "$STOPGAP" ] && [ "$(grep -c "stopgap $STOPGAP not retired: content is not the BH-5007 stopgap" "$LOG")" = 1 ] && ok \
  || bad "A12 other content is kept and logged once across two runs ($(grep stopgap "$LOG"))"
printf '23 * * * * root /root/bhfix-lane/tmp-sweep.sh 360\n5 * * * * root /root/bhfix-lane/other.sh\n' > "$STOPGAP"
run FAKE_DF_PCT=40 >/dev/null 2>&1
[ -f "$STOPGAP" ] && ok || bad "A12 a file with the stopgap line AND another line is kept"
rm -f "$STOPGAP" "$LOG" "$T/h/state/tmp-sweep/stopgap-mismatch-logged"
run FAKE_DF_PCT=40 >/dev/null 2>&1
grep -q 'stopgap' "$LOG" && bad "A12 an absent stopgap writes no line ($(grep stopgap "$LOG"))" || ok
printf '23 * * * * root /root/bhfix-lane/tmp-sweep.sh 360\n' > "$T/fx/real-stopgap"
ln -s "$T/fx/real-stopgap" "$STOPGAP"
run FAKE_DF_PCT=40 >/dev/null 2>&1
[ -L "$STOPGAP" ] && [ -f "$T/fx/real-stopgap" ] && ok || bad "A12 a symlinked stopgap is never removed, nor its target"
rm -f "$STOPGAP"

# ══ A14 a /proc that answers badly ═══════════════════════════════════════════
# TMP_SWEEP_PROC at a fixture: a cmdline that is a directory, one that is EIO
# (/proc/self/mem), one with no trailing NUL that names the dir inside
# --dir=..., a cwd link, an fd link to a deleted file. The run finishes, every
# real holder still holds, and a longer name does not hold a shorter one.
reset_fx
for n in pb1-proto pb2-sg bh3-proto bh4-rp scratch.ZZZZZZ scratch.ABCDEF; do mkold "$n"; done
FP="$T/fakeproc"; chmod -R u+w "$FP" 2>/dev/null; scratch_rm "$FP"
mkdir -p "$FP/101" "$FP/102/cmdline" "$FP/103" "$FP/104" "$FP/105" "$FP/106/fd"
printf 'holder\0%s\0' "$FX/pb1-proto/x" > "$FP/101/cmdline"
ln -s /proc/self/mem "$FP/103/cmdline"
printf 'tool\0--dir=%s' "$FX/pb2-sg" > "$FP/104/cmdline"
printf 'x\0%s\0' "$FX/scratch.ABCDEFG/y" > "$FP/105/cmdline"
ln -s "$FX/bh3-proto/sub" "$FP/105/cwd"
ln -s "$FX/bh4-rp/d/gone (deleted)" "$FP/106/fd/3"
run FAKE_DF_PCT=40 TMP_SWEEP_PROC="$FP" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A14 rc must be 0 against a /proc that answers badly (rc=$RC)"
for n in pb1-proto pb2-sg bh3-proto bh4-rp; do
  [ -d "$FX/$n" ] && ok || bad "A14 $n is held by the fixture /proc and must be kept"
done
[ ! -e "$FX/scratch.ZZZZZZ" ] && ok || bad "A14 the unheld scratch.ZZZZZZ is removed"
[ ! -e "$FX/scratch.ABCDEF" ] && ok || bad "A14 an argv naming scratch.ABCDEFG does not hold scratch.ABCDEF"
[ "$(field skipped_held)" = 4 ] && [ "$(field removed)" = 2 ] && ok || bad "A14 skipped_held=4 removed=2 ($(summary))"

# ══ A13 registry and cron wiring ═════════════════════════════════════════════
J="$DIR/catalog/lanes.d/tmp-sweep.json"
# TEST-CHANGE (BH-5747): the box list is fleet.conf's boxes plus hub, read from
# the registry rather than pinned, so a registered box needs no edit here.
FLEET_BOXES=$( { FLEET_CONF="$DIR/fleet.conf" "$DIR/bin/fleet-conf.sh" --box-ids; echo hub; } | sort -u | jq -R . | jq -cs .)
[ "$FLEET_BOXES" != '["hub"]' ] && jq -e --argjson want "$FLEET_BOXES" '(.boxes|sort) == $want' "$J" >/dev/null \
  && ok || bad "A13 tmp-sweep runs on every fleet.conf box and the hub: $(jq -c .boxes "$J") vs $FLEET_BOXES"
jq -e '.knobs[]|select(.env=="TMP_SWEEP_PATTERNS").settable==false' "$J" >/dev/null \
  && ok || bad "A13 TMP_SWEEP_PATTERNS, the deletion scope, is not settable from a page"
jq -e '[.knobs[]|select(.env=="TMP_SWEEP_ROOT" or .env=="TMP_SWEEP_PROC" or .env=="TMP_SWEEP_NOW" or .env=="TMP_SWEEP_STOPGAP_FILE")|.settable]==[false,false,false,false]' "$J" >/dev/null \
  && ok || bad "A13 the four test seams are not settable from a page"
grep -qxF '8,23,38,53 * * * * /root/harness/bin/tmp-sweep.sh >/dev/null 2>&1' "$DIR/cron/lanes/647-tmp-sweep.cron" \
  && ok || bad "A13 cron/lanes/647-tmp-sweep.cron carries the every-15-min line"
for b in small hub; do
  grep -qF '8,23,38,53 * * * * /root/harness/bin/tmp-sweep.sh' "$(rendered_cron "$b")" \
    && ok || bad "A13 the rendered crontab of $b runs bin/tmp-sweep.sh every 15 min"
done

echo "tmp-sweep.bh-5007: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
