#!/bin/bash
# bin/arch-conflict-scan.sh [-C dir] [--ref REF] [--hotspots FILE] [--giant-lines N]
#   [--min-appends N] [--append-pct P] [--min-refs N] [--exclude GLOB]... [--top N] [--tsv]
# The architecture audit's conflict section (BH-5270): which files are shaped to
# collide, and the structural fix that would stop it.
#
# WHY. bin/conflict-hotspots.sh measures WHICH files collide. This says WHY, from
# the shape of the file at REF, and proposes one fix per file: split it into
# fragments, split it into modules with a generated module map, or generate it.
# prompts/arch-audit.md runs it and pastes the output into the target repo's
# AGENT_ARCHITECTURE.md. It proposes; it never files a ticket or changes a file.
#
# WHAT COUNTS. One finding per tracked file at REF, first rule that matches:
#   1 generated-committed  declared in the repo's `## Generated files` table
#                          (bin/lib/generated-table.sh) without a `committed`
#                          cell, or `@generated` / `do not edit` /
#                          `auto-generated` in its first 5 lines   -> generation
#   2 derived-index        an append registry (rule 3) whose content names
#                          >= --min-refs distinct tracked paths     -> generation
#   3 append-registry      >= --min-appends commits that only added lines to it,
#                          making >= --append-pct % of its commits  -> fragments
#   4 giant-file           >= --giant-lines lines                   -> module-map
# A path the table flags `committed` is skipped entirely: the repo keeps that
# render in git on purpose. Binary files, lockfiles (LOCKFILES below, on the
# basename) and every --exclude GLOB (on the full path) are never findings.
# A path ref is a content token with a `/` that equals a tracked path, or one
# minus its extension, as written or joined to the file's own directory.
# Defaults: --ref HEAD, --giant-lines 1000, --min-appends 10, --append-pct 80,
# --min-refs 5, --top 10. Every value used is printed on the Scanned line.
#
# HOTSPOTS. --hotspots takes the TSV bin/conflict-hotspots.sh prints. Columns
# are found by header NAME (`path`, `conflicts`, optional `rebases`), comment
# lines (`#` then a space, as its footer) are skipped, a `#12` PR id in a data
# column is not, and a path listed twice keeps its higher conflicts row. Findings
# sort by conflicts, then rebases, then rule order, then path. Measured files
# with no finding are listed under their own heading and never proposed.
#
# READS only local git: no fetch, no gh, no network, no write under -C.
#
# OUTPUT. A `## Conflict shape` markdown section on stdout, or with --tsv
#   path<TAB>kind<TAB>fix<TAB>conflicts<TAB>rebases<TAB>evidence
# in the same order. --top caps both and says how many it cut.
# rc: 0 the section printed (zero findings included), 1 not a git repo or REF
# does not resolve, 2 bad arguments or an unreadable/unusable --hotspots file.
set -uo pipefail
export LC_ALL=C

LOCKFILES=(package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock poetry.lock Gemfile.lock composer.lock go.sum '*.min.js' '*.map')

usage() {
  echo "usage: arch-conflict-scan.sh [-C dir] [--ref REF] [--hotspots FILE] [--giant-lines N] [--min-appends N] [--append-pct P] [--min-refs N] [--exclude GLOB]... [--top N] [--tsv]" >&2
  exit 2
}
posint() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "arch-conflict-scan: $1 needs a positive integer, got '$2'" >&2; usage; }; }

D=. REF=HEAD HS="" GIANT=1000 MINAPP=10 PCT=80 MINREFS=5 TOP=10 TSV=0
EXCL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || usage; D=$2; shift 2 ;;
    --ref) [ $# -ge 2 ] || usage; REF=$2; shift 2 ;;
    --hotspots) [ $# -ge 2 ] || usage; HS=$2; shift 2 ;;
    --giant-lines) [ $# -ge 2 ] || usage; posint "$1" "$2"; GIANT=$2; shift 2 ;;
    --min-appends) [ $# -ge 2 ] || usage; posint "$1" "$2"; MINAPP=$2; shift 2 ;;
    --append-pct) [ $# -ge 2 ] || usage; posint "$1" "$2"; [ "$2" -le 100 ] || usage; PCT=$2; shift 2 ;;
    --min-refs) [ $# -ge 2 ] || usage; posint "$1" "$2"; MINREFS=$2; shift 2 ;;
    --exclude) [ $# -ge 2 ] || usage; EXCL+=("$2"); shift 2 ;;
    --top) [ $# -ge 2 ] || usage; posint "$1" "$2"; TOP=$2; shift 2 ;;
    --tsv) TSV=1; shift ;;
    -h|--help) usage ;;
    *) echo "arch-conflict-scan: unknown argument '$1'" >&2; usage ;;
  esac
done

if [ -n "$HS" ] && [ ! -r "$HS" ]; then
  echo "arch-conflict-scan: cannot read --hotspots $HS" >&2; exit 2
fi
if ! git -C "$D" rev-parse --git-dir >/dev/null 2>&1; then
  echo "arch-conflict-scan: $D is not a git repository" >&2; exit 1
fi
if ! SHA=$(git -C "$D" rev-parse --verify -q "$REF^{commit}" 2>/dev/null); then
  echo "arch-conflict-scan: $REF does not resolve to a commit in $D" >&2; exit 1
fi

# shellcheck source=bin/lib/generated-table.sh
. "$(dirname "$0")/lib/generated-table.sh" || { echo "arch-conflict-scan: cannot load lib/generated-table.sh" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
G=(git -c core.quotePath=false -C "$D")

# --- hotspots: path<TAB>conflicts<TAB>rebases, one row per path -------------
HSN=0
: > "$W/hs"
if [ -n "$HS" ]; then
  awk -F'\t' '
    BEGIN { pc = cc = rc = 0 }
    /^#[ \t]/ || $0 == "#" || !NF { next }
    !hdr { hdr = 1
           for (i = 1; i <= NF; i++) { if ($i == "path") pc = i; if ($i == "conflicts") cc = i; if ($i == "rebases") rc = i }
           if (!pc || !cc) { print "arch-conflict-scan: --hotspots header lacks a path or conflicts column" > "/dev/stderr"; bad = 1; exit 2 }
           next }
    { p = $pc; c = $cc; r = rc ? $rc : 0
      if (r == "") r = 0
      if (c !~ /^[0-9]+$/ || r !~ /^[0-9]+$/) { print "arch-conflict-scan: --hotspots row for " p " has a non-integer count" > "/dev/stderr"; bad = 1; exit 2 }
      if (!(p in C) || c + 0 > C[p] + 0 || (c + 0 == C[p] + 0 && r + 0 > R[p] + 0)) { if (!(p in C)) o[++n] = p; C[p] = c; R[p] = r } }
    END { if (bad) exit 2
          if (!hdr) { print "arch-conflict-scan: --hotspots has no header row" > "/dev/stderr"; exit 2 }
          for (i = 1; i <= n; i++) print o[i] "\t" C[o[i]] + 0 "\t" R[o[i]] + 0 }
  ' "$HS" > "$W/hs" || exit 2
  HSN=$(wc -l < "$W/hs" | tr -d ' ')
fi

# --- what is tracked at REF, and how many lines each text file has ----------
"${G[@]}" ls-tree -r --name-only "$SHA" > "$W/tracked" 2>/dev/null || { echo "arch-conflict-scan: cannot list $SHA" >&2; exit 1; }
"${G[@]}" grep -I -c '' "$SHA" -- > "$W/grep.out" 2>/dev/null
awk -v n=$((${#SHA} + 2)) '{ s = substr($0, n); k = s; sub(/:[0-9]+$/, "", k); c = substr(s, length(k) + 2); print k "\t" c }' \
  "$W/grep.out" > "$W/lines"
NTEXT=$(wc -l < "$W/lines" | tr -d ' ')

# --- the generated-files table: declared paths and the committed opt-out ----
_gen_table_rows "$D" "$SHA" | awk -F'\t' 'NF { if (!($1 in k)) { o[++n] = $1; k[$1] = 0 } if ($2 == 1) k[$1] = 1 }
  END { for (i = 1; i <= n; i++) print o[i] "\t" k[o[i]] }' > "$W/decl"
: > "$W/declared"
while IFS=$'\t' read -r pat kept; do
  [ -n "$pat" ] || continue
  case "$pat" in
    *[*?[]*)
      while IFS= read -r p; do
        gen_path_matches "$p" "$pat" && printf '%s\t%s\n' "$p" "$kept"
      done < "$W/tracked" ;;
    *) grep -qxF -- "$pat" "$W/tracked" && printf '%s\t%s\n' "$pat" "$kept" ;;
  esac
done < "$W/decl" >> "$W/declared"

# --- the universe: tracked, not excluded, not opted out --------------------
: > "$W/excluded"
while IFS= read -r p; do
  b=${p##*/} hit=""
  for g in "${LOCKFILES[@]}"; do
    # shellcheck disable=SC2254
    case "$b" in $g) hit=1; break ;; esac
  done
  if [ -z "$hit" ]; then
    for g in ${EXCL[@]+"${EXCL[@]}"}; do
      # shellcheck disable=SC2254
      case "$p" in $g) hit=1; break ;; esac
    done
  fi
  [ -n "$hit" ] && printf '%s\n' "$p"
done < "$W/tracked" > "$W/excluded"
awk -F'\t' 'BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] } f == 1 { x[$0] = 1; next } f == 2 { if ($2 == 1) x[$1] = 1; next } !($0 in x)' \
  "$W/excluded" "$W/declared" "$W/tracked" > "$W/universe"

# --- append history: path<TAB>touches<TAB>appends ---------------------------
# A shallow clone's boundary commits read as roots that add the whole tree, so
# their numstat is skipped: the counts stay a lower bound instead of inflating.
"${G[@]}" log "$SHA" --no-merges --no-renames --numstat --format='@%H' > "$W/log" 2>/dev/null
SHF=$(git -C "$D" rev-parse --path-format=absolute --git-path shallow 2>/dev/null)
if [ -n "$SHF" ] && [ -r "$SHF" ]; then cp "$SHF" "$W/shallow"; else : > "$W/shallow"; fi
awk -F'\t' 'BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] }
  f == 1 { sh[$1] = 1; next }
  /^@/ { skip = (substr($0, 2) in sh); next }
  skip || !NF || $1 == "-" || $2 == "-" { next }
  { t[$3]++; if ($2 == 0 && $1 > 0) a[$3]++ }
  END { for (p in t) print p "\t" t[p] "\t" a[p] + 0 }' "$W/shallow" "$W/log" > "$W/hist"

# append-qualified text files in the universe get their content read for refs
awk -F'\t' -v m="$MINAPP" -v pct="$PCT" 'BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] }
  f == 1 { u[$0] = 1; next } f == 2 { txt[$1] = 1; next }
  ($1 in u) && ($1 in txt) && $3 >= m && $3 * 100 >= pct * $2 { print $1 }' \
  "$W/universe" "$W/lines" "$W/hist" > "$W/cand"

# --- one cat-file pass over the universe's text files: header markers + refs -
awk -F'\t' 'BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] } f == 1 { u[$0] = 1; next } ($1 in u) { print $1 }' "$W/universe" "$W/lines" > "$W/texts"
awk -v s="$SHA" '{ print s ":" $0 }' "$W/texts" | "${G[@]}" cat-file --batch > "$W/batch" 2>/dev/null
awk '
  # cat-file prints "<oid> blob <size>", <size> bytes, then one newline. A line
  # costs length+1 bytes, so a file with no final newline ends at rem == -1 on
  # the delimiter itself, and one with a final newline leaves an empty line
  # that the header rule skips.
  function stemof(p,   b, d, i) {
    i = match(p, /[^\/]*$/); d = substr(p, 1, i - 1); b = substr(p, i)
    i = match(b, /\.[^.]*$/)
    return (i > 1) ? d substr(b, 1, i - 1) : ""
  }
  function resolve(t) { if (t in T) return t; if (t in S) return S[t]; return "" }
  # hdrmark(p, s) — the generated-file marker in line s of file p, or "".
  # Only a COMMENT line in p'"'"'s own comment syntax counts, and only as a header:
  # the comment text starts with the marker, or it also says "generated"
  # ("Code generated by X. DO NOT EDIT."). Prose ("Do not edit it here." in a
  # README) and string data (a JSON payload carrying DO NOT EDIT) never do.
  function hdrmark(p, s,   e, c, low) {
    e = p; sub(/^.*\//, "", e)
    e = (match(e, /\.[^.]+$/) ? tolower(substr(e, RSTART + 1)) : "")
    if (e == "json") return ""
    if (e ~ /^(md|markdown|html|htm|xml|svg)$/) c = "<!--"
    else if (e ~ /^(js|mjs|cjs|ts|tsx|jsx|go|c|h|cc|cpp|java|rs|css|scss|swift|kt)$/) c = "//|/\\*|\\*"
    else if (e == "sql") c = "--|/\\*"
    else if (e ~ /^(sh|bash|py|rb|pl|yml|yaml|toml|conf|cfg|ini|tsv|txt|env|mk|cron)$/ || e == "") c = "#"
    else c = "#|//|/\\*|<!--|--"
    low = tolower(s)
    if (!match(low, "^[ \t]*(" c ")[ \t*!-]*")) return ""
    low = substr(low, RLENGTH + 1)
    if (match(low, /^(@generated|do not edit|auto-?generated)/)) return substr(low, RSTART, RLENGTH)
    if (low ~ /generated/ && match(low, /@generated|do not edit|auto-?generated/)) return substr(low, RSTART, RLENGTH)
    return ""
  }
  function fin() {
    if (mk != "") print "M\t" p "\t" mk
    if (isc) print "R\t" p "\t" nref
  }
  BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] }
  f == 1 { T[$0] = 1; st = stemof($0); if (st != "" && !(st in S)) S[st] = $0; next }
  f == 2 { cand[$0] = 1; next }
  f == 3 { order[++no] = $0; next }
  !body {
    if ($0 ~ / missing$/) { obj++; next }
    if ($0 !~ /^[0-9a-f]+ blob [0-9]+$/) next
    obj++; p = order[obj]; rem = $3 + 0; ln = 0; mk = ""; nref = 0; split("", seen)
    dir = p; if (sub(/\/[^\/]*$/, "", dir) == 0) dir = ""
    isc = (p in cand); body = (rem > 0)
    next
  }
  {
    ln++
    if (ln <= 5 && mk == "") mk = hdrmark(p, $0)
    if (isc) {
      line = $0; gsub(/[^A-Za-z0-9_.\/@-]+/, " ", line)
      n = split(line, a, " ")
      for (i = 1; i <= n; i++) {
        t = a[i]; if (index(t, "/") == 0) continue
        sub(/^(\.\/)+/, "", t)
        r = resolve(t); if (r == "" && dir != "") r = resolve(dir "/" t)
        if (r != "" && r != p && !(r in seen)) { seen[r] = 1; nref++ }
      }
    }
    rem -= length($0) + 1
    if (rem <= 0) { fin(); body = 0 }
  }
' "$W/tracked" "$W/cand" "$W/texts" "$W/batch" > "$W/content"

# --- classify: sortkey fields, then the row -------------------------------
#   measured<TAB>conflicts<TAB>rebases<TAB>kindorder<TAB>path<TAB>kind<TAB>fix<TAB>c<TAB>r<TAB>evidence
awk -F'\t' -v giant="$GIANT" -v m="$MINAPP" -v pct="$PCT" -v mr="$MINREFS" '
  BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] }
  f == 1 { u[$0] = 1; uo[++nu] = $0; next }
  f == 2 { L[$1] = $2; next }
  f == 3 { if ($2 == 0) dec[$1] = 1; next }
  f == 4 { tc[$1] = $2; ap[$1] = $3; next }
  f == 5 { if ($1 == "M") mk[$2] = $3; else if ($1 == "R") rf[$2] = $3; next }
  f == 6 { hc[$1] = $2; hr[$1] = $3; next }
  END {
    for (i = 1; i <= nu; i++) {
      p = uo[i]; k = ""
      if (p in dec) { k = "generated-committed"; o = 1; fx = "generation"; ev = "declared in the Generated files table" }
      else if (p in mk) { k = "generated-committed"; o = 1; fx = "generation"; ev = "marked \x27" mk[p] "\x27 in its header" }
      else if (ap[p] >= m && ap[p] * 100 >= pct * tc[p]) {
        # A derived index is a LIST: at least half its lines name a tracked file,
        # and it is not a dotfile (.gitignore holds patterns, not an index).
        # Code that imports many paths is not one (lead review note on 41d7a343).
        b = p; sub(/^.*\//, "", b)
        if (rf[p] >= mr && rf[p] * 2 >= L[p] && b !~ /^\./) { k = "derived-index"; o = 2; fx = "generation"; ev = ap[p] " of " tc[p] " commits only appended; names " rf[p] " tracked files" }
        else { k = "append-registry"; o = 3; fx = "fragments"; ev = ap[p] " of " tc[p] " commits only appended" }
      }
      else if (L[p] >= giant) { k = "giant-file"; o = 4; fx = "module-map"; ev = L[p] " lines" }
      if (k == "") continue
      if (p in hc) { ms = 0; c = hc[p]; r = hr[p] } else { ms = 1; c = 0; r = 0 }
      print ms "\t" c "\t" r "\t" o "\t" p "\t" k "\t" fx "\t" ((p in hc) ? c : "-") "\t" ((p in hc) ? r : "-") "\t" ev
    }
  }' "$W/universe" "$W/lines" "$W/declared" "$W/hist" "$W/content" "$W/hs" \
  | sort -t "$(printf '\t')" -k1,1n -k2,2nr -k3,3nr -k4,4n -k5,5 > "$W/findings"
NF_ALL=$(wc -l < "$W/findings" | tr -d ' ')
head -n "$TOP" "$W/findings" > "$W/shown"
MORE=$((NF_ALL - $(wc -l < "$W/shown" | tr -d ' ')))

if [ "$TSV" = 1 ]; then
  printf 'path\tkind\tfix\tconflicts\trebases\tevidence\n'
  cut -f5- "$W/shown"
  [ "$MORE" -gt 0 ] && echo "# $MORE more findings not shown (re-run with --top $NF_ALL)."
  exit 0
fi

# --- markdown --------------------------------------------------------------
NAME=$(basename "$(git -C "$D" rev-parse --show-toplevel 2>/dev/null || (cd "$D" && pwd))")
if [ -n "$HS" ]; then HSLINE="$(basename "$HS") ($HSN rows)"; else HSLINE="not supplied"; fi
SHALLOW=""
[ "$(git -C "$D" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && SHALLOW=" History: shallow, append counts are a lower bound."

echo "## Conflict shape"
echo
echo "Scanned \`${SHA:0:12}\` of $NAME: $NTEXT tracked text files. Thresholds: giant file >= $GIANT lines; append registry >= $MINAPP pure-append commits making >= $PCT% of its commits; derived index names >= $MINREFS tracked files. Hotspots: $HSLINE.$SHALLOW"
echo
if [ "$NF_ALL" = 0 ]; then
  echo "No conflict-shape findings at this ref."
else
  echo "| file | finding | evidence | conflicts | rebases | proposed fix |"
  echo "|---|---|---|---|---|---|"
  awk -F'\t' '{ p = $5; gsub(/\|/, "\\|", p)
    c = ($8 == "-") ? "—" : $8; r = ($9 == "-") ? "—" : $9
    print "| `" p "` | " $6 " | " $10 " | " c " | " r " | " $7 " |" }' "$W/shown"
  [ "$MORE" -gt 0 ] && { echo; echo "$MORE more findings not shown (re-run with --top $NF_ALL)."; }
  echo
  echo "### Proposed tickets"
  echo
  echo "These are proposals for a person or the orchestrator to file. This scan files nothing and changes nothing."
  awk -F'\t' -v giant="$GIANT" '
    {
      p = $5; k = $6; fx = $7; c = $8; ev = $10
      dir = p; if (sub(/\/[^\/]*$/, "", dir) == 0) dir = ""
      b = p; sub(/^.*\//, "", b); stem = b; if (match(b, /\.[^.]*$/) > 1) stem = substr(b, 1, RSTART - 1)
      pre = (dir == "") ? "" : dir "/"
      conf = (c != "-" && c > 0) ? c : ""
      if (k == "append-registry") {
        split(ev, e, " ")
        title = "Split `" p "` into fragments"
        sd = "`" p "` grew by " e[1] " pure appends out of " e[3] " commits" (conf != "" ? ", and caused " conf " merge conflicts in the hotspot window" : "") ". Move each entry into its own file under `" pre stem ".d/`, build `" p "` from those files with a generator, declare `" p "` in the `## Generated files` table, and stop appending to it by hand."
      } else if (k == "derived-index") {
        n = split(ev, e, " ")
        title = "Generate `" p "` from the files it lists"
        sd = "`" p "` names " e[n - 2] " files that already exist in the repo and is kept by hand. Generate it from the files it lists, declare it in the `## Generated files` table, and stop editing it directly."
      } else if (k == "generated-committed") {
        title = "Stop committing generated `" p "`"
        sd = "`" p "` is generated (" ev ") but committed. Regenerate it at build or merge time and git-ignore it, or mark its table row `committed` if CI checks the committed render."
      } else {
        split(ev, e, " ")
        title = "Split `" p "` into modules with a generated module map"
        sd = "`" p "` is " e[1] " lines" (conf != "" ? ", with " conf " merge conflicts in the hotspot window" : "") ". Split it by concern into modules under `" pre stem "/`, keep `" p "` as a thin entry point, and generate a module map that lists each module and what it owns."
      }
      print ""; print "#### " NR ". " title; print "Type: " fx; print "Scope draft: " sd
    }' "$W/shown"
fi

# measured hotspots that no finding explains: listed, never proposed
awk -F'\t' 'BEGIN { for (i = 1; i < ARGC; i++) A[ARGV[i]] = i } { f = A[FILENAME] } f == 1 { fd[$5] = 1; next } f == 2 { tr[$0] = 1; next } f == 3 { ex[$0] = 1; next }
  !($1 in fd) { note = !($1 in tr) ? " (not at this ref)" : (($1 in ex) ? " (excluded)" : ""); print $2 "\t" $3 "\t" $1 "\t" note }' \
  "$W/findings" "$W/tracked" "$W/excluded" "$W/hs" | sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3 > "$W/unexp"
NU=$(wc -l < "$W/unexp" | tr -d ' ')
if [ "$NU" -gt 0 ]; then
  echo
  echo "### Measured hotspots with no structural finding"
  echo
  echo "| file | conflicts | rebases |"
  echo "|---|---|---|"
  head -n "$TOP" "$W/unexp" | awk -F'\t' '{ p = $3; gsub(/\|/, "\\|", p); print "| `" p "`" $4 " | " $1 " | " $2 " |" }'
  [ "$NU" -gt "$TOP" ] && { echo; echo "$((NU - TOP)) more measured hotspots not shown (re-run with --top $NU)."; }
fi
exit 0
