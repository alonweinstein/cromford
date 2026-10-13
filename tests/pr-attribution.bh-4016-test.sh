#!/bin/bash
# tests/pr-attribution.bh-4016-test.sh — bin/pr-attribution.sh, the read-only
# operator CLI that classifies a repo's merged PRs as harness / train /
# operator / human (BH-4016, child of BH-3987).
#
# HOW IT DRIVES. Every case runs the REAL bin/pr-attribution.sh as a process,
# under `env -i`, with a stub `gh` first on PATH. The stub records its argv and
# answers the REST pulls list from tests/fixtures/pr-attribution/merged-prs.bh-3987.json
# (or a 403 rate-limit / 404 when $T/fx.status says so, or ten generated pages
# for the truncation case). Assertions read stdout, stderr, rc and the stub's
# argv log, never the script's source text.
#
# THE CLOCK IS PINNED. PR_ATTRIBUTION_NOW is an epoch literal and every fixture
# date is a literal, so nothing here moves with the calendar.
#
# MUTATIONS (D1), at the bottom, each against a COPY of the script under $T:
#   M1 trailers never read (always the heuristic) -> A1 red
#   M2 a closed-unmerged PR counted by created_at -> A8 red
#   M3 the since filter dropped                   -> A3 red
#   M4 exit 0 on a failed REST read                -> A6 red
#   M5 the FIRST Harness-Job: line wins            -> A1 job value red
#
# Run from anywhere:  bash tests/pr-attribution.bh-4016-test.sh   (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/pr-attribution.sh"
FIX="$DIR/tests/fixtures/pr-attribution/merged-prs.bh-3987.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# 2026-10-03T00:00:00Z
NOW_PIN=1790985600
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/logs" "$T/bin" "$T/tmp" "$T/big" "$T/mut/bin"
: > "$T/h/env/global.env"
cat > "$T/h/bin/fleet-conf.sh" <<'FC'
#!/bin/bash
# stub: proj -> o/r, anything else -> no row
if [ "${1:-}" = proj ] && [ "${2:-}" = repo ]; then echo o/r; exit 0; fi
exit 1
FC
chmod +x "$T/h/bin/fleet-conf.sh"

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
st=200; [ -r "$D/fx.status" ] && st=$(cat "$D/fx.status")
case "$st" in
  403) printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded for installation"}'; exit 1 ;;
  404) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 1 ;;
  big)
    p=$(printf '%s\n' "$*" | sed -n 's/.*page=\([0-9][0-9]*\).*/\1/p')
    printf 'HTTP/2 200\r\n\r\n'; cat "$D/big/$p.json"; exit 0 ;;
esac
printf 'HTTP/2 200\r\n\r\n'; cat "$GH_STUB_FIXTURE"
STUB
chmod +x "$T/bin/gh"

reset() { rm -f "$T/fx.status" "$T/out" "$T/err"; : > "$T/gh-calls.txt"; }
# run <cli> [args...] -> $RC, $T/out, $T/err. NOW defaults to the pin; set
# NOWV= to override it for one call.
run() {
  local cli="$1"; shift
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T/tmp" HARNESS="$T/h" \
    ETC_HARNESS_ENV="$T/no-etc" HARNESS_TEST_SANDBOX=1 PR_ATTRIBUTION_NOW="${NOWV-$NOW_PIN}" \
    GH_ETAG=0 GH_STUB_DIR="$T" GH_STUB_FIXTURE="$FIX" \
    bash "$cli" "$@" > "$T/out" 2> "$T/err" || RC=$?
}
row() { awk -F'\t' -v n="$1" '$1 == n' "$T/out"; }
field() { row "$1" | cut -f"$2"; }       # field <num> <col>
cls()   { row "$1" | cut -f3-6 | tr '\t' ' '; }   # class basis job ticket
lines() { wc -l < "$1" | tr -d ' '; }

# ══ A1 trailer rows + the one REST read ══════════════════════════════════════
reset; run "$CLI" o/r 2026-09-01
[ "$RC" = 0 ] && ok || bad "A1: rc must be 0, got $RC ($(cat "$T/err"))"
[ "$(head -1 "$T/out")" = "$(printf 'number\tmerged_at\tclass\tbasis\tjob\tticket\tauthor\thead\turl')" ] \
  && ok || bad "A1: header wrong: $(head -1 "$T/out")"
[ "$(cls 101)" = "harness trailer 9001 BH-77" ] && ok || bad "A1: #101 want 'harness trailer 9001 BH-77', got '$(cls 101)'"
[ "$(cls 102)" = "train trailer train:batch/t1 none" ] && ok || bad "A1: #102 want train/trailer, got '$(cls 102)'"
[ "$(field 101 7)" = "cromford[bot]" ] && ok || bad "A1: #101 author must be the REST login, got '$(field 101 7)'"
[ "$(field 101 9)" = "https://github.com/o/r/pull/101" ] && ok || bad "A1: #101 url, got '$(field 101 9)'"
[ "$(lines "$T/gh-calls.txt")" = 1 ] && ok || bad "A1: exactly one gh call, got $(lines "$T/gh-calls.txt")"
C=$(cat "$T/gh-calls.txt")
case "$C" in "api -i -X GET repos/o/r/pulls "*"state=closed"*"page=1"*) ok ;; *) bad "A1: gh argv wrong: $C" ;; esac

# ══ A2 heuristic rows ════════════════════════════════════════════════════════
[ "$(cls 103)" = "harness? heuristic - -" ] && ok || bad "A2: #103 got '$(cls 103)'"
[ "$(cls 104)" = "harness? heuristic - -" ] && ok || bad "A2: #104 (cromford[bot], fix/x) got '$(cls 104)'"
[ "$(cls 105)" = "train? heuristic - -" ] && ok || bad "A2: #105 got '$(cls 105)'"
[ "$(cls 106)" = "operator? heuristic - -" ] && ok || bad "A2: #106 got '$(cls 106)'"

# ══ A3 human row, the since filter ═══════════════════════════════════════════
[ "$(cls 107)" = "human heuristic - -" ] && ok || bad "A3: #107 got '$(cls 107)'"
[ -z "$(row 108)" ] && ok || bad "A3: #108 merged before since must be absent"

# ══ A4 totals + row count + order ════════════════════════════════════════════
[ "$(tail -1 "$T/out")" = "# totals harness=1 harness?=2 train=1 train?=1 operator?=1 human=1" ] \
  && ok || bad "A4: totals wrong: $(tail -1 "$T/out")"
N=$(sed '1d;$d' "$T/out" | grep -c .)
[ "$N" = 7 ] && ok || bad "A4: want 7 rows, got $N"
ORDER=$(sed '1d;$d' "$T/out" | cut -f1 | paste -sd, -)
[ "$ORDER" = "101,102,103,104,105,106,107" ] && ok || bad "A4: rows must be merged_at desc, got $ORDER"
[ ! -s "$T/err" ] && ok || bad "A4: a clean run writes no stderr: $(cat "$T/err")"
cp "$T/out" "$T/tsv"

# ══ A8 closed-unmerged is excluded (TSV half) ════════════════════════════════
[ -z "$(row 109)" ] && ok || bad "A8: #109 (merged_at null) must be absent from TSV"

# ══ A5 --json is the same rows ═══════════════════════════════════════════════
reset; run "$CLI" o/r 2026-09-01 --json
[ "$RC" = 0 ] && ok || bad "A5: --json rc must be 0, got $RC"
cp "$T/out" "$T/json"
[ "$(jq 'type == "array" and length == 7' "$T/json" 2>/dev/null)" = true ] && ok || bad "A5: want a JSON array of 7, got $(head -c 200 "$T/json")"
JT=$(jq -c '[.[] | [.number, .class, .basis, .job, .ticket]]' "$T/json" 2>/dev/null)
TT=$(sed '1d;$d' "$T/tsv" | cut -f1,3-6 | jq -Rc 'split("\t") | [(.[0]|tonumber), .[1], .[2], (if .[3] == "-" then null else .[3] end), (if .[4] == "-" then null else .[4] end)]' | jq -sc .)
[ -n "$JT" ] && [ "$JT" = "$TT" ] && ok || bad "A5: JSON tuples differ from TSV: $JT vs $TT"
[ "$(jq -c '.[0] | keys' "$T/json" 2>/dev/null)" = '["author","basis","class","head","job","merged_at","number","ticket","url"]' ] \
  && ok || bad "A5: JSON keys wrong: $(jq -c '.[0] | keys' "$T/json" 2>/dev/null)"
[ "$(jq '[.[] | select(.number == 109)] | length' "$T/json" 2>/dev/null)" = 0 ] && ok || bad "A8: #109 must be absent from JSON"
reset; run "$CLI" --json o/r 2026-09-01
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/json" && ok || bad "A5: --json before <repo> must give the same output (rc $RC)"

# ══ A6 REST failure: rc 75, empty stdout, one stderr line ════════════════════
for s in 403 404; do
  reset; echo "$s" > "$T/fx.status"; run "$CLI" o/r 2026-09-01
  [ "$RC" = 75 ] && ok || bad "A6($s): rc must be 75, got $RC"
  [ ! -s "$T/out" ] && ok || bad "A6($s): stdout must be empty, got $(head -c 200 "$T/out")"
  [ "$(lines "$T/err")" = 1 ] && ok || bad "A6($s): stderr must be exactly 1 line, got: $(cat "$T/err")"
  grep -q "HTTP $s" "$T/err" && ok || bad "A6($s): stderr must name the HTTP status: $(cat "$T/err")"
done

# ══ A7 bad arguments: rc 2, empty stdout, no gh call ═════════════════════════
for s in 2026-02-31 2026-9-1 yesterday 2026-13-01; do
  reset; run "$CLI" o/r "$s"
  [ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok || bad "A7: since '$s' must be rc 2 with empty stdout, got rc $RC"
  [ ! -s "$T/gh-calls.txt" ] && ok || bad "A7: since '$s' must not call gh"
done
reset; run "$CLI";                        [ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok || bad "A7: no args must be rc 2, got $RC"
reset; run "$CLI" o/r 2026-09-01 extra;   [ "$RC" = 2 ] && ok || bad "A7: three positionals must be rc 2, got $RC"
reset; run "$CLI" --bogus o/r;            [ "$RC" = 2 ] && ok || bad "A7: --bogus must be rc 2, got $RC"
[ "$(lines "$T/err")" = 1 ] && ok || bad "A7: a usage error is one stderr line, got: $(cat "$T/err")"
reset; run "$CLI" --help
[ "$RC" = 0 ] && grep -q '^usage:' "$T/out" && ok || bad "A7: --help must be rc 0 with usage on stdout, got $RC"

# ══ A9 fleet project resolution ══════════════════════════════════════════════
reset; run "$CLI" proj 2026-09-01
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/tsv" && ok || bad "A9: 'proj' must resolve to o/r and give the same rows (rc $RC)"
reset; run "$CLI" nope 2026-09-01
[ "$RC" = 2 ] && [ ! -s "$T/out" ] && ok || bad "A9: unknown project must be rc 2, got $RC"
[ ! -s "$T/gh-calls.txt" ] && ok || bad "A9: unknown project must not call gh"

# ══ A10 default since = 30 days before NOW; junk NOW is never the clock ══════
reset; run "$CLI" o/r
[ "$RC" = 0 ] && ok || bad "A10: default since rc must be 0, got $RC"
[ -n "$(row 107)" ] && ok || bad "A10: #107 (2026-09-05) is inside the default window (since 2026-09-03)"
[ -z "$(row 108)" ] && ok || bad "A10: #108 (2026-08-31) is outside the default window"
reset; NOWV=abc run "$CLI" o/r 2026-09-01
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/tsv" && ok || bad "A10: PR_ATTRIBUTION_NOW=abc must be ignored, not taken as the clock (rc $RC)"

# ══ A12 truncation at the 1000-row cap ═══════════════════════════════════════
for p in 1 2 3 4 5 6 7 8 9 10; do
  jq -nc --argjson p "$p" '[range(100) | (($p - 1) * 100 + .) as $i
    | {number: (5000 - $i), created_at: "2026-09-20T00:00:00Z", merged_at: "2026-09-21T00:00:00Z",
       user: {login: "octo-dev"}, head: {ref: ("feature/b" + ($i|tostring))},
       html_url: ("https://github.com/o/r/pull/" + ((5000 - $i)|tostring)), body: null}]' > "$T/big/$p.json"
done
reset; echo big > "$T/fx.status"; run "$CLI" o/r 2026-09-01
[ "$RC" = 0 ] && ok || bad "A12: a capped read is still rc 0, got $RC ($(cat "$T/err"))"
[ "$(tail -1 "$T/out")" = "# totals harness=0 harness?=0 train=0 train?=0 operator?=0 human=1000 truncated=1" ] \
  && ok || bad "A12: totals must carry truncated=1, got $(tail -1 "$T/out")"
[ "$(lines "$T/err")" = 1 ] && ok || bad "A12: one stderr warning, got: $(cat "$T/err")"
[ "$(lines "$T/gh-calls.txt")" = 10 ] && ok || bad "A12: ten pages read, got $(lines "$T/gh-calls.txt")"

# ══ A11 read-only, across every case above ═══════════════════════════════════
# gh-calls.txt is reset per case, so this re-runs the main case and checks the
# accumulated log of a full pass of the cases that do call gh.
: > "$T/all-calls.txt"
for a in "o/r 2026-09-01" "o/r 2026-09-01 --json" "proj 2026-09-01" "o/r"; do
  reset; read -ra ARGS <<< "$a"; run "$CLI" "${ARGS[@]}"; cat "$T/gh-calls.txt" >> "$T/all-calls.txt"
done
[ -s "$T/all-calls.txt" ] && ok || bad "A11: the read-only check saw no gh calls at all"
[ "$(grep -vc '^api -i -X GET ' "$T/all-calls.txt")" = 0 ] && ok || bad "A11: a non-GET gh call was made: $(grep -v '^api -i -X GET ' "$T/all-calls.txt")"
[ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "A11: ALERTS.log must never be written"

# ══ MUTATIONS (D1) ═══════════════════════════════════════════════════════════
# Each mutant is a copy of the script beside a symlink to the real bin/lib, so
# it loads the same libraries the real one does.
ln -s "$DIR/bin/lib" "$T/mut/bin/lib"
mutant() { # mutant <name> <sed expr> -> $M (fails the suite if the sed changed nothing)
  M="$T/mut/bin/pr-attribution.$1.sh"
  sed "$2" "$CLI" > "$M"
  cmp -s "$M" "$CLI" && bad "mutation $1: the sed matched nothing, the mutant is the original"
  return 0
}
# M1: the trailer reader is replaced by one that never finds anything.
mutant m1 's/| pr_trailers_read -)/| { cat >\/dev\/null; printf "\\t\\t\\n"; })/'
reset; run "$M" o/r 2026-09-01
[ "$(cls 101)" != "harness trailer 9001 BH-77" ] && ok || bad "M1: always-heuristic must turn A1 red"
# M2: closed-unmerged rows counted by another date. (Deleting only the
# `!= null` guard is behavior-preserving: jq orders null below every string, so
# the since comparison alone already drops it. This is the realistic mistake.)
mutant m2 's/\.merged_at != null and \.merged_at >= /(.merged_at \/\/ .created_at) >= /'
reset; run "$M" o/r 2026-09-01
[ -n "$(row 109)" ] && ok || bad "M2: counting closed-unmerged PRs must turn A8 red"
# M3: the since filter dropped.
mutant m3 's/ and \.merged_at >= (\$since + "T00:00:00Z")//'
reset; run "$M" o/r 2026-09-01
[ -n "$(row 108)" ] && ok || bad "M3: dropping the since filter must turn A3 red"
# M4: a failed read exits 0.
mutant m4 's/^  exit 75 # read-failed$/  exit 0/'
reset; echo 403 > "$T/fx.status"; run "$M" o/r 2026-09-01
[ "$RC" != 75 ] && ok || bad "M4: exit 0 on a failed read must turn A6 red"
# M5: the first Harness-Job: line wins (the reader is wrapped to keep the first).
mutant m5 's/| pr_trailers_read -)/| awk '"'"'\/^Harness-Job:\/ \&\& f++ {next} 1'"'"' | pr_trailers_read -)/'
reset; run "$M" o/r 2026-09-01
[ "$(field 101 5)" = forged ] && ok || bad "M5: first-occurrence-wins must turn A1's job value red, got '$(field 101 5)'"

echo "pr-attribution.bh-4016: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
