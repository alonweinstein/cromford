#!/bin/bash
# bin/lib/plan-failure-modes.sh — the failure-mode checklist (BH-5800). Sourced,
# never executed. 47 of the 66 logic-bug BLOCK findings in the 2026-10
# review-block analysis (48 of them in bin/) fell into six patterns a plan can
# answer before any code: a decision rule matching the wrong cases, an exit
# path that leaves a stuck state or burns a budget, a writer and a reader that
# disagree on a format, an alert with no bound on its blast radius (665 pages
# on the first tick, #5160), an unsafe default in prod, and a status line that
# says done when nothing happened. The checklist is data:
# catalog/plan-failure-modes.tsv (its header has the format).
#
# pfm_check <plan.md> <catalog>
#   A plan that names a path the catalog's scope rows match (outside
#   `## Sibling claims`, fenced blocks included) must carry `## Failure
#   modes`, with one bullet or heading per catalog heading. Each answer names
#   its acceptance test (the word "test"), or is `n/a` with a reason of at
#   least one word. Prints one `  UNTRACED: failure modes — <label>: <why>`
#   line per gap, then `PLAN_FAILURE_MODES: ok | missing | n/a | unread`.
#   rc 0 ok, n/a or unread (a gate that cannot read its rules never refuses),
#   2 missing.
# pfm_labels [catalog]        the heading labels, one a line.
# pfm_plan_rule [catalog]     the planner's instruction, rendered from the catalog.
# pfm_repair_note <gate-out>  the repair-pass sentence for the gaps in a
#                             bin/plan-gate.sh output, or nothing.
# The default catalog is ${PLAN_FAILURE_MODES_CATALOG}, else
# ${HARNESS:-${H:-}}/catalog/plan-failure-modes.tsv; with no root, none.
# shellcheck shell=bash

[ -n "${_PFM_LIB_LOADED:-}" ] && return 0
_PFM_LIB_LOADED=1

_pfm_cat() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  if [ -n "${PLAN_FAILURE_MODES_CATALOG:-}" ]; then printf '%s' "$PLAN_FAILURE_MODES_CATALOG"; return 0; fi
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s' "$root/catalog/plan-failure-modes.tsv"
}

pfm_labels() {
  local cat
  cat=$(_pfm_cat "${1:-}") && [ -r "$cat" ] || return 1
  awk -F'\t' '$1 == "heading" {print $4}' "$cat"
}

pfm_plan_rule() {
  local cat
  cat=$(_pfm_cat "${1:-}") && [ -r "$cat" ] || return 0
  awk -F'\t' -v q="'" '
    $1 == "scope" { s = s (s ? " or " : "") $4 }
    $1 == "heading" { h = h sprintf("%s%s — %s", (h ? "; " : ""), $4, $5) }
    END {
      if (h == "") exit
      printf "FAILURE MODES (prompts/plan-contract.md §13): if this plan changes %s, it MUST carry a %s section with one bullet per heading, each %s or %s, and each answer becomes an acceptance test: %s. bin/plan-gate.sh refuses a plan that changes %s without it. ", \
        s, q "## Failure modes" q, q "- <Label>: <answer>. Test: <the acceptance test>" q, q "- <Label>: n/a — <why it does not apply>" q, h, s
    }' "$cat"
}

pfm_repair_note() {
  local gaps
  gaps=$(sed -n 's/^  UNTRACED: failure modes — //p' "${1:-/dev/null}" 2>/dev/null | tr '\n' ';' | sed 's/;$//')
  [ -n "$gaps" ] || return 0
  printf " The plan also needs its '## Failure modes' section (prompts/plan-contract.md §13), because it changes bin/ or worker/. These answers are missing or incomplete: %s. Write one bullet per heading: '- <Label>: <answer>. Test: <the acceptance test>' or '- <Label>: n/a — <why it does not apply>'." "$gaps"
}

pfm_check() {
  local plan="${1:-}" cat
  cat=$(_pfm_cat "${2:-}")
  if [ -z "$cat" ] || [ ! -r "$cat" ]; then echo "PLAN_FAILURE_MODES: unread"; return 0; fi
  [ -r "$plan" ] || { echo "PLAN_FAILURE_MODES: unread"; return 0; }
  awk -F'\t' '
    function strip(s) {
      gsub(/^[ \t]+/, "", s); sub(/^#+[ \t]*/, "", s)
      sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", s); gsub(/\*\*/, "", s)
      gsub(/[ \t]+$/, "", s); return s
    }
    FILENAME == ARGV[1] {
      if ($0 ~ /^#/) next
      if ($1 == "scope") scope[++ns] = $3
      if ($1 == "heading") { nh++; hid[nh] = $2; hre[nh] = $3; hlab[nh] = $4 }
      next
    }
    {
      line = $0
      # Fences first: a fence line, or any line inside ``` / ~~~, is never a
      # heading, so a `# comment` in a fenced answer or sibling list neither
      # closes the section nor ends the sibling-claims exclusion.
      isfence = (line ~ /^[ \t]*(```|~~~)/)
      if (isfence) fence = 1 - fence
      ishead = (!fence && !isfence && line ~ /^#+[ \t]/)
      if (ishead) {
        match(line, /^#+/); lvl = RLENGTH; t = tolower(strip(line))
        if (lvl <= 2) sib = (t ~ /^sibling claims/)
        if (infm && lvl <= fmlvl) infm = 0
        if (t ~ /^failure[- ]modes/) { infm = 1; fmlvl = lvl; cur = 0; hasfm = 1; next }
      }
      if (!sib) for (i = 1; i <= ns; i++) if (line ~ scope[i]) need = 1
      if (!infm || fence || isfence) next
      t = strip(line); lt = tolower(t)
      # Only a heading or a bullet with NO indent can open a checklist entry.
      # A nested sub-bullet (a decision-table row like "  - status row: match")
      # is part of the current answer, never a heading of its own (lead review
      # lr-5841-f1d23c19b02a).
      if (ishead || line ~ /^([-*+]|[0-9]+[.)])[ \t]+/) {
        for (i = 1; i <= nh; i++) if (!(i in seen) && lt ~ hre[i]) {
          seen[i] = 1; cur = i
          c = t; if (index(c, ":") > 0) c = substr(c, index(c, ":") + 1); else c = ""
          body[i] = c; next
        }
      }
      if (cur) body[cur] = body[cur] " " t
    }
    END {
      if (!need) { print "PLAN_FAILURE_MODES: n/a"; exit 0 }
      bad = 0
      for (i = 1; i <= nh; i++) {
        lab = tolower(hlab[i])
        if (!(i in seen)) { why = hasfm ? "not answered" : "no ## Failure modes section" }
        else {
          b = tolower(body[i]); gsub(/^[ \t:;.,—–-]+/, "", b)
          if (b ~ /^n\/a/) {
            r = substr(b, 4); gsub(/^[ \t:;.,—–-]+/, "", r)
            why = (r ~ /[a-z][a-z][a-z]/) ? "" : "n/a with no reason"
          } else if (b !~ /[a-z][a-z][a-z]/) why = "no answer"
          else if (b !~ /(^|[^a-z])tests?([^a-z]|$)/) why = "no acceptance test named"
          else why = ""
        }
        if (why != "") { printf "  UNTRACED: failure modes — %s: %s\n", lab, why; bad++ }
      }
      print "PLAN_FAILURE_MODES: " (bad ? "missing" : "ok")
      exit (bad ? 2 : 0)
    }' "$cat" "$plan"
}
