#!/bin/bash
# tests/prompt-eval-fixtures.bh-122-test.sh — BH-122: the golden scenario sets
# for project-1, project-3, project-4, project-8 and project-6, plus the
# two scrub nits in bin/prompt-eval.sh.
#
# Drives the real CLI (bin/prompt-eval.sh) with a RECORDER in place of
# agent-call.sh, the same contract tests/prompt-eval-compose-test.sh uses. No
# LLM call, no network, no spend.
#
#   §1 each new set is scoped to its project, consistent with its board shape
#   §2 each new set composes under --dry-run with its own SOP and slug
#   §3 each new set grades: perfect answers pass, a forbidden launch FAILs,
#      silence is MISSING
#   §4 the new fixtures are sanitized (own key prefix, example.com, no
#      project-2 copy-paste)
#   §5 the scrub covers *_SERVICE_ROLE_KEY / *_DB_URL / POSTGRES_*URL and
#      still keeps runner auth
#   §6 the empty-SCRUB expansions are guarded (bash < 4.4 under set -u)
# Run from anywhere: tests/prompt-eval-fixtures.bh-122-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/rec/answers"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

GOLD="$DIR/catalog/fixtures/golden"
PE="$DIR/bin/prompt-eval.sh"

# project -> expected scenario count, board shape, repo slug, key prefix
NEW_PROJECTS="project-1 project-3 project-4 project-8 project-6"
want_count() { case "$1" in project-6) echo 2 ;; *) echo 4 ;; esac; }
want_shape() { case "$1" in project-6) echo gh-issues ;; *) echo board-api ;; esac; }
want_slug()  { case "$1" in
  project-1) echo example-org/project-1 ;; project-3) echo example-org/project-3 ;;
  project-4) echo example-org/project-4 ;; project-8) echo example-org/project-8 ;;
  project-6) echo example-org/project-6-runtime ;; esac; }
want_prefix() { case "$1" in
  project-1|project-8|project-3|project-4|project-6) echo TK ;; esac; }

cat > "$T/rec/agent-call-recorder.sh" <<'EOF'
#!/bin/bash
S=$(basename "$5" .out)
printf 'stage=%s project=%s model=%s scenario=%s\n' "$1" "$2" "$3" "$S" >> "$REC/calls.txt"
env | sed 's/=.*//' | sort > "$REC/env-$S.txt"
[ -f "$REC/answers/$S" ] && cp "$REC/answers/$S" "$5"
exit 0
EOF
chmod +x "$T/rec/agent-call-recorder.sh"

# answer <mode>: perfect = first allowed action per key; launch = launch for
# every key; silent = prose with no DECISION line.
answer() {
  rm -f "$T/rec/answers"/*
  for S in "$GOLD"/*/; do
    N=$(basename "$S")
    case "$1" in
      silent) echo "I read the board and everything looks fine." > "$T/rec/answers/$N" ;;
      *) awk -v mode="$1" '/^[ \t]*(#|$)/{next} { i=index($0,"::"); k=$0; sub(/[ \t]*::.*/,"",k)
            a=substr($0,i+2); gsub(/[ \t]/,"",a); split(a,p,"|")
            printf "DECISION: %s :: %s :: canned\n", k, (mode=="launch" ? "launch" : p[1]) }' \
            "$S/expected.txt" > "$T/rec/answers/$N" ;;
    esac
  done
}
run_pe() { # run_pe <args...> -> rc on stdout; output in $T/run.out, stderr in $T/run.err
  ( export REC="$T/rec" HARNESS="$T" FLEET_CONF="$DIR/fleet.conf" \
           PROMPT_EVAL_FIXTURES="$GOLD" \
           PROMPT_EVAL_AGENT_CALL="$T/rec/agent-call-recorder.sh" \
           PROMPT_EVAL_BASELINE="$T/state/baseline.json" \
           TRIAGE_MODEL=claude-fable-5 TRIAGE_MODEL_LIGHT=claude-sonnet-5
    bash "$PE" "$@" > "$T/run.out" 2> "$T/run.err" )
  echo $?
}

# --- §1 scoping and consistency ---------------------------------------------
for P in $NEW_PROJECTS; do
  RC=$(run_pe --list "$P")
  [ "$RC" = 0 ] && ok || bad "§1 --list $P rc=$RC"
  N=$(grep -c . "$T/run.out")
  [ "$N" = "$(want_count "$P")" ] && ok || bad "§1 $P lists $N scenarios, want $(want_count "$P"): $(cat "$T/run.out")"
  grep -q 'FIXTURE INCONSISTENT' "$T/run.err" && bad "§1 $P has an inconsistent fixture: $(cat "$T/run.err")" || ok
  for S in $(awk '{print $1}' "$T/run.out"); do
    MP=$(jq -r .project "$GOLD/$S/meta.json"); MS=$(jq -r .board_shape "$GOLD/$S/meta.json")
    [ "$MP" = "$P" ] && ok || bad "§1 $S meta.project=$MP, want $P"
    [ "$MS" = "$(want_shape "$P")" ] && ok || bad "§1 $S board_shape=$MS, want $(want_shape "$P")"
  done
done
# the new dirs did not leak into the two projects that already had coverage
RC=$(run_pe --list project-2); N=$(grep -c . "$T/run.out")
[ "$N" = 8 ] && ok || bad "§1 project-2 now lists $N scenarios, want 8"
RC=$(run_pe --list project-5); N=$(grep -c . "$T/run.out")
[ "$N" = 2 ] && ok || bad "§1 project-5 now lists $N scenarios, want 2"

# --- §2 dry-run composition --------------------------------------------------
for P in $NEW_PROJECTS; do
  : > "$T/rec/calls.txt"
  RC=$(run_pe "$P" --dry-run)
  [ "$RC" = 0 ] && ok || bad "§2 $P --dry-run rc=$RC: $(tail -5 "$T/run.out")"
  N=$(grep -c ' DRY ' "$T/run.out")
  [ "$N" = "$(want_count "$P")" ] && ok || bad "§2 $P composed $N prompts, want $(want_count "$P")"
  [ ! -s "$T/rec/calls.txt" ] && ok || bad "§2 --dry-run made a call for $P"
  RUN=$(ls -td "$T/state/prompt-eval/$P"/*/ 2>/dev/null | head -1)
  NP=0
  for F in "$RUN"*.prompt; do
    [ -f "$F" ] || continue
    NP=$((NP+1))
    grep -qF 'You are the board watcher' "$F" && ok || bad "§2 $(basename "$F"): the $P SOP is not in the composed prompt"
    grep -qF "$(want_slug "$P")" "$F" && ok || bad "§2 $(basename "$F"): the $P repo slug is not in the composed prompt"
    grep -qF 'discard the scope and run the full SOP instead' "$F" \
      && bad "§2 $(basename "$F"): the live discard-scope escape hatch leaked into the eval prompt" || ok
  done
  [ "$NP" = "$(want_count "$P")" ] && ok || bad "§2 $P wrote $NP prompt files"
done

# --- §3 grading against synthetic output ------------------------------------
for P in $NEW_PROJECTS; do
  rm -f "$T/state/baseline.json"
  answer perfect
  RC=$(run_pe "$P" --baseline)
  [ "$RC" = 0 ] && ok || bad "§3 $P perfect answers rc=$RC: $(tail -8 "$T/run.out")"
  grep -q 'expected decisions correct = 100.0%' "$T/run.out" && ok || bad "§3 $P perfect answers did not score 100: $(tail -8 "$T/run.out")"
  # launch for every key: every scenario that forbids launch must FAIL, and the
  # run is a regression against the perfect baseline
  answer launch
  RC=$(run_pe "$P")
  [ "$RC" != 0 ] && ok || bad "§3 $P launching everything exited 0"
  for S in "$GOLD"/*/; do
    N=$(basename "$S"); [ "$(jq -r .project "$S/meta.json")" = "$P" ] || continue
    if grep -vE '^[ \t]*(#|$)' "$S/expected.txt" | grep -qE '::.*\blaunch\b'; then
      grep -qE "^  $N +PASS" "$T/run.out" && ok || bad "§3 $N allows launch but did not PASS on launch"
    else
      grep -qE "^  $N +FAIL" "$T/run.out" && ok || bad "§3 $N forbids launch but a launch answer did not FAIL: $(grep "$N" "$T/run.out")"
    fi
  done
  # silence is MISSING, never credited
  answer silent
  RC=$(run_pe "$P")
  [ "$RC" != 0 ] && ok || bad "§3 $P silent answers exited 0"
  grep -q 'MISSING' "$T/run.out" && ok || bad "§3 $P silent answers were not reported MISSING"
  grep -q 'expected decisions correct = 0.0%' "$T/run.out" && ok || bad "§3 $P silent answers were credited: $(tail -6 "$T/run.out")"
done
# each guard pins the action set its SOP rule demands, so a fixture edited to
# expect a forbidden answer is caught here rather than graded as correct
want_actions() { case "$1" in
  *-board-changed-ready-launch)       echo launch ;;
  *-board-changed-waiting-on-client)  echo skip ;;
  *-dup-launch-guard-open-pr)         echo 'skip|defer|comment' ;;
  *-results-sweep-review-blocked)     echo 'skip|escalate' ;;
  project-6-gh-blocked-by-open)       echo 'skip|defer' ;;
  *) echo '?' ;; esac; }
for P in $NEW_PROJECTS; do
  for S in "$GOLD"/*/; do
    N=$(basename "$S"); [ "$(jq -r .project "$S/meta.json")" = "$P" ] || continue
    GOT=$(grep -vE '^[ \t]*(#|$)' "$S/expected.txt" | sed 's/.*::[ \t]*//; s/[ \t]//g')
    NK=$(grep -cvE '^[ \t]*(#|$)' "$S/expected.txt")
    [ "$NK" = 1 ] && ok || bad "§3 $N pins $NK keys, want exactly 1"
    [ "$GOT" = "$(want_actions "$N")" ] && ok || bad "§3 $N expects '$GOT', its guard demands '$(want_actions "$N")'"
  done
done
# at least the guards the plan names exist per project
for P in project-1 project-3 project-4 project-8; do
  for G in board-changed-ready-launch board-changed-waiting-on-client dup-launch-guard-open-pr results-sweep-review-blocked; do
    [ -d "$GOLD/$P-$G" ] && ok || bad "§3 missing scenario $P-$G"
  done
done
for G in gh-board-changed-ready-launch gh-blocked-by-open; do
  [ -d "$GOLD/project-6-$G" ] && ok || bad "§3 missing scenario project-6-$G"
done

# --- §4 sanitization lint (the new dirs only) --------------------------------
for S in "$GOLD"/*/; do
  N=$(basename "$S"); P=$(jq -r .project "$S/meta.json")
  case " $NEW_PROJECTS " in *" $P "*) ;; *) continue ;; esac
  PFX=$(want_prefix "$P")
  grep -qF "$(want_slug "$P")" "$S/inputs.md" && ok || bad "§4 $N inputs.md never names $(want_slug "$P")"
  OTHER=$(cat "$S/inputs.md" "$S/expected.txt" "$S/scope.txt" 2>/dev/null \
    | grep -oiE '(^|[^A-Za-z0-9])(TK)-[0-9]+' | sed 's/^[^A-Za-z]*//' \
    | grep -viE "^$PFX-" | sort -u | tr '\n' ' ')
  [ -z "$OTHER" ] && ok || bad "§4 $N carries another project's key prefix: $OTHER"
  LOW=$(grep -vE '^[ \t]*(#|$)' "$S/expected.txt" | sed 's/[ \t]*::.*//' | sed "s/^$PFX-//" \
    | awk '$1+0 < 7000' | tr '\n' ' ')
  [ -z "$LOW" ] && ok || bad "§4 $N pins a ticket number below 7000 (could be a real one): $LOW"
  EM=$(grep -ohE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+' "$S/inputs.md" | grep -vE '@example\.com$' | tr '\n' ' ')
  [ -z "$EM" ] && ok || bad "§4 $N has a non-example.com email: $EM"
  grep -qiE 'acme project-2' "$S/inputs.md" "$S/expected.txt" "$S/meta.json" \
    && bad "§4 $N still carries project-2 template text" || ok
done

# --- §5 scrub shapes ---------------------------------------------------------
awk '/^# >>> prompt_eval_grade/{f=1;next} /^# <<< prompt_eval_grade/{exit} f' "$PE" > "$T/grade.sh"
grep -q 'scrub_env_names()' "$T/grade.sh" && ok || bad "§5 could not extract scrub_env_names"
SCRUBBED=$(printf '%s\n' SUPABASE_SERVICE_ROLE_KEY PROJECT_2_DB_URL DB_URL POSTGRES_URL \
  POSTGRES_URL_NON_POOLING POSTGRES_PRISMA_URL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN \
  PATH HOME HARNESS PROMPT_EVAL_MAX_DROP SUPABASE_URL NEXT_PUBLIC_SUPABASE_URL \
  | bash -c '. "$0"; scrub_env_names' "$T/grade.sh")
for MUST in SUPABASE_SERVICE_ROLE_KEY PROJECT_2_DB_URL DB_URL POSTGRES_URL POSTGRES_URL_NON_POOLING POSTGRES_PRISMA_URL; do
  grep -qx "$MUST" <<<"$SCRUBBED" && ok || bad "§5 env scrub misses $MUST"
done
for KEEP in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PATH HOME HARNESS PROMPT_EVAL_MAX_DROP SUPABASE_URL NEXT_PUBLIC_SUPABASE_URL; do
  grep -qx "$KEEP" <<<"$SCRUBBED" && bad "§5 env scrub removes $KEEP" || ok
done
# end to end: the session under test never sees them
answer perfect; rm -f "$T/rec"/env-*.txt
RC=$( export SUPABASE_SERVICE_ROLE_KEY=x PROJECT_2_DB_URL=x POSTGRES_URL=x ANTHROPIC_API_KEY=keep-me; run_pe project-1 )
NENV=$(ls "$T/rec"/env-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$NENV" = 4 ] && ok || bad "§5 expected 4 recorded eval calls for project-1, got $NENV (rc=$RC)"
LEAK=""
for F in "$T/rec"/env-*.txt; do
  for V in SUPABASE_SERVICE_ROLE_KEY PROJECT_2_DB_URL POSTGRES_URL; do grep -qx "$V" "$F" && LEAK="$LEAK $V"; done
  grep -qx ANTHROPIC_API_KEY "$F" || LEAK="$LEAK (ANTHROPIC_API_KEY-scrubbed)"
done
[ -z "$LEAK" ] && ok || bad "§5 scrub wrong at the eval call:$(echo "$LEAK" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

# --- §6 the empty-SCRUB expansions are guarded ------------------------------
# bash < 4.4 under `set -u` dies on "${SCRUB[@]}" when the array is empty. CI
# runs bash 5, which does not, so the static check is what pins it.
BARE=$(grep -n '"\${SCRUB\[@\]}"' "$PE" | grep -vF '${SCRUB[@]+"${SCRUB[@]}"}')
[ -z "$BARE" ] && ok || bad "§6 unguarded SCRUB expansion: $BARE"
NG=$(grep -cF '${SCRUB[@]+"${SCRUB[@]}"}' "$PE")
[ "$NG" -ge 2 ] && ok || bad "§6 expected the guarded expansion at both sites, found $NG"
# driven: a dry run and a graded run with nothing credential-shaped in the env
rm -rf "$T/state/prompt-eval/project-3"
env -i PATH="$PATH" HOME="$HOME" HARNESS="$T" FLEET_CONF="$DIR/fleet.conf" \
  PROMPT_EVAL_FIXTURES="$GOLD" PROMPT_EVAL_MODEL=m PROMPT_EVAL_MODEL_LIGHT=m \
  PROMPT_EVAL_BASELINE="$T/state/none.json" PROMPT_EVAL_AGENT_CALL="$T/rec/agent-call-recorder.sh" \
  REC="$T/rec" bash "$PE" project-3 --dry-run > "$T/run.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "§6 dry run with an empty scrub list rc=$RC: $(tail -4 "$T/run.out")"
ES=$(ls -td "$T/state/prompt-eval/project-3"/*/ 2>/dev/null | head -1)env-scrub.txt
[ -f "$ES" ] && ! grep -q . "$ES" && ok || bad "§6 env-scrub.txt should list nothing: $(cat "$ES" 2>/dev/null)"
env -i PATH="$PATH" HOME="$HOME" HARNESS="$T" FLEET_CONF="$DIR/fleet.conf" \
  PROMPT_EVAL_FIXTURES="$GOLD" PROMPT_EVAL_MODEL=m PROMPT_EVAL_MODEL_LIGHT=m \
  PROMPT_EVAL_BASELINE="$T/state/none.json" PROMPT_EVAL_AGENT_CALL="$T/rec/agent-call-recorder.sh" \
  REC="$T/rec" bash "$PE" project-3 > "$T/run.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "§6 graded run with an empty scrub list rc=$RC: $(tail -4 "$T/run.out")"

echo "prompt-eval-fixtures.bh-122-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
