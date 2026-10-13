#!/bin/bash
# tests/jev-pilot-score.bh-5024-test.sh — the BH-5024 replay pilot and its
# pre-registered decision rule (docs/jev-pilot/replay.py, docs/jev-pilot/score.py).
#
#   P1  replay.py --dry-run on fixtures (lead MERGE-WITH-NOTES and lead BLOCK
#       since 09-01, a box-only PR, a pre-09-01 lead PR, a lead PR with no
#       compare) keeps exactly the two lead rows, writes the unreadable one as a
#       skip row, makes 0 vendor calls; a rerun adds no duplicate row
#   P2  50 BLOCK rows, none called low by Jev, Jev merge_low > Haiku's -> PASS rc 0
#   P3  50 BLOCK rows, 1 called low by Jev (2.0%, not under 2%) -> FAIL rc 1 naming 2%
#   P4  Jev under 2% but merge_low_rate <= Haiku's -> FAIL rc 1 naming Haiku
#   P5  rows where only one model answered ok are excluded from both, and counted
#   P6  zero BLOCK rows -> INCONCLUSIVE rc 2; would-lower counts only rule
#       medium -> jev low; an empty input is INCONCLUSIVE rc 2
#   P7  the live Haiku call runs agent-call.sh with AGENT_CALL_NO_TOOLS=1 and
#       AGENT_CALL_RUNNERS=claude; a refused call (rc 78) stops the run, rc 3
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/jev-pilot-score.bh-5024-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REPLAY="$DIR/docs/jev-pilot/replay.py"
SCORE="$DIR/docs/jev-pilot/score.py"

# ---- stubs: every vendor door appends to $T/hits ----------------------------
mkdir -p "$T/bin" "$T/h/bin/lib" "$T/fx/verdicts" "$T/fx/cmp" "$T/fx/rule" "$T/fx/jev" "$T/fx/haiku"
: > "$T/hits"
for s in "$T/bin/gh" "$T/bin/curl" "$T/h/bin/jev-risk.sh" "$T/h/bin/agent-call.sh" "$T/h/bin/jobs-client.sh"; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$(basename "$s")" "$T/hits" > "$s"
  chmod +x "$s"
done

# ---- fixtures ----------------------------------------------------------------
HA=$(printf 'a%.0s' $(seq 40)); HB=$(printf 'b%.0s' $(seq 40))
HC=$(printf 'c%.0s' $(seq 40)); HD=$(printf 'd%.0s' $(seq 40)); HE=$(printf 'e%.0s' $(seq 40))
cat > "$T/fx/prs.json" <<EOF
[{"number":101,"updated_at":"2026-09-06T00:00:00Z","base":{"sha":"$HE"}},
 {"number":102,"updated_at":"2026-09-11T00:00:00Z","base":{"sha":"$HE"}},
 {"number":103,"updated_at":"2026-09-12T00:00:00Z","base":{"sha":"$HE"}},
 {"number":104,"updated_at":"2026-09-02T00:00:00Z","base":{"sha":"$HE"}},
 {"number":105,"updated_at":"2026-09-13T00:00:00Z","base":{"sha":"$HE"}},
 {"number":106,"updated_at":"2026-08-20T00:00:00Z","base":{"sha":"$HE"}}]
EOF
# 101: an older lead BLOCK, then the newest lead row MERGE-WITH-NOTES on HA.
cat > "$T/fx/verdicts/101.json" <<EOF
{"rows":[{"id":1,"source":"lead","verdict":"BLOCK","head_sha":"$HD","created_at":"2026-09-03T00:00:00Z"},
 {"id":2,"source":"lead","verdict":"MERGE-WITH-NOTES","head_sha":"$HA","created_at":"2026-09-05T00:00:00Z"},
 {"id":3,"source":"box","verdict":"BLOCK","head_sha":"$HA","created_at":"2026-09-06T00:00:00Z"}],"truncated":false}
EOF
cat > "$T/fx/verdicts/102.json" <<EOF
{"rows":[{"id":4,"source":"lead","verdict":"BLOCK","head_sha":"$HB","created_at":"2026-09-10T00:00:00Z"}],"truncated":false}
EOF
cat > "$T/fx/verdicts/103.json" <<EOF
{"rows":[{"id":5,"source":"box","verdict":"MERGE","head_sha":"$HC","created_at":"2026-09-12T00:00:00Z"}],"truncated":false}
EOF
cat > "$T/fx/verdicts/104.json" <<EOF
{"rows":[{"id":6,"source":"lead","verdict":"MERGE","head_sha":"$HC","created_at":"2026-08-20T00:00:00Z"}],"truncated":false}
EOF
cat > "$T/fx/verdicts/105.json" <<EOF
{"rows":[{"id":7,"source":"lead","verdict":"BLOCK","head_sha":"$HD","created_at":"2026-09-13T00:00:00Z"}],"truncated":false}
EOF
for n in 101 102 103 104 106; do
  echo '{"files":[{"filename":"docs/x.md","status":"modified","additions":3,"deletions":1}]}' > "$T/fx/cmp/$n.json"
  printf 'medium\tfixture\t4\t1\n' > "$T/fx/rule/$n.txt"
  printf '{"rc":0,"out":"ok\\tlow\\t0.9\\tmedium"}\n' > "$T/fx/jev/$n.json"
  printf '{"rc":0,"out":"sure: {\\"choice\\":\\"medium\\",\\"probability\\":0.7}"}\n' > "$T/fx/haiku/$n.json"
done

replay() {
  env PATH="$T/bin:$PATH" python3 -I "$REPLAY" --repo example-org/cromford --since 2026-09-01 \
    --out "$T/out" --harness "$T/h" --dry-run --fixtures "$T/fx" > "$T/r.out" 2> "$T/r.err"
}
settled() { python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(" ".join("%s:%s:%s:%s:%s:%s" % (r["pr"], r["lead_verdict"], r["head"][:1], r["rule_tier"], r["jev_tier"], r["haiku_tier"])
      for r in sorted(rows, key=lambda r: r["pr"]) if not r.get("skip_reason")))' "$T/out/replay.jsonl"; }
skiprows() { python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(" ".join("%s:%s" % (r["pr"], r["skip_reason"]) for r in rows if r.get("skip_reason")))' "$T/out/replay.jsonl"; }

# ---- P1 ------------------------------------------------------------------------
replay; rc=$?
got=$(settled 2>&1); sk=$(skiprows 2>&1)
if [ "$rc" = 0 ] && [ "$got" = "101:MERGE:a:medium:low:medium 102:BLOCK:b:medium:low:medium" ]; then ok
else bad "P1 expected exactly the two lead rows (rc=$rc): got [$got] $(cat "$T/r.err")"; fi
if [ "$sk" = "105:compare unreadable" ] && grep -q 'skipped 1' "$T/r.out"; then ok
else bad "P1 expected PR 105 as one counted skip row: got [$sk] $(cat "$T/r.out")"; fi
if [ ! -s "$T/hits" ]; then ok; else bad "P1 dry-run made vendor calls: $(cat "$T/hits")"; fi
if [ -f "$T/out/cmp/101-${HA:0:12}.json" ] && [ "$(wc -l < "$T/out/haiku.jsonl")" -eq 2 ]; then ok
else bad "P1 expected the compare cache file and 2 haiku cache lines"; fi
# Rerun: nothing new is asked and nothing is duplicated.
replay; rc=$?
got2=$(settled 2>&1); sk2=$(skiprows 2>&1)
if [ "$rc" = 0 ] && [ "$got2" = "$got" ] && [ "$sk2" = "$sk" ] && [ "$(wc -l < "$T/out/replay.jsonl")" -eq 3 ] \
   && grep -q 'already present 2' "$T/r.out" && [ "$(wc -l < "$T/out/haiku.jsonl")" -eq 2 ]; then ok
else bad "P1 rerun not resumable (rc=$rc): [$got2] [$sk2] $(cat "$T/r.out")"; fi
if [ ! -s "$T/hits" ]; then ok; else bad "P1 rerun made vendor calls: $(cat "$T/hits")"; fi

# ---- score fixtures ----------------------------------------------------------------
# gen <file> <spec>...   spec = LEAD:JEV:HAIKU:COUNT[:RULE[:JEVSTATUS[:HAIKUSTATUS]]]
gen() { python3 -I -c 'import json,sys
out=open(sys.argv[1],"w"); n=0
for spec in sys.argv[2:]:
    p=spec.split(":")+[""]*4
    lead,jt,ht,cnt=p[0],p[1],p[2],int(p[3])
    rule=p[4] or "medium"; js=p[5] or "ok"; hs=p[6] or "ok"
    for _ in range(cnt):
        n+=1
        out.write(json.dumps({"repo":"o/r","pr":n,"head":"%040x"%n,"lead_verdict":lead,"rule_tier":rule,
          "jev_status":js,"jev_tier":jt if js=="ok" else None,"jev_prob":0.8,
          "haiku_status":hs,"haiku_tier":ht if hs=="ok" else None,"skip_reason":None})+"\n")' "$@"; }
score() { python3 -I "$SCORE" "$1" > "$T/s.out" 2> "$T/s.err"; }

# ---- P2 ------------------------------------------------------------------------
gen "$T/p2.jsonl" BLOCK:medium:medium:50 MERGE:low:medium:10 MERGE:medium:low:5 MERGE:medium:medium:5
score "$T/p2.jsonl"; rc=$?
if [ "$rc" = 0 ] && grep -q '^VERDICT: PASS' "$T/s.out" && grep -q '^| jev |' "$T/s.out"; then ok
else bad "P2 expected PASS rc 0 (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi

# ---- P3 ------------------------------------------------------------------------
gen "$T/p3.jsonl" BLOCK:low:low:1 BLOCK:medium:low:49 MERGE:low:medium:10 MERGE:medium:medium:10
score "$T/p3.jsonl"; rc=$?
if [ "$rc" = 1 ] && grep -q '^VERDICT: FAIL.*2%' "$T/s.out" && ! grep -q '^VERDICT: FAIL.*Haiku' "$T/s.out"; then ok
else bad "P3 expected FAIL rc 1 naming only the 2% clause (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi

# ---- P4 ------------------------------------------------------------------------
gen "$T/p4.jsonl" BLOCK:medium:medium:50 MERGE:low:low:5 MERGE:medium:medium:15
score "$T/p4.jsonl"; rc=$?
if [ "$rc" = 1 ] && grep -q '^VERDICT: FAIL.*Haiku' "$T/s.out" && ! grep -q '^VERDICT: FAIL.*2%' "$T/s.out"; then ok
else bad "P4 expected FAIL rc 1 naming only the Haiku clause (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi

# ---- P5 ------------------------------------------------------------------------
# The P2 set plus 3 BLOCK rows Jev called low but Haiku failed, and 2 MERGE rows
# Haiku called low but Jev came back empty. Counted in, they would flip P2 to
# FAIL (3/53 = 5.7%); excluded from both, the verdict stays PASS.
gen "$T/p5.jsonl" BLOCK:medium:medium:50 MERGE:low:medium:10 MERGE:medium:low:5 MERGE:medium:medium:5 \
  BLOCK:low:low:3:medium:ok:failed MERGE:low:low:2:medium:empty:ok
score "$T/p5.jsonl"; rc=$?
if [ "$rc" = 0 ] && grep -q '^VERDICT: PASS' "$T/s.out" && grep -q '^excluded haiku failed: 3$' "$T/s.out" \
   && grep -q '^excluded jev empty: 2$' "$T/s.out" && grep -q 'shared set: 70, excluded: 5' "$T/s.out" \
   && grep -q '^| jev | 0/50 ' "$T/s.out"; then ok
else bad "P5 expected one-model rows excluded and counted (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi

# ---- P6 ------------------------------------------------------------------------
# No BLOCK rows. Would-lower: 4 rule-medium/jev-low rows count; rule high/jev
# low (2) and rule medium/jev medium (3) do not.
gen "$T/p6.jsonl" MERGE:low:medium:4:medium MERGE:low:medium:2:high MERGE:medium:medium:3:medium
score "$T/p6.jsonl"; rc=$?
if [ "$rc" = 2 ] && grep -q '^VERDICT: INCONCLUSIVE' "$T/s.out" \
   && grep -q '^would-lower (rule medium, jev low): 4, of them lead BLOCK: 0$' "$T/s.out"; then ok
else bad "P6 expected INCONCLUSIVE rc 2, would-lower 4 (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi
gen "$T/p6b.jsonl" BLOCK:low:low:2:medium BLOCK:low:low:1:high MERGE:low:low:3:medium MERGE:medium:medium:1:medium
score "$T/p6b.jsonl"; rc=$?
if [ "$rc" = 1 ] && grep -q '^would-lower (rule medium, jev low): 5, of them lead BLOCK: 2$' "$T/s.out"; then ok
else bad "P6 expected would-lower 5 with 2 lead BLOCK (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi
: > "$T/empty.jsonl"
score "$T/empty.jsonl"; rc=$?
if [ "$rc" = 2 ] && grep -q '^VERDICT: INCONCLUSIVE' "$T/s.out"; then ok
else bad "P6 empty input expected INCONCLUSIVE rc 2 (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi
score "$T/does-not-exist.jsonl"; rc=$?
if [ "$rc" = 2 ] && grep -q '^VERDICT: INCONCLUSIVE' "$T/s.out"; then ok
else bad "P6 missing input expected INCONCLUSIVE rc 2 (rc=$rc): $(cat "$T/s.out" "$T/s.err")"; fi

# ---- P7 ------------------------------------------------------------------------
# The Haiku baseline is a decision-only call over untrusted diff text: the live
# path runs bin/agent-call.sh with no tools and pinned to the claude rung, and a
# refusal (rc 78) stops the run rather than skipping the PR.
mkdir -p "$T/h7/bin"
cat > "$T/h7/bin/agent-call.sh" <<'EOF7'
#!/bin/bash
printf 'NO_TOOLS=%s RUNNERS=%s ARGS=%s\n' "${AGENT_CALL_NO_TOOLS:-}" "${AGENT_CALL_RUNNERS:-}" "$*" > "$(dirname "$0")/../seen"
printf '{"choice":"low","probability":0.6}\n' > "$5"
EOF7
chmod +x "$T/h7/bin/agent-call.sh"
printf 'prompt\n' > "$T/p7-prompt.txt"
hrc=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import replay
print(replay.Live(sys.argv[2]).haiku("m-fixture", sys.argv[3], sys.argv[4], 1))' \
  "$DIR/docs/jev-pilot" "$T/h7" "$T/p7-prompt.txt" "$T/p7-answer.txt" 2>&1)
seen=$(cat "$T/h7/seen" 2>/dev/null)
case "$seen" in
  "NO_TOOLS=1 RUNNERS=claude ARGS=triage fleet m-fixture 180 $T/p7-answer.txt @$T/p7-prompt.txt") ok ;;
  *) bad "P7 the live baseline call is not no-tools + claude-only (rc=$hrc): [$seen]" ;;
esac
cp -r "$T/fx" "$T/fx7"
printf '{"rc":78,"out":""}\n' > "$T/fx7/haiku/101.json"
env PATH="$T/bin:$PATH" python3 -I "$REPLAY" --repo example-org/cromford --since 2026-09-01 \
  --out "$T/out7" --harness "$T/h" --dry-run --fixtures "$T/fx7" > "$T/r7.out" 2> "$T/r7.err"; rc=$?
if [ "$rc" = 3 ] && grep -q 'STOPPED: agent-call refused the no-tools baseline call (rc 78)' "$T/r7.err" \
   && [ ! -s "$T/out7/haiku.jsonl" ]; then ok
else bad "P7 a refused baseline call did not stop the run (rc=$rc): $(cat "$T/r7.out" "$T/r7.err")"; fi

echo "jev-pilot-score.bh-5024: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
