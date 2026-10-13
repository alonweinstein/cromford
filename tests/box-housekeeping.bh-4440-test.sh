#!/bin/bash
# tests/box-housekeeping.bh-4440-test.sh — BH-4440: the daily box housekeeping
# that prunes the grok/codex session ledgers and stale /tmp top-level entries.
#
# What is proved here, against the REAL bin/box-housekeeping.sh (and, in §6,
# the real bin/disk-clean.sh that runs it from cron) over a fixture HOME, /tmp
# and /proc through the BOX_HK_* seams and a frozen clock:
#   §1  session files older than AGENT_SESSION_KEEP_DAYS (default 7) go, a 1d
#       file stays, and nothing outside the two sessions roots is touched:
#       $HOME/worktrees, ~/.claude project memory and ~/.codex/auth.json at 30d;
#   §2  a dir emptied by the sweep and its emptied parent go, sessions/ itself
#       and a dir still holding a file stay;
#   §3  /tmp: a 3d entry goes, a 1d one stays, and worktrees/ repos/ builds/
#       .X11-unix, a git worktree, a dir with one fresh child and a symlink's
#       target all survive;
#   §4  a 3d dir with a /proc fd or a /proc cwd into it is kept;
#   §5  --dry-run deletes nothing and names what it would remove; the knob
#       moves the cutoff; a garbage knob deletes nothing and says so;
#   §6  the production entry point: bin/disk-clean.sh runs the housekeeping,
#       and its npm stage obeys NPM_CACHE_MAX_MB.
# Run from anywhere: tests/box-housekeeping.bh-4440-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HK="$DIR/bin/box-housekeeping.sh"
[ -f "$HK" ] || { echo "FAIL: bin/box-housekeeping.sh does not exist"; exit 1; }
unset AGENT_SESSION_KEEP_DAYS TMP_TOPLEVEL_STALE_D TMP_SWEEP_KEEP_GLOBS NPM_CACHE_MAX_MB 2>/dev/null || true

NOW=1789514400                     # 2026-09-15T23:20:00Z — every age derives from this
D=86400
age() { # age <seconds-ago> <path...>
  local s=$1; shift
  touch -h -d "@$((NOW - s))" "$@"
}

FH="$T/home"; FT="$T/tmp"; FP="$T/proc"; HH="$T/h"
build_fixture() {
  scratch_rm "$FH"; scratch_rm "$FT"; scratch_rm "$FP"; scratch_rm "$T/outside"
  mkdir -p "$FH/.grok/sessions/a" "$FH/.grok/sessions/b/c" "$FH/.grok/sessions/keep" \
           "$FH/.codex/sessions/2026/09" "$FH/.codex/sessions/2026/08/01" \
           "$FH/worktrees/x" "$FH/.claude/projects/p/memory" \
           "$FT" "$FP" "$T/outside" "$HH/logs"
  for r in "$FH/.grok/sessions/a" "$FH/.codex/sessions/2026/09"; do
    for d in 1 8 30; do echo x > "$r/${d}d.jsonl"; age $((d * D)) "$r/${d}d.jsonl"; done
  done
  # only-old leaf two levels under sessions/: both levels empty after the sweep
  echo x > "$FH/.grok/sessions/b/c/old.jsonl";    age $((9 * D)) "$FH/.grok/sessions/b/c/old.jsonl"
  echo x > "$FH/.codex/sessions/2026/08/01/o.jsonl"; age $((20 * D)) "$FH/.codex/sessions/2026/08/01/o.jsonl"
  echo x > "$FH/.grok/sessions/keep/new.jsonl";   age $((2 * D)) "$FH/.grok/sessions/keep/new.jsonl"
  echo x > "$FH/worktrees/x/old.txt";             age $((30 * D)) "$FH/worktrees/x/old.txt"
  echo x > "$FH/.claude/projects/p/memory/old.md"; age $((30 * D)) "$FH/.claude/projects/p/memory/old.md"
  echo x > "$FH/.codex/auth.json";                age $((30 * D)) "$FH/.codex/auth.json"
  age $((30 * D)) "$FH/.grok/sessions/b/c" "$FH/.grok/sessions/b" "$FH/.codex/sessions/2026/08/01" "$FH/.codex/sessions/2026/08"

  # /tmp
  mkdir -p "$FT/old3d" "$FT/new1d" "$FT/worktrees/w" "$FT/repos" "$FT/builds" "$FT/.X11-unix" \
           "$FT/gitwt" "$FT/mixed" "$FT/held-fd" "$FT/held-cwd"
  echo x > "$FT/old3d/f";      age $((3 * D)) "$FT/old3d/f" "$FT/old3d"
  echo x > "$FT/old3.txt";     age $((3 * D)) "$FT/old3.txt"
  echo x > "$FT/new1d/f";      age $((1 * D)) "$FT/new1d/f" "$FT/new1d"
  echo x > "$FT/worktrees/w/f"; age $((30 * D)) "$FT/worktrees/w/f" "$FT/worktrees/w" "$FT/worktrees"
  age $((3 * D)) "$FT/repos" "$FT/builds"
  age $((30 * D)) "$FT/.X11-unix"
  echo 'gitdir: /nowhere/.git/worktrees/g' > "$FT/gitwt/.git"; age $((3 * D)) "$FT/gitwt/.git" "$FT/gitwt"
  echo x > "$FT/mixed/fresh";  age 3600 "$FT/mixed/fresh"; age $((3 * D)) "$FT/mixed"
  echo x > "$FT/held-fd/f";    age $((3 * D)) "$FT/held-fd/f" "$FT/held-fd"
  echo x > "$FT/held-cwd/f";   age $((3 * D)) "$FT/held-cwd/f" "$FT/held-cwd"
  echo x > "$T/outside/keep.txt"
  ln -s "$T/outside" "$FT/lnk"; age $((3 * D)) "$FT/lnk"
  mkdir -p "$FP/123/fd" "$FP/124" "$FP/1/fd"
  ln -s "$FT/held-fd/f" "$FP/123/fd/4"
  ln -s "$FT/held-cwd" "$FP/124/cwd"
  ln -s / "$FP/1/cwd"                        # pid 1's cwd is / — must not hold all of /tmp
}
hk() { # hk [env...] [-- args] -> runs the housekeeping over the fixture; stdout in $T/out
  local args=()
  local envs=()
  while [ $# -gt 0 ]; do
    [ "$1" = -- ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  env HARNESS_ROOT="$HH" HARNESS="$HH" BOX_HK_HOME="$FH" BOX_HK_TMP="$FT" BOX_HK_PROC="$FP" \
      BOX_HK_NOW="$NOW" "${envs[@]}" bash "$HK" "${args[@]}" > "$T/out" 2>&1
}
LOG="$HH/logs/disk-clean.log"

# ══ 1. session ledgers ═══════════════════════════════════════════════════════
build_fixture
hk; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the run exits 0 (rc=$RC: $(cat "$T/out"))"
for r in "$FH/.grok/sessions/a" "$FH/.codex/sessions/2026/09"; do
  [ -f "$r/1d.jsonl" ] && ok || bad "1 a 1d session file must stay ($r/1d.jsonl)"
  [ ! -e "$r/8d.jsonl" ] && ok || bad "1 an 8d session file must go ($r/8d.jsonl)"
  [ ! -e "$r/30d.jsonl" ] && ok || bad "1 a 30d session file must go ($r/30d.jsonl)"
done
[ -f "$FH/worktrees/x/old.txt" ] && ok || bad "1 \$HOME/worktrees is never touched"
[ -f "$FH/.claude/projects/p/memory/old.md" ] && ok || bad "1 ~/.claude project memory is never touched"
[ -f "$FH/.codex/auth.json" ] && ok || bad "1 ~/.codex/auth.json (outside sessions/) is never touched"
grep -q 'box-housekeeping: sessions removed_files=6 ' "$LOG" && ok \
  || bad "1 one sessions summary line counting the 6 verified removals ($(grep sessions "$LOG"))"

# ══ 2. empty dirs ════════════════════════════════════════════════════════════
[ ! -e "$FH/.grok/sessions/b/c" ] && ok || bad "2 the dir the sweep emptied must go"
[ ! -e "$FH/.grok/sessions/b" ] && ok || bad "2 its emptied parent must go"
[ ! -e "$FH/.codex/sessions/2026/08" ] && ok || bad "2 the codex month dir emptied by the sweep must go"
[ -d "$FH/.grok/sessions" ] && [ -d "$FH/.codex/sessions" ] && ok || bad "2 the sessions roots themselves stay"
[ -f "$FH/.grok/sessions/keep/new.jsonl" ] && ok || bad "2 a dir still holding a fresh file stays"
[ -d "$FH/.codex/sessions/2026/09" ] && ok || bad "2 the dir holding the 1d file stays"

# ══ 3. /tmp top level ════════════════════════════════════════════════════════
[ ! -e "$FT/old3d" ] && ok || bad "3 a 3d top-level dir must go"
[ ! -e "$FT/old3.txt" ] && ok || bad "3 a 3d top-level file must go"
[ -d "$FT/new1d" ] && ok || bad "3 a 1d dir must stay"
for k in worktrees repos builds .X11-unix gitwt; do
  [ -d "$FT/$k" ] && ok || bad "3 /tmp/$k must stay at any age"
done
[ -f "$FT/worktrees/w/f" ] && ok || bad "3 a 30d file under /tmp/worktrees must stay"
[ -f "$FT/mixed/fresh" ] && ok || bad "3 a dir with an old mtime but a fresh child must stay"
[ -f "$T/outside/keep.txt" ] && ok || bad "3 a symlink's target is never followed into"
grep -q 'box-housekeeping: tmp removed=3 ' "$LOG" && ok \
  || bad "3 one tmp summary line counting old3d, old3.txt and the link ($(grep 'tmp ' "$LOG"))"

# ══ 4. held open ═════════════════════════════════════════════════════════════
[ -f "$FT/held-fd/f" ] && ok || bad "4 a 3d dir with a /proc fd into it must stay"
[ -f "$FT/held-cwd/f" ] && ok || bad "4 a 3d dir that is a /proc cwd must stay"
grep -q 'box-housekeeping: tmp .*skipped_held=2' "$LOG" && ok || bad "4 both held dirs counted skipped_held ($(grep 'tmp ' "$LOG"))"

# ══ 5. dry run and knobs ═════════════════════════════════════════════════════
build_fixture
B=$(find "$FH" "$FT" "$T/outside" | wc -l)
hk -- --dry-run; RC=$?
A=$(find "$FH" "$FT" "$T/outside" | wc -l)
[ "$RC" = 0 ] && [ "$B" = "$A" ] && ok || bad "5 --dry-run must delete nothing (rc=$RC, $B entries before, $A after)"
grep -q "^would remove $FT/old3d (" "$T/out" && ok || bad "5 --dry-run names old3d ($(cat "$T/out"))"
grep -q "^would remove $FH/.grok/sessions/a/8d.jsonl (" "$T/out" && ok || bad "5 --dry-run names the 8d session file"
grep -q "would remove $FT/held-fd" "$T/out" && bad "5 --dry-run must not name a held dir" || ok

build_fixture
hk AGENT_SESSION_KEEP_DAYS=40
[ -f "$FH/.grok/sessions/a/30d.jsonl" ] && ok || bad "5 AGENT_SESSION_KEEP_DAYS=40 keeps the 30d file"
build_fixture
hk TMP_TOPLEVEL_STALE_D=5
[ -d "$FT/old3d" ] && ok || bad "5 TMP_TOPLEVEL_STALE_D=5 keeps a 3d /tmp dir"
for junk in abc 0; do
  build_fixture; : > "$LOG"
  B=$(find "$FH" | wc -l)
  hk AGENT_SESSION_KEEP_DAYS=$junk
  A=$(find "$FH" | wc -l)
  [ "$B" = "$A" ] && ok || bad "5 AGENT_SESSION_KEEP_DAYS=$junk must delete no session file ($B before, $A after)"
  grep -q 'AGENT_SESSION_KEEP_DAYS invalid' "$LOG" && ok || bad "5 AGENT_SESSION_KEEP_DAYS=$junk is logged invalid"
done
build_fixture; : > "$LOG"
hk TMP_TOPLEVEL_STALE_D=abc
[ -d "$FT/old3d" ] && ok || bad "5 TMP_TOPLEVEL_STALE_D=abc must delete nothing in /tmp"
grep -q 'TMP_TOPLEVEL_STALE_D invalid' "$LOG" && ok || bad "5 TMP_TOPLEVEL_STALE_D=abc is logged invalid"
# a sessions root that is a symlink is refused, never followed
build_fixture
mkdir -p "$T/elsewhere"; echo x > "$T/elsewhere/old.jsonl"; age $((30 * D)) "$T/elsewhere/old.jsonl"
scratch_rm "$FH/.grok/sessions"; ln -s "$T/elsewhere" "$FH/.grok/sessions"
hk
[ -f "$T/elsewhere/old.jsonl" ] && ok || bad "5 a symlinked sessions root must not be followed"
scratch_rm "$T/elsewhere"
# an unknown flag is refused before anything is deleted
build_fixture
hk -- --bogus; RC=$?
[ "$RC" = 2 ] && [ -d "$FT/old3d" ] && ok || bad "5 an unknown flag exits 2 and deletes nothing (rc=$RC)"

# ══ 6. the production entry point: bin/disk-clean.sh ═════════════════════════
build_fixture
mkdir -p "$HH/bin" "$HH/state" "$T/repos" "$T/fakebin" "$T/npmdir"
cp "$HK" "$HH/bin/box-housekeeping.sh"; chmod +x "$HH/bin/box-housekeeping.sh"
cat > "$T/fakebin/du" <<SH
#!/bin/bash
[ "\$1" = -sm ] && [ "\$2" = "$T/npmdir" ] && { printf '%s\t%s\n' "\${FAKE_NPM_MB:-0}" "\$2"; exit 0; }
exec /usr/bin/du "\$@"
SH
cat > "$T/fakebin/npm" <<SH
#!/bin/bash
printf '%s\n' "npm \$*" >> "$T/npm.calls"
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/pgrep"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/crontab"
chmod +x "$T/fakebin/"*
[ -x /usr/bin/du ] || { echo "du not at /usr/bin/du — skipping §6"; echo "box-housekeeping: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
dc() {
  rm -f "$T/npm.calls"
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$HH" HARNESS="$HH" DISK_CLEAN_REPOS="$T/repos" \
      DISK_CLEAN_NPM_DIR="$T/npmdir" DISK_CLEAN_NOW="$NOW" DISK_CLEAN_PROC="$FP" \
      BOX_HK_HOME="$FH" BOX_HK_TMP="$FT" BOX_HK_PROC="$FP" BOX_HK_NOW="$NOW" \
      "$@" bash "$DIR/bin/disk-clean.sh" >/dev/null 2>&1
}
dc FAKE_NPM_MB=3000 NPM_CACHE_MAX_MB=2048; RC=$?
[ "$RC" = 0 ] && ok || bad "6 bin/disk-clean.sh exits 0 (rc=$RC)"
[ ! -e "$FH/.grok/sessions/a/8d.jsonl" ] && ok || bad "6 bin/disk-clean.sh must run the housekeeping (8d session file still there)"
[ ! -e "$FT/old3d" ] && ok || bad "6 bin/disk-clean.sh must run the /tmp sweep"
grep -q '^npm cache clean --force$' "$T/npm.calls" 2>/dev/null && ok \
  || bad "6 3000 MB over NPM_CACHE_MAX_MB=2048 must run npm cache clean --force ($(cat "$T/npm.calls" 2>/dev/null))"
grep -q 'disk-clean: .*npm=3000M' "$LOG" && ok || bad "6 the disk-clean summary line keeps its shape"
dc FAKE_NPM_MB=1000 NPM_CACHE_MAX_MB=2048
[ ! -s "$T/npm.calls" ] && ok || bad "6 1000 MB under 2048 must not clean the npm cache ($(cat "$T/npm.calls"))"
dc FAKE_NPM_MB=1000 NPM_CACHE_MAX_MB=512
[ -s "$T/npm.calls" ] && ok || bad "6 NPM_CACHE_MAX_MB=512 moves the line: 1000 MB is over it"
: > "$LOG"
dc FAKE_NPM_MB=3000 NPM_CACHE_MAX_MB=abc
[ ! -s "$T/npm.calls" ] && ok || bad "6 a garbage NPM_CACHE_MAX_MB must skip the clean, not guess"
grep -q 'NPM_CACHE_MAX_MB' "$LOG" && ok || bad "6 a garbage NPM_CACHE_MAX_MB is logged"
# the disk-clean off switch stops the housekeeping too (lane gate in the script)
build_fixture; mkdir -p "$HH/bin/lib" "$HH/flags" "$HH/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$HH/bin/lib/"; : > "$HH/flags/lane-off-disk-clean"
hk
[ -d "$FT/old3d" ] && [ -f "$FH/.grok/sessions/a/8d.jsonl" ] && ok || bad "6 flags/lane-off-disk-clean stops bin/box-housekeeping.sh"
scratch_rm "$HH/flags"; scratch_rm "$HH/bin/lib"

echo "box-housekeeping: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
