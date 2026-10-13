#!/bin/bash
# tests/disk-clean-hygiene-test.sh — bin/disk-clean.sh's four state-hygiene
# stages (BH-1044) against a scratch harness root and a frozen clock. Nothing
# here touches a real box: every path is under $T, the repo/npm/proc seams point
# at empty fixture dirs, and the production entry point is the script itself.
#
# WHY IT EXISTS (#1044, audit of 2026-09-19). The hub carried a 45 MB
# state/closeout-aged-out.tsv that pipeline-health greps every 10 minutes and
# nothing ever pruned, 3,153 stale flock files in locks/, ~40 operator one-off
# scripts and .bak copies loose in state/, and a state/leases/ directory no
# reader references. All four ride into every restore. disk-clean.sh already
# runs daily on every box, so the four bounds live there.
#
# What is proved here:
#   P0      an empty fixture is one summary line and nothing else — no archive,
#           no scratch dir, no ALERTS line;
#   P1/P2   an 11 MB tsv of 90k rows keeps every row younger than
#           CLOSEOUT_TSV_KEEP_DAYS plus every row with no parseable launch
#           stamp, archives the rest AND the duplicate dir row, and conserves
#           every byte between the two files;
#   P3      a 90-day knob archives nothing and does not even re-write the file
#           (the inode is the proof);
#   P4      the writer's lock held elsewhere is a skip, not a rewrite;
#   P5      a non-numeric knob says so out loud and falls back to 30;
#   P6      a second run archives nothing and leaves the inode alone;
#   P7      a row past the cutoff whose build dir is STILL on the box is kept —
#           pipeline-health re-records it on its next tick, so archiving it by
#           age would move the growth into state/archive/ instead of ending it;
#           only a row whose dir is gone is archived;
#   L1-L4   100 stale locks go; a lock held by flock stays; a lock merely open
#           in /proc stays; a lock whose holder is invisible in /proc still
#           stays (flock -n is the last probe); a fresh lock stays; a directory
#           under locks/ is never a candidate;
#   S1-S5   the three operator-scratch shapes move with their content; a *.sh
#           the crontab names stays; a *.sh a bin/ script reads by name stays;
#           lane state (box-id, quota/, blocked-resolver/, backup-last.json)
#           never moves; a name collision under state/scratch/ leaves the
#           original in place and says so;
#   D1-D3   state/leases/ goes once nothing in it is recent, stays when
#           something is, and state/quota/leases/ is never touched;
#   M1      the summary line's counters are the work that really happened.
# Run from anywhere: tests/disk-clean-hygiene-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1789514400            # 2026-09-15T23:20:00Z — every fixture age derives from this
ARCHDAY=20260915          # the archive file this run must append to
S60=$(date -u -d "@$((NOW - 60 * 86400))" +%Y%m%d%H%M)   # older than the 30d default
S29=$(date -u -d "@$((NOW - 29 * 86400))" +%Y%m%d%H%M)   # younger than it
SEEDALERT='2026-09-15T00:00:00Z [some-other-lane] a line this suite must never disturb'
DISKPCT=$(df --output=pcent / | tail -1 | tr -dc 0-9)

TSV="" ; ARCH=""
mkdir -p "$T/fakebin" "$T/noproc" "$T/nonpm" "$T/norepos"

# crontab: whatever the case put in $T/crontab.txt, and "no crontab" otherwise.
cat > "$T/fakebin/crontab" <<SH
#!/bin/bash
[ -f "$T/crontab.txt" ] || exit 1
cat "$T/crontab.txt"
SH
chmod +x "$T/fakebin/crontab"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/pgrep"; chmod +x "$T/fakebin/pgrep"
# npm and git must never be reached with these seams; if they are, the case says so.
for c in npm git; do
  cat > "$T/fakebin/$c" <<SH
#!/bin/bash
printf '%s %s\n' "$c" "\$*" >> "$T/calls.log"
exit 1
SH
  chmod +x "$T/fakebin/$c"
done

mkfix() {
  rm -rf "$T/h"
  rm -f "$T/crontab.txt" "$T/calls.log"
  mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/flags"
  cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/env-path.sh"
  : > "$T/h/env/global.env"
  printf 'small\n' > "$T/h/state/box-id"
  printf '%s\n' "$SEEDALERT" > "$T/h/logs/ALERTS.log"
  TSV="$T/h/state/closeout-aged-out.tsv"
  ARCH="$T/h/state/archive/closeout-aged-out.$ARCHDAY.tsv"
}

# The production entry point, driven exactly as cron drives it.
run() { # run [VAR=VAL ...]
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" ETC_HARNESS_ENV="$T/no-such-etc" \
      DISK_CLEAN_REPOS="$T/norepos" DISK_CLEAN_NPM_DIR="$T/nonpm" \
      DISK_CLEAN_NOW="$NOW" \
      "$@" bash "$DIR/bin/disk-clean.sh" > "$T/run.out" 2>&1
}
LOG="$T/h/logs/disk-clean.log"
ALOG="$T/h/logs/ALERTS.log"
summary() { grep 'disk-clean: ' "$LOG" 2>/dev/null | tail -1; }
inode()   { stat -c %i "$1" 2>/dev/null; }
lines()   { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# 90k rows: 60% launched 60 days ago, 40% 29 days ago, one hand-written row with
# no launch stamp in its dir, and one exact duplicate of a 29-day row (the lib's
# contract says the file is a set keyed on that dir).
mktsv() {
  awk -v s60="$S60" -v s29="$S29" 'BEGIN {
    for (i = 1; i <= 90000; i++) {
      s = (i % 5 < 3) ? s60 : s29
      printf "proj%d\t/root/harness/builds/proj-BH-%d-%s\tPR_CREATED https://github.com/x/y/pull/%d\taged out after 168h\n", i, i, s, i
    }
    printf "handproj\t/root/harness/builds/hand-row\tEMPTY-URL no pr\thand written, no stamp\n"
  }' > "$TSV"
  grep -m1 -F "proj-BH-4-$S29" "$TSV" >> "$TSV"
}

# ── P0: an empty box ────────────────────────────────────────────────────────
mkfix
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P0: an empty fixture exited $RC ($(tail -3 "$T/run.out"))"
[ "$(grep -c 'disk-clean: ' "$LOG" 2>/dev/null)" -eq 1 ] \
  && ok || bad "P0: expected one summary line, log is: $(cat "$LOG" 2>/dev/null)"
summary | grep -q 'tsv_kept=0 tsv_archived=0 tsv_kept_live=0 locks_removed=0 locks_skipped_held=0 scratch_moved=0 scratch_skipped=0 leases=none' \
  && ok || bad "P0: the summary line on an empty box is: $(summary)"
[ ! -d "$T/h/state/archive" ] && ok || bad "P0: it created state/archive with nothing to archive"
[ ! -e "$T/h/state/scratch" ] && ok || bad "P0: it created state/scratch with nothing to move"
if [ "${DISKPCT:-0}" -le 90 ]; then
  [ "$(cat "$ALOG")" = "$SEEDALERT" ] && ok || bad "P0: a clean run wrote to ALERTS.log: $(cat "$ALOG")"
else
  ok   # this box is over the disk line; the pre-existing disk alert is not this ticket's
fi
[ ! -s "$T/calls.log" ] && ok || bad "P0: it called npm/git with empty seams: $(cat "$T/calls.log")"

# ── P1/P2: the 11 MB tsv ────────────────────────────────────────────────────
mkfix
mktsv
cp "$TSV" "$T/tsv-fixture"
FIXBYTES=$(stat -c%s "$TSV")
[ "$FIXBYTES" -ge 10485760 ] && ok || bad "P1: the fixture tsv is $FIXBYTES bytes, the ticket's fixture is 10 MB+"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P1: the prune run exited $RC ($(tail -3 "$T/run.out"))"
[ "$(lines "$TSV")" -eq 36001 ] \
  && ok || bad "P1: the tsv kept $(lines "$TSV") rows, want 36001 (36000 young + the unstamped row)"
grep -qF "$S60" "$TSV" \
  && bad "P1: a row launched 60 days ago survived the 30-day prune" || ok
grep -qF '/root/harness/builds/hand-row' "$TSV" \
  && ok || bad "P1: the row whose dir carries no launch stamp was archived by age"
[ "$(cut -f2 "$TSV" | sort -u | wc -l)" -eq 36001 ] \
  && ok || bad "P1: the tsv is no longer a set keyed on the build dir"
[ -f "$ARCH" ] && ok || bad "P2: no archive at state/archive/closeout-aged-out.$ARCHDAY.tsv"
[ "$(lines "$ARCH")" -eq 54001 ] \
  && ok || bad "P2: the archive holds $(lines "$ARCH") rows, want 54001 (54000 aged + the duplicate)"
sort "$T/tsv-fixture" > "$T/want.sorted"
cat "$TSV" "$ARCH" | sort > "$T/got.sorted"
cmp -s "$T/want.sorted" "$T/got.sorted" \
  && ok || bad "P2: tsv + archive is not row-for-row the fixture ($(cmp "$T/want.sorted" "$T/got.sorted" 2>&1 | head -1))"
[ "$(( $(stat -c%s "$TSV") + $(stat -c%s "$ARCH") ))" -eq "$FIXBYTES" ] \
  && ok || bad "P2: bytes were not conserved: tsv+archive $(( $(stat -c%s "$TSV") + $(stat -c%s "$ARCH") )) vs fixture $FIXBYTES"
summary | grep -q 'tsv_kept=36001 tsv_archived=54001 tsv_kept_live=0' \
  && ok || bad "P2: the summary counters are: $(summary)"

# ── P6: a second run has nothing left to archive ────────────────────────────
INO=$(inode "$TSV")
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P6: the second run exited $RC"
summary | grep -q 'tsv_kept=36001 tsv_archived=0 tsv_kept_live=0' \
  && ok || bad "P6: the second run's counters are: $(summary)"
[ "$(inode "$TSV")" = "$INO" ] \
  && ok || bad "P6: a run with nothing to archive re-wrote the file anyway"
[ "$(lines "$ARCH")" -eq 54001 ] \
  && ok || bad "P6: the second run appended to the archive again ($(lines "$ARCH") rows)"

# ── P7: a row past the cutoff whose build dir is STILL ON THE BOX ───────────
# bin/pipeline-health.sh re-records an aged dir on its next tick for as long as
# that dir exists with a RESULT and no COMMENTED, and nothing in this harness
# deletes build dirs. Archiving such a row by age alone would hand the row
# straight back to the tsv and grow state/archive/ by the same dirs every day —
# relocating the growth the ticket exists to stop. The dir is the gate: a row is
# archived when its dir is gone and nobody can record it again.
mkfix
mkdir -p "$T/h/builds/p-BH-live-$S60" "$T/h/builds/pool-p-BH-poollive-$S60"
{
  printf 'p\tp-BH-live-%s\tPR_CREATED u1\taged out\n' "$S60"
  printf 'p\tpool-p-BH-poollive-%s\tPR_CREATED u2\taged out\n' "$S60"
  printf 'p\tp-BH-gone-%s\tPR_CREATED u3\taged out\n' "$S60"
  printf 'p\tp-BH-young-%s\tPR_CREATED u4\taged out\n' "$S29"
} > "$TSV"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P7: exited $RC ($(tail -3 "$T/run.out"))"
grep -qF "p-BH-live-$S60" "$TSV" \
  && ok || bad "P7: a 60-day row whose build dir still exists was archived; pipeline-health re-records it in 10 minutes"
grep -qF "pool-p-BH-poollive-$S60" "$TSV" \
  && ok || bad "P7: a pool build dir that still exists did not protect its row"
grep -qF "p-BH-gone-$S60" "$TSV" \
  && bad "P7: a 60-day row whose build dir is gone survived the prune" || ok
grep -qF "p-BH-gone-$S60" "$ARCH" \
  && ok || bad "P7: the row whose dir is gone is not in the archive"
[ "$(lines "$ARCH")" -eq 1 ] \
  && ok || bad "P7: the archive took $(lines "$ARCH") rows, want 1 (only the dir that no longer exists)"
summary | grep -q 'tsv_kept=3 tsv_archived=1 tsv_kept_live=2' \
  && ok || bad "P7: the counters are: $(summary)"
grep -q 'tsv: 2 row(s) past the 30d cutoff kept' "$LOG" 2>/dev/null \
  && ok || bad "P7: the rows kept for a live build dir are not named in the log: $(cat "$LOG" 2>/dev/null)"

# ── P3: the knob, read from env/global.env where operators set it ───────────
mkfix
mktsv
head -n -1 "$TSV" > "$T/nodup" && mv "$T/nodup" "$TSV"   # the duplicate is dropped at any age
INO=$(inode "$TSV")
printf 'CLOSEOUT_TSV_KEEP_DAYS=90\n' > "$T/h/env/global.env"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P3: exited $RC"
[ "$(lines "$TSV")" -eq 90001 ] \
  && ok || bad "P3: a 90-day window archived by age anyway ($(lines "$TSV") rows left)"
[ ! -f "$ARCH" ] && ok || bad "P3: it wrote an archive with nothing older than 90 days"
[ "$(inode "$TSV")" = "$INO" ] && ok || bad "P3: it re-wrote a file it had nothing to drop from"
summary | grep -q 'tsv_kept=90001 tsv_archived=0 tsv_kept_live=0' \
  && ok || bad "P3: the counters claim work that did not happen: $(summary)"

# ── P4: the writer's lock is held elsewhere ─────────────────────────────────
mkfix
mktsv
cp "$TSV" "$T/tsv-before"
exec 8>"$T/h/locks/closeout-aged-out.lock"
flock -n 8 && ok || bad "P4: could not take the writer's lock in the test shell"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P4: a held lock exited $RC"
cmp -s "$T/tsv-before" "$TSV" && ok || bad "P4: it re-wrote the tsv while another writer held the lock"
grep -q 'tsv prune skipped: lock held' "$LOG" 2>/dev/null \
  && ok || bad "P4: the skip is not in the log: $(cat "$LOG" 2>/dev/null)"
summary | grep -q 'tsv_kept=0 tsv_archived=0 tsv_kept_live=0' \
  && ok || bad "P4: a skipped prune reported work: $(summary)"
exec 8>&-

# ── P5: a knob that is not a number ─────────────────────────────────────────
mkfix
mktsv
printf 'CLOSEOUT_TSV_KEEP_DAYS=abc\n' > "$T/h/env/global.env"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P5: exited $RC"
grep -q 'CLOSEOUT_TSV_KEEP_DAYS is not a number - using 30' "$LOG" 2>/dev/null \
  && ok || bad "P5: a typo'd knob was applied in silence: $(cat "$LOG" 2>/dev/null)"
summary | grep -q 'tsv_kept=36001 tsv_archived=54001 tsv_kept_live=0' \
  && ok || bad "P5: the fallback did not behave like the 30-day default: $(summary)"

# ── L1-L4: the locks ────────────────────────────────────────────────────────
mkfix
i=1
while [ "$i" -le 100 ]; do
  : > "$T/h/locks/stale-$i.lock"
  touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/stale-$i.lock"
  i=$((i + 1))
done
: > "$T/h/locks/held.lock";   touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/held.lock"
: > "$T/h/locks/openfd.lock"; touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/openfd.lock"
: > "$T/h/locks/fresh.lock";  touch -d "@$NOW" "$T/h/locks/fresh.lock"
mkdir -p "$T/h/locks/keep.d"; : > "$T/h/locks/keep.d/inner.lock"
touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/keep.d/inner.lock" "$T/h/locks/keep.d"
exec 8>"$T/h/locks/held.lock"
flock -n 8 && ok || bad "L2: could not take held.lock in the test shell"
exec 7>"$T/h/locks/openfd.lock"   # open, never flocked: /proc is the only probe that sees it
# the mtime probe reads the pinned clock, so re-stamp after the opens truncated them
touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/held.lock" "$T/h/locks/openfd.lock"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "L1: exited $RC ($(tail -3 "$T/run.out"))"
[ -z "$(find "$T/h/locks" -maxdepth 1 -name 'stale-*.lock' -print -quit)" ] \
  && ok || bad "L1: $(find "$T/h/locks" -maxdepth 1 -name 'stale-*.lock' | wc -l) stale locks survived"
[ -f "$T/h/locks/held.lock" ] && ok || bad "L2: a lock with a live flock holder was deleted"
[ -f "$T/h/locks/openfd.lock" ] && ok || bad "L2b: a lock a process still has open was deleted"
[ -f "$T/h/locks/fresh.lock" ] && ok || bad "L3: a lock touched this minute was deleted"
[ -f "$T/h/locks/keep.d/inner.lock" ] && ok || bad "L4: it descended into a directory under locks/"
summary | grep -q 'locks_removed=100 locks_skipped_held=2' \
  && ok || bad "L1: the lock counters are: $(summary)"
exec 7>&-

# L2c: the same held lock with /proc blinded — flock -n is the last line of defence
rm -f "$T/h/locks/stale-"*.lock "$T/h/locks/openfd.lock"
touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/held.lock"
run DISK_CLEAN_PROC="$T/noproc"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "L2c: exited $RC"
[ -f "$T/h/locks/held.lock" ] \
  && ok || bad "L2c: with /proc unreadable, a flock-held lock was deleted anyway"
summary | grep -q 'locks_removed=0 locks_skipped_held=1' \
  && ok || bad "L2c: the counters are: $(summary)"
exec 8>&-

# ── S1-S4: operator scratch ─────────────────────────────────────────────────
mkfix
mkdir -p "$T/h/state/quota" "$T/h/state/blocked-resolver" "$T/h/state/scratch"
printf 'one-off\n'   > "$T/h/state/oneoff.sh"
printf 'backfilled\n'> "$T/h/state/backfill.done"
printf 'old copy\n'  > "$T/h/state/claude-auth-down.txt.bak-202508170000"
printf 'mirror\n'    > "$T/h/state/mirror-sync.sh"
printf 'a different oneoff\n' > "$T/h/state/scratch/oneoff.sh"
printf '{"used":3}\n' > "$T/h/state/quota/a.json"
printf '{"ts":"x"}\n' > "$T/h/state/backup-last.json"
printf 'x\ty\n'       > "$T/h/state/blocked-resolver/.last-visited.tsv"
printf '12,42 * * * * %s/h/state/mirror-sync.sh >/dev/null 2>&1\n' "$T" > "$T/crontab.txt"
SUM_ONEOFF=$(sha256sum < "$T/h/state/oneoff.sh")
SUM_BAK=$(sha256sum < "$T/h/state/claude-auth-down.txt.bak-202508170000")
SUM_COLLIDE=$(sha256sum < "$T/h/state/scratch/oneoff.sh")
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1: exited $RC ($(tail -3 "$T/run.out"))"
[ -f "$T/h/state/scratch/backfill.done" ] && [ ! -e "$T/h/state/backfill.done" ] \
  && ok || bad "S1: state/backfill.done did not move"
[ -f "$T/h/state/scratch/claude-auth-down.txt.bak-202508170000" ] \
  && [ ! -e "$T/h/state/claude-auth-down.txt.bak-202508170000" ] \
  && ok || bad "S1: the .bak- copy did not move"
[ "$(sha256sum < "$T/h/state/scratch/claude-auth-down.txt.bak-202508170000")" = "$SUM_BAK" ] \
  && ok || bad "S1: the moved .bak- copy is not the file that was there"
[ -f "$T/h/state/mirror-sync.sh" ] \
  && ok || bad "S2: it moved a state/*.sh the crontab runs"
[ "$(sha256sum < "$T/h/state/scratch/oneoff.sh")" = "$SUM_COLLIDE" ] \
  && ok || bad "S4: a name collision clobbered the file already under state/scratch/"
[ -f "$T/h/state/oneoff.sh" ] && [ "$(sha256sum < "$T/h/state/oneoff.sh")" = "$SUM_ONEOFF" ] \
  && ok || bad "S4: the colliding original was moved or changed anyway"
grep -q 'scratch kept: oneoff.sh' "$LOG" 2>/dev/null \
  && ok || bad "S4: the collision is not named in the log: $(cat "$LOG" 2>/dev/null)"
for keep in state/box-id state/quota/a.json state/backup-last.json \
            state/blocked-resolver/.last-visited.tsv; do
  [ -f "$T/h/$keep" ] && ok || bad "S3: $keep moved"
done
summary | grep -q 'scratch_moved=2 scratch_skipped=2' \
  && ok || bad "S3: the scratch counters are: $(summary)"

# ── S5: a state/*.sh a bin/ script reads by name ────────────────────────────
# The crontab is not the only lane that owns a file in state/. A bin/ script
# that reads state/<name>.sh would break just as hard if the file moved under
# state/scratch/, so the second skip rule gets its own case.
mkfix
printf 'helper\n' > "$T/h/state/helper.sh"
printf 'loose\n'  > "$T/h/state/loose.sh"
printf '#!/bin/bash\n. "$H/state/helper.sh"\n' > "$T/h/bin/some-lane.sh"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S5: exited $RC ($(tail -3 "$T/run.out"))"
[ -f "$T/h/state/helper.sh" ] \
  && ok || bad "S5: it moved a state/*.sh that a bin/ script reads by name"
grep -q 'scratch kept: helper.sh (a bin/ script reads it)' "$LOG" 2>/dev/null \
  && ok || bad "S5: the bin/-reader skip is not named in the log: $(cat "$LOG" 2>/dev/null)"
[ -f "$T/h/state/scratch/loose.sh" ] && [ ! -e "$T/h/state/loose.sh" ] \
  && ok || bad "S5: a state/*.sh nothing reads did not move"
summary | grep -q 'scratch_moved=1 scratch_skipped=1' \
  && ok || bad "S5: the counters are: $(summary)"

# ── D1-D3: the dead leases dir ──────────────────────────────────────────────
mkfix
mkdir -p "$T/h/state/leases" "$T/h/state/quota/leases/max3"
for f in a b c; do : > "$T/h/state/leases/$f"; touch -d "@$((NOW - 40 * 86400))" "$T/h/state/leases/$f"; done
: > "$T/h/state/quota/leases/max3/m1"
touch -d "@$((NOW - 40 * 86400))" "$T/h/state/quota/leases/max3/m1" "$T/h/state/leases"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "D1: exited $RC"
[ ! -e "$T/h/state/leases" ] && ok || bad "D1: state/leases survived with nothing recent in it"
[ -f "$T/h/state/quota/leases/max3/m1" ] && ok || bad "D3: it deleted state/quota/leases, a live path"
summary | grep -q 'leases=removed' && ok || bad "D1: the summary is: $(summary)"

mkfix
mkdir -p "$T/h/state/leases"
: > "$T/h/state/leases/a"; touch -d "@$((NOW - 86400))" "$T/h/state/leases/a"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "D2: exited $RC"
[ -d "$T/h/state/leases" ] && ok || bad "D2: it deleted a leases dir with a one-day-old entry"
summary | grep -q 'leases=kept' && ok || bad "D2: the summary is: $(summary)"

# ── M1: the summary line is the work that really happened ───────────────────
mkfix
mkdir -p "$T/h/state/leases" "$T/h/state/scratch"
{
  printf 'p\t/root/harness/builds/p-BH-1-%s\tPR_CREATED u1\taged out\n' "$S60"
  printf 'p\t/root/harness/builds/p-BH-2-%s\tPR_CREATED u2\taged out\n' "$S60"
  printf 'p\t/root/harness/builds/p-BH-3-%s\tPR_CREATED u3\taged out\n' "$S29"
} > "$TSV"
i=1
while [ "$i" -le 100 ]; do
  : > "$T/h/locks/stale-$i.lock"; touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/stale-$i.lock"
  i=$((i + 1))
done
: > "$T/h/locks/held.lock"
exec 8>"$T/h/locks/held.lock"
flock -n 8 && ok || bad "M1: could not take held.lock in the test shell"
touch -d "@$((NOW - 3 * 86400))" "$T/h/locks/held.lock"
printf 'one\n' > "$T/h/state/oneoff.sh"
printf 'two\n' > "$T/h/state/backfill.done"
printf 'three\n' > "$T/h/state/claude-auth-down.txt.bak-202508170000"
printf 'cron\n' > "$T/h/state/mirror-sync.sh"
printf 'collide\n' > "$T/h/state/dup.sh"
printf 'already there\n' > "$T/h/state/scratch/dup.sh"
printf '12,42 * * * * %s/h/state/mirror-sync.sh\n' "$T" > "$T/crontab.txt"
: > "$T/h/state/leases/old"
touch -d "@$((NOW - 40 * 86400))" "$T/h/state/leases/old" "$T/h/state/leases"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "M1: exited $RC ($(tail -3 "$T/run.out"))"
summary | grep -q 'tsv_kept=1 tsv_archived=2 tsv_kept_live=0 locks_removed=100 locks_skipped_held=1 scratch_moved=3 scratch_skipped=2 leases=removed' \
  && ok || bad "M1: the summary line is: $(summary)"
summary | grep -q 'disk-clean: [0-9]*%->[0-9]*% npm=' \
  && ok || bad "M1: the original counters left the summary line: $(summary)"
exec 8>&-

echo "disk-clean-hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
