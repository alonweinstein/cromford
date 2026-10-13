#!/bin/bash
# tests/model-cooldown-fleet.bh-2319-test.sh — agent-call and orchestrate read
# and write the FLEET cooldown rows (BH-2356, slice BH-2319.3).
#
# WHY. A cooldown this box records (fable out of credits, an account spent, the
# openrouter lane down) used to live only in this box's state/ files, so every
# other box re-bought the same refusal before it learned the same thing. The
# contract bin/lib/fleet-cooldown.sh (BH-2352) is the shared record; this slice
# wires the call sites to it:
#   writers  ladder_recover's two account stamps  -> fcd_put account <runner> <acct>
#            the fable "usage credits" stamp       -> fcd_put model claude <model>[/<acct>]
#   readers  agent-call's model cooldown            file in window OR fcd_live model
#            openrouter_lane_down                   + fcd_live lane openrouter <self>
#            orchestrate's orc_model_ladder         file in window OR fcd_live model
# The fleet row is an OR on top of the local file. rc 2 (unknown: no store, the
# worker stub, FLEET_COOLDOWN_DB=0, a box without the lib) is never "hot".
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with fake CLIs; openrouter_lane_down and the `# >>> claude ladder` block are
# lifted verbatim from the shipped scripts. Rows are seeded with the real
# fcd_put against FLEET_COOLDOWN_STORE="$T/fleet.tsv".
#
#   AT1  a fleet model row sends the first claude attempt to the fallback rung
#   AT2  a row for another account / unsuffixed / another model / expired does not
#   AT3  fable out of credits puts model claude <model>[/<acct>]
#   AT4  an account refusal puts account <runner> <acct> (full, overage, codex)
#   AT5  a fleet lane row marks openrouter down; other lanes/boxes do not
#   AT6  unknown (no store, DB=0, no lib) behaves exactly as before
#   AT7  mutation: each reader/writer/source line, neutralised, turns a case red
#   AT8  the forbidden paths are not in this branch's diff
#
# Run from anywhere: tests/model-cooldown-fleet.bh-2319-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FABLE=claude-fable-5-1
STORE="$T/fleet.tsv"

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d" \
         "$T/.claude-a" "$T/.claude-b" "$T/.codex-d" "$T/.codex"
echo '{}' > "$T/.codex/auth.json"

# ---------- fakes ------------------------------------------------------------
# claude records "claude|<config dir>|<model>". Fable answers "out of usage
# credits" when FABLE_CREDITS=1; a config dir listed in $QUOTA_LIST answers the
# weekly limit; CLAUDE_MODE=real is an ordinary agent failure.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --resume <sessionId>\n  --session-id <uuid>\n'; exit 0 ;; esac
m=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && m="$a"; prev="$a"; done
printf 'claude|%s|%s\n' "${CLAUDE_CONFIG_DIR:-default}" "$m" >> "$ORDER_SINK"
if [ -n "${QUOTA_LIST:-}" ] && grep -qxF "${CLAUDE_CONFIG_DIR:-default}" "$QUOTA_LIST" 2>/dev/null; then
  echo "Claude AI: you have hit your weekly limit" >&2; exit 1
fi
case "$m" in claude-fable-*) [ "${FABLE_CREDITS:-0}" = 1 ] && { echo "Claude AI: out of usage credits for this model" >&2; exit 1; } ;; esac
[ "${CLAUDE_MODE:-ok}" = real ] && { printf '{"result":"could not do it","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1; }
printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do
  case "$arg" in *model_provider*openrouter*) provider=openrouter ;; *model_provider*fireworks*) provider=fireworks ;; esac
done
printf '%s|%s|-\n' "$provider" "${CODEX_HOME:-NONE}" >> "$ORDER_SINK"
[ "$provider" = codex ] || { echo "$provider: upstream refused" >&2; exit 1; }
[ -n "${CODEX_STDERR:-}" ] && echo "$CODEX_STDERR" >&2
exit "${CODEX_RC:-0}"
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo 'grok|-|-' >> "$ORDER_SINK"
[ "${GROK_FAIL:-0}" = 1 ] && { echo "grok is not configured" >&2; exit 1; }
echo "grok answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/codex-usage.sh"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.real.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/empty-catalog.json"
# The picker: the real one, except --overage-ok answers PICK_OVERAGE_OK (rc)
# when that is set — the one billing question agent-call execs it for.
cat > "$T/bin/account-pick.sh" <<EOF
#!/bin/bash
if [ "\${1:-}" = --overage-ok ] && [ -n "\${PICK_OVERAGE_OK:-}" ]; then exit "\$PICK_OVERAGE_OK"; fi
exec bash "$T/bin/account-pick.real.sh" "\$@"
EOF
chmod +x "$T/bin/account-pick.sh"

# ---------- fixtures ---------------------------------------------------------
reg() { cat > "$T/env/accounts.d/$1.env"; chmod 600 "$T/env/accounts.d/$1.env"; }
accounts() { # accounts <names...>: a (claude), b (claude), d (codex)
  rm -f "$T/env/accounts.d"/*.env
  local n
  for n in "$@"; do
    case "$n" in
      a|b) printf 'ACCOUNT_NAME=%s\nACCOUNT_VENDOR=claude\nACCOUNT_PRIORITY=%s\nCLAUDE_CONFIG_DIR=%s\n' \
             "$n" "$([ "$n" = a ] && echo 10 || echo 20)" "$T/.claude-$n" | reg "$n" ;;
      d) printf 'ACCOUNT_NAME=d\nACCOUNT_VENDOR=codex\nCODEX_HOME=%s\n' "$T/.codex-d" | reg d ;;
    esac
  done
}
reset() {
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  rm -rf "$T/state/quota" "$T/state/lane-down" "$T/state/openrouter-headroom"
  rm -f "$T/state/model-cooldown-"* "$T/state/claude-auth-down.txt" "$STORE" "$STORE.lock" "$T/err.txt"
}
# seed <kind> <vendor> <subject> <until-offset-secs> — the real contract writer
seed() {
  ( . "$DIR/bin/lib/fleet-cooldown.sh"
    FLEET_COOLDOWN_STORE="$STORE" fcd_put "$1" "$2" "$3" "$(( $(date +%s) + $4 ))" "$(date +%s)" test-seed )
}
fleet_list() { ( . "$DIR/bin/lib/fleet-cooldown.sh"; FLEET_COOLDOWN_STORE="$STORE" fcd_list "$1" ); }

AC="$DIR/bin/agent-call.sh"
# run_call <model> <env...> — the REAL bin/agent-call.sh ($AC). stderr kept in
# $T/err.txt. No reset here: a case seeds rows first.
run_call() {
  local model="$1"; shift
  : > "$T/order"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           LADDER_TIER2_GROK=1 RUNNER_EVAL=claude \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" \
           AUTH_ACCOUNTS_LOCAL="$T/state/auth-accounts.local.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CODEX_API_KEY \
      -u FLEET_COOLDOWN_STORE -u FLEET_COOLDOWN_DB -u MODEL_COOLDOWN_SECS -u ACCOUNT_COOLDOWN_SECS \
      -u ACCOUNT_OVERAGE_COOLDOWN_SECS -u LANE_DOWN_SELF \
      "$@" bash "$AC" eval testproj "$model" 60 "$T/out.txt" "hello" >/dev/null 2>"$T/err.txt" )
  echo $?
}
first_model() { sed -n '1{s/^claude|[^|]*|//;p}' "$T/order"; }
nocnf() { grep -q 'command not found' "$T/err.txt" 2>/dev/null && bad "$1: stderr has 'command not found': $(grep 'command not found' "$T/err.txt" | head -2)" || ok; }

# at1_agent [env...]: the AT1 inputs through $AC — a fleet row for <fable>/a,
# no local stamp, account a. Echoes the first model claude was asked for.
at1_agent() {
  reset; accounts a
  seed model claude "$FABLE/a" 600
  run_call "$FABLE" ACCOUNT_ROUTING=1 "$@" >/dev/null
  first_model
}

# =============================================================================
# AT1-agent / AT2-agent — the model reader (bin/agent-call.sh)
# =============================================================================
M=$(at1_agent FLEET_COOLDOWN_STORE="$STORE")
case "$M" in claude-opus-*) ok ;; *) bad "AT1-agent: a live fleet row for $FABLE/a must start on the opus rung, first model was '$M' ($(paste -sd, "$T/order"))" ;; esac
[ ! -e "$T/state/model-cooldown-$FABLE-a" ] && ok || bad "AT1-agent: reading a fleet row must not write the local stamp"

for sub in "$FABLE/b" "$FABLE" "claude-fable-9-9/a"; do
  reset; accounts a
  seed model claude "$sub" 600
  run_call "$FABLE" ACCOUNT_ROUTING=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
  [ "$(first_model)" = "$FABLE" ] && ok || bad "AT2-agent: a row for '$sub' with account a must leave fable first, got '$(first_model)'"
done
reset; accounts a
seed model claude "$FABLE/a" -1
run_call "$FABLE" ACCOUNT_ROUTING=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ "$(first_model)" = "$FABLE" ] && ok || bad "AT2-agent: an expired row must leave fable first, got '$(first_model)'"
# Routing off: no account, so the key is the bare model — an unsuffixed row hits.
reset; accounts a
seed model claude "$FABLE" 600
run_call "$FABLE" FLEET_COOLDOWN_STORE="$STORE" >/dev/null
case "$(first_model)" in claude-opus-*) ok ;; *) bad "AT1-agent: routing off, an unsuffixed row must start on opus, got '$(first_model)'" ;; esac

# =============================================================================
# AT3 — the model writer: fable out of usage credits
# =============================================================================
reset; accounts a
T0=$(date +%s)
run_call "$FABLE" ACCOUNT_ROUTING=1 FABLE_CREDITS=1 MODEL_COOLDOWN_SECS=3600 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
T1=$(date +%s)
[ -f "$T/state/model-cooldown-$FABLE-a" ] && ok || bad "AT3a: the local stamp must still be written"
ROW=$(fleet_list model | awk -F'\t' -v s="$FABLE/a" '$1=="claude" && $2==s')
U=$(cut -f3 <<<"$ROW")
[ -n "$ROW" ] && [ "$U" -ge $((T0 + 3600)) ] && [ "$U" -le $((T1 + 3605)) ] \
  && ok || bad "AT3a: expected a model row claude/$FABLE/a until now+3600, list: $(fleet_list model | tr '\t\n' ' ;')"
[ "$(fleet_list model | grep -c '')" = 1 ] && ok || bad "AT3a: exactly one model row expected: $(fleet_list model | tr '\t\n' ' ;')"

reset; accounts a
run_call "$FABLE" FABLE_CREDITS=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ "$(fleet_list model | cut -f1,2)" = "claude	$FABLE" ] \
  && ok || bad "AT3b: routing off must put the unsuffixed model, list: $(fleet_list model | tr '\t\n' ' ;')"
# `default` is no suffix: routing on, no claude account registered, the box's
# own credentials are the implicit default account.
reset; accounts d
run_call "$FABLE" ACCOUNT_ROUTING=1 FABLE_CREDITS=1 CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-default \
  FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ "$(fleet_list model | cut -f1,2)" = "claude	$FABLE" ] \
  && ok || bad "AT3b: account default must put the unsuffixed model, list: $(fleet_list model | tr '\t\n' ' ;') order: $(paste -sd, "$T/order")"

# =============================================================================
# AT4 — the account writer (ladder_recover, both branches, and the vendor)
# =============================================================================
at4a() { # at4a [env...] — claude account a spends its week, full branch
  reset; accounts a
  printf '%s\n' "$T/.claude-a" > "$T/quota"
  T0=$(date +%s)
  run_call claude-opus-5 ACCOUNT_ROUTING=1 QUOTA_LIST="$T/quota" PICK_OVERAGE_OK=1 \
    ACCOUNT_COOLDOWN_SECS=7200 FLEET_COOLDOWN_STORE="$STORE" "$@" >/dev/null
  T1=$(date +%s)
}
at4a
[ -f "$T/state/quota/cooldown/claude/a" ] && ok || bad "AT4a: the local account stamp must still be written ($(paste -sd, "$T/order"))"
ROW=$(fleet_list account | awk -F'\t' '$1=="claude" && $2=="a"')
U=$(cut -f3 <<<"$ROW")
[ -n "$ROW" ] && [ "$U" -ge $((T0 + 7200)) ] && [ "$U" -le $((T1 + 7205)) ] \
  && ok || bad "AT4a: expected account claude/a until now+7200, list: $(fleet_list account | tr '\t\n' ' ;')"
grep -q 'account-exhausted' <<<"$ROW" && ok || bad "AT4a: the row's reason must name the class: $ROW"

reset; accounts a
printf '%s\n' "$T/.claude-a" > "$T/quota"
T0=$(date +%s)
run_call claude-opus-5 ACCOUNT_ROUTING=1 QUOTA_LIST="$T/quota" PICK_OVERAGE_OK=0 \
  ACCOUNT_OVERAGE_COOLDOWN_SECS=900 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
T1=$(date +%s)
ROW=$(fleet_list account | awk -F'\t' '$1=="claude" && $2=="a"')
U=$(cut -f3 <<<"$ROW")
[ -n "$ROW" ] && [ "$U" -ge $((T0 + 900)) ] && [ "$U" -le $((T1 + 905)) ] \
  && ok || bad "AT4b: an overage account must put until now+900, list: $(fleet_list account | tr '\t\n' ' ;') ($(grep -c 'short cooldown' "$T/logs/failovers.log") short-cooldown notes)"
grep -q 'overage' <<<"$ROW" && ok || bad "AT4b: the overage row's reason must say overage: $ROW"

reset; accounts a d
run_call "$FABLE" RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
  CODEX_STDERR="stream error: usage limit reached" FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ "$(fleet_list account | cut -f1,2 | grep -c '^codex	d$')" = 1 ] \
  && ok || bad "AT4c: a codex refusal must put account codex/d, list: $(fleet_list account | tr '\t\n' ' ;') order: $(paste -sd, "$T/order")"
[ "$(fleet_list account | grep -c '^claude	')" = 0 ] \
  && ok || bad "AT4c: a codex refusal wrote a claude row: $(fleet_list account | tr '\t\n' ' ;')"
# A real failure is not an account's fault: no row at all.
reset; accounts a
run_call claude-opus-5 ACCOUNT_ROUTING=1 CLAUDE_MODE=real FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ -z "$(fleet_list account)" ] && ok || bad "AT4: a real failure put an account row: $(fleet_list account | tr '\t\n' ' ;')"

# =============================================================================
# AT5 — openrouter_lane_down, lifted verbatim, plus a real agent-call run
# =============================================================================
lift_or() { awk '/^openrouter_lane_down\(\) \{/,/^}/' "$1" > "$T/or.sh"; }
lift_or "$AC"
grep -q 'openrouter_lane_down' "$T/or.sh" && ok || bad "AT5: could not lift openrouter_lane_down from bin/agent-call.sh"
# or_down [env...]: rc of the lifted function against $T with the real lib.
or_down() {
  env -u OPENROUTER_API_KEY -u LANE_DOWN_SELF -u FLEET_COOLDOWN_DB -u FLEET_COOLDOWN_STORE \
    HARNESS="$T" "$@" bash -c '. "$1"; . "$2"; openrouter_lane_down' _ "$DIR/bin/lib/fleet-cooldown.sh" "$T/or.sh" 2>/dev/null
  echo $?
}
reset; seed lane openrouter hub 600
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE")" = 0 ] && ok || bad "AT5a: a lane openrouter/hub row with no state/lane-down/ must read DOWN"
[ ! -e "$T/state/lane-down" ] && ok || bad "AT5a: fixture: state/lane-down/ must not exist"
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE" LANE_DOWN_SELF=boxz)" = 1 ] && ok || bad "AT5: a hub row must not mark LANE_DOWN_SELF=boxz down"
reset; seed lane codex hub 600
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE")" = 1 ] && ok || bad "AT5b: a lane codex/hub row must not mark openrouter down"
reset; seed lane openrouter boxz 600
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE")" = 1 ] && ok || bad "AT5b: a row for another box must not mark the hub's openrouter down"
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE" LANE_DOWN_SELF=boxz)" = 0 ] && ok || bad "AT5: LANE_DOWN_SELF=boxz must read its own row"
reset; seed lane openrouter hub -1
[ "$(or_down FLEET_COOLDOWN_STORE="$STORE")" = 1 ] && ok || bad "AT5b: an expired lane row must not mark openrouter down"

# The production path: claude fails for real, openrouter is the floor the
# survival block would buy (OPENROUTER_FALLBACK=always, the exhausted-lane shape).
ran_or() { grep -c '^openrouter|' "$T/order" 2>/dev/null || true; }
at5_agent() { # at5_agent [env...] — echoes how many openrouter attempts ran
  reset; accounts
  seed lane openrouter hub 600
  run_call claude-opus-5 CLAUDE_MODE=real GROK_FAIL=1 OPENROUTER_API_KEY=x CODEX_API_KEY=x OPENROUTER_FALLBACK=always "$@" >/dev/null
  ran_or
}
[ "$(at5_agent FLEET_COOLDOWN_STORE="$STORE")" = 0 ] && ok || bad "AT5a: a hub-recorded openrouter outage was still bought ($(paste -sd, "$T/order"))"
[ "$(at5_agent)" -ge 1 ] && ok || bad "AT5 fixture: with no store the openrouter lane must be bought ($(paste -sd, "$T/order"))"

# =============================================================================
# AT6 — unknown is exactly today
# =============================================================================
M=$(at1_agent)
[ "$M" = "$FABLE" ] && ok || bad "AT6a: store unset (worker stub, rc 2) must leave fable first, got '$M'"
[ "$(grep -c '' < "$STORE")" = 1 ] && ok || bad "AT6a: a run with no store configured wrote to $STORE: $(tr '\t\n' ' ;' < "$STORE")"
nocnf AT6a
M=$(at1_agent FLEET_COOLDOWN_STORE="$STORE" FLEET_COOLDOWN_DB=0)
[ "$M" = "$FABLE" ] && ok || bad "AT6a: FLEET_COOLDOWN_DB=0 must leave fable first, got '$M'"
[ "$(at5_agent FLEET_COOLDOWN_STORE="$STORE" FLEET_COOLDOWN_DB=0)" -ge 1 ] && ok || bad "AT6a: FLEET_COOLDOWN_DB=0 must not read openrouter down"
reset; accounts a
run_call "$FABLE" ACCOUNT_ROUTING=1 FABLE_CREDITS=1 >/dev/null
[ ! -e "$STORE" ] && [ -f "$T/state/model-cooldown-$FABLE-a" ] && ok || bad "AT6a: no store: the put must be a no-op and the local stamp still written"
# The local file alone still works with the fleet in play (the OR's other arm).
reset; accounts a
date +%s > "$T/state/model-cooldown-$FABLE-a"  # determinism: ok a stamp of now is inside the 6h window on any day
run_call "$FABLE" ACCOUNT_ROUTING=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
case "$(first_model)" in claude-opus-*) ok ;; *) bad "AT6: the local stamp alone must still start on opus, got '$(first_model)'" ;; esac

# AT6b: a box whose sync has not landed the lib. agent-call's sibling lib/ is
# every file but fleet-cooldown.sh, and $HARNESS/bin/lib has none either.
mkdir -p "$T/nolib/bin/lib"
for f in "$DIR"/bin/lib/*; do
  [ "$(basename "$f")" = fleet-cooldown.sh ] || ln -s "$f" "$T/nolib/bin/lib/"
done
cp "$DIR/bin/agent-call.sh" "$T/nolib/bin/agent-call.sh"
[ ! -e "$T/bin/lib/fleet-cooldown.sh" ] && ok || bad "AT6b fixture: \$HARNESS/bin/lib must not carry the lib"
AC="$T/nolib/bin/agent-call.sh"
M=$(at1_agent FLEET_COOLDOWN_STORE="$STORE")
[ "$M" = "$FABLE" ] && ok || bad "AT6b: no lib reachable must leave fable first, got '$M'"
nocnf AT6b-reader
reset; accounts a
run_call "$FABLE" ACCOUNT_ROUTING=1 FABLE_CREDITS=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
[ -f "$T/state/model-cooldown-$FABLE-a" ] && ok || bad "AT6b: no lib: the local stamp must still be written"
nocnf AT6b-writer
AC="$DIR/bin/agent-call.sh"

# =============================================================================
# AT1-orc / AT2-orc / AT6c — orc_model_ladder, the lifted `# >>> claude ladder`
# =============================================================================
lift_orc() { sed -n '/^# >>> claude ladder/,/^# <<< claude ladder/p' "$1" > "$T/ladder.sh"; }
lift_orc "$DIR/bin/orchestrate.sh"
grep -q 'orc_model_ladder()' "$T/ladder.sh" && ok || bad "AT1-orc: could not lift the claude ladder block"
# The driver runs the block the way orchestrate.sh does; run_turn records the
# model and serves, so the ladder stops on the first model it tries.
cat > "$T/drive-orc.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
note() { echo "$1" >> "$HARNESS/logs/orc-notes.log"; }
orc_fail_class() { :; }; orc_fail_keep() { :; }
run_turn() { echo "$1" >> "$TURNS"; RC=0; OUT="served"; }
RC=0; OUT=""; SERVED_BY=""
. "$BLOCK"
DRIVE
mkdir -p "$T/orc/h/bin/lib" "$T/orc/h/logs" "$T/orc/h/state" "$T/orc/o"
cp "$DIR/bin/lib/fleet-cooldown.sh" "$T/orc/h/bin/lib/fleet-cooldown.sh"
# orc [env...] — echoes the first model the turn ran
orc() {
  : > "$T/orc/turns"; rm -f "$T/orc/h/state/model-cooldown-"*
  env -u FLEET_COOLDOWN_STORE -u FLEET_COOLDOWN_DB -u MODEL_COOLDOWN_SECS \
    HARNESS="$T/orc/h" ORC="$T/orc/o" TURNS="$T/orc/turns" BLOCK="$T/ladder.sh" \
    ORC_MODEL="$FABLE" ORC_FALLBACK=claude-opus-5-5 ORC_ACCOUNT=a ORC_SURVIVAL="" TEXT=hi \
    "$@" bash "$T/drive-orc.sh" >/dev/null 2>"$T/err.txt"
  head -1 "$T/orc/turns"
}
reset; seed model claude "$FABLE/a" 600
M=$(orc FLEET_COOLDOWN_STORE="$STORE")
[ "$M" = claude-opus-5-5 ] && [ "$(grep -c '' < "$T/orc/turns")" = 1 ] \
  && ok || bad "AT1-orc: a live row for $FABLE/a must run ONLY the fallback, ran: $(paste -sd, "$T/orc/turns")"
nocnf AT1-orc
for sub in "$FABLE/b" "$FABLE" "claude-fable-9-9/a"; do
  reset; seed model claude "$sub" 600
  [ "$(orc FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && ok || bad "AT2-orc: a row for '$sub' with account a must leave fable first, ran: $(paste -sd, "$T/orc/turns")"
done
reset; seed model claude "$FABLE/a" -1
[ "$(orc FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && ok || bad "AT2-orc: an expired row must leave fable first"
reset; seed model claude "$FABLE" 600
[ "$(orc FLEET_COOLDOWN_STORE="$STORE" ORC_ACCOUNT=default)" = claude-opus-5-5 ] \
  && ok || bad "AT1-orc: account default reads the unsuffixed row, ran: $(paste -sd, "$T/orc/turns")"
reset; seed model claude "$FABLE/a" 600
[ "$(orc)" = "$FABLE" ] && ok || bad "AT6a-orc: store unset must leave fable first"
[ "$(orc FLEET_COOLDOWN_STORE="$STORE" FLEET_COOLDOWN_DB=0)" = "$FABLE" ] && ok || bad "AT6a-orc: FLEET_COOLDOWN_DB=0 must leave fable first"
mv "$T/orc/h/bin/lib/fleet-cooldown.sh" "$T/orc/fcd.bak"
[ "$(orc FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && ok || bad "AT6c: no lib under \$HARNESS must leave fable first"
nocnf AT6c
mv "$T/orc/fcd.bak" "$T/orc/h/bin/lib/fleet-cooldown.sh"

# =============================================================================
# AT7 — mutation: neutralise each site once, the owning case must go red
# =============================================================================
# mutant <src> <sed-expr> <dest>: rc 1 (and a FAIL) when the expression changed nothing.
mutant() {
  sed "$2" "$1" > "$3"
  if cmp -s "$1" "$3"; then bad "AT7: '$2' matched nothing in $(basename "$1") — the site it pins is gone"; return 1; fi
  return 0
}
mkdir -p "$T/mut/bin"; ln -sfn "$DIR/bin/lib" "$T/mut/bin/lib"
red() { echo "MUTATION $1 -> $2 red"; ok; }

AC="$T/mut/bin/agent-call.sh"
if mutant "$DIR/bin/agent-call.sh" 's/fcd_live model claude/false/' "$AC"; then
  [ "$(at1_agent FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && red agent-call-model-reader AT1-agent \
    || bad "AT7: agent-call's model reader neutralised and AT1-agent stayed green"
fi
if mutant "$DIR/bin/agent-call.sh" 's#lib/fleet-cooldown\.sh#lib/fleet-cooldown.sh.MUTANT#g' "$AC"; then
  [ "$(at1_agent FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && red agent-call-source-line AT1-agent \
    || bad "AT7: agent-call's source line neutralised and AT1-agent stayed green"
fi
if mutant "$DIR/bin/agent-call.sh" 's/fcd_live lane openrouter/false/' "$AC"; then
  lift_or "$AC"; reset; seed lane openrouter hub 600
  [ "$(or_down FLEET_COOLDOWN_STORE="$STORE")" = 1 ] && red agent-call-lane-reader AT5a \
    || bad "AT7: openrouter_lane_down's fleet reading neutralised and AT5a stayed green"
  [ "$(at5_agent FLEET_COOLDOWN_STORE="$STORE")" -ge 1 ] && red agent-call-lane-reader AT5a-agent \
    || bad "AT7: openrouter_lane_down's fleet reading neutralised and the agent-call run still skipped openrouter"
  lift_or "$DIR/bin/agent-call.sh"
fi
if mutant "$DIR/bin/agent-call.sh" 's/fcd_put model claude/true/' "$AC"; then
  reset; accounts a
  run_call "$FABLE" ACCOUNT_ROUTING=1 FABLE_CREDITS=1 FLEET_COOLDOWN_STORE="$STORE" >/dev/null
  [ -z "$(fleet_list model)" ] && red agent-call-model-writer AT3a \
    || bad "AT7: the model writer neutralised and a model row was still put"
fi
if mutant "$DIR/bin/agent-call.sh" 's/fcd_put account/true/' "$AC"; then
  at4a FLEET_COOLDOWN_STORE="$STORE"
  [ -z "$(fleet_list account)" ] && red agent-call-account-writer AT4a \
    || bad "AT7: the account writers neutralised and an account row was still put"
fi
AC="$DIR/bin/agent-call.sh"
if mutant "$DIR/bin/orchestrate.sh" 's/fcd_live model claude/false/' "$T/mut/orchestrate.sh"; then
  lift_orc "$T/mut/orchestrate.sh"; reset; seed model claude "$FABLE/a" 600
  [ "$(orc FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && red orchestrate-model-reader AT1-orc \
    || bad "AT7: orc_model_ladder's fleet reading neutralised and AT1-orc stayed green"
fi
if mutant "$DIR/bin/orchestrate.sh" 's#bin/lib/fleet-cooldown\.sh#bin/lib/fleet-cooldown.sh.MUTANT#g' "$T/mut/orchestrate.sh"; then
  lift_orc "$T/mut/orchestrate.sh"; reset; seed model claude "$FABLE/a" 600
  [ "$(orc FLEET_COOLDOWN_STORE="$STORE")" = "$FABLE" ] && red orchestrate-source-line AT1-orc \
    || bad "AT7: orchestrate's source line neutralised and AT1-orc stayed green"
fi
lift_orc "$DIR/bin/orchestrate.sh"

# =============================================================================
# AT8 — the paths the ticket leaves to other slices are not in this diff
# =============================================================================
if BASE=$(git -C "$DIR" merge-base origin/main HEAD 2>/dev/null) && [ -n "$BASE" ]; then
  CHANGED=$(git -C "$DIR" diff --name-only "$BASE" 2>/dev/null)
  # Inert on any branch that is not this slice: after merge, a later ticket may
  # own those paths, and this arm must not go red on its PR.
  if ! grep -qxF 'tests/model-cooldown-fleet.bh-2319-test.sh' <<<"$CHANGED"; then  # own-slice: tests/model-cooldown-fleet.bh-2319-test.sh
    echo "note: this branch is not BH-2356's slice — AT8 is inert here"
  else
    HIT=$(grep -E '^(bin/account-pick\.sh|bin/lib/lane-down\.sh|bin/claude-auth-check\.sh|bin/lane-reprobe\.sh|bin/lib/fleet-cooldown\.sh|worker/|docs/verification-map/)' <<<"$CHANGED")
    [ -z "$HIT" ] && ok || bad "AT8: this branch touches paths the ticket forbids: $(tr '\n' ' ' <<<"$HIT")"
  fi
else
  echo "SKIP AT8: no origin/main in this checkout, the diff cannot be read"
fi

echo "model-cooldown-fleet.bh-2319: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
