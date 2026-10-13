#!/bin/bash
# tests/verification-map-retrofit-test.sh — BH-868. A PR whose ONLY conflict is the
# GENERATED docs/verification-map/README.md is resolved by moving the rows the PR
# appended into docs/verification-map/entries/<TICKET>.md and regenerating the
# README from main's sources — never by gluing the two tables together.
#
# WHY THIS EXISTS (the defect). Before this ticket the only resolver in
# mc_resolve_conflicts that matched the README was the `*.md` union arm
# (bin/lib/merge-conductor-lib.sh), and union is the wrong operation for a
# generated file: it leaves a duplicated header and a hand row with no entry
# file behind it, so the mechanical rung "succeeds", pushes, and CI's
# `bin/verification-map-build.sh --check-committed` step goes red. The park then spends a
# whole fix round on a mechanical problem. ~27 open PRs sit on that shape.
#
# WHY REAL GIT. The question is what git's index holds during the three-way
# merge and what bytes are left in the tree afterwards, so every case builds a
# real repository, makes a real conflicting merge, runs the REAL
# bin/verification-map-build.sh and asserts on real bytes. `gh` is a stub on
# PATH; the push cases push to a `git init --bare` remote inside $T. Nothing
# here touches a real box, a real remote or /root/harness.
# Run from anywhere: tests/verification-map-retrofit-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/config" "$T/fakebin"
cp "$DIR/config/generated-paths.conf" "$T/h/config/"
cp "$DIR/bin/verification-map-retrofit.sh" "$T/h/bin/" 2>/dev/null
cp "$DIR/bin/verification-map-build.sh" "$T/h/bin/" 2>/dev/null

RETRO="$DIR/bin/verification-map-retrofit.sh"
[ -x "$RETRO" ] || { echo "FAIL: bin/verification-map-retrofit.sh is missing or not executable"; echo "verification-map-retrofit: 0 passed, 1 failed"; exit 1; }
# shellcheck source=/dev/null
. "$RETRO" || { echo "FAIL: bin/verification-map-retrofit.sh could not be sourced"; exit 1; }
command -v vmr_resolve_readme >/dev/null || { echo "FAIL: vmr_resolve_readme not defined after sourcing"; exit 1; }

# The stub gh. The CLI reads PRs over REST through bin/lib/gh-rest.sh (BH-868
# fix round — a 90-call `--all-open` sweep on the GraphQL-backed `gh pr view`
# is exactly the burst that rate-limits the account), so the stub answers
# `gh api -i -X <verb> repos/<slug>/...` with a status line, a blank line and a
# JSON body — the shape gh_rest parses. PR 1 = ticket/bh-560, PR 2 =
# ticket/bh-561, PR 3 = the same branch as a FORK.
# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
hold_fixture_libs "$DIR" "$T/h" || exit 1
cat > "$T/fakebin/gh" <<'GHEOF'
#!/bin/bash
[ -n "${HOLD_FX_ANSWER:-}" ] && . "$HOLD_FX_ANSWER" && hold_answer "$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "$*" >> "$GHLOG"
emit() { printf 'HTTP/2.0 %s \r\n\r\n%s\n' "${2:-200}" "$1"; exit 0; }
pr_json() { # pr_json <branch> <sha> <fork>
  printf '{"number":1,"head":{"ref":"%s","sha":"%s","repo":{"fork":%s,"full_name":"o/r"}}}' "$1" "$2" "$3"
}
[ "${1:-}" = api ] || exit 0
path=""
for a in "$@"; do case "$a" in repos/*) path="$a"; break ;; esac; done
case "$path" in
  */pulls/1)  emit "$(pr_json ticket/bh-560 "$(cat "$T_HEAD1")" false)" ;;
  */pulls/2)  emit "$(pr_json ticket/bh-561 "$(cat "$T_HEAD2")" false)" ;;
  */pulls/3)  emit "$(pr_json ticket/bh-560 "$(cat "$T_HEAD1")" true)" ;;
  */pulls)    emit '[{"number":1,"head":{"ref":"ticket/bh-560"}},{"number":2,"head":{"ref":"ticket/bh-561"}}]' ;;
  */issues/*/comments)
      # gh_rest_comment sends the body by FILE so it never reaches argv; the
      # log keeps the bytes so the cases can still assert what was posted.
      for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "$GHLOG"; echo >> "$GHLOG" ;; esac; done
      emit '{"id":1}' 201 ;;
  *) emit '{"message":"Not Found"}' 404 ;;
esac
GHEOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GHLOG="$T/gh.log"; : > "$GHLOG"
export T_HEAD1="$T/head1.txt" T_HEAD2="$T/head2.txt"
: > "$T_HEAD1"; : > "$T_HEAD2"

g() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

HAND_README='# Verification map — fixture

| feature | entry | primary lane |
|---|---|---|
| Alpha | [alpha.md](alpha.md) | `bin/alpha.sh` |
| Beta | [beta.md](beta.md) | `bin/beta.sh` |
'
ROW_G='| Gamma | [gamma.md](gamma.md) | `bin/gamma.sh` |'

# build_fixture <dir> [--no-build-script] [--union-attr] [--no-hand-row]
#   commit A  = the pre-#799 layout: a hand-edited README, no entries/.
#   main      = the generated layout, README written by the REAL build script.
#   ticket/bh-560 = A + one appended row + a trailing blank line (#725's shape).
#   --union-attr  commit A also carries `.gitattributes` with
#                 `docs/verification-map/README.md merge=union` — main's shape
#                 since BH-865, which makes the merge CLEAN and glues the two
#                 tables instead of conflicting (BH-868 fix round, finding 1).
#   --no-hand-row ticket/bh-560 is cut from main and adds no README row at all:
#                 the genuine "nothing to retrofit" PR.
build_fixture() {
  local R="$1"; shift
  local nobuild="" union="" nohand="" a
  for a in "$@"; do
    case "$a" in
      --no-build-script) nobuild=--no-build-script ;;
      --union-attr)      union=1 ;;
      --no-hand-row)     nohand=1 ;;
    esac
  done
  mkdir -p "$R/docs/verification-map" "$R/bin"
  g "$R" init -q -b main .  >/dev/null 2>&1 || git init -q -b main "$R"
  printf '%s' "$HAND_README" > "$R/docs/verification-map/README.md"
  echo 'echo hello' > "$R/bin/x.sh"
  [ -n "$union" ] && printf '%s\n' 'docs/verification-map/README.md merge=union' > "$R/.gitattributes"
  g "$R" add -A; g "$R" commit -qm A
  g "$R" branch base-a
  g "$R" checkout -q -b ticket/bh-560 base-a
  printf '%s\n\n' "$ROW_G" >> "$R/docs/verification-map/README.md"
  g "$R" add -A; g "$R" commit -qm 'BH-560 hand row'
  g "$R" checkout -q main
  mkdir -p "$R/docs/verification-map/index" "$R/docs/verification-map/entries"
  printf '# Verification map — fixture\n\nIntro line.\n' > "$R/docs/verification-map/index/head.md"
  printf '## Driving conventions\n\n- Drive the real script.\n' > "$R/docs/verification-map/index/tail.md"
  printf '%s\n' '| Alpha | [alpha.md](alpha.md) | `bin/alpha.sh` |' > "$R/docs/verification-map/entries/BH-1.md"
  printf '%s\n' '| Beta | [beta.md](beta.md) | `bin/beta.sh` |'  > "$R/docs/verification-map/entries/BH-2.md"
  # The documents those rows LINK to. `--check` resolves every entry link since
  # BH-1175, so a fixture whose rows point at nothing would be refused for its
  # own shape rather than for the retrofit behaviour under test — and the
  # retrofit gates its repair on `--check`. ROW_G's document comes too: the
  # hand-added row becomes an entry file, and then it is a link like any other.
  for d in alpha beta gamma; do printf '# %s\n' "$d" > "$R/docs/verification-map/$d.md"; done
  if [ "$nobuild" != "--no-build-script" ]; then
    cp "$DIR/bin/verification-map-build.sh" "$R/bin/"
    chmod +x "$R/bin/verification-map-build.sh"
    "$R/bin/verification-map-build.sh" --repo "$R" >/dev/null || return 1
  else
    # main still rewrites the README, so the merge conflicts the same way; it
    # simply has no build script to rebuild it with.
    printf '# Verification map — fixture\n\nIntro line.\n\n| feature | entry | primary lane |\n|---|---|---|\n| Alpha | [alpha.md](alpha.md) | `bin/alpha.sh` |\n| Beta | [beta.md](beta.md) | `bin/beta.sh` |\n\n## Driving conventions\n\n- Drive the real script.\n' > "$R/docs/verification-map/README.md"
  fi
  g "$R" add -A; g "$R" commit -qm 'main: generated layout'
  if [ -n "$nohand" ]; then
    # A PR that never touched the README: main's own layout plus a code commit.
    g "$R" branch -f ticket/bh-560 main
    g "$R" checkout -q ticket/bh-560
    echo 'echo y' > "$R/bin/y.sh"; g "$R" add -A; g "$R" commit -qm 'BH-560 code only'
    g "$R" checkout -q main
  fi
}

# start_merge <dir> — checkout the branch, merge main, leave the conflict in the index.
start_merge() {
  local R="$1"
  g "$R" checkout -q ticket/bh-560
  g "$R" merge -q --no-edit main >/dev/null 2>&1 && return 1
  return 0
}
conf_of() { git -C "$1" diff --name-only --diff-filter=U; }

R="$T/r"
build_fixture "$R" || { echo "FAIL: fixture build"; exit 1; }
BASE=$(git -C "$R" merge-base ticket/bh-560 main)

# ---------------------------------------------------------------------------
# 1. HAPPY PATH — vmr_resolve_readme inside a real conflicted merge
# ---------------------------------------------------------------------------
start_merge "$R" || bad "1 fixture should conflict on the README"
[ "$(conf_of "$R")" = docs/verification-map/README.md ] && ok \
  || bad "1 the only conflict should be the README, got: $(conf_of "$R" | tr '\n' ' ')"
OURS=$(git -C "$R" rev-parse HEAD)
OUT=$(vmr_resolve_readme "$R" "$BASE" "$OURS" BH-560); RC=$?
[ "$RC" = 0 ] && ok || bad "1 vmr_resolve_readme should succeed (rc=$RC): $OUT"
[ -f "$R/docs/verification-map/entries/BH-560.md" ] && ok || bad "1 entries/BH-560.md should be written"
[ "$(cat "$R/docs/verification-map/entries/BH-560.md" 2>/dev/null)" = "$ROW_G" ] && ok \
  || bad "1 the entry file should hold exactly the added row, got: $(cat "$R/docs/verification-map/entries/BH-560.md" 2>/dev/null)"
grep -q '<<<<<<<' "$R/docs/verification-map/README.md" && bad "1 no conflict markers may survive" || ok
"$R/bin/verification-map-build.sh" --check-committed --repo "$R" >/dev/null 2>&1 && ok \
  || bad "1 --check must be in sync after the retrofit"
grep -qF "$ROW_G" "$R/docs/verification-map/README.md" && ok || bad "1 the regenerated README must carry the Gamma row"
[ "$(grep -c '^| ' "$R/docs/verification-map/README.md")" = 4 ] && ok \
  || bad "1 the README must hold one header + 3 rows, got $(grep -c '^| ' "$R/docs/verification-map/README.md")"
grep -q 'rows_before=2' <<<"$OUT" && grep -q 'rows_after=3' <<<"$OUT" && ok \
  || bad "1 stdout must carry the before/after row counts, got: $OUT"
STAGED=$(git -C "$R" diff --cached --name-only)
grep -qx 'docs/verification-map/entries/BH-560.md' <<<"$STAGED" \
  && grep -qx 'docs/verification-map/README.md' <<<"$STAGED" && ok \
  || bad "1 both paths must be staged, got: $(tr '\n' ' ' <<<"$STAGED")"
# Idempotent: the same call on the same tree is a no-op success.
vmr_resolve_readme "$R" "$BASE" "$OURS" BH-560 >/dev/null 2>&1 && ok || bad "1 a second identical run must be a no-op success"
g "$R" merge --abort >/dev/null 2>&1
g "$R" checkout -q -- . 2>/dev/null
rm -f "$R/docs/verification-map/entries/BH-560.md"

# ---------------------------------------------------------------------------
# 2-6. REFUSALS — anything but appended rows is rc 3 and writes no entry file
# ---------------------------------------------------------------------------
# refuse_case <name> <mutator applied to the branch tip>
refuse_case() {
  local name="$1"; shift
  local RR="$T/refuse-$name"
  build_fixture "$RR" || { bad "$name fixture"; return; }
  g "$RR" checkout -q ticket/bh-560
  "$@" "$RR"
  g "$RR" add -A; g "$RR" commit -qm "$name"
  local b o out rc
  b=$(git -C "$RR" merge-base ticket/bh-560 main)
  g "$RR" merge -q --no-edit main >/dev/null 2>&1
  o=$(git -C "$RR" rev-parse HEAD)
  out=$(vmr_resolve_readme "$RR" "$b" "$o" BH-560 2>&1); rc=$?
  [ "$rc" = 3 ] && ok || bad "$name should refuse with rc 3, got rc=$rc: $out"
  [ -f "$RR/docs/verification-map/entries/BH-560.md" ] && bad "$name must write no entry file" || ok
  g "$RR" merge --abort >/dev/null 2>&1
}
mut_edit()   { sed -i 's/`bin\/alpha.sh`/`bin\/alpha-renamed.sh`/' "$1/docs/verification-map/README.md"; }
mut_remove() { sed -i '/Beta/d' "$1/docs/verification-map/README.md"; }
mut_header() { printf '| feature | entry | primary lane |\n|---|---|---|\n' >> "$1/docs/verification-map/README.md"; }
mut_prose()  { printf 'A sentence somebody added under the table.\n' >> "$1/docs/verification-map/README.md"; }
mut_dupe()   { printf '%s\n' '| Alpha again | [alpha.md](alpha.md) | `bin/alpha.sh` |' >> "$1/docs/verification-map/README.md"; }
refuse_case edited-row  mut_edit
refuse_case removed-row mut_remove
refuse_case added-header mut_header
refuse_case added-prose  mut_prose
refuse_case dupe-target  mut_dupe

# An entry file already on the head with DIFFERENT rows is a refusal too.
RE="$T/refuse-entry-clash"
build_fixture "$RE" >/dev/null
g "$RE" checkout -q ticket/bh-560
mkdir -p "$RE/docs/verification-map/entries"
printf '%s\n' '| Something else | [other.md](other.md) | `bin/other.sh` |' > "$RE/docs/verification-map/entries/BH-560.md"
g "$RE" add -A; g "$RE" commit -qm 'pre-existing entry'
BE=$(git -C "$RE" merge-base ticket/bh-560 main)
g "$RE" merge -q --no-edit main >/dev/null 2>&1
vmr_resolve_readme "$RE" "$BE" "$(git -C "$RE" rev-parse HEAD)" BH-560 >/dev/null 2>&1
[ "$?" = 3 ] && ok || bad "an entry file with different content must refuse rc 3"
g "$RE" merge --abort >/dev/null 2>&1

# No ticket key = not ours.
vmr_ticket_of_branch ticket/bh-560 >/dev/null && [ "$(vmr_ticket_of_branch ticket/bh-560)" = BH-560 ] && ok \
  || bad "vmr_ticket_of_branch ticket/bh-560 -> BH-560"
[ "$(vmr_ticket_of_branch ticket/bh-560-r2)" = BH-560 ] && ok || bad "an -rN branch -> the base key"
vmr_ticket_of_branch design/whatever >/dev/null 2>&1 && bad "a keyless branch must yield no key" || ok

# A repo with no build script is "not mine" (rc 1), never a refusal.
RN="$T/nobuild"
build_fixture "$RN" --no-build-script >/dev/null
BN=$(git -C "$RN" merge-base ticket/bh-560 main)
g "$RN" checkout -q ticket/bh-560
g "$RN" merge -q --no-edit main >/dev/null 2>&1
vmr_resolve_readme "$RN" "$BN" "$(git -C "$RN" rev-parse HEAD)" BH-560 >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "a repo without bin/verification-map-build.sh must answer rc 1 (fall through)"
g "$RN" merge --abort >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 7-9, 12. THE CLI, against a real bare remote and the stub gh
# ---------------------------------------------------------------------------
# cli_fixture <dir> [--code-conflict|--union-attr|--no-hand-row] — a clone-shaped
# repo with an origin bare remote.
cli_fixture() {
  local R="$1" mode="${2:-}"
  case "$mode" in
    ""|--code-conflict) build_fixture "$R" || return 1 ;;
    *)                  build_fixture "$R" "$mode" || return 1 ;;
  esac
  if [ "$mode" = --code-conflict ]; then
    g "$R" checkout -q ticket/bh-560
    echo 'echo branch-side' > "$R/bin/x.sh"; g "$R" add -A; g "$R" commit -qm 'branch x.sh'
    g "$R" checkout -q main
    echo 'echo main-side' > "$R/bin/x.sh"; g "$R" add -A; g "$R" commit -qm 'main x.sh'
  fi
  git init -q --bare "$R.origin.git"
  # origin's URL is a REAL slug (the CLI reads owner/repo off it for every REST
  # call, and bin/lib/gh-rest.sh refuses anything that is not owner/repo);
  # insteadOf points every actual fetch/push at the bare repo inside $T.
  g "$R" remote add origin "https://github.com/o/r.git"
  g "$R" config "url.$R.origin.git.insteadOf" "https://github.com/o/r.git"
  g "$R" push -q origin main ticket/bh-560
  g "$R" checkout -q main
}

# 7. dry run: prints what it would write, pushes nothing, comments nothing.
RD="$T/cli-dry"; cli_fixture "$RD" || bad "7 fixture"
git -C "$RD" rev-parse ticket/bh-560 > "$T_HEAD1"
REMOTE_BEFORE=$(git -C "$RD.origin.git" rev-parse refs/heads/ticket/bh-560)
: > "$GHLOG"
OUT=$("$RETRO" --dry-run "$RD" 1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "7 dry-run should exit 0 (rc=$RC): $OUT"
grep -q 'WOULD write docs/verification-map/entries/BH-560.md' <<<"$OUT" && ok \
  || bad "7 dry-run must name the entry file it would write, got: $OUT"
grep -qF "$ROW_G" <<<"$OUT" && ok || bad "7 dry-run must print the row, got: $OUT"
[ "$(git -C "$RD.origin.git" rev-parse refs/heads/ticket/bh-560)" = "$REMOTE_BEFORE" ] && ok \
  || bad "7 dry-run must not move the remote branch"
grep -q 'issues/[0-9]*/comments' "$GHLOG" && bad "7 dry-run must post no comment" || ok

# 8. a code conflict is out of scope: rc 2, nothing touched.
RC2="$T/cli-code"; cli_fixture "$RC2" --code-conflict || bad "8 fixture"
git -C "$RC2" rev-parse ticket/bh-560 > "$T_HEAD1"
REMOTE_BEFORE=$(git -C "$RC2.origin.git" rev-parse refs/heads/ticket/bh-560)
: > "$GHLOG"
OUT=$("$RETRO" "$RC2" 1 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "8 a code conflict must exit 2 (rc=$RC): $OUT"
grep -q 'bin/x.sh' <<<"$OUT" && ok || bad "8 stdout must list the code path, got: $OUT"
[ "$(git -C "$RC2.origin.git" rev-parse refs/heads/ticket/bh-560)" = "$REMOTE_BEFORE" ] && ok \
  || bad "8 a code conflict must leave the remote branch alone"
grep -q 'issues/[0-9]*/comments' "$GHLOG" && bad "8 a code conflict must post no comment" || ok
[ -f "$RC2/bin/x.sh" ] && [ "$(git -C "$RC2" show ticket/bh-560:bin/x.sh)" = 'echo branch-side' ] && ok \
  || bad "8 the branch's own bin/x.sh must be untouched"

# 9. the real run: the remote branch advances, and the pushed head is in sync.
RR9="$T/cli-real"; cli_fixture "$RR9" || bad "9 fixture"
HEAD9=$(git -C "$RR9" rev-parse ticket/bh-560); printf '%s' "$HEAD9" > "$T_HEAD1"
: > "$GHLOG"
OUT=$("$RETRO" "$RR9" 1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "9 the real run should exit 0 (rc=$RC): $OUT"
NEW9=$(git -C "$RR9.origin.git" rev-parse refs/heads/ticket/bh-560)
[ "$NEW9" != "$HEAD9" ] && ok || bad "9 the remote branch must advance"
[ "$(git -C "$RR9" merge-base --is-ancestor "$HEAD9" "$NEW9" && echo yes)" = yes ] && ok \
  || bad "9 the pushed head must build ON the read head, never rewrite it"
V="$T/verify9"; git clone -q "$RR9.origin.git" -b ticket/bh-560 "$V" 2>/dev/null
[ -f "$V/docs/verification-map/entries/BH-560.md" ] && ok || bad "9 the pushed head must carry the entry file"
"$V/bin/verification-map-build.sh" --check-committed --repo "$V" >/dev/null 2>&1 && ok \
  || bad "9 --check must be in sync on the pushed head"
[ "$(grep -c 'issues/[0-9]*/comments' "$GHLOG")" = 1 ] && ok || bad "9 exactly one comment must be posted, got: $(grep -c 'issues/[0-9]*/comments' "$GHLOG")"
grep -q 'Rows before 2, after 3' "$GHLOG" && ok || bad "9 the comment must carry the before/after counts: $(grep 'comments' "$GHLOG")"

# 9b. a head that moved under us spends nothing: rc 4, no push, no comment.
RM="$T/cli-moved"; cli_fixture "$RM" || bad "9b fixture"
printf '%s' "$(git -C "$RM" rev-parse main)" > "$T_HEAD1"   # gh reports a sha that is not the branch tip
REMOTE_BEFORE=$(git -C "$RM.origin.git" rev-parse refs/heads/ticket/bh-560)
: > "$GHLOG"
OUT=$("$RETRO" "$RM" 1 2>&1); RC=$?
# The fixture makes this deterministically 4 (gh reports main's sha, the branch
# tip is something else). It used to also accept 0, which let a regression that
# dropped the lease check pass — BH-868 fix round, finding 5.
[ "$RC" = 4 ] && ok || bad "9b a moved head must answer rc 4, got rc=$RC"
[ "$(git -C "$RM.origin.git" rev-parse refs/heads/ticket/bh-560)" = "$REMOTE_BEFORE" ] && ok \
  || bad "9b a moved head must not be pushed over"
grep -q 'issues/[0-9]*/comments' "$GHLOG" && bad "9b a moved head must post no comment" || ok

# 9c. a fork PR is hands-off.
git -C "$RD" rev-parse ticket/bh-560 > "$T_HEAD1"
: > "$GHLOG"
OUT=$("$RETRO" "$RD" 3 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "9c a fork PR must refuse (rc=$RC)"
grep -q 'issues/[0-9]*/comments' "$GHLOG" && bad "9c a fork PR must post no comment" || ok

# 12. --all-open: one retrofit, one code conflict, one summary line each.
RA="$T/cli-all"; cli_fixture "$RA" || bad "12 fixture"
g "$RA" checkout -q -b ticket/bh-561 ticket/bh-560
echo 'echo branch-561' > "$RA/bin/x.sh"; g "$RA" add -A; g "$RA" commit -qm '561 x.sh'
g "$RA" checkout -q main
echo 'echo main-561' > "$RA/bin/x.sh"; g "$RA" add -A; g "$RA" commit -qm 'main x.sh for 561'
g "$RA" push -q origin main ticket/bh-561
printf '%s' "$(git -C "$RA" rev-parse ticket/bh-560)" > "$T_HEAD1"
printf '%s' "$(git -C "$RA" rev-parse ticket/bh-561)" > "$T_HEAD2"
: > "$GHLOG"
OUT=$("$RETRO" --all-open "$RA" 2>&1); RC=$?
grep -q '^#1 ticket/bh-560 RETROFITTED' <<<"$OUT" && ok || bad "12 PR 1 should read RETROFITTED, got: $OUT"
grep -q '^#2 ticket/bh-561 CODE-CONFLICT' <<<"$OUT" && ok || bad "12 PR 2 should read CODE-CONFLICT, got: $OUT"
[ "$RC" = 0 ] && ok || bad "12 a sweep with no refusals should exit 0 (rc=$RC)"

# ---------------------------------------------------------------------------
# 13-15. THE SHAPE THE COHORT IS ACTUALLY IN (BH-868 fix round, finding 1).
#   main has carried `docs/verification-map/README.md merge=union` in
#   .gitattributes since BH-865, so a PR that has merged main since then does
#   NOT conflict on the README any more: git's union driver glues main's
#   generated table onto the PR's hand table and the merge is CLEAN. The first
#   cut of this script computed its merge base from MERGE_HEAD, which a clean
#   merge does not leave behind, so it printed "nothing to retrofit", returned
#   0, and the --all-open sweep rendered that as RETROFITTED — for a branch
#   still red on --check. These cases pin the clean-merge path and the
#   distinct NOTHING status that makes a no-op readable as a no-op.
# ---------------------------------------------------------------------------
# 13. a clean union merge with an orphan hand row is still retrofitted.
RU="$T/cli-union"; cli_fixture "$RU" --union-attr || bad "13 fixture"
HEADU=$(git -C "$RU" rev-parse ticket/bh-560)
g "$RU" checkout -q ticket/bh-560
g "$RU" merge -q --no-edit main >/dev/null 2>&1 && ok \
  || bad "13 the fixture must merge CLEANLY under merge=union (that is the whole point)"
g "$RU" reset -q --hard "$HEADU"
g "$RU" checkout -q main
printf '%s' "$HEADU" > "$T_HEAD1"
: > "$GHLOG"
OUT=$("$RETRO" "$RU" 1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "13 a clean union merge must still retrofit (rc=$RC): $OUT"
grep -q 'retrofitted' <<<"$OUT" && ok || bad "13 the line must say retrofitted, got: $OUT"
NEWU=$(git -C "$RU.origin.git" rev-parse refs/heads/ticket/bh-560)
[ "$NEWU" != "$HEADU" ] && ok || bad "13 the remote branch must advance on a clean union merge"
VU="$T/verify13"; git clone -q "$RU.origin.git" -b ticket/bh-560 "$VU" 2>/dev/null
[ -f "$VU/docs/verification-map/entries/BH-560.md" ] && ok || bad "13 the pushed head must carry entries/BH-560.md"
"$VU/bin/verification-map-build.sh" --check-committed --repo "$VU" >/dev/null 2>&1 && ok \
  || bad "13 --check must be in sync on the pushed head (the whole ticket)"
[ "$(grep -c '^| ' "$VU/docs/verification-map/README.md")" = 4 ] && ok \
  || bad "13 the pushed README must hold one header + 3 rows, got $(grep -c '^| ' "$VU/docs/verification-map/README.md")"

# 14. a PR with nothing to retrofit is rc 5, not a silent 0 that reads as done.
RN14="$T/cli-nothing"; cli_fixture "$RN14" --no-hand-row || bad "14 fixture"
H14=$(git -C "$RN14" rev-parse ticket/bh-560); printf '%s' "$H14" > "$T_HEAD1"
REMOTE_BEFORE=$(git -C "$RN14.origin.git" rev-parse refs/heads/ticket/bh-560)
: > "$GHLOG"
OUT=$("$RETRO" "$RN14" 1 2>&1); RC=$?
[ "$RC" = 5 ] && ok || bad "14 a PR with nothing to retrofit must answer rc 5, got rc=$RC: $OUT"
[ "$(git -C "$RN14.origin.git" rev-parse refs/heads/ticket/bh-560)" = "$REMOTE_BEFORE" ] && ok \
  || bad "14 a no-op must not move the remote branch"
grep -q 'issues/[0-9]*/comments' "$GHLOG" && bad "14 a no-op must post no comment" || ok

# 15. and the sweep renders that as NOTHING, never RETROFITTED.
: > "$GHLOG"
OUT=$("$RETRO" --all-open "$RN14" 2>&1)
grep -q '^#1 ticket/bh-560 NOTHING' <<<"$OUT" && ok \
  || bad "15 the sweep must print NOTHING for a PR it never touched, got: $OUT"
grep -q '^#1 ticket/bh-560 RETROFITTED' <<<"$OUT" && bad "15 a no-op must never read RETROFITTED" || ok

# 16. dry run enforces the same preconditions as the real run (finding 7): a
#     repo with no build script is "not mine", not a WOULD-write.
RD16="$T/cli-dry-nobuild"; cli_fixture "$RD16" --no-build-script || bad "16 fixture"
git -C "$RD16" rev-parse ticket/bh-560 > "$T_HEAD1"
OUT=$("$RETRO" --dry-run "$RD16" 1 2>&1); RC=$?
grep -q 'WOULD write' <<<"$OUT" && bad "16 a dry run must not promise a write the real run declines" || ok
[ "$RC" = 1 ] && ok || bad "16 a repo without the build script must be rc 1 on a dry run too, got rc=$RC: $OUT"

# ---------------------------------------------------------------------------
# 10-11. THE PRODUCTION ENTRY POINT: mc_resolve_conflicts, the mechanical rung's
#        whole conflict policy, driven against a real merge.
# ---------------------------------------------------------------------------
cp "$DIR/bin/verification-map-retrofit.sh" "$T/h/bin/"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"; mc_init

R10="$T/mc-readme"; build_fixture "$R10" >/dev/null
start_merge "$R10" || bad "10 fixture should conflict"
OUT=$(mc_resolve_conflicts "$R10" ticket/bh-560); RC=$?
[ "$RC" = 0 ] && ok || bad "10 mc_resolve_conflicts should resolve a README-only conflict (rc=$RC): $OUT"
[ -z "$OUT" ] && ok || bad "10 stdout must be empty on success, got: $OUT"
STAGED=$(git -C "$R10" diff --cached --name-only)
grep -qx 'docs/verification-map/entries/BH-560.md' <<<"$STAGED" && ok \
  || bad "10 the entry file must be staged, got: $(tr '\n' ' ' <<<"$STAGED")"
grep -q '<<<<<<<' "$R10/docs/verification-map/README.md" && bad "10 no markers may survive" || ok
"$R10/bin/verification-map-build.sh" --check-committed --repo "$R10" >/dev/null 2>&1 && ok \
  || bad "10 --check must be in sync after the mechanical rung resolved it"
[ -z "$(git -C "$R10" diff --name-only --diff-filter=U)" ] && ok || bad "10 no path may stay conflicted"
g "$R10" merge --abort >/dev/null 2>&1

# 10b. README + a code path: exactly today's behaviour — rc 1, the full list.
R10B="$T/mc-both"; build_fixture "$R10B" >/dev/null
g "$R10B" checkout -q ticket/bh-560
echo 'echo branch-side' > "$R10B/bin/x.sh"; g "$R10B" add -A; g "$R10B" commit -qm 'branch x.sh'
g "$R10B" checkout -q main
echo 'echo main-side' > "$R10B/bin/x.sh"; g "$R10B" add -A; g "$R10B" commit -qm 'main x.sh'
start_merge "$R10B" || bad "10b fixture should conflict"
OUT=$(mc_resolve_conflicts "$R10B" ticket/bh-560); RC=$?
[ "$RC" = 1 ] && ok || bad "10b a code conflict must still fail the rung (rc=$RC)"
grep -q 'bin/x.sh' <<<"$OUT" && grep -q 'docs/verification-map/README.md' <<<"$OUT" && ok \
  || bad "10b stdout must list both paths, got: $OUT"
g "$R10B" merge --abort >/dev/null 2>&1

# 11. a repo WITHOUT bin/verification-map-build.sh falls through to the union
#     resolver — byte-identical to today, which is what keeps every other repo
#     and tests/generated-path-conflicts-test.sh on their current path.
R11="$T/mc-nobuild"; build_fixture "$R11" --no-build-script >/dev/null
start_merge "$R11" || bad "11 fixture should conflict"
OUT=$(mc_resolve_conflicts "$R11" ticket/bh-560); RC=$?
[ "$RC" = 0 ] && ok || bad "11 the union fall-through must still resolve (rc=$RC): $OUT"
[ -f "$R11/docs/verification-map/entries/BH-560.md" ] && bad "11 no entry file may be invented here" || ok
grep -qF "$ROW_G" "$R11/docs/verification-map/README.md" && ok || bad "11 the union keeps both sides' rows"
g "$R11" merge --abort >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 17-19. A DECLINE MUST LEAVE THE TREE IT FOUND (BH-868 fix round, finding 2).
#   vmr_resolve_readme overwrites the README with main's copy and writes
#   entries/<KEY>.md BEFORE the fallible rebuild. When the rebuild or --check
#   then fails it returns 3 — and the first cut left both writes on disk. Two
#   consequences: the `*.md` union fall-through needs conflict markers and they
#   were gone, so the rung FAILED instead of behaving as it did before; and the
#   untracked entries/<KEY>.md survived `git merge --abort` in the conductor's
#   REUSED scratch clone, where the next PR's retrofit committed another
#   ticket's row into an unrelated PR.
# ---------------------------------------------------------------------------
break_build() { printf '#!/bin/bash\nexit 1\n' > "$1/bin/verification-map-build.sh"; chmod +x "$1/bin/verification-map-build.sh"; }

R17="$T/mc-decline"; build_fixture "$R17" >/dev/null
B17=$(git -C "$R17" merge-base ticket/bh-560 main)
start_merge "$R17" || bad "17 fixture should conflict"
BEFORE17=$(cat "$R17/docs/verification-map/README.md")
break_build "$R17"
OUT=$(vmr_resolve_readme "$R17" "$B17" "$(git -C "$R17" rev-parse HEAD)" BH-560 2>&1); RC=$?
[ "$RC" = 3 ] && ok || bad "17 a build that cannot regenerate must refuse rc 3, got rc=$RC: $OUT"
[ "$(cat "$R17/docs/verification-map/README.md")" = "$BEFORE17" ] && ok \
  || bad "17 a decline must restore the README byte-for-byte (the union fall-through needs its markers)"
grep -q '<<<<<<<' "$R17/docs/verification-map/README.md" && ok || bad "17 the conflict markers must still be there after a decline"
[ -e "$R17/docs/verification-map/entries/BH-560.md" ] && bad "17 a decline must leave no entry file behind" || ok

# 18. and so the mechanical rung falls through to the union resolver exactly as
#     the docs promise, instead of failing the rung.
R18="$T/mc-decline-rung"; build_fixture "$R18" >/dev/null
start_merge "$R18" || bad "18 fixture should conflict"
break_build "$R18"
: > "$MC_LOG"
OUT=$(mc_resolve_conflicts "$R18" ticket/bh-560); RC=$?
[ "$RC" = 0 ] && ok || bad "18 a declined retrofit must fall through to the union resolver (rc=$RC): $OUT"
grep -q '<<<<<<<' "$R18/docs/verification-map/README.md" && bad "18 the union resolver must leave no markers" || ok
[ -e "$R18/docs/verification-map/entries/BH-560.md" ] && bad "18 no stray entry file may survive a decline in the rung" || ok
[ -z "$(git -C "$R18" status --porcelain -uall -- docs/verification-map/entries | grep '^??')" ] && ok \
  || bad "18 the reused conductor clone must carry no untracked entry file: $(git -C "$R18" status --porcelain -uall -- docs/verification-map/entries | grep '^??' | tr '\n' ' ')"

# 19. and the decline is LOGGED with the real rc and the reason. `$?` after an
#     `if` whose condition failed is 0, so the first cut always logged "rc 0"
#     and sent the one line that says why to /dev/null.
grep -q 'retrofit declined (rc 3' "$MC_LOG" && ok \
  || bad "19 the decline log must carry the real rc, got: $(grep 'retrofit declined' "$MC_LOG" | tail -1)"
grep -q 'retrofit declined (rc 3.*regenerate' "$MC_LOG" && ok \
  || bad "19 the decline log must carry the reason, got: $(grep 'retrofit declined' "$MC_LOG" | tail -1)"
g "$R18" merge --abort >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 20. THE CONDUCTOR'S OWN CLEAN MERGE (BH-868 fix round, finding 1, hook half).
#   Under `merge=union` the conductor's `git merge origin/main` succeeds, so
#   mc_resolve_conflicts is never reached and the rung committed and pushed a
#   README with main's table glued onto the PR's — CI red on --check, which is
#   the exact outcome this ticket exists to stop.
# ---------------------------------------------------------------------------
R20="$T/mc-clean-union"; build_fixture "$R20" --union-attr >/dev/null
PRE20=$(git -C "$R20" rev-parse ticket/bh-560)
g "$R20" checkout -q ticket/bh-560
g "$R20" merge -q --no-edit main >/dev/null 2>&1 && ok || bad "20 the fixture must merge cleanly under merge=union"
"$R20/bin/verification-map-build.sh" --check-committed --repo "$R20" >/dev/null 2>&1 \
  && bad "20 the glued README must be OUT of sync — otherwise this case proves nothing" || ok
OUT=$(mc_resolve_vmap_clean_merge "$R20" ticket/bh-560 "$PRE20" main 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "20 the clean-merge repair must succeed (rc=$RC): $OUT"
"$R20/bin/verification-map-build.sh" --check-committed --repo "$R20" >/dev/null 2>&1 && ok \
  || bad "20 --check must be in sync after the repair"
[ "$(git -C "$R20" show HEAD:docs/verification-map/entries/BH-560.md 2>/dev/null)" = "$ROW_G" ] && ok \
  || bad "20 the repair must COMMIT entries/BH-560.md, not just write it"
[ -z "$(git -C "$R20" status --porcelain -uall -- docs/verification-map)" ] && ok \
  || bad "20 the repair must leave nothing uncommitted: $(git -C "$R20" status --porcelain -uall -- docs/verification-map)"
[ "$(grep -c '^| ' "$R20/docs/verification-map/README.md")" = 4 ] && ok \
  || bad "20 the repaired README must hold one header + 3 rows, got $(grep -c '^| ' "$R20/docs/verification-map/README.md")"

# 20b. a clean merge with nothing wrong is left completely alone.
R20B="$T/mc-clean-ok"; build_fixture "$R20B" --union-attr --no-hand-row >/dev/null
PRE20B=$(git -C "$R20B" rev-parse ticket/bh-560)
g "$R20B" checkout -q ticket/bh-560
g "$R20B" merge -q --no-edit main >/dev/null 2>&1
HEAD20B=$(git -C "$R20B" rev-parse HEAD)
mc_resolve_vmap_clean_merge "$R20B" ticket/bh-560 "$PRE20B" main >/dev/null 2>&1
[ "$?" = 0 ] && ok || bad "20b a healthy clean merge must be rc 0"
[ "$(git -C "$R20B" rev-parse HEAD)" = "$HEAD20B" ] && ok || bad "20b a healthy clean merge must get no extra commit"

echo "verification-map-retrofit: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
