#!/bin/bash
# tests/mrb-probe.bh-3685-test.sh — the three bodies of bin/lib/mrb-probe.sh
# (BH-3694, split child 2 of 5 of BH-3685): which suites a CI log names red
# (A6), the bounded bisect over a fake probe (A7), and the snapshot probe
# against a scratch repo (A10). The name is the one the ticket gives (bh-3685,
# the parent), like the contract suite.
#
# No network, no clock: every commit date derives from one NOW.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-probe.bh-3685-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/../bin/lib/mrb-probe.sh" || exit 1
LIB="$(cd "$(dirname "$0")/.." && pwd)/bin/lib/mrb-probe.sh"
NOW=1790000000
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }

# ── A6: mrb_suites_from_log ──────────────────────────────────────────────────
# A6.1 GitHub timestamp prefix, CRLF, duplicates, unsorted
out=$(printf '%s\r\n' \
  '2026-09-30T18:30:29.0761234Z --- tests/b.sh rc=1' \
  '--- tests/a.sh rc=2' \
  '2026-09-30T18:30:30.0000000Z --- tests/b.sh rc=1' \
  '2026-09-30T18:30:31.0000000Z boom' | mrb_suites_from_log); rc=$?
eq "A6.1 rc" "$rc" 0
eq "A6.1 output" "$out" "$(printf 'tests/a.sh\ntests/b.sh')"

# A6.2 negatives: rc=0, HIT trace, not under tests/, not anchored
out=$(printf '%s\n' \
  '2026-09-30T18:30:29.0761234Z --- tests/c.sh rc=0' \
  'HIT tests/d.sh 3' \
  '2026-09-30T18:30:29.0761234Z HIT tests/d.sh 3' \
  '--- lib/e.sh rc=1' \
  'x--- tests/f.sh rc=1' | mrb_suites_from_log); rc=$?
eq "A6.2 rc" "$rc" 0
eq "A6.2 output" "$out" ""
out=$(printf 'HIT tests/a.sh 1\nHIT tests/b.sh 2\n' | mrb_suites_from_log); rc=$?
eq "A6.2 HIT-only rc" "$rc" 0
eq "A6.2 HIT-only output" "$out" ""

# A6.3 a large writer under pipefail never takes SIGPIPE
( set -o pipefail; awk 'BEGIN{for(i=0;i<200000;i++)print "2026-09-30T18:30:29.0761234Z --- tests/a.sh rc=1"}' \
    | mrb_suites_from_log >/dev/null ); rc=$?
eq "A6.3 pipefail large log rc" "$rc" 0

# ── A7: mrb_bisect over a fake probe ─────────────────────────────────────────
# PAT is one letter per candidate c1..cN: R red, G green, N norun, E empty.
# Every call is counted in $T/calls, so the step count is checked twice.
fp() {
  echo "$1" >> "$T/calls"
  local i=${1#c}
  case "${PAT:i-1:1}" in
    R) echo red ;; G) echo green ;; N) echo norun ;; *) ;;
  esac
}
cands() { local i; for ((i = 1; i <= $1; i++)); do printf 'c%d ' "$i"; done; }
calls() { if [ -f "$T/calls" ]; then wc -l < "$T/calls" | tr -d ' '; else echo 0; fi; }
bis() { : > "$T/calls"; mrb_bisect fp "$@"; }

# A7.1 first red at each position 1..8, monotonic
declare -A K=([1]=3 [2]=3 [3]=3 [4]=3 [5]=3 [6]=3 [7]=3 [8]=3)
for p in 1 2 3 4 5 6 7 8; do
  PAT=""; for ((i = 1; i <= 8; i++)); do if [ "$i" -ge "$p" ]; then PAT+=R; else PAT+=G; fi; done
  # shellcheck disable=SC2046
  out=$(bis 8 $(cands 8)); rc=$?
  eq "A7.1 p=$p rc" "$rc" 0
  eq "A7.1 p=$p" "$out" "found c$p ${K[$p]}"
  eq "A7.1 p=$p probe calls" "$(calls)" "${K[$p]}"
done

# A7.2 norun at the first midpoint (c4), then at the second (c6 when c4 is green)
PAT=GGGNRRRR;  out=$(bis 8 c1 c2 c3 c4 c5 c6 c7 c8); eq "A7.2 norun c4" "$out" "aborted c4 1"
PAT=GGGGGNRR;  out=$(bis 8 c1 c2 c3 c4 c5 c6 c7 c8); eq "A7.2 norun c6" "$out" "aborted c6 2"
eq "A7.2 probe calls" "$(calls)" 2

# A7.3 budget below log2(8): bounded (lo, hi]; budget 0 probes nothing
PAT=GGRRRRRR;  out=$(bis 2 c1 c2 c3 c4 c5 c6 c7 c8); eq "A7.3 budget 2" "$out" "bounded c2 c4 2"
eq "A7.3 budget 2 calls" "$(calls)" 2
out=$(bis 0 c1 c2 c3 c4 c5 c6 c7 c8); eq "A7.3 budget 0" "$out" "bounded - c8 0"
eq "A7.3 budget 0 calls" "$(calls)" 0

# A7.4 red, green again, red: the first red is still found
PAT=GRGR;      out=$(bis 8 c1 c2 c3 c4); eq "A7.4 GRGR" "$out" "found c2 2"

# A7.5 garbage and edges
PAT=GGGERRRR;  out=$(bis 8 c1 c2 c3 c4 c5 c6 c7 c8); eq "A7.5 empty probe answer" "$out" "aborted c4 1"
out=$(bis x c1 c2 c3); eq "A7.5 non-numeric budget" "$out" "aborted - 0"
eq "A7.5 non-numeric budget calls" "$(calls)" 0
out=$(bis -1 c1 c2 c3); eq "A7.5 negative budget" "$out" "aborted - 0"
out=$(bis 8); eq "A7.5 no candidates" "$out" "aborted - 0"
out=$(bis 8 c1); eq "A7.5 N=1" "$out" "found c1 0"
eq "A7.5 N=1 calls" "$(calls)" 0
# a probe that fails under the caller's errexit is an abort, not a dead caller
failp() { return 1; }
out=$(set -e; mrb_bisect failp 8 c1 c2 c3); eq "A7.5 failing probe under set -e" "$out" "aborted c1 1"

# ── A10: mrb_probe against a scratch repo ────────────────────────────────────
R="$T/repo"; mkdir -p "$R/tests"
g() { GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000" \
      git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g init -q
echo 'exit 0' > "$R/tests/x.sh"
echo '[ -z "${HARNESS_TEST_SANDBOX:-}" ] && [ -n "${TMPDIR:-}" ] && [ "$TMPDIR" != /tmp ]' > "$R/tests/env.sh"
g add -A; g commit -qm A; A=$(g rev-parse HEAD)
echo 'exit 1' > "$R/tests/x.sh"; echo 'exit 0' > "$R/tests/y.sh"
g add -A; g commit -qm B; B=$(g rev-parse HEAD)
printf '%s\n' 'exec sleep 30' > "$R/tests/z.sh"   # determinism: ok the suite under test must hang so the probe's timeout fires
g add -A; g commit -qm C; C=$(g rev-parse HEAD)
printf 'tests/x.sh\n' > "$T/x.list"
printf 'tests/y.sh\n' > "$T/y.list"
printf 'tests/z.sh\n' > "$T/z.list"
printf 'tests/env.sh\n' > "$T/env.list"
printf '' > "$T/empty.list"
printf 'lib/x.sh\n../tests/x.sh\ntests/../x.sh\n-x\n' > "$T/junk.list"

before=$(ls -d /tmp/mrb-* 2>/dev/null | LC_ALL=C sort)

# A10.1 green at A, red at B
out=$(MRB_RUNNER=local mrb_probe "$R" "$A" "$T/x.list" 2>/dev/null); rc=$?
eq "A10.1 A rc" "$rc" 0
eq "A10.1 A" "$out" green
out=$(MRB_RUNNER=local mrb_probe "$R" "$B" "$T/x.list" 2>"$T/err"); rc=$?
eq "A10.1 B rc" "$rc" 0
eq "A10.1 B" "$out" red
grep -q "mrb-probe: ${B:0:7} tests/x.sh rc=1" "$T/err" && ok || bad "A10.1 B stderr names the red suite: $(cat "$T/err")"
# a short sha resolves too
out=$(MRB_RUNNER=local mrb_probe "$R" "${A:0:7}" "$T/x.list" 2>/dev/null); eq "A10.1 short sha" "$out" green

# A10.2 unknown sha, option-shaped sha, nothing to run
out=$(MRB_RUNNER=local mrb_probe "$R" 0123456789abcdef0123456789abcdef01234567 "$T/x.list" 2>/dev/null); rc=$?
eq "A10.2 unknown sha rc" "$rc" 0
eq "A10.2 unknown sha" "$out" norun
out=$(MRB_RUNNER=local mrb_probe "$R" 0123456789abcdef0123456789abcdef01234567 "$T/x.list" 2>&1 >/dev/null)
case "$out" in *"is not a commit"*) ok ;; *) bad "A10.2 unknown sha reason: [$out]" ;; esac
out=$(MRB_RUNNER=local mrb_probe "$R" -x "$T/x.list" 2>/dev/null); eq "A10.2 -x" "$out" norun
out=$(MRB_RUNNER=local mrb_probe "$R" "$A" "$T/empty.list" 2>/dev/null); eq "A10.2 empty suites" "$out" norun
out=$(MRB_RUNNER=local mrb_probe "$R" "$A" "$T/junk.list" 2>/dev/null); eq "A10.2 junk suites" "$out" norun
out=$(MRB_RUNNER=local mrb_probe "$R" "$A" "$T/nope.list" 2>/dev/null); eq "A10.2 missing suites file" "$out" norun
out=$(MRB_RUNNER=local mrb_probe "$T/not-a-repo" "$A" "$T/x.list" 2>/dev/null); eq "A10.2 not a repo" "$out" norun

# A10.3 a suite that does not exist at that sha is red (bash rc 127)
out=$(MRB_RUNNER=local mrb_probe "$R" "$A" "$T/y.list" 2>"$T/err"); eq "A10.3 missing suite" "$out" red
grep -q 'tests/y.sh rc=127' "$T/err" && ok || bad "A10.3 stderr rc=127: $(cat "$T/err")"
out=$(MRB_RUNNER=local mrb_probe "$R" "$B" "$T/y.list" 2>/dev/null); eq "A10.3 present at B" "$out" green

# A10.4 a hung suite is red and logged as a timeout
out=$(MAIN_RED_BISECT_SUITE_TIMEOUT_S=1 MRB_RUNNER=local mrb_probe "$R" "$C" "$T/z.list" 2>"$T/err"); rc=$?
eq "A10.4 rc" "$rc" 0
eq "A10.4 timeout" "$out" red
grep -q 'tests/z.sh rc=124 timeout after 1s' "$T/err" && ok || bad "A10.4 stderr timeout: $(cat "$T/err")"

# A10.7 the suite never sees HARNESS_TEST_SANDBOX (this test runs with it set)
out=$(HARNESS_TEST_SANDBOX=1 MRB_RUNNER=local mrb_probe "$R" "$A" "$T/env.list" 2>/dev/null)
eq "A10.7 clean env" "$out" green

# the probe's EXIT trap is its own: a caller's trap survives it
out=$(trap 'echo caller-trap' EXIT; MRB_RUNNER=local mrb_probe "$R" "$A" "$T/x.list" 2>/dev/null)
eq "A10 caller trap kept" "$out" "$(printf 'green\ncaller-trap')"
# under the caller's errexit and nounset a red is still one word, rc 0
out=$(set -eu; MRB_RUNNER=local mrb_probe "$R" "$B" "$T/x.list" 2>/dev/null); rc=$?
eq "A10 set -eu red rc" "$rc" 0
eq "A10 set -eu red" "$out" red

# A10.6 the default (isolated) runner
if [ "$(id -u)" -eq 0 ]; then
  out=$(mrb_probe "$R" "$A" "$T/x.list" 2>"$T/err"); eq "A10.6 root isolated A" "$out" green
  [ "$out" = green ] || cat "$T/err"
  out=$(mrb_probe "$R" "$B" "$T/x.list" 2>/dev/null); eq "A10.6 root isolated B" "$out" red
  out=$(HARNESS_TEST_SANDBOX=1 mrb_probe "$R" "$A" "$T/env.list" 2>/dev/null); eq "A10.6 root isolated clean env" "$out" green
  # a runner that cannot switch (a container without CAP_SETUID) is norun,
  # never red: the switch is asked first, with the run's own flags (#1541 C1)
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/setpriv" <<'SH'
#!/bin/bash
exit 1
SH
  cat > "$T/fakebin/setpriv-late" <<'SH'
#!/bin/bash
# passes the switch check, then dies before the suites run
[ "${!#}" = true ] && exit 0
exit 126
SH
  chmod +x "$T/fakebin/setpriv" "$T/fakebin/setpriv-late"
  out=$(PATH="$T/fakebin:$PATH" mrb_probe "$R" "$B" "$T/x.list" 2>"$T/err"); eq "A10.6 setpriv cannot switch" "$out" norun
  grep -q 'cannot switch' "$T/err" && ok || bad "A10.6 cannot-switch reason: $(cat "$T/err")"
  mkdir -p "$T/fakebin2"; cp "$T/fakebin/setpriv-late" "$T/fakebin2/setpriv"
  out=$(PATH="$T/fakebin2:$PATH" mrb_probe "$R" "$B" "$T/x.list" 2>/dev/null); eq "A10.6 runner dies after the check" "$out" norun
  # the same probe as a non-root caller cannot switch users: norun, never red
  chmod -R a+rX "$T"
  out=$(setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups \
    env -i PATH="$PATH" HOME=/tmp GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
    bash -c '. "$1"; mrb_probe "$2" "$3" "$4"' _ "$LIB" "$R" "$B" "$T/x.list" 2>"$T/err")
  eq "A10.6 non-root isolated" "$out" norun
  grep -q 'setpriv' "$T/err" && ok || bad "A10.6 non-root reason names setpriv: $(cat "$T/err")"
else
  out=$(mrb_probe "$R" "$B" "$T/x.list" 2>"$T/err"); eq "A10.6 non-root isolated" "$out" norun
  grep -q 'setpriv' "$T/err" && ok || bad "A10.6 non-root reason names setpriv: $(cat "$T/err")"
fi

# A10.5 every probe removed its own /tmp/mrb- dir
after=$(ls -d /tmp/mrb-* 2>/dev/null | LC_ALL=C sort)
eq "A10.5 no /tmp/mrb- left behind" "$after" "$before"

echo "mrb-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
