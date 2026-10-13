#!/bin/bash
# tests/lead-checklist-conflict-eval.bh-5271-test.sh — BH-5271: the lead review
# checklist's item 9 (conflict shape), as an eval over the fixture set in
# tests/fixtures/lead-checklist-conflict.bh-5271/: a base tree, four case diffs
# and expected.txt (<case> :: NOTE|BLOCK|NONE).
#
# FREE MODE (default, CI). Each case is a PR on a scratch origin (base/ on main,
# <case>.diff on refs/pull/<n>/head). The REAL bin/lead-review.sh tick composes
# the review prompt, with curl (the jobs worker, hotspots.json on
# /api/conflict-hotspots), gh and bin/agent-call.sh stubbed. It asserts:
#   E1  the prompt's checklist is v2 or later, and item 9 gives [NOTE] for a new
#       shared list or a grown hotspot and [BLOCK] only with a changelog header
#       or a hand-written test lib list;
#   E2  item 9 names what is NOT conflict shape: the rationale comment, the
#       `## Changes` bump, docs/notes/ and the fragment directory, and tells the
#       reviewer that ABSENT / COULD NOT READ is not "no hotspots";
#   E3  the prompt's ## Conflict hotspots lists worker/jobs/schema.sql;
#   E4  the prompt's ## Diff carries each case's own added lines;
#   E5  expected.txt is whole: every line names a present .diff, every class is
#       NOTE|BLOCK|NONE, and there is a NOTE, a BLOCK and a NONE;
#   M1  mutation: item 9 removed from the checklist; E1 and E2 go red.
#
# LIVE MODE (opt-in, metered). LEAD_CHECKLIST_EVAL_MODEL=<model> sends each
# composed prompt through bin/agent-call.sh (lane lead-review, role
# lead.review, so the lane's caps apply) and grades the answer against
# expected.txt: NOTE = not BLOCK and a [NOTE] naming worker/jobs/schema.sql;
# BLOCK = VERDICT: BLOCK and a [BLOCK] naming the header comment; NONE = not
# BLOCK. The suite never picks a model itself. Unset = live grading skipped.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-checklist-conflict-eval.bh-5271-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/lead-checklist-conflict.bh-5271"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh prompts/lead-review-checklist.md tests/fixtures/lead-checklist-conflict.bh-5271/expected.txt; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PLAN_CONTEXT_HOTSPOT_TOP AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_MAX_PER_TICK

# ── E5: expected.txt is whole ──
CASES=(); declare -A CLASS
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  c=${line%% :: *}; k=${line##* :: }
  [ "$c" != "$line" ] || { bad "E5 malformed expected line '$line'"; continue; }
  [ -f "$FX/$c.diff" ] && ok || bad "E5 $c has no $c.diff"
  case "$k" in NOTE|BLOCK|NONE) ok ;; *) bad "E5 $c has class '$k'" ;; esac
  CASES+=("$c"); CLASS[$c]=$k
done < "$FX/expected.txt"
classes=" ${CLASS[*]} "
for k in NOTE BLOCK NONE; do
  [[ $classes == *" $k "* ]] && ok || bad "E5 no $k case in expected.txt"
done

# ── the scratch harness ──
HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
cp "\${6#@}" "$T/log/prompt.\$(cat "$T/case")"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
echo box-demo > "$HB/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$HB/fleet.conf"

# One origin: base/ on main, case i on refs/pull/<100+i>/head.
OR="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
cp -R "$FX/base/." "$WK/"
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$OR" main
declare -A PRN HEAD
i=0
for c in "${CASES[@]}"; do
  i=$((i + 1)); PRN[$c]=$((100 + i))
  git -C "$WK" checkout -q -B "case-$c" main
  if git -C "$WK" apply --index "$FX/$c.diff" 2>"$T/apply.err"; then ok; else bad "$c.diff does not apply on base/: $(cat "$T/apply.err")"; continue; fi
  git -C "$WK" commit -qm "$c"
  HEAD[$c]=$(git -C "$WK" rev-parse HEAD)
  git -C "$WK" push -q "$OR" "HEAD:refs/pull/${PRN[$c]}/head"
done
git clone -q "$OR" "$T/repos/cromford"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/conflict-hotspots?project=cromford&"*) out=\$(cat "$FX/hotspots.json") ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# compose <case> — one tick on that case's PR; the prompt lands in $T/log/prompt.<case>
compose() {
  local c="$1"
  echo "$c" > "$T/case"; echo "${HEAD[$c]}" > "$T/livehead"
  scratch_rm "$HB/state/lead-reviews"
  jq -nc --argjson p "${PRN[$c]}" --arg s "${HEAD[$c]}" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:$p,head_sha:$s,
    scope_notes:"eval",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/out" 2>&1
}
# section <file> <heading> <next heading>
section() { awk -v a="$2" -v b="$3" '$0 == a {f=1; next} $0 == b {f=0} f' "$1" 2>/dev/null; }
# item9 <file> — checklist item 9, from its line to the next numbered item or blank line
item9() { awk '/^9\. Conflict shape\./ {f=1} f && (/^$/ || /^[0-9]+\. / && !/^9\./) {exit} f' "$1" 2>/dev/null | tr '\n' ' ' | tr -s ' '; }

# check_prompt <case> <prompt-file> <tag> — E1-E4 on one composed prompt
check_prompt() {
  local c="$1" P="$2" tag="$3" it d
  [ -s "$P" ] || { bad "$tag $c: no prompt composed: $(cat "$T/out")"; return; }
  grep -qE '^Checklist-Version: ([2-9]|[1-9][0-9]+)$' "$P" && ok || bad "$tag E1 $c: checklist is not v2+: $(grep '^Checklist-Version' "$P")"
  it=$(item9 "$P")
  [ -n "$it" ] || { bad "$tag E1 $c: the prompt has no item 9 (Conflict shape)"; bad "$tag E2 $c: no item 9"; return; }
  grep -qF '[NOTE] a PR that adds a new append-only shared list' <<<"$it" && grep -qF 'grows a listed hotspot file' <<<"$it" \
    && ok || bad "$tag E1 $c: item 9 lacks the [NOTE] rule: $it"
  grep -qF '[BLOCK] only when the same PR ALSO adds a per-ticket changelog comment to a file header' <<<"$it" \
    && grep -qF 'hand-written lib list in a test' <<<"$it" && ok || bad "$tag E1 $c: item 9 lacks the [BLOCK]-only-with clause: $it"
  [ "$(grep -o '\[BLOCK\]' <<<"$it" | wc -l)" = 1 ] && ok || bad "$tag E1 $c: item 9 has more than one [BLOCK] rule"
  for s in 'a rationale comment next to the code it explains' 'a version bump with a `## Changes` line' \
           'a dated note under `docs/notes/`' 'a new file in a fragment directory' 'ABSENT or COULD NOT READ is not "no hotspots"'; do
    grep -qF -- "$s" <<<"$it" && ok || bad "$tag E2 $c: item 9 does not say '$s'"
  done
  section "$P" '## Conflict hotspots' '## Diff' | grep -qE '^  [0-9]+\. worker/jobs/schema\.sql — 17 conflicts' \
    && ok || bad "$tag E3 $c: ## Conflict hotspots lacks worker/jobs/schema.sql: $(section "$P" '## Conflict hotspots' '## Diff')"
  d=$(awk '$0 == "## Diff" {f=1; next} f' "$P")
  while IFS= read -r l; do
    grep -qxF -- "$l" <<<"$d" || { bad "$tag E4 $c: ## Diff lacks '$l'"; return; }
  done < <(grep '^+[^+]' "$FX/$c.diff")
  ok
}

for c in "${CASES[@]}"; do
  [ -n "${HEAD[$c]:-}" ] || continue
  compose "$c"; check_prompt "$c" "$T/log/prompt.$c" ""
done
grep -qxF -- '+-- BH-9999: added the foo table' "$T/log/prompt.changelog-header" 2>/dev/null && ok || bad "E4 the changelog-header prompt lacks its header line"

# ── M1: item 9 removed from the checklist; E1/E2 must go red ──
awk '/^9\. Conflict shape\./ {skip=1; next} skip && (/^$/ || /^[0-9]+\. / || /^[A-Z#]/) {skip=0} !skip' \
  "$SRC/prompts/lead-review-checklist.md" > "$HB/prompts/lead-review-checklist.md"
if cmp -s "$HB/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-checklist.md"; then
  bad "M1 the checklist has no item 9 to remove"
else
  c=${CASES[0]}; compose "$c"
  before=$FAIL
  check_prompt "$c" "$T/log/prompt.$c" "M1" > "$T/m1.out"
  mfail=$((FAIL - before)); FAIL=$before
  grep -q 'M1 E1' "$T/m1.out" && grep -q 'M1 E2' "$T/m1.out" && ok || bad "M1 E1/E2 stayed green with item 9 removed ($mfail misses): $(cat "$T/m1.out")"
fi
cp "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"

# ── LIVE MODE ──
if [ -z "${LEAD_CHECKLIST_EVAL_MODEL:-}" ]; then
  echo "live grading skipped: LEAD_CHECKLIST_EVAL_MODEL is not set (metered; the suite picks no model)"
else
  . "$SRC/bin/lib/verdict-parse.sh" || { bad "live: cannot source bin/lib/verdict-parse.sh"; }
  sed -n '/^lr_verdict() {/,/^}/p' "$SRC/bin/lead-review.sh" > "$T/lr-verdict.sh"
  . "$T/lr-verdict.sh"
  command -v lr_verdict >/dev/null || bad "live: no lr_verdict in bin/lead-review.sh"
  printf '%-20s %-6s %-6s %s\n' case want got verdict > "$T/live.tsv"
  for c in "${CASES[@]}"; do
    P="$T/log/prompt.$c"; out="$T/live.$c.out"
    [ -s "$P" ] || { bad "live $c: no composed prompt"; continue; }
    AGENT_CALL_ROLE=lead.review AGENT_CALL_LANE=lead-review \
      "$SRC/bin/agent-call.sh" lead-review cromford "$LEAD_CHECKLIST_EVAL_MODEL" 600 "$out" "@$P" >/dev/null 2>&1
    v=$(lr_verdict "$out"); got=NONE
    if [ "$v" = BLOCK ] && grep -qiE '^\s*-\s*\[BLOCK\].*(BH-9999|header)' "$out"; then got=BLOCK
    elif [ "$v" != BLOCK ] && [ "$v" != unknown ] && grep -qE '^\s*-\s*\[NOTE\].*worker/jobs/schema\.sql' "$out"; then got=NOTE
    elif [ "$v" = BLOCK ] || [ "$v" = unknown ]; then got="$v"; fi
    printf '%-20s %-6s %-6s %s\n' "$c" "${CLASS[$c]}" "$got" "$v" >> "$T/live.tsv"
    case "${CLASS[$c]}" in
      NONE) [ "$v" != BLOCK ] && [ "$v" != unknown ] && ok || bad "live $c: want not-BLOCK, got verdict $v" ;;
      *) [ "$got" = "${CLASS[$c]}" ] && ok || bad "live $c: want ${CLASS[$c]}, got $got (verdict $v)" ;;
    esac
  done
  cat "$T/live.tsv"
fi

echo "lead-checklist-conflict-eval.bh-5271: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
