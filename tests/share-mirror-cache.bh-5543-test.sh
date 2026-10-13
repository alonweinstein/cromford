#!/bin/bash
# tests/share-mirror-cache.bh-5543-test.sh — the public mirror is built once per
# tree and the share suites read that one build (BH-5543).
#
# tests/lib/share-mirror.sh keys the build on the committed tree, bin/share/ as
# on disk, the library itself and the python3 on PATH. C1-C8 drive it over a
# small committed scratch repo (fast); L1 drives the three real share suites
# over a clone of this checkout with a planted leak (about one full build).
#
#   C1  built, then reused; the built line carries the sanitize time
#   C2  two concurrent suites build once
#   C3  an uncommitted bin/share edit is a new key; reverting reuses the old one
#   C4  a new commit is a new key
#   C5  a failed sanitize is never stored; a python3 with no fingerprint is private
#   C6  --worktree on a dirty checkout is private and carries the uncommitted file
#   C7  prune keeps the newest SHARE_MIRROR_CACHE_KEEP, never one in use
#   C8  an entry with no DONE, or a dead temp build, is never read
#   L1  bh-795 builds, share-mirror-clean and publish-cromford-brand reuse, and a
#       planted leak still fails both leak suites
#
# The planted credential is assembled at run time, never spelled.
#
# Run from anywhere: tests/share-mirror-cache.bh-5543-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export PYTHONDONTWRITEBYTECODE=1 HARNESS_TEST_SANDBOX=1
unset SHARE_MIRROR_CACHE SHARE_MIRROR_CACHE_KEEP SHARE_MIRROR_LOCK_WAIT_S GITLEAKS_REQUIRED

if [ ! -f "$DIR/bin/share/sanitize.py" ]; then
  echo "SKIP share-mirror-cache.bh-5543: no bin/share in this copy"
  exit 0
fi
GIT=(git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)

# ── the scratch repo: bin/share, the two libs, every PATCHES target ─────────
R="$T/r"
mkdir -p "$R/bin/share" "$R/tests/lib" "$R/notes"
( cd "$DIR/bin/share" && tar -cf - --exclude=__pycache__ --exclude='*.pyc' . ) | tar -x -C "$R/bin/share"
cp "$DIR/tests/lib/scratch.sh" "$DIR/tests/lib/share-mirror.sh" "$R/tests/lib/"
while IFS= read -r rel; do
  mkdir -p "$R/$(dirname "$rel")"
  cp "$DIR/$rel" "$R/$rel"
done < <(cd "$DIR/bin/share" && python3 -B -c '
import sanitize
for rel, _, _ in sanitize.PATCHES: print(rel)' | sort -u)
printf 'an ordinary file the mirror ships\n' > "$R/notes/keep.md"
# The consumer: what a share suite does, and what it saw.
cat > "$R/tests/consumer.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
share_mirror_get "$(cd "$(dirname "$0")/.." && pwd)" ${1:+"$1"}
rc=$?
has=0; [ -n "${CHECK:-}" ] && [ -e "$SM_MIRROR/$CHECK" ] && has=1
printf 'rc=%s how=%s san=%s dir=%s has=%s\n' "$rc" "$SM_HOW" "$SM_SANITIZE_RC" "$SM_DIR" "$has"
SH
( cd "$R" && "${GIT[@]}" init -q -b main && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m base ) \
  || { echo "FAIL: fixture: cannot commit the scratch repo"; exit 1; }

# run <cache> [arg] — run the consumer; OUT is its result line, NEW the log
# lines this run added.
run() {
  local c="$1" before=0
  [ -f "$c/share-mirror.log" ] && before=$(wc -l < "$c/share-mirror.log")
  OUT=$(SHARE_MIRROR_CACHE="$c" bash "$R/tests/consumer.sh" ${2:+"$2"} 2>/dev/null | tail -1)
  NEW=$(tail -n +"$((before + 1))" "$c/share-mirror.log" 2>/dev/null)
}
key12() { sed -nE 's/.*share-mirror: (built|reused|failed) ([0-9a-f]{12}) .*/\2/p' <<< "$1" | head -1; }
field() { sed -nE "s/.*\\b$1=([^ ]*).*/\\1/p" <<< "$OUT"; }
entries() { find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp.*' | wc -l; }

# ── C1 built, then reused ───────────────────────────────────────────────────
C1="$T/c1"
run "$C1"; L1A=$NEW; D1A=$(field dir)
run "$C1"; L1B=$NEW; D1B=$(field dir)
[ "$(grep -c ' share-mirror: built ' "$C1/share-mirror.log")" = 1 ] \
  && [ "$(grep -c ' share-mirror: reused ' "$C1/share-mirror.log")" = 1 ] && ok \
  || bad "C1 two runs on one tree must log 1 built and 1 reused (log: $(cat "$C1/share-mirror.log"))"
grep -qE 'share-mirror: built [0-9a-f]{12} for consumer\.sh: sanitize=[0-9]+\.[0-9]s total=[0-9]+\.[0-9]s' <<< "$L1A" && ok \
  || bad "C1 the built line must carry the sanitize time alone (got: $L1A)"
grep -qE 'share-mirror: reused [0-9a-f]{12} for consumer\.sh \(sanitize=[0-9]+\.[0-9]s when built\)' <<< "$L1B" && ok \
  || bad "C1 the second run must log a reuse (got: $L1B)"
[ -n "$D1A" ] && [ "$D1A" = "$D1B" ] && [ -f "$D1A/DONE" ] && [ -f "$D1A/mirror/notes/keep.md" ] && ok \
  || bad "C1 both runs must read one complete build (dirs '$D1A' '$D1B')"
K1=$(key12 "$L1A")

# ── C2 concurrent suites build once ─────────────────────────────────────────
# A python3 that holds sanitize.py until $T/c2-go exists, so the first run is
# mid-build for certain while the second reaches the build lock.
waitfor() { local i; for i in $(seq 300); do "$@" && return 0; sleep 0.1; done; return 1; }
mkdir -p "$T/slow"
cat > "$T/slow/python3" <<SH
#!/bin/bash
case "\$*" in *sanitize.py*)
  : > "$T/c2-in"
  for i in \$(seq 300); do [ -e "$T/c2-go" ] && break; sleep 0.1; done ;;
esac
exec $(command -v python3) "\$@"
SH
chmod +x "$T/slow/python3"
C2="$T/c2"
PATH="$T/slow:$PATH" SHARE_MIRROR_CACHE="$C2" bash "$R/tests/consumer.sh" > "$T/c2a.out" 2>&1 &
P1=$!
waitfor test -e "$T/c2-in" || bad "C2 fixture: the first run never reached sanitize"
PATH="$T/slow:$PATH" SHARE_MIRROR_CACHE="$C2" bash "$R/tests/consumer.sh" > "$T/c2b.out" 2>&1 &
P2=$!
at_lock() { ls -l "/proc/$P2/fd" 2>/dev/null | grep -q '\.build$'; }
waitfor at_lock || bad "C2 fixture: the second run never opened the build lock"
: > "$T/c2-go"
wait "$P1"; wait "$P2"
[ "$(grep -c ' share-mirror: built ' "$C2/share-mirror.log")" = 1 ] \
  && [ "$(grep -c ' share-mirror: reused ' "$C2/share-mirror.log")" = 1 ] && [ "$(entries "$C2")" = 1 ] && ok \
  || bad "C2 two concurrent runs must build once (log: $(cat "$C2/share-mirror.log" 2>/dev/null); entries: $(entries "$C2"))"

# ── C3 an uncommitted bin/share edit is a new key ───────────────────────────
echo '# bh-5543 C3' >> "$R/bin/share/mapping.py"
run "$C1"; K3=$(key12 "$NEW")
grep -q ' share-mirror: built ' <<< "$NEW" && [ -n "$K3" ] && [ "$K3" != "$K1" ] && ok \
  || bad "C3 an edited bin/share/mapping.py must rebuild under a new key (K1=$K1, got: $NEW)"
( cd "$R" && git checkout -q -- bin/share/mapping.py )
run "$C1"
grep -q " share-mirror: reused $K1 " <<< "$NEW" && ok \
  || bad "C3 reverting the edit must reuse the first build $K1 (got: $NEW)"

# ── C4 a new commit is a new key ────────────────────────────────────────────
echo 'another file' > "$R/notes/c4.md"
( cd "$R" && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m c4 )
run "$C1"; K4=$(key12 "$NEW")
grep -q ' share-mirror: built ' <<< "$NEW" && [ -n "$K4" ] && [ "$K4" != "$K1" ] && [ "$K4" != "$K3" ] && ok \
  || bad "C4 a new commit must rebuild under a new key (got: $NEW)"

# ── C5 a failed sanitize is never stored ────────────────────────────────────
C5="$T/c5"
sed -i '1s/.*/# something else/' "$R/README.md"
( cd "$R" && "${GIT[@]}" commit -q -am c5-broken )
run "$C5"; K5=$(key12 "$NEW")
[ "$(field san)" != 0 ] && [ -n "$(field san)" ] && [ "$(field how)" = failed ] && ok \
  || bad "C5 a moved anchor must report the sanitize failure to the caller (got: $OUT)"
[ -n "$K5" ] && [ "$(entries "$C5")" = 0 ] && ok \
  || bad "C5 a failed build must not be stored (key '$K5', entries $(entries "$C5"))"
run "$C5"
grep -q " share-mirror: failed $K5 " <<< "$NEW" && ! grep -q 'reused' <<< "$NEW" && ok \
  || bad "C5 the next run on the failed tree must build and fail fresh, never reuse (got: $NEW)"
( cd "$R" && git checkout -q HEAD~1 -- README.md && echo 'fixed' > notes/c5.md && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m c5-fixed )
run "$C5"
grep -q ' share-mirror: built ' <<< "$NEW" && [ "$(field san)" = 0 ] && ok \
  || bad "C5 the fixed tree must build (got: $NEW / $OUT)"
mkdir -p "$T/stop"
printf '#!/bin/bash\necho "python3 shim: stop here" >&2\nexit 97\n' > "$T/stop/python3"
chmod +x "$T/stop/python3"
N5=$(entries "$C5")
before=$(wc -l < "$C5/share-mirror.log")
OUT=$(PATH="$T/stop:$PATH" SHARE_MIRROR_CACHE="$C5" bash "$R/tests/consumer.sh" 2>/dev/null | tail -1)
NEW=$(tail -n +"$((before + 1))" "$C5/share-mirror.log")
grep -q 'share-mirror: private (python3 fingerprint) for consumer.sh' <<< "$NEW" && [ "$(field san)" = 97 ] \
  && [ "$(entries "$C5")" = "$N5" ] && ok \
  || bad "C5 a python3 with no fingerprint must get a private build, never a cached one (got: $NEW / $OUT)"

# ── C6 --worktree on a dirty checkout ───────────────────────────────────────
echo 'not committed' > "$R/notes/untracked-bh5543.md"
OUT=$(CHECK=notes/untracked-bh5543.md SHARE_MIRROR_CACHE="$C1" bash "$R/tests/consumer.sh" --worktree 2>&1)
grep -q 'share-mirror: private (dirty worktree) for consumer.sh' <<< "$OUT" && [ "$(field has)" = 1 ] && ok \
  || bad "C6 a dirty checkout under --worktree must be a private build carrying the uncommitted file (got: $OUT)"
rm -f "$R/notes/untracked-bh5543.md"
run "$C1"; K6=$(key12 "$NEW")
run "$C1" --worktree
[ -n "$K6" ] && grep -q " share-mirror: reused $K6 " <<< "$NEW" && ok \
  || bad "C6 a clean checkout under --worktree must reuse the HEAD build $K6 (got: $NEW)"

# ── C7 prune ────────────────────────────────────────────────────────────────
commit_one() { echo "$1" > "$R/notes/c7.md"; ( cd "$R" && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m "$1" ); }
C7="$T/c7"
commit_one a; run "$C7"; KA=$(key12 "$NEW"); [ -n "$KA" ] || bad "C7 fixture: no build logged (got: $NEW)"
commit_one b; SHARE_MIRROR_CACHE_KEEP=2 run "$C7"
commit_one c; SHARE_MIRROR_CACHE_KEEP=2 run "$C7"
[ "$(entries "$C7")" = 2 ] && ! compgen -G "$C7/$KA*/DONE" >/dev/null && ok \
  || bad "C7 with KEEP=2 the oldest of 3 builds must be pruned (entries: $(ls "$C7"))"
C7B="$T/c7b"
commit_one d; run "$C7B"; FD=$(field dir)
( exec 9>>"$FD.use"; flock -s 9; exec sleep 60 ) >/dev/null 2>&1 &
HOLD=$!
waitfor grep -q '^sleep' "/proc/$HOLD/cmdline" || bad "C7 fixture: the holder never took the lock"
commit_one e; SHARE_MIRROR_CACHE_KEEP=2 run "$C7B"
commit_one f; SHARE_MIRROR_CACHE_KEEP=2 run "$C7B"
[ -f "$FD/DONE" ] && [ "$(entries "$C7B")" = 3 ] && ok \
  || bad "C7 an entry a suite still holds must survive prune (entries: $(ls "$C7B"))"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null

# ── C8 no DONE, no reuse ────────────────────────────────────────────────────
commit_one g; run "$T/c8probe"
KG=$(basename "$(field dir)")
C8="$T/c8"
mkdir -p "$C8/$KG/mirror" "$C8/$KG.tmp.1/mirror"
echo stale > "$C8/$KG/mirror/stale.md"; echo 0 > "$C8/$KG/sanitize.rc"; echo 1 > "$C8/$KG/sanitize.ms"
run "$C8"
grep -q ' share-mirror: built ' <<< "$NEW" && [ -f "$C8/$KG/DONE" ] && [ ! -e "$C8/$KG/mirror/stale.md" ] && ok \
  || bad "C8 an entry without DONE must be rebuilt, never read (got: $NEW)"

# ── L1 the real suites over one build, with a planted leak ──────────────────
CL="$T/clone"
git clone -q --local "$DIR" "$CL" 2>/dev/null || bad "L1 fixture: cannot clone $DIR"
# The clone is this checkout as it stands (uncommitted edits included), so the
# suites under test are the ones in the working tree.
( cd "$DIR" && git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - ) | tar -C "$CL" -xf -
mkdir -p "$CL/notes"
printf 'OAUTH_TOKEN=sk-%s\n' "notonanyallowlist0001" > "$CL/notes/planted-leak.txt"
( cd "$CL" && "${GIT[@]}" add -A && "${GIT[@]}" commit -q --no-verify -m 'bh-5543 L1 snapshot + planted leak' ) \
  || bad "L1 fixture: cannot commit the snapshot"
CC="$T/cl-cache"
SHARE_MIRROR_CACHE="$CC" bash "$CL/tests/share-publish-clean.bh-795-test.sh" > "$T/l1-795.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'leakcheck refused' "$T/l1-795.out" && ok \
  || bad "L1 bh-795 must refuse the planted leak (rc=$RC: $(grep FAIL "$T/l1-795.out" | head -3))"
grep -q '^share-mirror: built ' "$T/l1-795.out" && ok || bad "L1 bh-795 must build the mirror (got: $(grep share-mirror "$T/l1-795.out"))"
SHARE_MIRROR_CACHE="$CC" bash "$CL/tests/share-mirror-clean-test.sh" > "$T/l1-mc.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'planted-leak.txt' "$T/l1-mc.out" && ok \
  || bad "L1 share-mirror-clean must refuse and name planted-leak.txt (rc=$RC: $(grep FAIL "$T/l1-mc.out" | head -3))"
grep -q '^share-mirror: reused ' "$T/l1-mc.out" && ok || bad "L1 share-mirror-clean must reuse the build (got: $(grep share-mirror "$T/l1-mc.out"))"
SHARE_MIRROR_CACHE="$CC" bash "$CL/tests/publish-cromford-brand.bh-4901-test.sh" > "$T/l1-br.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "L1 publish-cromford-brand must pass on the shared build (rc=$RC: $(grep FAIL "$T/l1-br.out" | head -3))"
grep -q '^share-mirror: reused ' "$T/l1-br.out" && ok || bad "L1 publish-cromford-brand must reuse the build (got: $(grep share-mirror "$T/l1-br.out"))"
[ "$(grep -c ' share-mirror: built ' "$CC/share-mirror.log")" = 1 ] && ok \
  || bad "L1 three suites on one tree must build once (log: $(cat "$CC/share-mirror.log"))"

echo "share-mirror-cache.bh-5543: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
