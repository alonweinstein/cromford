#!/bin/bash
# guardrails/lib/escape-hatch.sh — the ONE escape hatch, shared by every check.
#
# A guardrail with no way out gets deleted the first time it is wrong. A
# guardrail with a silent way out is decoration. So every check in this catalog
# can be skipped, and skipping it costs a label plus a written reason that stays
# in the PR record where a reviewer sees it.
#
# Source this and call:  guardrail_escape_hatch <check-name>
#   rc 0  -> skipped: the PR carries the `skip-guardrail` label AND a real
#            written justification. The reason is printed.
#   rc 1  -> not skipped: run the check.
#
# Inputs (CI sets these; both are required, neither alone is enough):
#   PR_LABELS               comma/space separated PR labels
#   GUARDRAIL_JUSTIFICATION text containing a `Guardrail-Justification:` line
#
# TWO THINGS THIS DELIBERATELY REFUSES, both found by review:
#
#  1. WHITESPACE. An earlier version counted characters, so twenty-five spaces
#     was a valid reason to disable a security check. The marker line's payload
#     is stripped before it is measured, and a blank payload is no payload.
#
#  2. THE WHOLE PR BODY. The natural CI wiring is
#     GUARDRAIL_JUSTIFICATION: ${{ github.event.pull_request.body }} — which
#     makes ANY body, including an empty-ish one, a justification, and it is
#     the line every drafted check copies. So a bare blob is not accepted:
#     the text must carry an explicit `Guardrail-Justification: <reason>` line.
#     Someone has to type that sentence on purpose. (bin/guardrail-promote.sh
#     refuses to open a PR for a drafted step that wires the raw body at all.)
#
# A label with no justification fails LOUDLY rather than skipping: "I said skip"
# is not a reason, and letting it through would make the label the whole gate.
guardrail_escape_hatch() {
  local check="${1:-guardrail}" labels="${PR_LABELS:-}" why="${GUARDRAIL_JUSTIFICATION:-}"
  local reason
  case ",${labels//[[:space:]]/,}," in
    *,skip-guardrail,*) ;;
    *) return 1 ;;
  esac
  # Take only the marker line's payload, then strip surrounding whitespace.
  # One awk, not grep|sed: the match and the strip must share ONE definition of
  # the marker, or a case the matcher accepts and the stripper misses leaves the
  # marker text itself standing in as the "reason" (24 chars — passes the length
  # check with an empty actual payload). tolower/substr are POSIX awk.
  reason=$(printf '%s\n' "$why" | awk '{
    s=$0; sub(/^[[:space:]]+/, "", s)
    if (tolower(substr(s, 1, 24)) == "guardrail-justification:") { print substr(s, 25); exit }
  }')
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  if [ "${#reason}" -lt 20 ]; then
    echo "GUARDRAIL $check: 'skip-guardrail' label present, but no usable justification."
    echo "  Add a line to the PR body reading:"
    echo "    Guardrail-Justification: <at least 20 characters of actual reason>"
    echo "  Whitespace does not count, and neither does the label on its own. Not skipping."
    return 1
  fi
  echo "GUARDRAIL $check: SKIPPED via skip-guardrail label."
  echo "  Justification: $reason"
  return 0
}
