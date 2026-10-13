#!/bin/bash
# bin/lib/caller-check.sh — the caller check after the build's main merge.
# Sourced, never executed. bin/caller-check.sh is the CLI; the `caller check`
# block in bin/lib/rb/pr.sh runs it after the rebase verify and puts
# cc_section into the PR body, and item 13 of prompts/lead-review-checklist.md
# tells the lead to read it.
#
# WHY. After #4332 merged main, bin/data-lane-apply.sh still read the old pause
# file: a caller of a changed interface nobody ported. So the build lists, for
# each interface the diff changes, every caller in the final tree, and says
# whether the diff ported it (the call line is an added line) or left it alone
# (with the plan's reason, or a flag that there is none).
#
# The interfaces are the plan's `## Changed symbols` rows plus the functions
# the diff itself changes: a def line that differs between base and head (in
# this repo the shell usage comment is on the def line, so that is the
# signature), or a def at base that is gone at head.
#
# Formats and knobs: docs/notes/2026-10-10-BH-5791-design-collisions.md.
# No `set -e`, no `exit`, no side effect at source time. mawk-safe awk only.
# shellcheck shell=bash
if [ -n "${CALLER_CHECK_LIB:-}" ]; then return 0 2>/dev/null; fi
CALLER_CHECK_LIB=1
# shellcheck source=bin/lib/plan-collisions.sh
command -v pc_locate >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/plan-collisions.sh" 2>/dev/null

CK_MAX_LINES=60; CK_CONF_WARN=""

# cc_conf [project] — CK_MAX_LINES from the knob row (lib_env_apply
# caller-check), else the env, else 60. 0 is off.
cc_conf() {
  local p="${1:-}" root v
  root="${HARNESS:-${H:-}}"
  CK_CONF_WARN=""
  if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/lib/lane-gate.sh" 2>/dev/null || true
  fi
  if command -v lib_env_apply >/dev/null 2>&1; then lib_env_apply caller-check "$p" >/dev/null 2>&1 || true; fi
  v="${CALLER_CHECK_MAX_LINES:-60}"
  case "$v" in
    ''|*[!0-9]*) CK_CONF_WARN="CALLER_CHECK_MAX_LINES='$v' is not a whole number — using 60"; v=60 ;;
  esac
  CK_MAX_LINES=$((10#$v))
  return 0
}

# _cc_defs <repo> <ref> <file> — `name<TAB>def line` for each function the
# file defines at <ref> (shell `name()`, JS `function name(` and
# `const name = (…) =>` / `= function`).
_cc_defs() {
  git -C "$1" show "$2:$3" 2>/dev/null | awk -v f="$3" '
    {
      l = $0; n = ""
      if (f ~ /\.sh$/) {
        if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/) {
          n = l; sub(/^[ \t]*/, "", n); sub(/^function[ \t]+/, "", n); sub(/[ \t]*\(\).*$/, "", n)
        }
      } else if (l ~ /^[ \t]*(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?function\*?[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/) {
        n = l; sub(/^.*function\*?[ \t]+/, "", n); sub(/[ \t]*\(.*$/, "", n)
      } else if (l ~ /^[ \t]*(export[ \t]+)?(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*(async[ \t]+)?(function|\(|[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=>)/) {
        n = l; sub(/^[ \t]*(export[ \t]+)?(const|let|var)[ \t]+/, "", n); sub(/[ \t]*=.*$/, "", n)
      }
      if (n != "" && !s[n]++) { gsub(/\t/, " ", l); print n "\t" l }
    }'
}

# cc_interfaces <repo> <base> <head> <plan> — `name<TAB>kind<TAB>source<TAB>state<TAB>reason`.
# source: listed (the plan) or diff; state: changed or gone. A name both
# listed and found in the diff is one row, with the plan's reason.
cc_interfaces() {
  local repo="$1" base="$2" head="$3" plan="$4" f
  {
    if [ -r "$plan" ]; then
      pc_symbols "$plan" "$repo" "$head" 2>/dev/null | awk -F'\t' '$1 == "listed" { print $3 "\t" $2 "\tlisted\tchanged\t" $4 }'
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      LC_ALL=C join -t "$(printf '\t')" -a 1 -e '<gone>' -o '0,1.2,2.2' \
        <(_cc_defs "$repo" "$base" "$f" | LC_ALL=C sort -t "$(printf '\t')" -k1,1) \
        <(_cc_defs "$repo" "$head" "$f" | LC_ALL=C sort -t "$(printf '\t')" -k1,1) 2>/dev/null \
      | while IFS=$'\t' read -r n a b; do
          if [ "$b" = '<gone>' ]; then
            pc_locate "$repo" "$head" "$n" >/dev/null 2>&1 || printf '%s\tfunction\tdiff\tgone\t\n' "$n"
          elif [ "$a" != "$b" ]; then
            printf '%s\tfunction\tdiff\tchanged\t\n' "$n"
          fi
        done
    done < <(git -C "$repo" diff --no-ext-diff --name-only "$base" "$head" -- '*.sh' '*.js' '*.mjs' '*.ts' 2>/dev/null)
  } | awk -F'\t' '
      { if (!($1 in row)) { ord[++n] = $1; row[$1] = $0 }
        else {
          split(row[$1], o, "\t")
          if ($3 == "listed") row[$1] = $1 "\t" $2 "\tlisted\t" ($4 == "gone" || o[4] == "gone" ? "gone" : "changed") "\t" $5
          else if ($4 == "gone") row[$1] = o[1] "\t" o[2] "\t" o[3] "\tgone\t" o[5]
        } }
      END { for (i = 1; i <= n; i++) print row[ord[i]] }'
}

# cc_callers <repo> <base> <head> <interfaces-tsv> — one row per caller:
# `CALLER<TAB>name<TAB>file:line<TAB>ported|left alone<TAB>reason`, plus
# `SKIPPED<TAB>name<TAB>skipped (name too short)` for a name under 4 characters. The
# def lines, comment lines and *.md files are not callers.
cc_callers() {
  local repo="$1" base="$2" head="$3" ifs="$4" ranges name kind src state reason defs
  ranges=$(git -C "$repo" diff --no-ext-diff --no-color -U0 "$base" "$head" 2>/dev/null | awk '
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^@@ / {
      p = $3; sub(/^\+/, "", p); c = p; d = 1
      if (index(p, ",")) { c = substr(p, 1, index(p, ",") - 1); d = substr(p, index(p, ",") + 1) }
      if (d + 0 > 0) print f "\t" c "\t" (c + d - 1)
    }')
  while IFS=$'\t' read -r name kind src state reason; do
    [ -n "$name" ] || continue
    if [ "${#name}" -lt 4 ]; then printf 'SKIPPED\t%s\tskipped (name too short)\n' "$name"; continue; fi
    defs=$(pc_locate "$repo" "$head" "$name" 2>/dev/null | awk -F'\t' '{ print $1 ":" $2 }')
    git -C "$repo" grep -n -w -F -e "$name" "$head" -- . ':!*.md' 2>/dev/null \
    | awk -v ref="$head:" -v name="$name" -v state="$state" -v reason="$reason" -v defs="$defs" -v ranges="$ranges" '
        BEGIN {
          nd = split(defs, d, "\n"); for (i = 1; i <= nd; i++) isdef[d[i]] = 1
          nr = split(ranges, r, "\n")
          for (i = 1; i <= nr; i++) { split(r[i], x, "\t"); rf[i] = x[1]; rs[i] = x[2] + 0; re[i] = x[3] + 0 }
        }
        {
          l = $0; if (index(l, ref) == 1) l = substr(l, length(ref) + 1)
          i = index(l, ":"); f = substr(l, 1, i - 1); l = substr(l, i + 1)
          i = index(l, ":"); n = substr(l, 1, i - 1); t = substr(l, i + 1)
          if (isdef[f ":" n]) next
          sub(/^[ \t]+/, "", t)
          if (t ~ /^(#|\/\/|\*)/) next
          st = "left alone"
          for (i = 1; i <= nr; i++) if (rf[i] == f && n + 0 >= rs[i] && n + 0 <= re[i]) { st = "ported"; break }
          if (st == "ported") why = "the call line changed in this diff"
          else if (state == "gone") why = "definition gone at head; this caller still names it"
          else if (reason != "") why = reason
          else why = "no reason in the plan"
          printf "CALLER\t%s\t%s:%s\t%s\t%s\n", name, f, n, st, why
        }'
  done < "$ifs"
}

# cc_section <callers-file> [max] — the PR body section. Empty when max is 0.
cc_section() {
  local col="$1" max="${2:-60}" sum
  case "$max" in ''|*[!0-9]*) max=60 ;; esac
  [ "$max" = 0 ] && return 0
  printf '\n## Interface callers (BH-5791)\n\n'
  sum=$(sed -n 's/^CALLERS: //p' "$col" 2>/dev/null | head -1)
  case "$sum" in
    '') printf 'The caller check could not run: it wrote no output.\n'; return 0 ;;
    could-not-run*) sum=${sum#could-not-run}; sum=${sum# }; printf 'The caller check could not run: %s.\n' "${sum:-no reason given}"; return 0 ;;
  esac
  if ! grep -q '^INTERFACE	' "$col"; then printf 'No changed interface found in this diff.\n'; return 0; fi
  printf 'The callers of each interface this diff changes, in the tree after the main merge. `ported`: the call line changed in this diff. `left alone`: it did not.\n\n%s\n\n' "$sum"
  awk -F'\t' -v max="$max" '
    $1 == "INTERFACE" { ord[++ni] = $2; src[$2] = $4; st[$2] = $5 }
    $1 == "CALLER"    { nc[$2]++; c[$2, nc[$2]] = "- `" $2 "` " $3 " — " $4 " — " $5 }
    $1 == "SKIPPED"   { sk[$2] = 1 }
    END {
      for (i = 1; i <= ni; i++) {
        n = ord[i]
        if (sk[n]) { line[++m] = "- `" n "` — skipped (name too short)"; continue }
        if (!nc[n]) { line[++m] = "- `" n "` — no caller outside its definition (" src[n] ", " st[n] ")"; continue }
        for (j = 1; j <= nc[n]; j++) line[++m] = c[n, j]
      }
      for (k = 1; k <= m && k <= max; k++) print line[k]
      if (m > max) printf "… and %d more in callers.txt on the build box\n", m - max
    }' "$col"
}
