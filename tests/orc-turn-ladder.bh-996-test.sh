#!/bin/bash
# tests/orc-turn-ladder.bh-996-test.sh — the orchestrator turn ladder is more
# than one account deep, and the survival banner states the MEASURED refusal.
#
# WHAT THIS PINS (BH-996). Before this, a turn picked ONE account, ran fable
# then opus on it, and the moment both failed it crossed to codex under the
# banner "Claude is out of credits" — a sentence nobody had measured. Three
# properties now hold:
#   1. an account-class refusal cools the account down (the same stamp
#      agent-call.sh writes), re-picks, and only falls to survival once the
#      orchestrator.env default token has ALSO refused;
#   2. the banner and the survival brief carry the account, the class and
#      whether the default token was tried — "out of credits" renders only for
#      a credits/spend-cap refusal;
#   3. a refused account's pin is cleared, and the retry inside the same turn
#      never re-runs the refused account.
#
# Every ladder scenario runs the block lifted VERBATIM from bin/orchestrate.sh
# (`# >>> claude ladder`) with the REAL run_turn(), the REAL survival lanes
# block and the REAL bin/lib/orc-account.sh, against a fake claude CLI, a fake
# codex and a fake account-pick.sh. A copy of the logic here could agree with
# itself while the shipped turn did something else.
#
# Run from anywhere: tests/orc-turn-ladder.bh-996-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/orchestrate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }

# ---------------------------------------------------------------------------
# 0. Lifts — the production blocks this suite drives
# ---------------------------------------------------------------------------
sed -n '/^# >>> claude ladder/,/^# <<< claude ladder/p'   "$SRC" > "$T/ladder.sh"
sed -n '/^# >>> survival lanes/,/^# <<< survival lanes/p' "$SRC" > "$T/survival.sh"
awk '/^run_turn\(\) \{/,/^}/' "$SRC" > "$T/runturn.sh"
grep -q 'orc_fail_class' "$T/ladder.sh"   && ok || bad "the claude-ladder lift is empty or stale (no orc_fail_class — # >>> claude ladder markers missing?)"
grep -q 'CANDIDATES=(' "$T/ladder.sh"     && ok || bad "the claude-ladder lift must carry the model candidates"
grep -q 'run_survival()' "$T/survival.sh" && ok || bad "the survival-lanes lift is empty or stale (no run_survival — # >>> survival lanes markers missing?)"
grep -q 'ORC_TOKEN' "$T/runturn.sh"       && ok || bad "run_turn() lift is empty or stale (no ORC_TOKEN plumbing)"

# ---------------------------------------------------------------------------
# 1. Classifier table — bin/lib/orc-account.sh, sourced for real
# ---------------------------------------------------------------------------
export HARNESS="$T/h"; mkdir -p "$HARNESS/state/quota/cooldown/claude" "$HARNESS/state/quota/pins"
. "$DIR/bin/lib/orc-account.sh" || bad "could not source bin/lib/orc-account.sh"

cls() { # cls <label> <rc> <text> <class> <detail> [phrase]
  local lbl="$1" rc="$2" txt="$3" c="$4" d="$5" p="${6:-}"
  orc_fail_class "$rc" "$txt" 2>/dev/null
  eq "$lbl class"  "${ORC_FAIL_CLASS:-}"  "$c"
  eq "$lbl detail" "${ORC_FAIL_DETAIL:-}" "$d"
  [ -n "$p" ] && eq "$lbl phrase" "$(orc_fail_phrase 2>/dev/null)" "$p"
  return 0
}
# rc 0 is a SERVED turn even when the reply talks about limits.
cls "rc0-mentions-limit" 0 "we are close to the session limit on max7" ok "" ""
cls "session-limit"      1 "You've reached your session limit for this account" account-exhausted quota "session limit"
cls "usage-credits"      1 "You are out of usage credits, switch to another model" account-exhausted credits "out of credits"
cls "credit-balance"     1 "Credit balance is too low to continue" account-exhausted credits "out of credits"
cls "auth"               1 "invalid setup-token, please re-login" auth credential "auth error: setup-token"
cls "429"                1 "429 too many requests" transient vendor "transient vendor error: 429"
cls "529"                1 "529 overloaded, please retry" transient vendor "transient vendor error: 529"
cls "real-failure"       1 "No conversation found to continue" real-failure agent "rc=1, unclassified failure"
cls "timeout-124"      124 "" transient timeout "timed out"
cls "killed-137"       137 "" transient timeout "timed out"
# The credits phrase comes from the credits branch and nowhere else.
orc_fail_class 1 "You've reached your session limit" 2>/dev/null
hasnt "quota phrase" "$(orc_fail_phrase 2>/dev/null)" "out of credits"

# The three class knobs must stay byte-identical to agent-call.sh's (this file
# duplicates them on purpose — BH-996 forbids touching agent-call.sh — so drift
# between the turn ladder and the build ladders is what has to fail loudly).
for k in LADDER_EXHAUST_REGEX LADDER_TRANSIENT_REGEX LADDER_AUTH_REGEX; do
  a=$(grep -m1 "^$k=" "$DIR/bin/agent-call.sh")
  b=$(grep -m1 "^$k=" "$DIR/bin/lib/orc-account.sh")
  [ -n "$a" ] && [ "$a" = "$b" ] && ok || bad "$k drifted from bin/agent-call.sh
  agent-call: $a
  orc-account: $b"
done

# ---------------------------------------------------------------------------
# 2. orc_account_refuse — the cooldown stamp and the pin
# ---------------------------------------------------------------------------
printf 'max7\n' > "$HARNESS/state/quota/pins/orchestrator"
orc_account_refuse max7 2>/dev/null
# THE PATH IS THE FEATURE: bin/account-pick.sh reads cooldown/<vendor>/<account>
# and sweeps a bare cooldown/<account> to .legacy/ without reading it (BH-940),
# so the pre-BH-940 path is a stamp that cools nothing.
CD="$HARNESS/state/quota/cooldown/claude/max7"
[ -s "$CD" ] && ok || bad "orc_account_refuse must stamp state/quota/cooldown/claude/<account> (the path bin/account-pick.sh reads)"
[ -e "$HARNESS/state/quota/cooldown/max7" ] && bad "orc_account_refuse must NOT write the legacy unscoped cooldown/<account> — account-pick.sh sweeps it to .legacy/ and never reads it" || ok
case "$(cat "$CD" 2>/dev/null)" in ''|*[!0-9]*) bad "the cooldown stamp must be a bare epoch (got '$(cat "$CD" 2>/dev/null)')" ;; *) ok ;; esac
[ -e "$HARNESS/state/quota/pins/orchestrator" ] && bad "a refusal must clear state/quota/pins/orchestrator" || ok
# default is never stamped and never pins: the picker fails open to it anyway.
printf 'max7\n' > "$HARNESS/state/quota/pins/orchestrator"
orc_account_refuse default 2>/dev/null
[ -e "$HARNESS/state/quota/cooldown/claude/default" ] && bad "default must never be cooled down" || ok
[ -e "$HARNESS/state/quota/pins/orchestrator" ] && ok || bad "refusing 'default' must not touch the pin"
# Pin key sanitiser, same rule as account-pick.sh:_acct_pin_key
printf 'max3\n' > "$HARNESS/state/quota/pins/orc_x_y"
ORC_ACCOUNT_PIN='orc/x y' orc_account_refuse max3 2>/dev/null
[ -e "$HARNESS/state/quota/pins/orc_x_y" ] && bad "pin key must be sanitised the way _acct_pin_key sanitises it (orc/x y -> orc_x_y)" || ok

# ---------------------------------------------------------------------------
# Harness for the ladder scenarios
# ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/home/.codex"
printf '{"fake":true}\n' > "$T/home/.codex/auth.json"

# fake claude: answers on whatever token run_turn handed it, refuses for the
# tokens listed in $REFUSE ("token<TAB>message"), and logs "<token>|<model>".
cat > "$T/bin/claude" <<'CLAUDE'
#!/bin/bash
model=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && model="$a"; prev="$a"; done
tok="${CLAUDE_CODE_OAUTH_TOKEN:-none}"
echo "$tok|$model" >> "$CALLS"
# "<token>|<model>" wins over the bare "<token>" line, so a scenario can make
# one account refuse DIFFERENTLY per model (fable quota, opus 529).
msg=$(grep -P "^\Q$tok|$model\E\t" "$REFUSE" 2>/dev/null | head -1 | cut -f2-)
[ -n "$msg" ] || msg=$(grep -P "^\Q$tok\E\t" "$REFUSE" 2>/dev/null | head -1 | cut -f2-)
if [ -n "$msg" ]; then echo "$msg"; exit "${REFUSE_RC:-1}"; fi
echo "served on $tok"
CLAUDE
chmod +x "$T/bin/claude"

# fake codex on PATH: survival_ready needs a codex it can see. Since BH-2307 the
# survival lane must NEVER run it directly (no cost row, no gate); a direct call
# lands in $CODEXDIRECT and the scenarios assert that file stays empty.
cat > "$T/bin/codex" <<'CODEX'
#!/bin/bash
echo "direct $*" >> "$CODEXDIRECT"
exit 1
CODEX
chmod +x "$T/bin/codex"

# fake agent-call.sh: the survival lane's ONLY way to a vendor (BH-2307). It
# records its argv and the routing env, and answers as codex when the caller
# pinned the codex runner. Installed per scenario (scen wipes $T/h).
cat > "$T/fake-agent-call.sh" <<'AC'
#!/bin/bash
stage="$1" project="$2" to="$4" out="$5" prompt="$6"
su=$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]_' '_')
rv="RUNNER_$su"; runner="${!rv:-}"
printf '%s|%s|%s|%s|%s|%s\n' "$stage" "$project" "$runner" "${AGENT_CALL_RUNNERS:-}" "${AGENT_CALL_LANE:-}" "$to" >> "$ACCALLS"
case "$prompt" in @*) cat "${prompt#@}" > "$CODEXPROMPT" ;; *) printf '%s\n' "$prompt" > "$CODEXPROMPT" ;; esac
[ "$runner" = codex ] || exit 1
echo "call" >> "$CODEXCALLS"
printf 'codex reply\n' > "$out"
AC

# fake account-pick.sh: pops $PICKSEQ (a name per line, empty => default),
# honours a pin file the way the real picker does, and REWRITES the pin to the
# pick exactly as bin/account-pick.sh's `(5) refresh the pin` block does.
#
# It also SKIPS an account inside its cooldown, which is the whole point of the
# stamp: the real picker reads state/quota/cooldown/<vendor>/<account>
# (account_cooldown_file, BH-940) and sweeps a bare cooldown/<account> into
# .legacy/ without ever reading it. A picker that ignored cooldowns could not
# tell a correct stamp from one written to the dead path.
cat > "$T/fake-account-pick.sh" <<'PICK'
#!/bin/bash
echo "$* pin=${ACCOUNT_PIN_KEY:-}" >> "$PICKLOG"
pinf="$HARNESS/state/quota/pins/${ACCOUNT_PIN_KEY:-orchestrator}"
cooling() { [ -s "$HARNESS/state/quota/cooldown/claude/$1" ]; }
n=""
if [ -n "${PICK_ALWAYS:-}" ]; then n="$PICK_ALWAYS"   # ignores cooldowns on purpose
elif [ "${PICK_FROM_PIN:-0}" = 1 ] && [ -s "$pinf" ] && ! cooling "$(head -1 "$pinf")"; then
  printf 'name=%s\nreason=pinned\n' "$(head -1 "$pinf")"; exit 0
fi
if [ -z "$n" ]; then
  while [ -s "$PICKSEQ" ]; do
    c=$(head -1 "$PICKSEQ"); sed -i 1d "$PICKSEQ"
    cooling "$c" || { n="$c"; break; }
  done
fi
[ -n "$n" ] || n=default
printf 'name=%s\nreason=%s\n' "$n" "${PICKREASON:-priority}"
mkdir -p "$(dirname "$pinf")" 2>/dev/null && printf '%s\n' "$n" > "$pinf"
PICK

# The driver is a FILE: the lifted blocks run in a real script, with the real
# run_turn() and the real orc-account lib, the way bin/orchestrate.sh runs them.
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
. "$LIB"
orc_fresh() { return 0; }
compose_v2_prompt() { printf 'the message\n'; }
budget_check() { :; }
note() { echo "$1" >> "$HARNESS/logs/failovers.log"; }
IRON_LAW_ARM=()
# BH-2307 review: a failing mktemp must not turn run_survival's cleanup glob
# into `rm -f "" .*` in the orchestrator's cwd.
[ "${MKTEMP_FAIL:-0}" = 1 ] && mktemp() { return 1; }
RC=0; OUT=""; SERVED_BY=""
. "$BLOCK_SURVIVAL"
. "$BLOCK_RUNTURN"
. "$BLOCK_LADDER"
printf '%s' "$OUT" > "$OUTF"
{ echo "RC=$RC"
  echo "SERVED_BY=$SERVED_BY"
  echo "DEGRADED_BY=${DEGRADED_BY:-}"
  echo "ORC_ACCOUNT=${ORC_ACCOUNT:-}"
  echo "ORC_ACCOUNT_REASON=${ORC_ACCOUNT_REASON:-}"
  echo "COST_ACCT_NAME=${COST_ACCT_NAME:-}"; } > "$STATEF"
DRIVE

scen() { # scen <name> — a clean harness tree per scenario
  rm -rf "$T/h" "$T/orc"
  mkdir -p "$T/h/logs" "$T/h/bin" "$T/h/env/tokens.d" "$T/h/state/quota/cooldown/claude" "$T/h/state/quota/pins" "$T/orc"
  cp "$T/fake-account-pick.sh" "$T/h/bin/account-pick.sh"; chmod +x "$T/h/bin/account-pick.sh"
  cp "$T/fake-agent-call.sh" "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-max7\n' > "$T/h/env/tokens.d/max7-setup-token.env"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-max3\n' > "$T/h/env/tokens.d/max3-setup-token.env"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-max5\n' > "$T/h/env/tokens.d/max5-setup-token.env"
  : > "$T/calls"; : > "$T/codex.calls"; : > "$T/codex.prompt"; : > "$T/codex.direct"; : > "$T/ac.calls"; : > "$T/picklog"; : > "$T/pickseq"; : > "$T/refuse"
  rm -f "$T/out.txt" "$T/state.txt"
  SCEN="$1"
}
refuse() { printf '%s\t%s\n' "$1" "$2" >> "$T/refuse"; }   # <token> <message>
refuse_m() { printf '%s|%s\t%s\n' "$1" "$2" "$3" >> "$T/refuse"; }  # <token> <model> <message>
drive() { # drive <ORC_ACCOUNT> <ORC_TOKEN> [KEY=VAL ...]
  local acct="$1" tok="$2"; shift 2
  ( cd "$T" && env PATH="$T/bin:$PATH" HOME="$T/home" \
      HARNESS="$T/h" ORC="$T/orc" LIB="$DIR/bin/lib/orc-account.sh" \
      BLOCK_SURVIVAL="$T/survival.sh" BLOCK_RUNTURN="$T/runturn.sh" BLOCK_LADDER="$T/ladder.sh" \
      OUTF="$T/out.txt" STATEF="$T/state.txt" CALLS="$T/calls" REFUSE="$T/refuse" \
      CODEXCALLS="$T/codex.calls" CODEXPROMPT="$T/codex.prompt" \
      CODEXDIRECT="$T/codex.direct" ACCALLS="$T/ac.calls" \
      PICKLOG="$T/picklog" PICKSEQ="$T/pickseq" \
      ACCOUNT_ROUTING=1 ORC_MODEL=claude-fable-5-1 ORC_FALLBACK=claude-opus-5 \
      ORC_SURVIVAL=codex \
      ORC_BUDGET=2 TEXT=hi ORC_CLAUDE="$T/bin/claude" ORC_TOKEN_DEFAULT=tok-orc \
      ORC_TOKEN="$tok" ORC_ACCOUNT="$acct" ORC_ACCOUNT_REASON=pinned \
      "$@" timeout "${DRIVE_TIMEOUT:-30}" bash "$T/drive.sh" ) > "$T/drive.log" 2>&1
  # A ladder that cannot terminate is the failure mode the tried-set guard
  # exists to prevent — it has to read as a red test, not as a hung suite.
  [ $? -eq 124 ] && bad "$SCEN: the account ladder did not terminate within ${DRIVE_TIMEOUT:-30}s"
  return 0
}
out()   { cat "$T/out.txt" 2>/dev/null; }
st()    { sed -n "s/^$1=//p" "$T/state.txt" 2>/dev/null; }
calls() { tr '\n' ' ' < "$T/calls"; }
ncalls(){ grep -c '' < "$T/calls"; }
flog()  { cat "$T/h/logs/failovers.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 3. Ticket test 1 — max7 hits its session limit, the DEFAULT token serves
# ---------------------------------------------------------------------------
scen default-serves
refuse tok-max7 "You've reached your session limit for this account"
drive max7 tok-max7
eq  "3 reply"        "$(out)" "served on tok-orc"
eq  "3 served-by"    "$(st SERVED_BY)" "claude-fable-5-1"
eq  "3 calls"        "$(calls)" "tok-max7|claude-fable-5-1 tok-max7|claude-opus-5 tok-orc|claude-fable-5-1 "
eq  "3 codex calls"  "$(grep -c '' < "$T/codex.calls")" "0"
has "3 failovers"    "$(flog)" "turn account: max7 → refused(quota) → default"
[ -s "$T/h/state/quota/cooldown/claude/max7" ] && ok || bad "3: max7 must be cooled down before the re-pick"
eq  "3 cost label"   "$(st COST_ACCT_NAME)" ""
eq  "3 account"      "$(st ORC_ACCOUNT)" "default"

# 3b. A second max account exists: max7 -> max3 -> default, each tried once.
# The picker is offered max7 FIRST on the re-pick: only a cooldown stamp at the
# path the picker reads makes it skip max7 and hand back max3. Stamped to the
# legacy unscoped path, the picker re-offers max7, the tried-set guard forces
# `default`, and max3 — every further account — is never bought at all.
scen second-account
printf 'max7\nmax3\n' > "$T/pickseq"
refuse tok-max7 "You've reached your session limit for this account"
refuse tok-max3 "You've reached your session limit for this account"
drive max7 tok-max7
eq  "3b reply"      "$(out)" "served on tok-orc"
eq  "3b calls"      "$(ncalls)" "5"
has "3b max3 bought" "$(calls)" "tok-max3|claude-fable-5-1"
eq  "3b reason"     "$(st ORC_ACCOUNT_REASON)" "rung-cap"
has "3b trail"      "$(flog)" "max7 → refused(quota) → max3"
has "3b trail 2"    "$(flog)" "max3 → refused(quota) → default"
[ -s "$T/h/state/quota/cooldown/claude/max3" ] && ok || bad "3b: max3 must be cooled down too"
[ -e "$T/h/state/quota/cooldown/claude/default" ] && bad "3b: default must never be cooled down" || ok

# 3c. MIXED CLASSES ON ONE ACCOUNT. fable refuses on quota, opus then hits a
# 529 on the SAME account. Classifying only the tail $OUT reads the account as
# transient: no cooldown, no re-pick, straight to codex under a banner claiming
# "the default token was not tried (transient on max7 is not an account
# refusal)" about an account that refused on quota one call earlier. The
# strongest verdict across the account's models is the one that counts.
scen mixed-class
refuse_m tok-max7 claude-fable-5-1 "You've reached your session limit for this account"
refuse_m tok-max7 claude-opus-5   "529 overloaded, please retry"
drive max7 tok-max7
eq  "3c reply"       "$(out)" "served on tok-orc"
eq  "3c calls"       "$(calls)" "tok-max7|claude-fable-5-1 tok-max7|claude-opus-5 tok-orc|claude-fable-5-1 "
eq  "3c codex calls" "$(grep -c '' < "$T/codex.calls")" "0"
has "3c trail"       "$(flog)" "turn account: max7 → refused(quota) → default"
[ -s "$T/h/state/quota/cooldown/claude/max7" ] && ok || bad "3c: a quota refusal on ANY model of the account must cool the account down, even when a later model failed transiently"

# 3d. THE RUNG CAP. Every rung stamps a 6h cooldown the whole hub honours, so
# one chat message must not be able to walk (and park) the entire max pool: a
# turn buys at most ORC_ACCOUNT_RUNGS_MAX named accounts, then the default.
scen rung-cap
printf 'max3\nmax5\n' > "$T/pickseq"
refuse tok-max7 "You've reached your session limit for this account"
refuse tok-max3 "You've reached your session limit for this account"
refuse tok-max5 "You've reached your session limit for this account"
drive max7 tok-max7
eq  "3d reply"    "$(out)" "served on tok-orc"
eq  "3d calls"    "$(ncalls)" "5"
hasnt "3d third account" "$(calls)" "tok-max5"
eq  "3d reason"   "$(st ORC_ACCOUNT_REASON)" "rung-cap"
[ -e "$T/h/state/quota/cooldown/claude/max5" ] && bad "3d: a turn must not cool down an account it never ran on" || ok
eq  "3d cooled"   "$(ls "$T/h/state/quota/cooldown/claude" | tr '\n' ' ')" "max3 max7 "

# 3e. The fable→opus credits cooldown is keyed to the ACCOUNT that ran, the way
# agent-call.sh keys it. Stamped globally, max7's dry fable pool would send
# every other account straight to opus for six hours — the exact loss account
# routing exists to prevent, and nothing clears it but a fable success.
scen model-cooldown-scope
refuse_m tok-max7 claude-fable-5-1 "You are out of usage credits"
drive max7 tok-max7
eq  "3e reply"      "$(out)" "served on tok-max7"
eq  "3e served-by"  "$(st SERVED_BY)" "claude-opus-5"
[ -s "$T/h/state/model-cooldown-claude-fable-5-1-max7" ] && ok || bad "3e: the fable cooldown must be keyed to the account that ran"
[ -e "$T/h/state/model-cooldown-claude-fable-5-1" ] && bad "3e: one account's dry fable pool must not stamp the fleet-wide model cooldown" || ok

# ---------------------------------------------------------------------------
# 4. Ticket test 2 — max7 AND the default token refuse: survival, measured
# ---------------------------------------------------------------------------
scen all-refuse
refuse tok-max7 "You've reached your session limit for this account"
refuse tok-orc  "You've reached your session limit for this account"
drive max7 tok-max7
eq  "4 degraded-by"  "$(st DEGRADED_BY)" "codex"
eq  "4 served-by"    "$(st SERVED_BY)" "codex survival lane"
eq  "4 codex calls"  "$(grep -c '' < "$T/codex.calls")" "1"
has "4 banner"       "$(out)" "max7 (session limit)"
has "4 banner both"  "$(out)" "default (session limit)"
hasnt "4 banner credits" "$(out)" "out of credits"
has "4 reply body"   "$(out)" "codex reply"
has "4 brief why"    "$(cat "$T/codex.prompt")" "WHY YOU ARE ANSWERING: claude refused on max7 (session limit)"
hasnt "4 brief guess" "$(cat "$T/codex.prompt")" "out of credits or otherwise failing"
# BH-2307: the survival turn went through agent-call — priced, gated, attributed
# to the orchestrator stage and the orc-monitor lane, pinned to codex with no
# ladder below it, on the old 1800 s budget — and never ran codex directly.
eq  "4 via agent-call" "$(cat "$T/ac.calls")" "orchestrator|orchestrator|codex|codex|orc-monitor|1800"
eq  "4 no direct codex" "$(cat "$T/codex.direct")" ""

# 4m. mktemp fails inside run_survival: the lane reports a failure, nothing is
# called, and NOTHING in the cwd is deleted. /root/orchestrator holds .env and
# .mcp.json, which `rm -f "$tmp" "$tmp".*` with an empty $tmp would take out.
scen mktemp-fails
refuse tok-max7 "You've reached your session limit for this account"
refuse tok-orc  "You've reached your session limit for this account"
printf 'SECRET=keep\n' > "$T/.env-sentinel"; printf '{}\n' > "$T/.mcp-sentinel.json"
drive max7 tok-max7 MKTEMP_FAIL=1
[ -f "$T/.env-sentinel" ] && [ -f "$T/.mcp-sentinel.json" ] && ok \
  || bad "4m: a failing mktemp in run_survival deleted dotfiles in the cwd"
eq  "4m no agent-call" "$(cat "$T/ac.calls")" ""
eq  "4m not served"    "$(st DEGRADED_BY)" ""
rm -f "$T/.env-sentinel" "$T/.mcp-sentinel.json"
has "4 lane note"    "$(flog)" "claude lane dead (max7 → refused(quota) → default → refused(quota), rc=1)"

# ---------------------------------------------------------------------------
# 5. Credits wording — routing off, the default token is out of credits
# ---------------------------------------------------------------------------
scen credits
refuse tok-orc "Credit balance is too low: you are out of usage credits"
drive default tok-orc ACCOUNT_ROUTING=0
has "5 banner credits" "$(out)" "out of credits"
has "5 brief credits"  "$(cat "$T/codex.prompt")" "claude refused on default (out of credits)"
[ -s "$T/h/state/model-cooldown-claude-fable-5-1" ] && ok || bad "5: the per-model credits cooldown stamp must survive this change"
eq  "5 picker calls"   "$(grep -c '' < "$T/picklog")" "0"
eq  "5 codex calls"    "$(grep -c '' < "$T/codex.calls")" "1"

# ---------------------------------------------------------------------------
# 6. Ticket test 3 — the pin never survives the refusal it caused
# ---------------------------------------------------------------------------
scen pinned
printf 'max7\n' > "$T/h/state/quota/pins/orchestrator"
refuse tok-max7 "You've reached your session limit for this account"
drive max7 tok-max7 PICK_FROM_PIN=1
eq  "6 reply"   "$(out)" "served on tok-orc"
eq  "6 calls"   "$(calls)" "tok-max7|claude-fable-5-1 tok-max7|claude-opus-5 tok-orc|claude-fable-5-1 "
[ -e "$T/h/state/quota/pins/orchestrator" ] && bad "6: the pin must not name an account after the turn refused on it ($(cat "$T/h/state/quota/pins/orchestrator"))" || ok
has "6 picker ran" "$(cat "$T/picklog")" "pin=orchestrator"

# 6b. A picker that keeps answering max7 is overridden by the tried-set guard
scen pin-stuck
refuse tok-max7 "You've reached your session limit for this account"
drive max7 tok-max7 PICK_ALWAYS=max7
eq  "6b reply"   "$(out)" "served on tok-orc"
eq  "6b calls"   "$(calls)" "tok-max7|claude-fable-5-1 tok-max7|claude-opus-5 tok-orc|claude-fable-5-1 "
eq  "6b reason"  "$(st ORC_ACCOUNT_REASON)" "already-tried"

# ---------------------------------------------------------------------------
# 7. Not the account's fault: no re-buy, and the banner says so
# ---------------------------------------------------------------------------
scen transient
refuse tok-max7 "529 overloaded, please retry"
drive max7 tok-max7
eq  "7 codex calls"  "$(grep -c '' < "$T/codex.calls")" "1"
eq  "7 calls"        "$(ncalls)" "2"
eq  "7 picker calls" "$(grep -c '' < "$T/picklog")" "0"
[ -e "$T/h/state/quota/cooldown/claude/max7" ] && bad "7: a transient failure must not cool the account down" || ok
has "7 banner"       "$(out)" "the default token was not tried"
has "7 banner class" "$(out)" "max7 (transient vendor error: 529)"

# 7b. rc=124: the turn really ran for an hour — nothing else runs
scen timeout
refuse tok-max7 "timed out"
drive max7 tok-max7 REFUSE_RC=124
eq  "7b calls"       "$(ncalls)" "1"
eq  "7b codex calls" "$(grep -c '' < "$T/codex.calls")" "0"
eq  "7b picker"      "$(grep -c '' < "$T/picklog")" "0"
hasnt "7b no refusal line" "$(flog)" "refused("
[ -e "$T/h/state/quota/cooldown/claude/max7" ] && bad "7b: rc=124 must not cool an account down" || ok
has "7b floor reply" "$(out)" "ran the full hour"

# ---------------------------------------------------------------------------
# 8. Wiring and the ticket's two negatives
# ---------------------------------------------------------------------------
bash -n "$SRC" && ok || bad "bin/orchestrate.sh syntax"
bash -n "$DIR/bin/lib/orc-account.sh" && ok || bad "bin/lib/orc-account.sh syntax"
grep -q '^ORC_TOKEN_DEFAULT="\$ORC_TOKEN"' "$SRC" && ok || bad "orchestrate.sh must keep the orchestrator.env token before the pick overwrites it"
L1=$(grep -n '^ORC_TOKEN_DEFAULT="\$ORC_TOKEN"' "$SRC" | cut -d: -f1)
L2=$(grep -n 'orc_pick_account "\$ORC_MODEL"' "$SRC" | head -1 | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L2" -gt "$L1" ] && ok || bad "the default token must be captured BEFORE the pre-turn pick"
# NEGATIVE: agent-call.sh's ladders are not part of this change. This used to
# be `git diff --quiet main -- bin/agent-call.sh`, which is red on any checkout
# where main and the branch differ on that file for ANY reason (a stale local
# main, a later main commit touching it) and is skipped entirely wherever the
# suite runs without a git tree — it proved nothing where it mattered. The
# contract it was protecting is the three-regex equality check above, which is
# what actually fails if the two ladders drift apart.
# NEGATIVE: no new env var. Every ${NAME} read without being assigned in the
# same file is an env input, and the set may not grow.
#
# SCOPED TO WHAT BH-996 TOUCHES: the lifted `# >>> claude ladder` block and
# bin/lib/orc-account.sh — not all of bin/orchestrate.sh, which would make this
# ticket's suite red the day any later ticket adds a legitimate knob anywhere
# else in that file.
env_reads() {
  comm -23 \
    <(grep -oE '\$\{[A-Z][A-Z0-9_]*' "$1" | sed 's/^\${//' | sort -u) \
    <(grep -oE '(^|[;[:space:]])(export |local )?[A-Z][A-Z0-9_]*=' "$1" | grep -oE '[A-Z][A-Z0-9_]*' | sort -u)
}
# Every name here already existed before BH-996 (the three LADDER_*_REGEX are
# bin/agent-call.sh's own, duplicated verbatim). A knob added to the ladder or
# to bin/lib/orc-account.sh by a later change belongs in the ticket that adds
# it, not in this list.
# BH-2355: ACCOUNT_COOLDOWN_SECS (the picker's existing window, for the fleet
# row's until) and BASH_SOURCE (a bash builtin, for sourcing the seam lib).
# BH-2651: H (the lib's root is $HARNESS, else $H, per the BH-2613 contract).
# BH-5336: ORC_TURN_ERR is not a knob. It is the turn's own error-file path,
# exported by orct_state_begin (bin/lib/orc-turns.sh) for parallel turns.
ALLOWED=" ACCOUNT_COOLDOWN_SECS ACCOUNT_EXHAUST_REGEX ACCOUNT_ROUTING BASH_SOURCE COST_PROJECT H HARNESS LADDER_AUTH_REGEX LADDER_EXHAUST_REGEX LADDER_TRANSIENT_REGEX MODEL_COOLDOWN_SECS ORC_ACCOUNT_PIN ORC_ACCOUNT_ROUTING ORC_TURN_ERR "
NEW=""
for f in "$T/ladder.sh" "$DIR/bin/lib/orc-account.sh"; do
  while read -r n; do
    [ -n "$n" ] || continue
    case "$ALLOWED" in *" $n "*) ;; *) NEW="$NEW $n" ;; esac
  done < <(env_reads "$f")
done
[ -z "$NEW" ] && ok || bad "BH-996 forbids a new env var; these are read but never set:$NEW"

echo "orc-turn-ladder.bh-996: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
