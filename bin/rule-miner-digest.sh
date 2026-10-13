#!/bin/bash
# bin/rule-miner-digest.sh — BH-1749.0 (#1762) contract, BH-1749.1 (#1763) body:
# the rule-miner digest CLI.
#
#   rule-miner-digest.sh <findings.log> <inventory.tsv> <out.md> <ids-out>
#
# THE CONTRACT (fixed; the siblings of #1749 build on it):
#   <inventory.tsv>  what bin/rule-miner.sh add_incident writes, one row per
#                    incident: nn \t id \t bundle-path \t summary
#   <out.md>         the digest the miner session reads, headed "# Rule-miner digest"
#   <ids-out>        every inventory id the digest covers, one per line
#   rc 0 on success; rc 1 with a stderr line when an input cannot be read or an
#   output cannot be written; rc 2 on wrong usage, including a knob that is not
#   a positive integer (refused, never clamped). A failed run leaves no
#   half-written output file.
#
# Knobs: RULE_MINER_TOP_FAMILIES (default 40), RULE_MINER_DIGEST_MAX_TOKENS
# (default 40000, tokens = bytes/4), PROMOTE_MIN (default 3).
#
# A deterministic pre-aggregation: bash + awk, no network, no LLM, LC_ALL=C (so
# bytes are bytes and sort order is stable). No clock time is written, only the
# window's start date, so two runs on one UTC day are byte-identical.
#   Families   findings.log rows dated on or after 30 days ago, parsed with the
#              field walk of bin/rule-miner.sh (metadata stops at `::`;
#              `family=` empty or `-` is skipped). Per family: count, first and
#              last seen, projects, cited rules, and the text after " :: " cut to
#              200 bytes from the first and the latest occurrence (by date+time;
#              the second is dropped when identical). Families with count >=
#              PROMOTE_MIN, sorted count desc then family asc, top N.
#   Rules      each rule cited by a top-N family: its rows in those families and
#              which of them cite it.
#   Other incidents  every inventory row that is not a `findings:<family>` of a
#              qualifying family, in inventory order: id + summary, and the first
#              400 bytes of its bundle with newlines/tabs flattened to spaces.
# Budget: the header, headings, Rules section and a reserve for the INCOMPLETE
# line always go in; then family blocks in rank order, then incidents in
# inventory order, each list stopping at the first entry that would take the
# file past MAX_TOKENS*4 bytes. If that fixed part alone is over the budget,
# nothing else is written and the file is over it. Qualifying families not
# written (cut by N or by bytes) and incidents not written are counted on one
# "INCOMPLETE:" header line, present only when that count is non-zero.
# <ids-out> lists, in inventory order, only the ids whose content was written
# (a `findings:<family>` id when its family block was), so the caller defers
# the rest instead of marking them seen.
set -uo pipefail
export LC_ALL=C

if [ "$#" -ne 4 ]; then
  echo "usage: rule-miner-digest.sh <findings.log> <inventory.tsv> <out.md> <ids-out>" >&2
  exit 2
fi
findings="$1" inv="$2" out="$3" ids="$4"

knob() { # knob <name> <default>: an explicitly set value must be a positive integer
  local v="${!1-$2}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "rule-miner-digest: $1='$v' is not a positive integer" >&2; exit 2; }
  printf '%s' "$v"
}
TOP=$(knob RULE_MINER_TOP_FAMILIES 40) || exit 2
MAXTOK=$(knob RULE_MINER_DIGEST_MAX_TOKENS 40000) || exit 2
PMIN=$(knob PROMOTE_MIN 3) || exit 2

for f in "$findings" "$inv"; do
  [ -r "$f" ] || { echo "rule-miner-digest: cannot read $f" >&2; exit 1; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/rule-miner-digest.XXXXXX") || { echo "rule-miner-digest: no temp dir" >&2; exit 1; }
trap 'rm -rf "$W"; rm -f "$out.tmp.$$" "$ids.tmp.$$"' EXIT
fail() { echo "rule-miner-digest: $1" >&2; exit 1; }

# Same window as bin/rule-miner.sh (BSD fallback keeps it runnable off Linux).
SINCE30=$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null \
          || date -u -v-30d +%Y-%m-%d 2>/dev/null || echo 0000-00-00)

# One row per qualifying family, ranked:
#   fam \t count \t first \t last \t projs \t rules \t rule:rows,... \t sample1 \t sample2
awk -v s="$SINCE30" -v m="$PMIN" '
  $1 >= s {
    fam = ""; proj = ""; rule = ""
    for (i = 1; i <= NF; i++) {
      if ($i == "::") break
      else if (substr($i,1,7) == "family=") fam  = substr($i,8)
      else if (substr($i,1,5) == "rule=")   rule = substr($i,6)
      else if (proj == "" && substr($i,1,1) == "[") { proj = $i; gsub(/[][]/,"",proj) }
    }
    if (fam == "" || fam == "-") next
    if (!(fam in n)) order[++nf] = fam
    n[fam]++
    if (proj != "" && index("," projs[fam] ",", "," proj ",") == 0)
      projs[fam] = projs[fam] (projs[fam] == "" ? "" : ",") proj
    if (rule != "-" && rule != "") {
      if (!((fam, rule) in rc)) rl[fam] = rl[fam] (rl[fam] == "" ? "" : ",") rule
      rc[fam, rule]++
    }
    p = index($0, " :: "); txt = p ? substr($0, p + 4, 200) : ""
    gsub(/[\t\r]/, " ", txt)
    key = $1 " " $2
    if (!(fam in fk) || key < fk[fam]) { fk[fam] = key; fd[fam] = $1; fs[fam] = txt }
    if (!(fam in lk) || key >= lk[fam]) { lk[fam] = key; ld[fam] = $1; ls[fam] = txt }
  }
  END {
    for (k = 1; k <= nf; k++) {
      f = order[k]; if (n[f] < m) continue
      c = ""; r = split(rl[f], a, ",")
      for (j = 1; j <= r; j++) c = c (j > 1 ? "," : "") a[j] ":" rc[f, a[j]]
      printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f, n[f], fd[f], ld[f], projs[f],
        (rl[f] == "" ? "-" : rl[f]), c, fs[f], ((n[f] > 1 && ls[f] != fs[f]) ? ls[f] : "")
    }
  }' "$findings" | sort -t$'\t' -k2,2nr -k1,1 > "$W/q.tsv" || fail "cannot aggregate $findings"
QN=$(wc -l < "$W/q.tsv")
head -n "$TOP" "$W/q.tsv" > "$W/top.tsv"

# Rules over the top-N families, rows desc then rule asc.
awk -F'\t' '{ r = split($7, a, ",")
    for (j = 1; j <= r; j++) { k = match(a[j], /:[0-9]+$/); x = substr(a[j], 1, k - 1)
      rows[x] += substr(a[j], k + 1); fams[x] = fams[x] (fams[x] == "" ? "" : ",") $1 } }
  END { for (x in rows) printf "%d\t%s\t- %s: %d rows; families: %s\n", rows[x], x, x, rows[x], fams[x] }' "$W/top.tsv" \
  | sort -t$'\t' -k1,1nr -k2,2 | cut -f3- > "$W/rules.txt"
[ -s "$W/rules.txt" ] || echo "(none)" > "$W/rules.txt"

# Classify inventory rows: a findings:<fam> of a qualifying family is covered by
# its family block; everything else is an "other incident".
declare -A QUAL=()
while IFS=$'\t' read -r fam _; do QUAL[$fam]=1; done < "$W/q.tsv"
NINC=0
while IFS=$'\t' read -r _ id _ _; do
  [[ "$id" == findings:* ]] && [ -n "${QUAL[${id#findings:}]:-}" ] || NINC=$((NINC+1))
done < "$inv"

dir=$(dirname "$inv")
BUDGET=$((MAXTOK * 4))
{
  echo "# Rule-miner digest"
  echo "Window: findings.log rows since $SINCE30 (30 days); PROMOTE_MIN=$PMIN; top $TOP families; budget $MAXTOK tokens"
} > "$W/head.txt"
{ echo; echo "## Recurring finding families"; [ "$QN" -gt 0 ] || echo "(none)"; } > "$W/h1.txt"
{ echo; echo "## Rules cited"; cat "$W/rules.txt"; echo; echo "## Other incidents"; [ "$NINC" -gt 0 ] || echo "(none)"; } > "$W/h2.txt"
reserve="INCOMPLETE: 0000000000 families and 0000000000 incidents omitted by the digest budget; bundles on disk at $dir"
used=$(( $(cat "$W/head.txt" "$W/h1.txt" "$W/h2.txt" | wc -c) + ${#reserve} + 1 ))

# Family blocks, rank order, stopping at the first that does not fit.
awk -F'\t' -v room=$((BUDGET - used)) -v wf="$W/wfam" '
  { b = "### " $1 "\n- count: " $2 "\n- first seen: " $3 "\n- last seen: " $4 "\n- projects: " $5 "\n- rules: " $6 "\n- sample: " $8 "\n"
    if ($9 != "") b = b "- sample: " $9 "\n"
    if (length(b) > room) exit
    room -= length(b); printf "%s", b; print $1 > wf }' "$W/top.tsv" > "$W/fam.txt" || fail "cannot render families"
touch "$W/wfam"
used=$(( used + $(wc -c < "$W/fam.txt") ))
declare -A WFAM=()
while IFS= read -r fam; do WFAM[$fam]=1; done < "$W/wfam"
NFW=$(wc -l < "$W/wfam")

# Incidents and ids-out, inventory order.
: > "$W/inc.txt"; : > "$W/ids"
NIW=0 full=0
while IFS=$'\t' read -r _ id path sum; do
  if [[ "$id" == findings:* ]] && [ -n "${QUAL[${id#findings:}]:-}" ]; then
    [ -n "${WFAM[${id#findings:}]:-}" ] && echo "$id" >> "$W/ids"
    continue
  fi
  [ "$full" = 0 ] || continue
  if [ -r "$path" ] && [ -f "$path" ]; then ex=$(head -c 400 "$path" | tr '\n\t\r' '   ')
  else ex="(bundle not readable)"; fi
  entry="- $id — $sum"$'\n'"  excerpt: $ex"$'\n'
  if [ $((used + ${#entry})) -gt "$BUDGET" ]; then full=1; continue; fi
  printf '%s' "$entry" >> "$W/inc.txt"; echo "$id" >> "$W/ids"
  used=$((used + ${#entry})); NIW=$((NIW+1))
done < "$inv"

fo=$((QN - NFW)) io=$((NINC - NIW))
if ! { { cat "$W/head.txt"
         [ $((fo + io)) -eq 0 ] || echo "INCOMPLETE: $fo families and $io incidents omitted by the digest budget; bundles on disk at $dir"
         cat "$W/h1.txt" "$W/fam.txt"
         cat "$W/h2.txt" "$W/inc.txt"; } > "$out.tmp.$$" \
        && cp "$W/ids" "$ids.tmp.$$" \
        && mv -f "$out.tmp.$$" "$out" && mv -f "$ids.tmp.$$" "$ids"; }; then
  fail "could not write $out / $ids"
fi
exit 0
