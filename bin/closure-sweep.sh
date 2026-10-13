#!/bin/bash
# bin/closure-sweep.sh — convert a test suite's hand-copied bin/lib list to
# scratch_install_closure (tests/lib/scratch.sh), one suite at a time, and only
# when a before/after run of the suite proves nothing changed.
#
# A hand list (cp "$DIR/bin/lib/a.sh" "$H/bin/lib/") breaks in the merge queue
# the day the lane sources one more lib. The scratch-closure lint
# (tests/lib/scratch-closure-lint.sh) stops new ones; this tool removes old ones.
# "Hand line" means exactly what the lint's own hand_copy_lines counts.
#
# Usage:  bin/closure-sweep.sh [--root <dir>] [--apply] [--report <tsv>] <suite>...
#   --root    the repo the suites live in (default: the repo this script is in).
#             A <suite> path is relative to it, e.g. tests/x-test.sh.
#   --apply   edit the suites that come back `rewrite`, and prove each one.
#             Without it the run is a dry run and writes nothing.
#   --report  also write the rows to this file (truncated first).
# As root next to a live harness, set HARNESS_TEST_SANDBOX=1: the tool sources
# tests/lib/scratch.sh, and --apply runs each suite, which needs it anyway.
#
# Output: one row per suite, "<suite>\t<verdict>\t<detail>". The first verdict
# that matches wins:
#   skip:missing            no such file under --root.
#   skip:allow              the suite carries '# scratch-closure-allow: <reason>'.
#   skip:no-hand            the suite has no hand line.
#   skip:partial            the suite deletes a bin/lib file (rm -f ...bin/lib/),
#                           names half-synced or $T/mut on a non-comment line, or
#                           names missing|absent on a non-comment line that also
#                           names bin/lib: it tests a partial install. A bare
#                           "jq missing, skipping" guard does not count.
#   skip:shape              a hand line is in a for loop, copies from anything
#                           but "$DIR/bin/lib/...", is chained to another
#                           command (&&, ||, ;) other than one trailing
#                           `|| exit N` or `|| { ...exit N; }`, is or continues a
#                           `\` line, or the hand lines name more than one dest
#                           root. The detail names the reason and the line.
#   skip:no-target          the suite copies no "$DIR/bin/<x>.sh" into that
#                           dest root, so there is no script to take a closure of.
#   skip:closure-error      scratch_closure_list failed for a target script.
#   skip:not-in-closure:<libs>
#                           the hand lines name bin/lib files the targets'
#                           closure does not reach (comma-joined).
#   skip:no-scratch         the suite does not source lib/scratch.sh.
#   rewrite                 dry run: would rewrite; detail "<n> lines -> <targets>".
#   rewritten               --apply: rewritten, and the suite was green with the
#                           same summary lines before and after.
#   reverted:<b>/<a>[/summary]
#                           --apply: the proof failed, the file holds its
#                           original bytes again. <b>/<a> are the before/after
#                           exit codes; /summary when only the summaries differ.
#                           A suite red before the edit is reverted:<b>/- and is
#                           never edited.
#
# The rewrite deletes the hand lines and puts, at the first one's place and
# indent, one line per target script u:
#   scratch_install_closure <u> "<root>" >/dev/null || { echo "FAIL: closure <u>"; exit 1; }
# The proof runs `(cd <root> && HARNESS_TEST_SANDBOX=1 timeout $CS_TIMEOUT_S bash <suite>)`
# before and after; the summary lines are the sorted lines matching
# "N passed|failed", "PASS: N"/"FAIL= N" or "N/M ok|pass".
#
# Exit codes: 0 every suite got a verdict; 1 tests/lib/scratch.sh refused to
# load (root next to a live harness without HARNESS_TEST_SANDBOX=1); 2 bad
# usage, or --root has no tests/lib/scratch.sh. It makes no git writes.

# CS_TIMEOUT_S — the per-run proof timeout, seconds.
CS_TIMEOUT_S="${CS_TIMEOUT_S:-900}"

usage() { echo "usage: closure-sweep.sh [--root <dir>] [--apply] [--report <tsv>] <suite>..." >&2; exit 2; }

ROOT=""; APPLY=0; REPORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --report) [ "$#" -ge 2 ] || usage; REPORT="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || usage
[ -n "$ROOT" ] || ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/tests/lib/scratch.sh" ] || { echo "closure-sweep: no tests/lib/scratch.sh under '$ROOT'" >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd)
case "$CS_TIMEOUT_S" in ''|*[!0-9]*) echo "closure-sweep: CS_TIMEOUT_S='$CS_TIMEOUT_S' is not a number of seconds" >&2; exit 2 ;; esac

# scratch.sh gives $T (cleaned on exit) and scratch_closure_list; the lint lib
# gives hand_copy_lines and allowed, so a hand line here is the lint's hand line.
# shellcheck source=../tests/lib/scratch.sh
. "$ROOT/tests/lib/scratch.sh" || exit 2
# shellcheck source=../tests/lib/scratch-closure-lint.sh
. "$ROOT/tests/lib/scratch-closure-lint.sh" || exit 2
set -euo pipefail
export SCRATCH_CLOSURE_REPO="$ROOT"
if [ -n "$REPORT" ]; then : > "$REPORT"; fi

row() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"
  if [ -n "$REPORT" ]; then printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$REPORT"; fi
}

# dest_root <token> — the dest root of a cp destination: quotes stripped, cut
# before /bin/ (or a trailing /bin).
dest_root() {
  local d="${1//\"/}"
  d="${d//\'/}"
  case "$d" in
    */bin/*) printf '%s\n' "${d%%/bin/*}" ;;
    */bin) printf '%s\n' "${d%/bin}" ;;
    *) return 1 ;;
  esac
}

# loop_lines <file> — the line numbers inside a for loop (for line through done).
loop_lines() {
  awk '
    /^[[:space:]]*#/ { next }
    /(^|[;&|({[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/ { inloop = 1 }
    inloop { print FNR }
    inloop && /(^|[;&|[:space:]])done([;&|)[:space:]]|$)/ { inloop = 0 }
  ' "$1"
}

# shape <file> <lineno> — check one hand line. On success sets SRC (bin/lib
# paths as written) and DROOT; else prints the reason and returns 1.
shape() {
  local f="$1" n="$2" line prev cmd tok
  local -a w
  line=$(sed -n "${n}p" "$f")
  if [ "$n" -gt 1 ]; then prev=$(sed -n "$((n - 1))p" "$f"); else prev=""; fi
  [[ $line =~ \\[[:space:]]*$ ]] && { echo "continued line $n"; return 1; }
  [[ $prev =~ \\[[:space:]]*$ ]] && { echo "continuation line $n"; return 1; }
  cmd="$line"
  # A trailing comment, then one trailing failure handler, may go.
  cmd=$(sed -E 's/[[:space:]]+#[^"'\'']*$//' <<< "$cmd")
  cmd=$(sed -E 's/[[:space:]]*\|\|[[:space:]]*(exit[[:space:]]+[0-9]+|\{[^{}]*exit[[:space:]]+[0-9]+;?[[:space:]]*\})[[:space:]]*$//' <<< "$cmd")
  [[ $cmd == *'&&'* || $cmd == *'||'* || $cmd == *';'* ]] && { echo "chained line $n"; return 1; }
  read -r -a w <<< "$cmd"
  [ "${#w[@]}" -ge 3 ] && [ "${w[0]}" = cp ] || { echo "not a plain cp, line $n"; return 1; }
  SRC=(); DROOT=""
  for tok in "${w[@]:1}"; do
    case "$tok" in
      -*) continue ;;
      [0-9]\>*|\>*) continue ;;
    esac
    SRC+=("$tok")
  done
  [ "${#SRC[@]}" -ge 2 ] || { echo "no source, line $n"; return 1; }
  tok="${SRC[${#SRC[@]}-1]}"; unset 'SRC[${#SRC[@]}-1]'
  [[ ${tok//\"/} == */bin/lib* ]] || { echo "dest not a bin/lib dir, line $n"; return 1; }
  DROOT=$(dest_root "$tok") || { echo "dest root unreadable, line $n"; return 1; }
  [ -n "$DROOT" ] || { echo "dest root empty, line $n"; return 1; }
  for tok in "${SRC[@]}"; do
    [[ $tok =~ ^\"\$DIR/bin/lib/[^\"]+\"$ || $tok =~ ^\"\$DIR\"/bin/lib/[^\"[:space:]]+$ ]] \
      || { echo "source $tok is not \"\$DIR/bin/lib/...\", line $n"; return 1; }
  done
}

# targets <file> <root> — the bin/<x>.sh scripts (no subdir) the suite copies
# from $DIR into <root>.
targets() {
  local f="$1" want="$2" line seg d
  local -a w segs
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ \$DIR\"?/bin/[A-Za-z0-9._-]+\.sh ]] || continue
    mapfile -t segs < <(sed -E 's/&&|\|\||;/\n/g' <<< "$line")
    for seg in "${segs[@]}"; do
      read -r -a w <<< "$seg" || :
      [ "${#w[@]}" -ge 3 ] && [ "${w[0]}" = cp ] || continue
      d=$(dest_root "${w[${#w[@]}-1]}") || continue
      [ "$d" = "$want" ] || continue
      grep -oE '"\$DIR/bin/[A-Za-z0-9._-]+\.sh"|"\$DIR"/bin/[A-Za-z0-9._-]+\.sh' <<< "${w[*]:1:${#w[@]}-2}" \
        | sed -E 's/^"\$DIR"?\/?//; s/^\///; s/"$//' || :
    done
  done < "$f"
}

# summary <out-file> — the sorted summary lines of one suite run.
summary() {
  grep -iE '[0-9]+ (passed|failed)|^(PASS|FAIL)[=:]?[[:space:]]*[0-9]+|[0-9]+/[0-9]+ (ok|pass)' "$1" | LC_ALL=C sort || :
}

# prove <path> <tag> — run the suite once; sets RC and writes $T/<tag>.sum.
prove() {
  local rc=0
  (cd "$ROOT" && HARNESS_TEST_SANDBOX=1 timeout -k 10 "$CS_TIMEOUT_S" bash "$1") > "$T/$2.out" 2>&1 || rc=$?
  summary "$T/$2.out" > "$T/$2.sum"
  RC=$rc
}

sweep_one() {
  local s="$1" p n rb ra i first indent u list detail
  local -a H LOOP U LIBS EXTRA
  local -A roots=() inloop=() reach=()
  case "$s" in /*) p="$s" ;; *) p="$ROOT/$s" ;; esac
  [ -f "$p" ] || { row "$s" skip:missing; return 0; }
  if allowed "$p"; then row "$s" skip:allow; return 0; fi
  mapfile -t H < <(hand_copy_lines "$p" | cut -f2)
  [ "${#H[@]}" -gt 0 ] || { row "$s" skip:no-hand; return 0; }
  grep -vE '^[[:space:]]*#' "$p" > "$T/code" || :
  if grep -qE 'rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*[[:space:]].*bin/lib/' "$T/code" \
     || grep -qiE 'half-synced|\$T/mut' "$T/code" \
     || grep -iE 'missing|absent' "$T/code" | grep -q 'bin/lib'; then
    row "$s" skip:partial; return 0
  fi
  mapfile -t LOOP < <(loop_lines "$p")
  for i in "${LOOP[@]}"; do inloop[$i]=1; done
  LIBS=()
  for n in "${H[@]}"; do
    [ -z "${inloop[$n]:-}" ] || { row "$s" skip:shape "for loop, line $n"; return 0; }
    if ! shape "$p" "$n" > "$T/reason"; then row "$s" skip:shape "$(cat "$T/reason")"; return 0; fi
    roots[$DROOT]=1
    for u in "${SRC[@]}"; do LIBS+=("$(sed -E 's/^"\$DIR"?\/?//; s/^\///; s/"$//' <<< "$u")"); done
  done
  [ "${#roots[@]}" = 1 ] || { row "$s" skip:shape "dest roots: ${!roots[*]}"; return 0; }
  DROOT="${!roots[*]}"
  mapfile -t U < <(targets "$p" "$DROOT" | LC_ALL=C sort -u)
  [ "${#U[@]}" -gt 0 ] || { row "$s" skip:no-target "root $DROOT"; return 0; }
  for u in "${U[@]}"; do
    list=$(scratch_closure_list "$u" 2>&1) || { row "$s" skip:closure-error "$u: ${list//$'\n'/ }"; return 0; }
    while IFS= read -r i; do [ -z "$i" ] || reach[$i]=1; done <<< "$list"
  done
  EXTRA=()
  for i in "${LIBS[@]}"; do
    while IFS= read -r n; do
      n="${n#"$ROOT"/}"
      [ -n "${reach[$n]:-}" ] || EXTRA+=("$n")
    done < <(cd "$ROOT" && compgen -G "$i" || echo "$i")
  done
  if [ "${#EXTRA[@]}" -gt 0 ]; then
    row "$s" "skip:not-in-closure:$(printf '%s\n' "${EXTRA[@]}" | LC_ALL=C sort -u | paste -sd,)"; return 0
  fi
  grep -qE 'lib/scratch\.sh' "$T/code" || { row "$s" skip:no-scratch; return 0; }
  detail="${#H[@]} lines -> ${U[*]}"
  [ "$APPLY" = 1 ] || { row "$s" rewrite "$detail"; return 0; }

  prove "$p" before; rb=$RC
  [ "$rb" = 0 ] || { row "$s" "reverted:$rb/-" "red before the edit, not edited"; return 0; }
  cp -p "$p" "$T/orig"
  first="${H[0]}"
  indent=$(sed -n "${first}p" "$p" | sed -E 's/^([[:space:]]*).*/\1/')
  : > "$T/ins"
  for u in "${U[@]}"; do
    printf '%sscratch_install_closure %s "%s" >/dev/null || { echo "FAIL: closure %s"; exit 1; }\n' "$indent" "$u" "$DROOT" "$u" >> "$T/ins"
  done
  awk -v del=" ${H[*]} " -v first="$first" -v ins="$T/ins" '
    FNR == first { while ((getline l < ins) > 0) print l }
    index(del, " " FNR " ") { next }
    { print }
  ' "$p" > "$T/new"
  cat "$T/new" > "$p"
  prove "$p" after; ra=$RC
  if [ "$ra" = 0 ] && cmp -s "$T/before.sum" "$T/after.sum"; then
    row "$s" rewritten "$detail"
  else
    cp -p "$T/orig" "$p"
    if [ "$ra" = 0 ]; then row "$s" "reverted:$rb/$ra/summary" "summary lines differ"
    else row "$s" "reverted:$rb/$ra" "red after the edit, restored"; fi
  fi
}

for s in "$@"; do sweep_one "$s"; done
exit 0
