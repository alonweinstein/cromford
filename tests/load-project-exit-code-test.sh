#!/bin/bash
# tests/load-project-exit-code-test.sh — when the box-side bootstrap block
# fails, bin/load-project.sh must say so in its own words and exit non-zero.
#
# WHY THIS EXISTS. The registry row, the prompt and the crontab are PUBLISHED
# before the loader ever reaches the box, so a remote block that dies leaves a
# project that every hub lane believes is live on a machine that was never set
# up. The propagation used to rest entirely on `set -e` around the ssh heredoc,
# which is one stray `|| true` away from reporting success — and the loader
# printed nothing of its own, so the only clue was the remote FATAL scrolling
# past above a "== LOADED" banner that never came.
#
# Case B is the half that keeps the guard honest: a green remote block must
# still finish the run and print "== LOADED".
#
# Drives the real bin/load-project.sh; ssh, gh and the network verbs of git are
# stubs on a prepended PATH, and the box is always "zzz-box" so the local-box
# branch is never taken. Nothing here reaches a real machine.
#
# Run from anywhere: tests/load-project-exit-code-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

REAL_GIT=$(command -v git); export REAL_GIT
export SSH_STUB_FAIL="$T/ssh-fail"

mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
# The remote block arrives on stdin and is never executed here: the stub only
# decides whether the box answered yes or no.
cat > "$T/stub/ssh" <<'STUB'
#!/bin/bash
cat >/dev/null
if [ -f "${SSH_STUB_FAIL:-/nonexistent}" ]; then
  echo "FATAL: stub remote refused"
  exit 1
fi
exit 0
STUB
chmod +x "$T/stub/gh" "$T/stub/git" "$T/stub/ssh"

ROW_A='alpha         Acme/alpha                 -                                    -   2  box-small'

mkrepo() { # mkrepo <dir> — a scratch cromford checkout with a clean registry
  local R="$1"
  mkdir -p "$R/prompts"
  cp -r "$DIR/bin" "$R/bin"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
  # The doorbell check at the end of a successful run sends a heartbeat; in a
  # fixture that is the one call that would leave the scratch tree.
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/beat.sh"
  chmod +x "$R/bin/beat.sh"
  printf '%s\n' "$ROW_A" > "$R/fleet.conf"
  (
    cd "$R" || exit 1
    "$REAL_GIT" init -q .
    "$REAL_GIT" config user.email t@t
    "$REAL_GIT" config user.name t
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -qm base
  ) >/dev/null 2>&1
}

load() { # load <repo dir> [args...] — run the real loader, capture rc + output
  local R="$1"; shift
  ( cd "$R" && PATH="$T/stub:$PATH" HARNESS="$T/h" bash bin/load-project.sh "$@" ) >"$T/out" 2>&1
  echo $?
}

# ── A. the remote block fails ───────────────────────────────────────────────
: > "$SSH_STUB_FAIL"
mkrepo "$T/a"
RC=$(load "$T/a" acme/widget --project widget --box zzz-box)
[ "$RC" -ne 0 ] && ok || bad "A the loader must exit non-zero when the box fails (rc=$RC)"
eq "A the exact exit code is the remote's" "$RC" "1"
# The remote's own FATAL ("stub remote refused") names no box and claims no
# rung, so this only passes on a FATAL line the LOADER wrote: one line that
# names the box AND states honestly how far the load actually got.
LOADER_FATAL=$(grep -E '^FATAL:.*zzz-box' "$T/out" || true)
[ -n "$LOADER_FATAL" ] && ok || bad "A no loader-side FATAL names the box: $(cat "$T/out")"
case "$LOADER_FATAL" in
  *"NOT set up"*) ok ;;
  *) bad "A the loader's FATAL must say the box is NOT set up, got '$LOADER_FATAL'" ;;
esac
case "$LOADER_FATAL" in
  *PUBLISHED*) ok ;;
  *) bad "A the loader's FATAL must say the registry row was already published, got '$LOADER_FATAL'" ;;
esac
grep -q '== LOADED' "$T/out" && bad "A a failed load must never print == LOADED" || ok

# ── B. negative: a green remote block still completes the run ───────────────
rm -f "$SSH_STUB_FAIL"
mkrepo "$T/b"
RC=$(load "$T/b" acme/widget --project widget --box zzz-box)
eq "B rc" "$RC" "0"
grep -q '== LOADED: widget' "$T/out" && ok || bad "B a green load must print == LOADED: $(cat "$T/out")"
grep -q '^FATAL:' "$T/out" && bad "B a green load must print no FATAL: $(cat "$T/out")" || ok

echo "load-project-exit-code-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
