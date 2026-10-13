#!/bin/bash
# tests/rule-recur.bh-3716-test.sh — the 30-day recurrence measure of adopted
# rules (BH-3692.3). Runs the REAL "$DIR/bin/rule-recur.sh" against a scratch
# findings.log, an evidence dir written with re_write, a fake `gh` answering the
# commits read, and a recorder in place of lane-alert.sh. Every date is relative
# to `date -u` now, so the suite never rots.
#
#   a  a family row 10 days after adoption: exactly one rule-recur-D44 warn
#   b  a row before adoption, or 31+ days after: no warn; the closed D45 says held
#   c  a rule=D12,D44 cite with no family match warns with cite=1; rule=D4 adds nothing
#   d  commits read 500 / [] / 100 entries: no warn, each its own skip line
#   e  empty families and no cites: "citation only", never "held"
#   f  `-` families drop at write; a family=- row never matches
#   g  RULE_MINER_DRY=1 prints the would-flag line and records nothing
#   h  a rule adopted 40 days ago is past the age gate: no warn
#   i  lane-alert rc 1: "warn NOT delivered", never "flagged"
#   j  family= text after ` :: ` is finding text, not a field: no warn
#   k  a row exactly at the adoption instant is outside (A, E]: no warn
#   l  an empty or missing evidence dir is silent, rc 0; an unreadable
#      findings.log says so and never measures
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "rule-recur.bh-3716-test: SKIPPED — jq missing"; exit 0; }
. "$DIR/bin/lib/rule-evidence.sh" || exit 1
RECUR="$DIR/bin/rule-recur.sh"

NOW=$(date -u +%s)
ts()  { date -u -d "@$(( NOW - $1 * 86400 + ${2:-0} ))" '+%Y-%m-%d %H:%M:%SZ'; } # ts <days ago> [+secs]
iso() { date -u -d "@$(( NOW - $1 * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

mkdir -p "$T/bin" "$T/h"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
# fake gh: api -i -X GET repos/<slug>/commits?path=prompts/rule-evidence/D<n>.json&...
p=""; for a in "$@"; do case "$a" in repos/*) p=$a ;; esac; done
n=$(printf '%s' "$p" | sed -n 's/.*rule-evidence\/\(D[0-9]*\)\.json.*/\1/p')
echo "$p" >> "$FAKE_DIR/gh-calls"
st=200; [ -r "$FAKE_DIR/commits-$n.status" ] && st=$(cat "$FAKE_DIR/commits-$n.status")
printf 'HTTP/2 %s\r\n\r\n' "$st"
case "$st" in 2*) cat "$FAKE_DIR/commits-$n" ;; *) echo '{"message":"x"}'; exit 1 ;; esac
EOF
cat > "$T/alert" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/alerts"
exit "${ALERT_RC:-0}"
EOF
chmod +x "$T/bin/gh" "$T/alert"

reset() { scratch_rm "$T/ev"; mkdir -p "$T/ev"; rm -f "$T"/commits-* "$T/alerts" "$T/gh-calls"; : > "$T/findings.log"; }
# rule <n> <class> <adopted days ago> [family ...] — evidence file + its commits answer
rule() {
  local n=$1 class=$2 ago=$3; shift 3
  printf '%s\n' "$@" > "$T/fam"; printf 'TK-1\n' > "$T/inc"
  re_write "$T/ev/$n.json" "$n" "$class" - r 2026-09-01 findings "$T/inc" "$T/fam" || bad "fixture re_write $n"
  # newest first, as the API answers; the oldest (last) is the adoption
  printf '[{"sha":"b","commit":{"committer":{"date":"%s"}}},{"sha":"a","commit":{"committer":{"date":"%s"}}}]\n' \
    "$(iso 1)" "$(iso "$ago")" > "$T/commits-$n"
}
row() { # row <ts> <rule> <family> [finding]
  printf '%s [project-3] ticket=TK-9 lens=general verdict=BLOCK rule=%s family=%s :: %s\n' "$1" "$2" "$3" "${4:-a finding}" >> "$T/findings.log"
}
run() { # stdout+stderr of the real script
  env "$@" PATH="$T/bin:$PATH" FAKE_DIR="$T" HARNESS="$T/h" HARNESS_REPO=example-org/cromford \
    RULE_RECUR_ALERT_BIN="$T/alert" bash "$RECUR" "$T/findings.log" "$T/ev" 2>&1
}
calls() { [ -s "$T/alerts" ] && wc -l < "$T/alerts" | tr -d ' ' || echo 0; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: output lacks '$3': $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: output has '$3': $2" ;; *) ok ;; esac; }
ncalls() { local c; c=$(calls); [ "$c" = "$2" ] && ok || bad "$1: expected $2 alert call(s), got $c: $(cat "$T/alerts" 2>/dev/null)"; }
pass() { echo "PASS: $1"; }
f0=$FAIL

# ── a ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa
row "$(ts 10)" - fam44aaaaaaa
out=$(run); rc=$?
[ "$rc" = 0 ] && ok || bad "a rc $rc"
ncalls a 1
a=$(cat "$T/alerts" 2>/dev/null)
has a "$a" "--severity warn"; has a "$a" "--id rule-recur-D44"; has a "$a" " rule-miner D44 (lint-backed, adopted $(ts 20 | cut -c1-10))"
has a "$a" "[fam44aaaaaaa]"; has a "$a" "recurred 1 time(s)"; has a "$a" "0 finding(s) cite D44"
has a "$a" "Last: $(ts 10) [project-3] TK-9"
has a "$out" "D44 flagged"
grep -q 'commits?path=prompts/rule-evidence/D44.json&sha=main&per_page=100' "$T/gh-calls" && ok || bad "a commits read path: $(cat "$T/gh-calls")"
[ "$FAIL" = "$f0" ] && pass a; f0=$FAIL

# ── b ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa; rule D45 judgement 35 fam45bbbbbbb
row "$(ts 21)" - fam44aaaaaaa
row "$(ts 35 $((30*86400 + 3600)))" - fam45bbbbbbb   # 30d+1h after D45's adoption
out=$(run)
ncalls b 0
has b "$out" "D45 held: no recurrence by family [fam45bbbbbbb] and no citation in 30 days"
has b "$out" "D44 clean so far (20/30 days)"
hasnt b "$out" "flagged"
[ "$FAIL" = "$f0" ] && pass b; f0=$FAIL

# ── c ───────────────────────────────────────────────────────────────────────
reset; rule D44 judgement 20 fam44aaaaaaa
row "$(ts 5)" D12,D44 otherfamily
row "$(ts 4)" D4 otherfamily
row "$(ts 3)" D44x,D440 otherfamily
out=$(run)
ncalls c 1
a=$(cat "$T/alerts" 2>/dev/null)
has c "$a" "recurred 0 time(s)"; has c "$a" "and 1 finding(s) cite D44"; has c "$a" "Last: $(ts 5)"
[ "$FAIL" = "$f0" ] && pass c; f0=$FAIL

# ── d ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa; row "$(ts 10)" D44 fam44aaaaaaa
echo 500 > "$T/commits-D44.status"
out=$(run); rc=$?
ncalls "d/500" 0; has "d/500" "$out" "D44 adoption date unreadable"; [ "$rc" = 0 ] && ok || bad "d/500 rc $rc"
hasnt "d/500" "$out" "clean so far"
rm -f "$T/commits-D44.status"; echo '[]' > "$T/commits-D44"
out=$(run)
ncalls "d/[]" 0; has "d/[]" "$out" "D44 not on main yet, not measured"
jq -n --arg d "$(iso 20)" '[range(100) | {commit: {committer: {date: $d}}}]' > "$T/commits-D44"
out=$(run)
ncalls "d/100" 0; has "d/100" "$out" "D44 adoption date unreadable (100+ commits, oldest not on page 1)"
echo '{"not":"a list"}' > "$T/commits-D44"
out=$(run)
ncalls "d/obj" 0; has "d/obj" "$out" "D44 adoption date unreadable"
echo '[{"commit":{"committer":{"date":"yesterday-ish?"}}}]' > "$T/commits-D44"
out=$(run)
ncalls "d/date" 0; has "d/date" "$out" "D44 adoption date unreadable"
[ "$FAIL" = "$f0" ] && pass d; f0=$FAIL

# ── e ───────────────────────────────────────────────────────────────────────
reset; rule D46 judgement 35
row "$(ts 10)" D12 somefamily
out=$(run)
ncalls e 0
has e "$out" "D46 measured by citation only (no family key)"
hasnt e "$out" "held"
reset; rule D46 judgement 10; out=$(run)
has e2 "$out" "D46 measured by citation only (no family key)"; hasnt e2 "$out" "held"; hasnt e2 "$out" "clean"
[ "$FAIL" = "$f0" ] && pass e; f0=$FAIL

# ── f ───────────────────────────────────────────────────────────────────────
reset; rule D47 judgement 20 -
[ "$(re_field "$T/ev/D47.json" '.families|length')" = 0 ] && ok || bad "f '-' family was kept"
rule D44 lint-backed 20 fam44aaaaaaa
row "$(ts 10)" - -
row "$(ts 9)" D12 ''
out=$(run)
ncalls f 0
has f "$out" "D47 measured by citation only"
[ "$FAIL" = "$f0" ] && pass f; f0=$FAIL

# ── g ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa; row "$(ts 10)" - fam44aaaaaaa
out=$(run RULE_MINER_DRY=1); rc=$?
[ "$rc" = 0 ] && ok || bad "g rc $rc"
has g "$out" "rule-recur: would flag rule-recur-D44: D44 (lint-backed"
[ ! -s "$T/alerts" ] && ok || bad "g DRY recorded an alert: $(cat "$T/alerts")"
hasnt g "$out" "D44 flagged"
[ "$FAIL" = "$f0" ] && pass g; f0=$FAIL

# ── h ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 40 fam44aaaaaaa; row "$(ts 30)" D44 fam44aaaaaaa
out=$(run)
ncalls h 0; hasnt h "$out" "D44"
[ "$FAIL" = "$f0" ] && pass h; f0=$FAIL

# ── i ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa; row "$(ts 10)" - fam44aaaaaaa
out=$(run ALERT_RC=1)
ncalls i 1
has i "$out" "D44 warn NOT delivered (lane-alert rc=1)"
hasnt i "$out" "D44 flagged"
[ "$FAIL" = "$f0" ] && pass i; f0=$FAIL

# ── j ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa
row "$(ts 10)" - - "the reviewer wrote family=fam44aaaaaaa rule=D44 in prose"
out=$(run)
ncalls j 0; has j "$out" "D44 clean so far"
[ "$FAIL" = "$f0" ] && pass j; f0=$FAIL

# ── k ───────────────────────────────────────────────────────────────────────
reset; rule D44 lint-backed 20 fam44aaaaaaa
row "$(ts 20)" D44 fam44aaaaaaa
out=$(run)
ncalls k 0; has k "$out" "D44 clean so far"
row "$(ts 20 1)" - fam44aaaaaaa
out=$(run)
ncalls k2 1
[ "$FAIL" = "$f0" ] && pass k; f0=$FAIL

# ── l ───────────────────────────────────────────────────────────────────────
reset
out=$(run); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok || bad "l empty dir: rc=$rc out=$out"
out=$(PATH="$T/bin:$PATH" bash "$RECUR" "$T/findings.log" "$T/no-such-dir" 2>&1); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok || bad "l missing dir: rc=$rc out=$out"
[ ! -e "$T/gh-calls" ] && ok || bad "l read GitHub with no evidence"
rule D44 lint-backed 20 fam44aaaaaaa
out=$(env PATH="$T/bin:$PATH" FAKE_DIR="$T" HARNESS="$T/h" RULE_RECUR_ALERT_BIN="$T/alert" bash "$RECUR" "$T/no-such.log" "$T/ev" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "l unreadable findings rc $rc"
has l "$out" "rule-recur: findings.log unreadable ($T/no-such.log), nothing measured"
hasnt l "$out" "clean"; hasnt l "$out" "held"; ncalls l 0
[ "$FAIL" = "$f0" ] && pass l; f0=$FAIL

! grep -q '/root/harness' "$RECUR" && ok || bad "rule-recur.sh carries a /root/harness literal"

echo "rule-recur.bh-3716-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
