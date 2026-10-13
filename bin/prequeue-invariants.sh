#!/bin/bash
# bin/prequeue-invariants.sh — the whole-repo invariant suites the pre-queue gate
# runs on every head (BH-5438, #5429 child 0).
#
# bin/test-impact-gate.sh only runs the suites a diff can reach, and a suite
# that scans the whole tree (share-mirror-clean, lanes-registry, ...) is never
# on that map. On 2026-10-08 five PRs passed the pre-queue gate and then failed
# whole merge batches on exactly those suites. This runs every row of
# catalog/prequeue-invariants.tsv on the tree it lives in, so the gate's
# verdict can name the one that went red.
#
# Usage:
#   bin/prequeue-invariants.sh --run --catalog F --out DIR [--overrides STR] [--harness H] [--jobs N]
#   bin/prequeue-invariants.sh --list [--catalog F] [--harness H]
#   bin/prequeue-invariants.sh --overrides --harness H [--catalog F]
#
# --list prints the resolved rows, id<TAB>kind<TAB>argv<TAB>budget_s, in
# catalog order. --overrides with no value prints the settings rows below as
# one comma list of id=off|<n> (or nothing), rc 0; with no catalog it prints
# nothing, rc 0. The conductor hands it to the workflow as `-f invariants=`
# (bin/lib/mc-prequeue.d/invariants.sh). Both default --catalog to this tree's
# catalog/prequeue-invariants.tsv.
#
# Settings rows (BH-5440): with --harness H, `conf.prequeue-invariants.<id>[.<box>]`
# is read through H's bin/lib/conf-row.sh (box row first). Its value is off or
# a positive integer budget; anything else is refused through conf_row_refused
# and the catalog answers. A row for an id the catalog does not carry is
# skipped. So a row can turn a row off or rebudget it, never add one or change
# argv. With no --harness there are no rows. Rows apply first, then --overrides STR.
#
# The catalog: `#` lines and blank lines are skipped; every other line is five
# TAB-separated columns, id kind argv budget_s guards. A broken row refuses the
# whole catalog (rc 2) before anything runs.
#   suite  argv is one tests/[mc/]*.sh, run via bin/test-suite-run.sh --only-file
#   cmd    argv is split on spaces and executed directly, never through a shell
#
# --overrides STR is a comma list of id=off|<n>: off drops the row, a positive
# integer replaces its budget_s. A malformed item or an unknown id gets one
# stderr line and the catalog value answers.
#
# --jobs N (default 4, the RULES_PACK_JOBS precedent) runs up to N rows at
# once; bash older than 4.3 runs them serially. Output and every file below
# stay in catalog order.
#
# Before any row starts, the lazy catalog/lanes.json is rendered once (BH-5775).
# Every row runs from the repo root with HARNESS_TEST_SANDBOX=1, and with
# RATCHET_BASE=$PQ_MAIN when PQ_MAIN is set. A row over its budget is reported
# (OVER BUDGET), never killed. A suite missing from the tree is red. When a
# selected suite looks for gitleaks, the pinned gitleaks is installed first and
# GITLEAKS_REQUIRED=1 is exported; if that install fails nothing runs (rc 125).
#
# DIR gets res/<id> (rc seconds missing, one per row), timings.tsv (id rc
# seconds budget_s over), suites.txt (every suite that ran, the impact gate's
# --skip-suites input), failed.txt (red ids), and fail/<id>.txt (the first 8
# ^FAIL lines of log/<id>.log, else its last 8, token shapes redacted, each line
# cut at 300 chars).
# A row with no ^FAIL line that prints a `DRIFT <path>` line reports from that line on (BH-5591).
#
# Exit: 0 green | 1 red | 2 bad args, bad catalog or empty set | 125 could not run
set -uo pipefail

die2() { echo "prequeue-invariants: $*" >&2; exit 2; }
USAGE="--run --catalog F --out DIR [--overrides STR] [--harness H] [--jobs N] | --list [--catalog F] [--harness H] | --overrides --harness H"
RUN=""; LIST=""; PRINT_OVR=""; CAT=""; OUT=""; OVR=""; HAR=""; JOBS=4
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=1 ;;
    --list) LIST=1 ;;
    --catalog) [ $# -ge 2 ] || die2 "--catalog needs a path"; CAT="$2"; shift ;;
    --out) [ $# -ge 2 ] || die2 "--out needs a dir"; OUT="$2"; shift ;;
    --harness) [ $# -ge 2 ] || die2 "--harness needs a path"; HAR="$2"; shift ;;
    --jobs) [ $# -ge 2 ] && [[ $2 =~ ^[1-9][0-9]*$ ]] || die2 "--jobs needs a positive integer"; JOBS="$2"; shift ;;
    # An override item starts with an id (^[a-z0-9]), never with --.
    --overrides) if [ $# -ge 2 ] && [[ $2 != --* ]]; then OVR="$2"; shift; else PRINT_OVR=1; fi ;;
    *) die2 "unknown argument '$1' (usage: $USAGE)" ;;
  esac
  shift
done
[ "$((${RUN:-0} + ${LIST:-0} + ${PRINT_OVR:-0}))" = 1 ] || die2 "usage: $USAGE"
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 125
if [ -n "$RUN" ]; then
  [ -n "$CAT" ] || die2 "--catalog is required"
  [ -n "$OUT" ] || die2 "--out is required"
fi
[ -n "$CAT" ] || CAT="$ROOT/catalog/prequeue-invariants.tsv"
# No catalog in this tree: there is nothing to override.
[ -n "$PRINT_OVR" ] && [ ! -r "$CAT" ] && exit 0
[ -r "$CAT" ] || die2 "cannot read catalog '$CAT'"
case "$CAT" in /*) ;; *) CAT="$PWD/$CAT" ;; esac
case "$OUT" in ''|/*) ;; *) OUT="$PWD/$OUT" ;; esac
case "$HAR" in ''|/*) ;; *) HAR="$PWD/$HAR" ;; esac
cd "$ROOT" || exit 125

# ── the catalog, parsed whole before anything runs ──────────────────────────
ORDER=()
declare -A KIND=() ARGV=() BUD=() OFF=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r id kind argv budget guards extra <<<"$line"
  why=""
  if ! [[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]]; then why="id '$id'"
  elif [ -n "${KIND[$id]:-}" ]; then why="duplicate id $id"
  elif [ -n "$extra" ]; then why="more than 5 columns"
  elif [ -z "$guards" ]; then why="fewer than 5 columns (guards is empty)"
  elif ! [[ $budget =~ ^[1-9][0-9]*$ ]]; then why="budget_s '$budget' is not a positive integer"
  elif [[ $argv == *..* ]]; then why="argv '$argv' holds .."
  elif [ "$kind" = suite ]; then
    [[ $argv =~ ^tests/(mc/)?[A-Za-z0-9._-]+\.sh$ ]] || why="suite argv '$argv' is not tests/[mc/]<name>.sh"
  elif [ "$kind" = cmd ]; then
    [ -n "$argv" ] || why="cmd argv is empty"
  else why="kind '$kind' is not suite or cmd"
  fi
  [ -z "$why" ] || die2 "bad catalog line $n: $why"
  ORDER+=("$id"); KIND[$id]="$kind"; ARGV[$id]="$argv"; BUD[$id]="$budget"
done < "$CAT"

# ── settings rows: conf.prequeue-invariants.<id>[.<box>] from H ─────────────
declare -A ROWV=()
if [ -n "$HAR" ] && [ -r "$HAR/bin/lib/conf-row.sh" ]; then
  # shellcheck source=lib/conf-row.sh
  . "$HAR/bin/lib/conf-row.sh" 2>/dev/null || true
  if command -v conf_rows >/dev/null 2>&1; then
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] && [ -n "${KIND[$k]:-}" ] || continue
      if [ "$v" = off ] || [[ $v =~ ^[1-9][0-9]*$ ]]; then ROWV[$k]="$v"
      else conf_row_refused prequeue-invariants "$k" "$v" "$CAT" "$HAR"; fi
    done < <(conf_rows prequeue-invariants "$HAR")
  fi
fi
ROWS=""
for id in "${ORDER[@]}"; do [ -n "${ROWV[$id]:-}" ] && ROWS="${ROWS:+$ROWS,}$id=${ROWV[$id]}"; done
if [ -n "$PRINT_OVR" ]; then
  [ -z "$ROWS" ] || printf '%s\n' "$ROWS"
  exit 0
fi

IFS=, read -ra ITEMS <<<"$ROWS${ROWS:+,}$OVR"
for it in "${ITEMS[@]}"; do
  [ -n "$it" ] || continue
  k="${it%%=*}"; v="${it#*=}"
  if [[ $it != *=* ]]; then echo "prequeue-invariants: override '$it' ignored: not id=off|<n>" >&2
  elif [ -z "${KIND[$k]:-}" ]; then echo "prequeue-invariants: override '$it' ignored: no row $k" >&2
  elif [ "$v" = off ]; then OFF[$k]=1
  elif [[ $v =~ ^[1-9][0-9]*$ ]]; then BUD[$k]="$v"
  else echo "prequeue-invariants: override '$it' ignored: '$v' is not off or a whole number" >&2
  fi
done

SEL=()
for id in "${ORDER[@]}"; do [ -n "${OFF[$id]:-}" ] || SEL+=("$id"); done
[ "${#SEL[@]}" -gt 0 ] || die2 "no invariant left to run (empty catalog, or every row off)"
if [ -n "$LIST" ]; then
  for id in "${SEL[@]}"; do printf '%s\t%s\t%s\t%s\n' "$id" "${KIND[$id]}" "${ARGV[$id]}" "${BUD[$id]}"; done
  exit 0
fi

# ── gitleaks, when a selected suite looks for it ────────────────────────────
mkdir -p "$OUT" || exit 125
for id in "${SEL[@]}"; do
  [ "${KIND[$id]}" = suite ] && [ -f "${ARGV[$id]}" ] && grep -qF 'command -v gitleaks' "${ARGV[$id]}" || continue
  # shellcheck source=lib/gitleaks-pin.sh
  . "$ROOT/bin/lib/gitleaks-pin.sh" || exit 125
  mkdir -p "$OUT/tools" || exit 125
  if ! gl_err=$(gitleaks_pin_ensure "$OUT/tools" 2>&1); then
    echo "prequeue-invariants: could not install the pinned gitleaks: ${gl_err:-no reason given}" >&2
    exit 125
  fi
  PATH="$OUT/tools:$PATH"; export GITLEAKS_REQUIRED=1
  break
done

# ── the lazy lane render, once, before rows share the checkout (BH-5775) ────
# catalog/lanes.json is git-ignored, so a fresh checkout has none, and the first
# row to reach lanes_json_path renders it here. With rows running at once, that
# lands inside share-mirror-clean's before/after window and it blames itself.
# Rendered first, every row finds it current and writes nothing.
if [ -d "$ROOT/catalog/lanes.d" ] && [ -r "$ROOT/bin/lib/lanes-registry.sh" ]; then
  ( unset LANE_REGISTRY
    # shellcheck source=lib/lanes-registry.sh
    . "$ROOT/bin/lib/lanes-registry.sh" && lanes_json_path "$ROOT" ) > /dev/null 2>&1 || :
fi

# ── the rows, up to JOBS at once ────────────────────────────────────────────
mkdir -p "$OUT/log" "$OUT/fail" "$OUT/res" || exit 125
rm -f "$OUT/res/"*
: > "$OUT/timings.tsv"; : > "$OUT/suites.txt"; : > "$OUT/failed.txt"
export HARNESS_TEST_SANDBOX=1
[ -n "${PQ_MAIN:-}" ] && export RATCHET_BASE="$PQ_MAIN"

# run_one <id> — runs the row, writes its fail text and res/<id> (rc seconds missing).
# Each row has its own list file, so rows running at once never share one.
run_one() {
  local id="$1" argv="${ARGV[$1]}" log="$OUT/log/$1.log" lst="$OUT/.only.$1" rc=0 missing="" s0=$SECONDS s
  local -a a
  if [ "${KIND[$id]}" = suite ]; then
    if [ -f "$argv" ]; then
      printf '%s\n' "$argv" > "$lst"
      bash bin/test-suite-run.sh --only-file "$lst" tests tests/mc > "$log" 2>&1 < /dev/null; rc=$?
      rm -f "$lst"
    else missing=1; fi
  else
    read -ra a <<<"$argv"
    if [ -f "${a[0]}" ]; then
      case "${a[0]}" in
        *.sh) bash "${a[@]}" > "$log" 2>&1 < /dev/null; rc=$? ;;
        *) "${a[@]}" > "$log" 2>&1 < /dev/null; rc=$? ;;
      esac
    else missing=1; fi
  fi
  s=$((SECONDS - s0))
  if [ -n "$missing" ]; then
    rc=1; s=0; echo "suite missing on the merged tree" > "$OUT/fail/$id.txt"
  elif [ "$rc" != 0 ]; then
    { grep -m8 '^FAIL' "$log" || { grep -q '^DRIFT ' "$log" && sed -n '/^DRIFT /,$p' "$log" | head -n8; } || tail -n8 "$log"; } \
      | sed -E 's/gh[pousr]_[A-Za-z0-9_]{8,}/REDACTED/g; s/github_pat_[A-Za-z0-9_]+/REDACTED/g; s/sk-ant-[A-Za-z0-9_-]+/REDACTED/g; s/Bearer [^ ]+/REDACTED/g' \
      | cut -c1-300 > "$OUT/fail/$id.txt"
  fi
  echo "$rc $s $missing" > "$OUT/res/$id"
}

WALL0=$SECONDS
if [ "$JOBS" -gt 1 ] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
  live=0
  for id in "${SEL[@]}"; do
    while [ "$live" -ge "$JOBS" ]; do wait -n; live=$((live - 1)); done
    run_one "$id" & live=$((live + 1))
  done
  wait
else
  for id in "${SEL[@]}"; do run_one "$id"; done
fi

# ── the results, in catalog order ───────────────────────────────────────────
SUM=0; NRUN=0; NRED=0; OVERS=""
for id in "${SEL[@]}"; do
  b="${BUD[$id]}"; rc=1; s=0; missing=""
  if [ -r "$OUT/res/$id" ]; then read -r rc s missing < "$OUT/res/$id"
  else echo "no result recorded" > "$OUT/fail/$id.txt"; fi
  [ "${KIND[$id]}" = suite ] && [ -z "$missing" ] && printf '%s\n' "${ARGV[$id]}" >> "$OUT/suites.txt"
  [ "$rc" != 0 ] && { echo "$id" >> "$OUT/failed.txt"; NRED=$((NRED + 1)); }
  over=no; [ "$s" -gt "$b" ] && { over=yes; OVERS="${OVERS:+$OVERS,}$id"; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$rc" "$s" "$b" "$over" >> "$OUT/timings.tsv"
  flag=""; [ "$over" = yes ] && flag=" OVER BUDGET"
  echo "prequeue-invariant: $id rc=$rc ${s}s budget ${b}s$flag"
  SUM=$((SUM + s)); NRUN=$((NRUN + 1))
done
echo "prequeue-invariants: total ${SUM}s wall $((SECONDS - WALL0))s ($NRUN run, $NRED red)${OVERS:+ OVER BUDGET: $OVERS}"
[ -s "$OUT/failed.txt" ] && exit 1
exit 0
