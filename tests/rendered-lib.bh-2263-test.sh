#!/bin/bash
# tests/rendered-lib.bh-2263-test.sh — a tests/lib/rendered.sh helper that dies
# inside $(...) turns the suite that called it RED.
#
# WHY. Every helper fails through _rendered_die's `exit 1`, and callers run the
# helpers as `REG=$(rendered_registry)`, `"$(rendered_cron_dir)"/*.cron` and so
# on. The exit ended only that subshell: FAIL went to stderr, the suite read an
# empty path, and it could still exit 0 (BH-2263; BH-2205 fixed one call site).
# The die now records itself under $T and the library's EXIT trap forces the
# suite's exit red.
#
# Every case writes a CHILD suite that sources the REAL tests/lib/scratch.sh and
# tests/lib/rendered.sh, with DIR pointing at a fake root whose renderers are
# stubs (broken: exit 1; clean: write a non-empty file), and asserts on the
# child's real exit code and stderr.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rendered-lib.bh-2263-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SUMMARY='helper failure(s) inside a subshell, suite forced red'

# mkroot <dir> <broken|clean> — a fake repo root with stub renderers
mkroot() {
  mkdir -p "$1/bin" "$1/cron/boxes/hub.d"
  if [ "$2" = broken ]; then
    for s in lanes-build render-cron render-env-example; do
      printf '#!/bin/sh\necho "stub %s refused" >&2\nexit 1\n' "$s" > "$1/bin/$s.sh"
    done
  else
    cat > "$1/bin/lanes-build.sh" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --to ] && { shift; echo '[]' > "$1"; }; shift; done
EOF
    cat > "$1/bin/render-cron.sh" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  [ "$1" = --out-dir ] && { shift; echo '* * * * * true' > "$1/hub.cron"; exit 0; }
  shift
done
echo '* * * * * true'
EOF
    cp "$1/bin/lanes-build.sh" "$1/bin/render-env-example.sh"
  fi
  chmod +x "$1/bin/"*.sh
}
mkroot "$T/broken" broken
mkroot "$T/clean" clean

# mkchild <name> <broken|clean> <body> — a child suite on the real libs; echoes its path
mkchild() {
  local f="$T/$1.sh"
  {
    printf '. %q || exit 1\n' "$DIR/tests/lib/scratch.sh"
    printf 'DIR=%q\n' "$T/$2"
    printf '. %q || exit 1\n' "$DIR/tests/lib/rendered.sh"
    printf '%s\n' "$3"
  } > "$f"
  printf '%s' "$f"
}

# run <child> <out> — the child as CI runs a suite; echoes its rc
run() {
  HARNESS_TEST_SANDBOX=1 bash "$1" > "$2" 2>&1
  echo $?
}

# --- 1: registry die -> red ----------------------------------------------------
C=$(mkchild c1 broken 'REG=$(rendered_registry)
exit 0')
RC=$(run "$C" "$T/c1.out")
[ "$RC" -ne 0 ] && ok || bad "1 a refused registry render must turn the suite red (rc $RC)"
grep -q 'could not compose catalog/lanes.json' "$T/c1.out" && ok \
  || bad "1 the die's own message is missing: $(head -c 300 "$T/c1.out")"
grep -q "$SUMMARY" "$T/c1.out" && ok || bad "1 the forced-red summary line is missing"

# --- 2: cron die inside a grep -> red -----------------------------------------
C=$(mkchild c2 broken 'grep -q x "$(rendered_cron hub)" 2>/dev/null && true
exit 0')
RC=$(run "$C" "$T/c2.out")
[ "$RC" -ne 0 ] && ok || bad "2 a refused cron render inside grep must turn the suite red (rc $RC)"

# --- 3: fleet die in a glob loop -> red (the BH-2205 shape) -------------------
C=$(mkchild c3 broken 'for f in "$(rendered_cron_dir)"/*.cron; do :; done
exit 0')
RC=$(run "$C" "$T/c3.out")
[ "$RC" -ne 0 ] && ok || bad "3 a refused fleet render in a glob loop must turn the suite red (rc $RC)"

# --- 4: clean control, and a suite's own rc is kept ---------------------------
C=$(mkchild c4 clean 'REG=$(rendered_registry); C=$(rendered_cron hub); D=$(rendered_cron_dir)
[ -s "$REG" ] && [ -s "$C" ] && [ -s "$D/hub.cron" ] || exit 9
exit 0')
RC=$(run "$C" "$T/c4.out")
[ "$RC" -eq 0 ] && ok || bad "4 a clean suite must stay green (rc $RC): $(head -c 300 "$T/c4.out")"
grep -q 'FAIL' "$T/c4.out" && bad "4 a clean suite printed FAIL" || ok
C=$(mkchild c4b clean 'REG=$(rendered_registry)
exit 3')
RC=$(run "$C" "$T/c4b.out")
[ "$RC" -eq 3 ] && ok || bad "4 a clean suite's own exit 3 must be kept (rc $RC)"
C=$(mkchild c4c broken 'REG=$(rendered_registry)
exit 3')
RC=$(run "$C" "$T/c4c.out")
[ "$RC" -eq 3 ] && ok || bad "4 a broken suite's own exit 3 must not be flipped to 1 (rc $RC)"

# --- 5: forked subshells are inert, and scratch cleanup still runs ------------
C=$(mkchild c5 clean 'echo "TREE=$T"
( exit 0 ); ( true ) & wait
[ -d "$T" ] && echo "ALIVE" || echo "GONE"
exit 0')
RC=$(run "$C" "$T/c5.out")
[ "$RC" -eq 0 ] && ok || bad "5 subshells must not change the suite's rc (rc $RC)"
grep -qx ALIVE "$T/c5.out" && ok || bad "5 a subshell's exit removed the scratch tree early: $(cat "$T/c5.out")"
grep -q "$SUMMARY" "$T/c5.out" && bad "5 a clean suite printed the forced-red summary" || ok
TREE=$(sed -n 's/^TREE=//p' "$T/c5.out")
[ -n "$TREE" ] && [ ! -e "$TREE" ] && ok || bad "5 the chained scratch cleanup did not remove '$TREE'"
# Bash 5 does not run an inherited EXIT trap in those forks, so also run the
# trap in one directly, after a die: it must return and print nothing.
C=$(mkchild c5b broken 'REG=$(rendered_registry)
( __rendered_exit_trap; echo SUBSHELL-CONTINUED ) 2>&1
exit 0')
RC=$(run "$C" "$T/c5b.out")
grep -qx SUBSHELL-CONTINUED "$T/c5b.out" && ok \
  || bad "5 the EXIT trap ended a forked subshell it does not own: $(head -c 300 "$T/c5b.out")"
[ "$(grep -c "$SUMMARY" "$T/c5b.out")" -eq 1 ] && ok \
  || bad "5 the forced-red summary must print once, from the suite's own shell"

# --- 6: a nested child suite's deliberate failure does not leak up ------------
CB=$(mkchild c6b broken 'REG=$(rendered_registry)
exit 0')
C=$(mkchild c6a clean "REG=\$(rendered_registry)
HARNESS_TEST_SANDBOX=1 bash $(printf %q "$CB") >/dev/null 2>&1; echo \"B_RC=\$?\"
exit 0")
RC=$(run "$C" "$T/c6.out")
[ "$RC" -eq 0 ] && ok || bad "6 a parent suite went red on its child's failure (rc $RC): $(head -c 300 "$T/c6.out")"
BRC=$(sed -n 's/^B_RC=//p' "$T/c6.out")
[ -n "$BRC" ] && [ "$BRC" -ne 0 ] && ok || bad "6 the broken child itself must be red (B_RC '$BRC')"

# --- 7: suites that replace the EXIT trap keep the check ----------------------
# The trap text is lifted from the real suites, so removing rendered_verdict
# from either of them turns this red.
LR=$(sed -n '/^cleanup() {/,/^trap cleanup EXIT/p' "$DIR/tests/lane-reaper.bh-1770-test.sh")
HB=$(sed -n '/^__hb_exit() {/,/^trap __hb_exit EXIT/p' "$DIR/tests/heartbeat-reaper.bh-638-test.sh")
for pair in "lane-reaper:LANEPIDS=\$T/pids; : > \"\$LANEPIDS\"
$LR" "heartbeat-reaper:LIVE=
$HB"; do
  name=${pair%%:*}; body=${pair#*:}
  case "$body" in
    *"trap "*EXIT*) ;;
    *) bad "7 could not lift the EXIT trap out of tests/$name*.sh"; continue ;;
  esac
  C=$(mkchild "c7-$name" broken "$body
REG=\$(rendered_registry)
exit 0")
  RC=$(run "$C" "$T/c7-$name.out")
  [ "$RC" -ne 0 ] && ok || bad "7 $name's own EXIT trap let a helper failure exit 0"
  C=$(mkchild "c7c-$name" clean "$body
REG=\$(rendered_registry)
exit 0")
  RC=$(run "$C" "$T/c7c-$name.out")
  [ "$RC" -eq 0 ] && ok || bad "7 $name's own EXIT trap turned a clean suite red (rc $RC): $(head -c 300 "$T/c7c-$name.out")"
done

# --- 8: llm-lane-id sources rendered.sh at top level --------------------------
# A source pin, because the defect there IS the source shape: sourcing the
# library inside $(...) never installs its trap in the suite's own shell.
LL="$DIR/tests/llm-lane-id.bh-2303-test.sh"
N=$(grep -c '^\. "\$DIR/tests/lib/rendered.sh" || exit 1$' "$LL")
[ "${N:-0}" -ge 1 ] && ok || bad "8 llm-lane-id must source rendered.sh at top level"
grep -q '\$(\. .*rendered\.sh' "$LL" && bad "8 llm-lane-id still sources rendered.sh inside \$(...)" || ok

# ------------------------------------------------------------------------------
echo "rendered-lib.bh-2263-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
