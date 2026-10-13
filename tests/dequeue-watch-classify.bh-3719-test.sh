#!/bin/bash
# tests/dequeue-watch-classify.bh-3719-test.sh — the two pure dequeue-watch libs
# (BH-3728, slice 2 of BH-3719): attribution of a dequeued PR (C1-C6) and the
# classify/brief half (K1-K10), each with one mutation (MA, MK) and a purity scan.
#
# The libs are sourced from the checkout and fed the fixtures in
# tests/fixtures/dequeue-watch/, whose payloads are the bh-3480 Mergify comment
# with the draft and run edited and whose run titles are the real merge-queue
# shape (`merge queue: checking #A + #B together on main (<sha7>)`).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FX="$DIR/tests/fixtures/dequeue-watch"
ATTR="$DIR/bin/lib/dequeue-watch/attribute.sh"
CLS="$DIR/bin/lib/dequeue-watch/classify.sh"
RULES="$DIR/catalog/rules-pack.tsv"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

# shellcheck source=/dev/null
. "$ATTR" || { bad "attribute.sh does not source"; }
# shellcheck source=/dev/null
. "$CLS" || { bad "classify.sh does not source"; }
# shellcheck source=/dev/null
. "$DIR/bin/lib/fixround-preflight.sh" || { bad "fixround-preflight.sh does not source"; }

# A files dir per case: pr-files-<n>.json copied in from the fixtures.
files_dir() { # files_dir <name> <n>=<fixture>...
  local d="$T/files-$1" a; shift; mkdir -p "$d"
  for a in "$@"; do cp "$FX/${a#*=}" "$d/pr-files-${a%%=*}.json"; done
  printf '%s\n' "$d"
}
P1=$(dqw_parse_payload_md "$(cat "$FX/payload-dequeued-batch1.md")")
P3=$(dqw_parse_payload_md "$(cat "$FX/payload-dequeued-batch3.md")")
NOFILES=$(files_dir none)
ALLF=$(files_dir all 101=pr-files-101.json 102=pr-files-102.json 103=pr-files-103.json)
SRC="$FX/sources-lib-root.txt"

# ---- C1: batch of one ---------------------------------------------------------
eq "C1 payload batch1 parses" "$(cut -f1,2 <<<"$P1")" $'201\t5001'
eq "C1 batch of one → culprit" "$(dqw_attribute 101 "$P1" "$FX/runs-batch1.json" "$SRC" "$NOFILES")" $'culprit\tbatch-of-one'

# ---- C2: bisect ---------------------------------------------------------------
eq "C2 batch-3 members" "$(dqw_batch_members "$FX/runs-batch3.json" 5003 | paste -sd' ' -)" "101 102 103"
eq "C2a later #101 alone red → culprit" "$(dqw_attribute 101 "$P3" "$FX/runs-batch3-bisect-red.json" "$SRC" "$NOFILES")" $'culprit\tbisect'
eq "C2b later #101+#102 green → bystander" "$(dqw_attribute 101 "$P3" "$FX/runs-batch3-bisect-green.json" "$SRC" "$NOFILES")" $'bystander\tbisect'
# The stacked #102+#103 run in the red fixture is green; it is never evidence for 102.
if dqw_bisect_word "$FX/runs-batch3-bisect-red.json" 102 5003 "101 102 103" >/dev/null; then
  bad "C2c a stacked run was read as bisect evidence"
else ok "C2c a stacked run is never bisect evidence"; fi

# ---- C3: diff-touch -----------------------------------------------------------
eq "C3a 101 touches a failing source → culprit" "$(dqw_attribute 101 "$P3" "$FX/runs-batch3.json" "$SRC" "$ALLF")" $'culprit\tdiff-touch'
C3B=$(files_dir c3b 101=pr-files-101-none.json 102=pr-files-102.json 103=pr-files-103.json)
eq "C3b 101 touches none, 102 does → bystander" "$(dqw_attribute 101 "$P3" "$FX/runs-batch3.json" "$SRC" "$C3B")" $'bystander\tdiff-touch'

# ---- C4: a failed read is unknown, never bystander ----------------------------
C4A=$(dqw_attribute 101 "$P3" "$T/no-such-runs.json" "$SRC" "$(files_dir c4a 101=pr-files-101-none.json 102=pr-files-102.json)")
eq "C4a runs file missing → unknown" "$C4A" $'unknown\tundecided'
C4B=$(dqw_attribute 101 "$P3" "$FX/runs-batch3.json" "$SRC" "$(files_dir c4b 102=pr-files-102.json 103=pr-files-103.json)")
eq "C4b PR files absent → unknown" "$C4B" $'unknown\tundecided'
C4C=$(dqw_attribute 101 $'203\t9999\t-\t-' "$FX/runs-batch3.json" "$SRC" "$NOFILES")
eq "C4c run not in the runs file → unknown" "$C4C" $'unknown\tundecided'
case "$C4A$C4B$C4C" in *bystander*) bad "C4 a failed read printed bystander" ;; *) ok "C4 no failed read printed bystander" ;; esac
eq "C4d no run id → unknown/no-run" "$(dqw_attribute 101 $'-\t-\t-\t-' "$FX/runs-batch3.json" "$SRC" "$ALLF")" $'unknown\tno-run'

# ---- C5: batch of one wins over later green evidence --------------------------
eq "C5 batch of one + later green → culprit" "$(dqw_attribute 101 "$P1" "$FX/runs-batch1-rerun-green.json" "$SRC" "$C3B")" $'culprit\tbatch-of-one'

# ---- C6: the real payload shape -----------------------------------------------
REAL=$(jq -r '.[1].body' "$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json")
eq "C6 bh-3480 payload parses" "$(dqw_parse_payload_md "$REAL")" $'3397\t36511019338\tb49a1b832b0d294ee7a46325ac2ace79dc50d235\tPure-logic gate fixtures'
eq "C6 no Left-the-queue line → sha is -" "$(dqw_parse_payload_md "$(grep -v 'Left the queue' <<<"$REAL")" | cut -f3)" "-"
if dqw_parse_payload_md "$(cat "$FX/payload-waiting.md")" >/dev/null; then bad "C6 waiting payload parsed"
else ok "C6 waiting payload → rc 1"; fi

# ---- K: classify ---------------------------------------------------------------
parse() { dqw_parse_log "$FX/$1" >"$T/$1.tsv"; }
parse log-rule-break.txt; parse log-gitleaks.txt; parse log-semantic.txt; parse log-long.txt
cls() { dqw_classify rules="$RULES" "$@"; }

eq "K1 rule_id of the ratchet suite" "$(dqw_rule_id tests/lib-root-literal-ratchet.bh-2613-test.sh "$RULES")" lib-root
eq "K1 rule-break log → rule-break lib-root" "$(cls attribution=culprit parsed="$T/log-rule-break.txt.tsv")" $'rule-break\trule\tlib-root'
has "K1 hint names the rule id" "$(dqw_hint rule-break lib-root)" lib-root
if (HARNESS='' H='' dqw_rule_id tests/lib-root-literal-ratchet.bh-2613-test.sh >/dev/null); then bad "K1 empty root read a rules pack"
else ok "K1 empty root → rc 1 (D43)"; fi

K2=$(cls attribution=culprit parsed="$T/log-gitleaks.txt.tsv")
eq "K2 gitleaks → scanner-fp" "$(cut -f1 <<<"$K2")" scanner-fp
eq "K2 scanner-fp hint is the ticket's text" "$(dqw_hint scanner-fp -)" "Reword the flagged identifier or placeholder so the scanner no longer matches. Never add an allowlist entry."
GL=$(head -1 "$T/log-gitleaks.txt.tsv" | cut -f2)
has "K2 gitleaks FAIL line parsed" "$GL" "generic-api-key"
B2=$(dqw_brief scanner-fp - tests/share-publish-clean.bh-795-test.sh "$T/log-gitleaks.txt.tsv" -)
has "K2 brief carries the hint" "$B2" "Never add an allowlist entry."
has "K2 brief carries the FAIL line" "$B2" "- $GL"
has "K2 brief header" "$B2" "## Mergify dequeued this PR (dequeue-watch, BH-3719)"
has "K2 brief run of - " "$B2" "Batch run: -"

eq "K3 unpacked suite → semantic-test" "$(cls attribution=culprit parsed="$T/log-semantic.txt.tsv" | cut -f1)" semantic-test
has "K3 hint mentions TEST-CHANGE:" "$(dqw_hint semantic-test -)" "TEST-CHANGE:"
eq "K4 main red wins" "$(cls main_red=1 attribution=bystander parsed="$T/log-rule-break.txt.tsv" | cut -f1)" main-red
eq "K5 dirty → textual-conflict" "$(cls mergeable=dirty parsed="$T/log-rule-break.txt.tsv" | cut -f1)" textual-conflict
eq "K6 stale=1 → stale-status" "$(cls stale=1 parsed="$T/log-rule-break.txt.tsv" | cut -f1)" stale-status
eq "K6 checks=lead-verdict → stale-status" "$(cls checks=lead-verdict | cut -f1)" stale-status
eq "K7 rerun green → flake" "$(cls rerun_green=1 parsed="$T/log-rule-break.txt.tsv" | cut -f1)" flake
eq "K8a bystander → bystander" "$(cls attribution=bystander parsed="$T/log-rule-break.txt.tsv" | cut -f1)" bystander
eq "K8b unknown → rule-break, never bystander" "$(cls attribution=unknown parsed="$T/log-rule-break.txt.tsv" | cut -f1)" rule-break
eq "K8c no attribution key → rule-break" "$(cls parsed="$T/log-rule-break.txt.tsv" | cut -f1)" rule-break
for h in bystander flake main-red stale-status; do
  if dqw_hint "$h" - >/dev/null; then bad "K hint for $h should be rc 1"; else ok "K no hint for $h"; fi
done

if dqw_parse_log "$FX/log-empty.txt" >"$T/empty.tsv"; then bad "K9 empty log parsed rc 0"; else ok "K9 empty log → rc 1"; fi
eq "K9 empty log printed nothing" "$(cat "$T/empty.tsv")" ""
eq "K9 → unclassified" "$(cls attribution=culprit parsed="$T/empty.tsv")" $'unclassified\tnone\t-'

L="$T/log-long.txt.tsv"
eq "K10 40 rows + truncated" "$(wc -l <"$L" | tr -d ' ')" 41
eq "K10 last row is (truncated)" "$(tail -1 "$L")" $'-\t(truncated)'
eq "K10 no row over 300 chars" "$(awk -F'\t' 'length($2) > 300' "$L" | wc -l | tr -d ' ')" 0
eq "K10 no timestamp prefix" "$(grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$L")" 0
has "K10 token masked" "$(cat "$L")" "ghp_[masked]"
eq "K10 the unmasked token is gone" "$(grep -c 'not-a-real-token' "$L")" 0
eq "K10 rc=0 block's FAIL absent" "$(grep -c 'in-an-rc0-block' "$L")" 0
eq "K10 rows name the red suite" "$(head -1 "$L" | cut -f1)" tests/big-red-test.sh
eq "K10 non-numeric cap → 40" "$(DEQUEUE_WATCH_FAIL_LINES=abc dqw_parse_log "$FX/log-long.txt" | wc -l | tr -d ' ')" 41
B10=$(dqw_brief semantic-test - tests/big-red-test.sh "$L" "https://github.com/example-org/cromford/actions/runs/5003")
has "K10 brief says truncated" "$B10" "FAIL lines (truncated):"
eq "K10 brief carries no findings head" "$(frp_findings_head "$B10")" ""
eq "K10 brief carries no findings head (with a sha in the run url)" "$(frp_findings_head "$(dqw_brief semantic-test - x "$L" "of b49a1b832b0d294ee7a46325ac2ace79dc50d235")")" ""

# ---- MA: attribution's batch-of-one arm, broken, turns C1 red -----------------
sed 's/printf .culprit\\tbatch-of-one\\n./printf '"'"'bystander\\tbatch-of-one\\n'"'"'/' "$ATTR" >"$T/attr-ma.sh"
if [ ! -s "$ATTR" ] || cmp -s "$ATTR" "$T/attr-ma.sh"; then bad "MA the lib is absent or the mutation changed nothing"
else
  MA=$(unset _DQW_ATTRIBUTE_SH; . "$T/attr-ma.sh"; dqw_attribute 101 "$P1" "$FX/runs-batch1.json" "$SRC" "$NOFILES")
  if [ "$MA" = $'culprit\tbatch-of-one' ]; then bad "MA C1 stayed green under the mutation"; else ok "MA C1 goes red under the mutation ($MA)"; fi
fi

# ---- MK: classify without the scanner rule turns K2 red -----------------------
sed '/DQW_RULE_SCANNER/d' "$CLS" >"$T/cls-mk.sh"
if [ ! -s "$CLS" ] || cmp -s "$CLS" "$T/cls-mk.sh"; then bad "MK the lib is absent or the mutation changed nothing"
else
  MK=$(unset _DQW_CLASSIFY_SH; . "$T/cls-mk.sh"; dqw_classify rules="$RULES" attribution=culprit parsed="$T/log-gitleaks.txt.tsv" | cut -f1)
  if [ "$MK" = scanner-fp ]; then bad "MK K2 stayed scanner-fp without rule 6"; else eq "MK K2 falls to semantic-test without rule 6" "$MK" semantic-test; fi
fi

# ---- purity --------------------------------------------------------------------
IMPURE=$(grep -nE '(^|[^a-z_])gh |/root/harness|\bdate\b|graphql' "$ATTR" "$CLS")
eq "purity: no gh, root literal, clock or graphql in either lib" "$IMPURE" ""

echo "dequeue-watch-classify.bh-3719: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
