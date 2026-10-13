#!/bin/bash
# tests/audit-tail-test.sh — bin/audit-tail.sh against fixture audit trails and a
# scratch harness tree. Nothing here installs auditd, reads /var/log/audit or
# touches a real box: the fixtures are `ausearch -i` output written by hand.
#
# WHY THE SCRIPT EXISTS (incident #388). On 2026-09-15 a test re-derived its
# harness root as the LIVE one and deleted the hub's harness. Nothing recorded
# which process did it, from which working directory, or under which build.
# auditd watches the harness roots now, and this is the reader that turns those
# kernel records into one alert per burst.
#
# What is proved here:
#   1. a deletion under a watched root becomes ONE line with the fields in the
#      contracted order, and many events by one process collapse into one burst;
#   2. a build directory resolves a lane and names the session log;
#   3. the NEGATIVES: syscalls that are not deletions, paths outside the roots,
#      a lane nothing can name, and empty input all stay quiet;
#   4. class and severity, including the two shapes that must NOT page (a build
#      releasing its own claim file, a truncated log file);
#   4b. the lane does not watch itself, and it does not let a value out of the
#      audit log break the line it writes (BH-444 review, 2026-09-20);
#   5. the live loop end to end: the kill switches, the non-blocking lock, the
#      blind alert, checkpoint handling, the per-burst log-then-alert order, the
#      per-tick cap and the critical-first order that cap is spent in;
#   6. the cron line is in every live box file and in none of the paused one;
#   7. the docs exist and mention the lane.
# Run from anywhere: tests/audit-tail-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
FX="$DIR/tests/fixtures/audit"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/h/locks" \
         "$T/claims/cromford" "$T/builds/cromford-BH-406-202609151200" \
         "$T/fakebin" "$T/nobin"
cp "$DIR/bin/audit-tail.sh" "$T/h/bin/"; chmod +x "$T/h/bin/audit-tail.sh"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
: > "$T/claims/cromford/BH-405"
: > "$T/builds/cromford-BH-406-202609151200/pipeline.log"

ROOTS="/root/harness /root/orchestrator /etc/harness /root/.ssh"
P() { # P <fixture>  — the pure parser, exactly as an operator would run it
  bash "$T/h/bin/audit-tail.sh" --parse --claims "$T/claims" --builds "$T/builds" \
       --worktrees /root/worktrees --roots "$ROOTS" < "$FX/$1"
}
lines() { printf '%s' "$1" | grep -c . ; }

# ============================================================================
# 1. one deletion, one line — and ten of them are still one line
# ============================================================================
OUT=$(P single-unlink.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "one event must produce exactly one burst line: $OUT"
for want in \
  'path=/root/harness/env/global.env' 'syscall=unlinkat' 'pid=4242' 'ppid=4100' \
  'comm=rm' 'exe=/usr/bin/rm' 'cwd=/root/worktrees/cromford-bh-405' \
  'lane=build:cromford/BH-405' 'sev=critical' 'class=delete' 'n=1' 'more=0' \
  'root=/root/harness' 'auid=root' 'ses=3'; do
  grep -qF " $want" <<<" $OUT" && ok || bad "the burst line must carry $want: $OUT"
done
grep -qF "claim=$T/claims/cromford/BH-405" <<<"$OUT" \
  && ok || bad "a claim that exists must be named on the line: $OUT"
# The field ORDER is the contract — lane-alert ids and every future reader parse
# positionally-shaped key=value pairs, so one anchored regex pins the whole line.
grep -qE '^AUDIT class=[^ ]+ n=[0-9]+ path=[^ ]+ more=[0-9]+ root=[^ ]+ syscall=[^ ]+ pid=[^ ]+ ppid=[^ ]+ comm=[^ ]+ exe=[^ ]+ cwd=[^ ]+ auid=[^ ]+ ses=[^ ]+ lane=[^ ]+ first=[^ ]+ last=[^ ]+ sev=(info|critical)( (claim|session)=[^ ]+)?$' <<<"$OUT" \
  && ok || bad "the fields must appear in the contracted order: $OUT"
# Timestamps are carried verbatim (whitespace as _), never re-rendered.
grep -qF 'first=09/15/2026_12:00:01.123:4567' <<<"$OUT" \
  && ok || bad "first= must be the fixture's own timestamp string: $OUT"

OUT=$(P burst-10.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "ten events from one pid are ONE burst: $OUT"
grep -qF ' n=10 ' <<<"$OUT" && ok || bad "the burst must count its events (n=10): $OUT"
grep -qF ' more=9 ' <<<"$OUT" && ok || bad "more= is n-1: $OUT"
grep -qF 'first=09/15/2026_12:00:02.101:5001' <<<"$OUT" && ok || bad "first= is the earliest event: $OUT"
grep -qF 'last=09/15/2026_12:00:02.110:5010' <<<"$OUT" && ok || bad "last= is the latest event: $OUT"

# ============================================================================
# 2. a build directory names the lane and its session log
# ============================================================================
OUT=$(P builds-lane.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "the builds-dir fixture must produce one line: $OUT"
grep -qF 'lane=build:cromford/BH-406' <<<"$OUT" \
  && ok || bad "a builds dir must resolve the lane even with no claim: $OUT"
grep -qF "session=$T/builds/cromford-BH-406-202609151200/pipeline.log" <<<"$OUT" \
  && ok || bad "the session log must be named: $OUT"
grep -qF 'claim=' <<<"$OUT" && bad "there is no claim file here — claim= must be absent: $OUT" || ok

# ============================================================================
# 3. the negatives (these carry the weight: a noisy tailer gets turned off)
# ============================================================================
OUT=$(P neg-syscalls.txt)
[ "$(lines "$OUT")" -eq 0 ] && ok || bad "openat/write/chmod/setxattr/utimensat are not deletions: $OUT"
OUT=$(P neg-roots.txt)
[ "$(lines "$OUT")" -eq 0 ] && ok || bad "/tmp, /root/repos, /root/harnessfoo and /root/.sshd are outside the roots: $OUT"
OUT=$(P unresolved.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "an unresolvable lane is still a burst: $OUT"
grep -qF 'lane=unresolved' <<<"$OUT" && ok || bad "an unknown worktree must say unresolved, never guess: $OUT"
grep -qE ' (claim|session)=' <<<"$OUT" && bad "nothing may be attached to an unresolved lane: $OUT" || ok
OUT=$(P empty.txt); RC=$?
[ "$(lines "$OUT")" -eq 0 ] && ok || bad "empty input must produce nothing: $OUT"
[ "$RC" -eq 0 ] && ok || bad "empty input is not an error (rc=$RC)"
OUT=$(printf '' | bash "$T/h/bin/audit-tail.sh" --parse); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok || bad "--parse on empty stdin: rc=$RC out=$OUT"

# --parse must touch nothing at all, even pointed at a harness that is not there
HARNESS="$T/nowhere" bash "$T/h/bin/audit-tail.sh" --parse < "$FX/single-unlink.txt" >/dev/null 2>&1
[ -e "$T/nowhere" ] && bad "--parse created files under a harness root" || ok

# ============================================================================
# 4. classes and severity
# ============================================================================
OUT=$(P rename-bin.txt)
grep -qF 'class=rename' <<<"$OUT" && ok || bad "renameat2 is a rename: $OUT"
grep -qF 'sev=critical' <<<"$OUT" && ok || bad "a rename under <root>/bin is critical: $OUT"
OUT=$(P truncate-log.txt)
grep -qF 'class=truncate' <<<"$OUT" && ok || bad "an O_TRUNC open is a truncate: $OUT"
grep -qF 'sev=info' <<<"$OUT" && ok || bad "truncating a log file must NOT page: $OUT"
OUT=$(P claim-delete.txt)
grep -qF 'sev=info' <<<"$OUT" && ok || bad "a build releasing its own claim must NOT page: $OUT"
OUT=$(P rmdir-builds.txt)
grep -qF 'sev=critical' <<<"$OUT" && ok || bad "removing a directory is critical: $OUT"
OUT=$(P burst-30-logs.txt)
grep -qF ' n=30 ' <<<"$OUT" && ok || bad "thirty events are one burst of 30: $OUT"
grep -qF 'sev=critical' <<<"$OUT" && ok || bad "a burst at/over AUDIT_PAGE_MIN is critical: $OUT"
OUT=$(AUDIT_PAGE_MIN=31 P burst-30-logs.txt)
grep -qF 'sev=info' <<<"$OUT" && ok || bad "AUDIT_PAGE_MIN must move the line: $OUT"
OUT=$(AUDIT_PAGE_ALL=1 P truncate-log.txt)
grep -qF 'sev=critical' <<<"$OUT" && ok || bad "AUDIT_PAGE_ALL=1 makes every burst critical: $OUT"
OUT=$(P relative-name.txt)
grep -qF 'path=/root/harness/logs/x.log' <<<"$OUT" \
  && ok || bad "a relative name must be joined onto cwd: $OUT"
# A root written with a trailing slash is the same root. Getting this wrong is
# invisible on a live box: the installer watches the path, the tailer matches
# nothing, and the lane is silently blind.
OUT=$(ROOTS="/root/harness/ /root/orchestrator/ /etc/harness/ /root/.ssh/" P single-unlink.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "a trailing slash on a root must not drop the event: $OUT"
grep -qF ' root=/root/harness ' <<<"$OUT" \
  && ok || bad "the root is reported without its trailing slash: $OUT"
grep -qF 'sev=critical' <<<"$OUT" \
  && ok || bad "the protected prefixes must be built from the stripped root: $OUT"

# ============================================================================
# 4b. the lane does not watch itself, and no value out of the audit log may
#     break the line (BH-444 review, 2026-09-20)
# ============================================================================
# Every tick, this lane truncates its own lock file, rewrites its own checkpoint
# and hands bin/lane-alert.sh work that renames a state file into state/alerts.
# Counted, that is five bursts of the harness watching itself every five
# minutes, on every box, and AUDIT_MAX_BURSTS_PER_TICK is 5 — so a real wipe
# arriving in the same tick would be logged and never paged.
OUT=$(P self-noise.txt)
[ "$(lines "$OUT")" -eq 0 ] \
  && ok || bad "the lane own locks, state/alerts and checkpoint are not incidents: $OUT"
for nope in 'locks/audit-tail.lock' 'locks/beat.lock' 'state/alerts/' 'audit-tail.checkpoint'; do
  grep -qF "$nope" <<<"$OUT" && bad "self-noise leaked onto the wire: $nope" || ok
done
# The exclusion is three named paths, not a blanket on state/ or on the root: a
# claim file and a scratch file under the same tree are still bursts.
OUT=$(P claim-delete.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "the self-noise filter must not swallow state/claims: $OUT"
OUT=$(P burst-30-logs.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "the self-noise filter must not swallow logs/: $OUT"

# A comm is whatever the process called itself. ausearch reads it up to the next
# space, so a TAB rides through — and an unencoded tab splits the burst line for
# every reader that uses awk default field splitting, which is what the contract
# promises will not happen. exe and cwd are encoded; comm must be too.
OUT=$(P spoof-comm.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "the spoofed-comm event is still one burst: $OUT"
grep -qF 'comm=rm%20pid=1' <<<"$OUT" \
  && ok || bad "whitespace inside comm must be %20-encoded like exe and cwd: $OUT"
case "$OUT" in *"$(printf '\t')"*) bad "no burst line may carry a raw tab: $OUT" ;; *) ok ;; esac
# AUDIT + the 17 contracted key=value pairs, split the way any awk reader splits.
[ "$(printf '%s' "$OUT" | awk '{print NF}')" -eq 18 ] \
  && ok || bad "a burst line is AUDIT + 17 fields, got $(printf '%s' "$OUT" | awk '{print NF}'): $OUT"

# lane= is built from a worktree directory name, which is also not ours. A
# project directory holding a space puts a second ` pid=` on the line, AFTER the
# real one — and the live loop reads pid off that line to build the alert id.
mkdir -p "$T/claims/evil pid=1"
: > "$T/claims/evil pid=1/BH-405"
OUT=$(P spoof-lane.txt)
[ "$(lines "$OUT")" -eq 1 ] && ok || bad "the spoofed-lane event is still one burst: $OUT"
grep -qF 'lane=build:evil%20pid=1/BH-405' <<<"$OUT" \
  && ok || bad "a lane built from a directory name must be %20-encoded: $OUT"
[ "$(printf '%s' "$OUT" | awk '{print NF}')" -eq 19 ] \
  && ok || bad "a spoofed lane must not add fields to the line: $OUT"

# ============================================================================
# 5. the live loop — the production entry point, on a scratch tree
# ============================================================================
cat > "$T/fakebin/ausearch" <<SH
#!/bin/bash
T="$T"
SH
cat >> "$T/fakebin/ausearch" <<'SH'
echo "$*" >> "$T/ausearch.argv"
PREV=""; CKP=""
for A in "$@"; do [ "$PREV" = --checkpoint ] && CKP="$A"; PREV="$A"; done
# What the checkpoint looked like when this call started, and the fresh one the
# real ausearch would leave behind.
if [ -f "$CKP" ]; then echo present >> "$T/ausearch.ck"; else echo absent >> "$T/ausearch.ck"; fi
[ -n "$CKP" ] && echo NEW > "$CKP"
RC=0
if [ -s "$T/ausearch.rc" ]; then RC=$(cat "$T/ausearch.rc"); rm -f "$T/ausearch.rc"; fi
[ -s "$T/fixture" ] && cat "$(cat "$T/fixture")"
exit "$RC"
SH
chmod +x "$T/fakebin/ausearch"
cat > "$T/fakebin/pgrep" <<SH
#!/bin/bash
[ -f "$T/auditd-up" ] && exit 0
exit 1
SH
chmod +x "$T/fakebin/pgrep"; cp "$T/fakebin/pgrep" "$T/nobin/pgrep"
printf '#!/bin/bash\necho stubhost\n' > "$T/fakebin/hostname"
chmod +x "$T/fakebin/hostname"; cp "$T/fakebin/hostname" "$T/nobin/hostname"

LA="$T/h/bin/lane-alert.sh"
cat > "$LA" <<SH
#!/bin/bash
mkdir -p "$T/h/logs"
echo "\$*" >> "$T/h/logs/lane-alert.calls"
exit 0
SH
chmod +x "$LA"

resetlive() { # a fresh box: no logs, no state, no flags, no lock
  rm -rf "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks"
  rm -f "$T/ausearch.argv" "$T/ausearch.ck" "$T/ausearch.rc" "$T/fixture" "$T/auditd-up"
  : > "$T/h/env/global.env"
  echo small > "$T/h/state/box-id"
  touch "$T/auditd-up"
}
live() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "$@" bash "$T/h/bin/audit-tail.sh" >/dev/null 2>&1; }
calls() { [ -f "$T/h/logs/lane-alert.calls" ] && wc -l < "$T/h/logs/lane-alert.calls" || echo 0; }
# How many days this box has stamped as already-alerted. Counted by glob, never
# by re-deriving today's date: a test that reads the clock is a test that fails
# once a year at midnight.
blindmarks() { ls "$T/h/state" 2>/dev/null | grep -c '^audit-tail-blind-'; }
AULOG="$T/h/logs/audit-tail.log"

# (a) one burst -> one log line, one alert, and the read was checkpointed
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
live
[ "$(calls)" -eq 1 ] && ok || bad "one burst must produce exactly one lane-alert call (got $(calls))"
grep -qF -- '--critical' "$T/h/logs/lane-alert.calls" && ok || bad "a critical burst must page: $(cat "$T/h/logs/lane-alert.calls")"
grep -qF -- '--id audit:small:4242:4567' "$T/h/logs/lane-alert.calls" \
  && ok || bad "the alert id is audit:<box>:<pid>:<first-serial>: $(cat "$T/h/logs/lane-alert.calls")"
grep -qF -- '--severity critical' "$T/h/logs/lane-alert.calls" \
  && ok || bad "the severity must ride the call: $(cat "$T/h/logs/lane-alert.calls")"
grep -q 'AUDIT class=delete' "$AULOG" && ok || bad "the burst must be logged: $(cat "$AULOG" 2>/dev/null)"
grep -qF -- '-k harness' "$T/ausearch.argv" && ok || bad "ausearch must read the harness key: $(cat "$T/ausearch.argv")"
grep -qF -- '--checkpoint' "$T/ausearch.argv" && ok || bad "the read must be checkpointed: $(cat "$T/ausearch.argv")"
# an info burst rides the same path without --critical
resetlive
echo "$FX/truncate-log.txt" > "$T/fixture"
live
[ "$(calls)" -eq 1 ] && ok || bad "an info burst is still recorded (got $(calls))"
grep -qF -- '--critical' "$T/h/logs/lane-alert.calls" \
  && bad "an info burst must not page: $(cat "$T/h/logs/lane-alert.calls")" || ok

# (b) a rotted checkpoint is reset and the re-read is bounded
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
echo OLD > "$T/h/state/audit-tail.checkpoint"
echo 11 > "$T/ausearch.rc"
live
# The stale checkpoint is GONE before the second read starts — that is what the
# reset means. (ausearch itself writes a fresh one on the way out, and the stub
# does the same, so "absent afterwards" would be a test of the stub.)
[ "$(sed -n 2p "$T/ausearch.ck")" = absent ] \
  && ok || bad "rc=11 must remove the checkpoint before re-reading: $(cat "$T/ausearch.ck")"
[ "$(cat "$T/h/state/audit-tail.checkpoint")" != OLD ] \
  && ok || bad "the rotted checkpoint must not survive the reset"
grep -qF -- '-ts recent' <<<"$(head -n 1 "$T/ausearch.argv")" \
  && bad "a box WITH a checkpoint must not re-read the window on the first call: $(cat "$T/ausearch.argv")" || ok
sed -n 2p "$T/ausearch.argv" | grep -qF -- '-ts recent' \
  && ok || bad "the re-read after a reset must be bounded by -ts recent: $(cat "$T/ausearch.argv")"
grep -q 'reset' "$AULOG" && ok || bad "the reset must be written down: $(cat "$AULOG" 2>/dev/null)"

# (c) the per-tick cap, and the overflow said out loud
resetlive
echo "$FX/seven-bursts.txt" > "$T/fixture"
live AUDIT_MAX_BURSTS_PER_TICK=5
[ "$(calls)" -eq 5 ] && ok || bad "the cap must bound the alerts at 5 (got $(calls))"
[ "$(grep -c 'AUDIT class=' "$AULOG")" -eq 7 ] \
  && ok || bad "every burst must still be logged (got $(grep -c 'AUDIT class=' "$AULOG"))"
grep -q '+2 more bursts this tick' "$AULOG" \
  && ok || bad "the capped remainder must be written down: $(cat "$AULOG")"

# ...and the cap is spent CRITICAL FIRST. cap-order.txt is five info bursts
# (log truncation) seen before one critical burst (env/global.env deleted). In
# first-seen order the five info bursts take all five slots and the wipe is a
# "+1 more bursts" line nobody is paged about — which is the whole lane failing
# quietly on the one event it exists for.
resetlive
echo "$FX/cap-order.txt" > "$T/fixture"
live AUDIT_MAX_BURSTS_PER_TICK=5
[ "$(calls)" -eq 5 ] && ok || bad "the cap still bounds the alerts at 5 (got $(calls))"
[ "$(grep -c 'AUDIT class=' "$AULOG")" -eq 6 ] \
  && ok || bad "every burst is still logged (got $(grep -c 'AUDIT class=' "$AULOG"))"
grep -qF -- '--critical' "$T/h/logs/lane-alert.calls" \
  && ok || bad "the critical burst must be paged even though it was seen last: $(cat "$T/h/logs/lane-alert.calls")"
grep -qF -- 'path=/root/harness/env/global.env' "$T/h/logs/lane-alert.calls" \
  && ok || bad "the wipe of env/global.env must reach lane-alert: $(cat "$T/h/logs/lane-alert.calls")"
head -n 1 "$T/h/logs/lane-alert.calls" | grep -qF -- '--critical' \
  && ok || bad "critical goes FIRST, not somewhere in the five: $(cat "$T/h/logs/lane-alert.calls")"
grep -q '+1 more bursts this tick' "$AULOG" \
  && ok || bad "the burst that lost its slot is the info one: $(cat "$AULOG")"
# The log keeps first-seen order; only the sending is re-ordered.
head -n 1 "$AULOG" | grep -qF 'class=truncate' \
  && ok || bad "the log must stay in first-seen order: $(head -n 2 "$AULOG")"

# An alert id names the process that did it. A worktree directory carrying a
# space puts a second ` pid=` on the line after the real one; the id must still
# be the pid the kernel recorded.
resetlive
mkdir -p "$T/h/state/claims/evil pid=1"
: > "$T/h/state/claims/evil pid=1/BH-405"
echo "$FX/spoof-lane.txt" > "$T/fixture"
live
[ "$(calls)" -eq 1 ] && ok || bad "the spoofed-lane burst is one alert (got $(calls))"
grep -qF -- '--id audit:small:4242:9501' "$T/h/logs/lane-alert.calls" \
  && ok || bad "the alert id must carry the kernel pid, not one out of a path: $(cat "$T/h/logs/lane-alert.calls")"

# (d) blind: one alert per day, naming what is needed and why
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
[ -z "$(env PATH="$T/nobin:/usr/bin:/bin" command -v ausearch 2>/dev/null)" ] \
  && ok || bad "the blind case needs a PATH with no ausearch on it"
env PATH="$T/nobin:/usr/bin:/bin" HARNESS="$T/h" bash "$T/h/bin/audit-tail.sh" >/dev/null 2>&1
env PATH="$T/nobin:/usr/bin:/bin" HARNESS="$T/h" bash "$T/h/bin/audit-tail.sh" >/dev/null 2>&1
[ "$(calls)" -eq 0 ] && ok || bad "a blind box pages through ALERTS, not lane-alert (got $(calls))"
[ "$(grep -c 'audit-tail' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)" -eq 1 ] \
  && ok || bad "a blind box alerts ONCE a day: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'NEEDED FROM' "$T/h/logs/ALERTS.log" && ok || bad "the alert must name what is needed and from whom"
grep -q 'BLIND' "$T/h/logs/ALERTS.log" && ok || bad "the alert must say the box is blind"
grep -q 'ausearch is not installed' "$T/h/logs/ALERTS.log" \
  && ok || bad "the reason must be the true one: $(cat "$T/h/logs/ALERTS.log")"
# The marker must never run ahead of the alert. If the ALERTS append fails, the
# day must NOT be stamped as already-alerted, or the box stays quiet until 00:00Z
# about the one thing it cannot see. A directory in place of ALERTS.log makes
# every append to it fail, for root as well.
resetlive
mkdir -p "$T/h/logs/ALERTS.log"
env PATH="$T/nobin:/usr/bin:/bin" HARNESS="$T/h" bash "$T/h/bin/audit-tail.sh" >/dev/null 2>&1
[ "$(blindmarks)" -eq 0 ] \
  && ok || bad "an ALERTS line that never landed must not mark the day as alerted: $(ls "$T/h/state")"
rmdir "$T/h/logs/ALERTS.log"
env PATH="$T/nobin:/usr/bin:/bin" HARNESS="$T/h" bash "$T/h/bin/audit-tail.sh" >/dev/null 2>&1
[ "$(grep -c 'audit-tail' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)" -eq 1 ] \
  && ok || bad "the next tick must alert, because the first one never did: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ "$(blindmarks)" -eq 1 ] \
  && ok || bad "an alert that landed marks the day, so the next tick is quiet: $(ls "$T/h/state")"

# auditd installed but not running is the other reason, and it reads differently
resetlive; rm -f "$T/auditd-up"
echo "$FX/single-unlink.txt" > "$T/fixture"
live
[ "$(calls)" -eq 0 ] && ok || bad "a box with auditd down reads nothing (got $(calls))"
grep -q 'auditd is not running' "$T/h/logs/ALERTS.log" \
  && ok || bad "the reason must distinguish a missing binary from a dead daemon: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# (e) the kill switches cost nothing at all
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
live AUDIT_TAIL=0
[ -f "$AULOG" ] && bad "AUDIT_TAIL=0 must not even write a log line" || ok
[ "$(calls)" -eq 0 ] && ok || bad "AUDIT_TAIL=0 must stop it (got $(calls))"
resetlive; echo "$FX/single-unlink.txt" > "$T/fixture"; touch "$T/h/flags/audit-off"
live
[ -f "$AULOG" ] && bad "flags/audit-off must not even write a log line" || ok
[ "$(calls)" -eq 0 ] && ok || bad "flags/audit-off must stop it (got $(calls))"
resetlive; echo "$FX/single-unlink.txt" > "$T/fixture"
printf 'AUDIT_TAIL=0\n' > "$T/h/env/global.env"
live
[ -f "$AULOG" ] && bad "AUDIT_TAIL=0 in env/global.env must stop it" || ok
[ "$(calls)" -eq 0 ] && ok || bad "AUDIT_TAIL=0 in env/global.env must stop it (got $(calls))"

# The configured env directory wins over the compatibility directory.
resetlive; echo "$FX/single-unlink.txt" > "$T/fixture"
mkdir -p "$T/config-env"
printf 'AUDIT_TAIL=0\n' > "$T/config-env/global.env"
live HARNESS_ENV_DIR="$T/config-env"
[ -f "$AULOG" ] && bad "the resolved env kill switch must prevent logging" || ok
[ "$(calls)" -eq 0 ] && ok || bad "the resolved env kill switch must prevent alerts"

# (f) the lock is DEDUPE: a held lock is skipped, never waited on
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
flock "$T/h/locks/audit-tail.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$T/h/locks/audit-tail.lock" true || break
  sleep 0.1
done
live; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a held lock is a quiet skip, not a failure (rc=$RC)"
[ "$(calls)" -eq 0 ] && ok || bad "a held lock must produce no alerts (got $(calls))"
[ -f "$AULOG" ] && bad "a held lock must produce no log line either" || ok
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# (g) an unclassified ausearch failure consumes nothing
resetlive
echo "$FX/single-unlink.txt" > "$T/fixture"
echo OLD > "$T/h/state/audit-tail.checkpoint"
echo 2 > "$T/ausearch.rc"
live
[ "$(cat "$T/h/state/audit-tail.checkpoint")" = OLD ] \
  && ok || bad "a failed read must restore the checkpoint it started from: $(cat "$T/h/state/audit-tail.checkpoint")"
[ "$(calls)" -eq 0 ] && ok || bad "nothing was read, so nothing may be alerted (got $(calls))"
grep -q 'rc=2' "$AULOG" && ok || bad "the failure must be written down: $(cat "$AULOG" 2>/dev/null)"

# ============================================================================
# 6. the cron line, in every live box file and in none of the paused one
# ============================================================================
for F in "$(rendered_cron_dir)"/*.cron; do
  B=$(basename "$F")
  N=$(grep -c '^\*/5 \* \* \* \* /root/harness/bin/audit-tail\.sh' "$F")
  if [ "$B" = project-10.cron ]; then
    [ "$N" -eq 0 ] && ok || bad "$B is a paused box and must not run the tailer"
    continue
  fi
  [ "$N" -eq 1 ] && ok || bad "$B must carry exactly one audit-tail line (got $N)"
  CS=$(grep -n '^\*/30 \* \* \* \* /root/harness/bin/clock-sync\.sh' "$F" | head -n 1 | cut -d: -f1)
  AT=$(grep -n '^\*/5 \* \* \* \* /root/harness/bin/audit-tail\.sh' "$F" | head -n 1 | cut -d: -f1)
  HS=$(grep -n '^\*/10 \* \* \* \* /root/harness/bin/harden-state\.sh' "$F" | head -n 1 | cut -d: -f1)
  { [ -n "$CS" ] && [ -n "$AT" ] && [ -n "$HS" ] && [ "$CS" -lt "$AT" ] && [ "$AT" -lt "$HS" ]; } \
    && ok || bad "$B: the audit-tail line belongs between clock-sync ($CS) and harden-state ($HS), got $AT"
  # ...and outside the fleet-managed markers, or the next render would eat it
  awk -v n="$AT" '/^# BEGIN fleet-managed/{d=1} /^# END fleet-managed/{d=0}
       NR==n && d==1 { exit 1 }' "$F" \
    && ok || bad "$B: the audit-tail line is inside a fleet-managed block"
done

# ============================================================================
# 7. the docs an operator reads at 3am
# ============================================================================
[ -s "$DIR/docs/AUDIT-TRAIL.md" ] && ok || bad "docs/AUDIT-TRAIL.md must exist and say something"
[ "$(grep -c 'audit-tail\|audit-install\|ausearch -k harness' "$DIR/docs/AUDIT-TRAIL.md" 2>/dev/null || echo 0)" -ge 3 ] \
  && ok || bad "docs/AUDIT-TRAIL.md must cover the tailer, the installer and the forensic command"
[ "$(grep -c audit-tail "$DIR/cron/README.md")" -ge 1 ] \
  && ok || bad "cron/README.md must name the new fleet-wide operator line"

echo "audit-tail: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
