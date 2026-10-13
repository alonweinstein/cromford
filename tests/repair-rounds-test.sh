#!/bin/bash
# tests/repair-rounds-test.sh — SDLC item 3: how many times was this build sent
# back, and does anything downstream know?
#
# The hole this closes: a diff that needed a security fix round, a refuter fix
# round and a QA fix round settled at exactly the same tier-1 auto-merge as one
# that passed every lens first time, and no row anywhere recorded the
# difference. So the fleet could not ask its own history the one question that
# would let it tune a gate: are the builds that had to be repaired the builds
# that get reverted?
#
# WHY DRIVEN AND NOT GREPPED. `grep -q REPAIRS bin/run-build.sh` passes on a
# counter that counts every build as clean, on a demoter that fires on the first
# fix round, and on one wired to the wrong default. What is under test is the
# arithmetic and the switches: which six facts count, what the warn-first
# default actually does to a tier, and that the count reaches the verdict row,
# logs/findings.log and the metrics push in the shape their readers expect.
#
# The run-build blocks are extracted VERBATIM by their markers, so a regression
# in the shipped lines fails here rather than in a paraphrase. No network, no
# model call, no secrets: curl and the ledger are stubs.
# Run from anywhere: tests/repair-rounds-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/logs" "$T/stub"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

COUNT="$DIR/bin/repair-count.sh"

# ============================================================================
# 1. bin/repair-count.sh — the six facts, and nothing else
# ============================================================================
mkbuild() { # mkbuild <name> [round-files...]
  local b="$T/$1"; shift
  scratch_rm "$b"; mkdir -p "$b"
  for f in "$@"; do : > "$b/$f"; done
  printf '%s' "$b"
}
gates() { # gates <build> <tamper> <repro>
  jq -nc --arg t "$2" --arg r "$3" '{tamper:$t,repro:$r,intent:"0",e2e:"pass",migration:"none"}' > "$1/gates.json"
}

B=$(mkbuild clean)
[ "$("$COUNT" "$B")" = "$(printf '0\t-')" ] && ok || bad "a build nobody touched must count 0 (got: $("$COUNT" "$B"))"

B=$(mkbuild one review2-run.txt)
[ "$("$COUNT" "$B" | cut -f1)" = 1 ] && ok || bad "the general re-review must count as a repair"
[ "$("$COUNT" "$B" | cut -f2)" = review ] && ok || bad "the round list must name the lens: $("$COUNT" "$B")"

B=$(mkbuild four review2-run.txt security-review2-run.txt refute-review2-run.txt qa2-run.txt)
[ "$("$COUNT" "$B" | cut -f1)" = 4 ] && ok || bad "all four re-review rounds must count"
[ "$("$COUNT" "$B" | cut -f2)" = "review,security,refute,qa" ] && ok \
  || bad "the round list is not in pipeline order: $("$COUNT" "$B" | cut -f2)"

# Presence, not size: a re-review session that died still means code went back.
B=$(mkbuild empty-run review2-run.txt)
[ -s "$B/review2-run.txt" ] && bad "fixture is not empty" || ok
[ "$("$COUNT" "$B" | cut -f1)" = 1 ] && ok || bad "an empty re-review file must still count as a repair"

# The two mechanical-gate codes that are recorded rather than blocking.
B=$(mkbuild gates-2-4); gates "$B" 2 4
[ "$("$COUNT" "$B" | cut -f1)" = 2 ] && ok || bad "tamper=2 + repro=4 must count 2 (got: $("$COUNT" "$B"))"
[ "$("$COUNT" "$B" | cut -f2)" = "tamper-justified,repro-head-red" ] && ok \
  || bad "the gate contributions are not named: $("$COUNT" "$B" | cut -f2)"

# ...and only those two codes. A clean gate, a blocked one and a gate that could
# not run are not repairs — counting them would make the signal mean "anything
# happened", which is the number that demotes every build.
for PAIR in 0:0 1:1 3:3 0:2 2:0; do
  B=$(mkbuild "gates-$PAIR"); gates "$B" "${PAIR%%:*}" "${PAIR##*:}"
  N=$("$COUNT" "$B" | cut -f1)
  case "$PAIR" in
    2:0) [ "$N" = 1 ] && ok || bad "tamper=2 alone must count 1, got $N" ;;
    0:2) [ "$N" = 0 ] && ok || bad "repro=2 (no new tests) is not a repair, got $N" ;;
    *)   [ "$N" = 0 ] && ok || bad "gates $PAIR must count 0 repairs, got $N" ;;
  esac
done

# Fail-open: a missing build dir answers 0 and exits 0, because a counter that
# can stop a build is worse than a counter that is absent.
OUT=$("$COUNT" "$T/does-not-exist"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$(printf '0\t-')" ] && ok || bad "a missing build dir must answer 0/rc0 (got rc=$RC '$OUT')"
OUT=$("$COUNT"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$(printf '0\t-')" ] && ok || bad "no argument must answer 0/rc0 (got rc=$RC '$OUT')"

# An archived record re-counts to the same number months later — the whole
# reason this reads files and never the pipeline's live variables.
B=$(mkbuild archived review2-run.txt qa2-run.txt); gates "$B" 2 0
[ "$("$COUNT" "$B")" = "$("$COUNT" "$B")" ] && [ "$("$COUNT" "$B" | cut -f1)" = 3 ] && ok \
  || bad "a re-count of the same record disagreed with itself"

# ============================================================================
# 2. bin/run-build.sh — the demoter, its threshold and its warn-first default
# ============================================================================
awk '/^# >>> repair rounds/{f=1;next} /^# <<< repair rounds/{exit} f' \
  "$RB_ALL" > "$T/repairs.sh"
[ -s "$T/repairs.sh" ] && ok || bad "could not extract the repair-rounds block — markers missing?"
grep -q 'repair-count.sh' "$T/repairs.sh" && ok \
  || bad "the extracted block does not call bin/repair-count.sh — a second implementation?"

demote() { # demote <build-dir> <tier-in> [env assignments...]
  local b="$1" tier="$2"; shift 2
  ( env HARNESS="$DIR" BUILD="$b" PROJECT=p KEY=K TIER="$tier" QA_NOTE="" "$@" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
             printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/repairs.sh" 2>/dev/null )
}

# 2a. Warn-first is the SHIPPED default: at the threshold the tier stands, and
#     the count is still stated where every reader downstream picks it up.
B=$(mkbuild d-two review2-run.txt qa2-run.txt)
OUT=$(demote "$B" 1)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "the shipped default must not demote (got: $OUT)"
grep -q 'REPAIR_TIER_ENFORCE=0, warn only' <<<"$OUT" && ok \
  || bad "a warn-only run must still say so in the note (got: $OUT)"
grep -q 'REPAIRS: 2 repair round(s) (review,qa)' <<<"$OUT" && ok \
  || bad "the note must name the count and the rounds (got: $OUT)"
[ "$(cat "$B/repairs")" = "$(printf '2\treview,qa')" ] && ok \
  || bad "the file fallback was not written: '$(cat "$B/repairs" 2>/dev/null)'"

# 2b. Armed, the same build demotes and says why.
OUT=$(demote "$B" 1 REPAIR_TIER_ENFORCE=1)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "REPAIR_TIER_ENFORCE=1 must demote at the threshold (got: $OUT)"
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'recorded tier-2 (risk signal)' <<<"$OUT" && ok || bad "the demotion note must say it demoted (got: $OUT)"

# 2c. Below the threshold nothing happens at all — one fix round is ordinary
#     work, and a gate that fires on it would demote most of the fleet.
B=$(mkbuild d-one review2-run.txt)
OUT=$(demote "$B" 1 REPAIR_TIER_ENFORCE=1)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok || bad "one repair round must be silent (got: $OUT)"
[ "$(cat "$B/repairs")" = "$(printf '1\treview')" ] && ok \
  || bad "the count is recorded even below the threshold: '$(cat "$B/repairs" 2>/dev/null)'"

# 2d. The threshold is a knob, and a junk value falls back to the documented 2.
OUT=$(demote "$B" 1 REPAIR_TIER_ENFORCE=1 REPAIR_TIER_MAX=1)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "REPAIR_TIER_MAX=1 must demote at one repair (got: $OUT)"
B=$(mkbuild d-junk review2-run.txt qa2-run.txt)
OUT=$(demote "$B" 1 REPAIR_TIER_ENFORCE=1 REPAIR_TIER_MAX=banana)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a junk threshold must fall back to 2 (got: $OUT)"

# 2e. A build already at tier 2 keeps its existing note and gains no second
#     demotion — the note is a list of reasons, not a place to repeat one.
B=$(mkbuild d-t2 review2-run.txt qa2-run.txt)
OUT=$(env HARNESS="$DIR" BUILD="$B" PROJECT=p KEY=K TIER=2 QA_NOTE=" | QA: SKIPPED — demoted to tier-2" \
      REPAIR_TIER_ENFORCE=1 \
      bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
               printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/repairs.sh" 2>/dev/null)
grep -q '^TIER=2|NOTE= | QA: SKIPPED — demoted to tier-2$' <<<"$OUT" && ok \
  || bad "a build already at tier 2 must not gain a second demotion note (got: $OUT)"
[ -s "$B/repairs" ] && ok || bad "a tier-2 build still records its repair count"

# 2f. A build whose repair count cannot be read is not a repaired build: the
#     helper is fail-open, so the pipeline carries on with zero rather than
#     demoting on the absence of a number.
OUT=$(env HARNESS="$T/no-harness" BUILD="$(mkbuild d-nohelper review2-run.txt qa2-run.txt)" \
      PROJECT=p KEY=K TIER=1 QA_NOTE="" REPAIR_TIER_ENFORCE=1 \
      bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
               printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/repairs.sh" 2>/dev/null)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok || bad "a missing counter must not demote (got: $OUT)"

# ============================================================================
# 3. The verdict row carries the count — including zero
# ============================================================================
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' \
  "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/verdict.sh" ] && ok || bad "could not extract the verdict-artifact block"

verdict_detail() { # verdict_detail <repairs> <rounds>
  local b="$T/vb"; scratch_rm "$b"; mkdir -p "$b"
  printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$b/review.md"
  # The shipped call sends its own stdout to /dev/null (an artifact put must
  # never leak into a build's output), so the stub records the detail in a file.
  ( env BUILD="$b" PR_URL=https://github.com/x/y/pull/1 JOB_ID=job-1 TIER=1 QA_NOTE="" \
        HEADBOUND_SHA=abc123 REPAIRS="$1" REPAIR_ROUNDS="$2" SINK="$T/artifact.json" \
    bash -c 'set -uo pipefail
             job_artifact_put() { printf "%s" "$3" > "$SINK"; }
             . "$0"' "$T/verdict.sh" 2>/dev/null )
  cat "$T/artifact.json" 2>/dev/null
}
D=$(verdict_detail 3 "review,qa,tamper-justified")
[ "$(jq -r '.repairs' <<<"$D")" = 3 ] && ok || bad "the verdict row lost the repair count (detail: $D)"
[ "$(jq -r '.repairs|type' <<<"$D")" = number ] && ok || bad "repairs must be a number, not a string (detail: $D)"
[ "$(jq -r '.repair_rounds' <<<"$D")" = "review,qa,tamper-justified" ] && ok \
  || bad "the verdict row lost the round list (detail: $D)"
# Zero is a MEASUREMENT — the correlation needs the clean builds too — so unlike
# the reviewed sha it is written rather than omitted.
D=$(verdict_detail 0 "-")
[ "$(jq -r '.repairs' <<<"$D")" = 0 ] && ok || bad "a clean build must record repairs=0 (detail: $D)"
# ...and the fields item 1 put there still ride along untouched.
[ "$(jq -r '.reviewed_sha' <<<"$D")" = abc123 ] && ok || bad "the reviewed sha was dropped (detail: $D)"
[ "$(jq -r '.tier' <<<"$D")" = 1 ] && ok || bad "the tier was dropped (detail: $D)"

# ============================================================================
# 4. logs/findings.log — repairs= rides beside the lens's own findings
# ============================================================================
fl_run() { # fl_run <build-dir>
  rm -f "$T/logs/findings.log"
  ( env HARNESS="$T" bash "$DIR/bin/findings-log.sh" "$1" widget-os WD-9 >/dev/null 2>&1 )
  cat "$T/logs/findings.log" 2>/dev/null
}
B=$(mkbuild fl review2-run.txt qa2-run.txt)
printf '# review\n- The rate limiter is reset on every request, so the window never closes (D14)\nVERDICT: BLOCK\n' \
  > "$B/review.md"
OUT=$(fl_run "$B")
grep -q 'repairs=2 family=' <<<"$OUT" && ok || bad "the finding row does not carry repairs= (got: $OUT)"
# family= stays the LAST field before ::, the anchor every consumer keys on.
awk -F' :: ' '{n=split($1,a," "); if (a[n] !~ /^family=/) exit 1}' <<<"$OUT" && ok \
  || bad "repairs= displaced family= from the last field before :: (got: $OUT)"
grep -q 'lens=general verdict=BLOCK' <<<"$OUT" && ok || bad "the existing fields changed shape (got: $OUT)"

# A build that was never sent back says NOTHING rather than repairs=0: the field
# is optional on the same terms as fraud=, and both readings ("not repaired",
# "written before this shipped") are correctly outside the question it answers.
B=$(mkbuild fl-clean)
printf '# review\n- The rate limiter is reset on every request, so the window never closes (D14)\nVERDICT: APPROVE\n' \
  > "$B/review.md"
OUT=$(fl_run "$B")
grep -q 'repairs=' <<<"$OUT" && bad "a clean build wrote repairs=0 into findings.log (got: $OUT)" || ok
grep -q 'family=' <<<"$OUT" && ok || bad "the clean build wrote no finding at all (got: $OUT)"

# ============================================================================
# 5. bin/jobs-client.sh — the push and the read
# ============================================================================
cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
for a in "$@"; do
  case "$PREV" in --data-binary) printf '%s\n' "$a" >> "$POST_SINK" ;; esac
  PREV="$a"
done
URL="${!#}"
case "$URL" in
  */api/verdict*) printf '%s\n200\n' "$(cat "$FIX_VERDICT")" ;;
  *) printf '{"upserted":1}\n200\n' ;;
esac
CURL
chmod +x "$T/stub/curl"
export PATH="$T/stub:$PATH" POST_SINK="$T/posts.txt" FIX_VERDICT="$T/verdict.json"
: > "$POST_SINK"
export HARNESS_SECRET=x JOBS_URL=https://jobs.test
# shellcheck source=/dev/null
. "$DIR/bin/jobs-client.sh"

metric_outcomes Acme/widget-os https://github.com/Acme/widget-os/pull/11 reverted 2026-09-06 "revert abc" 2 >/dev/null 2>&1
[ "$(jq -r '.repairs' < "$POST_SINK")" = 2 ] && ok || bad "metric_outcomes dropped repairs: $(cat "$POST_SINK")"
[ "$(jq -r '.repairs|type' < "$POST_SINK")" = number ] && ok || bad "repairs pushed as a string: $(cat "$POST_SINK")"
: > "$POST_SINK"
# "-" (a PR whose build never measured it) and a junk value push NO field at
# all, so the worker's COALESCE keeps whatever is already there.
metric_outcomes Acme/widget-os https://github.com/Acme/widget-os/pull/12 reverted 2026-09-06 "revert abc" - >/dev/null 2>&1
[ "$(jq -r 'has("repairs")' < "$POST_SINK")" = false ] && ok || bad "an unmeasured PR pushed a repairs field: $(cat "$POST_SINK")"
: > "$POST_SINK"
metric_outcomes Acme/widget-os https://github.com/Acme/widget-os/pull/13 reverted 2026-09-06 "revert abc" >/dev/null 2>&1
[ "$(jq -r 'has("repairs")' < "$POST_SINK")" = false ] && ok || bad "an old caller (5 args) pushed a repairs field: $(cat "$POST_SINK")"
: > "$POST_SINK"
metric_outcomes Acme/widget-os https://github.com/Acme/widget-os/pull/14 reverted 2026-09-06 "revert abc" 0 >/dev/null 2>&1
[ "$(jq -r '.repairs' < "$POST_SINK")" = 0 ] && ok || bad "repairs=0 was dropped as if it were absent: $(cat "$POST_SINK")"

# job_pr_facts APPENDS repairs, so a reader of the first six fields is unchanged.
cat > "$FIX_VERDICT" <<'JSON'
{"pr":"https://github.com/Acme/widget-os/pull/11","job_id":"b-11","verdict":"APPROVE","tier":1,
 "merge_sha":"aaaa1111","repairs":3,"job":{"id":"b-11","project":"widget-os","ticket_id":"WD-11"}}
JSON
# F8 is the scope verdict (SDLC item 4) — read into its own variable so the
# repairs assertion below keeps testing repairs rather than the tail of the row.
IFS=$'\t' read -r F1 F2 F3 F4 F5 F6 F7 F8 <<<"$(job_pr_facts https://github.com/Acme/widget-os/pull/11)"
[ "$F1 $F2 $F3 $F4 $F5 $F6" = "b-11 widget-os WD-11 APPROVE aaaa1111 1" ] && ok \
  || bad "job_pr_facts changed the first six fields: $F1 $F2 $F3 $F4 $F5 $F6"
[ "$F7" = 3 ] && ok || bad "job_pr_facts did not carry repairs (got '$F7')"
# A row from before the count existed reports "-", never 0.
jq 'del(.repairs)' "$FIX_VERDICT" > "$T/v2.json" && mv "$T/v2.json" "$FIX_VERDICT"
IFS=$'\t' read -r _ _ _ _ _ _ F7 F8 <<<"$(job_pr_facts https://github.com/Acme/widget-os/pull/11)"
[ "$F7" = "-" ] && ok || bad "an unmeasured build must read '-' rather than 0 (got '$F7')"

echo "repair-rounds-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
