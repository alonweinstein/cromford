#!/bin/bash
# tests/flaky-tier-release.bh-3686-test.sh — BH-3702 (BH-3686.4): ft_release
# (bin/lib/flaky-tier-release.sh) releases a quarantined suite after K clean
# scheduled nightly runs on main.
#
# The lib is sourced next to the REAL bin/lib/gh-rest.sh (with gh-rest-var.sh)
# and bin/lib/jobs/cost.sh, and only the transport underneath them is stubbed:
# gh_ci_api (the run and artifact listings), gh_rest (the issue read and the
# comment POST) and _jobs_req (the quarantine re-read and the PUT). The artifact
# download goes through the lib's own `gh api … > file` to a fake `gh` on PATH,
# which answers with zips built by `python3 -m zipfile -c`. Every assertion
# counts calls from the stub logs. Timestamps are fixed literals; nothing reads
# the clock and nothing sleeps.
#
# Run from anywhere: bash tests/flaky-tier-release.bh-3686-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FT_LIB="$DIR/bin/lib/flaky-tier-release.sh"
FX="$T/fx"
HARNESS="$T/h"
SLUG=example-org/x

# shellcheck source=/dev/null
. "$DIR/bin/lib/gh-rest.sh" || { echo "cannot source gh-rest.sh"; exit 1; }
# shellcheck source=/dev/null
. "$DIR/bin/lib/jobs/cost.sh" || { echo "cannot source jobs/cost.sh"; exit 1; }
# shellcheck source=/dev/null
. "$FT_LIB" || { echo "cannot source $FT_LIB"; exit 1; }
command -v gh_rest_issue_state_var >/dev/null 2>&1 || { echo "gh-rest-var.sh did not load"; exit 1; }

# --- recording stubs ---------------------------------------------------------
gh_ci_api() { # answers from $FX: runs.json / art-<id>.json, rc from *.rc
  local p="${2:-}" id f r=0
  printf '%s\n' "$p" >> "$T/ci.log"
  case "$p" in
    */actions/workflows/*) f="$FX/runs.json"; [ -f "$FX/runs.rc" ] && r=$(cat "$FX/runs.rc") ;;
    */actions/runs/*/artifacts*)
      id=${p#*/actions/runs/}; id=${id%%/*}
      f="$FX/art-$id.json"; [ -f "$FX/art-$id.rc" ] && r=$(cat "$FX/art-$id.rc") ;;
    *) return 1 ;;
  esac
  [ "$r" = 0 ] || return "$r"
  cat "$f"
}
gh_rest() { # GET issues/<n> answers $FX/issue-<n>.state; POST answers {}
  local m="${1:-}" p="${2:-}" n
  printf '%s %s\n' "$m" "$p" >> "$T/rest.log"
  GH_REST_STATUS=200; GH_REST_REASON=
  case "$m $p" in
    "GET repos/$SLUG/issues/"*) n=${p##*/}; printf '{"state":"%s"}\n' "$(cat "$FX/issue-$n.state")" ;;
    "POST repos/$SLUG/issues/"*/comments) cp "${4#body=@}" "$T/comment.txt"; echo '{}' ;;
    *) GH_REST_STATUS=500; return 75 ;;
  esac
}
_jobs_req() { # GET answers $FX/rows.json; PUT answers rc from $FX/put.rc
  printf '%s %s\n' "$1" "$2" >> "$T/req.log"
  [ -n "${3:-}" ] && printf '%s\n' "$3" >> "$T/req-body.log"
  case "$1" in
    GET) cat "$FX/rows.json" ;;
    PUT) [ -f "$FX/put.rc" ] && return "$(cat "$FX/put.rc")"; echo '{"ok":true}' ;;
  esac
}

# The fake gh: only the lib's zip download reaches it.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s tok=%s\n' "$*" "${GH_TOKEN:-}" >> "$FTR_T/gh.log"
case "$1 $2" in
  "api repos/"*/actions/artifacts/*/zip) ;;
  *) exit 1 ;;
esac
aid=${2%/zip}; aid=${aid##*/}
if [ -f "$FTR_FX/zip-$aid.rc" ]; then
  want=$(cat "$FTR_FX/zip-$aid.tok" 2>/dev/null)
  [ -n "$want" ] && [ "${GH_TOKEN:-}" = "$want" ] || exit "$(cat "$FTR_FX/zip-$aid.rc")"
fi
cat "$FTR_FX/zip-$aid.zip"
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FTR_T="$T" FTR_FX="$FX"
unset GH_TOKEN GITHUB_TOKEN FLAKY_TIER_DRY FLAKY_TIER_ACT FLAKY_TIER_RELEASE_CLEAN \
  FLAKY_TIER_NIGHTLY_RUNS FLAKY_TIER_RELEASE_ACTORS

# --- fixtures ----------------------------------------------------------------
fresh() { # fresh: empty fixtures, logs and cache
  scratch_rm "$FX"; scratch_rm "$HARNESS"; scratch_rm "$T/z"
  rm -f "$T"/*.log "$T/comment.txt"
  mkdir -p "$FX" "$HARNESS" "$T/z"
  : > "$FX/runs.list"
  echo open > "$FX/issue-77.state"
}
# row <test> <active> <actor> <updated_at> <reason> — the rows file and the
# matching worker re-read answer.
row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$@" > "$FX/rows.tsv"
  jq -nc --arg t "$1" --arg a "$2" --arg c "$3" --arg u "$4" --arg r "$5" \
    '{rows:[{test:$t,active:($a|tonumber),actor:$c,updated_at:$u,reason:$r}]}' > "$FX/rows.json"
}
std_row() { row tests/a-test.sh 1 flaky-tier 2026-09-20T00:00:00.000Z 'quarantined, fix #77'; }
# run <id> <created_at> <log text> [expired] — one listed run, its artifact list
# (the shard artifact plus nightly-verdict-strict) and the shard zip.
run() {
  local id="$1" at="$2" log="$3" exp="${4:-false}" aid=$(( $1 * 10 + 1 ))
  printf '%s\t%s\n' "$id" "$at" >> "$FX/runs.list"
  jq -nc --argjson a "$aid" --argjson s "$(( aid + 1 ))" --argjson e "$exp" \
    '{total_count:2,artifacts:[{id:$a,name:"nightly-verdict-1",expired:$e},{id:$s,name:"nightly-verdict-strict",expired:false}]}' \
    > "$FX/art-$id.json"
  mkdir -p "$T/z/$id"
  printf '%s\n' "$log" > "$T/z/$id/shard-1.log"
  printf 'PASS\n' > "$T/z/$id/shard-1.txt"
  ( cd "$T/z/$id" && python3 -m zipfile -c "$FX/zip-$aid.zip" shard-1.log shard-1.txt ) || echo "zip build failed for $id"
}
list() { # write runs.json from runs.list (listed OLDEST first on purpose: the lib sorts)
  jq -Rn '{total_count:0,workflow_runs:[inputs | split("\t") | {id:(.[0]|tonumber),created_at:.[1],head_sha:"abc\(.[0])"}] | reverse}' \
    < "$FX/runs.list" > "$FX/runs.json"
}
clean() { printf -- '--- tests/a-test.sh rc=0 3s\n--- tests/b-test.sh rc=0 1s'; }
five_clean() { # runs 101..105, 2026-09-21..25, all clean
  local i; for i in 1 2 3 4 5; do run "10$i" "2026-09-2${i}T03:00:00Z" "$(clean)"; done
}
go() { # go [env...] — call ft_release in a subshell, stdout to OUT, rc to RC
  OUT=$(env "$@" bash -c '. "$1"; . "$2"; . "$3"; '"$(declare -f gh_ci_api gh_rest _jobs_req)"'; ft_release "$4" "$5"' \
    _ "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/jobs/cost.sh" "$FT_LIB" "$SLUG" "$FX/rows.tsv" 2>"$T/err.txt"); RC=$?
}
cnt() { # cnt <file> <fixed string> — matching lines, 0 when the file is absent
  [ -f "$1" ] || { echo 0; return; }
  grep -cF -- "$2" "$1"
}
puts()  { cnt "$T/req.log" 'PUT /api/metrics/flakes/quarantine'; }
posts() { cnt "$T/rest.log" "POST repos/$SLUG/issues/77/comments"; }
export HARNESS SLUG T FX

# --- R1: five clean runs after the quarantine release it ---------------------
fresh; std_row; five_clean; list
go
BODY=$(sed -n 1p "$T/req-body.log" 2>/dev/null)
[ "$RC" = 0 ] && [ "$OUT" = tests/a-test.sh ] && ok || bad "R1: rc=$RC out='$OUT' err=$(cat "$T/err.txt")"
[ "$(puts)" = 1 ] && ok || bad "R1: puts=$(puts)"
[ "$(printf '%s' "$BODY" | jq -r '"\(.active) \(.actor) \(.test)"')" = "0 flaky-tier tests/a-test.sh" ] && ok || bad "R1 body: $BODY"
[ "$(printf '%s' "$BODY" | jq -r .reason)" = "auto-release (flaky-tier): 5 clean nightly runs 105,104,103,102,101" ] && ok || bad "R1 reason: $BODY"
[ "$(posts)" = 1 ] && [ "$(cnt "$T/rest.log" PATCH)" = 0 ] && ok || bad "R1: posts=$(posts) rest=$(cat "$T/rest.log" 2>/dev/null)"
grep -qF 'https://github.com/example-org/x/actions/runs/105' "$T/comment.txt" 2>/dev/null \
  && grep -qF 'tests/a-test.sh' "$T/comment.txt" && ! grep -q '—' "$T/comment.txt" && ok || bad "R1 comment: $(cat "$T/comment.txt" 2>/dev/null)"
[ "$(cnt "$T/gh.log" "$(( 1011 + 1 ))")" = 0 ] && ok || bad "N1: the strict artifact was downloaded"

# --- L2: the listing query ----------------------------------------------------
L=$(sed -n 1p "$T/ci.log")
case "$L" in
  "repos/$SLUG/actions/workflows/harness-nightly.yml/runs?"*) ok ;; *) bad "L2 path: $L" ;;
esac
for q in event=schedule branch=main status=completed per_page=10; do
  case "$L" in *"$q"*) ok ;; *) bad "L2: $q missing from $L" ;; esac
done

# --- C1: the per-run cache, and a warm second call spends nothing ------------
F="$HARNESS/state/flaky-tier/nightly/103.tsv"
[ "$(sed -n 1p "$F" 2>/dev/null)" = "# created_at=2026-09-23T03:00:00Z sha=abc103" ] && ok || bad "C1 header: $(cat "$F" 2>/dev/null)"
grep -qxF "$(printf 'tests/a-test.sh\t0')" "$F" 2>/dev/null && ok || bad "C1 row: $(cat "$F" 2>/dev/null)"
rm -f "$T/ci.log" "$T/gh.log"
go FLAKY_TIER_DRY=1
[ "$(cnt "$T/ci.log" /artifacts)" = 0 ] && [ "$(cnt "$T/gh.log" /zip)" = 0 ] && [ "$(cnt "$T/ci.log" /workflows/)" = 1 ] \
  && ok || bad "C1: warm call re-fetched: $(cat "$T/ci.log" "$T/gh.log" 2>/dev/null)"

# --- R2a: a red newest run ends the streak -----------------------------------
fresh; std_row
for i in 1 2 3 4; do run "10$i" "2026-09-2${i}T03:00:00Z" "$(clean)"; done
run 105 2026-09-25T03:00:00Z '--- tests/a-test.sh rc=1 3s'; list
go
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "R2a: rc=$RC out='$OUT' puts=$(puts)"
# ... even when five clean runs sit behind it: a red is never skipped.
fresh; std_row; five_clean
run 106 2026-09-26T03:00:00Z '--- tests/a-test.sh rc=1 3s'; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "R2a 5 clean behind a red: out='$OUT'"

# --- R2a': a red run inside the window, even with 5 clean ones after it ------
fresh; std_row
run 100 2026-09-21T01:00:00Z '--- tests/a-test.sh rc=1 3s'
for i in 1 2 3 4; do run "10$i" "2026-09-2${i}T03:00:00Z" "$(clean)"; done; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "R2a': 4 clean after a red released: out='$OUT'"

# --- R2b: a run with no line for the suite is skipped, not counted ----------
fresh; std_row
for i in 1 2 3; do run "10$i" "2026-09-2${i}T03:00:00Z" "$(clean)"; done
run 104 2026-09-24T03:00:00Z '--- tests/b-test.sh rc=0 1s'
run 105 2026-09-25T03:00:00Z "$(clean)"
run 106 2026-09-26T03:00:00Z "$(clean)"; list
go
R=$(sed -n 1p "$T/req-body.log" 2>/dev/null | jq -r .reason 2>/dev/null)
[ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 1 ] && [ "$R" = "auto-release (flaky-tier): 5 clean nightly runs 106,105,103,102,101" ] \
  && ok || bad "R2b: out='$OUT' reason='$R'"

# --- R3a: a clean run from before updated_at never counts --------------------
fresh; std_row
run 100 2026-09-19T03:00:00Z "$(clean)"
for i in 1 2 3 4; do run "10$i" "2026-09-2${i}T03:00:00Z" "$(clean)"; done; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "R3a: out='$OUT' puts=$(puts)"
[ "$(cnt "$T/ci.log" runs/100/artifacts)" = 0 ] && ok || bad "R3a: a run older than every row was fetched"
# A second row quarantined earlier makes run 100 cached: a-test still cannot
# count it, b-test (clean in all five) is released alone.
printf '%s\t1\tflaky-tier\t2026-09-18T00:00:00.000Z\tfix #78\n' tests/b-test.sh >> "$FX/rows.tsv"
jq -c '.rows += [{test:"tests/b-test.sh",active:1,actor:"flaky-tier",updated_at:"2026-09-18T00:00:00.000Z",reason:"fix #78"}]' \
  "$FX/rows.json" > "$FX/rows.j2" && mv "$FX/rows.j2" "$FX/rows.json"
echo open > "$FX/issue-78.state"
go
[ "$OUT" = tests/b-test.sh ] && [ "$(puts)" = 1 ] && [ -e "$HARNESS/state/flaky-tier/nightly/100.tsv" ] \
  && ok || bad "R3a two rows: out='$OUT' puts=$(puts)"

# --- R3b / C2: an expired artifact is cached unreadable, ends the streak -----
fresh; std_row; five_clean
run 106 2026-09-26T03:00:00Z "$(clean)" true; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "R3b: out='$OUT'"
[ "$(sed -n 1p "$HARNESS/state/flaky-tier/nightly/106.tsv" 2>/dev/null)" = "# unreadable created_at=2026-09-26T03:00:00Z" ] \
  && ok || bad "R3b cache: $(cat "$HARNESS/state/flaky-tier/nightly/106.tsv" 2>/dev/null)"
grep -qF 'nightly run 106 cached unreadable: artifact 1061 expired' "$T/err.txt" && ok || bad "R3b: no stderr line: $(cat "$T/err.txt")"
go
[ -z "$OUT" ] && [ "$(cnt "$T/ci.log" runs/106/artifacts)" = 1 ] && [ "$(cnt "$T/gh.log" 1061/zip)" = 0 ] \
  && ok || bad "R3b: unreadable run re-fetched: $(cat "$T/ci.log")"

# --- C3 / U1: an artifact-list rc 75 caches nothing and blocks the release ---
fresh; std_row; five_clean
run 106 2026-09-26T03:00:00Z "$(clean)"; list
echo 75 > "$FX/art-106.rc"
go
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "U1: released across an unknown run: out='$OUT'"
[ ! -e "$HARNESS/state/flaky-tier/nightly/106.tsv" ] && ok || bad "C3: an rc-75 run was cached"
rm -f "$FX/art-106.rc"
go
[ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 1 ] && [ "$(cnt "$T/ci.log" runs/106/artifacts)" = 2 ] \
  && ok || bad "U1: second call did not fetch and release: out='$OUT' puts=$(puts)"

# U1c: gh api exits 1 (not 75) on a secondary rate limit, a 5xx or a network
# error. That is unknown too: nothing cached, the fetch loop stops there (older
# runs are not spent on or poisoned), one stderr line, and the next tick releases.
fresh; std_row; five_clean
run 106 2026-09-26T03:00:00Z "$(clean)"; list
echo 1 > "$FX/art-106.rc"
go
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "U1c: released across a failed listing: out='$OUT'"
[ -z "$(ls -A "$HARNESS/state/flaky-tier/nightly" 2>/dev/null)" ] && [ "$(cnt "$T/ci.log" runs/105/artifacts)" = 0 ] \
  && ok || bad "U1c: cached or fetched past a failed listing: $(ls -A "$HARNESS/state/flaky-tier/nightly" 2>/dev/null) ci=$(cat "$T/ci.log")"
[ "$(grep -c 'ft_release' "$T/err.txt")" = 1 ] && grep -qF 'nightly run 106 artifact listing failed (rc 1), unknown this tick' "$T/err.txt" \
  && ok || bad "U1c stderr: $(cat "$T/err.txt")"
rm -f "$FX/art-106.rc"
go
[ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 1 ] && [ "$(cnt "$T/ci.log" runs/106/artifacts)" = 2 ] \
  && ok || bad "U1c: next tick did not fetch and release: out='$OUT' puts=$(puts)"

# U1b: older runs already cached from an earlier tick; an unknown newest run
# still stops the walk instead of being stepped over.
fresh; std_row; five_clean; list
go FLAKY_TIER_DRY=1
run 106 2026-09-26T03:00:00Z "$(clean)"; list; echo 75 > "$FX/art-106.rc"
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ -e "$HARNESS/state/flaky-tier/nightly/105.tsv" ] && ok || bad "U1b: stepped over an unknown run: out='$OUT'"

# --- a failed zip download (rc 75 or gh api's rc 1) is unknown, never cached --
fresh; std_row; five_clean; list
echo 75 > "$FX/zip-1051.rc"
go
[ -z "$OUT" ] && [ ! -e "$HARNESS/state/flaky-tier/nightly/105.tsv" ] && ok || bad "Z75: out='$OUT'"
echo 1 > "$FX/zip-1051.rc"
go
[ -z "$OUT" ] && [ -z "$(ls -A "$HARNESS/state/flaky-tier/nightly" 2>/dev/null)" ] && [ "$(cnt "$T/ci.log" runs/104/artifacts)" = 0 ] \
  && ok || bad "Z1: a failed download was cached or the loop went on: $(ls -A "$HARNESS/state/flaky-tier/nightly" 2>/dev/null)"
grep -qF 'nightly run 105 artifact 1051 download failed (rc 1), unknown this tick' "$T/err.txt" && ok || bad "Z1 stderr: $(cat "$T/err.txt")"
rm -f "$FX/zip-1051.rc"
go
[ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 1 ] && ok || bad "Z1: next tick did not fetch and release: out='$OUT'"

# --- Z2: a refused download is retried once on gh-token.sh's token -----------
fresh; std_row; five_clean; list
mkdir -p "$HARNESS/bin"
printf '#!/bin/bash\necho app-tok\n' > "$HARNESS/bin/gh-token.sh"; chmod +x "$HARNESS/bin/gh-token.sh"
echo 1 > "$FX/zip-1051.rc"; echo app-tok > "$FX/zip-1051.tok"
go
[ "$OUT" = tests/a-test.sh ] && [ "$(cnt "$T/gh.log" '1051/zip tok=app-tok')" = 1 ] && ok || bad "Z2: out='$OUT' gh=$(cat "$T/gh.log")"

# --- C4: a zip that does not extract is unreadable ---------------------------
fresh; std_row; five_clean; list
echo 'not a zip' > "$FX/zip-1051.zip"
go
[ -z "$OUT" ] && [ "$(sed -n 1p "$HARNESS/state/flaky-tier/nightly/105.tsv")" = "# unreadable created_at=2026-09-25T03:00:00Z" ] \
  && ok || bad "C4: $(cat "$HARNESS/state/flaky-tier/nightly/105.tsv" 2>/dev/null)"

# --- C6: a listing with no nightly-verdict artifact, or a body that does not
# parse, is a terminal answer: cached unreadable, with a stderr line ---------
fresh; std_row; five_clean; list
echo '{"total_count":1,"artifacts":[{"id":9,"name":"nightly-verdict-strict","expired":false}]}' > "$FX/art-105.json"
go
[ -z "$OUT" ] && [ "$(sed -n 1p "$HARNESS/state/flaky-tier/nightly/105.tsv")" = "# unreadable created_at=2026-09-25T03:00:00Z" ] \
  && grep -qF 'nightly run 105 cached unreadable: no nightly-verdict artifact' "$T/err.txt" && ok || bad "C6 none: $(cat "$T/err.txt")"
fresh; std_row; five_clean; list
echo 'not json' > "$FX/art-105.json"
go
[ -z "$OUT" ] && [ "$(sed -n 1p "$HARNESS/state/flaky-tier/nightly/105.tsv")" = "# unreadable created_at=2026-09-25T03:00:00Z" ] \
  && grep -qF 'nightly run 105 cached unreadable: artifact listing unparseable' "$T/err.txt" && ok || bad "C6 body: $(cat "$T/err.txt")"

# --- C5: the prune drops an old unlisted run and keeps the listed ones ------
fresh; std_row; five_clean; list
C="$HARNESS/state/flaky-tier/nightly"; mkdir -p "$C"
echo '# created_at=2026-09-01T03:00:00Z sha=old' > "$C/90.tsv"
echo '# created_at=2026-09-30T03:00:00Z sha=new' > "$C/999.tsv"
go FLAKY_TIER_DRY=1
[ ! -e "$C/90.tsv" ] && [ -e "$C/999.tsv" ] && [ -e "$C/101.tsv" ] && [ -e "$C/105.tsv" ] && ok || bad "C5: $(ls "$C")"

# --- L1: an unknown listing releases nothing and caches nothing -------------
fresh; std_row; five_clean; list
echo 1 > "$FX/runs.rc"
go
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ -z "$(ls -A "$HARNESS/state/flaky-tier/nightly" 2>/dev/null)" ] \
  && [ "$(cnt "$T/ci.log" /artifacts)" = 0 ] && ok || bad "L1: out='$OUT'"
rm -f "$FX/runs.rc"; echo '{"message":"x"}' > "$FX/runs.json"
go
[ -z "$OUT" ] && [ "$(cnt "$T/ci.log" /artifacts)" = 0 ] && ok || bad "L1 no array: out='$OUT'"

# --- R4 / N2: operator rows and inactive rows are never released -------------
for a in operator console; do
  fresh; row tests/a-test.sh 1 "$a" 2026-09-20T00:00:00.000Z 'quarantined, fix #77'; five_clean; list
  go
  [ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "R4 actor=$a: out='$OUT'"
done
fresh; row tests/a-test.sh 0 flaky-tier 2026-09-20T00:00:00.000Z 'fix #77'; five_clean; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "N2 inactive: out='$OUT'"
fresh; row tests/a-test.sh 1 flaky-tier - 'fix #77'; five_clean; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ ! -e "$T/ci.log" ] && ok || bad "N3 updated_at '-': out='$OUT'"
fresh; row 'job:nightly' 1 flaky-tier 2026-09-20T00:00:00.000Z 'fix #77'; five_clean; list
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "N4 job row: out='$OUT'"
fresh; std_row; five_clean; list
go FLAKY_TIER_RELEASE_ACTORS='main-red-bisect other'
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "N5 actor list honoured: out='$OUT'"

# --- R5: dry mode decides and prints, never writes ---------------------------
for e in FLAKY_TIER_DRY=1 FLAKY_TIER_ACT=0; do
  fresh; std_row; five_clean; list
  go "$e"
  [ "$RC" = 0 ] && [ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] \
    && grep -q 'dry, would release tests/a-test.sh after 5 clean nightly runs' "$T/err.txt" && ok || bad "R5 $e: out='$OUT' puts=$(puts)"
done

# --- W1: a closed fix ticket gets no comment; the release stands ------------
fresh; std_row; five_clean; list; echo closed > "$FX/issue-77.state"
go
[ "$OUT" = tests/a-test.sh ] && [ "$(puts)" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "W1: out='$OUT' posts=$(posts)"
fresh; row tests/a-test.sh 1 flaky-tier 2026-09-20T00:00:00.000Z 'quarantined'; five_clean; list
go
[ "$OUT" = tests/a-test.sh ] && [ ! -e "$T/rest.log" ] && ok || bad "W1b no fix #: rest=$(cat "$T/rest.log" 2>/dev/null)"

# --- W2: a failed PUT prints nothing and comments nothing --------------------
fresh; std_row; five_clean; list; echo 1 > "$FX/put.rc"
go
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "W2: out='$OUT' posts=$(posts)"

# --- W3: a row that changed since the rows file was read is left alone ------
fresh; std_row; five_clean; list
jq -nc '{rows:[{test:"tests/a-test.sh",active:1,actor:"operator",updated_at:"2026-09-26T00:00:00.000Z",reason:"x"}]}' > "$FX/rows.json"
go
[ -z "$OUT" ] && [ "$(puts)" = 0 ] && ok || bad "W3: out='$OUT' puts=$(puts)"

# --- G1: no root, nothing called ---------------------------------------------
fresh; std_row; five_clean; list
go HARNESS= H=
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$T/ci.log" ] && [ ! -e "$HARNESS/state" ] && ok || bad "G1: out='$OUT'"

# --- G2: a missing helper releases nothing; the lib sources nothing ----------
fresh; std_row; five_clean; list
OUT=$(bash -c '. "$1"; '"$(declare -f gh_ci_api gh_rest _jobs_req)"'; . "$2"; ft_release "$3" "$4"' \
  _ "$DIR/bin/lib/gh-rest.sh" "$FT_LIB" "$SLUG" "$FX/rows.tsv" 2>"$T/err.txt"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$T/ci.log" ] && grep -q metric_flake_quarantine_put "$T/err.txt" && ok || bad "G2: out='$OUT' err=$(cat "$T/err.txt")"
[ "$(grep -cE '^[[:space:]]*(\.|source)[[:space:]]' "$FT_LIB")" = 0 ] && ok || bad "G2: the lib sources a file"

# --- G3: bad knobs release nothing -------------------------------------------
for e in FLAKY_TIER_RELEASE_CLEAN=0 FLAKY_TIER_RELEASE_CLEAN=abc FLAKY_TIER_NIGHTLY_RUNS=101 \
         FLAKY_TIER_RELEASE_CLEAN=11; do
  fresh; std_row; five_clean; list
  go "$e"
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(puts)" = 0 ] && [ ! -e "$T/ci.log" ] && ok || bad "G3 $e: out='$OUT'"
done
fresh; std_row; five_clean; list
go FLAKY_TIER_RELEASE_CLEAN=3
[ "$OUT" = tests/a-test.sh ] && [ "$(sed -n 1p "$T/req-body.log" | jq -r .reason)" = "auto-release (flaky-tier): 3 clean nightly runs 105,104,103" ] \
  && ok || bad "G3 K=3: out='$OUT'"

echo "flaky-tier-release: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
