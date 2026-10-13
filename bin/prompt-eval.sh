#!/bin/bash
# bin/prompt-eval.sh <project|TEMPLATE-GH> [--scenario <name>] [--runner <r>]
#                    [--baseline [--force-baseline]] [--cron] [--list] [--dry-run]
#
# PROMPT/SOP REGRESSION EVALS (Wave E). The fleet's triage prompts carry the
# decision policy — ready-to-build vs waiting-on-client, launch vs queue,
# duplicate-work guard, HOLD — and until now they changed with ZERO regression
# testing. A prompt edit that quietly drops a guard produces no error, no failed
# build and no alert; the first symptom is a twin PR or a ticket built off an
# unanswered thread, days later, on a client's board.
#
# So: recorded board/queue/results states under catalog/fixtures/golden/, the
# REAL triage prompt composed over each one, and CODE-BASED grading of the
# DECISION lines the session emits. No model judges another model here — the
# grade is a set-membership test on an action verb, which is the only kind of
# grade that means the same thing next month.
#
# SIDE-EFFECT FREEDOM IS MECHANICAL, NOT PROMPT TEXT. The session under test is
# the very thing that might be broken, so "the prompt says do not act" is not a
# control. Three layers, in order of how much they are worth:
#   1. AGENT_CALL_NO_TOOLS=1 — agent-call.sh runs claude with `--tools ""` and
#      refuses every runner that cannot enforce that (see its contract block).
#   2. the invocation env is scrubbed of board/gh/db credentials, so even a
#      session that somehow got a shell has nothing to authenticate with.
#   3. the prompt envelope, which is defense-in-depth ONLY and is never counted
#      as the guard.
#
# WHAT THIS MEASURES, HONESTLY. It measures the SOP's DECISION POLICY, not the
# tick's tool use. So it can catch a dropped guard, a flipped decision table, a
# lost precedence rule; it cannot catch a broken curl or a wrong API path. Those
# belong to the live tick.
#
# COSTS REAL TOKENS BY DESIGN. Every scenario is one metered LLM call on stage
# `eval` (declared in catalog/context-budgets.json, so its spend lands in
# cost.csv under its own lane rather than hiding inside triage). Never wire this
# into per-PR CI — see docs/PROMPT-EVALS.md for the per-run cost estimate.
#
# Exit: 0 = graded, no regression beyond the threshold (or no baseline yet).
#       1 = pass-rate regression vs state/prompt-eval-baseline.json.
#       2 = the eval could not run, or ran over less than it used to.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=prompt-eval

SELF=$(cd "$(dirname "$0")" && pwd)
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-prompt-eval
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off prompt-eval.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit prompt-eval
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    prompt-eval
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# ---------------------------------------------------------------------------
# >>> prompt_eval_grade
# THE GRADER. Pure: text in, a verdict out. No harness paths, no network, no
# model. tests/prompt-eval-grade-test.sh extracts this block by the markers
# above/below and drives it directly, which is why the expensive half of this
# script can stay out of CI while the half that decides what the answers MEAN is
# proven on every run of the suite.

# grade_scenario <expected-file> <decisions-file>
#   expected.txt : one line per ticket key -> `KEY :: action[|action...]`
#                  (# comments and blank lines ignored)
#   decisions    : the session's raw output; DECISION: lines are harvested the
#                  same way bin/decision-log.sh harvests them.
#   stdout       : PASS/FAIL/WARN lines, then `TOTAL <passed> <expected> malformed=<n>`
#   rc           : 0 iff every expected key was decided, and decided only with
#                  allowed actions.
#
# THE POLICIES, each one a decision rather than an accident:
#   MISSING is a FAIL. A session that says nothing about a ticket has not
#     handled it. Reading silence as a pass makes the eval greener the quieter
#     the model gets — the dead-feed smell wearing an eval's clothes.
#   EVERY emitted action must be allowed (changed 2026-08-25, review I1 — this
#     is a deliberate re-pin, not a silent weakening). The first version passed
#     a key if ANY of its actions matched, so `launch` + `comment` satisfied an
#     expectation of `skip|defer|comment`: a session that launched a duplicate
#     build and then posted about it scored full marks on the scenario written
#     to catch exactly that. An action the SOP forbids is a failure whatever
#     else the session also did.
#   EXTRA is a WARN. A triage tick may legitimately decide on a ticket the
#     fixture does not pin (one a scoped thread depends on).
#   MALFORMED is counted and never credited. A line that does not parse cannot
#     satisfy an expected key, so the key it was meant for reports MISSING.
#   A DUPLICATE expected key REFUSES the scenario. Two lines for one key means
#     one of them is silently ignored, and a fixture that grades something other
#     than what it appears to say is worse than no fixture.
grade_scenario() {
  local exp="$1" dec="$2"
  awk -v EXP="$exp" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN {
      nexp = 0; bad_exp = 0
      while ((getline line < EXP) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*#/ || trim(line) == "") continue
        i = index(line, "::")
        if (i == 0) { printf "WARN malformed-expected %s\n", trim(line); bad_exp = 1; continue }
        k = trim(substr(line, 1, i - 1))
        a = tolower(substr(line, i + 2)); gsub(/[ \t]/, "", a)
        if (k == "" || a == "") { printf "WARN malformed-expected %s\n", trim(line); bad_exp = 1; continue }
        if (k in allowed) { printf "WARN duplicate-expected %s\n", k; bad_exp = 1; continue }
        order[++nexp] = k
        allowed[k] = a
      }
      close(EXP)
    }
    {
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^[ \t]*DECISION:/) next
      sub(/^[ \t]*DECISION:[ \t]*/, "", line)
      n = split(line, parts, /::/)
      if (n < 2) { printf "WARN malformed %s\n", trim(line); nmal++; next }
      k = trim(parts[1]); a = tolower(trim(parts[2])); gsub(/[ \t]/, "", a)
      if (k == "" || a == "") { printf "WARN malformed %s\n", trim(line); nmal++; next }
      seen[k] = seen[k] " " a
    }
    END {
      np = 0
      for (i = 1; i <= nexp; i++) {
        k = order[i]
        if (!(k in seen)) { printf "FAIL %s MISSING want=%s\n", k, allowed[k]; continue }
        m = split(allowed[k], al, /\|/)
        g = split(seen[k], got, / +/)
        ok = 1; ngot = 0
        for (y = 1; y <= g; y++) {
          if (got[y] == "") continue
          ngot++
          hit = 0
          for (x = 1; x <= m; x++) if (got[y] == al[x]) hit = 1
          if (!hit) ok = 0
        }
        if (ok && ngot > 0) { printf "PASS %s %s\n", k, trim(seen[k]); np++ }
        else                 printf "FAIL %s %s want=%s\n", k, trim(seen[k]), allowed[k]
      }
      for (k in seen) if (!(k in allowed)) printf "WARN extra %s %s\n", k, trim(seen[k])
      printf "TOTAL %d %d malformed=%d\n", np, nexp, nmal + 0
      # nexp == 0, a malformed expected file or a duplicate key grades NOTHING.
      # Reporting that as a pass is the empty-result-set lie: 0 of 0 is not green.
      exit (np == nexp && nexp > 0 && bad_exp == 0) ? 0 : 1
    }
  ' "$dec"
}

# baseline_verdict <observed-pct> <baseline-pct|-|""> <max-drop-pp>
#   rc 0 = within the band (or no baseline recorded yet), rc 1 = regression.
#
# The rule is "fail if the rate drops MORE than max-drop", so a drop of exactly
# max-drop passes. Implementing it as >= fails a healthy fleet on the boundary
# every week, and a gate that cries wolf gets re-baselined into silence — which
# is how a regression gate stops being one.
baseline_verdict() {
  local obs="$1" base="$2" maxdrop="${3:-2}"
  if [ -z "$base" ] || [ "$base" = "-" ] || [ "$base" = "null" ]; then
    printf 'NOBASELINE observed=%s%% — recorded only, nothing to compare against yet\n' "$obs"
    return 0
  fi
  awk -v o="$obs" -v b="$base" -v d="$maxdrop" 'BEGIN {
    drop = b - o
    if (drop <= d + 1e-9) {
      printf "OK observed=%.1f%% baseline=%.1f%% drop=%.1fpp (allowed %.1fpp)\n", o, b, (drop < 0 ? 0 : drop), d
      exit 0
    }
    printf "REGRESSION observed=%.1f%% baseline=%.1f%% drop=%.1fpp exceeds %.1fpp\n", o, b, drop, d
    exit 1
  }'
}

# coverage_verdict <scored-expected-count> <baseline-expected-count|-|"">
#   rc 0 = graded at least as much as last time, rc 1 = the run shrank.
#
# THE RATE IS A FRACTION AND NOBODY READS THE DENOMINATOR. Six of eight
# scenarios erroring out leaves two that pass and a headline of 100% — better
# than the baseline, so the gate stays quiet on a run that graded a quarter of
# the policy. A shrinking denominator is a failure in its own right, reported
# separately from the rate, because the two mean completely different things.
coverage_verdict() {
  local scored="$1" base="$2"
  if [ -z "$base" ] || [ "$base" = "-" ] || [ "$base" = "null" ]; then
    printf 'COVERAGE-UNKNOWN scored=%s (no baseline count to compare)\n' "$scored"
    return 0
  fi
  awk -v s="$scored" -v b="$base" 'BEGIN {
    if (s + 0 >= b + 0) { printf "COVERAGE-OK scored=%d baseline=%d\n", s, b; exit 0 }
    printf "COVERAGE-SHRANK scored=%d baseline=%d — %d expected decisions were never graded; the pass rate is computed over a smaller set and is NOT comparable\n", s, b, b - s
    exit 1
  }'
}

# scrub_env_names — reads env var NAMES on stdin, prints the ones an eval call
# must not inherit.
#
# LAYER 2 of side-effect freedom. The tool ban is the real control; this is what
# stands if the ban is ever inert. Pattern-based rather than a hand-list,
# because a hand-list of credentials is out of date the day a project is added —
# and the keep-list is narrow on purpose: runner auth stays (the call cannot
# happen without it), everything that opens a board, a repo or a database goes.
# Database shapes include *_SERVICE_ROLE_KEY (Supabase), *_DB_URL / DB_URL and
# POSTGRES_URL / POSTGRES_PRISMA_URL / POSTGRES_URL_NON_POOLING (Vercel Postgres).
scrub_env_names() {
  grep -E '(TOKEN|SECRET|PASSWORD|CREDENTIAL|WEBHOOK|DATABASE_URL|_PAT$|APIKEY|_API_KEY$|^GH_|^GITHUB_|_SERVICE_ROLE_KEY$|(^|_)DB_URL|POSTGRES_(PRISMA_)?URL)' \
    | grep -vE '^(ANTHROPIC_|CLAUDE_)'
}
# <<< prompt_eval_grade
# ---------------------------------------------------------------------------

usage() { sed -n '2,8p' "$0"; exit 2; }
die() { echo "prompt-eval: $*" >&2; exit 2; }

PROJECT=""; ONE_SCENARIO=""; RUNNER=""; WRITE_BASELINE=0; FORCE_BASELINE=0
CRON=0; LIST=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario)       ONE_SCENARIO="${2:?}"; shift 2 ;;
    --runner)         RUNNER="${2:?}"; shift 2 ;;
    --baseline)       WRITE_BASELINE=1; shift ;;
    --force-baseline) WRITE_BASELINE=1; FORCE_BASELINE=1; shift ;;
    --cron)           CRON=1; shift ;;
    --list)           LIST=1; shift ;;
    --dry-run)        DRY=1; shift ;;
    -h|--help)        usage ;;
    -*)               echo "unknown flag: $1" >&2; usage ;;
    *)                PROJECT="$1"; shift ;;
  esac
done

# Re-baselining the whole fleet unattended is how a regression becomes the new
# normal without anyone deciding that it should.
[ "$WRITE_BASELINE" = 1 ] && [ "$CRON" = 1 ] \
  && die "--baseline with --cron is refused: recording a baseline is a deliberate act, one project at a time."

command -v jq >/dev/null || die "jq is required (scenario metadata is JSON). Refusing rather than running with the board-shape and project filters silently disabled."

# Paths resolve for BOTH homes: the deployed harness (/root/harness, which gets
# bin/ + prompts/ from fly-sync-harness) and a plain repo checkout, where
# catalog/ actually lives. catalog/ is deliberately not synced to builders, so
# the fixtures are found via the checkout when the harness copy has none.
pick_dir() { for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }; done; return 1; }
pick_file() { for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; return 1; }

GOLD=$(pick_dir "${PROMPT_EVAL_FIXTURES:-}" "$HARNESS/catalog/fixtures/golden" \
                "/root/harness-checkout/catalog/fixtures/golden" "$SELF/../catalog/fixtures/golden") \
  || die "no golden fixtures found (set PROMPT_EVAL_FIXTURES)"
STATE=$(pick_dir "$HARNESS/state" "$SELF/../state") || { mkdir -p "$SELF/../state"; STATE="$SELF/../state"; }
BASEFILE="${PROMPT_EVAL_BASELINE:-$STATE/prompt-eval-baseline.json}"
ALERTS="$HARNESS/logs/ALERTS.log"
MAX_DROP="${PROMPT_EVAL_MAX_DROP:-2}"
EVAL_STAGE="eval"   # agent-call.sh stage + the lane name in catalog/context-budgets.json
EVAL_TIMEOUT="${PROMPT_EVAL_TIMEOUT:-1800}"
# Test seam: tests/prompt-eval-compose-test.sh points this at a recorder so the
# composed argv, env and prompt can be asserted without spending a token.
AGENT_CALL="${PROMPT_EVAL_AGENT_CALL:-$SELF/agent-call.sh}"

# --runner picks the lane the same way the stages do: agent-call.sh reads
# RUNNER_<STAGE>. Exported here rather than inlined as an assignment prefix,
# because a prefix built by ${VAR:+...} is not recognised as an assignment and
# would be run as a command name.
[ -n "$RUNNER" ] && export RUNNER_EVAL="$RUNNER"
# The no-tools contract only holds on claude today (agent-call.sh refuses the
# rest). Say so HERE, before any fixture work, rather than letting the refusal
# surface as N mysterious per-scenario errors.
EFFECTIVE_RUNNER="${RUNNER_EVAL:-claude}"
[ "$EFFECTIVE_RUNNER" = "claude" ] || die "runner '$EFFECTIVE_RUNNER' cannot enforce the no-tools contract — only the claude lane has a tool-disable flag. Refusing to run eval sessions with live credentials and working tools."

alert_keyed() { # alert_keyed <project> <akey> <line> — ALERTS.log + a fleet_alert beat
  local p="$1" akey="$2" line="$3"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$p] $line" >> "$ALERTS" 2>/dev/null
  [ -x "$SELF/beat.sh" ] && "$SELF/beat.sh" "$(jq -nc --arg p "$p" \
    --arg akey "$akey" --arg l "$line" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}

alert() { # alert <project> <line>  — ALERTS.log + a fleet_alert beat, together
  alert_keyed "$1" "prompteval:$1:$(date -u +%Y%m%d)" "$2"
}

# A project's BOARD SHAPE is a property of its SOP; a scenario's `project` is
# what it was actually recorded against. Both are checked, and they answer
# different questions — see scenarios().
project_shape() { # project_shape <project>
  local bp
  case "$1" in
    TEMPLATE-GH) printf 'gh-issues'; return 0 ;;
    TEMPLATE)    printf 'board-api'; return 0 ;;
  esac
  bp=$("$SELF/fleet-conf.sh" "$1" board_prefix 2>/dev/null || echo "")
  case "$bp" in ""|"-") printf 'gh-issues' ;; *) printf 'board-api' ;; esac
}

# scenarios [project] — the scenarios that apply to a project.
#
# SCOPED TO meta.project (review I5). A fixture's board text names a real repo
# slug, a real prod domain and that project's ticket-key prefix, so grading a
# project-1 SOP against project-2-flavoured board JSON measures the mismatch,
# not the prompt — the session would spend the tick correctly noticing the board
# is not its own. Board shape is checked too, as a CONSISTENCY assertion rather
# than a filter: a scenario whose declared shape disagrees with its project's is
# a broken fixture, and it is refused rather than skipped.
scenarios() {
  local want="${1:-}" d n mp ms shape=""
  [ -n "$want" ] && shape=$(project_shape "$want")
  for d in "$GOLD"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [ -n "$ONE_SCENARIO" ] && [ "$n" != "$ONE_SCENARIO" ] && continue
    [ -f "$d/meta.json" ] || { echo "prompt-eval: $n has no meta.json — skipping" >&2; continue; }
    mp=$(jq -r '.project // ""' "$d/meta.json" 2>/dev/null)
    ms=$(jq -r '.board_shape // "any"' "$d/meta.json" 2>/dev/null)
    if [ -n "$want" ]; then
      [ "$mp" = "$want" ] || continue
      [ "$ms" = "any" ] || [ "$ms" = "$shape" ] || {
        echo "prompt-eval: FIXTURE INCONSISTENT — $n declares board_shape=$ms but project $want is $shape" >&2
        continue; }
    fi
    printf '%s\n' "$n"
  done
}

if [ "$LIST" = 1 ]; then
  for s in $(scenarios "${PROJECT:-}"); do
    printf '%-34s %s\n' "$s" "$(jq -r '"gate=" + .gate + "  " + .note' "$GOLD/$s/meta.json" 2>/dev/null)"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# PROMPT COMPOSITION — the same shape bin/run-triage.sh builds for a live tick:
# the project SOP, wrapped in the gate's TICK SCOPE preamble, with the
# AGENT_SYSTEM_APPEND decision-log contract attached.
#
# ONE DELIBERATE DIVERGENCE (review B1d), and it is load-bearing: the live
# preambles end by telling the session that if the scope looks inconsistent it
# should "discard the scope and run the full SOP instead" — i.e. go enumerate
# the whole board. Against a fixture, which is inconsistent BY CONSTRUCTION
# (three tickets exist, one is scoped), that sentence is an instruction to go
# fetch a real client's board. It is REPLACED here, never merely contradicted
# later by the envelope. tests/prompt-eval-grade-test.sh section 12 pins the
# rest of every preamble verbatim against run-triage.sh AND asserts this
# replacement, so the divergence cannot grow silently.
#
# TODO(dedup): the preambles below are replicated from bin/run-triage.sh
# L151-203 rather than shared, because Wave B was editing that file this round.
# The next touch of run-triage.sh should factor them into one file both callers
# source, parameterised on the tail sentence. Note for whoever does it: the live
# queue/sweep preambles also append $BOARD_SEC when the board moved during a
# queue/sweep tick, and the eval composes only the EMPTY-BOARD_SEC variant — a
# scenario for the board-moved-under-a-queue-tick case would need that branch.
# ---------------------------------------------------------------------------
EVAL_TAIL="If anything in the scope list looks inconsistent with the BOARD STATE above, say so in that ticket's DECISION reason and decide on what you can see. Do NOT fall back to enumerating a board, and do NOT fetch anything: the BOARD STATE above is the entire world for this tick and this session has no tools."

compose_prompt() { # compose_prompt <sop-file> <gate> <scope-file> <scope2-file> <inputs-file>
  local sop="$1" gate="$2" scopef="$3" scope2f="$4" inputs="$5"
  local PROMPT_TEXT SCOPE SCOPE2
  PROMPT_TEXT="$(cat "$sop")"
  SCOPE="$( [ -f "$scopef" ] && cat "$scopef" )"
  SCOPE2="$( [ -f "$scope2f" ] && cat "$scope2f" )"

  case "$gate" in
    board-changed)
      [ -n "$SCOPE" ] && PROMPT_TEXT="TICK SCOPE (deterministic — computed by diffing the board fingerprint since the last consumed tick):
$SCOPE

Work ONLY the tickets listed above this tick: fetch each one's full comment thread and act on it per the SOP below. SKIP the full board/ticket enumeration the SOP opens with — unchanged tickets have not moved since the last consumed run and owe nothing new. You MAY fetch any other specific ticket that a changed thread references or depends on. Queue and build-results handling in the SOP still applies as written. $EVAL_TAIL

$PROMPT_TEXT"
      ;;
    queue-pending)
      PROMPT_TEXT="TICK SCOPE (queue — deterministic): this tick fired because queue-side state changed, not the board. The queue right now:
READY-QUEUE lines:
${SCOPE:-(none)}
Queued launch requests for <project> (from the coordination DB):
${SCOPE2:-(none)}

Work ONLY the queue this tick, per the SOP's queue and launch rules: for each line, verify its gating condition against reality (blocking PR merged? in-flight build finished? free slots per free-slots.sh <project> — its first word, where 'unlimited' means this project is Fly-routed and the local slot gate does not apply?), launch what is genuinely unblocked, drop lines that are satisfied or superseded, leave the rest. Results-sweep rules still apply to any finished build you encounter. Fetch ONLY the board tickets these lines name (a key that does not resolve on this project's board belongs to another lane on this box — ignore it) — SKIP the full board/ticket enumeration: the board fingerprint was re-checked at the start of this tick.
$EVAL_TAIL

$PROMPT_TEXT"
      ;;
    results-sweep|remote-results-pending)
      PROMPT_TEXT="TICK SCOPE (results sweep — deterministic): this tick fired because these finished builds await their board close-out (dir :: first RESULT line):
$SCOPE

Handle ONLY these result dirs this tick, per the SOP's sweep rules: read each dir's RESULT in full, post the close-out comment on its ticket (direct production links included), set the ticket's status, mark the dir COMMENTED. Queue rules still apply to any launch these close-outs unblock. Fetch ONLY the tickets these dirs name — SKIP the full board/ticket enumeration: the board fingerprint was re-checked at the start of this tick.
$EVAL_TAIL

$PROMPT_TEXT"
      ;;
    *) : ;;   # daily-sweep / forced keep full context, exactly as the tick does
  esac

  # THE EVAL ENVELOPE — defense in depth, never the control. The tool ban in
  # agent-call.sh and the scrubbed env are what actually make this safe; these
  # words only make the session's job legible.
  printf '%s\n' "EVAL MODE — READ THIS FIRST, IT OVERRIDES THE SOP'S EXECUTION INSTRUCTIONS.

This is a recorded regression scenario, not a live tick. Nothing you decide here reaches a board, a repo or a client. This session has NO TOOLS: there is nothing to run, fetch or post, and no credentials to do it with.

1. The BOARD STATE section below is the complete reality of this tick. It is exactly what the SOP's fetches would have returned.
2. Reason exactly as the SOP tells you to, over that data.
3. Your entire reply is the DECISION block: one line per ticket you would act on or deliberately skip, in the exact format the decision-log contract specifies. No preamble, no summary line, no explanation outside the reasons.

===== BOARD STATE (this tick's reality) =====
$(cat "$inputs")
===== END BOARD STATE =====

$PROMPT_TEXT"
}

# The eval must grade the contract the live tick actually ships, including the
# words that ask for the DECISION lines. This used to be a hand-copied literal
# whose comment cited a run-triage.sh line number that had already moved; both
# lanes now read the one file, so "the eval graded a different SOP than the
# fleet runs" is no longer a reachable state.
SYS_APPEND="$("$SELF/triage-contract.sh")"
# An eval that graded the scenarios WITHOUT the contract would score the model on
# a prompt the fleet never ships, and would do it while reporting pass rates that
# look perfectly normal — a silently wrong benchmark is worse than none.
[ -n "$SYS_APPEND" ] || die "triage-contract.sh returned nothing: catalog/agent-contracts/triage-system-append.txt is missing or empty, and grading without the live contract would measure a prompt the fleet does not run"

# MODEL FIDELITY (review I4). run-triage.sh routes results-sweep and
# remote-results-pending to TRIAGE_MODEL_LIGHT and everything else to the
# judgment model. An eval that graded every scenario on the strong model would
# be measuring a prompt/model pair the fleet never runs — and the sweep lane is
# precisely where a cheaper model is most likely to drop a rule.
#
# BH-1510.2: the roles are run-triage's own — `triage.light` for the sweeps,
# `triage` for judgment — resolved for the PROJECT under eval, so a project
# override is graded on the model that project really runs. PROMPT_EVAL_MODEL*
# then TRIAGE_MODEL* still win when set. No route = rc 75 and the project is
# not graded (bin/lib/model-route.sh alerted the role): grading on a guessed
# model is the silently wrong benchmark this file refuses everywhere else.
model_for_gate() { # model_for_gate <gate> [project]
  . "$SELF/lib/lane-model.sh"
  case "$1" in
    results-sweep|remote-results-pending)
      if [ -n "${PROMPT_EVAL_MODEL_LIGHT:-}" ]; then printf '%s' "$PROMPT_EVAL_MODEL_LIGHT"; return 0; fi
      lane_model TRIAGE_MODEL_LIGHT triage.light "${2:-}" ;;
    *)
      if [ -n "${PROMPT_EVAL_MODEL:-}" ]; then printf '%s' "$PROMPT_EVAL_MODEL"; return 0; fi
      lane_model TRIAGE_MODEL triage "${2:-}" ;;
  esac
}

run_project() { # run_project <project> -> prints the table, sets EV_*
  local project="$1" sop run_dir n gate exp out grade rc model
  sop=$(pick_file "$HARNESS/prompts/$project.md" "$SELF/../prompts/$project.md") || {
    echo "  no prompt file for '$project' (looked in $HARNESS/prompts and $SELF/../prompts)"; return 2; }
  # PID-suffixed, because a second-resolution stamp is not unique: two runs in
  # the same second shared a directory, the second run found the FIRST run's
  # non-empty .out files still sitting there, and graded them. An eval that can
  # score a previous run's answers is not measuring the prompt it just composed
  # — caught as a flaky assertion in tests/prompt-eval-compose-test.sh, which is
  # the only reason it was ever visible.
  run_dir="$STATE/prompt-eval/$project/$(date -u +%Y%m%d%H%M%S)-$$"
  mkdir -p "$run_dir"
  EV_PASSED=0; EV_TOTAL=0; EV_SCENARIOS=""; EV_ERRORS=0; EV_RUNDIR="$run_dir"

  # Layer 2 of side-effect freedom, computed from THIS process's environment so
  # it covers whatever env/<project>.env put there.
  local -a SCRUB=()
  while IFS= read -r v; do [ -n "$v" ] && SCRUB+=(-u "$v"); done < <(compgen -e | scrub_env_names | sort)
  # ${SCRUB[@]+...}: bash < 4.4 under set -u calls an empty array unbound.
  printf '%s\n' ${SCRUB[@]+"${SCRUB[@]}"} > "$run_dir/env-scrub.txt" 2>/dev/null

  for n in $(scenarios "$project"); do
    gate=$(jq -r '.gate // "daily-sweep"' "$GOLD/$n/meta.json" 2>/dev/null || echo daily-sweep)
    model=$(model_for_gate "$gate" "$project") \
      || { echo "  no model route for gate '$gate' (rc 75) — $project not graded"; return 75; }
    exp="$GOLD/$n/expected.txt"
    out="$run_dir/$n.out"
    compose_prompt "$sop" "$gate" "$GOLD/$n/scope.txt" "$GOLD/$n/scope-2.txt" "$GOLD/$n/inputs.md" \
      > "$run_dir/$n.prompt"
    if [ "$DRY" = 1 ]; then
      printf '  %-30s DRY  prompt=%sB gate=%s model=%s\n' "$n" \
        "$(wc -c < "$run_dir/$n.prompt" | tr -d ' ')" "$gate" "$model"
      continue
    fi
    # Belt and braces on the same hazard: the outfile is truncated before the
    # call, so "the runner produced nothing" can never be satisfied by a file
    # that was already there.
    : > "$out"
    # Rides agent-call.sh so the spend lands in cost.csv on the `eval` stage.
    # AGENT_CALL_NO_TOOLS=1 is the control; the env scrub is the second layer.
    # @file form: the composed prompt is well over the 128KB argv ceiling.
    env ${SCRUB[@]+"${SCRUB[@]}"} AGENT_SYSTEM_APPEND="$SYS_APPEND" AGENT_CALL_NO_TOOLS=1 \
      "$AGENT_CALL" "$EVAL_STAGE" "$project" "$model" \
        "$EVAL_TIMEOUT" "$out" "@$run_dir/$n.prompt" >/dev/null 2>&1
    rc=$?
    # AN ERROR DUMP IS NOT AN ANSWER (2026-09-16). The empty-outfile test above
    # caught only half of "the runner produced nothing". When the claude CLI
    # returns no `.result` — a dead credential, a usage cap, a CLI error —
    # agent-call.sh writes `cat $OUT.json $OUT.err > $OUT`, so the outfile is
    # NON-empty, holds no DECISION line, and bills nothing. The eval runner then
    # graded twenty of those as "the session said nothing about the pinned
    # ticket" and announced VERDICT: REGRESSION over an auth outage (cromford
    # PR #473, run 35097060207: 20/20 <no decision>, $0.0000 spend, 52 seconds).
    # A false regression is worse than a red: it invites the next agent to
    # rewrite expected.txt, which would bake an outage into the fixtures.
    #
    # The tell is agent-call's own: it dumps precisely when `.result` is absent,
    # so `$out.json` without `.result` is that branch, read at the source rather
    # than guessed at from the prose. The two named refusal banners are the same
    # non-answer by another route. A runner that writes no `.json` envelope at
    # all (the test seam's fake) is untouched — prose with no DECISION line is
    # still a FAIL, because that session really did run and really was silent.
    local eval_unrun=""
    [ -s "$out" ] || eval_unrun="no output"
    if [ -z "$eval_unrun" ] && [ -f "$out.json" ] && ! jq -e '.result' "$out.json" >/dev/null 2>&1; then
      eval_unrun="runner returned no result envelope"
    fi
    if [ -z "$eval_unrun" ] && head -c 200 "$out" | grep -qE '^(AGENT_CALL_REFUSED|AGENT_CALL_NO_HEADROOM)'; then
      eval_unrun=$(head -c 200 "$out" | head -1)
    fi
    if [ -n "$eval_unrun" ]; then
      # A lane that produced nothing is NOT a scored zero — it is an unrun
      # scenario, and scoring it would let an outage read as a prompt
      # regression. Counted as an error and reflected in the coverage check.
      printf '  %-30s ERROR  runner rc=%s, %s (scenario NOT scored)\n' "$n" "$rc" "$eval_unrun"
      # What the runner actually said, so the cause is in the log rather than in
      # a scratch file the CI runner throws away. The first line is skipped when
      # it is the JSON envelope: agent-call writes `cat $OUT.json $OUT.err`, so
      # the message a person needs — "Invalid API key", "usage limit reached",
      # a timeout — is the prose UNDER it.
      local said=""
      [ -s "$out" ] && said=$(head -20 "$out" | grep -vE '^[[:space:]]*([{[]|$)' | head -1 | cut -c1-160)
      # No prose under the envelope (an empty .err) left this line blank on
      # main at f83ca87f, so the cause of the one ERROR was unknowable. The
      # envelope names it itself: subtype, is_error, api_error_status.
      [ -z "$said" ] && [ -s "$out.json" ] && said=$(jq -rc \
        '{subtype, is_error, api_error_status, num_turns, duration_ms, total_cost_usd} | with_entries(select(.value != null)) | "envelope: \(.)"' \
        "$out.json" 2>/dev/null | head -1 | cut -c1-200)
      [ -n "$said" ] && printf '  %-30s        runner said: %s\n' "" "$said"
      EV_SCENARIOS="$EV_SCENARIOS$n=error "; EV_ERRORS=$((EV_ERRORS + 1))
      continue
    fi
    # Harvested exactly as bin/decision-log.sh harvests a live tick.
    grep -a '^DECISION:' "$out" 2>/dev/null | head -40 | cut -c1-330 > "$run_dir/$n.decisions"
    grade=$(grade_scenario "$exp" "$run_dir/$n.decisions"); rc=$?
    printf '%s\n' "$grade" > "$run_dir/$n.grade"
    local p t
    p=$(awk '/^TOTAL /{print $2}' <<<"$grade"); t=$(awk '/^TOTAL /{print $3}' <<<"$grade")
    EV_PASSED=$((EV_PASSED + ${p:-0})); EV_TOTAL=$((EV_TOTAL + ${t:-0}))
    EV_SCENARIOS="$EV_SCENARIOS$n=${p:-0}/${t:-0} "
    printf '  %-30s %s  %s/%s  %s\n' "$n" \
      "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "${p:-0}" "${t:-0}" \
      "$(grep -E '^(FAIL|WARN)' <<<"$grade" | head -3 | tr '\n' ';')"
  done

  [ "$DRY" = 1 ] && return 0
  EV_RATE=$(awk -v p="$EV_PASSED" -v t="$EV_TOTAL" 'BEGIN{printf "%.1f", (t>0 ? 100*p/t : 0)}')
  return 0
}

read_baseline() { # read_baseline <project> <field> -> value or "-"
  [ -f "$BASEFILE" ] || { printf '-'; return 0; }
  jq -r --arg p "$1" --arg f "$2" '.projects[$p][$f] // "-"' "$BASEFILE" 2>/dev/null || printf '-'
}

write_baseline() { # write_baseline <project> <rate> <passed> <total> <scenarios>
  local old_rate old_exp tmp
  old_rate=$(read_baseline "$1" pass_rate); old_exp=$(read_baseline "$1" expected)
  mkdir -p "$(dirname "$BASEFILE")"
  [ -f "$BASEFILE" ] || printf '%s\n' '{"_doc":"Recorded pass rates for bin/prompt-eval.sh. Re-baselining is a DELIBERATE act: see docs/PROMPT-EVALS.md. A baseline written to silence a regression erases the only record that the prompt used to do better.","projects":{}}' > "$BASEFILE"
  tmp="$BASEFILE.tmp.$$"
  jq --arg p "$1" --argjson r "$2" --argjson pa "$3" --argjson t "$4" \
     --arg s "$5" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg host "$(hostname)" \
     '.projects[$p] = {pass_rate:$r, passed:$pa, expected:$t, scenarios:$s, recorded_at:$ts, host:$host}' \
     "$BASEFILE" > "$tmp" && mv -f "$tmp" "$BASEFILE" || return 1
  # EVERY overwrite is logged, including the innocent ones. A baseline is the
  # only record that the prompt used to do better; a change to it that leaves no
  # trace is indistinguishable from one made to silence a gate.
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$1] PROMPT EVAL BASELINE REWRITTEN: pass_rate $old_rate -> $2, expected $old_exp -> $4 (force=$FORCE_BASELINE, host=$(hostname))" >> "$ALERTS" 2>/dev/null
  return 0
}

eval_one() { # eval_one <project> -> rc 0 ok / 1 regression / 2 could not run
  local project="$1" base base_exp verdict cov rc crc
  # Cleared per project, so a cron alert for a project that produced no
  # artifacts cannot point at the PREVIOUS project's directory.
  EV_RUNDIR=""; EV_RATE=""; EV_TOTAL=0; EV_PASSED=0; EV_ERRORS=0
  # WHY a project could not be graded. All four causes below exit 2, but they are
  # not the same event: "no fixtures have ever been recorded for this project" is
  # a standing, documented, human-owned debt, while the other three mean the
  # machinery broke on a project that DOES have coverage. Collapsing them cost a
  # weekly page per uncovered project (7 of 9 on 2026-08-31) that no lane could
  # ever clear, which is what the medic then churned on all night.
  EV_WHY=""
  echo "prompt-eval: $project  (fixtures: $GOLD)"
  if [ -z "$(scenarios "$project")" ]; then
    echo "  NO SCENARIOS recorded for $project — not evaluated. This is a coverage gap, not a pass."
    EV_WHY="no-scenarios"; return 2
  fi
  run_project "$project" || { EV_WHY="run-failed"; return 2; }
  [ "$DRY" = 1 ] && return 0
  if [ "$EV_TOTAL" -eq 0 ]; then
    echo "  NOTHING GRADED — no scenario produced a scored result. Not a pass."
    EV_WHY="nothing-graded"; return 2
  fi
  base=$(read_baseline "$project" pass_rate)
  base_exp=$(read_baseline "$project" expected)
  verdict=$(baseline_verdict "$EV_RATE" "$base" "$MAX_DROP"); rc=$?
  cov=$(coverage_verdict "$EV_TOTAL" "$base_exp"); crc=$?
  printf '  %s/%s expected decisions correct = %s%%\n  %s\n  %s\n  artifacts: %s\n' \
    "$EV_PASSED" "$EV_TOTAL" "$EV_RATE" "$verdict" "$cov" "$EV_RUNDIR"
  [ "$EV_ERRORS" -gt 0 ] && printf '  %s scenario(s) errored and were not scored\n' "$EV_ERRORS"

  if [ "$WRITE_BASELINE" = 1 ]; then
    # THE FRICTION IS THE POINT. Re-baselining on top of a regression is how a
    # gate gets disabled without anyone deciding to disable it, so it takes a
    # second, explicit flag and it says why.
    if { [ "$rc" != 0 ] || [ "$crc" != 0 ]; } && [ "$FORCE_BASELINE" != 1 ]; then
      echo "  BASELINE REFUSED: this run is a regression or graded less than the last one."
      echo "  If the new answers are genuinely the correct ones, change the fixture's expected.txt"
      echo "  and say so in the PR. To record anyway: --force-baseline (logged to ALERTS.log)."
      EV_WHY="baseline-refused"
      return "$([ "$rc" != 0 ] && echo 1 || echo 2)"
    fi
    write_baseline "$project" "$EV_RATE" "$EV_PASSED" "$EV_TOTAL" "$EV_SCENARIOS" \
      && echo "  baseline recorded in $BASEFILE"
  fi
  [ "$crc" != 0 ] && { EV_WHY="coverage-shrank"; return 2; }
  return "$rc"
}

if [ "$CRON" = 1 ]; then
  # Weekly hub run. PROMPT_EVAL_PROJECTS pins the set; default is every project
  # in fleet.conf that actually has a prompt file. Each project is one metered
  # run — see the cost note in docs/PROMPT-EVALS.md before widening this.
  PROJECTS="${PROMPT_EVAL_PROJECTS:-$("$SELF/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')}"
  if [ -z "${PROJECTS// /}" ]; then
    # An empty project list produced a silent rc=0 run that evaluated nothing —
    # a green cron line meaning "fleet.conf was unreadable".
    alert prompt-eval "PROMPT EVAL DID NOT RUN: the project list is empty (fleet.conf unreadable or PROMPT_EVAL_PROJECTS blank). Nothing was evaluated; this is not a clean bill of health."
    exit 2
  fi
  # ATTEMPTED counts every project this cron actually ran, so the coverage alert
  # can state an honest denominator. GRADED counts only rc 0 and 1, so
  # "GRADED + uncovered" silently omits projects that failed some OTHER way —
  # reporting "7 of 8" when the cron set is 9. This file's own coverage_verdict
  # exists to stop exactly that kind of flattering arithmetic.
  WORST=0; GRADED=0; ATTEMPTED=0; SKIPPED=""; NOCOV=""
  for P in $PROJECTS; do
    pick_file "$HARNESS/prompts/$P.md" "$SELF/../prompts/$P.md" >/dev/null || continue
    ATTEMPTED=$((ATTEMPTED + 1))
    eval_one "$P"; RC=$?
    case "$RC" in
      0) GRADED=$((GRADED + 1)) ;;
      1) GRADED=$((GRADED + 1)); WORST=1
         alert "$P" "PROMPT EVAL REGRESSION: $P scored $EV_RATE% on the golden scenarios, below its recorded baseline by more than ${MAX_DROP}pp. A prompt/SOP change has moved the decision policy — see $EV_RUNDIR. Do NOT re-baseline to clear this." ;;
      *) SKIPPED="$SKIPPED $P"
         if [ "$EV_WHY" = "no-scenarios" ]; then
           NOCOV="$NOCOV $P"       # rolled up below into ONE alert for the set
         else
           alert "$P" "PROMPT EVAL DID NOT RUN for $P ($EV_WHY): the project HAS golden scenarios but this run produced no scored result. This is a broken gate, not a coverage gap — see ${EV_RUNDIR:-no artifacts}."
         fi ;;
    esac
  done
  [ -n "$SKIPPED" ] && echo "prompt-eval: not evaluated:$SKIPPED (see ALERTS.log)"
  # ── COVERAGE DEBT IS ONE FACT, NOT N PAGES (2026-08-31) ────────────────────
  # Projects with no golden fixtures are a single standing debt that only a human
  # can pay down (recording fixtures is a repo PR). Paging once per project every
  # Monday produced seven un-actionable alerts that no automated lane could
  # resolve, and the medic then re-verified each of them around the clock. This
  # says the same true thing once, and keys the alert on the SET — so it re-pages
  # exactly when the set changes (a project gains coverage, or a new project
  # joins the fleet uncovered) and is silent while the debt is merely unchanged.
  # Nothing is suppressed: the console row stays open until the set changes, the
  # per-project detail is in this run's stdout, and the digest reports it daily.
  if [ -n "$NOCOV" ]; then
    NOCOV_SORTED=$(printf '%s\n' $NOCOV | sort | tr '\n' ' ')
    NOCOV_SORTED="${NOCOV_SORTED% }"
    NOCOV_N=$(printf '%s\n' $NOCOV | grep -c .)
    # Hash via python3 — already a hard dependency of this lane, and unlike a
    # `shasum || sha1sum` pair it cannot fail silently: a missing binary in the
    # middle of a pipe still exits 0 through `cut`, yielding an EMPTY key that
    # would collide every set with every other one.
    NOCOV_KEY=$(printf '%s' "$NOCOV_SORTED" | python3 -c \
      'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:12])' 2>/dev/null)
    # A key we could not compute must not become one shared key for all sets.
    [ -n "$NOCOV_KEY" ] || NOCOV_KEY="unhashed-$(printf '%s' "$NOCOV_SORTED" | tr -c 'a-z0-9' '-' | cut -c1-40)"
    alert_keyed prompt-eval "prompteval-coverage:$NOCOV_KEY" \
      "PROMPT EVAL COVERAGE DEBT: $NOCOV_N of the $ATTEMPTED cron projects have ZERO golden scenarios and were not graded — $NOCOV_SORTED. This is a coverage gap, NOT a clean bill of health: their SOPs are ungated. Paying it down is a repo act (record fixtures under catalog/fixtures/golden per docs/PROMPT-EVALS.md); no harness lane can clear this alert, so it is stated once and re-fires only when this set changes."
  fi
  if [ "$GRADED" -eq 0 ]; then
    alert prompt-eval "PROMPT EVAL DID NOT RUN: not one project in the cron set produced a graded result. The weekly regression gate is dark."
    exit 2
  fi
  exit "$WORST"
fi

[ -n "$PROJECT" ] || usage
eval_one "$PROJECT"
exit $?
