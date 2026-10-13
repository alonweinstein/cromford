#!/bin/bash
# tests/fc-issues.bh-982-test.sh — bin/lib/fc-issues.sh, the GitHub-Issues lane
# module of the child filer, and bin/run-decompose.sh calling it.
#
# WHY THIS SUITE IS A DIFF AND NOT A SET OF OPINIONS. BH-982 moves the filing
# loop out of bin/run-decompose.sh and behind file_children. Four other scripts
# parse the lines that loop writes — bin/unblocked-children.sh launches a child
# off `Blocked-by: #<n>`, bin/lib/dep-verify-lib.sh reads the `(hard)` suffix,
# bin/decompose-parent-close.sh counts `Part of #N` / `Order: n of N`, and
# bin/size-gate.sh reads the size budget line — so a move that changes one byte
# of a child body is a move that strands or collides a child, quietly, days
# later. tests/fixtures/fc-issues/* were generated from the script as it stood
# BEFORE the move and committed first; every decompose assertion here is `cmp`
# against those bytes, not a regex somebody wrote next to the code.
#
# The rollout kind has no pre-change output to diff, so it is asserted on the
# artifacts instead (the child bodies, decompose-gh.log, children.txt,
# pipeline.log and the parent comment), and wave 3's real body is handed to the
# REAL bin/unblocked-children.sh rather than to a regex.
#
# No network, no model call, no secrets, nothing written outside $T.
#   tests/fc-issues.bh-982-test.sh      (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
LIB="$DIR/bin/lib/file-children.sh"
MOD="$DIR/bin/lib/fc-issues.sh"
FIX="$DIR/tests/fixtures/fc-issues"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"
[ -r "$MOD" ] && ok || bad "bin/lib/fc-issues.sh is missing"

# ---------------------------------------------------------------- scratch tree
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" ledger-os scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# Both lanes in one registry: "-" is the GitHub-Issues lane, and ledger-os is an
# in-app board whose prefix is NOT /api/board — which is the whole point of B1.
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -                              9 box-1 10.0.0.9
ledger-os  example-org/ledger-os  https://ledger.example    /api/accounting/requests-board 3 box-1 10.0.0.3
CONF
export FLEET_CONF="$T/h/fleet.conf"
# The library resolves these beside itself first and falls back to $HARNESS, so
# the direct-library drives below see exactly what the script's drives see.
for L in hotfix-lib.sh env-path.sh gh-repo-token.sh; do
  [ -r "$DIR/bin/lib/$L" ] && cp "$DIR/bin/lib/$L" "$T/h/bin/lib/"
done
cp "$LIB" "$MOD" "$T/h/bin/lib/"
# agent-call must never be reached on an issues drive: every one hands in a spec.
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
# The board lane expects the model to file the children and write their keys.
case "${2:-}" in ledger-os) printf 'LG-78\n' > "$(dirname "$5")/children.txt" ;; esac
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"
: > "$T/agent.log"

# drive_script <build> <project> <parent> <key> [env ...] — the PRODUCTION entry
# point: the real bin/run-decompose.sh, dry run, spec already in the build dir.
drive_script() {
  local b="$1" p="$2" par="$3" k="$4"; shift 4
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
      DECOMPOSE_DRY_RUN=1 "$@" "$DEC" "$p" "$par" "$k" "$b" 300 12 2>&1
}
# drive_lib <build> <kind> <project> <parent> <key> [env ...] — the library on
# its own, through file_children, which is the seam the rollout lane will use.
drive_lib() {
  local b="$1" kind="$2" p="$3" par="$4" k="$5"; shift 5
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" MAXL=300 MAXF=12 "$@" \
      bash -c 'set -u; . "$1"; file_children "$2" "$3" "$4" "$5" "$5/children.json" --kind "$6"' \
      _ "$LIB" "$p" "$par" "$k" "$b" "$kind" 2>&1
}
seed() { # seed <build> <spec-file>
  scratch_rm "$1"; mkdir -p "$1"
  cp "$2" "$1/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$1/size-gate.txt"
}
cmpf() { # cmpf <got> <want> <what>
  if cmp -s "$1" "$2"; then ok
  else bad "$3 drifted from the pre-move bytes:
$(diff -u "$2" "$1" 2>&1 | head -30)"; fi
}

# ===========================================================================
# D1 — byte-compare against the pre-move script, through BOTH entry points
# ===========================================================================
for SET in two-plain two-after five-plain five-after; do
  [ -s "$FIX/$SET/children.json" ] || { bad "fixture set $SET is missing"; continue; }
  # (a) the production entry point: bin/run-decompose.sh
  seed "$T/b" "$FIX/$SET/children.json"
  OUT=$(drive_script "$T/b" scoutish 552 TK-552); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "$SET: the dry-run drive must exit 0 (rc=$RC): $OUT"
  for F in "$FIX/$SET"/child-*.md; do
    cmpf "$T/b/children/$(basename "$F")" "$F" "$SET/$(basename "$F") (via run-decompose.sh)"
  done
  cmpf "$T/b/decompose-comment.md" "$FIX/$SET/decompose-comment.md" "$SET parent comment"
  sed "s#$T/b#<BUILD>#g" "$T/b/decompose-gh.log" > "$T/gh.got"
  cmpf "$T/gh.got" "$FIX/$SET/gh.log" "$SET decompose-gh.log"
  # (b) the library alone, with no script above it, on the same spec
  seed "$T/b2" "$FIX/$SET/children.json"
  OUT=$(drive_lib "$T/b2" decompose scoutish 552 TK-552 DECOMPOSE_DRY_RUN=1); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "$SET: the direct file_children drive must return 0 (rc=$RC): $OUT"
  for F in "$FIX/$SET"/child-*.md; do
    cmpf "$T/b2/children/$(basename "$F")" "$F" "$SET/$(basename "$F") (via file_children)"
  done
  cmpf "$T/b2/decompose-comment.md" "$FIX/$SET/decompose-comment.md" "$SET parent comment (via file_children)"
  sed "s#$T/b2#<BUILD>#g" "$T/b2/decompose-gh.log" > "$T/gh.got2"
  cmpf "$T/gh.got2" "$FIX/$SET/gh.log" "$SET decompose-gh.log (via file_children)"
  [ "$(paste -sd, "$T/b/children.txt")" = "$(paste -sd, "$T/b2/children.txt")" ] \
    && ok || bad "$SET: children.txt differs between the script and the library"
done
# two-after is two-plain with `after: [1]` on the sibling. Position 1 is the
# contract, which blocks everyone anyway, so the bodies must be IDENTICAL.
cmp -s "$FIX/two-plain/child-2.md" "$FIX/two-after/child-2.md" \
  && ok || bad "an 'after: [1]' must not change a sibling's body — position 1 is the contract"
# The `, ` separator between two blockers on one line, which is what
# bin/unblocked-children.sh splits on.
grep -q '^Blocked-by: #553 (hard), #555 (hard)$' "$FIX/five-after/child-4.md" \
  && ok || bad "five-after child 4 must carry two blockers on one line: $(grep '^Blocked-by' "$FIX/five-after/child-4.md")"

# ===========================================================================
# D3 — what the run says about itself, in fc_log's format
# ===========================================================================
seed "$T/b" "$FIX/two-plain/children.json"
drive_script "$T/b" scoutish 552 TK-552 >/dev/null 2>&1
grep -qE '^[0-9-]+ [0-9:]+Z \[scoutish/TK-552\] child 1 labels: ai-build \(' "$T/b/pipeline.log" \
  && ok || bad "the label decision must be logged per child: $(cat "$T/b/pipeline.log")"
grep -qE '^[0-9-]+ [0-9:]+Z \[scoutish/TK-552\] decomposed into: TK-553,TK-554 \(DRY RUN' "$T/b/pipeline.log" \
  && ok || bad "the closing line must name the children it filed: $(cat "$T/b/pipeline.log")"

# ===========================================================================
# D5 — a SOURCED library: no exit, no set -e, inert at source time
# ===========================================================================
bash -n "$MOD" && ok || bad "bin/lib/fc-issues.sh does not parse"
bash -n "$DEC" && ok || bad "bin/run-decompose.sh does not parse"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$MOD" && ok || bad "shellcheck -S error on bin/lib/fc-issues.sh"
  shellcheck -S error "$DEC" && ok || bad "shellcheck -S error on bin/run-decompose.sh"
else
  echo "note: shellcheck absent — the D5 lint assertions did not run"
fi
# A sourced `exit` kills the lane that sourced it; `set -e` kills it on the
# first grep that answers no.
grep -nE '^[[:space:]]*(set -e|exit)([[:space:]]|$)' "$MOD" \
  && bad "a sourced library may never exit or set -e" || ok
# Sourcing it changes nothing and says nothing, under the caller's set -u.
: > "$T/src.log"
SRCOUT=$( cd "$T" && env -u HARNESS bash -c 'set -u; . "$1"; . "$2"; echo READY' _ "$LIB" "$MOD" 2>&1 )
[ "$SRCOUT" = READY ] && ok || bad "sourcing must print nothing: [$SRCOUT]"
declare -F fc_file_issues >/dev/null 2>&1 && bad "the suite's own shell must not have been polluted" || ok

# ===========================================================================
# D6 — the loop really left the script (structural, paired with D1's behaviour)
# ===========================================================================
grep -q 'gh issue create -R' "$DEC" \
  && bad "the filing loop must not still be inline in bin/run-decompose.sh" || ok
[ "$(grep -c 'file_children "' "$DEC")" -eq 1 ] \
  && ok || bad "the script must call file_children exactly once (got $(grep -c 'file_children "' "$DEC"))"
grep -q 'fc_board_base' "$DEC" \
  && ok || bad "the board tail must resolve its base through fc_board_base"
# Scoped to the parking tail this ticket owns (from the `# <<< board child
# keys` marker to EOF), not the whole file: a sibling feature landed on main
# after this ticket was built and added its own /api/board re-map path inside
# the board-child-key block above the marker — out of this ticket's scope, and
# not what this assertion is for.
grep -q '/api/board' <<<"$(sed -n '/# <<< board child keys/,$p' "$DEC")" \
  && bad "the hardcoded /api/board must be gone from the board-lane parking tail" || ok
[ "$(grep -c '^[[:space:]]*fc_child_footer ' "$MOD")" -eq 1 ] \
  && ok || bad "the body footer must be composed by the contract's function, once"
grep -nE '(^|[^_A-Za-z0-9])(SQ|LOG) ["$'"'"']' "$MOD" \
  && bad "the library must call fc_sq/fc_log, not the script's SQ/LOG" || ok

# ===========================================================================
# R1 — rollout: three waves, ordered, no contract anywhere
# ===========================================================================
ROLLOUT='[
 {"title":"schema","after":[],"body":"w1"},
 {"title":"backfill","after":[],"body":"w2"},
 {"title":"cutover","after":["1: schema","2"],"body":"w3"}
]'
rm -rf "$T/r"; mkdir -p "$T/r"; printf '%s\n' "$ROLLOUT" > "$T/r/children.json"
OUT=$(drive_lib "$T/r" rollout scoutish 900 AB-900 FILE_CHILDREN_DRY_RUN=1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a rollout drive must return 0 (rc=$RC): $OUT"
[ "$(grep -c '^gh issue create ' "$T/r/decompose-gh.log")" -eq 3 ] \
  && ok || bad "three waves = three create commands: $(cat "$T/r/decompose-gh.log")"
for W in 1:schema 2:backfill 3:cutover; do
  grep -qF -- "--title 'AB-900.${W%%:*}: ${W#*:}'" "$T/r/decompose-gh.log" \
    && ok || bad "wave ${W%%:*} must be titled 'AB-900.${W%%:*}: ${W#*:}': $(cat "$T/r/decompose-gh.log")"
done
grep -q '\.0:' "$T/r/decompose-gh.log" \
  && bad "a rollout has no .0 child: $(cat "$T/r/decompose-gh.log")" || ok
W1="$T/r/children/child-1.md"; W2="$T/r/children/child-2.md"; W3="$T/r/children/child-3.md"
for F in "$W1" "$W2" "$W3"; do [ -s "$F" ] || bad "missing wave body $F"; done
ok
grep -qi 'blocked-by' "$W1" && bad "wave 1 waits on nobody: $(cat "$W1")" || ok
grep -qi 'blocked-by' "$W2" && bad "wave 2 named no after, so it has no blocker line: $(cat "$W2")" || ok
{ [ "$(grep -c '^Blocked-by' "$W3")" -eq 1 ] && grep -q '^Blocked-by: #901 (hard), #902 (hard)$' "$W3"; } \
  && ok || bad "wave 3 is blocked by the two waves its author named, in order: $(cat "$W3")"
for F in "$W1" "$W2" "$W3"; do
  grep -qE '^(CONTRACT|DEPENDS):' "$F" && bad "a wave carries no contract or dependency lines: $(cat "$F")" || ok
  grep -q 'Size budget' "$F" && bad "a wave carries no size budget: $(cat "$F")" || ok
  grep -q 'contract —' "$F" && bad "a wave is never a contract child: $(cat "$F")" || ok
  grep -q '^Part of #900$' "$F" && ok || bad "every wave says which parent it is part of: $(cat "$F")"
done
for N in 1 2 3; do
  grep -q "^Order: $N of 3$" "$T/r/children/child-$N.md" \
    && ok || bad "wave $N must carry 'Order: $N of 3'"
  grep -q "^Rollout wave $N of 3: " "$T/r/children/child-$N.md" \
    && ok || bad "wave $N must say it is a wave, so the PLAN stage never re-splits it"
done
[ "$(paste -sd, "$T/r/children.txt")" = "AB-901,AB-902,AB-903" ] \
  && ok || bad "children.txt must list the wave keys in landing order (got: $(paste -sd, "$T/r/children.txt"))"
tail -1 "$T/r/decompose-gh.log" | grep -q '^gh api -X DELETE repos/example-org/scoutish/issues/900/labels/ai-build$' \
  && ok || bad "the master must be parked by losing the label, last: $(tail -1 "$T/r/decompose-gh.log")"
# The parent comment a human reads.
RCM="$T/r/decompose-comment.md"
grep -q 'AB-900.1 (#901): schema' "$RCM" && grep -q 'AB-900.2 (#902): backfill' "$RCM" \
  && grep -q 'AB-900.3 (#903): cutover' "$RCM" \
  && ok || bad "the comment must link every wave with its title: $(cat "$RCM")"
grep -q 'builds when the one before it merges' "$RCM" \
  && ok || bad "the comment must say how the waves are sequenced: $(cat "$RCM")"
grep -q 'ai-build' "$RCM" \
  && ok || bad "the comment must say the master was unlabelled: $(cat "$RCM")"
grep -q '3 waves' "$RCM" && ok || bad "the comment must count the waves: $(cat "$RCM")"
[ "$(grep -c '—' "$RCM")" -eq 0 ] \
  && ok || bad "De-AI voice: no em dashes in a client-facing comment: $(cat "$RCM")"
grep -q 'lines of product code' "$RCM" \
  && bad "a rollout was not split for being oversized: $(cat "$RCM")" || ok

# ===========================================================================
# R2 — rollout `after` adversarially: 10 is not 1, self and forward are dropped
# ===========================================================================
ADV='[
 {"title":"one","after":[1],"body":"w1"},
 {"title":"two","after":["10","2","3","0","x: y","1"],"body":"w2"},
 {"title":"three","after":[],"body":"w3"}
]'
rm -rf "$T/r2"; mkdir -p "$T/r2"; printf '%s\n' "$ADV" > "$T/r2/children.json"
OUT=$(drive_lib "$T/r2" rollout scoutish 900 AB-900 FILE_CHILDREN_DRY_RUN=1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the adversarial rollout drive must return 0 (rc=$RC): $OUT"
{ [ "$(grep -c '^Blocked-by' "$T/r2/children/child-2.md")" -eq 1 ] \
  && grep -q '^Blocked-by: #901 (hard)$' "$T/r2/children/child-2.md"; } \
  && ok || bad "'10' must not match position 1, and self/forward/0 are dropped: $(cat "$T/r2/children/child-2.md")"
for P in 10 2 3 0; do
  grep -qF "dropped 'after: $P'" "$T/r2/pipeline.log" \
    && ok || bad "dropping '$P' must be said out loud: $(cat "$T/r2/pipeline.log")"
done
grep -qi 'blocked-by' "$T/r2/children/child-1.md" \
  && bad "wave 1's own 'after: [1]' is a self reference and must be dropped: $(cat "$T/r2/children/child-1.md")" || ok
grep -q "child 1: dropped 'after: 1'" "$T/r2/pipeline.log" \
  && ok || bad "wave 1's dropped self reference must be logged: $(cat "$T/r2/pipeline.log")"
# THE ANCHOR ON ITS OWN. Above, wave 2 also named a real position 1, so a
# matcher that read '10' as '1' would have produced the same line by luck. Here
# '10' is the ONLY entry: position 10 does not exist in a three-wave rollout, so
# the wave must come out with no blocker at all. A wrong blocker is not a
# cosmetic bug — it stands a wave behind an issue that will never close.
ADV2='[
 {"title":"one","after":[],"body":"w1"},
 {"title":"two","after":[],"body":"w2"},
 {"title":"three","after":["10"],"body":"w3"}
]'
rm -rf "$T/r2b"; mkdir -p "$T/r2b"; printf '%s\n' "$ADV2" > "$T/r2b/children.json"
OUT=$(drive_lib "$T/r2b" rollout scoutish 900 AB-900 FILE_CHILDREN_DRY_RUN=1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the anchor drive must return 0 (rc=$RC): $OUT"
grep -qi 'blocked-by' "$T/r2b/children/child-3.md" \
  && bad "'10' must not be read as position 1: $(cat "$T/r2b/children/child-3.md")" || ok
grep -qF "child 3: dropped 'after: 10'" "$T/r2b/pipeline.log" \
  && ok || bad "a position that does not exist must be dropped out loud: $(cat "$T/r2b/pipeline.log")"

# ===========================================================================
# R3 — the REAL launcher reads the REAL wave body
# ===========================================================================
# An assertion about a regex written next to the regex under test proves
# nothing. bin/unblocked-children.sh is what launches a child when its blocker
# closes, so wave 3's produced body goes through IT.
cat > "$T/fakebin/gh" <<'SH'
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
#!/bin/bash
cat "$ISSUES_JSON"
SH
chmod +x "$T/fakebin/gh"
W3BODY=$(jq -Rs . < "$W3")
unblocked_when() { # unblocked_when <state-of-902> <changed-issue>
  jq -nc --argjson b3 "$W3BODY" --arg s2 "$1" '[
    {"number":901,"state":"CLOSED","title":"AB-900.1: schema","body":"Part of #900"},
    {"number":902,"state":$s2,"title":"AB-900.2: backfill","body":"Part of #900"},
    {"number":903,"state":"OPEN","title":"AB-900.3: cutover","body":$b3}
  ]' > "$T/issues.json"
  mkdir -p "$T/h/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
  PATH="$T/fakebin:$PATH" ISSUES_JSON="$T/issues.json" HARNESS="$T/h" GH_ISSUES_REPO="example-org/scoutish" \
    "$DIR/bin/unblocked-children.sh" scoutish \
    <<<"board issues: CHANGED $2 \"AB-900\" (state: OPEN -> CLOSED)" 2>/dev/null
}
UNB=$(unblocked_when OPEN 901)
grep -q 'UNBLOCKED 903 ' <<<"$UNB" \
  && bad "902 is still open, so wave 3 must NOT launch (got: '$UNB')" || ok
UNB=$(unblocked_when CLOSED 902)
grep -q 'UNBLOCKED 903 ' <<<"$UNB" \
  && ok || bad "with both named waves closed the real launcher must release wave 3 (got: '$UNB')"

# ===========================================================================
# L1/L2 — the parent's labels are inherited on BOTH kinds, from one whitelist
# ===========================================================================
labels_of() { # labels_of <build> — the flags on the first create line
  sed -n '1s/.*--label/--label/p; 1s/ --body-file.*//p' "$1/decompose-gh.log" | head -1
}
# decompose, through the script
seed "$T/b" "$FIX/two-plain/children.json"
printf '{"labels":[{"name":"ai-build"},{"name":"hotfix"}]}\n' > "$T/b/ticket-meta.json"
drive_script "$T/b" scoutish 552 TK-552 >/dev/null 2>&1
[ "$(grep -c -- '--label ai-build --label hotfix ' "$T/b/decompose-gh.log")" -eq 2 ] \
  && ok || bad "both children must inherit hotfix: $(cat "$T/b/decompose-gh.log")"
grep -q 'inherited from parent #552: hotfix' "$T/b/pipeline.log" \
  && ok || bad "the inheritance must be logged: $(cat "$T/b/pipeline.log")"
# rollout, through the library — same whitelist, same flags
rm -rf "$T/r3"; mkdir -p "$T/r3"; printf '%s\n' "$ROLLOUT" > "$T/r3/children.json"
printf '{"labels":[{"name":"ai-build"},{"name":"hotfix"}]}\n' > "$T/r3/ticket-meta.json"
drive_lib "$T/r3" rollout scoutish 900 AB-900 FILE_CHILDREN_DRY_RUN=1 >/dev/null 2>&1
[ "$(grep -c -- '--label ai-build --label hotfix ' "$T/r3/decompose-gh.log")" -eq 3 ] \
  && ok || bad "every wave must inherit hotfix too: $(cat "$T/r3/decompose-gh.log")"
# `not-hotfix` is somebody saying this is NOT urgent, and `bug` is the KIND
# signal bin/kind-gate.sh reads: neither is in the vocabulary.
seed "$T/b" "$FIX/two-plain/children.json"
printf '{"labels":[{"name":"not-hotfix"},{"name":"bug"}]}\n' > "$T/b/ticket-meta.json"
drive_script "$T/b" scoutish 552 TK-552 >/dev/null 2>&1
[ "$(grep -c -- "--label ai-build --body-file" "$T/b/decompose-gh.log")" -eq 2 ] \
  && ok || bad "not-hotfix and bug must NOT be copied: $(cat "$T/b/decompose-gh.log")"
grep -q 'nothing inherited from parent #552' "$T/b/pipeline.log" \
  && ok || bad "a read that inherited nothing must say so: $(cat "$T/b/pipeline.log")"

# ===========================================================================
# E1/E2 — a re-entered build files nothing, on either entry point
# ===========================================================================
# Dry-run mode: the guard fires before any gh call, and synthetic issue titles
# cannot be verified, so a non-empty children.txt still means "do nothing".
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "issue create") echo "https://github.com/example-org/scoutish/issues/999" ;;
  *) echo '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\necho tok_fixture\n' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"
seed "$T/b" "$FIX/two-plain/children.json"
printf 'TK-553\nTS-554\n' > "$T/b/children.txt"
: > "$T/gh.calls"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" GH_CALLS="$T/gh.calls" DECOMPOSE_DRY_RUN=1 \
         PATH="$T/fakebin:$PATH" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "an already-decomposed build must exit 0 (rc=$RC): $OUT"
grep -q 'issue create' "$T/gh.calls" \
  && bad "a re-entered build must not file a second set of issues: $(cat "$T/gh.calls")" || ok
[ "$(paste -sd, "$T/b/children.txt")" = "TK-553,TK-554" ] \
  && ok || bad "the existing children list must be left alone"
grep -q 'already decomposed into: TK-553,TK-554' "$T/b/pipeline.log" \
  && ok || bad "a resumed decompose must say it re-filed nothing: $(cat "$T/b/pipeline.log")"
# ...and the library's own guard, which is what the rollout lane's caller gets.
rm -rf "$T/r4"; mkdir -p "$T/r4"; printf '%s\n' "$ROLLOUT" > "$T/r4/children.json"
printf 'AB-901\nAB-902\nAB-903\n' > "$T/r4/children.txt"
: > "$T/gh.calls"
OUT=$(drive_lib "$T/r4" rollout scoutish 900 AB-900 GH_CALLS="$T/gh.calls" PATH="$T/fakebin:$PATH" FILE_CHILDREN_DRY_RUN=1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a re-entered rollout must return 0 (rc=$RC): $OUT"
[ -s "$T/gh.calls" ] \
  && bad "the library's own re-entrancy guard must fire before any gh call: $(cat "$T/gh.calls")" || ok
[ ! -e "$T/r4/children/child-1.md" ] \
  && ok || bad "nothing may be written after the guard fires"

# ===========================================================================
# F1 — a create that fails mid-loop: nonzero, truthful children.txt, no parking
# ===========================================================================
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "issue create")
    if [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]; then
      echo "https://github.com/example-org/scoutish/issues/701"
    else
      echo "gh: HTTP 401: Bad credentials"; exit 1
    fi ;;
  "issue view") echo '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
seed "$T/b" "$FIX/two-plain/children.json"
: > "$T/gh.calls"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" GH_CALLS="$T/gh.calls" \
         PATH="$T/fakebin:$PATH" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a failed create must not exit 0: $OUT"
[ "$(paste -sd, "$T/b/children.txt")" = "TK-701" ] \
  && ok || bad "children.txt must hold exactly the children that exist (got: $(paste -sd, "$T/b/children.txt"))"
grep -qE '^issue comment|/issues/552/comments' "$T/gh.calls" \
  && bad "the parent must not be commented on after a failed split: $(cat "$T/gh.calls")" || ok
grep -qE 'remove-label|labels/ai-build' "$T/gh.calls" \
  && bad "the master must keep its label when the split did not finish: $(cat "$T/gh.calls")" || ok
grep -q 'DECOMPOSE_FAILED: gh issue create failed on child 2 of 2' "$T/b/decompose-run.txt" \
  && ok || bad "the artifact the sweep SOP reads must name the child and the reason: $(cat "$T/b/decompose-run.txt" 2>/dev/null)"
grep -q 'decompose FAILED (issues lane)' "$T/b/pipeline.log" \
  && ok || bad "the failure must be in pipeline.log too: $(cat "$T/b/pipeline.log")"
grep -q '401' "$T/b/decompose-run.txt" \
  && ok || bad "the reason must carry what gh actually said: $(cat "$T/b/decompose-run.txt")"

# ===========================================================================
# B1 — the board tail parks the parent at the board's OWN base path
# ===========================================================================
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" > "$CURL_URL"
echo '{"status":"in_progress"}'
SH
chmod +x "$T/fakebin/curl"
cat > "$T/h/env/ledger-os.env" <<'ENVF'
LEDGER_API_BASE=https://ar.example
LEDGER_INTERNAL_API_TOKEN=tok_fixture_board
ENVF
# The model-filed board tail this pins lives behind the switch since BH-3965.
mkdir -p "$T/h/flags" && : > "$T/h/flags/decompose-board-filer-off"
rm -rf "$T/bd"; mkdir -p "$T/bd"
: > "$T/curl.url"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" CURL_URL="$T/curl.url" \
         PATH="$T/fakebin:$PATH" "$DEC" ledger-os 77 LG-77 "$T/bd" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the board lane must exit 0 when the model filed children (rc=$RC): $OUT"
[ "$(cat "$T/curl.url")" = 'https://ar.example/api/accounting/requests-board/tickets/77/move' ] \
  && ok || bad "the move must go to the board's own prefix, not /api/board (got: $(cat "$T/curl.url"))"
grep -q 'parent parked in_progress' "$T/bd/pipeline.log" \
  && ok || bad "the parking must be logged: $(cat "$T/bd/pipeline.log")"
grep -qF 'tok_fixture_board' "$T/bd/pipeline.log" \
  && bad "a token must never reach the log" || ok
# No base in the env file: nothing is curled, and the operator is told.
printf 'LEDGER_INTERNAL_API_TOKEN=tok_fixture_board\n' > "$T/h/env/ledger-os.env"
rm -rf "$T/bd2"; mkdir -p "$T/bd2"
: > "$T/curl.url"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" CURL_URL="$T/curl.url" \
         PATH="$T/fakebin:$PATH" "$DEC" ledger-os 77 LG-77 "$T/bd2" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a missing base must not fail the split (rc=$RC): $OUT"
[ -s "$T/curl.url" ] \
  && bad "with no API base nothing may be POSTed: $(cat "$T/curl.url")" || ok
grep -q 'WARN: could not park parent in_progress after split' "$T/bd2/pipeline.log" \
  && ok || bad "a parent that could not be parked is a WARN, not silence: $(cat "$T/bd2/pipeline.log")"

# ===========================================================================
# this suite is this ticket's own file (the repo's test-home rule)
# ===========================================================================
# shellcheck source=bin/lib/test-home-lib.sh
. "$DIR/bin/lib/test-home-lib.sh" 2>/dev/null
if command -v th_is_own >/dev/null 2>&1; then
  th_is_own tests/fc-issues.bh-982-test.sh BH-982 \
    && ok || bad "this suite must be recognised as BH-982's own test file"
else
  echo "note: bin/lib/test-home-lib.sh absent — the test-home assertion did not run"
fi

echo "fc-issues.bh-982: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
