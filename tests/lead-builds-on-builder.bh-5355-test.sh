#!/bin/bash
# tests/lead-builds-on-builder.bh-5355-test.sh — BH-5355: the lead review builds
# on the builder review (bin/review-prs.sh, posted on GitHub) of the SAME head.
#
# The REAL bin/lead-review.sh tick composes the prompt on a scratch origin, with
# curl (the jobs worker), gh and bin/agent-call.sh stubbed. The gh stub answers
# repos/<r>/pulls/<n>/reviews from a per-case JSON file in GitHub's review shape
# (user.login, state, commit_id, submitted_at, id, body). The agent-call stub
# keeps the prompt, the model argument and AGENT_CALL_ROW_NOTE of each call.
#
#   R0  BR_MARKER (bin/lib/builder-review.sh) equals RP_MARKER (bin/review-prs.sh).
#   R1  one APPROVE by a verdict author, commit_id == head, footer names head:
#       the section is there with verdict, reviewed sha and reviewer.
#   R2  commit_id and footer on an older sha: no section, prompt == P3's.
#   R2b commit_id older, footer names head (a re-push): no section.
#   R3  commit_id == head, footer names another sha: no section.
#   R4  marker + head right, author cromford-builders[bot]: no section.
#   R5  REQUEST_CHANGES then a later APPROVE on the head: the later one is used.
#   R6  the reviews read answers a non-array, or 404: a full review, one agent
#       call, and a log line naming the read failure.
#   R7  100 reviews: a full review, logged "may be cut at 100".
#   R8  no VERDICT line + state CHANGES_REQUESTED -> REQUEST_CHANGES; a body that
#       quotes "VERDICT: APPROVE" mid-text and ends REQUEST_CHANGES -> REQUEST_CHANGES.
#   P1  build-on: prompts/lead-review-builds-on.md verbatim right after the
#       checklist, `## Builder review (same head)` after the hotspots and before
#       `## Diff`, and the report header `- review mode: builds on builder review`.
#   P2  build-on: `## Diff` still carries every added line of the case.
#   P3  no reviews: no section, no builds-on text, no header line.
#   P4  the model argument is the same in build-on and full mode.
#   P5  a delta request with a matching review: delta prompt, no builder section.
#   K1  LEAD_REVIEW_BUILDS_ON_BUILDER=off with a matching review: prompt == P3's.
#   K2  knob unset (P1) and knob `on`: build-on.
#   K3  knob `yes`: prompt == P3's, and one log line names the bad value.
#   C1  AGENT_CALL_ROW_NOTE is lead-mode=build-on / full / delta.
#   E1-E3  each fixture case (tests/fixtures/lead-builds-on.bh-5355/): the
#       build-on prompt carries the case's builder review and its added lines;
#       expected.txt is whole, every class BLOCK, at least one builder APPROVE.
#   M1  mutations on scratch copies: no commit_id check -> R2b red; no marker
#       check -> R3 red; no author check -> R4 red; no builds-on cat -> P1 red.
#
# LIVE MODE (opt-in, metered). LEAD_BUILDS_ON_EVAL_MODEL=<model> sends each
# E-case prompt, in build-on mode and in knob-off mode, through bin/agent-call.sh
# (lane lead-review, role lead.review) and reads the verdict with lr_verdict.
# Every build-on answer must be BLOCK. It prints a per-case table and
# `agreement: <n>/<total> build-on vs full`. The suite never picks a model.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-builds-on-builder.bh-5355-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/lead-builds-on.bh-5355"
LIB="$SRC/bin/lib/builder-review.sh"
BOP="$SRC/prompts/lead-review-builds-on.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/review-prs.sh tests/fixtures/lead-builds-on.bh-5355/expected.txt; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
[ -f "$LIB" ] || bad "bin/lib/builder-review.sh does not exist"
[ -f "$BOP" ] || bad "prompts/lead-review-builds-on.md does not exist"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE LEAD_REVIEW_BUILDS_ON_BUILDER HARNESS_VERDICT_AUTHORS \
  HARNESS_OPERATOR_LOGIN LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES PLAN_CONTEXT_HOTSPOT_TOP

# ── R0: the reader's marker is the writer's ──
rp=$(sed -n 's/^RP_MARKER="\(.*\)"$/\1/p' "$SRC/bin/review-prs.sh" | head -n 1)
br=$(sed -n 's/^BR_MARKER="\(.*\)"$/\1/p' "$LIB" 2>/dev/null | head -n 1)
[ -n "$rp" ] && [ "$rp" = "$br" ] && ok || bad "R0 BR_MARKER '$br' is not RP_MARKER '$rp'"

# ── E1-E3 (part one): expected.txt is whole ──
CASES=(); declare -A CLASS
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  c=${line%% :: *}; k=${line##* :: }
  [ "$c" != "$line" ] || { bad "E malformed expected line '$line'"; continue; }
  [ -f "$FX/$c.diff" ] && ok || bad "E $c has no $c.diff"
  [ -f "$FX/$c.builder.md" ] && ok || bad "E $c has no $c.builder.md"
  [ "$k" = BLOCK ] && ok || bad "E $c has class '$k' (every case is known-bad: BLOCK)"
  CASES+=("$c"); CLASS[$c]=$k
done < "$FX/expected.txt"
[ "${#CASES[@]}" -ge 3 ] && ok || bad "E expected.txt has ${#CASES[@]} cases, want 3"
grep -lx 'VERDICT: APPROVE' "$FX"/*.builder.md >/dev/null 2>&1 && ok || bad "E no builder review APPROVEs (the wrong-approve fixture is missing)"

# ── the scratch harness ──
HB="$T/h"; mkdir -p "$HB/bin" "$HB/prompts" "$HB/catalog/lanes.d" "$HB/state" "$HB/env" "$T/repos" "$T/tmp" "$T/fakebin" "$T/log"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
t=\$(cat "$T/case")
echo x >> "$T/log/calls.\$t"
cp "\${6#@}" "$T/log/prompt.\$t"
printf '%s\n' "\${AGENT_CALL_ROW_NOTE-<unset>}" > "$T/log/note.\$t"
printf '%s\n' "\$3" > "$T/log/model.\$t"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/builder-review.sh" ] && ok || bad "the closure of bin/lead-review.sh lacks bin/lib/builder-review.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HB/prompts/"
cp "$BOP" "$HB/prompts/" 2>/dev/null
echo box-demo > "$HB/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$HB/fleet.conf"
LLOG="$HB/logs/lead-review.log"

# One origin: base/ on main, case i on refs/pull/<100+i>/head, and a delta PR
# 150 whose head D moved one commit past G (the head a prior lead report names).
OR="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
cp -R "$FX/base/." "$WK/"
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$OR" main
OLD=$(git -C "$WK" rev-parse HEAD)
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
C0=${CASES[0]}
git -C "$WK" checkout -q -B delta "case-$C0"; G=$(git -C "$WK" rev-parse HEAD)
echo 'one more line' >> "$WK/README.md"; git -C "$WK" commit -qam "delta"; DH=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" delta "HEAD:refs/pull/150/head"
PRN[delta]=150; HEAD[delta]=$DH
git clone -q "$OR" "$T/repos/demo-os"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/reviews"*)
    echo "\$*" >> "$T/log/reviews-reads"
    printf 'HTTP/2 %s\r\n\r\n' "\$(cat "$T/reviews.code")"
    cat "$T/reviews.json" ;;
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# body <case> <footer sha> — the builder review body as review-prs.sh posts it
body() { sed "s/{{HEAD_SHA}}/$2/g" "$FX/$1.builder.md"; }
# rev <login> <state> <commit_id> <id> <submitted_at> — one review; the body on stdin
rev() {
  jq -Rsc --arg l "$1" --arg st "$2" --arg c "$3" --argjson id "$4" --arg at "$5" \
    '{id:$id, user:{login:$l, type:"Bot"}, state:$st, commit_id:$c, submitted_at:$at, body:.}'
}
# reviews <review json>... — the reviews answer (200, a JSON array)
reviews() { printf '%s\n' "$@" | jq -sc . > "$T/reviews.json"; echo 200 > "$T/reviews.code"; }
appr() { body "$1" "$2" | rev 'cromford[bot]' "${4:-APPROVED}" "$3" "${5:-11}" "${6:-2026-10-10T10:00:00Z}"; }

# compose <tag> <case> [VAR=value ...] — one tick on that case's PR. The prompt,
# the row note and the model land in $T/log/<kind>.<tag>, the report and the
# lane log in $T/log/report.<tag> and $T/log/lane.<tag>.
compose() {
  local tag="$1" c="$2"; shift 2
  echo "$tag" > "$T/case"; echo "${HEAD[$c]}" > "$T/livehead"
  rm -f "$T/log/calls.$tag" "$T/log/prompt.$tag" "$T/log/note.$tag" "$T/log/model.$tag" "$LLOG"
  scratch_rm "$HB/state/lead-reviews"; scratch_rm "$HB/state/lead-review"; mkdir -p "$HB/state/lead-reviews"
  [ -n "${SCOPE_NOTES:-}" ] && [ -n "${PRIOR_REPORT:-}" ] && printf '%s' "$PRIOR_REPORT" > "$HB/state/lead-reviews/lr-${PRN[$c]}-${G:0:12}.md"
  jq -nc --argjson p "${PRN[$c]}" --arg s "${HEAD[$c]}" --arg n "${SCOPE_NOTES:-eval}" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:$p,head_sha:$s,
    scope_notes:$n,prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 "$@" bash "$HB/bin/lead-review.sh" tick ) > "$T/out.$tag" 2>&1
  cp "$HB/state/lead-reviews/lr-${PRN[$c]}-${HEAD[$c]:0:12}.md" "$T/log/report.$tag" 2>/dev/null || : > "$T/log/report.$tag"
  cp "$LLOG" "$T/log/lane.$tag" 2>/dev/null || : > "$T/log/lane.$tag"
}
calls() { [ -f "$T/log/calls.$1" ] && wc -l < "$T/log/calls.$1" | tr -d ' ' || echo 0; }
# section <file> <heading> <next heading>
section() { awk -v a="$2" -v b="$3" '$0 == a {f=1; next} $0 == b {f=0} f' "$1" 2>/dev/null; }
lineof() { grep -nxF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }
has_section() { grep -qxF '## Builder review (same head)' "$T/log/prompt.$1" 2>/dev/null; }
same_as() { cmp -s "$T/log/prompt.$1" "$T/log/prompt.$2"; }
H0=${HEAD[$C0]}; H12=${H0:0:12}
# APB: a fixture body that APPROVEs, posted on C0's head by the R/P/K cases.
APB=$(grep -lx 'VERDICT: APPROVE' "$FX"/*.builder.md | head -n 1); APB=$(basename "${APB:-none.builder.md}" .builder.md)

# ── P3 first: no reviews at all is the reference full prompt ──
reviews; compose p3 "$C0"
[ "$(calls p3)" = 1 ] && ok || bad "P3 agent called $(calls p3) time(s): $(cat "$T/out.p3") $(cat "$T/log/lane.p3")"
has_section p3 && bad "P3 no reviews, yet the prompt has a builder section" || ok
[ -s "$BOP" ] && grep -qF -- "$(head -n 1 "$BOP")" "$T/log/prompt.p3" && bad "P3 the full prompt carries the builds-on text" || ok
grep -q '^- review mode: builds on' "$T/log/report.p3" && bad "P3 the report claims build-on mode" || ok
grep -q "full review (no builder review on $H12)" "$T/log/lane.p3" && ok || bad "P3 no 'full review (no builder review on <sha12>)' log line: $(cat "$T/log/lane.p3")"

# ── R1 / P1 / P2 / K2: one APPROVE on the head, knob unset ──
reviews "$(appr "$APB" "$H0" "$H0")"; compose p1 "$C0"
P="$T/log/prompt.p1"
[ "$(calls p1)" = 1 ] && ok || bad "P1 agent called $(calls p1) time(s): $(cat "$T/log/lane.p1")"
has_section p1 && ok || bad "R1/K2 no '## Builder review (same head)' section (knob unset, matching APPROVE): $(cat "$T/log/lane.p1")"
S=$(section "$P" '## Builder review (same head)' '## Diff')
grep -qx 'verdict: APPROVE' <<<"$S" && ok || bad "R1 the section lacks 'verdict: APPROVE': $S"
grep -qx "reviewed sha: $H0" <<<"$S" && ok || bad "R1 the section lacks 'reviewed sha: <head>'"
grep -qx 'reviewer: cromford\[bot\]' <<<"$S" && ok || bad "R1 the section lacks the reviewer"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  grep -qxF -- "$l" <<<"$S" || { bad "R1 the section lacks the builder body line '$l'"; break; }
done < <(body "$APB" "$H0")
# P1: builds-on text verbatim, right after the checklist; section after the hotspots, before ## Diff
if [ -s "$BOP" ]; then
  n=$(wc -l < "$BOP"); s=$(lineof "$P" "$(head -n 1 "$BOP")")
  if [ -n "$s" ]; then
    sed -n "${s},$((s + n - 1))p" "$P" | cmp -s - "$BOP" && ok || bad "P1 the builds-on prompt is not in the prompt verbatim"
    ck=$(lineof "$P" "$(tail -n 1 "$HB/prompts/lead-review-checklist.md")"); prl=$(lineof "$P" '## PR')
    [ -n "$ck" ] && [ -n "$prl" ] && [ "$ck" -lt "$s" ] && [ "$s" -lt "$prl" ] && ok \
      || bad "P1 the builds-on text is not between the checklist (line ${ck:-?}) and ## PR (line ${prl:-?}); it starts at $s"
  else
    bad "P1 the prompt lacks the builds-on text"
  fi
fi
for want in 'can be wrong' 'Read every part'; do
  grep -qF -- "$want" "$P" && ok || bad "P1 the build-on prompt does not say '$want'"
done
hs=$(lineof "$P" '## Conflict hotspots'); bs=$(lineof "$P" '## Builder review (same head)'); ds=$(lineof "$P" '## Diff')
[ -n "$bs" ] && [ -n "$ds" ] && [ "${hs:-0}" -lt "$bs" ] && [ "$bs" -lt "$ds" ] && ok \
  || bad "P1 the section is not between ## Conflict hotspots (${hs:-?}) and ## Diff (${ds:-?}): ${bs:-absent}"
grep -qx -- "- review mode: builds on builder review APPROVE at $H12" "$T/log/report.p1" && ok \
  || bad "P1 the report lacks '- review mode: builds on builder review APPROVE at <sha12>': $(head -n 12 "$T/log/report.p1")"
grep -q "builds on builder review APPROVE at $H12" "$T/log/lane.p1" && ok || bad "P1 no build-on log line"
D=$(awk '$0 == "## Diff" {f=1; next} f' "$P")
while IFS= read -r l; do
  grep -qxF -- "$l" <<<"$D" || { bad "P2 build-on ## Diff lacks '$l'"; break; }
done < <(grep '^+[^+]' "$FX/$C0.diff")
ok
# P4: the same model in both modes
[ -s "$T/log/model.p1" ] && cmp -s "$T/log/model.p1" "$T/log/model.p3" && ok \
  || bad "P4 the model differs: build-on '$(cat "$T/log/model.p1" 2>/dev/null)' vs full '$(cat "$T/log/model.p3" 2>/dev/null)'"
# C1 (two of three)
[ "$(cat "$T/log/note.p1" 2>/dev/null)" = lead-mode=build-on ] && ok || bad "C1 build-on row note is '$(cat "$T/log/note.p1" 2>/dev/null)'"
[ "$(cat "$T/log/note.p3" 2>/dev/null)" = lead-mode=full ] && ok || bad "C1 full row note is '$(cat "$T/log/note.p3" 2>/dev/null)'"
for m in lead-mode=build-on lead-mode=full lead-mode=delta; do
  [ "$(printf '%s' "$m" | tr -cd 'a-z0-9=:._-' | cut -c1-64)" = "$m" ] && ok || bad "C1 '$m' does not survive agent-call's note cut"
done

# ── K2b: knob `on` explicitly ──
compose k2 "$C0" LEAD_REVIEW_BUILDS_ON_BUILDER=on
same_as k2 p1 && ok || bad "K2 knob on: the prompt is not P1's"

# ── K1: knob off with a matching review is today's prompt ──
compose k1 "$C0" LEAD_REVIEW_BUILDS_ON_BUILDER=off
same_as k1 p3 && ok || bad "K1 knob off: the prompt differs from the no-review prompt: $(diff "$T/log/prompt.p3" "$T/log/prompt.k1" | head -n 8)"
grep -q 'full review (LEAD_REVIEW_BUILDS_ON_BUILDER=off)' "$T/log/lane.k1" && ok || bad "K1 no knob-off log line: $(cat "$T/log/lane.k1")"

# ── K3: an unknown value is off, logged ──
compose k3 "$C0" LEAD_REVIEW_BUILDS_ON_BUILDER=yes
same_as k3 p3 && ok || bad "K3 knob yes: the prompt differs from the no-review prompt"
[ "$(grep -c "LEAD_REVIEW_BUILDS_ON_BUILDER='yes'" "$T/log/lane.k3")" = 1 ] && ok || bad "K3 want one log line naming 'yes': $(cat "$T/log/lane.k3")"

# ── R2: commit_id and footer on an older sha ──
reviews "$(appr "$APB" "$OLD" "$OLD")"; compose r2 "$C0"
same_as r2 p3 && ok || bad "R2 a review of an older sha changed the prompt"
# ── R2b: commit_id older, footer names the head ──
reviews "$(appr "$APB" "$H0" "$OLD")"; compose r2b "$C0"
same_as r2b p3 && ok || bad "R2b a review with an older commit_id was used"
# ── R3: commit_id == head, footer names another sha ──
reviews "$(appr "$APB" "$OLD" "$H0")"; compose r3 "$C0"
same_as r3 p3 && ok || bad "R3 a review whose footer names another sha was used"
# ── R4: the builders App, and the PR author, are not verdict authors ──
reviews "$(body "$APB" "$H0" | rev 'cromford-builders[bot]' APPROVED "$H0" 12 2026-10-10T10:00:00Z)" \
        "$(body "$APB" "$H0" | rev 'someone-else' APPROVED "$H0" 13 2026-10-10T10:01:00Z)"
compose r4 "$C0"
same_as r4 p3 && ok || bad "R4 a review by a non-verdict author was used"
# ── R5: two on the head; the later one wins ──
printf 'Findings\n- [Critical] x.sh:1: the earlier review\n\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of %s. Static review._\n' "$H0" \
  | rev 'cromford[bot]' COMMENTED "$H0" 20 2026-10-10T09:00:00Z > "$T/rc.json"
reviews "$(appr "$APB" "$H0" "$H0" APPROVED 21 2026-10-10T11:00:00Z)" "$(cat "$T/rc.json")"
compose r5 "$C0"
S=$(section "$T/log/prompt.r5" '## Builder review (same head)' '## Diff')
grep -qx 'verdict: APPROVE' <<<"$S" && ! grep -q 'the earlier review' <<<"$S" && ok || bad "R5 the later review was not the one used: $S"
# ── R6: the reviews read fails ──
echo '{"message":"Not Found"}' > "$T/reviews.json"; echo 200 > "$T/reviews.code"; compose r6 "$C0"
same_as r6 p3 && [ "$(calls r6)" = 1 ] && ok || bad "R6 a non-array answer: calls=$(calls r6), prompt differs: $(diff "$T/log/prompt.p3" "$T/log/prompt.r6" | head -n 5)"
grep -q 'full review (reviews read failed' "$T/log/lane.r6" && ok || bad "R6 no read-failure log line: $(cat "$T/log/lane.r6")"
echo 404 > "$T/reviews.code"; compose r6b "$C0"
same_as r6b p3 && [ "$(calls r6b)" = 1 ] && grep -q 'full review (reviews read failed' "$T/log/lane.r6b" && ok || bad "R6 a 404: not a logged full review"
# ── R7: 100 reviews ──
for k in $(seq 1 100); do appr "$APB" "$H0" "$H0" APPROVED "$k"; done | jq -sc . > "$T/reviews.json"; echo 200 > "$T/reviews.code"
compose r7 "$C0"
same_as r7 p3 && ok || bad "R7 100 reviews were used"
grep -q 'may be cut at 100' "$T/log/lane.r7" && ok || bad "R7 no 'may be cut at 100' log line: $(cat "$T/log/lane.r7")"
# ── R8: the verdict, from the state, and from the final block only ──
printf 'Findings\n- [Critical] bin/sync.sh:10: outage read as done\n\n---\n_Automated harness review (Fable) of %s. Static review._\n' "$H0" \
  | rev 'cromford[bot]' CHANGES_REQUESTED "$H0" 30 2026-10-10T10:00:00Z > "$T/r8.json"
reviews "$(cat "$T/r8.json")"; compose r8 "$C0"
section "$T/log/prompt.r8" '## Builder review (same head)' '## Diff' | grep -qx 'verdict: REQUEST_CHANGES' && ok \
  || bad "R8 a body with no VERDICT line and state CHANGES_REQUESTED: $(section "$T/log/prompt.r8" '## Builder review (same head)' '## Diff' | head -n 3)"
printf 'An earlier pass wrote VERDICT: APPROVE on this head, and it was wrong.\n\nFindings\n- [Critical] bin/sync.sh:10: outage read as done\n\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of %s. Static review._\n' "$H0" \
  | rev 'cromford[bot]' COMMENTED "$H0" 31 2026-10-10T10:00:00Z > "$T/r8b.json"
reviews "$(cat "$T/r8b.json")"; compose r8b "$C0"
section "$T/log/prompt.r8b" '## Builder review (same head)' '## Diff' | grep -qx 'verdict: REQUEST_CHANGES' && ok \
  || bad "R8 a mid-text 'VERDICT: APPROVE' quote decided the verdict"

# ── P5 / C1: a delta request with a matching review stays a plain delta ──
reviews "$(appr "$APB" "$DH" "$DH")"
SCOPE_NOTES="auto: builder APPROVE on ${DH:0:12}; lead-delta:$G lines:1/40 files:1" \
PRIOR_REPORT=$(printf '# Lead review lr-150-%s (example-org/demo-os#150 at %s)\n\n- verdict: MERGE\n- reviewer model: stub-model\n\nFindings\n- none\n\nVERDICT: MERGE\n' "${G:0:12}" "$G") \
  compose p5 delta
grep -q '^DELTA REVIEW' "$T/log/prompt.p5" 2>/dev/null && ok || bad "P5 the delta request was not a delta review: $(cat "$T/log/lane.p5")"
has_section p5 && bad "P5 a delta review carries the builder section" || ok
[ "$(cat "$T/log/note.p5" 2>/dev/null)" = lead-mode=delta ] && ok || bad "C1 delta row note is '$(cat "$T/log/note.p5" 2>/dev/null)'"

# ── E1-E3: each fixture case, with its builder review on its head ──
for c in "${CASES[@]}"; do
  [ -n "${HEAD[$c]:-}" ] || continue
  st=APPROVED; grep -qx 'VERDICT: REQUEST_CHANGES' "$FX/$c.builder.md" && st=COMMENTED
  reviews "$(appr "$c" "${HEAD[$c]}" "${HEAD[$c]}" "$st")"
  compose "e-$c" "$c"; compose "f-$c" "$c" LEAD_REVIEW_BUILDS_ON_BUILDER=off
  S=$(section "$T/log/prompt.e-$c" '## Builder review (same head)' '## Diff')
  f=$(grep -m1 '^- ' "$FX/$c.builder.md")
  [ -n "$S" ] && grep -qxF -- "$f" <<<"$S" && ok || bad "E $c: the build-on prompt lacks the builder finding '$f'"
  D=$(awk '$0 == "## Diff" {f=1; next} f' "$T/log/prompt.e-$c")
  miss=""; while IFS= read -r l; do grep -qxF -- "$l" <<<"$D" || miss="$l"; done < <(grep '^+[^+]' "$FX/$c.diff")
  [ -z "$miss" ] && ok || bad "E $c: build-on ## Diff lacks '$miss'"
  has_section "f-$c" && bad "E $c: the knob-off prompt carries the builder section" || ok
done

# ── M1: mutations on the scratch copies; each must turn its case red ──
mutate() { # mutate <file> <sed expr> <tag> <label> — one compose on C0 with the file mutated, then restored
  cp "$HB/$1" "$T/mut.bak"; sed -i "$2" "$HB/$1"
  if cmp -s "$HB/$1" "$T/mut.bak"; then bad "M1 $4: the mutation changed nothing in $1"; return; fi
  compose "$3" "$C0"; cp "$T/mut.bak" "$HB/$1"
}
reviews "$(appr "$APB" "$H0" "$OLD")"
mutate bin/lib/builder-review.sh 's/select(.commit_id == \$s) | //' m-r2b "no commit_id check"
has_section m-r2b && ok || bad "M1 R2b stayed green with the commit_id check removed"
reviews "$(appr "$APB" "$OLD" "$H0")"
mutate bin/lib/builder-review.sh 's/ | select((.body \/\/ "") | contains(\$m))//' m-r3 "no marker check"
has_section m-r3 && ok || bad "M1 R3 stayed green with the marker check removed"
reviews "$(body "$APB" "$H0" | rev 'cromford-builders[bot]' APPROVED "$H0" 12 2026-10-10T10:00:00Z)"
mutate bin/lib/builder-review.sh 's/harness_verdict_author_match "\$login" || continue/:/' m-r4 "no author check"
has_section m-r4 && ok || bad "M1 R4 stayed green with the author check removed"
reviews "$(appr "$APB" "$H0" "$H0")"
mutate bin/lead-review.sh '/cat "\$H\/prompts\/lead-review-builds-on.md"/d' m-p1 "no builds-on cat"
[ -s "$BOP" ] && grep -qF -- "$(head -n 1 "$BOP")" "$T/log/prompt.m-p1" && bad "M1 P1 stayed green with the builds-on cat removed" || ok

# ── LIVE MODE ──
if [ -z "${LEAD_BUILDS_ON_EVAL_MODEL:-}" ]; then
  echo "live grading skipped: LEAD_BUILDS_ON_EVAL_MODEL is not set (metered; the suite picks no model)"
else
  . "$SRC/bin/lib/verdict-parse.sh" || bad "live: cannot source bin/lib/verdict-parse.sh"
  sed -n '/^lr_verdict() {/,/^}/p' "$SRC/bin/lead-review.sh" > "$T/lr-verdict.sh"
  . "$T/lr-verdict.sh"
  command -v lr_verdict >/dev/null || bad "live: no lr_verdict in bin/lead-review.sh"
  agree=0; total=0
  printf '%-22s %-8s %-16s %-10s %-10s\n' case want builder build-on full > "$T/live.tsv"
  for c in "${CASES[@]}"; do
    vs=()
    for mode in e f; do
      P="$T/log/prompt.$mode-$c"; out="$T/live.$mode-$c.out"
      [ -s "$P" ] || { bad "live $c: no $mode prompt"; vs+=(none); continue; }
      AGENT_CALL_ROLE=lead.review AGENT_CALL_LANE=lead-review AGENT_CALL_ROW_NOTE="lead-mode=eval-$mode" \
        "$SRC/bin/agent-call.sh" lead-review demo-os "$LEAD_BUILDS_ON_EVAL_MODEL" 900 "$out" "@$P" >/dev/null 2>&1
      vs+=("$(lr_verdict "$out")")
    done
    total=$((total + 1)); [ "${vs[0]}" = "${vs[1]}" ] && agree=$((agree + 1))
    printf '%-22s %-8s %-16s %-10s %-10s\n' "$c" "${CLASS[$c]}" "$(grep -oE '^VERDICT: [A-Z_]+' "$FX/$c.builder.md" | cut -d' ' -f2)" "${vs[0]}" "${vs[1]}" >> "$T/live.tsv"
    [ "${vs[0]}" = BLOCK ] && ok || bad "live $c: build-on verdict ${vs[0]}, want BLOCK"
  done
  cat "$T/live.tsv"
  echo "agreement: $agree/$total build-on vs full"
fi

echo "lead-builds-on-builder.bh-5355: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
