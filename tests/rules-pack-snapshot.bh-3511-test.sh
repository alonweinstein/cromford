#!/bin/bash
# tests/rules-pack-snapshot.bh-3511-test.sh — the rules pack's isolated runner
# (BH-3511, BH-3477.2): bin/lib/rules-pack-snapshot.sh, driven through its three
# real functions with a stub setpriv on PATH.
#
#   S1.  setpriv cannot switch -> probe rc 125, `setpriv cannot switch`.
#   S1b. setpriv switches -> probe rc 0, run with the exact probe flags.
#   S1c. no setpriv at all -> probe rc 125, `setpriv cannot switch`.
#   S2.  build: repo has base+head commits, origin/main = printed base sha,
#        the diff equals the source's fork..head diff, base/ is the fork tree
#        in one commit, the whole workdir belongs to nobody.
#   S3.  an uncommitted edit in the source never reaches the snapshot.
#   S4.  run: the command's rc, in <dir>, under env -i with only the 7 names;
#        a planted GH_TOKEN does not reach it; the caller's cwd is untouched.
#   S4b. RATCHET_BASE unset -> origin/main.
#   S5.  a bad fork or head sha -> build rc 125, stdout empty, step named.
#   S6.  a pre-existing <workdir>/repo -> build rc 125, left as it was.
#   S7.  too few args -> build/run rc 125; a missing <dir> -> run rc 125.
# Run from anywhere: tests/rules-pack-snapshot.bh-3511-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SNAP="$DIR/bin/lib/rules-pack-snapshot.sh"

[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
# snap <function> <args...> — the lib's real function, sourced into a fresh bash
snap() { run bash -c '. "$1"; shift; "$@"' _ "$SNAP" "$@"; }
# A root reader of a nobody-owned repo is "dubious ownership" to git.
sgit() { git -c safe.directory='*' "$@"; }

# --- stubs ----------------------------------------------------------------
# setpriv: STUB_SETPRIV=fail|pass|exec, argv logged to $STUB_LOG.
mkdir -p "$T/stub" "$T/nosetpriv"
cat > "$T/stub/setpriv" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$STUB_SETPRIV" in
  fail) exit 1 ;;
  pass) exit 0 ;;
  exec) while [ "$#" -gt 0 ] && [ "$1" != env ]; do shift; done; exec "$@" ;;
esac
exit 99
EOF
chmod +x "$T/stub/setpriv"
if [ "$(id -u)" -ne 0 ]; then
  # Not root: chown to nobody cannot work, so the stub records the call.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/chown.log"\n' "$T" > "$T/stub/chown"
  chmod +x "$T/stub/chown"
fi
export PATH="$T/stub:$PATH" STUB_LOG="$T/setpriv.log"

# --- fixture source repo: F (a, b, .hid/x) then H (a edited, b and .hid gone, c)
SRC="$T/src"
mkdir -p "$SRC/.hid"
git -C "$SRC" init -q
printf 'a1\n' > "$SRC/a"; printf 'b1\n' > "$SRC/b"; printf 'x\n' > "$SRC/.hid/x"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm F
F=$(git -C "$SRC" rev-parse HEAD)
printf 'a2\n' > "$SRC/a"; printf 'c1\n' > "$SRC/c"; git -C "$SRC" rm -q b .hid/x
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm H
H=$(git -C "$SRC" rev-parse HEAD)

# --- S1 / S1b / S1c -------------------------------------------------------
: > "$STUB_LOG"
STUB_SETPRIV=fail snap rp_snapshot_probe
[ "$RC" -eq 125 ] && ok || bad "S1 probe rc $RC (want 125)"
case "$ERR" in *"setpriv cannot switch"*) ok ;; *) bad "S1 stderr lacks 'setpriv cannot switch': $ERR" ;; esac
[ -z "$OUT" ] && ok || bad "S1 probe wrote stdout: $OUT"

: > "$STUB_LOG"
STUB_SETPRIV=pass snap rp_snapshot_probe
[ "$RC" -eq 0 ] && ok || bad "S1b probe rc $RC (want 0): $ERR"
[ -z "$OUT" ] && ok || bad "S1b probe wrote stdout: $OUT"
[ "$(cat "$STUB_LOG")" = "--reuid nobody --regid nogroup --clear-groups true" ] && ok \
  || bad "S1b probe argv [$(cat "$STUB_LOG")]"

run env PATH="$T/nosetpriv" "$BASH" -c '. "$1"; rp_snapshot_probe' _ "$SNAP"
[ "$RC" -eq 125 ] && ok || bad "S1c probe without setpriv rc $RC (want 125)"
case "$ERR" in *"setpriv cannot switch"*"not installed"*) ok ;; *) bad "S1c stderr: $ERR" ;; esac

# --- S2 -------------------------------------------------------------------
W="$T/w2"
snap rp_snapshot_build "$SRC" "$F" "$H" "$W"
[ "$RC" -eq 0 ] && ok || bad "S2 build rc $RC (want 0): $ERR"
BASE_SHA="$OUT"
[ "$(sgit -C "$W/repo" rev-list --count HEAD 2>/dev/null)" = 2 ] && ok || bad "S2 repo commit count != 2"
[ "$(sgit -C "$W/repo" log --format=%s 2>/dev/null | tr '\n' ' ')" = "head base " ] && ok || bad "S2 repo subjects are not 'head base'"
[ -n "$BASE_SHA" ] && [ "$(sgit -C "$W/repo" rev-parse refs/remotes/origin/main 2>/dev/null)" = "$BASE_SHA" ] && ok \
  || bad "S2 origin/main != printed sha [$BASE_SHA]"
[ "$(sgit -C "$W/repo" rev-parse HEAD~1 2>/dev/null)" = "$BASE_SHA" ] && ok || bad "S2 printed sha is not the base commit"
want_diff=$(git -C "$SRC" diff "$F" "$H")
got_diff=$(sgit -C "$W/repo" diff origin/main HEAD 2>/dev/null)
[ -n "$want_diff" ] && [ "$got_diff" = "$want_diff" ] && ok || bad "S2 snapshot diff differs from the source diff"
[ -z "$(sgit -C "$W/repo" status --porcelain 2>/dev/null)" ] && ok || bad "S2 repo worktree is not clean"
[ ! -e "$W/repo/b" ] && [ ! -e "$W/repo/.hid" ] && ok || bad "S2 deleted files survived in repo"
[ "$(sgit -C "$W/base" rev-list --count HEAD 2>/dev/null)" = 1 ] && ok || bad "S2 base commit count != 1"
[ "$(sgit -C "$W/base" ls-tree -r HEAD 2>/dev/null)" = "$(git -C "$SRC" ls-tree -r "$F")" ] && ok \
  || bad "S2 base tree is not the fork tree"
[ -d "$W/home" ] && [ -d "$W/tmp" ] && ok || bad "S2 home/tmp not made"
if [ "$(id -u)" -eq 0 ]; then
  owners=$(stat -c %U:%G "$W" "$W/repo" "$W/repo/a" "$W/repo/.git" "$W/base" "$W/home" "$W/tmp" 2>/dev/null | sort -u)
  [ "$owners" = "nobody:nogroup" ] && ok || bad "S2 owners [$owners] (want nobody:nogroup)"
else
  grep -qx -- "-R nobody:nogroup $W" "$T/chown.log" 2>/dev/null && ok || bad "S2 chown not called with -R nobody:nogroup $W"
fi

# --- S3 -------------------------------------------------------------------
printf 'dirty\n' > "$SRC/a"
W="$T/w3"
snap rp_snapshot_build "$SRC" "$F" "$H" "$W"
[ "$RC" -eq 0 ] && ok || bad "S3 build rc $RC (want 0): $ERR"
[ "$(cat "$W/repo/a" 2>/dev/null)" = "$(git -C "$SRC" show "$H:a")" ] && ok || bad "S3 snapshot a is not H:a: $(cat "$W/repo/a" 2>/dev/null)"
git -C "$SRC" checkout -q -- a

# --- S4 / S4b -------------------------------------------------------------
mkdir -p "$T/w4/repo" "$T/w4/home" "$T/w4/tmp"
: > "$STUB_LOG"
run env RATCHET_BASE=rb1 GH_TOKEN=planted-secret STUB_SETPRIV=exec \
  bash -c '. "$1"; rp_snapshot_run "$2" bash -c "env > \"\$1\"; pwd >> \"\$1\"; exit 7" _ "$3"; r=$?; echo "cwd=$(pwd)"; exit "$r"' \
  _ "$SNAP" "$T/w4/repo" "$T/env4"
[ "$RC" -eq 7 ] && ok || bad "S4 run rc $RC (want 7): $ERR"
[ "$OUT" = "cwd=$T" ] && ok || bad "S4 caller cwd moved: $OUT"
E4=$(cat "$T/env4" 2>/dev/null)
for want in RATCHET_BASE=rb1 TI_BASE=origin/main "HOME=$T/w4/home" "TMPDIR=$T/w4/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 "PATH=$PATH"; do
  grep -qxF -- "$want" <<<"$E4" && ok || bad "S4 env lacks $want"
done
grep -q GH_TOKEN <<<"$E4" && bad "S4 GH_TOKEN reached the command" || ok
extra=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$E4" | tr -d = \
  | grep -vxE 'PATH|HOME|TMPDIR|LANG|LC_ALL|RATCHET_BASE|TI_BASE|PWD|SHLVL|_' | tr '\n' ' ')
[ -z "$extra" ] && ok || bad "S4 unexpected env names reached the command: $extra"
[ "$(tail -n1 <<<"$E4")" = "$T/w4/repo" ] && ok || bad "S4 command did not run in <dir>"
case "$(cat "$STUB_LOG")" in "--reuid nobody --regid nogroup --clear-groups env -i "*) ok ;;
  *) bad "S4 setpriv argv [$(cat "$STUB_LOG")]" ;; esac

run env -u RATCHET_BASE -u TI_BASE STUB_SETPRIV=exec \
  bash -c '. "$1"; rp_snapshot_run "$2" bash -c "env > \"\$1\"" _ "$3"' _ "$SNAP" "$T/w4/repo" "$T/env4b"
[ "$RC" -eq 0 ] && ok || bad "S4b run rc $RC (want 0): $ERR"
grep -qx RATCHET_BASE=origin/main "$T/env4b" && ok || bad "S4b RATCHET_BASE is not origin/main"

# --- S5 -------------------------------------------------------------------
BOGUS=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
snap rp_snapshot_build "$SRC" "$BOGUS" "$H" "$T/w5"
[ "$RC" -eq 125 ] && ok || bad "S5 bad fork rc $RC (want 125)"
[ -z "$OUT" ] && ok || bad "S5 bad fork wrote stdout: $OUT"
case "$ERR" in *"rules-pack: snapshot:"*) ok ;; *) bad "S5 stderr names no step: $ERR" ;; esac
snap rp_snapshot_build "$SRC" "$F" "$BOGUS" "$T/w5b"
[ "$RC" -eq 125 ] && ok || bad "S5 bad head rc $RC (want 125)"
[ -z "$OUT" ] && ok || bad "S5 bad head wrote stdout: $OUT"

# --- S6 -------------------------------------------------------------------
mkdir -p "$T/w6/repo"; printf 'keep\n' > "$T/w6/repo/mine"
snap rp_snapshot_build "$SRC" "$F" "$H" "$T/w6"
[ "$RC" -eq 125 ] && ok || bad "S6 pre-existing repo rc $RC (want 125)"
[ -z "$OUT" ] && ok || bad "S6 wrote stdout: $OUT"
[ "$(cat "$T/w6/repo/mine" 2>/dev/null)" = keep ] && [ ! -e "$T/w6/repo/.git" ] && ok || bad "S6 pre-existing repo was touched"

# --- S7 -------------------------------------------------------------------
snap rp_snapshot_build "$SRC" "$F" "$H"
[ "$RC" -eq 125 ] && ok || bad "S7 build with 3 args rc $RC (want 125)"
STUB_SETPRIV=exec snap rp_snapshot_run "$T/w4/repo"
[ "$RC" -eq 125 ] && ok || bad "S7 run with no command rc $RC (want 125)"
STUB_SETPRIV=exec snap rp_snapshot_run "$T/nosuch" true
[ "$RC" -eq 125 ] && ok || bad "S7 run in a missing dir rc $RC (want 125)"

echo "rules-pack-snapshot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
