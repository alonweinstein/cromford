#!/bin/bash
# tests/rebind-same-patch.bh-2310-test.sh — the merge conductor's approval rebind
# recognises a head that only MERGED MAIN (BH-2310), against real git.
#
# bin/merge-conductor.sh calls rebind_patch_id on an approved PR whose head moved
# (`elif … rebind_patch_id …; then REVIEWED="$HEAD"`). rc 0 means the approval
# is rebound and no re-review is bought; rc 1 falls through to the overlap
# rebind and then to a paid Fable re-review. The whole-diff patch-id missed a fix
# round that only merged main whenever main touched a line near a hunk (#2131).
#
#   C1  reviewed R, then a clean main merge next to the PR hunk -> rc 0,
#       the ledger rebind called with the new head, reviewed-sha moved, and the
#       log names the same-patch rule
#   C2  reviewed R, then a real change behind a main merge     -> rc 1, no rebind
#   C3  a pure rebase still rebinds on the patch-id path (regression)
#   C4  the lib missing -> rc 1 on the C1 shape (fail closed, today's behaviour)
#   C5  a head that differs ONLY in whitespace inside the PR's own line -> rc 1
#       (the patch-id is --verbatim now; --stable stripped whitespace)
# Real git end to end: a bare remote, the hub's clone under MC_REPOS, the real
# bin/lib/merge-conductor-lib.sh. mc_git_auth and the ledger rebind are stubbed.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HARNESS="$T/h" MC_REPOS="$T/repos"
mkdir -p "$T/h/config" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/repos"
cp "$DIR/config/generated-paths.conf" "$T/h/config/" 2>/dev/null || true
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
# The seams: the remote is a local bare repo, and the ledger rebind is recorded.
mc_git_auth() { MC_REMOTE="$T/remote.git"; return 0; }
mc_git_auth_clear() { :; }
job_verdict_rebind() { printf '%s %s\n' "$1" "$2" >> "$T/rebinds"; return 0; }

W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }

# fixture <name> — a remote with main and a PR branch whose one commit (line 10)
# is the reviewed head R; the hub clone under MC_REPOS; a fresh record dir.
fixture() {
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos/demo-os" 2>/dev/null
  scratch_rm "$T/rec" 2>/dev/null; rm -f "$T/rebinds"
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
  git clone -q "$T/remote.git" "$T/repos/demo-os"
  mkdir -p "$T/rec"; echo "$R" > "$T/rec/reviewed-sha"
}
main_edit() { w checkout -q main; edit "$1" "$2"; commit "main $1" >/dev/null; push main; w checkout -q pr; }
rebind() { rebind_patch_id "demo-os#7" demo-os example-org/demo-os 7 https://github.com/example-org/demo-os/pull/7 "$T/rec" "$R" "$1"; }

# ---- C1: a clean main merge next to the PR hunk
fixture
main_edit 13 'line 13 EDITED ON MAIN'
w merge -q --no-edit main; H=$(w rev-parse HEAD); push pr
rebind "$H"; rc=$?
[ "$rc" = 0 ] && ok || bad "C1 a main-merge-only head must rebind (rc 0, no re-review bought), got rc=$rc"
[ "$(cat "$T/rebinds" 2>/dev/null)" = "https://github.com/example-org/demo-os/pull/7 $H" ] && ok \
  || bad "C1 the ledger verdict must be rebound onto the new head: '$(cat "$T/rebinds" 2>/dev/null)'"
[ "$(cat "$T/rec/reviewed-sha")" = "$H" ] && ok || bad "C1 reviewed-sha must move to the new head"
grep -q "REBOUND ${R:0:8} -> ${H:0:8}: own commits unchanged (main-merge" "$MCLOG" && ok \
  || bad "C1 the log must name the same-patch rule: $(tail -2 "$MCLOG" 2>/dev/null)"

# ---- C2: a real change hidden behind a main merge
fixture
edit 20 'line 20 FIX ROUND'; commit fix >/dev/null
main_edit 13 'line 13 EDITED ON MAIN'
w merge -q --no-edit main; H=$(w rev-parse HEAD); push pr
rebind "$H"; rc=$?
[ "$rc" = 1 ] && ok || bad "C2 a changed head must NOT rebind (the re-review is bought), got rc=$rc"
[ ! -s "$T/rebinds" ] && ok || bad "C2 no ledger rebind on a changed head: $(cat "$T/rebinds")"
[ "$(cat "$T/rec/reviewed-sha")" = "$R" ] && ok || bad "C2 reviewed-sha must stay on the reviewed head"

# ---- C3: a pure rebase still rebinds on the patch-id path
fixture
w checkout -q main; printf 'x\n' > "$W/o.txt"; commit other >/dev/null; push main; w checkout -q pr
w rebase -q main; H=$(w rev-parse HEAD); push pr
rebind "$H"; rc=$?
[ "$rc" = 0 ] && grep -q "REBOUND ${R:0:8} -> ${H:0:8}: patch-id [0-9a-f]* unchanged" "$MCLOG" && ok \
  || bad "C3 a pure rebase must rebind on the patch-id path: rc=$rc $(tail -1 "$MCLOG" 2>/dev/null)"

# ---- C5: a head rebuilt on a moved main whose ONLY difference is whitespace in
# the PR's own line (the #2386 review). `git patch-id --stable` strips whitespace,
# so the conductor's own rebind used to call this the approved patch and merge
# code nobody reviewed. It must buy the re-review.
fixture
w checkout -q main; printf 'x\n' > "$W/o.txt"; commit other >/dev/null; push main
w checkout -q -B pr main; edit 10 'line 10  CHANGED BY  PR'; H=$(commit pr-change-ws); push pr
rebind "$H"; rc=$?
[ "$rc" = 1 ] && ok || bad "C5 a whitespace-changed head must NOT rebind (the re-review is bought), got rc=$rc: $(tail -1 "$MCLOG" 2>/dev/null)"
[ ! -s "$T/rebinds" ] && ok || bad "C5 no ledger rebind on a whitespace-changed head: $(cat "$T/rebinds")"

# ---- C4: without the lib the C1 shape is not rebound (today's behaviour, fail closed)
fixture
main_edit 13 'line 13 EDITED ON MAIN'
w merge -q --no-edit main; H=$(w rev-parse HEAD); push pr
# A copy of the conductor lib and its modules WITHOUT bin/lib/patch-same.sh beside them.
mkdir -p "$T/nolib/lib/mc"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/nolib/lib/"; cp "$DIR"/bin/lib/mc/*.sh "$T/nolib/lib/mc/"
( unset -f patch_same patch_same_fetch
  # shellcheck source=/dev/null
  . "$T/nolib/lib/merge-conductor-lib.sh"; mc_init
  mc_git_auth() { MC_REMOTE="$T/remote.git"; return 0; }
  mc_git_auth_clear() { :; }
  job_verdict_rebind() { printf '%s %s\n' "$1" "$2" >> "$T/rebinds"; return 0; }
  rebind "$H" ); rc=$?
[ "$rc" = 1 ] && ok || bad "C4 with no patch_same the main-merge head must fall through, got rc=$rc"

echo "rebind-same-patch.bh-2310: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
