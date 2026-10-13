#!/bin/bash
# tests/hold-push-ratchet.bh-2504-test.sh — no lane under bin/ pushes a PR branch
# except through bin/lib/hold-push.sh.
#
# WHY (BH-2504, 2026-09-25). Six held tickets took pushes from six different
# writers in one evening: the blocked-resolver's fix round, the conductor's main
# merges, a pool rebuild, a harness push. Each lane had its own `git push` line
# and none of them re-read the ticket before it ran. bin/lib/hold-push.sh is the
# one place that does, and this ratchet is what keeps it the one place: a raw
# `git push` (or a REST ref write) anywhere else under bin/ fails here unless
# tests/hold-push-ratchet-allowlist.txt names the file and says why its branch
# is not a PR branch.
#
# WHAT COUNTS. After full-line `#` comments are dropped, a line offends when it
# runs `git [-C x] [-c k=v]… push`, or names a `git/refs` REST endpoint. A push
# spelled through a variable (`$GIT push`), split so `git` and `push` sit on
# different lines, or inside a `bash -c` string is not seen: it is a ratchet
# that holds the line already held, not a proof.
#
# THE SCANNER IS WATCHED FAILING FIRST (section 1), on synthetic files, so a
# green run over the repo means something.
#   bash tests/hold-push-ratchet.bh-2504-test.sh     exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ALLOW="$DIR/tests/hold-push-ratchet-allowlist.txt"
HELPER="bin/lib/hold-push.sh"

# scan <root> — "<path from root>" once per file that offends, sorted.
# `grep -c`, never `grep -q`, at the end of a pipe: under pipefail an early-exit
# reader SIGPIPEs the writer and a match reads as a miss.
scan() {
  local root="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    [ "$rel" = "$HELPER" ] && continue
    if grep -vE '^[[:space:]]*#' "$f" \
       | grep -cE '(^|[^A-Za-z0-9_./-])git([[:space:]]+(-C|-c)[[:space:]]+("[^"]*"|[^[:space:]]+))*[[:space:]]+push([[:space:]]|$|")|git/refs' >/dev/null; then
      printf '%s\n' "$rel"
    fi
  done < <(find "$root/bin" -type f -name '*.sh' 2>/dev/null | sort)
}

# ── 1. the scanner, on files built to trip it ────────────────────────────────
S="$T/synthetic"
mkdir -p "$S/bin/lib"
printf '#!/bin/bash\ngit push origin "$BR"\n' > "$S/bin/raw.sh"
printf '#!/bin/bash\n(cd "$WT" && git push -qf origin "lander/$BR:$BR")\n' > "$S/bin/subshell.sh"
printf '#!/bin/bash\ngit -C "$wt" -c credential.helper= push -q \\\n  "$remote" "HEAD:$br"\n' > "$S/bin/lib/split.sh"
printf '#!/bin/bash\ngh api -X PATCH "repos/$slug/git/refs/heads/$br" -f sha=x\n' > "$S/bin/restref.sh"
printf '#!/bin/bash\n# a comment that says git push origin main\nhold_push "$p" - "$wt" origin HEAD "$br" "$sha"\n' > "$S/bin/clean.sh"
printf '#!/bin/bash\ngit -C "$wt" push -q origin HEAD\n' > "$S/$HELPER"
GOT=$(scan "$S" | tr '\n' ' ')
for want in bin/raw.sh bin/subshell.sh bin/lib/split.sh bin/restref.sh; do
  case " $GOT " in *" $want "*) ok ;; *) bad "the scanner must flag $want (got: $GOT)" ;; esac
done
case " $GOT " in *" bin/clean.sh "*) bad "a comment and a hold_push call are not raw pushes (got: $GOT)" ;; *) ok ;; esac
case " $GOT " in *" $HELPER "*) bad "the helper itself is the one place a push lives (got: $GOT)" ;; *) ok ;; esac

# ── 2. the repo ──────────────────────────────────────────────────────────────
[ -r "$ALLOW" ] && ok || bad "missing $ALLOW"
[ -r "$DIR/$HELPER" ] && ok || bad "missing $HELPER — the one place a PR-branch push lives"
ALLOWED=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null | cut -f1 | sort -u)
# every allowlist line carries a reason
while IFS= read -r line; do
  [ -n "$(printf '%s' "$line" | cut -s -f2)" ] && ok || bad "allowlist line has no reason: $line"
done < <(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null)
OFFENDERS=$(scan "$DIR")
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF "$f" <<<"$ALLOWED" && ok \
    || bad "$f runs a raw git push (or a REST ref write): push a PR branch through hold_push ($HELPER), or name the file in tests/hold-push-ratchet-allowlist.txt with the reason its branch is not a PR branch"
done <<<"$OFFENDERS"
# a stale line is a hole: the list only gets shorter
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF "$f" <<<"$OFFENDERS" && ok \
    || bad "$f is allowlisted but no longer pushes — delete its line from tests/hold-push-ratchet-allowlist.txt"
done <<<"$ALLOWED"
# the lanes BH-2504 names push through the helper, not around it
for f in bin/blocked-resolver.sh bin/lib/mc/rebase.sh bin/lib/mc/train.sh bin/lib/rebase-job.sh \
         bin/rebase-train.sh bin/lander.sh bin/merge-queue.sh bin/review-rescue.sh \
         bin/lane-checkpoint.sh bin/lib/rb/gates.sh bin/quiesce-for-resize.sh bin/verification-map-retrofit.sh; do
  grep -vE '^[[:space:]]*#' "$DIR/$f" | grep -c 'hold_push' >/dev/null && ok || bad "$f must push through hold_push"
done

echo "hold-push-ratchet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
