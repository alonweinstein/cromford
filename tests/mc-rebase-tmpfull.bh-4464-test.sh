#!/bin/bash
# tests/mc-rebase-tmpfull.bh-4464-test.sh — a full hub /tmp made every conductor
# rebase fail as an anonymous rc 4 whose logged reason was git's PROGRESS line
# (BH-4464). Two fixes in bin/lib/mc/rebase.sh, pinned here:
#
#   1   mc_rebase: `worktree add` prints a progress line, then error:, then
#       fatal: X, and exits 128 -> rc 4, the log names `fatal: X` and NOT
#       `Preparing worktree` (mc_git_fail_line replaced `head -1`)
#   1b  the same through mc_restack
#   1c  the extractor alone: an `error` word mid-line is not picked over a later
#       fatal:; no fatal/error line -> the last non-empty line; empty -> (no stderr)
#   2   a df reporting 0 KB free -> mc_rebase rc 8, `tmp full` logged, NO git
#       call at all (not even the credential probe), no mc-askpass-* left
#   3   the same for mc_restack -> rc 8
#   4   a df that exits 1 -> fail open: the flow reaches `worktree add`
#   4b  a df that prints `-` for Available -> fail open
#   5   MC_TMP_MIN_FREE_MB=0 with 0 free -> not refused; =abc with 100 MB free
#       -> refused (the 256 default, never 0); free exactly = minimum -> not refused
#   6   rebase_result rc 8 (the production reader of the detached job's rc)
#       logs `tmp full` and writes NEEDS_REBASE to the conductor's row file
#
# The real bin/lib/merge-conductor-lib.sh and the real mc_git_auth. Only git and
# df are fakes on PATH, plus gh_repo_use_token (the token ROUTER, which would
# probe GitHub); GH_TOKEN is the token it would have exported.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: this suite pins bin/lib/mc/rebase.sh

export HARNESS="$T/h" MC_REPOS="$T/repos"
mkdir -p "$T/h/config" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" \
         "$T/repos/demo-os/.git" "$T/fakebin" "$T/tmp"
cp "$DIR/config/generated-paths.conf" "$T/h/config/" 2>/dev/null || true
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
gh_repo_use_token() { return 0; }
export GH_TOKEN=tok-test TMPDIR="$T/tmp"
unset REBASE_ON_POOL MC_TMP_MIN_FREE_MB

# The fake git: every call is logged; the credential probe, set-url and fetch
# succeed; `worktree add` fails the way it did on the hub on 2026-10-04.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-calls"
case " \$* " in
  *" worktree add "*)
    echo "Preparing worktree (detached HEAD ccfa24ab9) error-handling" >&2
    echo "error: unable to write file a" >&2
    echo "fatal: X" >&2
    exit 128 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
# df_avail <kb|-> — the stub df prints that in the Available column; FAIL -> rc 1.
df_avail() {
  if [ "$1" = FAIL ]; then printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/df"
  else printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1000000 1000 %s 99%% /tmp"\n' "$1" > "$T/fakebin/df"; fi
  chmod +x "$T/fakebin/df"
}
export PATH="$T/fakebin:$PATH"
askpass_left() { find "$TMPDIR" -maxdepth 1 -name 'mc-askpass-*' | wc -l | tr -d ' '; }
reset() { : > "$T/git-calls"; : > "$MCLOG"; }
URL=https://github.com/example-org/demo-os/pull/7
HEAD_SHA=1111111111111111111111111111111111111111
rebase()  { mc_rebase example-org/demo-os demo-os feature-x "$HEAD_SHA" "$URL"; }
restack() { mc_restack example-org/demo-os demo-os feature-x "$HEAD_SHA" parent-x main "$URL"; }

# ---- 1: mc_rebase logs the fatal line, not the progress line
df_avail 10000000; reset
rebase >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "1 a failed worktree add is rc 4, got $rc"
grep -q 'worktree add on the hub clone failed — .*fatal: X' "$MCLOG" && ok || bad "1 the log must name 'fatal: X': $(cat "$MCLOG")"
grep -q 'Preparing worktree' "$MCLOG" && bad "1 the progress line must not be the logged reason: $(cat "$MCLOG")" || ok
[ "$(askpass_left)" = 0 ] && ok || bad "1 no mc-askpass-* may be left behind"

# ---- 1b: the same through mc_restack
reset
restack >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "1b a failed worktree add is rc 4, got $rc"
grep -q 'restack: worktree add on the hub clone failed — .*fatal: X' "$MCLOG" && ok || bad "1b the log must name 'fatal: X': $(cat "$MCLOG")"
grep -q 'Preparing worktree' "$MCLOG" && bad "1b the progress line must not be the logged reason" || ok

# ---- 1c: the extractor
out=$(mc_git_fail_line "$(printf 'Preparing worktree (error-handling)\nerror: a\nerror: b\nfatal: Could not reset index file\n')")
[ "$out" = "fatal: Could not reset index file" ] && ok || bad "1c the LAST fatal/error line: [$out]"
out=$(mc_git_fail_line "$(printf 'fatal: early\nerror: later one\n')")
[ "$out" = "error: later one" ] && ok || bad "1c the last of fatal/error wins: [$out]"
out=$(mc_git_fail_line "$(printf 'first\nsecond line\n\n')")
[ "$out" = "second line" ] && ok || bad "1c no fatal/error -> last non-empty line: [$out]"
out=$(mc_git_fail_line "")
[ "$out" = "(no stderr)" ] && ok || bad "1c empty stderr -> (no stderr): [$out]"
out=$(mc_git_fail_line "fatal: auth ghp_abcdefghijklmnop failed")
[ "$out" = "fatal: auth REDACTED failed" ] && ok || bad "1c a token-shaped string is redacted: [$out]"

# ---- 2: a full TMPDIR refuses mc_rebase before any git work
df_avail 0; reset
rebase >/dev/null; rc=$?
[ "$rc" = 8 ] && ok || bad "2 a full TMPDIR is rc 8, got $rc"
grep -q "$URL rebase: tmp full (0 MB free on $TMPDIR, need 256 MB) — rc 8, nothing fetched" "$MCLOG" && ok \
  || bad "2 the log must say tmp full: $(cat "$MCLOG")"
[ -s "$T/git-calls" ] && bad "2 no git call may run on a full tmp: $(cat "$T/git-calls")" || ok
[ "$(askpass_left)" = 0 ] && ok || bad "2 no mc-askpass-* may be created on a full tmp"

# ---- 3: the same for mc_restack
reset
restack >/dev/null; rc=$?
[ "$rc" = 8 ] && ok || bad "3 a full TMPDIR is rc 8 for restack, got $rc"
grep -q "$URL restack: tmp full (0 MB free" "$MCLOG" && ok || bad "3 the log must say tmp full: $(cat "$MCLOG")"
[ -s "$T/git-calls" ] && bad "3 no git call may run on a full tmp: $(cat "$T/git-calls")" || ok
[ "$(askpass_left)" = 0 ] && ok || bad "3 no mc-askpass-* may be created on a full tmp"

# ---- 4: an unreadable df fails open
df_avail FAIL; reset
rebase >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "4 df rc 1 must fail open (rc 4 from worktree add), got $rc"
grep -q ' worktree add ' "$T/git-calls" && ok || bad "4 df rc 1 must reach worktree add"
grep -q 'tmp full' "$MCLOG" && bad "4 df rc 1 must not log tmp full" || ok
df_avail -; reset
rebase >/dev/null; rc=$?
[ "$rc" = 4 ] && grep -q ' worktree add ' "$T/git-calls" && ok || bad "4b a df printing '-' must fail open, got rc $rc"

# ---- 5: the knob
df_avail 0; reset
MC_TMP_MIN_FREE_MB=0 rebase >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "5 MC_TMP_MIN_FREE_MB=0 turns the check off, got rc $rc"
df_avail 102400; reset
MC_TMP_MIN_FREE_MB=abc rebase >/dev/null; rc=$?
[ "$rc" = 8 ] && ok || bad "5 MC_TMP_MIN_FREE_MB=abc must fall back to 256 (100 MB free refused), got rc $rc"
reset
MC_TMP_MIN_FREE_MB=100 rebase >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "5 free exactly equal to the minimum is not refused, got rc $rc"
df_avail 262143; reset
rebase >/dev/null; rc=$?
[ "$rc" = 8 ] && ok || bad "5 one KB under the 256 MB default is refused, got rc $rc"

# ---- 6: rebase_result reads rc 8
: > "$MCLOG"
rebase_result "demo-os#7" "$URL" "" "$HEAD_SHA" "$HEAD_SHA" APPROVE CLEAN 8 ""
grep -q 'demo-os#7 rebase refused: hub tmp full — nothing spent, retried next tick' "$MCLOG" && ok \
  || bad "6 rebase_result rc 8 must log tmp full: $(cat "$MCLOG")"
[ "$(mc_row_field "demo-os#7" 2)" = NEEDS_REBASE ] && ok || bad "6 rc 8 must write NEEDS_REBASE: $(mc_row_get "demo-os#7")"
[ "$(mc_row_field "demo-os#7" 7)" = "tmp full, retry" ] && ok || bad "6 the row reason: $(mc_row_get "demo-os#7")"

echo "mc-rebase-tmpfull.bh-4464: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
