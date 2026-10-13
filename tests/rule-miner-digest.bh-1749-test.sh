#!/bin/bash
# tests/rule-miner-digest.bh-1749-test.sh — BH-1749.1 (#1763): the rule-miner
# digest's real body, driven through the CLI (bin/rule-miner-digest.sh).
#
# A deterministic generator (arithmetic only, no $RANDOM) writes ~45,000
# findings.log rows into scratch and, alongside them, the truth it wrote: per
# family the exact count, the earliest and latest date, and the prose of the
# first and latest occurrence (fx/truth.tsv), plus rows per (family, rule)
# (fx/rules.tsv). The assertions read that truth, never the digest's own awk.
#   K1     a malformed knob is rc 2, names the knob, writes nothing
#   F1-F4  families: exact counts/dates/samples, TOP cap + tie order, the
#          `family=-` and prose `family=zzz` rows, the 30-day window, PROMOTE_MIN
#   R1     the rules section over the top-N families
#   I1     other incidents: id + summary + 400-byte excerpt, inventory order
#   B1-B5  budget, INCOMPLETE line, ids-out, byte-identical reruns
#   E1     empty inventory and no rows in the window
# DIGEST_UNDER_TEST points the suite at another copy of the CLI (the red run
# against the contract stub uses it).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LC_ALL=C
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
D="${DIGEST_UNDER_TEST:-$DIR/bin/rule-miner-digest.sh}"
unset RULE_MINER_TOP_FAMILIES RULE_MINER_DIGEST_MAX_TOKENS PROMOTE_MIN

F="$T/fx"; mkdir -p "$F/b"
ago() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }
DATES=""; for n in $(seq 0 40); do DATES="$DATES $(ago "$n")"; done

# ---- the generator
# Family k (1..300) gets floor(7000/k) rows over days 1..29 ago, except k=5 and
# k=6, which are the tie pair "tie-b" and "tie-a" at 1300 rows each (ranks 5/6;
# tie-b is written first, so file order would pick the wrong one). Then 300
# fam001..fam004 rows whose PROSE says family=zzz, 500 family=- rows, 200 rows
# of fam001 dated 40 days ago, and "lowfam" with 2 rows citing D99.
awk -v dates="$DATES" -v truth="$F/truth.tsv" -v rtruth="$F/rules.tsv" '
  function name(k) { return k == 5 ? "tie-b" : k == 6 ? "tie-a" : sprintf("fam%03d", k) }
  function row(fam, dago, j, k, rule, extra,   d, t, key, prose, p) {
    d = D[dago]
    t = sprintf("%02d:%02d:%02dZ", (j*13+k)%24, (j*7+k)%60, (j*31+k)%60)
    p = "p" ((j+k)%4)
    prose = sprintf("fam %s row %d says the build %s", fam, j, extra) FILL
    print d " " t " [" p "] ticket=BH-" j " lens=general verdict=BLOCK rule=" rule " family=" fam " :: " prose
    if (dago > 30) return
    key = d " " t
    cnt[fam]++
    if (!(fam in fk) || key < fk[fam]) { fk[fam] = key; fp[fam] = prose; fd[fam] = d }
    if (!(fam in lk) || key >= lk[fam]) { lk[fam] = key; lp[fam] = prose }
    if (!(fam in mind) || d < mind[fam]) mind[fam] = d
    if (!(fam in maxd) || d > maxd[fam]) maxd[fam] = d
    if (rule != "-") rc[fam "\t" rule]++
  }
  BEGIN {
    n = split(dates, a, " "); for (i = 1; i <= n; i++) D[i-1] = a[i]
    FILL = "and the reviewer keeps writing the same paragraph about it because nobody turned the lesson into a guardrail yet, which is why this sentence runs well past two hundred bytes on purpose: zz-tail-marker"
    for (k = 1; k <= 300; k++) {
      c = (k == 5 || k == 6) ? 1300 : int(7000 / k)
      for (j = 0; j < c; j++)
        row(name(k), 1 + (j*7+k) % 29, j, k, (j % 3 == 0) ? "-" : "D" (1 + (k+j) % 14), "")
    }
    for (i = 0; i < 300; i++) row(name(1 + i%4), 1 + i%29, 9000+i, 1 + i%4, "D14", "family=zzz rule=D77")
    for (i = 0; i < 500; i++) print D[1 + i%29] " 10:00:00Z [p1] ticket=BH-9 lens=general verdict=BLOCK rule=D3 family=- :: unkeyed finding " i
    for (i = 0; i < 200; i++) print D[40] " 11:00:00Z [p2] ticket=BH-8 lens=general verdict=BLOCK rule=D14 family=fam001 :: old row " i
    row("lowfam", 3, 1, 1, "D99", ""); row("lowfam", 4, 2, 1, "D99", "")
    for (f in cnt) printf "%s\t%d\t%s\t%s\t%s\t%s\n", f, cnt[f], mind[f], maxd[f], fp[f], lp[f] > truth
    for (x in rc) printf "%s\t%d\n", x, rc[x] > rtruth
  }' > "$F/findings.log"
# the spec ranking (count desc, family asc), over the families that qualify at 3
awk -F'\t' '$2 >= 3' "$F/truth.tsv" | sort -t$'\t' -k2,2nr -k1,1 > "$F/ranked.tsv"
QN=$(wc -l < "$F/ranked.tsv")

# Inventory: bundle bodies are >400 bytes with a marker past byte 400.
bundle() { { printf 'INCIDENT: %s\nSUMMARY: s\n\n' "$1"; printf 'line\twith a tab %s\n' $(seq 1 40); echo BEYOND-400-MARKER; } > "$F/b/$1.md"; }
: > "$F/inventory.tsv"
nn=0
inv() { nn=$((nn+1)); printf '%02d\t%s\t%s\t%s\n' "$nn" "$1" "$2" "$3" >> "$F/inventory.tsv"; }
for id in revert-a reopen-b; do bundle "$id"; done
inv "revert:fleet/app@abc123" "$F/b/revert-a.md" "revert of abc123 in app"
inv "reopen:BH-12" "$F/b/reopen-b.md" "BH-12 reopened after merge"
for k in $(seq 1 60); do
  fam=$(awk -v k="$k" 'BEGIN { print k == 5 ? "tie-b" : k == 6 ? "tie-a" : sprintf("fam%03d", k) }')
  inv "findings:$fam" "$F/b/revert-a.md" "review-finding family $fam recurred"
done
for id in block-c refuted-d manual-e; do bundle "$id"; done
inv "block:BH-13" "$F/b/block-c.md" "BH-13 blocked twice"
inv "refuted:BH-14" "$F/b/refuted-d.md" "BH-14 claim refuted"
inv "findings:lowfam" "$F/b/manual-e.md" "sub-threshold family row"
inv "manual:note-1" "$F/b/manual-e.md" "hand-filed note, with commas"
NINC=6

run() { # run <tag> [VAR=val ...] -> $F/<tag>.md $F/<tag>.ids, rc in $rc
  local tag="$1"; shift
  env "$@" "$D" "$F/findings.log" "$F/inventory.tsv" "$F/$tag.md" "$F/$tag.ids" 2>"$F/$tag.err"; rc=$?
}
block() { awk -v h="### $2" '$0 == h { on = 1; next } on && /^##/ { exit } on' "$1"; }
field() { block "$1" "$2" | sed -n "s/^- $3: //p"; }
heads() { sed -n 's/^### //p' "$1"; }

# ---- K1: malformed knobs are refused, never clamped
for kv in RULE_MINER_TOP_FAMILIES=abc RULE_MINER_DIGEST_MAX_TOKENS=0 PROMOTE_MIN=-3 RULE_MINER_TOP_FAMILIES=; do
  run k1 "$kv"
  [ "$rc" -eq 2 ] && grep -qF "${kv%%=*}" "$F/k1.err" && [ ! -e "$F/k1.md" ] && [ ! -e "$F/k1.ids" ] \
    && ok || bad "K1 $kv: rc=$rc err='$(cat "$F/k1.err")' out exists=$([ -e "$F/k1.md" ] && echo y || echo n)"
done

# ---- default run
run def
[ "$rc" -eq 0 ] && ok || bad "default run rc=$rc err='$(cat "$F/def.err")'"

# ---- F1: the top 5 by generator count, exact
for fam in $(head -n5 "$F/ranked.tsv" | cut -f1); do
  IFS=$'\t' read -r _ cnt mn mx fp lp < <(awk -F'\t' -v f="$fam" '$1 == f' "$F/truth.tsv")
  [ "$(field "$F/def.md" "$fam" count)" = "$cnt" ] && ok || bad "F1 $fam count '$(field "$F/def.md" "$fam" count)' want $cnt"
  [ "$(field "$F/def.md" "$fam" 'first seen')" = "$mn" ] && ok || bad "F1 $fam first seen '$(field "$F/def.md" "$fam" 'first seen')' want $mn"
  [ "$(field "$F/def.md" "$fam" 'last seen')" = "$mx" ] && ok || bad "F1 $fam last seen '$(field "$F/def.md" "$fam" 'last seen')' want $mx"
  s=$(field "$F/def.md" "$fam" sample)
  [ "$(grep -c . <<<"$s")" = 2 ] && ok || bad "F1 $fam want 2 samples, got '$s'"
  [ "$(sed -n 1p <<<"$s")" = "${fp:0:200}" ] && ok || bad "F1 $fam sample 1 is not the first occurrence cut to 200 bytes"
  [ "$(sed -n 2p <<<"$s")" = "${lp:0:200}" ] && ok || bad "F1 $fam sample 2 is not the latest occurrence cut to 200 bytes"
  grep -q zz-tail-marker <<<"$s" && bad "F1 $fam sample not cut at 200 bytes" || ok
done

# ---- F2: TOP=5 -> exactly 5 families, count order, tie broken family-asc
run top5 RULE_MINER_TOP_FAMILIES=5
[ "$(heads "$F/top5.md")" = "$(head -n5 "$F/ranked.tsv" | cut -f1)" ] && ok || bad "F2 TOP=5 headings: $(heads "$F/top5.md" | tr '\n' ' ')"
[ "$(heads "$F/top5.md" | sed -n 5p)" = tie-a ] && ok || bad "F2 rank 5 is not tie-a"
grep -qx tie-b <<<"$(heads "$F/top5.md")" && bad "F2 tie-b (rank 6) was written under TOP=5" || ok

# ---- F3: the decoy and the dash are never families; decoy rows count under their real family
grep -qxE 'zzz|-|' <<<"$(heads "$F/def.md")" && bad "F3 zzz, - or an empty family has a heading" || ok
grep -q '^- D77:' "$F/def.md" && bad "F3 a rule= quoted in prose was cited" || ok

# ---- F4: the 30-day window and PROMOTE_MIN
want=$(awk -F'\t' '$1 == "fam001" { print $2 }' "$F/truth.tsv")
[ "$(field "$F/def.md" fam001 count)" = "$want" ] && ok || bad "F4 fam001 count '$(field "$F/def.md" fam001 count)' want $want: the 200 rows 40 days old must not count"
grep -qx lowfam <<<"$(heads "$F/def.md")" && bad "F4 lowfam (2 rows < PROMOTE_MIN 3) has a heading" || ok
run pm PROMOTE_MIN=1300
[ "$(heads "$F/pm.md" | tr '\n' ' ')" = "fam001 fam002 fam003 fam004 tie-a tie-b " ] && ok || bad "F4 PROMOTE_MIN=1300 headings: $(heads "$F/pm.md" | tr '\n' ' ')"
grep -q '^INCOMPLETE:' "$F/pm.md" && bad "F4 INCOMPLETE on a run that capped nothing" || ok

# ---- R1: D14 over the top-40 families
head -n40 "$F/ranked.tsv" | cut -f1 > "$F/top40"
want=$(awk -F'\t' 'NR == FNR { top[$1] = NR; next } $2 == "D14" && ($1 in top) { n += $3; o[top[$1]] = $1 }
  END { for (i = 1; i <= 40; i++) if (i in o) s = s (s == "" ? "" : ",") o[i]; printf "- D14: %d rows; families: %s\n", n, s }' "$F/top40" "$F/rules.tsv")
[ "$(grep '^- D14:' "$F/def.md")" = "$want" ] && ok || bad "R1 got '$(grep '^- D14:' "$F/def.md")' want '$want'"
grep -q '^- D99:' "$F/def.md" && bad "R1 D99 (cited only by a sub-threshold family) is listed" || ok

# ---- I1: other incidents, inventory order, 400-byte excerpt
sect=$(awk '/^## Other incidents/ { on = 1; next } on' "$F/def.md")
want=$(awk -F'\t' '$2 !~ /^findings:/ || $2 == "findings:lowfam" { print $2 }' "$F/inventory.tsv")
[ "$(sed -n 's/^- \(.*\) — .*/\1/p' <<<"$sect")" = "$want" ] && ok || bad "I1 incident ids/order: $(sed -n 's/^- \(.*\) — .*/\1/p' <<<"$sect" | tr '\n' ' ')"
while IFS=$'\t' read -r _ id path sum; do
  case "$id" in findings:lowfam) ;; findings:*) continue ;; esac
  [ "$(grep -cxF -- "- $id — $sum" <<<"$sect")" = 1 ] && ok || bad "I1 no single '- $id — $sum' line"
  ex="  excerpt: $(head -c 400 "$path" | tr '\n\t\r' '   ')"
  [ "$(grep -A1 -xF -- "- $id — $sum" <<<"$sect" | sed -n 2p)" = "$ex" ] && ok || bad "I1 $id excerpt is not the flattened first 400 bytes"
done < "$F/inventory.tsv"
grep -q BEYOND-400-MARKER "$F/def.md" && bad "I1 bundle bytes past 400 reached out.md" || ok

# ---- B1: the budget
[ $(( $(wc -c < "$F/def.md") / 4 )) -le 40000 ] && ok || bad "B1 default digest is $(wc -c < "$F/def.md") bytes"
run small RULE_MINER_DIGEST_MAX_TOKENS=5000
[ "$rc" -eq 0 ] && [ $(( $(wc -c < "$F/small.md") / 4 )) -le 5000 ] && ok || bad "B1 5000-token digest rc=$rc, $(wc -c < "$F/small.md") bytes"
sn=$(heads "$F/small.md" | grep -c .)
[ "$sn" -gt 0 ] && [ "$sn" -lt 40 ] && ok || bad "B1 5000-token run wrote $sn families; the fixture must make the byte budget bite"

# ---- B2: INCOMPLETE carries the exact omitted counts
[ "$(grep '^INCOMPLETE:' "$F/def.md")" = "INCOMPLETE: $((QN-40)) families and 0 incidents omitted by the digest budget; bundles on disk at $F" ] \
  && ok || bad "B2 default: '$(grep '^INCOMPLETE:' "$F/def.md")' want $((QN-40)) families and 0 incidents"
si=$(awk '/^## Other incidents/ { on = 1; next } on && /^- /' "$F/small.md" | grep -c .)
[ "$(grep '^INCOMPLETE:' "$F/small.md")" = "INCOMPLETE: $((QN-sn)) families and $((NINC-si)) incidents omitted by the digest budget; bundles on disk at $F" ] \
  && ok || bad "B2 5000: '$(grep '^INCOMPLETE:' "$F/small.md")' want $((QN-sn)) families and $((NINC-si)) incidents"
[ "$(grep -c '^INCOMPLETE:' "$F/def.md")" = 1 ] && [ "$(sed -n 3p "$F/def.md" | cut -c1-11)" = "INCOMPLETE:" ] && ok || bad "B2 INCOMPLETE is not one header line"

# ---- B3: nothing capped -> no INCOMPLETE line
S="$T/sm"; mkdir -p "$S"
for fam in a b c; do for i in 1 2 3; do echo "$(ago 2) 0$i:00:00Z [p] ticket=X lens=general verdict=BLOCK rule=D1 family=sm-$fam :: s $i"; done; done > "$S/f.log"
printf '01\tblock:X\t%s\tone\n02\tmanual:Y\t%s\ttwo\n' "$F/b/block-c.md" "$F/b/manual-e.md" > "$S/inv.tsv"
"$D" "$S/f.log" "$S/inv.tsv" "$S/o.md" "$S/ids"; rc=$?
[ "$rc" -eq 0 ] && [ "$(heads "$S/o.md" | grep -c .)" = 3 ] && ok || bad "B3 small fixture rc=$rc families=$(heads "$S/o.md" | grep -c .)"
grep -q '^INCOMPLETE' "$S/o.md" && bad "B3 INCOMPLETE on an uncapped run" || ok
[ "$(cat "$S/ids")" = "$(printf 'block:X\nmanual:Y')" ] && ok || bad "B3 ids-out '$(cat "$S/ids")'"

# ---- B4: ids-out is exactly what was written, in inventory order
idsof() { # idsof <out.md>: inventory ids whose content is in out.md, inventory order
  awk -F'\t' 'NR == FNR { if (sub(/^### /, "")) w["findings:" $0] = 1; else if (sub(/^- /, "") && index($0, " — ")) w[substr($0, 1, index($0, " — ") - 1)] = 1; next }
    ($2 in w) { print $2 }' "$1" "$F/inventory.tsv"
}
[ "$(cat "$F/def.ids")" = "$(idsof "$F/def.md")" ] && ok || bad "B4 default ids-out differs from the written set"
[ "$(grep -c '^findings:' "$F/def.ids")" = 41 ] && [ "$(grep -vc '^findings:' "$F/def.ids")" = 5 ] && ok || bad "B4 default ids-out: want 40 families + findings:lowfam + 5 others"
[ "$(cat "$F/small.ids")" = "$(idsof "$F/small.md")" ] && ok || bad "B4 5000 ids-out differs from the written set"
grep -qx "findings:$(sed -n "$((sn+1))p" "$F/ranked.tsv" | cut -f1)" "$F/small.ids" && bad "B4 an omitted family's id is in ids-out" || ok

# ---- B5: byte-identical reruns
run def2
cmp -s "$F/def.md" "$F/def2.md" && cmp -s "$F/def.ids" "$F/def2.ids" && ok || bad "B5 two runs differ"

# ---- E1: nothing in the window, empty inventory -> rc 0, empty ids-out file, no INCOMPLETE
E="$T/e"; mkdir -p "$E"
echo "$(ago 40) 00:00:00Z [p] ticket=X lens=general verdict=BLOCK rule=D1 family=old :: gone" > "$E/f.log"; : > "$E/inv.tsv"
"$D" "$E/f.log" "$E/inv.tsv" "$E/o.md" "$E/ids"; rc=$?
[ "$rc" -eq 0 ] && [ -e "$E/ids" ] && [ ! -s "$E/ids" ] && ! grep -q '^INCOMPLETE' "$E/o.md" && [ -z "$(heads "$E/o.md")" ] \
  && ok || bad "E1 empty case rc=$rc"

echo "rule-miner-digest: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
