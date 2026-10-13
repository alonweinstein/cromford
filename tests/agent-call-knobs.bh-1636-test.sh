#!/bin/bash
# tests/agent-call-knobs.bh-1636-test.sh — bin/agent-call.sh's operator knobs
# are settings rows (BH-1636 item 2).
#
# GROK_OUTPUT_JSON and the other numeric policy knobs agent-call.sh reads are
# registered in catalog/lanes.d/_lib.json as the `agent-call` lib, keyed
# `lib.agent-call.<env lowercased>`, and agent-call.sh calls lib_env_apply for
# them right after it sources the spend gate. So flipping grok's envelope
# capture is one settings row, not an env/global.env edit on every box.
#
#   K1  the registry entry: unique knobs, none required, all settable, and every
#       default equal to the literal agent-call.sh itself falls back to
#   K2  a lib.agent-call.grok_output_json=1 row turns the envelope on
#   K3  a lib.agent-call.grok_max_turns=7 row reaches grok's --max-turns
#   K4  no rows: the call is today's call (no json, --max-turns 25), and an
#       env GROK_OUTPUT_JSON=1 is still honoured
#   K5  LANE_GATE_DISABLE=1: a row is not applied
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/agent-call-knobs.bh-1636-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
ENV_FIX="$DIR/tests/fixtures/grok-usage/1.0.40/envelope.json"
AC="$DIR/bin/agent-call.sh"
mkdir -p "$T/logs" "$T/flags" "$T/locks" "$T/fakebin" "$T/bin" "$T/env" "$T/state"
: > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── K1. the registry entry ───────────────────────────────────────────────────
echo "--- K1. registry"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "K1 lanes-build.sh could not compose the registry"
LIB() { jq -r --arg q "$1" '.libs[]?|select(.id=="agent-call")|'"$1" "$REG" 2>/dev/null; }
[ "$(LIB .file)" = bin/agent-call.sh ] && ok || bad "K1 lib agent-call must name bin/agent-call.sh, got '$(LIB .file)'"
# TEST-CHANGE (Lane E, 2026-09-24): this was `.knobs|length = 17`, re-pinned by
# three PRs in four days (the 2026-09-23 pool loop's OpenRouter headroom pair and
# fallback gate, BH-1837's AGENT_CALL_MODEL_MISMATCH and stage-route pair). Two
# sibling PRs that each add a knob each bump the integer to the same N+1, merge
# clean, and are red together at N+2. The count's real guarantee — no knob is
# registered (or dropped) without a reviewed edit to THIS suite — is kept as a
# reviewed allowlist in fragments: tests/agent-call-knobs.d/*.txt, one env per
# line, `#` comments, the base in 00-base.txt and one <TICKET-KEY>.txt per PR
# that adds a knob. The registry's env SET must EQUAL the fragments' union, in
# both directions, so a registration nobody listed here is red (review of #2226:
# ATTEMPT_N, LANE_GATE_DISABLE and AGENT_CALL_NO_TOOLS are per-call context,
# which _lib.json forbids as knobs, and each one is refused below).
KD="$DIR/tests/agent-call-knobs.d"
# k1_allowlist <dir> — the union of the fragments, sorted; rc 1 (stderr names
# the file) on a stray, symlinked or malformed fragment, or an empty dir.
k1_allowlist() {
  local d="$1" f bad=0 n=0
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "${f##*/}" in
      *.txt) if [ -L "$f" ] || [ ! -f "$f" ]; then echo "k1: ${f##*/} is not a regular file" >&2; bad=1; else n=$((n+1)); fi ;;
      *) echo "k1: ${f##*/} is not a <TICKET-KEY>.txt fragment, so never read" >&2; bad=1 ;;
    esac
  done
  [ "$n" -gt 0 ] || { echo "k1: $d holds no *.txt fragment" >&2; return 1; }
  awk '/^[[:space:]]*(#|$)/{next} $0 !~ /^[A-Z][A-Z0-9_]*$/ { f=FILENAME; sub(/.*\//,"",f); print "k1: " f ":" FNR " is not one env name: " $0 > "/dev/stderr"; e=1; next } {print} END{exit e}' \
    "$d"/*.txt | LC_ALL=C sort -u || bad=1
  [ "$bad" = 0 ]
}
# k1_setdiff <registry.json> <dir> — one line per env in only one of the two
# sets, `+ENV` registered but not listed, `-ENV` listed but not registered.
k1_setdiff() {
  local reg; reg=$(jq -r '.libs[]?|select(.id=="agent-call")|.knobs[].env' "$1" 2>/dev/null | LC_ALL=C sort -u)
  comm -3 <(printf '%s\n' "$reg" | grep .) <(k1_allowlist "$2" 2>/dev/null) | sed -E 's/^\t/-/; s/^([^-])/+\1/'
}
ALLOW=$(k1_allowlist "$KD" 2>"$T/k1.err") && ok || bad "K1 tests/agent-call-knobs.d must assemble: $(tr '\n' ' ' < "$T/k1.err")"
[ -n "$ALLOW" ] && ok || bad "K1 the allowlist is empty"
[ "$(LIB '[.knobs[].env]|length')" = "$(LIB '[.knobs[].env]|unique|length')" ] && ok \
  || bad "K1 an agent-call knob env is registered twice: $(LIB '[.knobs[].env]|group_by(.)|map(select(length>1)[0])|join(" ")')"
SD=$(k1_setdiff "$REG" "$KD")
[ -z "$SD" ] && ok || bad "K1 the registry and tests/agent-call-knobs.d disagree (+ registered but not listed, - listed but not registered): $(tr '\n' ' ' <<<"$SD")"
# The guard proves itself: registering each per-call context env the review
# named, unlisted, must be red; listing a knob the registry lacks must be red.
for e in ATTEMPT_N LANE_GATE_DISABLE AGENT_CALL_NO_TOOLS; do
  jq --arg e "$e" '(.libs[]|select(.id=="agent-call")|.knobs) += [{"env":$e,"default":"0"}]' "$REG" > "$T/k1-$e.json"
  [ "$(k1_setdiff "$T/k1-$e.json" "$KD")" = "+$e" ] && ok || bad "K1 registering unlisted $e must be red, got '$(k1_setdiff "$T/k1-$e.json" "$KD" | tr '\n' ' ')'"
done
mkdir -p "$T/k1d"; cp "$KD"/*.txt "$T/k1d/" 2>/dev/null; printf 'AGENT_CALL_NOT_REGISTERED\n' > "$T/k1d/BH-0.txt"
[ "$(k1_setdiff "$REG" "$T/k1d")" = "-AGENT_CALL_NOT_REGISTERED" ] && ok || bad "K1 a listed knob that is not registered must be red, got '$(k1_setdiff "$REG" "$T/k1d" | tr '\n' ' ')'"
# And the allowlist reader refuses what it would otherwise skip.
mkdir -p "$T/k1s"; printf 'GROK_MAX_TURNS\n' > "$T/k1s/00-base.txt"; : > "$T/k1s/BH-1.txt.orig"
k1_allowlist "$T/k1s" >/dev/null 2>"$T/k1s.err" && bad "K1 a stray file in the allowlist dir must be refused" || ok
ln -s "$T/k1s/00-base.txt" "$T/k1d/BH-9.txt"
k1_allowlist "$T/k1d" >/dev/null 2>"$T/k1l.err" && bad "K1 a symlinked allowlist fragment must be refused" || ok
printf 'not an env\n' > "$T/k1s/00-base.txt"; rm -f "$T/k1s/BH-1.txt.orig"
k1_allowlist "$T/k1s" >/dev/null 2>&1 && bad "K1 a malformed allowlist line must be refused" || ok
# The cooldowns are also read by orchestrate.sh, quota-poll.sh, quota-status.sh and
# pool-account.sh, which never apply this lib: a row here would split one cooldown.
[ "$(LIB '[.knobs[].env|select(test("COOLDOWN"))]|length')" = 0 ] && ok \
  || bad "K1 a cooldown knob is registered under agent-call: $(LIB '[.knobs[].env|select(test("COOLDOWN"))]|join(" ")')"
[ "$(LIB '[.knobs[]|select(.required==true)]|length')" = 0 ] && ok || bad "K1 no agent-call knob may be required (agent-call.sh keeps its literals)"
[ "$(LIB '[.knobs[]|select(.settable==false)]|length')" = 0 ] && ok || bad "K1 every agent-call knob is settable"
# The ledger TTL is the replay window that answers a repeat prompt without a
# second metered call. A row must never be able to close that window, so its
# floor is above zero and lane_knob's clamp holds any row to it.
[ "$(LIB '.knobs[]|select(.env=="AGENT_CALL_LEDGER_TTL_S")|.min')" -gt 0 ] 2>/dev/null && ok \
  || bad "K1 AGENT_CALL_LEDGER_TTL_S min must be > 0 (a row of 0 turns the replay ledger off), got '$(LIB '.knobs[]|select(.env=="AGENT_CALL_LEDGER_TTL_S")|.min')'"
[ "$(LIB '[.knobs[].env|select(test("KEY|TOKEN|SECRET|PASSWORD|URL|HOOK|BILLING|MODEL$"))]|length')" = 0 ] && ok \
  || bad "K1 a credential-, url- or model-shaped knob is registered: $(LIB '[.knobs[].env]|join(" ")')"
# Every allowlisted AND every registered knob: its registry default is the one
# literal agent-call.sh falls back to.
REGISTERED=$(LIB '.knobs[].env' | tr '\n' ' ')
# shellcheck disable=SC2086 # word-split on purpose: the union of both lists
for e in $(printf '%s\n' $ALLOW $REGISTERED | sort -u); do
  lits=$(grep -v '^[[:space:]]*#' "$AC" | grep -oE "[{]$e:-[^}\$]*[}]" | sed -E "s/^[{]$e:-//; s/[}]$//" | sort -u)
  def=$(LIB ".knobs[]|select(.env==\"$e\")|.default|tostring")
  [ -n "$lits" ] && [ "$(wc -l <<<"$lits")" = 1 ] && [ "$lits" = "$def" ] && ok \
    || bad "K1 $e: registry default '$def' vs agent-call.sh literal(s) '$(tr '\n' ' ' <<<"$lits")'"
done

# ── K2..K5. the driven lane ──────────────────────────────────────────────────
mkdir -p "$T/.grok/bin"
cat > "$T/.grok/bin/grok" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$GROK_ARGV"
for a in "$@"; do
  if [ "$a" = json ]; then cat "$GROK_ENVELOPE"; exit 0; fi
done
echo "DECISION: BH-1636 :: skip :: fake"
EOF
chmod +x "$T/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# rows <key=value>... — a FRESH settings cache holding exactly those operator
# rows, so lane-gate reads it without asking a worker (the 60 s TTL).
rows() {
  local v='{}' kv
  for kv in "$@"; do v=$(jq -c --arg k "${kv%%=*}" --arg x "${kv#*=}" '. + {($k): $x}' <<<"$v"); done
  scratch_rm "$T/state/lane-gate"
  jq -nc --argjson fa "$(date -u +%s)" --argjson v "$v" '{fetched_at:$fa, values:$v, seeded:{}}' \
    > "$T/state/settings-cache.json"
}
drive() { # drive [ENV=VAL ...] — runs the grok triage lane, leaves $T/grok.argv
  rm -f "$T/out.txt" "$T/out.txt.envelope" "$T/grok.argv"
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY HARNESS_SECRET \
          GROK_OUTPUT_JSON GROK_MAX_TURNS LANE_GATE_DISABLE
    export HOME="$T" HARNESS="$T" PATH="$T/fakebin:$PATH" LANE_REGISTRY="$REG" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           GROK_ENVELOPE="$ENV_FIX" GROK_ARGV="$T/grok.argv" \
           RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok
    for kv in "$@"; do export "${kv?}"; done
    bash "$AC" triage testproj grok-4.6 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
}
argv() { cat "$T/grok.argv" 2>/dev/null; }

echo "--- K2. grok_output_json row"
rows lib.agent-call.grok_output_json=1
drive
grep -q -- '--output-format json' "$T/grok.argv" 2>/dev/null && ok || bad "K2 the row must turn the envelope on: argv '$(argv)'"
[ -s "$T/out.txt.envelope" ] && ok || bad "K2 the row must leave the envelope beside the answer"

echo "--- K3. grok_max_turns row"
rows lib.agent-call.grok_max_turns=7
drive
grep -q -- '--max-turns 7 ' "$T/grok.argv" 2>/dev/null && ok || bad "K3 the row must reach --max-turns: argv '$(argv)'"

echo "--- K4. no rows"
rows
drive
[ -s "$T/grok.argv" ] && ok || bad "K4 the fake grok never ran"
grep -q -- '--output-format' "$T/grok.argv" 2>/dev/null && bad "K4 with no row the lane must not ask for json: '$(argv)'" || ok
grep -q -- '--max-turns 25 ' "$T/grok.argv" 2>/dev/null && ok || bad "K4 with no row --max-turns stays 25: '$(argv)'"
drive GROK_OUTPUT_JSON=1
grep -q -- '--output-format json' "$T/grok.argv" 2>/dev/null && ok || bad "K4 env GROK_OUTPUT_JSON=1 with no row must still turn json on: '$(argv)'"

echo "--- K5. LANE_GATE_DISABLE"
rows lib.agent-call.grok_output_json=1
drive LANE_GATE_DISABLE=1
[ -s "$T/grok.argv" ] && ok || bad "K5 the fake grok never ran"
grep -q -- '--output-format' "$T/grok.argv" 2>/dev/null && bad "K5 LANE_GATE_DISABLE=1 must not apply the row: '$(argv)'" || ok

echo "agent-call-knobs.bh-1636-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
