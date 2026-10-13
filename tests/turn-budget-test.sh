#!/bin/bash
# tests/turn-budget-test.sh — the per-turn dollar bound, and its own honesty.
#
# `--max-budget-usd` is a DIRECT cost cap per invocation, which is what we
# actually care about: a turn can be 5 cheap calls or 5 expensive ones, and only
# the dollars matter. Verified present on the hub's claude 2.1.241.
#
# WHAT IS NOT VERIFIED, AND WHY THE CODE CHECKS ITSELF. Whether the cap actually
# TRIPS on a subscription-OAuth session is unestablished — a flag existing is
# not a flag bounding anything, and shipping a cap that silently enforces
# nothing is the exact failure this wave exists to end. It cannot be settled
# from a laptop: it needs a real turn driven into the cap on the box.
#
# So the code detects its own inertness on real traffic. After every turn it
# prices the session's own usage, and a turn that cost MORE than the budget
# while the CLI never said it stopped is proof the flag did nothing — which
# raises an alert saying exactly that. The first runaway turn settles the
# question either way, with nobody having to remember to check.
# Run from anywhere: tests/turn-budget-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
ORC="$DIR/bin/orchestrate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/flags" "$T/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
mkdir -p "$T/orc"
# PRICES ARE DATA. turn_cost_usd resolves them from catalog/model-prices.json
# keyed on the model that served; the constants it used to carry inline were
# opus-tier while the lane runs claude-fable-5, so the detector's threshold and
# the ledger's dollars meant different things. The fixture carries the real
# fable shape (PER TOKEN, as the table stores it).
cat > "$T/prices.json" <<'EOF'
{"updated_at":"2026-08-25T00:00:00Z","per_token":{"test-fable":{"prompt":1e-05,"completion":5e-05,"cache_read":1e-06,"cache_write":1.25e-05}}}
EOF

# --- 1. the flag is on EVERY invocation --------------------------------------
# Three claude calls live in run_turn (fresh, continue, first-turn-fresh). A cap
# on two of three is a cap with a hole, and the hole is the path taken when a
# continued session has no conversation — i.e. exactly the unusual case.
N=$(grep -c -- '--max-budget-usd "\$ORC_BUDGET"' "$ORC")
[ "$N" -eq 3 ] \
  && ok || bad "expected the budget flag on all 3 claude invocations, found $N"

# --- 1b. THE SEAM: run_turn must actually CALL budget_check -------------------
# Everything below tests budget_check directly, and all of it stays green with
# the call deleted from run_turn — the function would be perfect and never run.
# Fourth time this session that the units were covered and the wiring was not,
# so it gets its own assertion rather than a comment reminding someone to look.
python3 - "$ORC" <<'@PY@' && ok || bad "run_turn never calls budget_check — the bound and the detector would both be dead code"
import sys, re
src = open(sys.argv[1]).read()
i = src.index("run_turn() {")
body = src[i:src.index("\n}\n", i)]
assert re.search(r'budget_check\s+"\$t0"', body), "budget_check is not invoked inside run_turn"
@PY@

# --- 1c. THE SEAM UNDERNEATH: the usage read must be SCOPED and DATA-PRICED ---
# Everything below stubs claude-usage.sh, so it proves the detector's ARITHMETIC
# and nothing about its INPUT. Measured on the hub 2026-08-25: unscoped, the
# real reader answered an 18-call orchestrator turn (1,087,133 cache_read) with
# `4|28|70548|0` — an unrelated session's tokens, ~15x low — and all 18
# assertions here stayed green, because a stub cannot be wrong. So the call site
# gets asserted where the stub cannot reach it. (The reader's own behaviour is
# proven against a real-shaped tree in tests/chat-usage-capture-test.sh §2b.)
python3 - "$ORC" <<'@PY@' && ok || bad "turn_cost_usd reads usage unscoped — it can price another session's turn as this one"
import sys, re
src = open(sys.argv[1]).read()
i = src.index("turn_cost_usd() {")
body = src[i:src.index("\n}\n", i)]
assert re.search(r'claude-usage\.sh"\s+"\$1"\s+"--cwd=\$ORC"', body), \
    "the usage read is not scoped to the orchestrator's own session tree"
@PY@
python3 - "$ORC" <<'@PY@' && ok || bad "turn_cost_usd hardcodes prices — the detector's threshold would mean something different from the ledger's dollars"
import sys, re
src = open(sys.argv[1]).read()
i = src.index("turn_cost_usd() {")
body = src[i:src.index("\n}\n", i)]
assert "MODEL_PRICES" in body and "per_token" in body, "prices are not resolved from the price table"
# The constants that used to live here were opus-tier ($15/$18.75/$1.50/$75 per
# M) on a lane running claude-fable-5 — the same turn priced $5.71 here and
# $3.81 in the ledger. Model/price config is data, not code.
assert not re.search(r'1e6\s*\*\s*(15|18\.75|1\.5|75)\b', body), "an inline per-million price constant is back"
@PY@

# --- 2. it is env-tunable and the effective value is LOGGED ------------------
# Same reasoning as the #67 threshold: a bound nobody can confirm from the box
# is a bound people assume rather than know.
grep -q 'ORC_TURN_BUDGET_USD:-2.00' "$ORC" \
  && ok || bad "no env-tunable default for the turn budget"
grep -q 'turn budget \\\$\$ORC_BUDGET (\$_BSRC)' "$ORC" \
  && ok || bad "the effective budget is not logged with its source"

# --- 3. budget_hit matches the CLI's words, and does not over-match ----------
python3 - "$ORC" "$T/fns.sh" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
out = []
# turn_cost_usd is named EXPLICITLY. It used to arrive by accident: budget_hit
# was a one-liner, so the "up to the next \n}\n" scan ran past it and swept
# turn_cost_usd in. Making budget_hit multi-line silently dropped it and three
# assertions failed for a reason unrelated to the change. An extraction that
# depends on the formatting of an unrelated function is not an extraction.
for name in ("budget_hit() {", "turn_cost_usd() {", "budget_check() {"):
    i = src.index(name)
    out.append(src[i:src.index("\n}\n", i) + len("\n}\n")])
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/fns.sh" ] && ok || bad "could not extract budget_hit/budget_check from orchestrate.sh"

hit() { bash -c '. "'"$T"'/fns.sh"; if budget_hit "$1"; then echo YES; else echo NO; fi' _ "$1"; }
[ "$(hit "Error: max budget exceeded")" = YES ] && ok || bad "must match the CLI's budget message"
[ "$(hit "reached the max-budget-usd limit")" = YES ] && ok || bad "must match the flag-name phrasing"
# HOSTILE FIXTURES, and they are hostile on purpose. The previous fixture here
# ("the budget for Q3 marketing is approved") contained no trigger words at
# all, so it passed against the BROKEN matcher too — the token-less-decoy
# problem from #69, where a test proves nothing because its input could never
# have failed. These three all MATCHED the old regex, and all three are
# ordinary sentences for an orchestrator that discusses client engagements and
# is currently working a cost wave.
for PROSE in \
  "The Q3 marketing budget exceeded forecast by 12%" \
  "Tell the operator the budget limit for the project-2 engagement is \$100K" \
  "We exceeded the project budget last quarter"; do
  [ "$(hit "$PROSE")" = NO ] \
    || bad "ordinary prose read as a cap hit, which would prefix a COMPLETE answer with a false 'I stopped partway': $PROSE"
done
ok

# A stop notice buried EARLY in a long reply is prose, not a stop: the CLI
# prints its notice last. This pins the positional anchor, which the flag-name
# anchor alone does not cover.
LONGPROSE=$(printf 'The max budget exceeded our forecast.\nfiller\nfiller\nfiller\nfiller\nfiller\nhere is the real answer\n')
[ "$(hit "$LONGPROSE")" = NO ] \
  && ok || bad "budget language early in a long reply must not read as a terminal stop notice"
[ "$(hit "here is your answer")" = NO ] && ok || bad "must not fire on a normal reply"

# --- 4. A BUDGET STOP IS ANNOUNCED, not handed back as a whole answer --------
# This is the honesty half. A cap that stops mid-turn returns partial work, and
# presenting it as complete is a silent truncation — the reader cannot tell a
# finished answer from a cut-off one.
OUT_TEXT=$(bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="test-fable"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="I was working on it. Error: max budget exceeded"
  . "'"$T"'/fns.sh"
  budget_check 0
  printf "%s" "$OUT"')
grep -q 'Turn budget exhausted' <<<"$OUT_TEXT" \
  && ok || bad "a budget stop must say so in the reply, not pass partial work off as complete"
grep -q 'ask me to continue' <<<"$OUT_TEXT" \
  && ok || bad "the reply must tell the operator how to resume"
grep -q 'I was working on it' <<<"$OUT_TEXT" \
  && ok || bad "the partial work must be kept, not discarded — it is still the best answer available"

# --- 5. THE INERTNESS DETECTOR ------------------------------------------------
# The flag existing is not the flag working. If a turn cost more than the budget
# and the CLI never reported stopping, the bound is imaginary and that must be
# said out loud rather than assumed away.
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$T/bin/claude-usage.sh"
chmod +x "$T/bin/claude-usage.sh"
rm -f "$T/logs/ALERTS.log"
bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="test-fable"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="a perfectly normal looking answer"
  . "'"$T"'/fns.sh"
  budget_check 0' >/dev/null 2>&1
grep -q 'BUDGET FLAG INERT' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a turn that outspent the budget without stopping must expose the flag as inert"
grep -q 'treat the turn cap as absent' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the alert must say what to believe now — an unenforced cap is worse than a known-absent one"

# A turn UNDER budget must stay silent. A detector that always fires is not a
# detector, and this one would otherwise cry inert on every healthy turn.
printf '#!/bin/bash\necho "1000|1000|0|0"\n' > "$T/bin/claude-usage.sh"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="test-fable"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="a normal answer"
  . "'"$T"'/fns.sh"
  budget_check 0' >/dev/null 2>&1
[ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "a cheap turn must not be reported as evidence the flag is inert"

# And a turn that DID stop must not also be called inert — the cap worked.
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$T/bin/claude-usage.sh"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="test-fable"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="Error: max budget exceeded"
  . "'"$T"'/fns.sh"
  budget_check 0' >/dev/null 2>&1
[ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "a turn the cap actually stopped must not be reported as proof the cap does nothing"

# A TURN THIS CHECK CANNOT PRICE IS NOT A PASSING TURN. Silence on an unknown
# model reads exactly like a cheap turn, which is the check reporting "fine"
# when it means "I did not look" — the failure this whole wave is about.
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$T/bin/claude-usage.sh"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="a-model-nobody-priced"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="a normal answer"
  . "'"$T"'/fns.sh"
  budget_check 0' >/dev/null 2>&1
grep -q 'TURN NOT PRICED' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "an unpriceable model must be declared, not passed over in silence"
grep -q 'not passing, unchecked' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the alert must distinguish 'under budget' from 'never checked'"

# Once per day, not once per turn: an alert on every expensive turn is noise.
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$T/bin/claude-usage.sh"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
for _ in 1 2; do bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; ORC_BUDGET="2.00"
  ORC="'"$T"'/orc"; ORC_MODEL="test-fable"; export MODEL_PRICES="'"$T"'/prices.json"
  OUT="normal"
  . "'"$T"'/fns.sh"
  budget_check 0' >/dev/null 2>&1; done
[ "$(grep -c 'BUDGET FLAG INERT' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the inert-flag alert must fire once per day, not once per turn"

# --- 7. THE HANDOFF: a refusal is only safe if the caller HONORS it -----------
# #97 made a truncated read exit 3, and tests/chat-usage-capture-test.sh proves
# the reader does that. Nothing proved the other half: that turn_cost_usd's
# `|| return 1` carries the refusal through, so a truncated turn is REFUSED
# rather than priced from the partial it still prints. That link lives in
# orchestrate.sh, spans two files, and every assertion above stubs the reader —
# so someone deleting the propagation turns "truncated" into "priced low, looks
# cheap, no alert" with all 24 reader assertions still green.
#
# This drives the REAL reader and the REAL budget_check, no stub. The second
# case is the control and it is the entire point: without it the truncation
# assertion also passes whenever the scope resolves to nothing, which is the
# wrong-reason trap that caught both review-pr35 and me on #97's first check.
H2="$T/real"; mkdir -p "$H2/logs" "$H2/flags" "$H2/bin"
cp "$DIR/bin/claude-usage.sh" "$H2/bin/claude-usage.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H2/bin/"
E2E_ORC="$T/orc"
E2E_SCOPE="$T/home/.claude/projects/$(printf '%s' "$E2E_ORC" | tr '/' '-')"
mkdir -p "$E2E_SCOPE"
e2e_turn() {  # the real Claude Code session shape
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":12,"output_tokens":5000,"cache_read_input_tokens":400000,"cache_creation_input_tokens":60000}}}\n' \
    "$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
}
for f in a b c; do e2e_turn > "$E2E_SCOPE/$f.jsonl"; done
e2e_run() {  # e2e_run <max-files>
  rm -f "$H2/logs/ALERTS.log" "$H2/flags/"*
  HOME="$T/home" HARNESS="$H2" ORC="$E2E_ORC" ORC_MODEL="test-fable" ORC_BUDGET="2.00" \
  MODEL_PRICES="$T/prices.json" CLAUDE_USAGE_MAX_FILES="$1" \
  bash -c '. "'"$T"'/fns.sh"; OUT="a perfectly normal looking answer"; budget_check 0' >/dev/null 2>&1
}
# TRUNCATED -> refused. Priced from the 2-file partial this would read $2.80 and
# convict; priced from a smaller partial it would read cheap and say nothing.
# Both are wrong answers to a question we could not answer.
e2e_run 2
grep -q 'TURN NOT PRICED' "$H2/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a truncated read was priced instead of refused — the reader's exit 3 is not reaching the caller"
# THE CONTROL, same fixture, cap above the file count: it must price ($4.20) and
# convict. If this does not fire, the case above proved only that nothing was
# read, which is not the same claim at all.
e2e_run 5
grep -q 'BUDGET FLAG INERT' "$H2/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the control did not price — the truncation case proves nothing"
grep -q 'TURN NOT PRICED' "$H2/logs/ALERTS.log" 2>/dev/null \
  && bad "an untruncated read must not be reported as unpriceable" || ok

# --- 8. REACHABILITY: the detector must RUN on the path turns actually take ---
# Assertion 1b greps run_turn's body for `budget_check "$t0"` and passes as long
# as the call EXISTS. It existed. It was also unreachable: the `if orc_fresh`
# branch — the default since #73 — did `RC=$?; return` before ever reaching it,
# so budget_check had never executed in production on any turn at any price.
#
# Measured on the hub 2026-08-25, after #95 had already fixed the reader and the
# prices: turns of $2.06, $2.57, $2.93 against a $2.00 cap, no alert, no flag.
# Presence is not reachability, and only driving the function tells them apart —
# so this DRIVES run_turn down the fresh path with a stubbed CLI and asserts the
# alert lands.
H3="$T/reach"; mkdir -p "$H3/logs" "$H3/flags" "$H3/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H3/bin/"
printf '#!/bin/bash\necho "a normal looking answer"\n' > "$H3/bin/claude"
printf '#!/bin/bash\necho "1000000|1000000|0|0"\n' > "$H3/bin/claude-usage.sh"
chmod +x "$H3/bin/claude" "$H3/bin/claude-usage.sh"
python3 - "$ORC" "$T/runturn.sh" <<'@RT@'
import sys
src = open(sys.argv[1]).read()
out = []
for name in ("run_turn() {", "budget_hit() {", "turn_cost_usd() {", "budget_check() {"):
    i = src.index(name)
    out.append(src[i:src.index("\n}\n", i) + len("\n}\n")])
open(sys.argv[2], "w").write("\n".join(out))
@RT@
REACH=$(PATH="$H3/bin:$PATH" bash -c '
  set -uo pipefail
  HARNESS="'"$H3"'"; ORC_BUDGET="2.00"; ORC="'"$T"'/orc"; ORC_MODEL="test-fable"
  export MODEL_PRICES="'"$T"'/prices.json"
  TEXT="hello"; ORC_TOKEN=""
  orc_fresh() { return 0; }            # THE DEFAULT PATH
  compose_v2_prompt() { echo "prompt"; }
  . "'"$T"'/runturn.sh"
  run_turn test-fable >/dev/null 2>&1
  grep -c "BUDGET FLAG INERT" "'"$H3"'/logs/ALERTS.log" 2>/dev/null || echo 0')
[ "${REACH:-0}" -ge 1 ] \
  && ok || bad "budget_check never RAN on the fresh path — the default path every turn takes skips the detector entirely"

echo "turn-budget-test: $PASS pass, $FAIL fail"
echo "NOTE: whether --max-budget-usd TRIPS under subscription OAuth is UNVERIFIED."
echo "      It needs a real turn driven into the cap on the box. Until then the"
echo "      inertness detector is what will tell us, on the first runaway turn."
[ "$FAIL" -eq 0 ]
