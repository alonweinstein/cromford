#!/bin/bash
# tests/ci-apt-update.bh-2128-test.sh — BH-2128: A MIRROR MID-SYNC RETRIES,
# AND AN APT FAILURE READS AS INFRA, NEVER AS A TEST FAILURE.
#
# Runs 36029556164 / 36029663354 died in `sudo apt-get update` with "File has
# unexpected size (46392 != 46384). Mirror sync in progress?" — one attempt,
# under set -e, inside the step that runs the corpus, so the shard read as a
# red test run.
#
#   A  bin/ci-apt-update.sh through its own CLI, against stub sudo/apt-get/sleep:
#      A1 one clean call carries -o Acquire::Retries=3 update
#      A2 fail-then-pass is rc 0 after exactly two calls, with a warning
#      A3 fail-fail is apt's own rc after exactly two calls (no loop), ::error
#      A4 a non-integer CI_APT_RETRY_DELAY_S is rc 2 and apt is never called
#      A5 the default back-off is 20 s
#   B  .github/workflows/harness-ci.yml, the production entry point:
#      B1 every apt-get update goes through the helper, inside an install step
#      B2 every apt-installing step is named `infra:`, precedes the step that
#         runs the corpus, and no corpus step runs apt at all
#      B3 anti-vacuity: the reader saw the install steps it claims to check
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$DIR/bin/ci-apt-update.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── A. the helper ───────────────────────────────────────────────────────────
# stubs <dir> <fail-first-K> — sudo execs its argv; apt-get logs argv to
# calls.log and fails its first K calls with rc 100 and the mirror-sync text;
# sleep logs its argument and returns at once.
stubs() {
  mkdir -p "$1"; : > "$1/calls.log"; : > "$1/sleep.log"; echo 0 > "$1/n"
  printf '#!%s\nexec "$@"\n' "$BASH_BIN" > "$1/sudo"
  cat > "$1/apt-get" <<SH
#!$BASH_BIN
printf '%s\n' "\$*" >> "$1/calls.log"
n=\$(( \$(cat "$1/n") + 1 )); echo "\$n" > "$1/n"
if [ "\$n" -le $2 ]; then
  echo "E: Failed to fetch ... File has unexpected size (46392 != 46384). Mirror sync in progress?" >&2
  exit 100
fi
exit 0
SH
  printf '#!%s\nprintf "%%s\\n" "$*" >> "%s/sleep.log"\n' "$BASH_BIN" "$1" > "$1/sleep"
  chmod +x "$1/sudo" "$1/apt-get" "$1/sleep"
}
run_helper() { # run_helper <dir> [env assignments...] -> rc on stdout
  local d="$1"; shift
  env "$@" PATH="$d:$PATH" "$BASH_BIN" "$HELPER" >"$d/out" 2>&1; echo $?
}
calls() { wc -l < "$1/calls.log" | tr -d ' '; }

[ -x "$HELPER" ] && ok || bad "A0: $HELPER must exist and be executable"

stubs "$T/a1" 0
RC=$(run_helper "$T/a1")
[ "$RC" = 0 ] && ok || bad "A1: a clean update must be rc 0 (got $RC: $(cat "$T/a1/out"))"
[ "$(calls "$T/a1")" = 1 ] && ok || bad "A1: a clean update is exactly one apt call (got $(calls "$T/a1"))"
grep -qx -- '-o Acquire::Retries=3 update -q' "$T/a1/calls.log" \
  && ok || bad "A1: apt must be called as '-o Acquire::Retries=3 update -q' (calls: $(cat "$T/a1/calls.log"))"
grep -q '::warning' "$T/a1/out" && bad "A1: a clean update must not warn ($(cat "$T/a1/out"))" || ok

stubs "$T/a2" 1
RC=$(run_helper "$T/a2" CI_APT_RETRY_DELAY_S=0)
[ "$RC" = 0 ] && ok || bad "A2: fail-then-pass must be rc 0 (got $RC: $(cat "$T/a2/out"))"
[ "$(calls "$T/a2")" = 2 ] && ok || bad "A2: fail-then-pass is exactly two apt calls (got $(calls "$T/a2"))"
grep -q '^::warning title=CI infra (apt)::' "$T/a2/out" \
  && ok || bad "A2: a retried update must print a '::warning title=CI infra (apt)::' line (got: $(cat "$T/a2/out"))"
grep -qx 0 "$T/a2/sleep.log" && ok || bad "A2: the back-off must use CI_APT_RETRY_DELAY_S (sleep got: $(cat "$T/a2/sleep.log"))"

stubs "$T/a3" 2
RC=$(run_helper "$T/a3" CI_APT_RETRY_DELAY_S=0)
[ "$RC" = 100 ] && ok || bad "A3: fail-fail must exit with apt's own rc 100 (got $RC: $(cat "$T/a3/out"))"
[ "$(calls "$T/a3")" = 2 ] && ok || bad "A3: fail-fail is exactly two apt calls, never a loop (got $(calls "$T/a3"))"
grep -q '^::error title=CI infra (apt)::' "$T/a3/out" \
  && ok || bad "A3: a second failure must print a '::error title=CI infra (apt)::' line (got: $(cat "$T/a3/out"))"
grep -q 'Mirror sync in progress' "$T/a3/out" \
  && ok || bad "A3: apt's own stderr must stay visible (got: $(cat "$T/a3/out"))"

for BADV in abc '' -5 1.5 '20 '; do
  stubs "$T/a4" 0
  RC=$(run_helper "$T/a4" "CI_APT_RETRY_DELAY_S=$BADV")
  [ "$RC" = 2 ] && ok || bad "A4: CI_APT_RETRY_DELAY_S='$BADV' must be rc 2 (got $RC: $(cat "$T/a4/out"))"
  [ "$(calls "$T/a4")" = 0 ] && ok || bad "A4: CI_APT_RETRY_DELAY_S='$BADV' must never reach apt (calls: $(cat "$T/a4/calls.log"))"
done

stubs "$T/a5" 1
RC=$(env -u CI_APT_RETRY_DELAY_S PATH="$T/a5:$PATH" "$BASH_BIN" "$HELPER" >"$T/a5/out" 2>&1; echo $?)
[ "$RC" = 0 ] && ok || bad "A5: fail-then-pass with no env must be rc 0 (got $RC: $(cat "$T/a5/out"))"
grep -qx 20 "$T/a5/sleep.log" && ok || bad "A5: the default back-off must be 20 s (sleep got: '$(cat "$T/a5/sleep.log")')"

# ── B. the workflow ─────────────────────────────────────────────────────────
# steps -> "<job>\t<step#>\t<line>" for every non-comment line inside a step,
# plus "<job>\t<step#>\t@name <name>" for the step's name. Same reader shape as
# job_steps in tests/ci-pyyaml.bh-1741-test.sh, across every job.
steps() {
  awk '
    /^jobs:/ { injobs = 1; next }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); n = 0; next }
    /^[[:space:]]*#/ { next }
    /^      - / { n++ }
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/^- /, "", line)
      if (line ~ /^name:[[:space:]]/ && $0 ~ /^      (- |  )name:/) {
        nm = line; sub(/^name:[[:space:]]*/, "", nm); gsub(/^"|"$/, "", nm)
        if (n) print job "\t" n "\t@name " nm
        next }
      if (n && job != "") print job "\t" n "\t" line }' "$WF"
}
S=$(steps)

# B1: the helper is the only way apt-get update runs.
RAW=$(grep -nE '^[^#]*apt-get[^#]*update' "$WF")
[ -z "$RAW" ] && ok || bad "B1: no workflow line may run apt-get update directly (found: $RAW)"
SITES=$(printf '%s\n' "$S" | awk -F'\t' '$3 == "bin/ci-apt-update.sh"' | wc -l | tr -d ' ')
[ "$SITES" = 3 ] && ok || bad "B1: expected exactly 3 'bin/ci-apt-update.sh' call sites (got $SITES)"
# Each call site is followed, on the next line of the same step, by the
# apt-get install it refreshes the index for.
BAD1=$(printf '%s\n' "$S" | awk -F'\t' '
  pend != "" { if (!($1 SUBSEP $2 == pend && $3 ~ /apt-get install/)) print pj " step " pn; pend = "" }
  $3 == "bin/ci-apt-update.sh" { pend = $1 SUBSEP $2; pj = $1; pn = $2 }
  END { if (pend != "") print pj " step " pn }')
[ -z "$BAD1" ] && ok || bad "B1: a helper call is not immediately followed by an apt-get install in its own step: $BAD1"

# B2: every apt-installing step is an infra step, and the corpus steps run no apt.
INST=$(printf '%s\n' "$S" | awk -F'\t' '$3 ~ /apt-get install/ { print $1 "\t" $2 }' | sort -u)
while IFS=$'\t' read -r J N; do
  [ -n "$J" ] || continue
  NM=$(printf '%s\n' "$S" | awk -F'\t' -v j="$J" -v n="$N" '$1 == j && $2 == n && $3 ~ /^@name / { sub(/^@name /, "", $3); print $3; exit }')
  case "$NM" in
    infra:*) ok ;;
    *) bad "B2: $J step $N apt-installs but is named '$NM' — an apt step must be named 'infra: …'" ;;
  esac
done <<< "$INST"
CORPUS=$(printf '%s\n' "$S" | awk -F'\t' '$3 ~ /bin\/test-suite-run\.sh|bin\/test-trace-safety\.sh/ { print $1 "\t" $2 }' | sort -u)
[ -n "$CORPUS" ] && ok || bad "B2: found no step that runs bin/test-suite-run.sh or bin/test-trace-safety.sh"
while IFS=$'\t' read -r J N; do
  [ -n "$J" ] || continue
  grep -q 'apt-get' <<< "$(printf '%s\n' "$S" | awk -F'\t' -v j="$J" -v n="$N" '$1 == j && $2 == n')" \
    && bad "B2: $J step $N runs the corpus AND apt-get — an apt failure there reads as a test failure" || ok
done <<< "$CORPUS"
# tests-shard: the age/zstd/rsync infra step comes before the suite step. (Three
# helper call sites since the CI cost cut, 2026-09-24: the traced shard job is
# the only corpus job, so PyYAML is installed once, not once per lane.)
AGE=$(printf '%s\n' "$S" | awk -F'\t' '$1 == "tests-shard" && $3 ~ /apt-get install/ && $3 ~ / age / { print $2; exit }')
RSY=$(printf '%s\n' "$S" | awk -F'\t' '$1 == "tests-shard" && $3 ~ /apt-get install/ && $3 ~ / rsync / { print $2; exit }')
SUITE=$(printf '%s\n' "$S" | awk -F'\t' '$1 == "tests-shard" && $3 ~ /bin\/test-trace-safety\.sh --gate/ { print $2; exit }')
if [ -n "$AGE" ] && [ -n "$RSY" ] && [ -n "$SUITE" ]; then
  [ "$AGE" -lt "$SUITE" ] && [ "$RSY" -lt "$SUITE" ] && ok \
    || bad "B2: tests-shard must install age/zstd (step $AGE) and rsync (step $RSY) BEFORE the suite (step $SUITE)"
else
  bad "B2: tests-shard is missing the age/zstd install ($AGE), rsync install ($RSY) or suite step ($SUITE)"
fi

# B3: the reader actually saw the steps it judged.
NINST=$(printf '%s\n' "$INST" | grep -c .)
[ "$NINST" -ge 2 ] && ok || bad "B3: the step reader saw only $NINST apt-installing steps (expected >= 2) — it is not reading the workflow"

echo "ci-apt-update: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
