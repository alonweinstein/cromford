#!/bin/bash
# tests/resolver-cron-hygiene-test.sh — the blocked-resolver cron tick is
# single-flighted, and its scan does not spew into a closed pipe (BH-642 fix 3).
#
# WHAT WENT WRONG. Resolver cron instances stacked — several live at once,
# rescanning the same parks — and logs/blocked-resolver-cron.log filled with
# ~33k `printf: write error: Broken pipe` lines. The pipe is the main loop's
# `done < <(br_candidates)`: the loop `break`s at BR_PER_TICK while
# br_candidates is still walking every build record, the read end closes, and
# with SIGPIPE ignored (which is how cron launches this) every remaining printf
# reports EPIPE instead of dying quietly.
#
# THE SHAPE OF THE FIX THIS PINS:
#   A  a second tick, while the first is scanning, exits immediately with ONE
#      line and takes no rung. (And the same tick, with the lock free, acts.)
#   B  the lock is released BEFORE any rung runs, and no child of a rung holds
#      it — "never hold a lock across a build" (the operator, 2026-09-13). A stub the
#      rung invokes probes the lock and must find it FREE, and a detached child
#      the rung leaves behind must not keep it after the tick exits.
#   C  a short read at the per-tick cap spews nothing. This was the
#      REPRODUCTION for BH-642 (at its merge base the case printed a
#      Broken-pipe line per record); BH-980 shipped the fix on main by reading
#      the candidate list once into an array instead of through a process
#      substitution, and this case is what keeps a pipe from coming back.
#
# Run from anywhere: tests/resolver-cron-hygiene-test.sh   (exit 0 = all pass)
set -uo pipefail
# tests/lib/scratch.sh is not in git yet (#394). Until it lands this suite owns
# its own scratch tree, on ONE line so the source still precedes the first
# mktemp for checks/tests-scratch-only R1.
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

mkdir -p "$T/fakebin"
# gh is answered, never real. Nothing in this suite is about GitHub.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# bin/blocked-resolver.sh reads every decision through bin/lib/gh-rest.sh, which
# talks to \`gh api -i\` and reads anything that is not a status-line envelope as
# rc 75 "GitHub did not answer". Nothing in this suite is about GitHub — its
# records carry no PR — but the envelope is answered anyway so a stray read can
# never turn an assertion here into "the lane deferred".
case "\$*" in
  *"-i -X "*|*"api -i"*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"--json state"*) echo OPEN ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# mkharness <root> <n-build-records> — a scratch HARNESS with n parked build
# records (BUILD_DEAD, aged past the lane's 90-minute floor), each of which is
# one candidate whose rung is REBUILD FRESH.
mkharness() {
  local H="$1" n="$2" i d dirs=""
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
           "$H/state/merge-conductor" "$H/state/build-queue/tproj"
  cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
     "$DIR/bin/box-for.sh" "$H/bin/"
  # The three libs bin/blocked-resolver.sh HARD-requires (it exits 1 without any
  # of them), plus the mc/ modules merge-conductor-lib.sh sources (BH-680), plus
  # the optional heartbeat so the lane runs the same shape it runs in cron.
  cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
     "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
  mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
  # BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
  # missing, so the modules travel with the copy. One helper, one edit when the
  # split moves again.
  # shellcheck source=tests/lib/br-modules.sh
  . "$DIR/tests/lib/br-modules.sh" || return 1
  br_modules_install "$DIR" "$H" || return 1
  [ -r "$DIR/bin/lib/heartbeat.sh" ] && cp "$DIR/bin/lib/heartbeat.sh" "$H/bin/lib/"
  # A box project's re-offer is the D1 `commented` row (bin/lib/comment-mark.sh,
  # BH-2674), so the child the rung shells out to is the ledger write:
  # $H/bin/ledger-put, which records its argv. B swaps it for a probe.
  cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/" || return 1
  printf 'job_ledger_put() { "%s/bin/ledger-put" "$@"; }\n' "$H" > "$H/bin/jobs-client.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ledger.txt"\nexit 0\n' "$H" > "$H/bin/ledger-put"
  chmod +x "$H/bin/"*.sh "$H/bin/ledger-put"
  printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
  : > "$H/env/global.env"
  for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
  done
  for ((i=1; i<=n; i++)); do dirs="$dirs $H/builds/tproj-BH-$i-202609170000"; done
  # shellcheck disable=SC2086
  [ -n "$dirs" ] && mkdir -p $dirs
  for d in $dirs; do printf 'BUILD_DEAD the pool machine died twice\n' > "$d/RESULT"; done
  [ -n "$dirs" ] && touch -d '3 hours ago' "$H"/builds/tproj-BH-*/RESULT
  return 0
}

# ============================================================================
# A. Two overlapping ticks: the second exits immediately, having taken nothing.
# ============================================================================
HA="$T/hA"; mkharness "$HA" 1
RUNA() { ( HARNESS="$HA" FLEET_CONF="$HA/fleet.conf" REPOS_ROOT="$T/repos" \
             bash "$HA/bin/blocked-resolver.sh" tproj >"$T/runA.log" 2>&1 7>&- ) || true; }

# The "first tick" is this shell holding the lane's own lock. Since BH-5913 a
# one-project run (`blocked-resolver.sh tproj`, the unit the dispatcher starts)
# locks its project, locks/blocked-resolver-tproj.lock, not the fleet's.
exec 7>"$HA/locks/blocked-resolver-tproj.lock"
flock -n 7 && ok || bad "A: the test could not take the lock it is about to contend for"
RUNA
grep -q 'another tick is live' "$T/runA.log" && ok \
  || bad "A: the second tick must say it is exiting without a scan, got: $(cat "$T/runA.log")"
[ "$(wc -l < "$T/runA.log")" = 1 ] && ok || bad "A: one line, not a page: $(cat "$T/runA.log")"
[ ! -s "$HA/logs/blocked-resolver.log" ] && ok \
  || bad "A: the blocked tick must take no rung, log: $(cat "$HA/logs/blocked-resolver.log")"
[ -z "$(ls "$HA/state/blocked-resolver/tproj" 2>/dev/null)" ] && ok \
  || bad "A: the blocked tick must move no counter"
[ ! -s "$HA/ledger.txt" ] && ok || bad "A: the blocked tick must re-offer nothing ($(cat "$HA/ledger.txt"))"

# Released — the SAME tick now acts. Without this half, A would pass on a lane
# that is simply broken.
flock -u 7; exec 7>&-
RUNA
grep -q 'REBUILD FRESH' "$HA/logs/blocked-resolver.log" 2>/dev/null && ok \
  || bad "A: with the lock free the tick must act, log: $(cat "$HA/logs/blocked-resolver.log" 2>/dev/null)"

# ============================================================================
# B. The lock is free while a rung's child runs, and nothing inherits it.
# ============================================================================
HB="$T/hB"; mkharness "$HB" 1
# The rung's child. It is what br_enqueue_fresh shells out to (the re-offer's
# `commented` row write), so it runs INSIDE the rung — exactly where a 90-minute
# fix round would be. Every other ledger write is only recorded.
cat > "$HB/bin/ledger-put" <<EOF
#!/bin/bash
[ "\$1" = commented ] || exit 0
flock -n "$HB/locks/blocked-resolver-tproj.lock" true; printf '%s' "\$?" > "$T/probe"
# A detached child of the rung, the shape of the resolver's own setsid launches.
setsid sleep 20 >/dev/null 2>&1 </dev/null &
printf '%s' "\$!" > "$T/sleeper.pid"
exit 0
EOF
chmod +x "$HB/bin/ledger-put"
( HARNESS="$HB" FLEET_CONF="$HB/fleet.conf" REPOS_ROOT="$T/repos" \
    bash "$HB/bin/blocked-resolver.sh" tproj >"$T/runB.log" 2>&1 ) || true
grep -q 'REBUILD FRESH' "$HB/logs/blocked-resolver.log" 2>/dev/null && ok \
  || bad "B: the rung must have run at all, log: $(cat "$HB/logs/blocked-resolver.log" 2>/dev/null)"
[ "$(cat "$T/probe" 2>/dev/null)" = 0 ] && ok \
  || bad "B: the cron lock must be FREE while the rung's child runs, probe rc=$(cat "$T/probe" 2>/dev/null)"
SPID=$(cat "$T/sleeper.pid" 2>/dev/null)
kill -0 "${SPID:-0}" 2>/dev/null && ok || bad "B: the detached child should still be alive for this check"
flock -n "$HB/locks/blocked-resolver-tproj.lock" true && ok \
  || bad "B: a detached child must not keep the lane's lock after the tick exits"
[ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null

# ============================================================================
# C. THE REPRODUCTION. Short read at the per-tick cap, SIGPIPE ignored the way
#    cron runs this: the scan must not spew a Broken-pipe line per record.
# ============================================================================
HC="$T/hC"; mkharness "$HC" 300
# The spew used to OUTLIVE the tick: with the scan in a process substitution the
# tick exited while the writer was still walking records and reporting EPIPE into
# the same cron log. So the log is read once it stops growing, not the instant the
# tick returns — otherwise a regression that brought the pipe back would "pass"
# here on a race rather than fail on the fix.
settle() { local f="$1" a=-1 b i
  for ((i=0; i<60; i++)); do b=$(wc -c <"$f" 2>/dev/null || echo 0); [ "$b" = "$a" ] && return 0; a="$b"; sleep 0.5; done
  return 0; }
( trap '' PIPE
  HARNESS="$HC" FLEET_CONF="$HC/fleet.conf" REPOS_ROOT="$T/repos" \
    BR_PER_TICK=1 bash "$HC/bin/blocked-resolver.sh" tproj >"$T/runC.log" 2>&1 )
CRC=$?
settle "$T/runC.log"
SPEW=$(grep -c 'Broken pipe' "$T/runC.log" 2>/dev/null || true)
[ "${SPEW:-0}" -eq 0 ] && ok || bad "C: a short read must not spew — $SPEW 'Broken pipe' lines in the cron log"
[ "$CRC" -eq 0 ] && ok || bad "C: the tick must still exit 0, got rc=$CRC"
ACTED=$(grep -c 'REBUILD FRESH' "$HC/logs/blocked-resolver.log" 2>/dev/null || true)
[ "${ACTED:-0}" -eq 1 ] && ok || bad "C: exactly one key may act at BR_PER_TICK=1, got $ACTED"
# And the scan leaves no scratch file behind in the lane's state dir: today it
# writes none at all, and a future one that does must clean up after itself.
[ -z "$(ls "$HC/state/blocked-resolver"/.candidates.* 2>/dev/null)" ] && ok \
  || bad "C: the materialized candidate file must be removed: $(ls "$HC/state/blocked-resolver"/.candidates.* 2>/dev/null)"

echo "resolver-cron-hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
