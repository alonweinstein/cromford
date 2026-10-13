#!/bin/bash
# tests/project-lanes.bh-5913-test.sh — BH-5913: the shared per-project lane
# runner (bin/lib/project-lanes.sh + bin/project-lane-run.sh).
#
# WHY. One blocked-resolver scan walked every project's parks; cromford's
# 600+ candidates spent the whole 55-minute tick and nine projects waited 65
# hours. The runner starts one independent process per project instead, and 12
# more hub lanes move onto it after this (their rollout is Blocked-by #5913).
#
#   R1  20 projects, one dispatch, no cap: every run reaches a barrier that only
#       20 runs in parallel can pass
#   R2  the dispatcher returns before any run finishes
#   R3  lock isolation: each run holds locks/<lane>-<project>.lock for its life;
#       a project whose lock is held gets one line and no run; the others run;
#       a lock the dispatcher's caller held is not inherited by a run
#   R4  offsets: stable, inside the period, 5-55 s past a minute, spread, keyed
#       on lane AND project; a period of 0 starts every run at once
#   R5  credential: each run carries its own repo's App token (gh_auth_for);
#       with no App on the box, GH_TOKEN is left as it was
#   R6  each run gets PL_LANE, PL_PROJECT, PL_SLUG and its own state dir
#   R7  a held project gets no run
#
# Run from anywhere: tests/project-lanes.bh-5913-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in bin/project-lane-run.sh bin/lib/project-lanes.sh bin/fleet-conf.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export GH_TOKEN="fixture-default-token"
# FLEET <n> — fleet.conf with projects p1..p<n>, repo o/p<n>.
FLEET() { local i
  for i in $(seq 1 "$1"); do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$i" "$i" "$i" "$i"; done > "$H/fleet.conf"; }

# The lane command every case dispatches. It records what the runner gave it,
# probes its own lock and fd 7, then waits on whatever the case asks for.
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
p="\$1"
own=free; flock -n "$H/locks/\$PL_LANE-\$p.lock" true || own=held
fd7=closed; { : >&7; } 2>/dev/null && fd7=open
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "\$p" "\$PL_LANE" "\$PL_PROJECT" "\${PL_SLUG:-}" "\$PL_STATE_DIR" "\${GH_TOKEN:-none}" "\$own" "\$fd7" >> "$T/runs.tsv"
if [ -e "$T/barrier" ]; then
  for i in \$(seq 1 300); do [ "\$(grep -c . "$T/runs.tsv")" -ge "\$(cat "$T/barrier")" ] && break; sleep 0.2; done
  [ "\$(grep -c . "$T/runs.tsv")" -ge "\$(cat "$T/barrier")" ] || echo "timeout \$p" >> "$T/barrier-timeouts.txt"
fi
if [ -e "$T/hold" ]; then for i in \$(seq 1 300); do [ -e "$T/release" ] && break; sleep 0.2; done; fi
echo "\$p" >> "$T/done.txt"
EOF
chmod +x "$H/bin/fake-lane.sh"

# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1
CLEAN() { rm -f "$T/runs.tsv" "$T/done.txt" "$T/barrier" "$T/barrier-timeouts.txt" "$T/hold" "$T/release" "$H/logs/"*.log
          : > "$T/runs.tsv"; : > "$T/done.txt"; }
NDONE() { grep -c . "$T/done.txt" 2>/dev/null; }
# WAITFOR <shell-test> — up to 60 s for a condition the detached runs make true.
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }
COL() { awk -F'\t' -v p="$1" -v c="$2" '$1 == p {print $c; exit}' "$T/runs.tsv"; }

# ============================================================================
# R1. NO CAP: 20 PROJECTS, ONE DISPATCH, ALL AT ONCE.
# ============================================================================
CLEAN; FLEET 20; echo 20 > "$T/barrier"
OUT=$(pl_dispatch fakelane 0 "$H/bin/fake-lane.sh")
WAITFOR '[ "$(NDONE)" -ge 20 ]' && ok || bad "R1: all 20 runs finish (done: $(NDONE); log: $(tail -3 "$H/logs/fakelane-cron.log" 2>/dev/null))"
[ ! -s "$T/barrier-timeouts.txt" ] && ok || bad "R1: THE POINT: a run waited on another — barrier timeouts: $(tr '\n' ' ' < "$T/barrier-timeouts.txt")"
case "$OUT" in *more*) bad "R1: the summary lists 20 names with no overflow: $OUT" ;; "fakelane dispatch: started 20 project run(s) (period 0s, no cap), 0 held: ["*) ok ;; *) bad "R1: one summary line: $OUT" ;; esac

# ============================================================================
# R2. THE DISPATCHER RETURNS BEFORE THE RUNS FINISH.
# ============================================================================
CLEAN; FLEET 3; touch "$T/hold"
pl_dispatch fakelane 0 "$H/bin/fake-lane.sh" >/dev/null
RC=$?
[ "$RC" = 0 ] && ok || bad "R2: pl_dispatch answers 0 (rc=$RC)"
WAITFOR '[ "$(grep -c . "$T/runs.tsv")" -ge 3 ]' && ok || bad "R2: three runs started (runs: $(grep -c . "$T/runs.tsv"))"
[ "$(NDONE)" = 0 ] && ok || bad "R2: no run had finished when the dispatcher returned (done: $(NDONE))"
touch "$T/release"
WAITFOR '[ "$(NDONE)" -ge 3 ]' && ok || bad "R2: the runs finish after release (done: $(NDONE))"

# ============================================================================
# R3. LOCK ISOLATION.
# ============================================================================
CLEAN; FLEET 3
exec 6>"$H/locks/fakelane-p1.lock"; flock -n 6 || bad "R3 setup: could not take p1's lock"
exec 7>"$H/locks/some-caller.lock"; flock -n 7 || bad "R3 setup: could not take the caller's lock"
pl_dispatch fakelane 0 "$H/bin/fake-lane.sh" >/dev/null
WAITFOR '[ "$(NDONE)" -ge 2 ]' && ok || bad "R3: p2 and p3 run while p1's lock is held (done: $(tr '\n' ' ' < "$T/done.txt"))"
WAITFOR 'grep -q "a run of p1 is still live (locks/fakelane-p1.lock held)" "$H/logs/fakelane-cron.log"' && ok \
  || bad "R3: p1 gets one line and no run: $(cat "$H/logs/fakelane-cron.log" 2>/dev/null)"
grep -q '^p1$' "$T/done.txt" && bad "R3: p1's command must not run while its lock is held" || ok
[ "$(COL p2 7)" = held ] && [ "$(COL p3 7)" = held ] && ok || bad "R3: each run holds its own lock for its life (p2=$(COL p2 7) p3=$(COL p3 7))"
[ "$(COL p2 8)" = closed ] && ok || bad "R3: a run does not inherit the caller's fd 7 (p2 fd7=$(COL p2 8))"
exec 6>&- 7>&-
flock -n "$H/locks/fakelane-p2.lock" true && ok || bad "R3: the lock is free once the run ended"

# ============================================================================
# R4. OFFSETS.
# ============================================================================
NAMES="cromford project-9 project-8 project-4 project-2 project-7 project-1 harness-console project-5 project-6-os project-3 cromford p1 p2 p3 p4 p5 p6 p7 p8"
A=""; B=""; BADOFF=""; SAME=0
for N in $NAMES; do
  O=$(pl_offset blocked-resolver "$N" 540); A="$A $O"; B="$B $(pl_offset blocked-resolver "$N" 540)"
  if [ "$O" -lt 0 ] || [ "$O" -ge 540 ] || [ $((O % 60)) -lt 5 ] || [ $((O % 60)) -gt 55 ]; then BADOFF="$BADOFF $N=$O"; fi
  [ "$O" = "$(pl_offset merge-sweep "$N" 540)" ] && SAME=$((SAME + 1))
done
[ "$A" = "$B" ] && ok || bad "R4: stable (first:$A second:$B)"
[ -z "$BADOFF" ] && ok || bad "R4: inside [0,540) and 5-55 s past a minute:$BADOFF"
MINS=$(for O in $A; do echo $((O / 60)); done | sort | uniq -c | sort -rn)
[ "$(printf '%s\n' "$MINS" | grep -c .)" -ge 6 ] && ok || bad "R4: 20 projects over at least 6 of 9 minutes: $(printf '%s' "$MINS" | tr '\n' ' ')"
[ "$(printf '%s\n' "$MINS" | awk 'NR == 1 {print $1}')" -le 5 ] && ok || bad "R4: no minute starts more than 5: $(printf '%s' "$MINS" | tr '\n' ' ')"
[ "$SAME" -le 2 ] && ok || bad "R4: the lane is part of the key: $SAME of 20 projects got the same offset on two lanes"
[ "$(pl_offset blocked-resolver cromford 0)" = 0 ] && ok || bad "R4: a period of 0 starts at once"
[ "$(pl_offset blocked-resolver cromford 45)" -lt 45 ] && ok || bad "R4: a period under a minute still bounds the offset"

# ============================================================================
# R5. EACH RUN READS GITHUB AS ITS PROJECT.
# ============================================================================
CLEAN; FLEET 3
pl_dispatch fakelane 0 "$H/bin/fake-lane.sh" >/dev/null
WAITFOR '[ "$(NDONE)" -ge 3 ]' || bad "R5 setup: runs did not finish"
[ "$(COL p2 6)" = fixture-default-token ] && ok || bad "R5: with no App on the box GH_TOKEN is unchanged (p2: $(COL p2 6))"
CLEAN
printf '# fixture: no real App key\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
pl_dispatch fakelane 0 "$H/bin/fake-lane.sh" >/dev/null
WAITFOR '[ "$(NDONE)" -ge 3 ]' || bad "R5 setup: runs did not finish"
[ "$(COL p1 6)" = ghs_fixture_o_p1 ] && [ "$(COL p2 6)" = ghs_fixture_o_p2 ] && [ "$(COL p3 6)" = ghs_fixture_o_p3 ] && ok \
  || bad "R5: each run carries its own repo's token (p1=$(COL p1 6) p2=$(COL p2 6) p3=$(COL p3 6))"
rm -f "$H/env/github-app.env" "$H/bin/gh-token.sh"

# ============================================================================
# R6. THE ENVIRONMENT AND THE STATE DIR.
# ============================================================================
[ "$(COL p2 2)" = fakelane ] && [ "$(COL p2 3)" = p2 ] && [ "$(COL p2 4)" = o/p2 ] && ok \
  || bad "R6: PL_LANE PL_PROJECT PL_SLUG (p2: $(COL p2 2) $(COL p2 3) $(COL p2 4))"
[ "$(COL p2 5)" = "$H/state/fakelane/p2" ] && [ -d "$H/state/fakelane/p2" ] && ok \
  || bad "R6: PL_STATE_DIR is state/<lane>/<project> and exists ($(COL p2 5))"

# ============================================================================
# R7. A HELD PROJECT GETS NO RUN.
# ============================================================================
CLEAN; FLEET 3
lane_project_held() { [ "$1" = fakelane ] && [ "$2" = p3 ]; }
OUT=$(pl_dispatch fakelane 0 "$H/bin/fake-lane.sh")
unset -f lane_project_held
WAITFOR '[ "$(NDONE)" -ge 2 ]' || bad "R7 setup: runs did not finish"
case "$OUT" in *"started 2 project run(s)"*", 1 held:"*) ok ;; *) bad "R7: the summary counts the held project: $OUT" ;; esac
grep -q '^p3$' "$T/done.txt" && bad "R7: p3 is held and must not run" || ok
pl_dispatch 'bad lane' 0 "$H/bin/fake-lane.sh" >/dev/null 2>&1; [ $? = 2 ] && ok || bad "R7: a lane name that is not a name is refused"

echo "project-lanes.bh-5913: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
