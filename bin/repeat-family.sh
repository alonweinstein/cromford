#!/bin/bash
# bin/repeat-family.sh — repeat-family rate: does a finding family come BACK
# after the miner has ruled on it.
#
# The rule loop has counters at every stage except the last one. findings-log.sh
# counts findings harvested, rule-miner.sh counts families mined and checks
# promoted, guardrail-promote.sh counts PRs opened — and every one of those
# numbers goes UP whether or not a single rule ever stopped anything. A loop
# that mines diligently and changes nothing looks, in all of them, exactly like
# a loop that works. The only number that can tell the two apart is recurrence
# AFTER a ruling: the miner saw this class, ruled on it, and here it is again.
#
# So, for every family the miner has consumed:
#   ruled_date      — from the mining bundle DIRNAME (state/rule-mining/<date>/
#                     inventory.tsv). seen.txt records the set one-shot and
#                     carries no dates at all, so the directory is the only
#                     record of WHEN a family was ruled on.
#   recurrences_14d — rows in logs/findings.log for that family, dated strictly
#                     AFTER its ruling date and inside the window.
#
# STRICTLY AFTER is the whole metric. A family is mined BECAUSE it occurred, so
# its own evidence sits in the log with earlier dates; counting that would score
# every ruling as an instant failure and the readout would report a broken loop
# forever, which is as useless as reporting a perfect one.
#
# HONESTY ABOUT THE DATA. logs/findings.log was bootstrapped in a single harvest
# on 2026-08-26 — ~11.6K rows, every one stamped with the harvest date rather
# than the date its review was actually written. Pre-bootstrap history is
# date-compressed onto that one day, so a family whose ruling ALSO lands on it
# has no clean window at all: nothing can be "strictly after" a date that every
# historical row already carries. Those families read zero for structural
# reasons, not because the rule held, and every output path here says so.
# Post-bootstrap data is the only clean signal this metric has.
#
# THIS IS A READOUT, NEVER A GATE. rc 0 on every path — missing log, missing
# rule-mining tree, nothing ruled yet, junk env. Nothing is written except
# state/repeat-family.json (same flat shape discipline as reopen-rate.json:
# {family: {ruled_date, recurrences_14d, projects}}), and that file is written
# only when something was actually measured — an absent findings.log leaves no
# JSON, because a `{}` a consumer reads as "measured, nothing found" is the
# dead-feed smell wearing a data file's clothes.
#
# Usage: repeat-family.sh          summary line + per-family table + caveat
#        repeat-family.sh --line   the summary line only (for the nightly beat)
set -uo pipefail
H="${HARNESS:-/root/harness}"
MODE=table
case "${1:-}" in
  --line) MODE=line ;;
  -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
  "") ;;
  *) echo "repeat-family: unknown argument '$1' (expected --line)" >&2; exit 0 ;;
esac

FINDINGS="$H/logs/findings.log"
MINE="$H/state/rule-mining"
OUT="$H/state/repeat-family.json"
# The date every bootstrapped findings row carries. Env-tunable because it is a
# fact about one file's history, not a law.
BOOT="${REPEAT_BOOTSTRAP_DATE:-2026-08-26}"
# Junk falls back rather than breaking the window — an unparseable knob must
# never silently widen or collapse the measurement.
WINDOW="${REPEAT_WINDOW_DAYS:-14}"
case "$WINDOW" in ''|*[!0-9]*) WINDOW=14 ;; esac
[ "$WINDOW" -gt 0 ] 2>/dev/null || WINDOW=14
MAXROWS="${REPEAT_TABLE_MAX:-25}"
case "$MAXROWS" in ''|*[!0-9]*) MAXROWS=25 ;; esac

# REHYDRATE BEFORE THE ABSENCE TEST (BH-436). "absent or empty" is this script's
# honest NOT MEASURED answer, and after a hub wipe (#388) it would be the answer
# forever. Guarded and silent: no client on the box, or a file already on disk,
# and this is byte-for-byte the previous behaviour with zero requests.
if [ -r "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" 2>/dev/null
  log_rehydrate findings "$FINDINGS" 14 >/dev/null 2>&1 || true
fi

if [ ! -s "$FINDINGS" ]; then
  echo "repeat-family: logs/findings.log is absent or empty — recurrence NOT MEASURED (this is unknown, not a clean record); nothing written"
  exit 0
fi

# The published file names its window (recurrences_14d), so a non-default
# window computes and prints but does not overwrite it.
JSONOUT=""; [ "$WINDOW" = 14 ] && JSONOUT="$OUT.$$"
SINCE=$(date -u -d "$WINDOW days ago" +%Y-%m-%d 2>/dev/null \
        || date -u -v-"$WINDOW"d +%Y-%m-%d 2>/dev/null || echo 0000-00-00)

TMPD=$(mktemp -d) || exit 0
trap 'rm -rf "$TMPD"' EXIT
RULED="$TMPD/ruled.tsv"

# ── The ruled set: which families the miner has consumed, and when ────────────
# Two sources, unioned. The bundle dirs carry the date; seen.txt carries
# families whose bundle has since been cleaned — still ruled, date unrecoverable.
# Sorting date-ascending with "unknown" last means a real date always wins for a
# family that appears in both.
{
  for D in "$MINE"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -f "$D/inventory.tsv" ] || continue
    B=$(basename "$D")
    awk -F'\t' -v iso="${B:0:4}-${B:4:2}-${B:6:2}" \
      '$2 ~ /^findings:/ && length($2) > 9 { print substr($2, 10) "\t" iso }' \
      "$D/inventory.tsv" 2>/dev/null
  done
  [ -f "$MINE/seen.txt" ] && awk \
    '/^findings:./ { print substr($0, 10) "\tunknown" }' "$MINE/seen.txt" 2>/dev/null
} 2>/dev/null | sort -k1,1 -k2,2 | awk -F'\t' '!($1 in s) { s[$1] = 1; print }' > "$RULED"

if [ ! -s "$RULED" ]; then
  echo "repeat-family: no families ruled by the miner yet (nothing matching findings:<family> in $MINE/*/inventory.tsv or seen.txt) — there is nothing to measure recurrence against"
  exit 0
fi

# ── Count, emit, and write the JSON in one pass ──────────────────────────────
awk -v since="$SINCE" -v window="$WINDOW" -v boot="$BOOT" \
    -v mode="$MODE" -v maxrows="$MAXROWS" -v out="$JSONOUT" '
FILENAME == ARGV[1] {
  fam = $1; rd[fam] = $2; n[fam] = 0; projs[fam] = ""
  if ($2 == boot) bootn++
  famn++
  next
}
{
  # Same field walk as rule-miner.sh source (e): stop at the `::` separator so a
  # reviewer sentence quoting "family=" cannot reassign its own row.
  fam = ""; proj = ""
  for (i = 1; i <= NF; i++) {
    if ($i == "::") break
    else if (substr($i, 1, 7) == "family=") fam = substr($i, 8)
    else if (proj == "" && substr($i, 1, 1) == "[") { proj = $i; gsub(/[][]/, "", proj) }
  }
  if (fam == "" || fam == "-") next        # the unkeyed fallback is not a family
  if (!(fam in rd)) next                   # never ruled on: recurrence undefined
  if (rd[fam] == "unknown") next           # no ruling date: not countable
  if ($1 <= rd[fam]) next                  # the evidence it was mined from
  if ($1 < since) next
  n[fam]++
  if (index("," projs[fam] ",", "," proj ",") == 0)
    projs[fam] = projs[fam] (projs[fam] == "" ? "" : ",") proj
}
END {
  total = 0; topf = ""; topn = 0
  for (f in rd) {
    if (rd[f] == "unknown") continue
    total += n[f]
    if (n[f] > topn) { topn = n[f]; topf = f }
  }
  line = sprintf("repeat-family: %d recurrence%s across %d ruled famil%s (window %dd)",
                 total, (total == 1 ? "" : "s"), famn, (famn == 1 ? "y" : "ies"), window)
  if (topn > 0) line = line sprintf("; top: %s x%d [%s]", topf, topn, projs[topf])
  else          line = line " — no ruled family has come back"
  # The caveat travels with the number on EVERY path, one-line beat included: a
  # structural zero reported as a clean record is the failure this readout is
  # for. Suffixed rather than dropped in --line mode.
  cav = ""
  if (bootn > 0)
    cav = sprintf("caveat: %d of %d ruling%s land on the findings.log bootstrap date (%s) — pre-bootstrap history is date-compressed onto that one stamp, so those families cannot show a recurrence from before it. Post-bootstrap data is the only clean signal.",
                  bootn, famn, (bootn == 1 ? "" : "s"), boot)
  if (mode == "line") {
    if (cav != "") line = line sprintf("; %d/%d rulings bootstrap-dated (%s) — window not yet clean", bootn, famn, boot)
    print line
  } else {
    print line
    print ""
    printf "%-16s  %-10s  %-15s  %s\n", "family", "ruled", "recurrences_" window "d", "projects"
    shown = 0; hidden = 0
    # Non-zero rows always print. Zero rows print until the cap, then are
    # counted out loud — elided, never dropped without saying so.
    for (pass = 1; pass <= 3; pass++) {
      for (f in rd) {
        if (pass == 1 && !(rd[f] != "unknown" && n[f] > 0)) continue
        if (pass == 2 && !(rd[f] != "unknown" && n[f] == 0)) continue
        if (pass == 3 && rd[f] != "unknown") continue
        if (pass > 1 && shown >= maxrows) { hidden++; continue }
        shown++
        printf "%-16s  %-10s  %-15s  %s\n", f, rd[f],
               (rd[f] == "unknown" ? "unknown" : n[f]),
               (rd[f] == "unknown" ? "-" : (projs[f] == "" ? "-" : projs[f]))
      }
    }
    if (hidden > 0) printf "(+%d ruled famil%s with 0 recurrences not listed — REPEAT_TABLE_MAX=%d)\n", hidden, (hidden == 1 ? "y" : "ies"), maxrows
    if (cav != "") { print ""; print cav }
  }
  # {family: {ruled_date, recurrences_14d, projects}} — flat, like
  # reopen-rate.json, whose key likewise names its window. An unknown ruling
  # date writes null, never 0. Only the canonical 14d window is published: an
  # exploratory REPEAT_WINDOW_DAYS run prints its table but must not leave 25
  # days of counts sitting under a field every consumer reads as 14.
  if (out == "") exit
  printf "{\n" > out
  first = 1
  for (f in rd) {
    if (!first) printf ",\n" > out
    first = 0
    plist = ""
    if (rd[f] != "unknown" && projs[f] != "") {
      k = split(projs[f], pa, ",")
      for (i = 1; i <= k; i++) plist = plist (i > 1 ? ", " : "") "\"" pa[i] "\""
    }
    printf "  \"%s\": {\"ruled_date\": \"%s\", \"recurrences_14d\": %s, \"projects\": [%s]}",
           f, rd[f], (rd[f] == "unknown" ? "null" : n[f] ""), plist > out
  }
  printf "\n}\n" > out
  close(out)
}
' "$RULED" "$FINDINGS" || exit 0

if [ -n "$JSONOUT" ]; then
  mkdir -p "$H/state" 2>/dev/null
  [ -s "$JSONOUT" ] && mv -f "$JSONOUT" "$OUT" 2>/dev/null
  rm -f "$JSONOUT" 2>/dev/null
fi
exit 0
