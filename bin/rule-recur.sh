#!/bin/bash
# rule-recur.sh <findings.log> <evidence-dir>
# The 30-day recurrence measure of adopted rules (BH-3692). bin/rule-miner.sh
# calls it once per run, before its empty-week exit; its stdout is the miner's
# log (the terminal under RULE_MINER_DRY=1). Always exits 0 on a handled path.
#
# For each <evidence-dir>/D<n>.json with a class:
#   adopted  the OLDEST main commit of prompts/rule-evidence/D<n>.json (its
#            committer date). A failed read, a non-list answer, an unparseable
#            date or a full first page (100: the oldest may be on page 2) is
#            "adoption date unreadable" and the rule is skipped, never dated
#            today. `[]` is "not on main yet", skipped the same way.
#   gate     adopted more than RECUR_GATE_DAYS ago: skipped silently. The days
#            over RECUR_WINDOW_DAYS give the weekly run one pass after close.
#   count    findings.log rows stamped in (adopted, adopted+30d]: k = rows whose
#            family= is one of the rule's families, m = rows whose rule= list
#            holds exactly D<n>. Fields are read before the first ` :: ` only,
#            and family=- or an empty family never matches.
#   report   k+m > 0: one lane-alert warn, id rule-recur-D<n> (the id keeps a
#            repeat week from re-sending); "flagged" only after lane-alert rc 0.
#            RULE_MINER_DRY=1 prints the would-flag line and sends nothing.
#            No family keys and no cites: "measured by citation only", never
#            "held". Open and clean: "clean so far". Closed, clean, with family
#            keys: "held".
#
# RULE_RECUR_ALERT_BIN overrides the alert recorder (tests). No model call.
set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
FINDINGS=${1:-}; EVDIR=${2:-}
RECUR_WINDOW_DAYS=30
RECUR_GATE_DAYS=37

say() { echo "rule-recur: $*"; }

# A quiet week before any adoption: no evidence, nothing to say.
[ -n "$EVDIR" ] && [ -d "$EVDIR" ] || exit 0
compgen -G "$EVDIR/D*.json" >/dev/null || exit 0
if [ ! -r "$FINDINGS" ] || [ -d "$FINDINGS" ]; then
  say "findings.log unreadable ($FINDINGS), nothing measured"; exit 0
fi

. "$SELF/lib/rule-evidence.sh" || exit 1
. "$SELF/lib/gh-rest.sh" || exit 1
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1  # BH-4080: HARNESS_REPO
ALERT="${RULE_RECUR_ALERT_BIN:-$SELF/lane-alert.sh}"
NOW=$(date -u +%s)
TMP=$(mktemp "${TMPDIR:-/tmp}/rule-recur.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }

for f in "$EVDIR"/D*.json; do
  n=$(basename "$f" .json)
  [[ $n =~ ^D[0-9]+$ ]] || continue
  if ! class=$(re_field "$f" .class 2>/dev/null) || ! fams=$(re_field "$f" '.families[]' 2>/dev/null); then
    say "$n evidence unreadable"; continue
  fi
  [ -n "$class" ] && [ "$class" != null ] || continue
  fams=$(printf '%s\n' "$fams" | grep -v -e '^-$' -e '^[[:space:]]*$' | paste -sd, -)

  rc=0
  GH_ETAG=0 gh_rest GET "repos/$HARNESS_REPO/commits?path=$RE_DIR/$n.json&sha=main&per_page=100" > "$TMP" || rc=$?
  len=""; [ "$rc" = 0 ] && len=$(jq -er 'if type == "array" then length else error end' "$TMP" 2>/dev/null)
  if [ -z "$len" ]; then say "$n adoption date unreadable"; continue; fi
  if [ "$len" = 0 ]; then say "$n not on main yet, not measured"; continue; fi
  if [ "$len" -ge 100 ]; then say "$n adoption date unreadable (100+ commits, oldest not on page 1)"; continue; fi
  raw=$(jq -er '.[-1].commit.committer.date | strings' "$TMP" 2>/dev/null) || raw=""
  A=""; [ -n "$raw" ] && A=$(date -u -d "$raw" +%s 2>/dev/null)
  if [ -z "$A" ]; then say "$n adoption date unreadable"; continue; fi

  age=$(( NOW - A ))
  [ "$age" -gt $(( RECUR_GATE_DAYS * 86400 )) ] && continue
  E=$(( A + RECUR_WINDOW_DAYS * 86400 ))

  # k m last-ts last-project last-ticket
  read -r k m lts lproj ltick < <(awk -v a="$(stamp "$A")" -v e="$(stamp "$E")" -v fams="$fams" -v rule="$n" '
    BEGIN { nf = split(fams, fl, ","); for (i = 1; i <= nf; i++) fs[fl[i]] = 1; k = m = 0; last = "- - - -" }
    {
      head = $0; i = index(head, " :: "); if (i) head = substr(head, 1, i - 1)
      nw = split(head, w, " "); if (nw < 3) next
      t = w[1] " " w[2]; if (!(t > a && t <= e)) next
      fam = ""; rl = ""; tk = "-"
      for (j = 3; j <= nw; j++) {
        if (w[j] ~ /^family=/) fam = substr(w[j], 8)
        else if (w[j] ~ /^rule=/) rl = substr(w[j], 6)
        else if (w[j] ~ /^ticket=/) tk = substr(w[j], 8)
      }
      hit = 0
      if (fam != "" && fam != "-" && (fam in fs)) { k++; hit = 1 }
      nr = split(rl, rr, ","); for (j = 1; j <= nr; j++) if (rr[j] == rule) { m++; hit = 1; break }
      if (hit) last = t " " w[3] " " tk
    }
    END { print k, m, last }' "$FINDINGS")

  if [ $(( k + m )) -gt 0 ]; then
    msg="$n ($class, adopted $(stamp "$A" | cut -c1-10)) did not hold: its incident class recurred $k time(s) by family [$fams] and $m finding(s) cite $n, within $RECUR_WINDOW_DAYS days. Last: $lts $lproj $ltick"
    if [ "${RULE_MINER_DRY:-0}" = 1 ]; then
      say "would flag rule-recur-$n: $msg"
    else
      arc=0
      "$ALERT" --severity warn --id "rule-recur-$n" rule-miner "$msg" >&2 || arc=$?
      if [ "$arc" = 0 ]; then say "$n flagged"; else say "$n warn NOT delivered (lane-alert rc=$arc)"; fi
    fi
  elif [ -z "$fams" ]; then
    say "$n measured by citation only (no family key)"
  elif [ "$NOW" -le "$E" ]; then
    say "$n clean so far ($(( age / 86400 ))/$RECUR_WINDOW_DAYS days)"
  else
    say "$n held: no recurrence by family [$fams] and no citation in $RECUR_WINDOW_DAYS days"
  fi
done
exit 0
