#!/bin/bash
# tests/mc-askpass-cleanup.bh-4464-test.sh — no mc-askpass-* file survives any
# exit path of a mc_git_auth caller (BH-4464: 32,510 of them filled the hub's
# /tmp by 2026-10-04).
#
# THE LEAK. mc_patch_id and mc_patch_same used to call `wt=$(mc_patch_wt …)`.
# mc_patch_wt arms mc_git_auth, so the askpass helper was mktemp'd inside that
# command substitution and MC_ASKPASS died with it; the caller's
# mc_git_auth_clear then found MC_ASKPASS empty and removed nothing. One file
# per call. mc_patch_wt now sets MC_PATCH_WT and runs in the caller's shell.
#
#   a  mc_git_auth ok, then mc_git_auth_clear
#   b  mc_git_auth refused by every ls-remote, then mc_git_auth_clear
#   c  id=$(mc_patch_id …) succeeds (non-empty id)
#   d  mc_patch_id with the fetch failing
#   e  mc_patch_id with an empty merge-base
#   f  mc_patch_same success, and with the fetch failing
#   g  mc_land_main_sha
#   h  mc_rebase refused at `worktree add`
#   i  mc_rebase refused at the tmp-full precheck
#
# The real bin/lib/merge-conductor-lib.sh and the real mc_git_auth. A git shim on
# PATH answers the network verbs (ls-remote, fetch) and hands every other verb
# to the real git over a local fixture repo; gh_repo_use_token (the router,
# which would probe GitHub) is a no-op and GH_TOKEN is its answer.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$DIR/bin/lib/mc/settle.sh" ] || exit 1   # impact: this suite pins bin/lib/mc/settle.sh
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: and mc_git_auth in bin/lib/mc/rebase.sh
REALGIT=$(command -v git) || { echo "git missing"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HARNESS="$T/h" MC_REPOS="$T/repos"
mkdir -p "$T/h/config" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" \
         "$T/repos" "$T/fakebin" "$T/tmp"
cp "$DIR/config/generated-paths.conf" "$T/h/config/" 2>/dev/null || true

# The fixture: a bare remote with main and a PR branch, the hub's clone of it.
W="$T/work"
"$REALGIT" init -q --bare -b main "$T/remote.git"
"$REALGIT" init -q -b main "$W"; "$REALGIT" -C "$W" remote add origin "$T/remote.git"
seq 1 20 > "$W/f.txt"; "$REALGIT" -C "$W" add -A; "$REALGIT" -C "$W" commit -qm base
"$REALGIT" -C "$W" push -q origin main
"$REALGIT" -C "$W" checkout -qb feature-x; echo pr >> "$W/f.txt"; "$REALGIT" -C "$W" commit -qam pr
PR=$("$REALGIT" -C "$W" rev-parse HEAD); "$REALGIT" -C "$W" push -q origin feature-x
"$REALGIT" clone -q "$T/remote.git" "$T/repos/demo-os"
MAIN=$("$REALGIT" -C "$T/repos/demo-os" rev-parse origin/main)

# The shim. LS_RC / FETCH_RC / WT_FAIL are read from files so a case can flip
# them without re-exporting into every subshell.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in
  *" ls-remote "*)
    rc=\$(cat "$T/ls-rc" 2>/dev/null || echo 0); [ "\$rc" = 0 ] || exit "\$rc"
    case " \$* " in *" refs/heads/main "*) printf '%s\trefs/heads/main\n' "$MAIN" ;; esac
    exit 0 ;;
  *" fetch "*) exit "\$(cat "$T/fetch-rc" 2>/dev/null || echo 0)" ;;
  *" worktree add "*)
    if [ -e "$T/wt-fail" ]; then echo "Preparing worktree (detached HEAD ccfa24ab9)" >&2; echo "fatal: X" >&2; exit 128; fi ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/x 1000000 1000 \$(cat "$T/df-kb" 2>/dev/null || echo 10000000) 9% /tmp"
EOF
chmod +x "$T/fakebin/df"
export PATH="$T/fakebin:$PATH"

# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
gh_repo_use_token() { return 0; }
export GH_TOKEN=tok-test TMPDIR="$T/tmp"
unset REBASE_ON_POOL MC_TMP_MIN_FREE_MB

left() { find "$TMPDIR" -maxdepth 1 -name 'mc-askpass-*' | wc -l | tr -d ' '; }
setrc() { echo "${2:-0}" > "$T/$1"; }
check() { local n; n=$(left); [ "$n" = 0 ] && ok || bad "$1: $n mc-askpass-* left in TMPDIR"; find "$TMPDIR" -maxdepth 1 -name 'mc-askpass-*' -delete; }
S=example-org/demo-os P=demo-os

# ---- a
setrc ls-rc 0; setrc fetch-rc 0
mc_git_auth "$S"; rc=$?
[ "$rc" = 0 ] && ok || bad "a mc_git_auth must succeed against the shim, got $rc"
[ "$(left)" = 1 ] && ok || bad "a mc_git_auth must have armed one helper (the fixture is live), saw $(left)"
mc_git_auth_clear; check "a mc_git_auth ok + clear"

# ---- b
setrc ls-rc 128
mc_git_auth "$S"; rc=$?
[ "$rc" = 1 ] && ok || bad "b every candidate refused is rc 1, got $rc"
mc_git_auth_clear; check "b mc_git_auth refused + clear"
setrc ls-rc 0

# ---- c
id=$(mc_patch_id "$S" "$P" "$PR"); rc=$?
[ "$rc" = 0 ] && [ -n "$id" ] && ok || bad "c mc_patch_id must compute an id, rc=$rc id=[$id]"
check "c mc_patch_id success"
# The parent's shell, too: the substitution is the production shape, but a
# direct call must not leave MC_ASKPASS pointing at a file either.
mc_patch_id "$S" "$P" "$PR" >/dev/null
[ -z "$MC_ASKPASS" ] && ok || bad "c a direct mc_patch_id must leave MC_ASKPASS cleared, got [$MC_ASKPASS]"
check "c mc_patch_id direct call"

# ---- d
setrc fetch-rc 1
id=$(mc_patch_id "$S" "$P" "$PR"); rc=$?
[ "$rc" = 1 ] && ok || bad "d a failed fetch is rc 1, got $rc"
check "d mc_patch_id fetch failed"
setrc fetch-rc 0

# ---- e
id=$(mc_patch_id "$S" "$P" 0123456789abcdef0123456789abcdef01234567); rc=$?
[ "$rc" = 1 ] && ok || bad "e an empty merge-base is rc 1, got $rc"
check "e mc_patch_id empty merge-base"

# ---- f
out=$(mc_patch_same "$S" "$P" "$PR" "$PR"); rc=$?
[ "$rc" = 0 ] && [ "${out#same:}" != "$out" ] && ok || bad "f mc_patch_same on the same head must be same:…, rc=$rc out=[$out]"
check "f mc_patch_same success"
setrc fetch-rc 1
out=$(mc_patch_same "$S" "$P" "$PR" "$PR"); rc=$?
[ "$rc" = 1 ] && ok || bad "f a failed fetch is rc 1, got $rc"
check "f mc_patch_same fetch failed"
setrc fetch-rc 0

# ---- g
sha=$(mc_land_main_sha "$S" main); rc=$?
[ "$rc" = 0 ] && [ "$sha" = "$MAIN" ] && ok || bad "g mc_land_main_sha must answer main's sha, rc=$rc [$sha]"
check "g mc_land_main_sha"

# ---- h
: > "$T/wt-fail"
mc_rebase "$S" "$P" feature-x "$PR" https://github.com/example-org/demo-os/pull/7 >/dev/null; rc=$?
[ "$rc" = 4 ] && ok || bad "h a failed worktree add is rc 4, got $rc"
check "h mc_rebase refused at worktree add"
rm -f "$T/wt-fail"

# ---- i
echo 0 > "$T/df-kb"
mc_rebase "$S" "$P" feature-x "$PR" https://github.com/example-org/demo-os/pull/7 >/dev/null; rc=$?
[ "$rc" = 8 ] && ok || bad "i a full TMPDIR is rc 8, got $rc"
check "i mc_rebase refused at the tmp precheck"
rm -f "$T/df-kb"

echo "mc-askpass-cleanup.bh-4464: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
