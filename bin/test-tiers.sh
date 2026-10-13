#!/bin/bash
# bin/test-tiers.sh — WHICH TIER A SUITE RUNS IN (2026-09-28, the nightly tier).
#
#   bin/test-tiers.sh batch   [--tiers <f>] [--changed <f>] [--quarantine <f>] [--protected <f>]  < list > list
#   bin/test-tiers.sh nightly [--tiers <f>] [--quarantine <f>] [--protected <f>]                 < list > list
#   bin/test-tiers.sh check   [--tiers <f>] [--protected <f>] [--root <dir>]
#
# WHY IT EXISTS. A merge-queue batch ran every suite on every tree, and 124 slow
# suites that never failed in 300 batch runs (09-25..09-28) were ~64% of each
# batch's corpus minutes. They still earn their place, just not once per batch:
# they run once a night on main (.github/workflows/harness-nightly.yml), and a
# red night opens a ticket (bin/nightly-ticket.sh), so a nightly suite can never
# rot quietly. Between the PR and that night, the one run a nightly suite gets
# is the builder's pre-push gate (bin/test-impact-gate.sh), which runs every
# nightly suite the diff reaches FIRST and outside its cap. A nightly suite the
# gate's time budget could not start is reported as left to the nightly run,
# not "left to CI": no batch runs it, so it reaches main untested until then.
#
# THE DATA IS catalog/test-tiers.tsv, reviewed in the repo like any other
# catalog. One row per suite, tab separated:
#
#   <suite>  <tier>  <runtime_s>  <paths>  <reason>
#
#   batch    every merge-queue batch (the DEFAULT — a suite with no row is batch)
#   nightly  the nightly run only
#   guard    a safety/leak guard: the nightly run, AND a batch whose diff touches
#            one of <paths>. <paths> is a space-separated list of repo paths in
#            bin/test-impact.sh's map-row spelling: an exact file, a directory
#            ending in `/` (everything under it), or a glob (`prompts/product-*`,
#            `*` = every path). `-` means none (nightly and batch rows).
#
# FAIL-SAFE IN ONE DIRECTION ONLY. Every unknown lands in BATCH, never nightly:
# a missing or unreadable tier file, a suite with no row, a row whose tier is
# not one of the three, a guard row with no paths. And every unknown about a
# guard RUNS it: no --changed list, an unreadable one, an empty one (a diff that
# could not be computed is not a diff that touched nothing). A guard also always
# runs when the diff touches the guard suite itself, this file, or the tier
# file — "a change to the guard, or to its paths, triggers it".
#
# NEVER A SILENTLY SHORTER LIST. The join and the write are checked, and the
# output must be the input minus exactly the rows this step chose to drop. A
# mismatch (a broken awk, a full disk) hands the batch back WHOLE, with a
# `tiers: FAIL-SAFE` line; in nightly mode it is rc 2 (a red night, never a
# partial one). TEST_TIERS_AWK is the seam tests/test-tiers-test.sh T9 uses to
# break the join.
#
# The reason channel is stderr: one `tiers: …` summary line, plus one line per
# guard saying whether it runs and why. stdout is the list and nothing else.
#
# QUARANTINE (BH-3686). `--quarantine <f>` names suites flaky enough to take out
# of the batch: tokens split on whitespace and newlines, each a `tests/…sh` path
# (a glob, a `..` or anything else is ignored with a `tiers:` line). `-`, an
# empty or a blank file means none, and the run is byte-identical to one with no
# flag; an unreadable file quarantines nothing and says so once. In the batch a
# quarantined `batch` (or no-row) suite is dropped, `tiers: quarantine <s> — out
# of the batch`, and counted in the summary as `, <n> quarantined`; in nightly
# mode the same suite is ADDED, so it still runs every night on main. A
# PROTECTED suite is never dropped: tp_protected (bin/lib/test-protected.sh)
# over `--protected <f>` (default catalog/test-quarantine-protected.txt, exported
# as TP_PROTECTED_LIST) or a guard row in the --tiers file refuses it with a
# `quarantine refused for <s> — protected (<why>)` line. It fails closed: an
# unreadable protected list protects everything, and a lib that cannot be loaded
# refuses every quarantine. bin/ci-plan.sh builds the list from the repo
# variable CI_QUARANTINE. tests/test-tiers-quarantine.bh-3686-test.sh drives it.
#
# `check` validates the file (every row names an existing suite, a known tier, a
# whole-number runtime, paths on a guard and a reason on every row, no suite
# twice), and the protected list (each exact path exists, each glob matches a
# tests/*.sh or tests/mc/*.sh suite, every line has a reason).
# tests/test-tiers-test.sh runs it against the shipped files.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
TIERS=""; CHANGED=""; HAVE_CHANGED=0; CMD=""; QUAR=""; HAVE_QUAR=0; PROT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tiers)   [ $# -ge 2 ] || { echo "test-tiers: --tiers needs a path" >&2; exit 2; }; TIERS="$2"; shift ;;
    --changed) [ $# -ge 2 ] || { echo "test-tiers: --changed needs a path" >&2; exit 2; }; CHANGED="$2"; HAVE_CHANGED=1; shift ;;
    --root)    [ $# -ge 2 ] || { echo "test-tiers: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift ;;
    --quarantine) [ $# -ge 2 ] || { echo "test-tiers: --quarantine needs a path" >&2; exit 2; }; QUAR="$2"; HAVE_QUAR=1; shift ;;
    --protected)  [ $# -ge 2 ] || { echo "test-tiers: --protected needs a path" >&2; exit 2; }; PROT="$2"; shift ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    -*)        echo "test-tiers: unknown flag $1" >&2; exit 2 ;;
    *)         [ -z "$CMD" ] || { echo "test-tiers: one command, got '$CMD' and '$1'" >&2; exit 2; }; CMD="$1" ;;
  esac
  shift
done
TIERS="${TIERS:-$ROOT/catalog/test-tiers.tsv}"
TIERS_REL="catalog/test-tiers.tsv"
SELF_REL="bin/test-tiers.sh"
PROT="${PROT:-$ROOT/catalog/test-quarantine-protected.txt}"
export TP_PROTECTED_LIST="$PROT"
TP_OK=1
# shellcheck source=bin/lib/test-protected.sh
. "$SELF_DIR/lib/test-protected.sh" 2>/dev/null || TP_OK=0

# tt_quar_load <out> — the quarantine set, one valid suite per line (empty for
# none). Every refusal is said on stderr; none of them quarantines anything.
tt_quar_load() {
  local out="$1" tok
  : > "$out"
  [ "$HAVE_QUAR" = 1 ] && [ "$QUAR" != - ] || return 0
  if [ ! -f "$QUAR" ] || [ ! -r "$QUAR" ]; then
    echo "tiers: quarantine list $QUAR unreadable — nothing is quarantined" >&2; return 0
  fi
  tr -s '[:space:]' '\n' < "$QUAR" | while IFS= read -r tok; do
    case "$tok" in ''|-) continue ;; esac
    case "$tok" in
      *[*?[]*|*..*) ;;
      tests/*.sh) printf '%s\n' "$tok"; continue ;;
    esac
    echo "tiers: quarantine token '$tok' ignored — not a tests/ suite" >&2
  done > "$out"
  if [ "$TP_OK" != 1 ] && grep -q . "$out"; then
    echo "tiers: quarantine refused — bin/lib/test-protected.sh could not be loaded; every quarantined suite stays in the batch" >&2
    : > "$out"
  fi
}

# tt_rows — the file's data rows as `suite\ttier\tpaths`, comments and blanks
# dropped, an unknown tier rewritten to batch (and said out loud on stderr).
tt_rows() {
  [ -r "$TIERS" ] || return 0
  awk -F'\t' '
    /^[[:space:]]*(#|$)/ { next }
    { t = $2
      if (t != "batch" && t != "nightly" && t != "guard") {
        print "tiers: " $1 ": unknown tier \x27" t "\x27 — it runs in the batch" > "/dev/stderr"; t = "batch" }
      p = $4; if (t == "guard" && (p == "" || p == "-")) {
        print "tiers: " $1 ": a guard with no paths — it runs in the batch" > "/dev/stderr"; t = "batch" }
      print $1 "\t" t "\t" p }' "$TIERS"
}

# tt_hit <path> <spec...> — does a changed path match one of a guard's specs?
# The map's row semantics: exact, `dir/` prefix, or a glob.
tt_hit() {
  local p="$1" s; shift
  for s in "$@"; do
    case "$s" in
      */) case "$p" in "$s"*) return 0 ;; esac ;;
      *)  # shellcheck disable=SC2254 # the spec IS a glob, on purpose
          case "$p" in $s) return 0 ;; esac ;;
    esac
  done
  return 1
}

tt_filter() { # <batch|nightly>
  local mode="$1" s t p nb=0 ns=0 ng=0 nr=0 nq=0 why changed_ok=0 tmp q
  local -A quar=()
  [ -r "$TIERS" ] || echo "tiers: no tier file at $TIERS — every suite runs in the batch" >&2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-tiers.XXXXXX") || { echo "test-tiers: no temp dir" >&2; return 2; }
  local ok_io=1 nin nout
  tt_rows > "$tmp/rows" || ok_io=0
  cat > "$tmp/list" || ok_io=0
  nin=$(grep -c . "$tmp/list")
  tt_quar_load "$tmp/quar"
  while IFS= read -r q; do quar[$q]=1; done < "$tmp/quar"
  if [ "$mode" = batch ] && [ "$HAVE_CHANGED" = 1 ] && [ -r "$CHANGED" ] && grep -q . "$CHANGED" 2>/dev/null; then
    changed_ok=1
  fi
  # One join, not an awk per suite: `suite<TAB>tier<TAB>paths`, a suite with no
  # row being batch. The list's order is kept.
  "${TEST_TIERS_AWK:-awk}" -F'\t' -v rf="$tmp/rows" '
    FILENAME == rf { t[$1] = $2; p[$1] = $3; next }
    $0 == "" { next }
    { if ($0 in t) print $0 "\t" t[$0] "\t" p[$0]; else print $0 "\tbatch\t" }
  ' "$tmp/rows" "$tmp/list" > "$tmp/joined" || ok_io=0
  [ "$(grep -c . "$tmp/joined")" = "$nin" ] || ok_io=0
  : > "$tmp/out" || ok_io=0
  while IFS=$'\t' read -r s t p; do
    if [ "$mode" = nightly ]; then
      case "$t" in
        nightly|guard) printf '%s\n' "$s"; nr=$((nr+1)) ;;
        *) if [ -n "${quar[$s]:-}" ] && ! tp_protected "$s" "$ROOT" >/dev/null; then
             printf '%s\n' "$s"; nr=$((nr+1))
           fi ;;
      esac
      continue
    fi
    if [ -n "${quar[$s]:-}" ]; then
      case "$t" in
        guard) echo "tiers: quarantine refused for $s — protected (guard tier); its guard rule still decides" >&2 ;;
        nightly) ;;
        *) if why=$(tp_protected "$s" "$ROOT"); then
             echo "tiers: quarantine refused for $s — protected ($why); it stays in the batch" >&2
           else
             nq=$((nq+1))
             echo "tiers: quarantine $s — out of the batch (flaky; the nightly runs it)" >&2
             continue
           fi ;;
      esac
    fi
    case "$t" in
      nightly) ns=$((ns+1)) ;;
      guard)
        why=""
        if [ "$changed_ok" = 0 ]; then
          why="the changed paths are unknown"
        else
          local c specs=()
          read -r -a specs <<<"$p"
          while IFS= read -r c; do
            [ -n "$c" ] || continue
            case "$c" in
              "$s"|"$TIERS_REL"|"$SELF_REL") why="$c changed (the guard or its tier)"; break ;;
            esac
            if tt_hit "$c" "${specs[@]}"; then why="$c changed"; break; fi
          done < "$CHANGED"
        fi
        if [ -n "$why" ]; then
          printf '%s\n' "$s"; nb=$((nb+1)); ng=$((ng+1))
          echo "tiers: guard $s runs — $why" >&2
        else
          ns=$((ns+1))
          echo "tiers: guard $s skipped — no path it guards changed (it runs nightly)" >&2
        fi ;;
      *) printf '%s\n' "$s"; nb=$((nb+1)) ;;
    esac
  done < "$tmp/joined" > "$tmp/out" || ok_io=0
  nout=$(grep -c . "$tmp/out")
  if [ "$mode" = batch ]; then [ "$((nout + ns + nq))" = "$nin" ] || ok_io=0
  else [ "$nout" = "$nr" ] || ok_io=0; fi
  if [ "$ok_io" != 1 ]; then
    if [ "$mode" = nightly ]; then
      echo "tiers: the nightly list could not be built intact ($nin in, $nout out) — refusing a partial night" >&2
      rm -rf "$tmp"; return 2
    fi
    echo "tiers: FAIL-SAFE — the tier step lost rows ($nin in, $nout out + ${ns} dropped + ${nq} quarantined); the batch runs the whole list" >&2
    grep . "$tmp/list"; local rc=$?; rm -rf "$tmp"; [ "$rc" = 0 ] || [ "$nin" = 0 ]; return
  fi
  cat "$tmp/out" || { rm -rf "$tmp"; return 2; }
  rm -rf "$tmp"
  if [ "$mode" = nightly ]; then
    echo "tiers: nightly — $nr suite(s) of the nightly and guard tiers" >&2
  else
    echo "tiers: batch — $nb suite(s) run ($ng guard(s) triggered), $ns left to the nightly run$([ "$nq" = 0 ] || echo ", $nq quarantined")" >&2
  fi
}

tt_check() {
  local bad=0
  [ -r "$TIERS" ] || { echo "test-tiers check: cannot read $TIERS" >&2; return 2; }
  while IFS=$'\t' read -r s t r p why extra; do
    case "$s" in ''|'#'*) continue ;; esac
    [ -f "$ROOT/$s" ] || { echo "test-tiers check: $s: no such suite" ; bad=1; }
    case "$s" in tests/*.sh) ;; *) echo "test-tiers check: $s: not a tests/ suite"; bad=1 ;; esac
    case "$t" in batch|nightly|guard) ;; *) echo "test-tiers check: $s: unknown tier '$t'"; bad=1 ;; esac
    case "$r" in ''|*[!0-9]*) echo "test-tiers check: $s: runtime '$r' is not whole seconds"; bad=1 ;; esac
    if [ "$t" = guard ]; then
      case "$p" in ''|-) echo "test-tiers check: $s: a guard needs the paths it guards"; bad=1 ;; esac
    else
      [ "$p" = - ] || { echo "test-tiers check: $s: paths are for guard rows only (got '$p')"; bad=1; }
    fi
    [ -n "$why" ] || { echo "test-tiers check: $s: no reason"; bad=1; }
    [ -z "$extra" ] || { echo "test-tiers check: $s: more than five columns"; bad=1; }
  done < "$TIERS"
  local dup
  dup=$(grep -Ev '^[[:space:]]*(#|$)' "$TIERS" | cut -f1 | LC_ALL=C sort | uniq -d)
  [ -z "$dup" ] || { echo "test-tiers check: listed twice: $dup"; bad=1; }
  # The protected list: an exact path exists, a glob matches a suite, a reason
  # on every line.
  local g gwhy np=0 suites m
  if [ -r "$PROT" ]; then
    suites=$(cd "$ROOT" && ls tests/*.sh tests/mc/*.sh 2>/dev/null)
    while read -r g gwhy; do
      case "$g" in ''|'#'*) continue ;; esac
      np=$((np+1))
      [ -n "$gwhy" ] || { echo "test-tiers check: protected $g: no reason"; bad=1; }
      case "$g" in
        *[*?[]*)
          m=0
          while IFS= read -r s; do
            # shellcheck disable=SC2254 # the line IS a glob, on purpose
            case "$s" in $g) m=1; break ;; esac
          done <<<"$suites"
          [ "$m" = 1 ] || { echo "test-tiers check: protected $g: matches no tests/ suite"; bad=1; } ;;
        *) [ -f "$ROOT/$g" ] || { echo "test-tiers check: protected $g: no such suite"; bad=1; } ;;
      esac
    done < "$PROT"
  else
    echo "test-tiers check: cannot read the protected list $PROT"; bad=1
  fi
  [ "$bad" = 0 ] && echo "test-tiers check: $(grep -Ecv '^[[:space:]]*(#|$)' "$TIERS") row(s) ok, $np protected line(s) ok"
  [ "$bad" = 0 ]
}

case "$CMD" in
  batch|nightly) tt_filter "$CMD" ;;
  check) tt_check ;;
  *) echo "test-tiers: command must be batch, nightly or check (got '${CMD:-<none>}')" >&2; exit 2 ;;
esac
