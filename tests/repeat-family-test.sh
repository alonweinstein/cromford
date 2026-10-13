#!/bin/bash
# tests/repeat-family-test.sh — bin/repeat-family.sh, the rule loop's closing
# metric: does a finding family come BACK after the miner has ruled on it.
#
# The failure this pins is the one the metric exists to catch in itself. Every
# other number in this repo counts work done — findings harvested, families
# mined, checks promoted — and all of them keep climbing whether or not the
# rules stop anything. Recurrence-after-ruling is the only one that can say
# "the loop is not closing", so the assertions that matter are the ones about
# what must NOT be counted: an occurrence from BEFORE the ruling (the family's
# whole reason for being mined), an occurrence outside the window, and a family
# nobody ever ruled on. Any of those leaking in turns a closed loop into a
# fake-open one, or an open loop into a fake-closed one.
#
# The other half is honesty about the data: logs/findings.log was bootstrapped
# in one harvest, so ~11.6K rows carry the harvest date rather than the date
# their review was written. A family ruled ON that date can only ever show
# recurrences from after it, and the readout has to say so rather than
# presenting a structural zero as a clean record.
#
# Run from anywhere: tests/repeat-family-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/repeat-family.sh"
ROLLUP="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

iso() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }
D1=$(iso 1);  D2=$(iso 2);   D3=$(iso 3);   D5=$(iso 5)
D7=$(iso 7);  D10=$(iso 10); D12=$(iso 12); D20=$(iso 20); D30=$(iso 30)

mkdir -p "$T/logs" "$T/state/rule-mining"

# ---------- fixture: three mining runs, six families -------------------------
# A mining run's DIRNAME is the ruling date — seen.txt carries no dates at all,
# so the bundle dir is the only record of when a family was ruled on.
mine() { # mine <YYYY-MM-DD> <family>...
  local d="${1//-/}" n=0 f; shift
  mkdir -p "$T/state/rule-mining/$d"
  for f in "$@"; do
    n=$((n+1))
    printf '%02d\tfindings:%s\t%s\tfamily %s recurred\n' \
      "$n" "$f" "$T/state/rule-mining/$d/$n.md" "$f" \
      >> "$T/state/rule-mining/$d/inventory.tsv"
  done
}
mine "$D30" bbbb2222
mine "$D10" aaaa1111 cccc3333
mine "$D7"  eeee5555
# A family in seen.txt whose bundle dir has been cleaned: ruled, but the date
# is gone with the directory. Unknowable is not zero.
echo "findings:ffff6666" > "$T/state/rule-mining/seen.txt"
echo "revert:Acme/x:abc123" >> "$T/state/rule-mining/seen.txt"

row() { # row <YYYY-MM-DD> <project> <family>
  printf '%s 09:00:00Z [%s] ticket=K-1 lens=general verdict=BLOCK rule=- family=%s :: a finding headline long enough to be real\n' \
    "$1" "$2" "$3" >> "$T/logs/findings.log"
}
row "$D12" alpha-os aaaa1111   # BEFORE the ruling — the evidence it was mined from
row "$D5"  alpha-os aaaa1111   # after  -> counts
row "$D3"  beta-os  aaaa1111   # after  -> counts
row "$D20" alpha-os bbbb2222   # after the D30 ruling, but outside the 14d window
row "$D2"  alpha-os bbbb2222   # inside -> counts
row "$D1"  alpha-os dddd4444   # never ruled on -> must not appear at all
row "$D1"  alpha-os dddd4444
row "$D1"  beta-os  dddd4444
row "$D3"  alpha-os eeee5555   # bootstrap-dated ruling, one later recurrence
row "$D1"  alpha-os ffff6666   # ruled, ruling date unknown -> not countable
row "$D1"  alpha-os -          # unkeyed row: never a family

run() { HARNESS="$T" REPEAT_BOOTSTRAP_DATE="$D7" bash "$SCRIPT" "$@" 2>&1; }

OUT=$(run); RC=$?
[ "$RC" = 0 ] && ok || bad "readout must exit 0 — it is a readout, never a gate (rc=$RC)"
J="$T/state/repeat-family.json"
jq -e . "$J" >/dev/null 2>&1 && ok || bad "state/repeat-family.json must be valid JSON: $(cat "$J" 2>/dev/null)"

# ---------- 1. recurrence is counted only AFTER the ruling -------------------
[ "$(jq -r '.aaaa1111.recurrences_14d' "$J")" = 2 ] && ok \
  || bad "aaaa1111: 2 post-ruling occurrences (got $(jq -r '.aaaa1111.recurrences_14d' "$J"))"
[ "$(jq -r '.aaaa1111.ruled_date' "$J")" = "$D10" ] && ok \
  || bad "ruled_date comes from the bundle dirname (got $(jq -r '.aaaa1111.ruled_date' "$J"))"
[ "$(jq -r '.aaaa1111.projects | length' "$J")" = 2 ] && ok \
  || bad "both projects must be recorded (got $(jq -c '.aaaa1111.projects' "$J"))"

# 2. THE PRE-RULING OCCURRENCE. A family is mined BECAUSE it occurred; counting
# that evidence as recurrence would score every ruling as an instant failure
# and the metric would read "nothing ever works".
grep -q "$D12" <<<"$(jq -c . "$J")" && bad "a pre-ruling date leaked into the output" || ok

# 3. the window boundary is real
[ "$(jq -r '.bbbb2222.recurrences_14d' "$J")" = 1 ] && ok \
  || bad "bbbb2222: the $D20 occurrence is outside 14d (got $(jq -r '.bbbb2222.recurrences_14d' "$J"))"
WOUT=$(HARNESS="$T" REPEAT_BOOTSTRAP_DATE="$D7" REPEAT_WINDOW_DAYS=25 bash "$SCRIPT" 2>&1)
grep -qE '^bbbb2222 +[0-9-]+ +2 ' <<<"$WOUT" && ok \
  || bad "a 25d window must pick the $D20 occurrence up: $(grep bbbb2222 <<<"$WOUT")"
grep -q 'window 25d' <<<"$WOUT" && ok || bad "the summary must state the window it used"
# ...and must NOT overwrite the published file, whose field is named 14d. A
# 25-day count sitting under recurrences_14d is a number relabelled as another.
[ "$(jq -r '.bbbb2222.recurrences_14d' "$J")" = 1 ] && ok \
  || bad "an exploratory window must not overwrite the 14d file (got $(jq -r '.bbbb2222.recurrences_14d' "$J"))"

# 4. a family the miner never ruled on is not in the table
jq -e 'has("dddd4444")' "$J" >/dev/null 2>&1 \
  && bad "dddd4444 was never ruled on — recurrence is undefined for it" || ok
grep -q 'dddd4444' <<<"$OUT" && bad "an unruled family must not reach the table" || ok
jq -e 'has("-")' "$J" >/dev/null 2>&1 && bad "the unkeyed family '-' must never be counted" || ok

# 5. a ruled family with no recurrences is a real zero, and says so
[ "$(jq -r '.cccc3333.recurrences_14d' "$J")" = 0 ] && ok \
  || bad "cccc3333 must read 0, not vanish (got $(jq -r '.cccc3333.recurrences_14d' "$J"))"

# 6. ruled, but the ruling date is gone: unknowable, NOT zero
[ "$(jq -r '.ffff6666.ruled_date' "$J")" = "unknown" ] && ok \
  || bad "a seen.txt family with no bundle has an unknown ruling date (got $(jq -r '.ffff6666.ruled_date' "$J"))"
[ "$(jq -r '.ffff6666.recurrences_14d' "$J")" = "null" ] && ok \
  || bad "an unknown ruling date cannot yield a count (got $(jq -r '.ffff6666.recurrences_14d' "$J"))"

# ---------- 7. the summary line ---------------------------------------------
head -1 <<<"$OUT" | grep -q '^repeat-family: 4 recurrences across 5 ruled families (window 14d)' && ok \
  || bad "summary line wrong: $(head -1 <<<"$OUT")"
head -1 <<<"$OUT" | grep -q 'top: aaaa1111 x2' && ok \
  || bad "the summary must name the worst family and its count: $(head -1 <<<"$OUT")"

# ---------- 8. the bootstrap caveat -----------------------------------------
# eeee5555 was ruled on the date every bootstrapped findings row carries, so
# its window can only ever contain post-bootstrap rows. Presenting that as a
# clean record is the dishonest reading this line exists to block.
grep -qi 'caveat' <<<"$OUT" && ok || bad "a bootstrap-dated ruling must print a caveat line"
grep -q "$D7" <<<"$OUT" && ok || bad "the caveat must name the bootstrap date"
grep -qi 'date-compressed\|bootstrap' <<<"$OUT" && ok || bad "the caveat must explain WHY the ruling date is suspect"

# ...and no caveat when no ruling lands on the bootstrap date.
NOBOOT=$(HARNESS="$T" REPEAT_BOOTSTRAP_DATE=1999-01-01 bash "$SCRIPT" 2>&1)
grep -qi 'caveat' <<<"$NOBOOT" && bad "no bootstrap-dated ruling means no caveat line" || ok
run >/dev/null

# ---------- 9. --line is ONE line, for the beat ------------------------------
LINE=$(run --line)
[ "$(wc -l <<<"$LINE" | tr -d ' ')" = 1 ] && ok || bad "--line must emit exactly one line (got $(wc -l <<<"$LINE"))"
grep -q '^repeat-family: 4 recurrences across 5 ruled families' <<<"$LINE" && ok \
  || bad "--line must carry the same summary: $LINE"
# The caveat cannot be dropped just because the beat is one line — a beat that
# reports a structural zero as a clean record is the whole failure mode.
grep -qi 'bootstrap' <<<"$LINE" && ok || bad "--line must keep the bootstrap caveat inline: $LINE"

# ---------- 10. three outcomes ----------------------------------------------
# (a) no ruled families yet — the live hub state on the day this shipped.
E="$T/empty"; mkdir -p "$E/logs" "$E/state/rule-mining"
cp "$T/logs/findings.log" "$E/logs/findings.log"
EOUT=$(HARNESS="$E" bash "$SCRIPT" 2>&1); ERC=$?
[ "$ERC" = 0 ] && ok || bad "no ruled families must still exit 0 (rc=$ERC)"
grep -qi 'no famil\(y\|ies\).*ruled\|ruled.*none' <<<"$EOUT" && ok \
  || bad "with nothing ruled the readout must say so: $EOUT"
grep -q '^repeat-family: 0 recurrences across 0 ruled families' <<<"$EOUT" \
  && bad "0-of-0 must not be dressed up as a measured zero" || ok

# (b) findings.log missing — absent, not zero, and it must not write a JSON
# that a consumer would read as "measured, nothing found".
M="$T/missing"; mkdir -p "$M/logs" "$M/state/rule-mining"
cp -r "$T/state/rule-mining/." "$M/state/rule-mining/"
MOUT=$(HARNESS="$M" bash "$SCRIPT" 2>&1); MRC=$?
[ "$MRC" = 0 ] && ok || bad "a missing findings.log must exit 0, not fail a caller (rc=$MRC)"
grep -qi 'absent\|not measured\|nothing measured' <<<"$MOUT" && ok \
  || bad "a missing findings.log must produce an honest absent line: $MOUT"
grep -q '0 recurrences' <<<"$MOUT" && bad "absent must never be reported as 0 recurrences" || ok
[ -f "$M/state/repeat-family.json" ] && bad "nothing measured must write no JSON" || ok

# (c) an unreadable rule-mining tree changes nothing else
N="$T/nomine"; mkdir -p "$N/logs" "$N/state"
cp "$T/logs/findings.log" "$N/logs/findings.log"
NRC=$(HARNESS="$N" bash "$SCRIPT" >/dev/null 2>&1; echo $?)
[ "$NRC" = 0 ] && ok || bad "a missing state/rule-mining must not fail (rc=$NRC)"

# ---------- 11. the cost-rollup seam ----------------------------------------
# The JSON rides summary.json as an ADDITIVE top-level key. Extracted verbatim
# so the loader cannot drift from the shipped one, and driven with a present
# file and an absent one: an absent readout must leave `{}` behind rather than
# raising inside the rollup, which would take summary.json — and every box's
# dashboard figure — down with it.
awk '/^# >>> repeat family json/{f=1;next} /^# <<< repeat family json/{exit} f' \
  "$ROLLUP" > "$T/loader.py"
[ -s "$T/loader.py" ] && ok || bad "could not extract the repeat-family loader from cost-rollup.sh — markers missing?"
# `json` is imported at the top of the rollup's python block, so the probe
# imports it before exec — without it the loader's own except would swallow a
# NameError and every probe would report a healthy-looking {}.
probe() { python3 -c "
import json
H='$1'
exec(open('$T/loader.py').read())
print(json.dumps(repeat_families))"; }
[ "$(probe "$T" | jq -r '.aaaa1111.recurrences_14d')" = 2 ] && ok \
  || bad "the rollup loader must read state/repeat-family.json (got $(probe "$T"))"
[ "$(probe "$T/nowhere")" = '{}' ] && ok \
  || bad "an absent readout must load as {} and never raise (got $(probe "$T/nowhere"))"

# The beat must actually be wired, and from the SAME sentence the script emits
# — a second copy of the wording in python is how the two would drift apart.
grep -q 'repeat-family.sh" --line' "$ROLLUP" && ok \
  || bad "cost-rollup.sh must take the beat line from repeat-family.sh --line"
grep -q 'repeat_families' "$ROLLUP" && ok \
  || bad "cost-rollup.sh must publish repeat_families on summary.json"

# ---------- 12. the optional fraud= field must not move the numbers ----------
# findings-log.sh gained an optional `fraud=<class>` field (2026-08-26), written
# between rule= and family= on findings the reviewer tagged as one of the six
# fraud classes. This walk stops at `::` and keys on prefixes, so an unknown
# field is meant to be invisible to it — "meant to" is what this row converts
# into a fact. A silent regression here would not error: it would drop tagged
# rows out of the count, and the metric would read BETTER than the truth.
X="$T/fraudfield"; mkdir -p "$X/logs" "$X/state/rule-mining"
cp -r "$T/state/rule-mining/." "$X/state/rule-mining/"
frow() { # frow <YYYY-MM-DD> <project> <family> <fraud-class>
  printf '%s 09:00:00Z [%s] ticket=K-1 lens=general verdict=BLOCK rule=D1 fraud=%s family=%s :: a finding headline long enough to be real\n' \
    "$1" "$2" "$4" "$3" >> "$X/logs/findings.log"
}
frow "$D5" alpha-os aaaa1111 weakened-tests
frow "$D3" beta-os  aaaa1111 false-completion
XOUT=$(HARNESS="$X" REPEAT_BOOTSTRAP_DATE="$D7" bash "$SCRIPT" 2>&1)
XJ="$X/state/repeat-family.json"
[ "$(jq -r '.aaaa1111.recurrences_14d' "$XJ" 2>/dev/null)" = 2 ] && ok \
  || bad "fraud-tagged rows must still count for their family (got $(jq -r '.aaaa1111.recurrences_14d' "$XJ" 2>/dev/null))"
[ "$(jq -r '.aaaa1111.projects | length' "$XJ" 2>/dev/null)" = 2 ] && ok \
  || bad "the project field must still parse past fraud= (got $(jq -c '.aaaa1111.projects' "$XJ" 2>/dev/null))"
jq -e 'has("weakened-tests")' "$XJ" >/dev/null 2>&1 \
  && bad "a fraud class was read as a family key" || ok
grep -q 'weakened-tests' <<<"$XOUT" && bad "a fraud class leaked into the readout" || ok

echo "repeat-family-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
