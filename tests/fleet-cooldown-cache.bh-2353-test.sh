#!/bin/bash
# tests/fleet-cooldown-cache.bh-2353-test.sh — BH-2353 lead fix round: the
# three merge conditions on #2353 (lead comment, 2026-09-25 19:49Z) and #2464.
# Sources the REAL seam and the REAL cooldown_* verbs; only _jobs_req is a
# stub, which records "<method> <path> <body>" to $T/calls and answers from
# $T/ans/<key> (+ <key>.rc), key = "<method> <path>" with every non-alphanumeric
# turned into _. The same stub as tests/fleet-cooldown.bh-2353-test.sh.
#
#   C1 the knobs are registered: catalog/lanes.d carries a `fleet-cooldown` lib
#      whose knobs include FLEET_COOLDOWN_DB and FLEET_COOLDOWN_STORE, and every
#      knob's read_in names every bin/ file that reads it; lanes-build --check
#      passes and section 20 (the libs scope) holds for the new lib
#   C2 reprobe reseed guard: a lane clear that FAILED, followed by a good list
#      read in another process, does not hand the cleared row back (fcd_list
#      omits it, fcd_live is 1); a newer row for the same lane (a real re-down,
#      later until) still shows; a local put of the lane lifts the guard
#   C3 N processes in one cycle make ONE GET per kind (account, model, lane)
#   C4 a cache older than FLEET_COOLDOWN_CACHE_S refetches
#   C5 an outage with a stale cache is unknown (rc 2), never "not cooling" (rc 1),
#      and never serves the stale rows
#   C6 a put or clear drops the box cache of its kind, so the box reads its write
#   C7 with H, HARNESS_ROOT and HARNESS unset the seam names no path (nothing
#      under /root) and keeps today's per-process behaviour
#   C8 a harness root the (unprivileged) caller cannot write never kills a
#      set -euo pipefail caller: every fcd_* call and lane-down-lib A9's
#      ld_mark/ld_clear return, answers unchanged
#   C9 (review r3) a tomb rm that fails even as root (the tomb path is a dir)
#      does not kill a set -e fcd_put caller
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fleet-cooldown-cache.bh-2353-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fleet-cooldown.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE FLEET_COOLDOWN_CACHE_S HARNESS_SECRET JOBS_URL
export HARNESS="$T" HARNESS_ENV_DIR="$T/env" JOBS_BOX=testbox
mkdir -p "$T/logs" "$T/ans"
FUT=4102444800
CACHE="$T/state/fleet-cooldown"

cat > "$T/prelude.sh" <<EOF
. "$LIB" || exit 99
. "$DIR/bin/lib/jobs/machines.sh" || exit 99
_jobs_req() {
  local key; key=\$(printf '%s' "\$1 \$2" | tr -c 'A-Za-z0-9' _)
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls"
  cat "$T/ans/\$key" 2>/dev/null
  return "\$(cat "$T/ans/\$key.rc" 2>/dev/null || echo 0)"
}
EOF
run() { bash -c ". '$T/prelude.sh'; $1" 2>&1; }
answer() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
answer_rc() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).rc"; }
reset() { rm -f "$T/calls" "$T/ans"/*; scratch_rm "$T/state"; : > "$T/logs/agent-rules.log"; }
calls() { cat "$T/calls" 2>/dev/null; }
gets() { calls | grep -c "^GET /api/cooldowns?kind=$1 "; }
row() { printf '{"kind":"%s","vendor":"%s","subject":"%s","until":%s,"since":null,"reason":"r","box":"hub","set_at":1}' "$@"; }
all_answers() {
  answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude a $FUT)],\"truncated\":false}"
  answer "GET /api/cooldowns?kind=model" '{"rows":[],"truncated":false}'
  answer "GET /api/cooldowns?kind=lane" "{\"rows\":[$(row lane claude box1 $FUT)],\"truncated\":false}"
}
# backdate <kind>: make the box cache of <kind> look fetched at epoch 1.
backdate() {
  local f="$CACHE/cache.$1.tsv"
  [ -f "$f" ] || return 1
  sed -i '1s/^[0-9]*/1/' "$f"
}

# ---------- C1 the knobs are registered -----------------------------------------
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "C1 registry did not compose"
"$DIR/bin/lanes-build.sh" --root "$DIR" --check >/dev/null 2>&1 && ok || bad "C1 lanes-build --check failed"
for env in FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE FLEET_COOLDOWN_CACHE_S FLEET_COOLDOWN_CLEAR_GUARD_S; do
  k=$(jq -c --arg e "$env" '[.libs[]? | select(.id=="fleet-cooldown") | .knobs[]? | select(.env==$e)][0] // empty' "$REG" 2>/dev/null)
  [ -n "$k" ] && ok || { bad "C1 $env is not a knob of the fleet-cooldown lib"; continue; }
  read_in=" $(jq -r '.read_in // ""' <<<"$k") "
  readers=$(cd "$DIR" && grep -rlw -- "$env" bin/ 2>/dev/null | sort)
  [ -n "$readers" ] && ok || bad "C1 nothing in bin/ reads $env"
  for f in $readers; do
    case "$read_in" in *" $f "*) ok ;; *) bad "C1 $env read_in [$read_in] misses reader $f" ;; esac
  done
  for f in $read_in; do
    [ -f "$DIR/$f" ] && grep -qw -- "$env" "$DIR/$f" && ok || bad "C1 $env read_in names $f, which does not read it"
  done
done
# Section 20 of tests/lanes-registry-test.sh over the new lib: the file exists
# and reads the knob, the settings key is legal, a default is a value, and a
# path is never settable from a page.
lib_file=$(jq -r '.libs[]? | select(.id=="fleet-cooldown") | .file' "$REG" 2>/dev/null)
[ "$lib_file" = bin/lib/fleet-cooldown.sh ] && ok || bad "C1 lib file: [$lib_file]"
[ "$(jq -r '[.libs[]? | select(.id=="fleet-cooldown") | .knobs[] | select(.env=="FLEET_COOLDOWN_STORE") | .settable][0]' "$REG" 2>/dev/null)" = false ] \
  && ok || bad "C1 FLEET_COOLDOWN_STORE (a path) must carry settable:false"
[ "$(jq -r '[.libs[]? | select(.id=="fleet-cooldown") | .knobs[] | (.default|tostring) | select(test("[$]"))] | length' "$REG" 2>/dev/null)" = 0 ] \
  && ok || bad "C1 a fleet-cooldown default is shell text"

# ---------- C2 the reprobe reseed guard -----------------------------------------
reset; all_answers
answer_rc "POST /api/cooldowns/clear" 1        # the clear FAILS (unknown)
out=$(run 'rc=0; fcd_clear lane claude box1 || rc=$?; echo $rc')
[ "$out" = 2 ] && ok || bad "C2 failed clear rc: $out"
rm -f "$T/ans/POST__api_cooldowns_clear.rc"
# A fresh process (the next reprobe tick), a GOOD list read that still carries the row.
rm -f "$CACHE/cache.lane.tsv"
out=$(run 'echo "[$(fcd_list lane)]"; rc=0; fcd_live lane claude box1 || rc=$?; echo "live=$rc"')
[ "$out" = "$(printf '[]\nlive=1')" ] && ok || bad "C2 a cleared lane was reseeded from a good list read: [$out]"
[ "$(gets lane)" -ge 2 ] && ok || bad "C2 the second process did not read the fleet (calls: $(calls))"
# Another lane (a different box) is untouched by the guard.
answer "GET /api/cooldowns?kind=lane" "{\"rows\":[$(row lane claude box1 $FUT),$(row lane claude box2 $FUT)],\"truncated\":false}"
rm -f "$CACHE/cache.lane.tsv"
out=$(run 'fcd_list lane | cut -f2')
[ "$out" = box2 ] && ok || bad "C2 want only box2 (box1 guarded, box2 untouched): [$out]"
# A REAL re-down after the clear (a later until) is not hidden.
answer "GET /api/cooldowns?kind=lane" "{\"rows\":[$(row lane claude box1 $((FUT + 60)))],\"truncated\":false}"
rm -f "$CACHE/cache.lane.tsv"
out=$(run 'rc=0; fcd_live lane claude box1 || rc=$?; echo $rc')
[ "$out" = 0 ] && ok || bad "C2 a re-down with a later until was hidden: $out"
# A local put of the lane lifts the guard for the old row too.
answer "GET /api/cooldowns?kind=lane" "{\"rows\":[$(row lane claude box1 $FUT)],\"truncated\":false}"
answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
rm -f "$CACHE/cache.lane.tsv"
out=$(run "fcd_put lane claude box1 $FUT; rc=0; fcd_live lane claude box1 || rc=\$?; echo \$rc")
[ "$out" = 0 ] && ok || bad "C2 a local put did not lift the guard: $out"
# The guard is lane-only: an account clear that fails does not hide the row.
reset; all_answers; answer_rc "POST /api/cooldowns/clear" 1
run 'fcd_clear account claude a' >/dev/null
rm -f "$T/ans/POST__api_cooldowns_clear.rc" "$CACHE/cache.account.tsv"
out=$(run 'rc=0; fcd_live account claude a || rc=$?; echo $rc')
[ "$out" = 0 ] && ok || bad "C2 an account clear hid the account row: $out"

# ---------- C3 one GET per kind per cycle, across processes ---------------------
reset; all_answers
N=6
for _ in $(seq 1 $N); do
  run 'fcd_live account claude a; fcd_live account claude b; fcd_live model claude x; fcd_list lane >/dev/null' >/dev/null &
done
wait
for k in account model lane; do
  [ "$(gets "$k")" = 1 ] && ok || bad "C3 $N processes made $(gets "$k") $k GETs (want 1): $(calls)"
done
C3_GETS="account=$(gets account) model=$(gets model) lane=$(gets lane) processes=$N"
# The cached answer is the real answer.
out=$(run 'for k in "account claude a" "account claude b" "model claude x" "lane claude box1"; do rc=0; fcd_live $k || rc=$?; printf "%s " $rc; done')
[ "$out" = "0 1 1 0 " ] && ok || bad "C3 cached answers: [$out]"
[ "$(calls | wc -l)" = 3 ] && ok || bad "C3 a later process in the cycle refetched: $(calls)"

# ---------- C4 a stale cache refetches ------------------------------------------
backdate account && ok || bad "C4 no box cache for account at $CACHE/cache.account.tsv"
out=$(run 'rc=0; fcd_live account claude a || rc=$?; echo $rc')
[ "$out" = 0 ] && ok || bad "C4 refetch answer: $out"
[ "$(gets account)" = 2 ] && ok || bad "C4 a stale cache did not refetch: $(calls)"
[ "$(gets model)" = 1 ] && ok || bad "C4 a fresh model cache was refetched: $(calls)"
# FLEET_COOLDOWN_CACHE_S=0 is no cache: every process reads.
out=$(FLEET_COOLDOWN_CACHE_S=0 run 'fcd_live model claude x; echo $?')
[ "$(gets model)" = 2 ] && ok || bad "C4 CACHE_S=0 still served the cache: $(calls)"

# ---------- C5 an outage with a stale cache is unknown --------------------------
reset
answer "GET /api/cooldowns?kind=model" '{"rows":[],"truncated":false}'
answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude a $FUT)],\"truncated\":false}"
run 'fcd_live model claude x; fcd_live account claude a' >/dev/null
backdate model && backdate account && ok || bad "C5 no caches to backdate"
answer_rc "GET /api/cooldowns?kind=model" 1
answer_rc "GET /api/cooldowns?kind=account" 1
out=$(run 'rc=0; fcd_live model claude x || rc=$?; echo "model=$rc"; rc=0; fcd_live account claude b || rc=$?; echo "acct=$rc"; echo "[$(fcd_list account)]"')
[ "$out" = "$(printf 'model=2\nacct=2\n[]')" ] && ok || bad "C5 outage + stale cache: [$out]"
# The failed read left no fresh cache behind: the next process asks again.
run 'fcd_live model claude x' >/dev/null
[ "$(gets model)" = 3 ] && ok || bad "C5 an outage was cached: $(calls)"
# The fleet-or caller: account_cooling's shape. Unknown falls to the local file.
out=$(run 'rc=0; fcd_live account claude a || rc=$?; [ "$rc" = 1 ] && echo NOT-COOLING || echo "unknown-or-cooling rc=$rc"')
[ "$out" = "unknown-or-cooling rc=2" ] && ok || bad "C5 outage read as: $out"

# ---------- C6 a write drops the box cache of its kind --------------------------
reset; all_answers
answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
run 'fcd_live account claude a; fcd_live model claude x' >/dev/null
run "fcd_put account claude z $FUT" >/dev/null
run 'fcd_live account claude a; fcd_live model claude x' >/dev/null
[ "$(gets account)" = 2 ] && ok || bad "C6 a put did not drop the account cache: $(calls)"
[ "$(gets model)" = 1 ] && ok || bad "C6 a put dropped another kind's cache: $(calls)"
answer "POST /api/cooldowns/clear" '{"cleared":1}'
run 'fcd_clear account claude a' >/dev/null
run 'fcd_live account claude a' >/dev/null
[ "$(gets account)" = 3 ] && ok || bad "C6 a clear did not drop the account cache: $(calls)"

# ---------- C7 no root named: nothing under /root, today's behaviour ------------
# The trace-safety hit on #2476: a suite that sourced the seam with H, HARNESS_ROOT
# and HARNESS all unset had the guard and the cache resolve to the live
# /root/harness and `rm` files there. With no root named, the seam must name no
# path at all and fall back to one GET per kind per process and no guard. The
# write commands are shimmed: each records its argv, and one that names /root is
# NEVER run, so even the red run cannot touch the real tree.
mkdir -p "$T/c7shim" "$T/c7home"
for c in rm mkdir mktemp mv flock; do
  real=$(command -v "$c" 2>/dev/null) || continue
  cat > "$T/c7shim/$c" <<SH
#!/bin/bash
printf '%s %s\n' "$c" "\$*" >> "$T/c7argv"
case " \$* " in *" /root"*|*"=/root"*) exit 0 ;; esac
exec "$real" "\$@"
SH
  chmod +x "$T/c7shim/$c"
done
reset; all_answers
answer "POST /api/cooldowns/clear" '{"cleared":1}'
rm -f "$T/c7argv"
out=$(cd "$T/c7home" && env -u H -u HARNESS -u HARNESS_ROOT HOME="$T/c7home" PATH="$T/c7shim:$PATH" bash -c "
  set -euo pipefail
  . '$T/prelude.sh'
  rc=0; _fcd_state >/dev/null || rc=\$?; echo state=\$rc
  fcd_put lane claude box1 $FUT; fcd_put account claude a $FUT
  rc=0; fcd_clear lane claude box1 || rc=\$?; echo clear=\$rc
  rc=0; fcd_live lane claude box1 || rc=\$?; echo lane=\$rc
  rc=0; fcd_live account claude a || rc=\$?; echo acct=\$rc
  rc=0; fcd_live account claude a || rc=\$?; echo acct2=\$rc
  echo list=\$(fcd_list lane | cut -f2)
  echo survived" 2>&1)
[ "$out" = "$(printf 'state=1\nclear=0\nlane=0\nacct=0\nacct2=0\nlist=box1\nsurvived')" ] \
  && ok || bad "C7 no-root answers: [$out]"
hits=$(grep -E '(^| |=)/root' "$T/c7argv" 2>/dev/null)
[ -z "$hits" ] && ok || bad "C7 a write command named /root with no root set: $hits"
[ "$(gets account)" = 1 ] && [ "$(gets lane)" -ge 1 ] && ok || bad "C7 per-process reads changed: $(calls)"
[ -z "$(ls -A "$T/c7home")" ] && ok || bad "C7 wrote into cwd/HOME: $(ls -A "$T/c7home")"

# ---------- C8 an unwritable root never kills a set -e caller -------------------
# The #2552 review: `[ "$kind" = lane ] && rm -f <tomb>` ended an && list, so an
# rm that failed (EACCES: a non-root caller whose root it cannot write) killed a
# set -euo pipefail caller. ld_mark -> fcd_put (bin/lib/lane-down.sh) is such a
# caller: tests/lane-down-lib.bh-1686 A9 went 73/0 -> 69/4 as nobody, which is
# how CI runs. Here: HARNESS is a scratch dir the caller cannot enter, the caller
# is unprivileged (dropped to nobody when this suite runs as root), and every
# fcd_* call and the A9 ld_mark/ld_clear sequence must return, with the fleet
# answers unchanged: a failed guard or cache write is today's behaviour.
NB="$T/c8"; mkdir -p "$NB/io/ans" "$NB/locked" "$NB/h9"
unpriv() { "$@"; }
if [ "$(id -u)" = 0 ]; then
  if command -v setpriv >/dev/null 2>&1; then
    # BASH_ENV (a tracer's hook in the runner's root-only temp dir) cannot be
    # read by nobody and would print a line into every answer; the dropped child
    # runs without it. CI runs this suite as nobody, where nothing is dropped.
    unpriv() { setpriv --reuid=65534 --regid=65534 --clear-groups -- env -u BASH_ENV "$@"; }
  else unpriv() { return 99; }; fi
  chmod o+x "$T"; chmod 755 "$NB"; chmod 777 "$NB/io" "$NB/io/ans" "$NB/h9"; chmod 700 "$NB/locked"
else
  chmod 000 "$NB/locked"
fi
cat > "$NB/prelude.sh" <<EOF
. "$LIB" || exit 99
. "$DIR/bin/lib/jobs/machines.sh" || exit 99
_jobs_req() {
  local key; key=\$(printf '%s' "\$1 \$2" | tr -c 'A-Za-z0-9' _)
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$NB/io/calls"
  cat "$NB/io/ans/\$key" 2>/dev/null
  return "\$(cat "$NB/io/ans/\$key.rc" 2>/dev/null || echo 0)"
}
EOF
chmod 644 "$NB/prelude.sh"
c8ans() { printf '%s' "$2" > "$NB/io/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; chmod 666 "$NB/io/ans/"* 2>/dev/null; }
c8ans "GET /api/cooldowns?kind=lane" "{\"rows\":[$(row lane claude box1 $FUT)],\"truncated\":false}"
c8ans "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude a $FUT)],\"truncated\":false}"
c8ans "POST /api/cooldowns" '{"ok":true,"row":{}}'
c8ans "POST /api/cooldowns/clear" '{"cleared":0}'
out=$(unpriv env -u H -u HARNESS_ROOT HARNESS="$NB/locked" HOME="$NB/io" bash -c "
  set -euo pipefail
  . '$NB/prelude.sh'
  [ -w '$NB/locked' ] && echo WRITABLE-ROOT
  fcd_put lane claude box1 $FUT; echo put-lane
  fcd_put account claude a $FUT; echo put-acct
  rc=0; fcd_clear lane claude box1 || rc=\$?; echo clear=\$rc
  rc=0; fcd_live lane claude box1 || rc=\$?; echo lane=\$rc
  rc=0; fcd_live account claude a || rc=\$?; echo acct=\$rc
  echo list=\$(fcd_list lane | cut -f2)
  echo survived" 2>&1); rc=$?
if [ "$rc" = 99 ] && [ -z "$out" ]; then
  ok; echo "C8 skipped: root without setpriv cannot drop to nobody"
else
  [ "$rc" = 0 ] && [ "$out" = "$(printf 'put-lane\nput-acct\nclear=1\nlane=0\nacct=0\nlist=box1\nsurvived')" ] \
    && ok || bad "C8 an unwritable root killed or changed a set -e caller: rc=$rc [$out]"
  # tests/lane-down-lib.bh-1686 A9, with the fleet seam live: ld_mark and
  # ld_clear on a flagless lane, the harness root the caller cannot write.
  out=$(unpriv env -u H -u HARNESS_ROOT HARNESS="$NB/locked" HOME="$NB/io" bash -c '
    set -euo pipefail; . "$1"; . "$5"
    ld_mark "$2" hub-grok "" 401 "$3"; echo marked
    ld_clear "$2" hub-grok "$3"; ld_clear "$2" project-4-none "$3"; echo survived' \
    _ "$NB/prelude.sh" "$NB/h9" 1790000000 unused "$DIR/bin/lib/lane-down.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -cxE 'marked|survived')" = 2 ] \
    && ok || bad "C8 A9 ld_mark/ld_clear died under set -e: rc=$rc [$out]"
fi
chmod 700 "$NB/locked" 2>/dev/null
# ---------- C9 a failed tomb rm (tomb is a dir) never kills a set -e caller -----
# Review r3 of #2476: `[ lane ] && tomb=$(...) && rm -f "$tomb"` ended an && list,
# so an rm that failed (unwritable state dir; here the tomb path is a DIRECTORY,
# which rm -f refuses even as root) exited a `set -e` caller such as ld_mark.
reset; all_answers
mkdir -p "$T/c9/state/fleet-cooldown/cleared.lane.claude.box9"
out=$(HARNESS="$T/c9" bash -c "
  set -euo pipefail
  . '$T/prelude.sh'
  fcd_put lane claude box9 $FUT
  echo survived" 2>&1)
case "$out" in *survived*) ok ;; *) bad "C9 a failed tomb rm killed the set -e caller: [$out]" ;; esac

# ---------- sourcing stays side-effect free ---------------------------------------
mkdir -p "$T/empty"
out=$(cd "$T/empty" && HARNESS="$T/empty" bash -c 'set -euo pipefail; . "$1"; . "$1"' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(ls -A "$T/empty")" ] && ok || bad "source rc=$rc out=[$out] files=$(ls -A "$T/empty")"

echo "C3 GETs: $C3_GETS"
echo "fleet-cooldown-cache.bh-2353: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
