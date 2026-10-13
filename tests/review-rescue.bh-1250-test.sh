#!/bin/bash
# tests/review-rescue.bh-1250-test.sh — the lane must run the gh the CALLER's
# PATH names, not whatever /usr/local/bin happens to hold.
#
# WHY (BH-1250). tests/review-rescue-test.sh was red as root on the Fly test
# host and green everywhere else. The reported cause was a /root/harness path
# leak under HOME=/root; it is not. A host-shaped probe on
# pool-cromford-8d5206feee6028 (2026-09-22: tmpfs /root, a real checkout
# remounted strictatime at /root/harness, both suites run in parallel) showed
# `find /root/harness -anewer <marker>` empty — neither suite reads or writes a
# byte there. Adding a gh to /usr/local/bin inside the same namespace turned the
# suite red with the reported shape (13 fails here, 22 on the host where an
# authenticated gh answered `issue view`/`pr list` for real) and left
# /root/.cache/gh behind: the lane's own
# `export PATH="/usr/local/bin:$PATH"` put /usr/local/bin AHEAD of the caller's
# PATH, so the HOST's gh ran in place of the suite's fake, against
# example-org/project-5.
#
# The line exists because cron's PATH lacks /usr/local/bin (bin/lane-reaper.sh:59
# carries the same line with that comment). So this suite pins BOTH halves: the
# directory is still added, and it is added at the END, where it cannot shadow a
# PATH the caller chose. Deliberately a tiny fixture — the lane's behaviour is
# tests/review-rescue-test.sh's 55 assertions; the only thing asserted here is
# the PATH the lane's first gh actually ran with, read out of that gh itself.
#
# Run from anywhere: tests/review-rescue.bh-1250-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── the fixture harness tree ─────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/review-rescue.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"   # TEST-CHANGE BH-1651: the state read is REST
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"
: > "$H/env/global.env"

# flock and timeout are incidental to what is asserted here (util-linux on the
# hub, absent on a mac), so they are stubbed rather than skipped.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    -*) shift ;;
    [0-9]*) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF

# THE INSTRUMENT. This gh records the PATH it was reached with and answers the
# lane's first call — `gh issue view <n> --json state`, made for a `-`
# board-prefix project before any git command — with CLOSED, so the candidate is
# retired on the spot and the fixture needs no origin and no clone.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$PATH" >> "$T/gh-path.txt"
case "\$*" in
  *"-i -X GET"*"/issues/"*) printf 'HTTP/2 200\r\n\r\n{"state":"closed"}' ;;   # TEST-CHANGE BH-1651: REST state read
esac
exit 0
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout" "$T/fakebin/gh"

# ── one aged candidate ───────────────────────────────────────────────────────
# The candidate scan is `find -mmin +90`, so the RESULT must be aged. LOCAL
# time, deliberately: `touch -t` reads its stamp in local time, so a UTC stamp on
# a box west of Greenwich lands in the FUTURE and -mmin never matches.
ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }
D="$H/builds/pool-project-5-TK-551-202609131444"
mkdir -p "$D"
printf '%s\n' "REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification" > "$D/RESULT"
printf '# pool-project-5-TK-551 — the ticket title from the plan\n\n## Tasks\n' > "$D/plan.md"
touch -t "$(ago 200)" "$D/RESULT"

# ── run the lane, once, through the production entry point ───────────────────
# PATH deliberately WITHOUT /usr/local/bin, so assertion 3 proves the lane still
# adds it. HOME=/root is the condition BH-1250 reported and is harmless here:
# nothing in this fixture reads a path under HOME.
env HOME=/root GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    PATH="$T/fakebin:/usr/bin:/bin" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
    REPOS_ROOT="$T/repos" bash "$H/bin/review-rescue.sh" >>"$T/run.log" 2>&1

# ── 1. the gh that ran was the one on the caller's PATH ──────────────────────
# On a box that has /usr/local/bin/gh the buggy lane never reaches this fake at
# all, and the file is absent.
if [ -s "$T/gh-path.txt" ]; then ok; else
  bad "1: the lane never ran the fake gh on the caller's PATH (run.log: $(tail -3 "$T/run.log" 2>/dev/null))"
fi
P=$(head -1 "$T/gh-path.txt" 2>/dev/null)

# ── 2. the caller's PATH order survived ──────────────────────────────────────
case "$P" in
  "$T/fakebin:"*) ok ;;
  *) bad "2: the lane reordered the caller's PATH — gh ran with PATH='$P', which does not start with $T/fakebin" ;;
esac

# ── 3. …and /usr/local/bin is still on it ────────────────────────────────────
# The line exists for cron, whose PATH lacks /usr/local/bin. The fix appends; it
# must not simply delete.
case ":$P:" in
  *:/usr/local/bin:*) ok ;;
  *) bad "3: the lane no longer adds /usr/local/bin at all — gh ran with PATH='$P'" ;;
esac

# ── 4. the whole tick ran through that gh ────────────────────────────────────
[ -f "$D/.review-rescued" ] && ok \
  || bad "4: the candidate was not retired — the closed-ticket answer from the fake gh never reached the lane"
grep -q 'is closed' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "4: the log must say the ticket is closed (log: $(cat "$H/logs/review-rescue.log" 2>/dev/null))"

echo "$PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
