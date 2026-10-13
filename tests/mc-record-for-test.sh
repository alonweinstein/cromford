#!/bin/bash
# tests/mc-record-for-test.sh — mc_record_for must find a PR's build record in
# ONE pass over builds/, not one `head` + one `grep` per build directory.
#
# THE DEFECT THIS CLOSES (hub, 2026-09-16 16:00Z). The hub carried 1,893 build
# directories. Every conductor worker called mc_record_for for its PR, and the
# lookup forked `head -1` and `grep` for EACH directory — ~3,700 process spawns
# per PR per tick — while the box sat at load 184. The `ps` leaves under the
# oldest tick were nothing but `head -1 builds/pool-project-5-TK-731-…/RESULT`;
# ticks took 390s, every later tick found the PR locks still held, and the
# TICK line read prs=19 locked=17 merges=0 for an hour.
#
# WHY DRIVEN. The contract is the same as before: glob order (pool-* first,
# then the rest), first-line-only match on `PR_CREATED https://…<url>`, rc 1
# with no output when nothing names the PR. What changes is the cost, so the
# last case counts the processes the lookup forks under a large fixture and
# fails if the count grows with the number of directories.
# Run from anywhere: tests/mc-record-for-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"; mkdir -p "$HARNESS/builds" "$HARNESS/logs" "$HARNESS/state"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"

URL=https://github.com/example-org/project-5/pull/1634
mk() { mkdir -p "$HARNESS/builds/$1"; printf '%s\n' "$2" > "$HARNESS/builds/$1/RESULT"; }

# 1. nothing names the PR → rc 1, empty output
mk project-5-TK-1-1 "PR_CREATED https://github.com/example-org/project-5/pull/1 opened"
out=$(mc_record_for "$URL"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "no record → rc 1 and no output (rc=$rc out=$out)"

# 2. a plain record names it
mk project-5-TK-1602-2 "PR_CREATED $URL opened"
out=$(mc_record_for "$URL") && [ "$out" = "$HARNESS/builds/project-5-TK-1602-2" ] \
  && ok || bad "the plain build dir that names the PR is returned (got: $out)"

# 3. a pool record wins over a plain one (glob order: pool-* first)
mk pool-project-5-TK-1602-3 "PR_CREATED $URL opened"
out=$(mc_record_for "$URL") && [ "$out" = "$HARNESS/builds/pool-project-5-TK-1602-3" ] \
  && ok || bad "a pool-* record is preferred over a plain one (got: $out)"

# 4. only the FIRST line counts, and only a PR_CREATED line
mk project-5-TK-1602-4 "BUILD_DEAD
PR_CREATED $URL opened"
scratch_rm "$HARNESS/builds/pool-project-5-TK-1602-3"; scratch_rm "$HARNESS/builds/project-5-TK-1602-2"
out=$(mc_record_for "$URL"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "a PR_CREATED line below the first is not a record (rc=$rc out=$out)"
mk project-5-TK-1602-5 "COMMENTED $URL"
out=$(mc_record_for "$URL"); rc=$?
[ "$rc" = 1 ] && ok || bad "a non-PR_CREATED first line is not a record (got: $out)"

# 5. a RESULT-less dir and a dir without the -<n> shape are skipped, not fatal
mkdir -p "$HARNESS/builds/project-5-TK-1602-6" "$HARNESS/builds/noresult"
mk project-5-TK-1602-7 "PR_CREATED $URL opened"
out=$(mc_record_for "$URL") && [ "$out" = "$HARNESS/builds/project-5-TK-1602-7" ] \
  && ok || bad "empty dirs are skipped and the record is still found (got: $out)"

# 6. COST: forks must not scale with the number of build dirs
for i in $(seq 1 1500); do mk "other-X-$i-$i" "PR_CREATED https://github.com/example-org/other/pull/$i opened"; done
# the record sits AFTER the 1,500 others in glob order (no pool-* dir exists now)
count_forks() {  # subshell-spawn count of one lookup via bash's own child accounting
  # Count processes by tracing with a wrapper PATH: every external binary the
  # function execs is recorded once.
  local W="$T/w"; mkdir -p "$W"; : > "$T/forks"
  for b in head grep awk ls xargs find cat sed; do
    printf '#!/bin/bash\necho %s >> %q\nexec /usr/bin/%s "$@"\n' "$b" "$T/forks" "$b" > "$W/$b"
    [ -x "/usr/bin/$b" ] || printf '#!/bin/bash\necho %s >> %q\nexec %s "$@"\n' "$b" "$T/forks" "$(command -v $b)" > "$W/$b"
    chmod +x "$W/$b"
  done
  PATH="$W:$PATH" mc_record_for "$URL" >/dev/null
  wc -l < "$T/forks" | tr -d ' '
}
n=$(count_forks)
out=$(mc_record_for "$URL")
[ "$out" = "$HARNESS/builds/project-5-TK-1602-7" ] && ok || bad "the record is found among 1,500 others (got: $out)"
[ "$n" -le 8 ] && ok || bad "one lookup over 1,507 build dirs forked $n external processes — must be a single pass (≤8), not one per directory"

echo "mc-record-for-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
