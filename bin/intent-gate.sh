#!/bin/bash
# bin/intent-gate.sh <build-dir>
#
# Mechanize the intent declaration. Before its first behavior-changing edit the
# executor must state, in one line, WHERE the intended behavior comes from and
# whether the sources agree:
#
#   INTENT: <file:line | spec | docstring | ticket quote> :: agree
#   INTENT: <source> :: CONFLICT: <which sides disagree, which one is being
#                                 trusted, and why>
#   INTENT: none (no behavior change)          <- docs-only / config-only builds
#
# WHY A GATE AND NOT JUST A PROMPT. The expensive builds are not the ones that
# implement the wrong thing loudly; they are the ones where two sources of truth
# disagreed — a docstring against a ticket, a plan against a schema, a test
# against a comment — and the builder silently picked one, shipped, and left the
# reviewer to discover the choice by reading the diff against the wrong side.
# Making the pick EXPLICIT costs one line and turns a hidden decision into an
# adjudicable one. A declared CONFLICT is this gate working, not failing.
#
# WARN FIRST, ENFORCE LATER. INTENT_GATE_ENFORCE defaults to 0: this gate never
# blocks, it only feeds GATES_NOTE into the review prompt. The flip plan is
# deliberate and dated:
#
#   Week 1 (from 2026-08-26): INTENT_GATE_ENFORCE=0 everywhere. Collect
#     GATES_NOTE lines across the fleet and count how often the line is absent,
#     malformed, or a CONFLICT. That count is the argument for or against
#     enforcing — a rule the builders cannot actually satisfy blocks builds for
#     a prompt bug, and shipping enforcement on day one is how you find that out
#     the expensive way.
#   After a week of data: if absence is rare and malformation rarer, set
#     INTENT_GATE_ENFORCE=1 in env/global.env (the env file run-build.sh sources
#     `set -a` — NOT fleet.conf, which is a positional project registry whose
#     first column is read as a project name) so a diff-producing build with NO
#     intent line reuses REVIEW_BLOCKED. Malformed and CONFLICT never block —
#     they are the reviewer's to adjudicate, not a machine's.
#
#   The readout that decides it, run on the hub (remote builds land in builds/
#     too, via fly-results-ingest):
#       grep -ho 'intent=[0-9]*' /root/harness/builds/*/pipeline.log \
#         | sort | uniq -c | sort -rn
#     0=declared 1=MISSING 2=malformed 3=could-not-run 4=conflict 5=none.
#     Nothing aggregates this on its own yet; the manual grep is the v1.
#
# The discipline itself is D34 in prompts/build-discipline.md.
#
# READS ONLY THE EXECUTE OUTPUT ($BUILD/execute-run.txt), which is the agent's
# final message. A resumed build that skipped EXECUTE has no such file, and the
# honest answer there is "could not run" — never "you skipped it".
#
# NEVER PARSE AGENT TEXT WITH A SHELL. Everything here is bash string ops and
# printf '%s'; no eval, no command substitution on file content, no `bash -c`.
# The input is written by an LLM that was steered by client-authored ticket
# text, so a line reading `INTENT: $(rm -rf /) :: agree` is reachable.
#
# exit 0  INTENT declared, well-formed, sources agree
# exit 1  NO INTENT line at all — the discipline was skipped (the only
#         block-eligible outcome, and only under INTENT_GATE_ENFORCE=1)
# exit 2  present but malformed (no source, no `::` half, or a right side that
#         is neither agree nor a substantiated CONFLICT) — record, never block
# exit 3  could not run (no build dir, no/empty execute output) — never block
# exit 4  CONFLICT declared — the reviewer must adjudicate which side was
#         trusted; never a block, this is the gate paying for itself
# exit 5  "none (no behavior change)" declared — the diff is the check on that
set -uo pipefail

MAX_LINES="${INTENT_GATE_MAX_LINES:-8}"   # bound what can reach the review prompt
MAX_CHARS=300

BUILD="${1:-}"
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
  echo "GATE_UNAVAILABLE no build dir: ${BUILD:-<none>}"
  echo "INTENT_VERDICT: unavailable"
  exit 3
fi
SRC="$BUILD/execute-run.txt"
if [ ! -s "$SRC" ]; then
  echo "GATE_UNAVAILABLE no execute output at $SRC (resumed build, or EXECUTE never ran) — intent was NOT checked"
  echo "INTENT_VERDICT: unavailable"
  exit 3
fi

# Candidate lines: anything carrying an INTENT: marker, however the agent
# dressed it (bullet, bold, blockquote). -a so a binary-ish log still greps.
CANDIDATES=$(grep -a 'INTENT:' "$SRC" 2>/dev/null | head -50)
if [ -z "$CANDIDATES" ]; then
  echo "GATE FAILED — no INTENT line in the execute output."
  echo "The executor never stated where the intended behavior came from, so any"
  echo "disagreement between the ticket, the code, and the docs was resolved"
  echo "silently. See D34 in prompts/build-discipline.md."
  echo "INTENT_VERDICT: missing"
  exit 1
fi

trim() { # trim <string> — leading/trailing whitespace and markdown dressing
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  s="${s#\*\*}"; s="${s%\*\*}"
  s="${s#\`}"; s="${s%\`}"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

SAW_AGREE=0; SAW_CONFLICT=0; SAW_NONE=0
REPORT=""; SHOWN=0

while IFS= read -r RAW; do
  [ "$SHOWN" -lt "$MAX_LINES" ] || break
  case "$RAW" in *INTENT:*) ;; *) continue ;; esac
  REST="${RAW#*INTENT:}"
  REST=$(trim "$REST")
  REST="${REST#\*\*}"          # `**INTENT:** src...` leaves a stray closer here
  REST=$(trim "$REST")
  [ "${#REST}" -le "$MAX_CHARS" ] || REST="${REST:0:$MAX_CHARS}…"

  KIND=malformed
  case "$REST" in
    none|none\ *|none\(*)
      KIND=none ;;
    *::*)
      LEFT=$(trim "${REST%%::*}")
      RIGHT=$(trim "${REST#*::}")
      LEFT="${LEFT%\`}"; LEFT=$(trim "$LEFT")
      if [ -z "$LEFT" ]; then
        KIND=malformed
      else
        case "$RIGHT" in
          agree|agree\ *|agree.|AGREE|AGREE\ *)
            KIND=agree ;;
          CONFLICT:*)
            [ -n "$(trim "${RIGHT#CONFLICT:}")" ] && KIND=conflict || KIND=malformed ;;
          *) KIND=malformed ;;
        esac
      fi ;;
  esac

  # No counter for malformed: it is the fallthrough verdict at the bottom, and
  # a variable nothing reads is the dead code D25 asks you to catch in your own
  # diff.
  case "$KIND" in
    agree)    SAW_AGREE=1 ;;
    conflict) SAW_CONFLICT=1 ;;
    none)     SAW_NONE=1 ;;
  esac
  REPORT="$REPORT"$'\n'"  [$KIND] INTENT: $REST"
  SHOWN=$((SHOWN + 1))
done <<< "$CANDIDATES"

# PRECEDENCE. A declared conflict outranks everything: it is the one outcome a
# human has to rule on, and a build that also declared a clean intent elsewhere
# does not make the conflict go away. Then a real declaration, then the
# docs-only claim, and malformed last — a line that says nothing parseable is
# the weakest thing in the file, not a veto over the ones that do.
if [ "$SAW_CONFLICT" = 1 ]; then
  echo "CONFLICT DECLARED — the builder found the sources of truth disagreeing and named the side it trusted:"
  printf '%s\n' "${REPORT#$'\n'}"
  echo "INTENT_VERDICT: conflict"
  exit 4
fi
if [ "$SAW_AGREE" = 1 ]; then
  echo "INTENT DECLARED — the builder named its source and the sources agree:"
  printf '%s\n' "${REPORT#$'\n'}"
  echo "INTENT_VERDICT: declared"
  exit 0
fi
if [ "$SAW_NONE" = 1 ]; then
  echo "NO BEHAVIOR CHANGE CLAIMED — the builder declared this diff carries none:"
  printf '%s\n' "${REPORT#$'\n'}"
  echo "INTENT_VERDICT: none"
  exit 5
fi
echo "MALFORMED — an INTENT line is present but does not name a source and a ruling:"
printf '%s\n' "${REPORT#$'\n'}"
echo "Expected: INTENT: <file:line|spec|docstring> :: agree   |   :: CONFLICT: <sides, which one trusted, why>   |   INTENT: none (no behavior change)"
echo "INTENT_VERDICT: malformed"
exit 2
