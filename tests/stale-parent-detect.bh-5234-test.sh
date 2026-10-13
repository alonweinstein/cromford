#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stale-parent-detect.bh-5234-test.sh — a PR stacked on a parent that
# landed on main under another sha (cherry-pick, squash, rebase) still carries
# the parent's commits. bin/lib/stale-parent.sh names them by patch-id, and a
# bin/pipeline-health.sh block pages each open PR that carries one (BH-5234).
#
# D1-D4 drive sp_stale_commits against real git fixtures, including a child
# that sync-merged main (so `git cherry` would hide the copy). D5-D8 extract the
# pipeline-health block VERBATIM between its markers and run it against a bare
# origin, a full hub clone and a fake gh. RETRACT_NS is read from the real file.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SPLIB="$DIR/bin/lib/stale-parent.sh"
PH="$DIR/bin/pipeline-health.sh"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name tester
git config --global commit.gpgsign false
git config --global init.defaultBranch main

# commit <repo> <file> <subject>
commit() { echo "$3" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$3"; }
sha() { git -C "$1" rev-parse "$2"; }

# mkstale <repo> — main: base, m1, then p1 cherry-picked (another sha).
# Branch p: p1 off base. Branch child: c1 off p1.
mkstale() {
  local r="$1"
  git init -q "$r"
  commit "$r" base.txt "base"
  git -C "$r" checkout -q -b p
  commit "$r" p1.txt "p1: parent work"
  git -C "$r" checkout -q -b child
  commit "$r" c.txt "c1: child work"
  git -C "$r" checkout -q main
  commit "$r" m.txt "m1: other main work"
  git -C "$r" cherry-pick p >/dev/null
  git -C "$r" checkout -q child
}

# sp <repo> <base> <head> — run sp_stale_commits in a subshell; rc in $T/sp.rc
sp() {
  ( [ -f "$SPLIB" ] || exit 99
    # shellcheck disable=SC1090
    . "$SPLIB"; sp_stale_commits "$@" ) > "$T/sp.out" 2> "$T/sp.err"
  echo $? > "$T/sp.rc"
}

# ── the lib ───────────────────────────────────────────────────────────────
if [ -f "$SPLIB" ]; then
  ok
  SRC=$( # shellcheck disable=SC1090
         . "$SPLIB" 2>&1 )
  [ -z "$SRC" ] && ok || bad "sourcing bin/lib/stale-parent.sh printed output: $SRC"
else
  bad "bin/lib/stale-parent.sh does not exist (BH-5234)"
fi

# D1 — child stacked on p1, p1 landed on main by cherry-pick.
R1="$T/d1"; mkstale "$R1"
P1=$(sha "$R1" p); M1=$(sha "$R1" main)
sp "$R1" main child
[ "$(cat "$T/sp.rc")" = 0 ] && ok || bad "D1: sp_stale_commits rc=$(cat "$T/sp.rc") ($(cat "$T/sp.err"))"
[ "$(grep -c . "$T/sp.out")" = 1 ] && ok || bad "D1: expected exactly one row, got: $(cat "$T/sp.out")"
IFS=$'\t' read -r C1 C2 C3 < "$T/sp.out"
[ "${C1:-}" = "$P1" ] && ok || bad "D1: col1 must be p1's sha $P1, got '${C1:-}'"
[ "${C2:-}" = "$M1" ] && ok || bad "D1: col2 must be main's cherry-picked sha $M1, got '${C2:-}'"
[ -n "${C1:-}" ] && [ "${C1:-}" != "${C2:-}" ] && ok || bad "D1: col1 and col2 must differ"
[ "${C3:-}" = "p1: parent work" ] && ok || bad "D1: col3 must be p1's subject, got '${C3:-}'"

# D2 — the child then sync-merges main: main's copy is reachable from the head,
#      so `git cherry` would see nothing. Still one row for p1.
R2="$T/d2"; mkstale "$R2"
P2=$(sha "$R2" p); M2=$(sha "$R2" main)
git -C "$R2" merge -q --no-edit main >/dev/null
sp "$R2" main child
[ "$(cat "$T/sp.rc")" = 0 ] && ok || bad "D2: sp_stale_commits rc=$(cat "$T/sp.rc") ($(cat "$T/sp.err"))"
[ "$(grep -c . "$T/sp.out")" = 1 ] && ok || bad "D2: a sync-merged child must still give exactly one row, got: $(cat "$T/sp.out")"
grep -q "^$P2	$M2	p1: parent work\$" "$T/sp.out" && ok || bad "D2: the row must be p1 -> main's copy, got: $(cat "$T/sp.out")"

# D3 — a clean child with only its own commits on main: no rows, rc 0.
R3="$T/d3"; git init -q "$R3"; commit "$R3" base.txt base; commit "$R3" m.txt m1
git -C "$R3" checkout -q -b child; commit "$R3" c.txt "c1: own"; commit "$R3" c2.txt "c2: own"
sp "$R3" main child
[ "$(cat "$T/sp.rc")" = 0 ] && ok || bad "D3: a clean child must be rc 0, got $(cat "$T/sp.rc") ($(cat "$T/sp.err"))"
[ -s "$T/sp.out" ] && bad "D3: a clean child gave rows: $(cat "$T/sp.out")" || ok

# D4 — the child's own commit merged into main with --no-ff (same sha on main).
R4="$T/d4"; git init -q "$R4"; commit "$R4" base.txt base
git -C "$R4" checkout -q -b child; commit "$R4" c.txt "c1: own"
git -C "$R4" checkout -q main; commit "$R4" m.txt m1
git -C "$R4" merge -q --no-ff --no-edit child >/dev/null
sp "$R4" main child
[ "$(cat "$T/sp.rc")" = 0 ] && ok || bad "D4: rc=$(cat "$T/sp.rc") ($(cat "$T/sp.err"))"
[ -s "$T/sp.out" ] && bad "D4: a commit merged as itself is not stale: $(cat "$T/sp.out")" || ok

# A git failure is not a clean answer.
sp "$R1" main no-such-ref
[ -f "$SPLIB" ] && [ "$(cat "$T/sp.rc")" != 0 ] && ok || bad "a bad head ref must be non-zero (rc=$(cat "$T/sp.rc"))"

# ── the pipeline-health block ─────────────────────────────────────────────
A=$(grep -c '^# >>> stale parent (BH-5234)' "$PH")
B=$(grep -c '^# <<< stale parent' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> stale parent (BH-5234)' … '# <<< stale parent' block (open=$A close=$B)"
awk '/^# <<< stale dequeue/{d=1} d && /^# >>> stale parent \(BH-5234\)/{o=1} END{exit !o}' "$PH" \
  && ok || bad "the stale parent block must follow '# <<< stale dequeue' (inside the PH_ALL section)"
awk '/^# >>> stale parent \(BH-5234\)/{f=1;next} /^# <<< stale parent/{exit} f' "$PH" > "$T/block.sh"

RL=$(grep -m1 '^RETRACT_NS=' "$PH")
RNS=$( eval "$RL"; printf '%s' "$RETRACT_NS" )
grep -qE "^($RNS):" <<<"staleparent:demo:7" \
  && ok || bad "staleparent is not in RETRACT_NS, so a restacked PR never retracts its page"

if [ ! -s "$T/block.sh" ]; then
  bad "no stale parent block to run; D5-D8 not driven"
  echo "stale-parent-detect.bh-5234: $PASS passed, $FAIL failed"
  exit 1
fi

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$T/fakebin" "$T/repos"
[ -f "$SPLIB" ] && cp "$SPLIB" "$H/bin/lib/" # scratch-closure-allow: the block sources this one lib directly; its own unit is driven above
printf 'demo example-org/demo-os - - 2 box\n' > "$H/fleet.conf"

# Origin: main carries p1's cherry-picked copy; refs/pull/7/head is the stale
# child, refs/pull/8/head and 101..131 a clean child.
SEED="$T/seed"; mkstale "$SEED"
STALE=$(sha "$SEED" child); LASTSTALE=$(sha "$SEED" p)
git -C "$SEED" checkout -q -b clean main; commit "$SEED" k.txt "k1: clean"
CLEAN=$(sha "$SEED" clean)
git init -q --bare "$T/origin.git"
git -C "$SEED" push -q "$T/origin.git" main:refs/heads/main "$STALE:refs/pull/7/head" "$CLEAN:refs/pull/8/head"
for n in $(seq 101 131); do git -C "$T/origin.git" update-ref "refs/pull/$n/head" "$CLEAN"; done
reclone() { rm -rf "$T/repos/demo"; git clone -q "$T/origin.git" "$T/repos/demo"; }

pr() { printf '{"number":%s,"html_url":"https://github.com/example-org/demo-os/pull/%s","base":{"ref":"main","repo":{"default_branch":"main"}}}' "$1" "$1"; }

cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CT/gh-calls.txt"
case "$*" in
  *"api repos/example-org/demo-os/pulls?state=open&per_page=100"*)
    [ "$(cat "$CT/list-mode" 2>/dev/null)" = down ] && exit 1; cat "$CT/list.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"

drive() { # drive [env...]
  : > "$T/alerts.txt"; : > "$T/gh-calls.txt"; : > "$H/state/health-fired.test"
  ( export PATH="$T/fakebin:$PATH" CT="$T" HUB_REPOS="$T/repos" "$@"
    H="$T/h"; PROJECTS=demo; NOW=1790000000
    FIRED="$T/h/state/health-fired.test"; ACTIVE="$T/h/state/health-active.txt"
    gh_budget_low() { return 1; }
    alert() { printf '%s|%s\n' "$2" "$3" >> "$T/alerts.txt"; echo "$2" >> "$FIRED"; }
    # shellcheck disable=SC1090
    . "$T/block.sh"; echo reached ) > "$T/drive.out" 2>&1
}
FIREDF="$H/state/health-fired.test"

# D5 — one stale PR (#7) and one clean (#8): one page, for #7.
reclone; echo ok > "$T/list-mode"; : > "$H/state/health-active.txt"
printf '[%s,%s]' "$(pr 7)" "$(pr 8)" > "$T/list.json"
drive
grep -qx reached "$T/drive.out" && ok || bad "D5: the block did not run to its end: $(cat "$T/drive.out")"
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && ok || bad "D5: exactly one page expected, got: $(cat "$T/alerts.txt")"
grep -q '^staleparent:demo:7|.*#7.*stale-parent' "$T/alerts.txt" \
  && ok || bad "D5: the page must be keyed staleparent:demo:7 and name '#7' and 'stale-parent': $(cat "$T/alerts.txt")"
grep -q '^staleparent:demo:7|.*https://github.com/example-org/demo-os/pull/7' "$T/alerts.txt" \
  && ok || bad "D5: the page must carry the PR url"
grep -q "^staleparent:demo:7|.*$LASTSTALE" "$T/alerts.txt" \
  && ok || bad "D5: the page must name the last stale sha for the rebase --onto"
grep -q ':8|' "$T/alerts.txt" && bad "D5: a clean PR (#8) paged" || ok
grep -qx 'staleparent:demo:7' "$FIREDF" && ok || bad "D5: FIRED must hold staleparent:demo:7"
[ "$(grep -c 'pulls?state=open' "$T/gh-calls.txt")" = 1 ] && ok || bad "D5: exactly one list read per project expected: $(cat "$T/gh-calls.txt")"

# D6 — the list read fails: no page, and an active page is held, not cleared.
echo down > "$T/list-mode"; echo 'staleparent:demo:7' > "$H/state/health-active.txt"
drive
[ -s "$T/alerts.txt" ] && bad "D6: a failed list read paged: $(cat "$T/alerts.txt")" || ok
grep -qx 'staleparent:demo:7' "$FIREDF" && ok || bad "D6: a skipped read must re-assert the active key in FIRED (a skip is never a clear)"
grep -qx reached "$T/drive.out" && ok || bad "D6: the block did not run to its end: $(cat "$T/drive.out")"

# D7 — STALE_PARENT_CHECK=0: no read at all, no page.
echo ok > "$T/list-mode"; : > "$H/state/health-active.txt"
drive STALE_PARENT_CHECK=0
[ -s "$T/gh-calls.txt" ] && bad "D7: STALE_PARENT_CHECK=0 still called gh: $(cat "$T/gh-calls.txt")" || ok
[ -s "$T/alerts.txt" ] && bad "D7: STALE_PARENT_CHECK=0 paged: $(cat "$T/alerts.txt")" || ok

# D8 — 31 clean PRs over a cap of 30: the cut is named, 30 are fetched.
reclone
L=""; for n in $(seq 101 131); do L="$L${L:+,}$(pr "$n")"; done
printf '[%s]' "$L" > "$T/list.json"
drive STALE_PARENT_MAX_PRS=30
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && ok || bad "D8: exactly one page expected (the cut), got: $(cat "$T/alerts.txt")"
grep -q '^staleparent:demo:page-cut|' "$T/alerts.txt" && ok || bad "D8: a 31-PR list must page staleparent:demo:page-cut: $(cat "$T/alerts.txt")"
NREF=$(git -C "$T/repos/demo" for-each-ref refs/ph-stale | wc -l)
[ "$NREF" = 30 ] && ok || bad "D8: the cap is 30 fetched PR heads (got $NREF refs under refs/ph-stale/)"

echo "stale-parent-detect.bh-5234: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
