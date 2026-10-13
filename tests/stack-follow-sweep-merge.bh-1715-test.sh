#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stack-follow-sweep-merge.bh-1715-test.sh — BH-1715 item 2: a parent
# merged OUTSIDE the conductor (merge-sweep, poll-commands) still gets its
# stacked children restacked.
#
# THE DEFECT. Those lanes merge through `gh_pr_merge_rest … 1`, whose
# `_gpm_delete_branch` (BH-1483) PATCHes every open child to the parent's base
# and then deletes the parent branch. It recorded nothing. By the time the
# conductor looked, the child was already on main, so `conductor_settle`'s
# follow (BH-1670) never fired and the child kept the parent's pre-squash
# commits with no CI push.
#
# THE FIX UNDER TEST. The PATCH-200 arm writes the same owed-restack record the
# settle writes ($HARNESS/state/stack-follow/<owner_repo>#<child>), and the
# conductor's pr_worker drain follows it: `rebase --onto <base> <parent head>`
# and one push when the branch still carries the parent's commits, nothing when
# it does not.
#
#   A  the record `_gpm_owe_restack` writes is the one `mc_stack_pending_get`
#      reads, field for field (the two writers cannot drift)
#   B  the production entry `gh_pr_merge_rest … 1` writes it on a 200 PATCH, and
#      writes nothing (and deletes nothing) on a refused PATCH
#   C  the drain restacks the recorded child: no base PATCH, one push, the new
#      head sits on main's tip with only the child's own commit
#   D  a child already rebased by hand: rc 0, no push, the record is cleared
#   E  a closed child: the record is cleared, no push
#
# Git runs for real against a bare origin that never leaves this box; gh is a
# stub that records every argv and writes PATCH / DELETE / PUSH to events.txt.
#
# D1 MUTATIONS, run once before the PR and confirmed red: drop the
# `_gpm_owe_restack` call from `_gpm_delete_branch` (B, C, D red), write the
# record on a refused PATCH as well (B's refused case red).
#
# Run from anywhere: tests/stack-follow-sweep-merge.bh-1715-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/gh-pr-merge.sh" ] || exit 1   # impact: bin/lib/gh-pr-merge.sh
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1     # impact: bin/lib/mc/rebase.sh
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV
REALGIT=$(command -v git)
SLUG=example-org/demo-os

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/repos"

cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/events.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"

# gh. The lib reads with `api -i repos/…` and the conductor with
# `api -i -X GET repos/…`, so the two readers of #1 and #2 are told apart. The
# children list and the PATCH arms come first: a looser pulls arm above them
# would answer both with a pull object.
# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pulls?state=open&base=ticket%2Fbh-1&per_page=100"*) restpr --raw 200 '[{"number":2}]' ;;
  # TEST-CHANGE (BH-5234): mc_restack reads the restacked child's own open
  # children before it pushes; ticket/bh-2 has none.
  *"pulls?state=open&base=ticket%2Fbh-2&per_page=100"*) restpr --raw 200 '[]' ;;
  *"-X PATCH repos/$SLUG/pulls/2"*)
    printf 'PATCH %s\n' "\$*" >> "$T/events.txt"
    code=\$(cat "$T/patch-code" 2>/dev/null); code=\${code:-200}
    a="\$*"; [ "\$code" = 200 ] && printf '%s' "\${a##*base=}" > "$T/child-base"
    case " \$* " in *" -i "*) restpr --raw "\$code" '{"number":2}' ;; esac
    [ "\$code" = 200 ] ;;
  *"-X PUT repos/$SLUG/pulls/1/merge"*) restpr --raw 200 '{"sha":"cafe0001cafe0001cafe0001cafe0001cafe0001","merged":true}' ;;
  *"-X DELETE repos/$SLUG/git/refs/heads/"*) printf 'DELETE %s\n' "\$*" >> "$T/events.txt"; restpr --raw 204 '' ;;
  *"api -i repos/$SLUG/pulls/1"*)
    restpr --raw 200 "\$(jq -nc --arg sha "\$(cat "$T/parent-head")" \
      '{number:1,merged:true,head:{sha:\$sha,ref:"ticket/bh-1",repo:{full_name:"$SLUG"}},base:{ref:"main"}}')" ;;
  *"api -i repos/$SLUG"*)
    restpr --raw 200 '{"full_name":"$SLUG","allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":false}' ;;
  *"api -i -X GET repos/$SLUG/pulls/2"*)
    case "\$(cat "$T/child-state")" in CLOSED) st=closed ;; *) st=open ;; esac
    restpr --raw 200 "\$(jq -nc --arg st "\$st" --arg sha "\$(cat "$T/child-head")" \
      --arg base "\$(cat "$T/child-base")" \
      '{number:2,state:\$st,merged_at:null,head:{sha:\$sha,ref:"ticket/bh-2",repo:{full_name:"$SLUG"}},base:{ref:\$base},labels:[],html_url:"https://github.com/$SLUG/pull/2"}')" ;;
  *) echo "" ;;
esac
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"

# fixture [byhand] — main; the parent ticket/bh-1 (two commits); the child
# ticket/bh-2 (one commit on the parent); the parent SQUASH-merged into main.
# The child PR's base is still ticket/bh-1: the sweep's merge moves it.
#   byhand  somebody already rebased the child onto main and pushed it
fixture() {
  local S="$T/seed"
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor" "$T/h/state/stack-follow"
  : > "$T/events.txt"; : > "$T/gh-argv.txt"; : > "$T/h/logs/merge-conductor.log"; : > "$T/plog"
  rm -f "$T/patch-code" "$T/h/state/merge-conductor/pr-state.tsv"
  echo OPEN > "$T/child-state"; echo ticket/bh-1 > "$T/child-base"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  printf 'base\n' > "$S/a.txt"; printf 'c0\n' > "$S/child.txt"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb ticket/bh-1
  printf 'p1\n' > "$S/p1.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p1
  printf 'p2\n' > "$S/p2.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p2
  PHEAD=$("$REALGIT" -C "$S" rev-parse HEAD); printf '%s' "$PHEAD" > "$T/parent-head"
  "$REALGIT" -C "$S" checkout -qb ticket/bh-2
  printf 'child\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam child
  CHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main
  "$REALGIT" -C "$S" merge -q --squash ticket/bh-1 >/dev/null && "$REALGIT" -C "$S" commit -qm 'parent (#1)'
  if [ "${1:-}" = byhand ]; then
    "$REALGIT" -C "$S" rebase -q --onto main "$PHEAD" ticket/bh-2 >/dev/null 2>&1
    CHEAD=$("$REALGIT" -C "$S" rev-parse ticket/bh-2); "$REALGIT" -C "$S" checkout -q main
  fi
  "$REALGIT" -C "$S" push -q origin main ticket/bh-2 2>/dev/null
  printf '%s' "$CHEAD" > "$T/child-head"
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
PEND="$T/h/state/stack-follow/example-org_demo-os#2"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export PATH="$T/fakebin:$PATH"
command -v gh_pr_merge_rest >/dev/null || { echo "FAIL: gh_pr_merge_rest did not load"; exit 1; }

# The sweep's own call, verbatim in shape: bin/merge-sweep.sh passes delete=1.
sweep_merge() { gh_pr_merge_rest "$SLUG" 1 "$PHEAD" "$T/gh-stderr.log" "$T/plog" "merge-sweep #1" 1 >/dev/null 2>&1; }
# pr_worker's drain, as bin/merge-conductor.sh runs it for the child's row.
drain() {
  local SFPEND SFPN SFPURL SFPBR SFPHEAD SFBASE
  SFPEND=$(mc_stack_pending_get "$SLUG" 2) || { DRC=none; DOUT=""; return 0; }
  IFS=$'\t' read -r SFPN SFPURL SFPBR SFPHEAD SFBASE _ _ <<<"$SFPEND"
  DOUT=$(mc_stack_follow demo-os "$SLUG" 2 "$SFPN" "$SFPURL" "$SFPBR" "$SFPHEAD" "$SFBASE" 2>/dev/null); DRC=$?
}

# ============================================================================
# A. The format contract: what the merge lib writes, the conductor reads.
# ============================================================================
fixture
S40=0123456789abcdef0123456789abcdef01234567
if command -v _gpm_owe_restack >/dev/null; then
  _gpm_owe_restack o/r 11 10 https://github.com/o/r/pull/10 ticket/a "$S40" main 2>/dev/null
else bad "A: _gpm_owe_restack is not defined by bin/lib/gh-pr-merge.sh"; fi
LINE=$(mc_stack_pending_get o/r 11) || LINE=""
IFS=$'\t' read -r F1 F2 F3 F4 F5 F6 F7 <<<"$LINE"
[ "$F1|$F2|$F3|$F4|$F5" = "10|https://github.com/o/r/pull/10|ticket/a|$S40|main" ] \
  && ok || bad "A: mc_stack_pending_get must read back the five fields written (got: $LINE)"
[ "${F6:-}" = 0 ] && ok || bad "A: a fresh record starts at attempts 0 (got '${F6:-}')"
case "${F7:-}" in ''|*[!0-9]*) bad "A: since must be an epoch (got '${F7:-}')" ;; *) ok ;; esac
[ -z "$(find "$T/h/state/stack-follow" -name '*.tmp.*' 2>/dev/null)" ] && ok || bad "A: no temp file may be left behind"

# ============================================================================
# B. Through the production entry: the 200 PATCH leaves the record; a refused
#    PATCH leaves none, and the parent branch is kept.
# ============================================================================
fixture; sweep_merge
grep -q '^PATCH .*pulls/2 -f base=main' "$T/events.txt" && ok || bad "B: the child must be retargeted to main (events: $(cat "$T/events.txt"))"
grep -q '^DELETE ' "$T/events.txt" && ok || bad "B: the parent branch must still be deleted after the retarget (events: $(cat "$T/events.txt"))"
[ -s "$PEND" ] && ok || bad "B: the retargeted child must be owed a restack ($PEND missing; plog: $(cat "$T/plog"))"
IFS=$'\t' read -r F1 F2 F3 F4 F5 F6 _ 2>/dev/null < "$PEND" || true
[ "${F1:-}|${F2:-}|${F3:-}|${F4:-}|${F5:-}|${F6:-}" = "1|https://github.com/$SLUG/pull/1|ticket/bh-1|$PHEAD|main|0" ] \
  && ok || bad "B: the record must carry the parent #, url, branch, PRE-MERGE head and base (got: $(cat "$PEND" 2>/dev/null))"
fixture; echo 422 > "$T/patch-code"; sweep_merge
[ -e "$PEND" ] && bad "B: a refused PATCH must record nothing" || ok
grep -q '^DELETE ' "$T/events.txt" && bad "B: a refused PATCH must keep the parent branch" || ok

# ============================================================================
# C. The drain restacks the recorded child: no second PATCH, one push.
# ============================================================================
fixture; sweep_merge
: > "$T/events.txt"; ACTIONS=1; drain
[ "$DRC" = 0 ] && ok || bad "C: the follow must rc 0 (got $DRC; log: $(tail -3 "$T/h/logs/merge-conductor.log"))"
grep -q '^PATCH' "$T/events.txt" && bad "C: the child is already on main — no base PATCH (events: $(cat "$T/events.txt"))" || ok
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] && ok || bad "C: exactly one push (events: $(cat "$T/events.txt"))"
[ "$(origin_rev ticket/bh-2^)" = "$(origin_rev main)" ] \
  && ok || bad "C: the child's new parent must be main's tip"
[ "$("$REALGIT" -C "$T/origin.git" rev-list --count main..ticket/bh-2)" = 1 ] \
  && ok || bad "C: main..child must be the child's own commit only"
[ -n "$DOUT" ] && [ "$DOUT" = "$(origin_rev ticket/bh-2)" ] && ok || bad "C: stdout must be the pushed head (got '$DOUT')"
[ -e "$PEND" ] && bad "C: the record must be cleared after the push" || ok

# ============================================================================
# D. Already rebased by hand: the parent head is not in its history.
# ============================================================================
fixture byhand; sweep_merge
[ -s "$PEND" ] && ok || bad "D: the retarget still records the follow"
: > "$T/events.txt"; ACTIONS=1; drain
[ "$DRC" = 0 ] && [ -z "$DOUT" ] && ok || bad "D: rc 0 with empty stdout (got rc $DRC, '$DOUT')"
grep -q '^PUSH' "$T/events.txt" && bad "D: nothing to restack — no push" || ok
[ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "D: origin's child head must be untouched"
[ -e "$PEND" ] && bad "D: the record must be cleared" || ok

# ============================================================================
# E. The child closed before the drain.
# ============================================================================
fixture; sweep_merge
echo CLOSED > "$T/child-state"; : > "$T/events.txt"; ACTIONS=1; drain
grep -q '^PUSH\|^PATCH' "$T/events.txt" && bad "E: a closed child must not be touched" || ok
[ -e "$PEND" ] && bad "E: a closed child's record must be cleared" || ok

echo "stack-follow-sweep-merge.bh-1715-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
