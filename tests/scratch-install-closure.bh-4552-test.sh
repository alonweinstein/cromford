#!/bin/bash
# tests/scratch-install-closure.bh-4552-test.sh — BH-4552: scratch trees copy a
# script's full source closure through scratch_install_closure, never a hand
# list of bin/lib files (tests/lib/scratch.sh).
#
#   C1  bin/pr-owner-sweep.sh's closure has pr-owner/*.sh, pr-health.sh,
#       lane-switch.sh, lane-gate.sh and env-path.sh
#   C2  bin/lib/file-children.sh's closure has tracker.sh, every tracker/*.sh,
#       fc-board.sh and fc-issues.sh (assignment-carried and globbed sources)
#   C3  bin/main-red-bisect.sh's closure has its six libs, and deployment.sh
#       whenever that file exists in the tree (it lands with #4415)
#   C3b the #4415 shape on a synthetic repo: deployment.sh reached through a
#       `for _d in "${X-}" "$(dirname ...)/deployment.sh"` list
#   C4  a lane sourcing a missing file: rc 1, stderr names it, nothing copied
#   C5  a lane that grows a new `. "$(dirname "$0")/lib/new.sh"` gets it
#       installed with no suite edit, and runs under env -i
#   C6  the real bin/main-red-bisect.sh installed end to end: every file there,
#       exec bit kept, a stub written first is not clobbered
#   C7  usage refusals: dest outside SCRATCH, absolute or `..` script, rc 2
#   C8  a source cycle terminates and lists both files
#   C9  a bare `. "$dir/$mod"` does not expand to all of bin/lib
#   C10 a directory carried in a variable (MC_DIR=".../mc"; . "$MC_DIR/x.sh")
# Run from anywhere: tests/scratch-install-closure.bh-4552-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { grep -qxF "$2" <<< "$1"; }   # <list> <line>

declare -F scratch_install_closure >/dev/null && declare -F scratch_closure_list >/dev/null \
  || { echo "FAIL: scratch_install_closure / scratch_closure_list not defined by tests/lib/scratch.sh"; exit 1; }

# --- C1 pr-owner-sweep ----------------------------------------------------------
L=$(cd "$T" && scratch_closure_list bin/pr-owner-sweep.sh); rc=$?
[ "$rc" = 0 ] && ok || bad "C1 rc=$rc"
[ "$(head -1 <<< "$L")" = bin/pr-owner-sweep.sh ] && ok || bad "C1 script is not first: $(head -1 <<< "$L")"
for f in bin/lib/pr-health.sh bin/lib/lane-switch.sh bin/lib/lane-gate.sh bin/lib/env-path.sh; do
  has "$L" "$f" && ok || bad "C1 closure lacks $f"
done
n=0
for f in "$DIR"/bin/lib/pr-owner/*.sh; do
  r="bin/lib/pr-owner/${f##*/}"
  grep -q "lib/pr-owner/${f##*/}" "$DIR/bin/pr-owner-sweep.sh" || continue
  n=$((n+1)); has "$L" "$r" && ok || bad "C1 closure lacks $r"
done
[ "$n" -ge 4 ] && ok || bad "C1 found only $n pr-owner libs sourced by the sweep (vacuous)"

# --- C2 file-children -----------------------------------------------------------
L=$(scratch_closure_list bin/lib/file-children.sh); rc=$?
[ "$rc" = 0 ] && ok || bad "C2 rc=$rc"
for f in bin/lib/tracker.sh bin/lib/fc-board.sh bin/lib/fc-issues.sh; do
  has "$L" "$f" && ok || bad "C2 closure lacks $f"
done
n=0
for f in "$DIR"/bin/lib/tracker/*.sh; do
  n=$((n+1)); has "$L" "bin/lib/tracker/${f##*/}" && ok || bad "C2 closure lacks bin/lib/tracker/${f##*/}"
done
[ "$n" -ge 1 ] && ok || bad "C2 no bin/lib/tracker/*.sh in the tree (vacuous)"

# --- C3 main-red-bisect -----------------------------------------------------------
L=$(scratch_closure_list bin/main-red-bisect.sh); rc=$?
[ "$rc" = 0 ] && ok || bad "C3 rc=$rc"
for f in lane-gate env-path hub-box mrb-probe mrb-detect mrb-act; do
  has "$L" "bin/lib/$f.sh" && ok || bad "C3 closure lacks bin/lib/$f.sh"
done
if [ -f "$DIR/bin/lib/deployment.sh" ]; then
  has "$L" bin/lib/deployment.sh && ok || bad "C3 closure lacks bin/lib/deployment.sh"
fi
# Only bin/lib files join: no other bin/*.sh, no fixture, no absolute path.
other=$(grep -v -e '^bin/main-red-bisect\.sh$' -e '^bin/lib/' <<< "$L")
[ -z "$other" ] && ok || bad "C3 closure has a non-bin/lib entry: $(tr '\n' ' ' <<< "$other")"

# Synthetic repos: SCRATCH_CLOSURE_REPO points the helper at them.
mkrepo() { scratch_rm "$T/$1" || return 1; mkdir -p "$T/$1/bin/lib"; }

# --- C3b the #4415 shape ------------------------------------------------------------
mkrepo r3b
cat > "$T/r3b/bin/lane.sh" <<'EOF'
#!/bin/bash
H="${HARNESS:-/root/harness}"
. "$H/bin/lib/hub.sh" 2>/dev/null || true
EOF
cat > "$T/r3b/bin/lib/hub.sh" <<'EOF'
_hub_dep() {
  local _d
  for _d in "${HARNESS_DEPLOYMENT_FILE-}" "$(dirname "${BASH_SOURCE[0]}")/deployment.sh"; do
    [ -n "$_d" ] && [ -r "$_d" ] && { . "$_d"; return 0; }
  done
}
EOF
echo 'dep_ok() { :; }' > "$T/r3b/bin/lib/deployment.sh"
L=$(SCRATCH_CLOSURE_REPO="$T/r3b" scratch_closure_list bin/lane.sh); rc=$?
[ "$rc" = 0 ] && ok || bad "C3b rc=$rc"
want=$'bin/lane.sh\nbin/lib/deployment.sh\nbin/lib/hub.sh'
[ "$L" = "$want" ] && ok || bad "C3b closure want [$want] got [$L]"

# --- C4 a missing source fails loudly, before any copy ---------------------------------
mkrepo r4
cat > "$T/r4/bin/lane.sh" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/ok.sh" || exit 1
. "$(dirname "$0")/lib/nope.sh" || exit 1
EOF
echo 'ok_fn() { :; }' > "$T/r4/bin/lib/ok.sh"
err=$(SCRATCH_CLOSURE_REPO="$T/r4" scratch_closure_list bin/lane.sh 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "C4 list rc=$rc want 1"
grep -q 'lib/nope.sh' <<< "$err" && ok || bad "C4 stderr does not name lib/nope.sh: [$err]"
mkdir -p "$T/d4"
SCRATCH_CLOSURE_REPO="$T/r4" scratch_install_closure bin/lane.sh "$T/d4" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "C4 install rc=$rc want 1"
[ -z "$(find "$T/d4" -mindepth 1 -print -quit)" ] && ok || bad "C4 install left a half-built tree: $(find "$T/d4" -mindepth 1 | tr '\n' ' ')"

# --- C5 a lane grows a new lib; the suite needs no edit -----------------------------------
mkrepo r5
cat > "$T/r5/bin/lane.sh" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/old.sh" || exit 1
old_fn
EOF
chmod +x "$T/r5/bin/lane.sh"
echo 'old_fn() { echo OLD; }' > "$T/r5/bin/lib/old.sh"
run5() {  # <dest> — the suite's whole setup: one helper call, then the lane under env -i
  SCRATCH_CLOSURE_REPO="$T/r5" scratch_install_closure bin/lane.sh "$1" >/dev/null || return 9
  env -i /bin/bash "$1/bin/lane.sh"
}
out=$(run5 "$T/d5a" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = OLD ] && ok || bad "C5 before: rc=$rc out=[$out]"
cat > "$T/r5/bin/lane.sh" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/old.sh" || exit 1
. "$(dirname "$0")/lib/new.sh" || exit 1
old_fn; new_fn
EOF
echo 'new_fn() { echo NEW; }' > "$T/r5/bin/lib/new.sh"
out=$(run5 "$T/d5b" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = $'OLD\nNEW' ] && ok || bad "C5 after new.sh: rc=$rc out=[$out]"

# --- C6 the real lane installed end to end ---------------------------------------------------
H6="$T/h6"; mkdir -p "$H6/bin/lib"
echo '# suite stub' > "$H6/bin/lib/hub-box.sh"
L=$(scratch_closure_list bin/main-red-bisect.sh)
out=$(scratch_install_closure bin/main-red-bisect.sh "$H6"); rc=$?
[ "$rc" = 0 ] && ok || bad "C6 install rc=$rc"
while IFS= read -r f; do
  [ -f "$H6/$f" ] || { bad "C6 $f not installed"; continue; }
  if [ -x "$DIR/$f" ]; then [ -x "$H6/$f" ] && ok || bad "C6 $f lost its exec bit"; else ok; fi
done <<< "$L"
[ "$(cat "$H6/bin/lib/hub-box.sh")" = '# suite stub' ] && ok || bad "C6 the stub bin/lib/hub-box.sh was clobbered"
cmp -s "$DIR/bin/lib/mrb-act.sh" "$H6/bin/lib/mrb-act.sh" && ok || bad "C6 bin/lib/mrb-act.sh is not the real file"
has "$out" bin/lib/mrb-act.sh && ok || bad "C6 install did not print what it copied"
! has "$out" bin/lib/hub-box.sh && ok || bad "C6 install printed the kept stub as copied"

# --- C7 refusals -------------------------------------------------------------------------------
OUT7="$(dirname "$SCRATCH")/not-scratch-bh4552.$$"
scratch_install_closure bin/main-red-bisect.sh "$OUT7" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$OUT7" ] && ok || bad "C7 dest outside SCRATCH rc=$rc want 2"
# OUT7 sits beside SCRATCH, so scratch_rm refuses it by design. It only exists
# if the refusal above already failed; remove it only if empty, else name it.
if [ -e "$OUT7" ]; then rmdir "$OUT7" 2>/dev/null || echo "NOTE: C7 left $OUT7 behind; remove it by hand"; fi
for a in "$DIR/bin/main-red-bisect.sh" bin/../bin/main-red-bisect.sh '' bin/no-such-lane.sh; do
  scratch_closure_list "$a" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok || bad "C7 scratch_closure_list '$a' rc=$rc want 2"
  scratch_install_closure "$a" "$T/d7" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok || bad "C7 scratch_install_closure '$a' rc=$rc want 2"
done

# --- C8 a cycle terminates ------------------------------------------------------------------------
mkrepo r8
printf '. "$(dirname "${BASH_SOURCE[0]}")/b.sh"\n' > "$T/r8/bin/lib/a.sh"
printf '. "$(dirname "${BASH_SOURCE[0]}")/a.sh"\n' > "$T/r8/bin/lib/b.sh"
L=$(SCRATCH_CLOSURE_REPO="$T/r8" timeout 20 bash -c '. "$1" || exit 1; scratch_closure_list bin/lib/a.sh' _ "$DIR/tests/lib/scratch.sh"); rc=$?
[ "$rc" = 0 ] && [ "$L" = $'bin/lib/a.sh\nbin/lib/b.sh' ] && ok || bad "C8 cycle rc=$rc closure [$L]"

# --- C9 a bare variable source is not a glob over bin/lib -------------------------------------------
mkrepo r9
cat > "$T/r9/bin/lib/loader.sh" <<'EOF'
load() { local dir mod="$1"; dir=$(dirname "${BASH_SOURCE[0]}"); . "$dir/$mod"; }
load2() { local dir; dir=$(dirname "${BASH_SOURCE[0]}"); . "$dir/$1.sh"; }
for f in "$dir"/$mod.sh; do :; done
EOF
for x in one two three; do echo ':' > "$T/r9/bin/lib/$x.sh"; done
L=$(SCRATCH_CLOSURE_REPO="$T/r9" scratch_closure_list bin/lib/loader.sh); rc=$?
[ "$rc" = 0 ] && [ "$L" = bin/lib/loader.sh ] && ok || bad "C9 rc=$rc closure [$L] want only bin/lib/loader.sh"

# --- C10 a directory carried in a variable (bin/lib/merge-conductor-lib.sh) ---------------------
mkrepo r10; mkdir -p "$T/r10/bin/lib/mc"
cat > "$T/r10/bin/lib/conductor.sh" <<'EOF'
MC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mc"
for _m in log queue; do . "$MC_DIR/$_m.sh" || exit 1; done
[ -r "$MC_DIR/opt.sh" ] && . "$MC_DIR/opt.sh"
EOF
for x in log queue opt; do echo ':' > "$T/r10/bin/lib/mc/$x.sh"; done
L=$(SCRATCH_CLOSURE_REPO="$T/r10" scratch_closure_list bin/lib/conductor.sh); rc=$?
want=$'bin/lib/conductor.sh\nbin/lib/mc/log.sh\nbin/lib/mc/opt.sh\nbin/lib/mc/queue.sh'
[ "$rc" = 0 ] && [ "$L" = "$want" ] && ok || bad "C10 rc=$rc closure [$L] want [$want]"
L=$(scratch_closure_list bin/lib/merge-conductor-lib.sh); rc=$?
[ "$rc" = 0 ] && has "$L" bin/lib/mc/log.sh && ok || bad "C10 real merge-conductor-lib.sh rc=$rc, closure lacks bin/lib/mc/log.sh"

echo "scratch-install-closure.bh-4552: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
