#!/bin/bash
# tests/contested-store-test.sh — the contested-hold store, the conflict-size
# sidecar and the two no-page rules (BH-587, the contract slice of BH-579).
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a file on disk or an rc:
# which JSON the store writes, which rows a release moves and which it leaves
# alone, whether an expired hold still answers, and whether mc_rebase writes the
# size of the conflict it just hit. `grep -q mc_contested_write bin/lib/...`
# passes on a function nothing calls and on a store that never writes.
#
# The sidecar case (§6) drives the PRODUCTION entry point: a real mc_rebase
# against a real local bare origin whose branch really conflicts with main. The
# only stub is `gh auth token`, so nothing here can reach the box's real PAT.
# Run from anywhere: tests/contested-store-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$T/fakebin" "$T/repos"
# HARNESS is read at SOURCE time by the lib (MC_H), so it is exported first.
export HARNESS="$H"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/"
# mc_pr_files reads the file list through bin/lib/gh-rest.sh since BH-784, so the
# contract rides into the fixture tree with the lib; without it the lib keeps its
# fail-closed shim and §7 would assert against a reader that cannot read.
# restpr (tests/lib/rest-emit.sh) is how the stub answers: gh-rest.sh judges the
# HTTP STATUS LINE, not gh's exit code, so an answer is a full HTTP response.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# BH-680: the lib is a shim over bin/lib/mc/ and resolves its modules off its own
# BASH_SOURCE, so a fixture that copies the lib copies the modules with it or the
# source exits the test.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh"
mc_init
NOW=$(date +%s)

# One git identity for every git call in this file AND for the ones the lib
# makes: a box with no global user.email cannot commit, and the insteadOf pair
# below is what lets mc_rebase's https remote resolve to the local bare origin.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always

# Paths are built LITERALLY here, never through the functions under test: a
# missing helper expands to nothing and a test that then writes to / is worse
# than a red one.
hold_path() { printf '%s/state/contested/%s/%s' "$H" "$1" "$(printf '%s' "$2" | sha1sum | cut -c1-16)"; }
rows() { printf '%s/state/merge-conductor/pr-state.tsv' "$H"; }

# ============================================================================
# 0. mc_init creates both new dirs
# ============================================================================
[ -d "$H/state/contested" ] \
  && ok || bad "mc_init must create state/contested"
[ -d "$H/state/merge-conductor/conflict-size" ] \
  && ok || bad "mc_init must create state/merge-conductor/conflict-size"

# ============================================================================
# 1. mc_conflict_lines — marker-bounded lines, summed, over a REAL conflict
# ============================================================================
ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b ticket/TK-41
printf 'the branch changed this line\n' >> "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on TK-41"
git -C "$SEED" push -q origin ticket/TK-41
# main moves AFTER the branch, on the same line: the conflict is one git
# computes, not a fixture that says the word.
git -C "$SEED" checkout -q main
printf 'main changed this line\n' >> "$SEED/a.txt"
git -C "$SEED" commit -qam "main work"; git -C "$SEED" push -q origin main
HEAD41=$(git -C "$ORIGIN" rev-parse ticket/TK-41)

git clone -q "$ORIGIN" "$T/probe" 2>/dev/null
git -C "$T/probe" checkout -q ticket/TK-41
git -C "$T/probe" merge -q --no-edit origin/main >/dev/null 2>&1 \
  && bad "the fixture must really conflict — it merged cleanly" || ok
EXPECT=$(awk '/^<<<<<<< /{b=1} b{n++} /^>>>>>>> /{b=0} END{print n+0}' "$T/probe/a.txt")
[ "${EXPECT:-0}" -gt 0 ] \
  && ok || bad "the fixture must leave conflict markers in a.txt (got '$EXPECT')"
[ "$(mc_conflict_lines "$T/probe")" = "$EXPECT" ] \
  && ok || bad "mc_conflict_lines must count the marker-bounded lines ($EXPECT), not the whole diff (got '$(mc_conflict_lines "$T/probe")')"
# The whole-diff reading of the same tree is a DIFFERENT number, so the
# assertion above cannot be satisfied by `git diff | wc -l`.
[ "$(git -C "$T/probe" diff | wc -l)" != "$EXPECT" ] \
  && ok || bad "fixture too weak: git diff | wc -l happens to equal the marker count, so §1 proves nothing"
git clone -q "$ORIGIN" "$T/clean" 2>/dev/null
[ "$(mc_conflict_lines "$T/clean")" = 0 ] \
  && ok || bad "a clean tree must answer 0 (got '$(mc_conflict_lines "$T/clean")')"
[ "$(mc_conflict_lines "$T/nope-not-a-tree")" = 0 ] \
  && ok || bad "a path that is not a git tree must answer 0, not crash (got '$(mc_conflict_lines "$T/nope-not-a-tree")')"
[ "$(mc_conflict_size_file o/tproj 41)" = "$H/state/merge-conductor/conflict-size/o_tproj_41" ] \
  && ok || bad "mc_conflict_size_file must map / to _ (got '$(mc_conflict_size_file o/tproj 41)')"

# A DELETE/MODIFY CONFLICT MEASURES 0, AND 0 IS NOT A SMALL CONFLICT. git leaves
# NO `<<<<<<<` markers for a `UD` path — the file is simply there, unmerged — so
# the honest marker count over a real one is 0. This is what makes a measured 0
# unknown rather than tiny (bin/blocked-resolver.sh br_shape), and it is proved
# here on a tree git really conflicted rather than asserted in prose.
git -C "$SEED" checkout -q main
printf 'gone soon\n' > "$SEED/d.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm "d.txt lands"; git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b ticket/ts-del
printf 'the branch edits it\n' >> "$SEED/d.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm "edit d.txt"; git -C "$SEED" push -q origin ticket/ts-del
git -C "$SEED" checkout -q main
git -C "$SEED" rm -q d.txt; git -C "$SEED" commit -qm "main deletes d.txt"; git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$T/udprobe" 2>/dev/null
git -C "$T/udprobe" checkout -q ticket/ts-del
git -C "$T/udprobe" merge -q --no-edit origin/main >/dev/null 2>&1 \
  && bad "the delete/modify fixture must really conflict — it merged cleanly" || ok
[ "$(git -C "$T/udprobe" status --porcelain -- d.txt | cut -c1-2)" = UD ] \
  && ok || bad "the fixture must leave d.txt as a delete/modify (UD) conflict (got '$(git -C "$T/udprobe" status --porcelain -- d.txt)')"
[ -n "$(git -C "$T/udprobe" diff --name-only --diff-filter=U)" ] \
  && ok || bad "and git must report it as unmerged, or mc_conflict_lines is not even asked"
grep -q '^<<<<<<< ' "$T/udprobe/d.txt" \
  && bad "a delete/modify conflict has NO markers — if this file has them the claim below is wrong" || ok
[ "$(mc_conflict_lines "$T/udprobe")" = 0 ] \
  && ok || bad "a real delete/modify conflict measures 0 marker-bounded lines (got '$(mc_conflict_lines "$T/udprobe")')"

# ============================================================================
# 2. mc_contested_write — the hold JSON, its path, its ttl, and its failure
# ============================================================================
LPRS='[{"num":41,"url":"https://gh/o/tproj/pull/41","key":"TK-6"}]'
mc_contested_write tproj o/tproj src/x.ts TK-5 https://gh/o/tproj/pull/40 "$LPRS" '["TK-7"]' '' 'siblings collided' \
  && ok || bad "mc_contested_write must answer rc 0"
F1=$(hold_path tproj src/x.ts)
[ -s "$F1" ] && ok || bad "the hold must be at state/contested/tproj/<sha1(path)[0:16]> ($F1)"
[ "$(mc_contested_file tproj src/x.ts)" = "$F1" ] \
  && ok || bad "mc_contested_file must print that path (got '$(mc_contested_file tproj src/x.ts)')"
[ "$(mc_contested_dir tproj)" = "$H/state/contested/tproj" ] \
  && ok || bad "mc_contested_dir (got '$(mc_contested_dir tproj)')"
[ "$(jq -r 'keys|join(",")' "$F1")" = "created,loser_prs,loser_tickets,path,project,repo,ttl,why,winner_key,winner_url" ] \
  && ok || bad "the hold carries EXACTLY the ten contract fields (got '$(jq -r 'keys|join(",")' "$F1")')"
[ "$(jq -r '[.project,.repo,.path,.winner_key,.winner_url,.why]|join("|")' "$F1")" = "tproj|o/tproj|src/x.ts|TK-5|https://gh/o/tproj/pull/40|siblings collided" ] \
  && ok || bad "the string fields must be what was passed (got '$(jq -r '[.project,.repo,.path,.winner_key,.winner_url,.why]|join("|")' "$F1")')"
[ "$(jq -r '[.loser_prs[0].num,.loser_prs[0].url,.loser_prs[0].key,.loser_tickets[0]]|join("|")' "$F1")" = "41|https://gh/o/tproj/pull/41|TK-6|TK-7" ] \
  && ok || bad "loser_prs and loser_tickets must survive as JSON (got '$(jq -c '[.loser_prs,.loser_tickets]' "$F1")')"
case "$(jq -r .created "$F1")" in ''|*[!0-9]*) bad "created must be a bare epoch (got '$(jq -r .created "$F1")')" ;; *) ok ;; esac
[ "$(jq -r .ttl "$F1")" = 21600 ] \
  && ok || bad "ttl defaults to 21600 (got '$(jq -r .ttl "$F1")')"
CONTESTED_TTL=60 mc_contested_write tproj o/tproj src/y.ts TK-5 https://gh/o/tproj/pull/40 '[]' '[]'
[ "$(jq -r .ttl "$(hold_path tproj src/y.ts)")" = 60 ] \
  && ok || bad "CONTESTED_TTL from the environment must win (got '$(jq -r .ttl "$(hold_path tproj src/y.ts)" 2>/dev/null)')"
[ "$(jq -r '.why + "|" + (.loser_prs|length|tostring)' "$(hold_path tproj src/y.ts)")" = "|0" ] \
  && ok || bad "why defaults to the empty string and empty losers stay empty"
# A malformed loser list is a REFUSED write, not a half-written hold.
mc_contested_write tproj o/tproj src/bad.ts TK-5 https://gh/o/tproj/pull/40 '{bad' '[]' \
  && bad "a malformed loser_prs JSON must be rc 1" || ok
[ -e "$(hold_path tproj src/bad.ts)" ] \
  && bad "a refused write must leave NO hold file" || ok
[ "$(find "$H/state/contested/tproj" -maxdepth 1 -name '.tmp*' | wc -l)" = 0 ] \
  && ok || bad "a refused write must clean up its temp file"
mc_contested_write tproj o/tproj src/bad2.ts TK-5 u '[]' '[]' notanumber \
  && bad "a non-numeric ttl must be rc 1" || ok
[ -e "$(hold_path tproj src/bad2.ts)" ] \
  && bad "a non-numeric ttl must leave NO hold file" || ok

# ============================================================================
# 3. mc_contested_list / _live / _loser / _wins
# ============================================================================
[ "$(mc_contested_list tproj | wc -l)" = 2 ] \
  && ok || bad "the list is one line per hold file (got '$(mc_contested_list tproj)')"
mc_contested_list nope > "$T/list-absent.out" 2> "$T/list-absent.err"; LRC=$?
[ "$LRC" = 0 ] && [ ! -s "$T/list-absent.out" ] && [ ! -s "$T/list-absent.err" ] \
  && ok || bad "mc_contested_list on an absent project is silent rc 0 (rc=$LRC)"
mc_contested_live "$F1" && ok || bad "a fresh hold must be live"
[ "$(mc_contested_loser tproj o/tproj 41)" = "$(printf 'src/x.ts\tTS-5')" ] \
  && ok || bad "mc_contested_loser must print path<TAB>winner_key (got '$(mc_contested_loser tproj o/tproj 41)')"
mc_contested_loser tproj o/tproj 41 >/dev/null && ok || bad "a hit is rc 0"
LOUT=$(mc_contested_loser tproj o/tproj 42 2>&1); LRC=$?
[ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "an unlisted PR is silent rc 1 (rc=$LRC out='$LOUT')"
LOUT=$(mc_contested_loser tproj o/tproj 410 2>&1); LRC=$?
[ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "410 must not match a hold listing 41 (rc=$LRC out='$LOUT')"
LOUT=$(mc_contested_loser tproj o/other 41 2>&1); LRC=$?
[ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "another repo's #41 must not match (rc=$LRC out='$LOUT')"
LOUT=$(mc_contested_loser nope o/tproj 41 2>&1); LRC=$?
[ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "no dir is silent rc 1 (rc=$LRC out='$LOUT')"
mc_contested_wins tproj TK-5 && ok || bad "mc_contested_wins must find the winner"
mc_contested_wins tproj TK-6 && bad "a loser key is not a winner" || ok
# An expired hold is inert the instant it expires, with nothing sweeping it.
mc_contested_write tproj o/tproj src/e.ts TK-9 https://gh/o/tproj/pull/90 '[{"num":99,"url":"u","key":"TK-8"}]' '[]' 60
FE=$(hold_path tproj src/e.ts)
jq --argjson c "$((NOW-100))" '.created=$c' "$FE" > "$T/e.json" && mv -f "$T/e.json" "$FE"
mc_contested_live "$FE" && bad "a hold older than its ttl is NOT live" || ok
LOUT=$(mc_contested_loser tproj o/tproj 99 2>&1); LRC=$?
[ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "an expired hold must not answer for its loser (rc=$LRC out='$LOUT')"
mc_contested_wins tproj TK-9 && bad "an expired hold has no winner" || ok
# Malformed files: never live, never a crash, never stderr noise — and they do
# not poison the queries for the holds that ARE well formed.
printf 'not json\n' > "$H/state/contested/tproj/1111111111111111"
printf '[]\n' > "$H/state/contested/tproj/2222222222222222"
printf '{"loser_prs":"41","repo":"o/tproj","created":%s,"ttl":600}\n' "$NOW" > "$H/state/contested/tproj/3333333333333333"
: > "$H/state/contested/tproj/4444444444444444"
for M in 1111111111111111 2222222222222222 4444444444444444; do
  LOUT=$(mc_contested_live "$H/state/contested/tproj/$M" 2>&1); LRC=$?
  [ "$LRC" = 1 ] && [ -z "$LOUT" ] && ok || bad "malformed hold $M must be rc 1 with no output (rc=$LRC out='$LOUT')"
done
LOUT=$(mc_contested_loser tproj o/tproj 41 2>&1); LRC=$?
[ "$LRC" = 0 ] && [ "$LOUT" = "$(printf 'src/x.ts\tTS-5')" ] \
  && ok || bad "malformed neighbours must not break the query (rc=$LRC out='$LOUT')"

# ============================================================================
# 4. mc_contested_release — rows first, file last, log once, alert on request
# ============================================================================
seed_row() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$NOW" "$3" "$4" "$5" "$6" >> "$(rows)"; }
: > "$(rows)"
WHY41='contested:src/x.ts (winner TK-5)'
seed_row 'o/tproj#41' BLOCKED_HUMAN h41 r41 "$WHY41"                      https://github.com/o/tproj/pull/41
seed_row 'o/tproj#42' MERGED        h42 r42 merged                        https://github.com/o/tproj/pull/42
seed_row 'o/tproj#44' BLOCKED_HUMAN h44 r44 'conflict-unresolvable: a.txt' https://github.com/o/tproj/pull/44
seed_row 'o/tproj#46' BLOCKED_HUMAN h46 r46 'contest-something'            https://github.com/o/tproj/pull/46
seed_row 'o/tproj#47' BLOCKED_HUMAN h47 r47 'Contested:src/x.ts'           https://github.com/o/tproj/pull/47
seed_row 'o/other#41' BLOCKED_HUMAN hOT rOT "$WHY41"                      https://github.com/o/other/pull/41
declare -A BEFORE
for K in 'o/tproj#42' 'o/tproj#44' 'o/tproj#46' 'o/tproj#47' 'o/other#41'; do BEFORE[$K]=$(mc_row_get "$K"); done
# 48 is listed as a loser and has no row at all.
mc_contested_write tproj o/tproj src/x.ts TK-5 https://gh/o/tproj/pull/40 \
  '[{"num":41,"url":"https://github.com/o/tproj/pull/41","key":"TK-6"},
    {"num":42,"url":"u42","key":"TK-7"},{"num":44,"url":"u44","key":"TK-8"},
    {"num":46,"url":"u46","key":"TK-9"},{"num":47,"url":"u47","key":"TK-10"},
    {"num":48,"url":"u48","key":"TK-11"}]' '["TK-6"]'
: > "$H/logs/ALERTS.log"; : > "$H/logs/merge-conductor.log"
mc_contested_release "$F1" "winner merged" && ok || bad "mc_contested_release must be rc 0"
[ "$(mc_row_get 'o/tproj#41' | cut -f2)" = NEEDS_REBASE ] \
  && ok || bad "the contested loser must move to NEEDS_REBASE (got '$(mc_row_get 'o/tproj#41' | cut -f2)')"
[ "$(mc_row_get 'o/tproj#41' | cut -f7)" = "contested released: winner merged" ] \
  && ok || bad "the reason must name the release (got '$(mc_row_get 'o/tproj#41' | cut -f7)')"
[ "$(mc_row_get 'o/tproj#41' | cut -f4,5)" = "$(printf 'h41\tr41')" ] \
  && ok || bad "head and reviewed sha ride through the release (got '$(mc_row_get 'o/tproj#41' | cut -f4,5)')"
[ "$(mc_row_get 'o/tproj#41' | cut -f8)" = https://github.com/o/tproj/pull/41 ] \
  && ok || bad "the url survives (got '$(mc_row_get 'o/tproj#41' | cut -f8)')"
for K in 'o/tproj#42' 'o/tproj#44' 'o/tproj#46' 'o/tproj#47' 'o/other#41'; do
  [ "$(mc_row_get "$K")" = "${BEFORE[$K]}" ] \
    && ok || bad "$K must be byte-identical after the release (was '${BEFORE[$K]}' now '$(mc_row_get "$K")')"
done
[ -e "$(mc_handoff_rel_file 'o/tproj#41')" ] \
  && ok || bad "the release marker the conductor reads must be written"
[ -e "$F1" ] && bad "the hold file must be gone" || ok
[ "$(grep -c 'contested hold on src/x.ts released' "$H/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "exactly one release line (got $(grep -c 'contested hold on src/x.ts released' "$H/logs/merge-conductor.log"))"
grep -q 'winner TK-5' "$H/logs/merge-conductor.log" \
  && ok || bad "the release line names the winner"
[ "$(grep -c contested "$H/logs/ALERTS.log")" = 0 ] \
  && ok || bad "a release without the alert word pages NOBODY (got: $(cat "$H/logs/ALERTS.log"))"
ROUT=$(mc_contested_release "$F1" "winner merged" 2>&1); LRC=$?
[ "$LRC" = 0 ] && [ -z "$ROUT" ] \
  && ok || bad "a second release on a missing file is silent rc 0 (rc=$LRC out='$ROUT')"
[ "$(grep -c 'contested hold on src/x.ts released' "$H/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "the idempotent re-run must not log a second release"
# The alert arm: one line, and it names what happened.
seed_row 'o/tproj#45' BLOCKED_HUMAN h45 r45 'contested:src/z.ts (winner TK-5)' https://github.com/o/tproj/pull/45
mc_contested_write tproj o/tproj src/z.ts TK-5 https://gh/o/tproj/pull/40 \
  '[{"num":45,"url":"https://github.com/o/tproj/pull/45","key":"TK-6"}]' '[]'
mc_contested_release "$(hold_path tproj src/z.ts)" "abandoned" alert
[ "$(mc_row_get 'o/tproj#45' | cut -f2)" = NEEDS_REBASE ] \
  && ok || bad "the alert release still moves the row (got '$(mc_row_get 'o/tproj#45' | cut -f2)')"
[ "$(grep -cE 'contested.*abandoned' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "exactly one ALERTS line on an alert release (got: $(cat "$H/logs/ALERTS.log"))"
grep -q 'src/z.ts' "$H/logs/ALERTS.log" \
  && ok || bad "the ALERTS line names the contested path"

# TWO LIVE HOLDS, ONE LOSER. #51 is a loser on BOTH the m/one.ts hold and the
# m/two.ts hold. Releasing the one.ts hold must leave it exactly where it is,
# because the two.ts hold is still live and still names it — unparking it here
# hands the conductor a PR that rebases straight back into a path somebody is
# still landing. #52 loses only on one.ts and is released in the same call.
: > "$(rows)"
seed_row 'o/tproj#51' BLOCKED_HUMAN h51 r51 'contested:m/two.ts (winner TK-20)' https://github.com/o/tproj/pull/51
seed_row 'o/tproj#52' BLOCKED_HUMAN h52 r52 'contested:m/one.ts (winner TK-20)' https://github.com/o/tproj/pull/52
B51=$(mc_row_get 'o/tproj#51')
LP='[{"num":51,"url":"https://github.com/o/tproj/pull/51","key":"TK-21"},
     {"num":52,"url":"https://github.com/o/tproj/pull/52","key":"TK-22"}]'
mc_contested_write tproj o/tproj m/one.ts TK-20 https://gh/o/tproj/pull/50 "$LP" '[]'
mc_contested_write tproj o/tproj m/two.ts TK-20 https://gh/o/tproj/pull/50 \
  '[{"num":51,"url":"https://github.com/o/tproj/pull/51","key":"TK-21"}]' '[]'
mc_contested_release "$(hold_path tproj m/one.ts)" "winner merged"
[ "$(mc_row_get 'o/tproj#51')" = "$B51" ] \
  && ok || bad "a loser a second LIVE hold still names must be byte-identical after this release (was '$B51' now '$(mc_row_get 'o/tproj#51')')"
mc_contested_loser tproj o/tproj 51 >/dev/null \
  && ok || bad "the m/two.ts hold must still name #51 — the fixture is meaningless otherwise"
[ "$(mc_row_get 'o/tproj#52' | cut -f2)" = NEEDS_REBASE ] \
  && ok || bad "the loser nobody else holds is still released (got '$(mc_row_get 'o/tproj#52' | cut -f2)')"
# And now the other way round: the same PR parked on the path being released,
# while a second live hold still names it. Still held — and the LAST hold to end
# is what unparks it, whichever path its own park names, so no order of releases
# can leave a loser parked with nobody holding it.
mc_contested_write tproj o/tproj m/one.ts TK-20 https://gh/o/tproj/pull/50 \
  '[{"num":51,"url":"https://github.com/o/tproj/pull/51","key":"TK-21"}]' '[]'
: > "$(rows)"
seed_row 'o/tproj#51' BLOCKED_HUMAN h51 r51 'contested:m/one.ts (winner TK-20)' https://github.com/o/tproj/pull/51
B51=$(mc_row_get 'o/tproj#51')
mc_contested_release "$(hold_path tproj m/one.ts)" "winner merged"
[ "$(mc_row_get 'o/tproj#51')" = "$B51" ] \
  && ok || bad "a loser another LIVE hold still names must stay parked (was '$B51' now '$(mc_row_get 'o/tproj#51')')"
mc_contested_release "$(hold_path tproj m/two.ts)" "winner merged"
[ "$(mc_row_get 'o/tproj#51' | cut -f2)" = NEEDS_REBASE ] \
  && ok || bad "and it is released by the LAST hold that named it (got '$(mc_row_get 'o/tproj#51' | cut -f2)')"
[ "$(mc_row_get 'o/tproj#51' | cut -f7)" = "contested released: winner merged" ] \
  && ok || bad "with the ordinary release reason (got '$(mc_row_get 'o/tproj#51' | cut -f7)')"

# ============================================================================
# 5. Ownership: the resolver owns a contested park, and it never pages by age
# ============================================================================
mc_resolver_owns "$WHY41" && ok || bad "mc_resolver_owns must own a contested reason as it is STORED, detail and all"
mc_handoff_owns "$WHY41" && bad "a contested park must NOT be a sticky hand-off — the sibling that parks losers relies on that" || ok
[ "$(mc_state_display BLOCKED_HUMAN "$WHY41")" = BLOCKED_AGENT ] \
  && ok || bad "a contested park displays as BLOCKED_AGENT (got '$(mc_state_display BLOCKED_HUMAN "$WHY41")')"
: > "$H/logs/ALERTS.log"
mc_stuck_check 'o/tproj#41' BLOCKED_HUMAN "$((NOW-10800))" deadbeef https://github.com/o/tproj/pull/41 "$WHY41" \
  && bad "mc_stuck_check must return 1 for a contested park — the hold's own TTL is its pager" || ok
[ "$(find "$H/state/merge-conductor/stuck" -type f | wc -l)" = 0 ] \
  && ok || bad "no stuck marker may be written for a contested park"
[ "$(grep -c STUCK "$H/logs/ALERTS.log")" = 0 ] \
  && ok || bad "no stuck alert for a contested park (got: $(cat "$H/logs/ALERTS.log"))"
# The word inside the DETAIL of another reason is not the prefix: this one still pages.
mc_stuck_check 'o/tproj#43' BLOCKED_HUMAN "$((NOW-10800))" deadbeef https://github.com/o/tproj/pull/43 'conflict-unresolvable: contested.ts' \
  && ok || bad "an ordinary park past its TTL must still be rc 0"
[ "$(grep -c STUCK "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "and it must page exactly once (got: $(cat "$H/logs/ALERTS.log"))"
grep -q 'BLOCKED_AGENT' "$H/logs/ALERTS.log" \
  && ok || bad "the ordinary park's alert is unchanged and still names BLOCKED_AGENT"

# ============================================================================
# 6. The sidecar, through mc_rebase itself
# ============================================================================
git clone -q "$ORIGIN" "$T/repos/tproj" 2>/dev/null
git config --global "url.$ORIGIN.insteadOf" "https://x-access-token@github.com/o/tproj.git"
git config --global "url.$ORIGIN.insteadOf" "https://github.com/o/tproj.git" --add
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"auth token"*) echo faketoken ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export MC_REPOS="$T/repos"
OUT=$(mc_rebase o/tproj tproj ticket/TK-41 "$HEAD41" https://github.com/o/tproj/pull/41); RC=$?
[ "$RC" = 1 ] && ok || bad "a conflicting rebase is still rc 1 (got $RC; log: $(tail -2 "$H/logs/merge-conductor.log"))"
[ "$OUT" = a.txt ] && ok || bad "stdout is still the conflict list (got '$OUT')"
SIDE="$H/state/merge-conductor/conflict-size/o_tproj_41"
[ -s "$SIDE" ] && ok || bad "mc_rebase must write the conflict-size sidecar at $SIDE"
[ "$(cat "$SIDE" 2>/dev/null)" = "$(printf '%s\t%s\ta.txt' "$EXPECT" "$HEAD41")" ] \
  && ok || bad "the sidecar is <lines>\\t<head>\\t<paths> with the size §1 measured (want '$(printf '%s\t%s\ta.txt' "$EXPECT" "$HEAD41")' got '$(cat "$SIDE" 2>/dev/null)')"
[ "$(find "$H/state/merge-conductor/conflict-size" -maxdepth 1 -name '.tmp*' | wc -l)" = 0 ] \
  && ok || bad "the sidecar write leaves no temp file behind"
[ "$(git -C "$T/repos/tproj" worktree list | wc -l)" = 1 ] \
  && ok || bad "mc_rebase must still clean up its worktree (got: $(git -C "$T/repos/tproj" worktree list))"

# ============================================================================
# 7. mc_pr_files reads the PR's files over REST (BH-587 review round 1)
#    br_competitors buys one file list per open PR, up to CONTESTED_PR_SCAN_MAX
#    (40) per hold creation. `gh pr view --json files` is GraphQL, and the
#    GraphQL bucket is the one that dies first on these accounts — so the hold
#    would stop being written exactly when the fleet is busiest.
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/fcalls.txt"
case "\$*" in
  *"auth token"*)            echo faketoken ;;
  # The paginated REST read wants a 200 whose body is the files ARRAY; the jq
  # that names the filenames is mc_pr_files's, not gh's -q template.
  *"pulls/77/files"*)        restpr --raw 200 '[{"filename":"src/rest.ts"},{"filename":"src/two.ts"}]' ;;
  *"--json files"*)          printf 'src/graphql.ts\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/fcalls.txt"
scratch_rm "$H/state/merge-conductor/pr-files"
[ "$(mc_pr_files o/tproj 77 https://github.com/o/tproj/pull/77 deadbeefdeadbeef | tr '\n' ' ')" = 'src/rest.ts src/two.ts ' ] \
  && ok || bad "mc_pr_files must answer the REST file list (got '$(mc_pr_files o/tproj 77 https://github.com/o/tproj/pull/77 deadbeefdeadbeef | tr '\n' ' ')')"
grep -q 'repos/o/tproj/pulls/77/files' "$T/fcalls.txt" \
  && ok || bad "and it must ASK over REST (calls: $(cat "$T/fcalls.txt"))"
grep -q -- '--json files' "$T/fcalls.txt" \
  && bad "a REST answer must cost NO GraphQL call (calls: $(cat "$T/fcalls.txt"))" || ok
: > "$T/fcalls.txt"
mc_pr_files o/tproj 77 https://github.com/o/tproj/pull/77 deadbeefdeadbeef >/dev/null
[ "$(wc -l < "$T/fcalls.txt")" = 0 ] \
  && ok || bad "the per-(PR, head) cache must still answer the second call with no API call at all (calls: $(cat "$T/fcalls.txt"))"
# AND THERE IS NO FALLBACK (BH-587 review round 1, finding 4). The old reader
# fired on any empty stdout, and stderr is discarded, so a REST OUTAGE — not an
# empty PR — bought up to CONTESTED_PR_SCAN_MAX (40) GraphQL reads per hold
# creation, out of the bucket this whole change exists to stop spending. An
# empty answer is rc 1, "cannot judge", which parks nobody; so does the GraphQL
# list it used to buy. Same decision, no spend.
: > "$T/fcalls.txt"
OUT78=$(mc_pr_files o/tproj 78 https://github.com/o/tproj/pull/78 deadbeefdeadbeef); RC78=$?
[ "$RC78" = 1 ] && [ -z "$OUT78" ] \
  && ok || bad "a REST read that answers nothing is rc 1 and nothing — never a GraphQL retry (rc $RC78, got '$OUT78')"
grep -q -- '--json files' "$T/fcalls.txt" \
  && bad "and it must buy NO GraphQL call on the way there — that is the bucket a REST outage would drain 40 reads at a time (calls: $(cat "$T/fcalls.txt"))" || ok
[ "$(mc_pr_files o/tproj 79 https://github.com/o/tproj/pull/79 -)" = "" ] \
  && ok || bad "an unknown head still reads nothing and costs nothing"

echo "contested-store-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
