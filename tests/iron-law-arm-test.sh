#!/bin/bash
# tests/iron-law-arm-test.sh — the three conversational launchers carry the
# act-time iron-law hook, and bin/iron-law-arm.sh is what puts it there.
#
# WHY THIS SHAPE. bin/agent-call.sh wires the guard for the pipeline stages, and
# tests/iron-law-guard-test.sh section 6 proves that by reading what reached the
# CLI. The orchestrator, the per-box chat and greenfield do not come through
# agent-call.sh at all — they are conversational turns with their own model
# ladders — so until now they ran with no hook and no HARNESS_LANE marker. This
# suite proves the same thing for them, the same way: a fake claude-cost.sh
# dumps its argv and its environment, and every assertion is read back off disk.
# Nothing here is asserted by grepping a launcher's source.
#
# SCOPE. This is a WIRING suite. Whether `rm -rf /root/harness/env` is actually
# refused in an orchestrator turn is bin/iron-law-guard.sh's property and is
# proved by tests/iron-law-guard-test.sh and tests/iron-law-fs-test.sh. What is
# proved here: the settings file reaches the CLI, it wires the guard, the lane
# marker reaches the process, and the lanes that must NOT be marked are not.
#
# determinism: ok-file this suite reads no clock and rolls no dice; every fixture
# value is a literal and the only variable part is mktemp's own directory name.
# Run from anywhere: tests/iron-law-arm-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/fakebin" "$T/logs" "$T/state" "$T/locks" "$T/flags"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ARM="$DIR/bin/iron-law-arm.sh"
GUARD="$DIR/bin/iron-law-guard.sh"

# The helper resolves its guard as $(dirname "$0")/iron-law-guard.sh first, so a
# copy under $T/bin is what makes $T a self-contained fake harness — exactly the
# layout it has in production ($HARNESS/bin next to $HARNESS/state).
if [ -f "$ARM" ]; then cp "$ARM" "$T/bin/iron-law-arm.sh"; chmod +x "$T/bin/iron-law-arm.sh"; fi
cp "$GUARD" "$T/bin/iron-law-guard.sh"; chmod +x "$T/bin/iron-law-guard.sh"

# The fake CLI, shared by every section: argv and environment to disk, one line
# of JSON-ish output so a caller that parses gets something.
cat > "$T/fakebin/claude-cost.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$T_SENTINEL_DIR/argv.txt"
env > "$T_SENTINEL_DIR/env.txt"
echo '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0.01}'
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fakebin/claude-cost.sh"

# EVERY driver below starts from a CLEAN lane environment. This suite runs
# inside a harness build lane, which already exports HARNESS_LANE and friends, so
# a fixture that merely inherited them would assert nothing at all — and the
# negatives ("this lane is NOT marked") would fail on a box and pass on a laptop.
CLEANENV=(env -u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT -u HARNESS_LANE_BUILD_DIR)

# The --settings value claude was handed, read out of the dumped argv.
settings_arg() { grep -A1 -Fx -- '--settings' "${1:-$T/argv.txt}" 2>/dev/null | tail -1; }
wires_guard() { # wires_guard <settings-file> <expected-guard-path>
  [ -n "$1" ] && [ -f "$1" ] \
    && [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$1" 2>/dev/null)" = "$2" ]
}

# ── 1. bin/iron-law-arm.sh itself ────────────────────────────────────────────
run_arm() { # run_arm <harness> <script> <lane> -> stdout in $OUT, rc in $RC
  OUT=$("${CLEANENV[@]}" HARNESS="$1" bash "$2" "$3" 2>/dev/null); RC=$?
}

if [ ! -x "$T/bin/iron-law-arm.sh" ]; then
  bad "bin/iron-law-arm.sh does not exist (or is not executable) — nothing can arm a launcher"
else
  run_arm "$T" "$T/bin/iron-law-arm.sh" orchestrator
  [ "$RC" = 0 ] && ok || bad "the arm helper exited $RC; it must always exit 0 and never refuse a turn"
  [ "$OUT" = "$T/state/iron-law-guard-settings.json" ] \
    && ok || bad "the helper must print the SHARED settings path when the guard is \$HARNESS/bin/iron-law-guard.sh (got '$OUT')"
  wires_guard "$OUT" "$T/bin/iron-law-guard.sh" \
    && ok || bad "the settings file does not wire the guard as a hook command: $(cat "$OUT" 2>/dev/null)"
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout' "$OUT" 2>/dev/null)" = 30 ] \
    && ok || bad "the hook timeout is not 30s — a hook the CLI kills runs the command UNGUARDED"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$OUT" 2>/dev/null)" = Bash ] \
    && ok || bad "the guard hook is not matched to Bash"

  # INVOKED BY A RELATIVE PATH, the hook command must still be ABSOLUTE. The CLI
  # reads the settings file from whatever cwd the session has — box-chat runs its
  # turn from $SESS — so a relative command is a hook that resolves to nothing
  # and a lane that believes it is fenced. `bash bin/iron-law-arm.sh` from a
  # checkout is exactly how that shape reaches production.
  OUT=$( cd "$T" && "${CLEANENV[@]}" HARNESS="$T" bash bin/iron-law-arm.sh orchestrator 2>/dev/null )
  case "$OUT" in
    /*) ok ;;
    *) bad "invoked by a relative path the helper printed a relative settings path '$OUT'" ;;
  esac
  CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$OUT" 2>/dev/null)
  [ "$CMD" = "$T/bin/iron-law-guard.sh" ] \
    && ok || bad "a relative invocation wrote a hook command the CLI cannot resolve from another cwd: '$CMD'"

  # A guard that is not on the box is an ALERT and an unarmed turn, never a
  # settings path pointing at nothing.
  : > "$T/logs/ALERTS.log"
  mv "$T/bin/iron-law-guard.sh" "$T/bin/iron-law-guard.off"
  run_arm "$T" "$T/bin/iron-law-arm.sh" orchestrator
  [ "$RC" = 0 ] && [ -z "$OUT" ] \
    && ok || bad "with no guard on the box the helper must print nothing and exit 0 (rc=$RC out='$OUT')"
  [ "$(grep -c 'iron-law guard MISSING' "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
    && ok || bad "a box with no guard armed a launcher silently — exactly one ALERTS line is owed"

  # No logs dir (a Mac running greenfield): still quiet, still rc 0, and the
  # helper does not go creating a harness log tree that does not belong to it.
  mv "$T/logs" "$T/logs.off"
  run_arm "$T" "$T/bin/iron-law-arm.sh" greenfield
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -d "$T/logs" ] \
    && ok || bad "with no \$HARNESS/logs the helper must stay quiet and create nothing (rc=$RC out='$OUT')"
  mv "$T/logs.off" "$T/logs"
  mv "$T/bin/iron-law-guard.off" "$T/bin/iron-law-guard.sh"

  # $HARNESS/state unusable -> TMPDIR, never a skipped arm. A REGULAR FILE where
  # the dir belongs is the fixture that holds for every uid: this suite runs as
  # root on a box, and root ignores mode bits, so a chmod 500 dir would still be
  # writable and would prove nothing.
  mv "$T/state" "$T/state.off"; : > "$T/state"
  run_arm "$T" "$T/bin/iron-law-arm.sh" chat
  case "$OUT" in
    "${TMPDIR:-/tmp}"/iron-law-guard-settings-*) ok ;;
    *) bad "with \$HARNESS/state unusable the helper must fall back under ${TMPDIR:-/tmp} (got '$OUT')" ;;
  esac
  wires_guard "$OUT" "$T/bin/iron-law-guard.sh" \
    && ok || bad "the TMPDIR fallback settings file does not wire the guard: $(cat "$OUT" 2>/dev/null)"
  rm -f "$OUT" "$T/state"; mv "$T/state.off" "$T/state"
  # The mode-bit half of "unwritable" still gets asserted where mode bits mean
  # something (a non-root dev machine); as root the chmod is a no-op and the
  # case above is the one that carries the property.
  chmod 500 "$T/state"
  if [ ! -w "$T/state" ]; then
    run_arm "$T" "$T/bin/iron-law-arm.sh" chat
    case "$OUT" in
      "${TMPDIR:-/tmp}"/iron-law-guard-settings-*) ok ;;
      *) bad "a read-only \$HARNESS/state must fall back under ${TMPDIR:-/tmp} (got '$OUT')" ;;
    esac
    rm -f "$OUT"
  fi
  chmod 755 "$T/state"

  # A checkout driving its OWN copy of the guard must not overwrite the shared
  # file with a different command path — agent-call.sh writes that same file.
  mkdir -p "$T/other"
  cp "$T/bin/iron-law-arm.sh" "$T/bin/iron-law-guard.sh" "$T/other/"
  SHARED="$T/state/iron-law-guard-settings.json"
  run_arm "$T" "$T/other/iron-law-arm.sh" chat
  [ -n "$OUT" ] && [ "$OUT" != "$SHARED" ] && [ "${OUT%.json}" != "$OUT" ] \
    && case "$OUT" in *"/iron-law-guard-settings-"*) true ;; *) false ;; esac \
    && ok || bad "a sibling-path guard must get its OWN settings file, not the shared one (got '$OUT')"
  wires_guard "$OUT" "$T/other/iron-law-guard.sh" \
    && ok || bad "the sibling settings file must wire the sibling guard: $(cat "$OUT" 2>/dev/null)"
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SHARED" 2>/dev/null)" = "$T/bin/iron-law-guard.sh" ] \
    && ok || bad "the sibling run clobbered the shared settings file agent-call.sh also writes"
fi

# ── 2. bin/orchestrate.sh — lane orchestrator, project fleet ─────────────────
extract_block() { # extract_block <script> <out>
  awk '/# >>> iron-law arm/,/# <<< iron-law arm/' "$1" > "$2"
}
extract_block "$DIR/bin/orchestrate.sh" "$T/orc-block.sh"
awk '/^run_turn\(\) \{/,/^}/' "$DIR/bin/orchestrate.sh" > "$T/orc-runturn.sh"
[ -s "$T/orc-runturn.sh" ] || bad "could not extract run_turn() from bin/orchestrate.sh — the rest of section 2 proves nothing"

# The driver is a FILE so $(dirname "$0") inside the extracted block resolves the
# way it does in the real launcher (a sibling lookup that misses, then $HARNESS).
cat > "$T/orc-drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
orc_fresh() { return "${ORC_FRESH_RC:-1}"; }
budget_check() { :; }
compose_v2_prompt() { echo hi; }
note() { :; }
. "$T_SENTINEL_DIR/orc-block.sh"
. "$T_SENTINEL_DIR/orc-runturn.sh"
run_turn claude-x
DRIVE
chmod +x "$T/orc-drive.sh"

orc_run() { # orc_run <harness> <block-file> [ORC_FRESH_RC]
  rm -f "$T/argv.txt" "$T/env.txt"
  cp "$2" "$T/orc-block.sh"
  ( cd "$T" && "${CLEANENV[@]}" T_SENTINEL_DIR="$T" HARNESS="$1" ORC_CLAUDE="$T/fakebin/claude-cost.sh" \
      ORC_BUDGET=1 TEXT=hi ORC_FRESH_RC="${3:-1}" ORC_TOKEN="" \
      bash "$T/orc-drive.sh" >/dev/null 2>&1 )
}

cp "$T/orc-block.sh" "$T/orc-block.real"
if [ ! -s "$T/orc-block.real" ]; then
  bad "bin/orchestrate.sh carries no '# >>> iron-law arm' block — the orchestrator turn is unfenced"
else
  # continue path (-c): the one every turn after the first takes.
  orc_run "$T" "$T/orc-block.real" 1
  S=$(settings_arg)
  wires_guard "$S" "$T/bin/iron-law-guard.sh" \
    && ok || bad "the orchestrator -c turn got no settings file wiring the guard (--settings='$S')"
  grep -qFx -- '-c' "$T/argv.txt" \
    && ok || bad "the -c continue path stopped being taken, so this proves nothing about it"
  grep -qFx "HARNESS_LANE=orchestrator" "$T/env.txt" \
    && ok || bad "HARNESS_LANE=orchestrator never reached the CLI, so the hook has nothing to fence on"
  grep -qFx "HARNESS_LANE_PROJECT=fleet" "$T/env.txt" \
    && ok || bad "HARNESS_LANE_PROJECT=fleet never reached the CLI, so findings cannot name the lane"
  grep -qFx "HARNESS=$T" "$T/env.txt" \
    && ok || bad "HARNESS never reached the CLI, so the hook would read the wrong harness tree"

  # fresh path: the default since #73, and the one that used to skip its checks.
  orc_run "$T" "$T/orc-block.real" 0
  S=$(settings_arg)
  wires_guard "$S" "$T/bin/iron-law-guard.sh" \
    && ok || bad "the orchestrator FRESH turn is unfenced (--settings='$S')"
  grep -qFx "HARNESS_LANE=orchestrator" "$T/env.txt" \
    && ok || bad "the fresh orchestrator path carries no lane marker"

  # Without the arm block there is no --settings: this is what the block buys.
  printf 'IRON_LAW_ARM=()\n' > "$T/orc-block.none"
  orc_run "$T" "$T/orc-block.none" 1
  [ -z "$(settings_arg)" ] \
    && ok || bad "a turn with no arm block still got --settings — section 2 is not measuring the block"
  grep -qFx -- '-p' "$T/argv.txt" \
    && ok || bad "the unarmed turn did not run at all; arming must never be able to refuse a turn"

  # A box with no helper anywhere: unfenced turn, still a turn.
  orc_run "$T/nowhere" "$T/orc-block.real" 1
  [ -z "$(settings_arg)" ] && grep -qFx -- '-p' "$T/argv.txt" \
    && ok || bad "with no arm helper on the box the turn must run unfenced, not break"
fi
cp "$T/orc-block.real" "$T/orc-block.sh"

# ── 3. bin/box-chat.sh — lane chat, project from the payload ─────────────────
# The whole script, driven for real: this is the production entry point.
BC="$T/bc"
mkdir -p "$BC/bin" "$BC/state" "$BC/logs" "$BC/locks" "$BC/env" "$BC/fakebin"
model_routes_fixture "$BC" || exit 1  # BH-1510.2: the chat pane's model is role orchestrate
cp "$DIR/bin/box-chat.sh" "$BC/bin/"
[ -f "$ARM" ] && { cp "$ARM" "$BC/bin/"; chmod +x "$BC/bin/iron-law-arm.sh"; }
cp "$GUARD" "$BC/bin/iron-law-guard.sh"; chmod +x "$BC/bin/iron-law-guard.sh"
cp "$T/fakebin/claude-cost.sh" "$BC/bin/claude-cost.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/BEATS.jsonl"\n' "$BC" > "$BC/bin/beat.sh"
printf '#!/bin/bash\necho -\n' > "$BC/bin/fleet-conf.sh"
cat > "$BC/bin/agent-call.sh" <<'FB'
#!/bin/bash
env > "$T_SENTINEL_DIR/fb-env.txt"
printf 'fb answer\n' > "${5:-/dev/null}"
exit 0
FB
chmod +x "$BC/bin/"*.sh
: > "$BC/env/global.env"
echo boxy > "$BC/state/box-id"

B=$(printf '%s' '{"text":"why is the queue stuck","project":"proj1"}' | base64 -w0)
chat_run() { # chat_run <command-id> [env assignments...]
  local cid="$1"; shift
  rm -f "$BC/argv.txt" "$BC/env.txt" "$BC/fb-env.txt"
  ( cd "$T" && "${CLEANENV[@]}" T_SENTINEL_DIR="$BC" HARNESS="$BC" BOX_CHAT_TIMEOUT=60 "$@" \
      bash "$BC/bin/box-chat.sh" --b64 "$B" "$cid" >/dev/null 2>&1 )
}

chat_run id1
S=$(settings_arg "$BC/argv.txt")
wires_guard "$S" "$BC/bin/iron-law-guard.sh" \
  && ok || bad "the box-chat turn got no settings file wiring the guard (--settings='$S')"
grep -qFx "HARNESS_LANE=chat" "$BC/env.txt" 2>/dev/null \
  && ok || bad "HARNESS_LANE=chat never reached the CLI in a box-chat turn"
grep -qFx "HARNESS_LANE_PROJECT=proj1" "$BC/env.txt" 2>/dev/null \
  && ok || bad "the chat lane's project marker is not the payload's project"
grep -q '"kind":"chat_reply"' "$BC/BEATS.jsonl" 2>/dev/null && grep -q 'id1' "$BC/BEATS.jsonl" \
  && ok || bad "the console pane never got its answer — arming must not change what box-chat replies"

# Rung 2 is a DIFFERENT lane and keeps its own authority: the marker is on the
# `env` word of rung 1 only, never exported script-wide.
: > "$BC/BEATS.jsonl"
chat_run id2 FAKE_RC=3 RUNNER_CHAT_FALLBACK=codex
[ -s "$BC/fb-env.txt" ] \
  && ok || bad "the fallback runner was never reached, so the negative below proves nothing"
! grep -q '^HARNESS_LANE=' "$BC/fb-env.txt" 2>/dev/null \
  && ok || bad "box-chat's fallback runner inherited HARNESS_LANE — the marker leaked script-wide"
! grep -q '^HARNESS_LANE_WT=' "$BC/fb-env.txt" 2>/dev/null \
  && ok || bad "box-chat's fallback runner inherited HARNESS_LANE_WT"

# ── 4. bin/greenfield.sh — lane greenfield, project greenfield ───────────────
extract_block "$DIR/bin/greenfield.sh" "$T/gf-block.sh"
awk '/^run_llm\(\) \{/,/^}/' "$DIR/bin/greenfield.sh" > "$T/gf-runllm.sh"
[ -s "$T/gf-runllm.sh" ] || bad "could not extract run_llm() from bin/greenfield.sh"
cat > "$T/gf-drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
. "$T_SENTINEL_DIR/gf-block.sh"
. "$T_SENTINEL_DIR/gf-runllm.sh"
run_llm claude-x "$T_SENTINEL_DIR/map.out.txt" hello
DRIVE
chmod +x "$T/gf-drive.sh"
gf_run() { # gf_run <harness>
  rm -f "$T/argv.txt" "$T/env.txt" "$T/map.out.txt"
  ( cd "$T" && "${CLEANENV[@]}" T_SENTINEL_DIR="$T" HARNESS="$1" HERE="$T" CLAUDE_BIN="$T/fakebin/claude-cost.sh" \
      bash "$T/gf-drive.sh" >/dev/null 2>&1 )
}

if [ ! -s "$T/gf-block.sh" ]; then
  bad "bin/greenfield.sh carries no '# >>> iron-law arm' block — greenfield turns are unfenced"
else
  gf_run "$T"
  S=$(settings_arg)
  wires_guard "$S" "$T/bin/iron-law-guard.sh" \
    && ok || bad "the greenfield turn got no settings file wiring the guard (--settings='$S')"
  grep -qFx "HARNESS_LANE=greenfield" "$T/env.txt" \
    && ok || bad "HARNESS_LANE=greenfield never reached the CLI"
  grep -qFx "HARNESS_LANE_PROJECT=greenfield" "$T/env.txt" \
    && ok || bad "HARNESS_LANE_PROJECT=greenfield never reached the CLI"
  grep -qFx "COST_STAGE=gf-map" "$T/env.txt" \
    && ok || bad "the per-stage cost tag stopped reaching the wrapper — the ledger would stop splitting a pack"
  [ -s "$T/map.out.txt" ] \
    && ok || bad "the stage's own output file is empty — arming must not eat the stage's stdout"

  # A machine with no harness at all (the operator's Mac mid-sync): unfenced, still runs.
  gf_run "$T/nowhere"
  [ -z "$(settings_arg)" ] && [ -s "$T/map.out.txt" ] \
    && ok || bad "greenfield on a machine with no harness must run unfenced, not break"
fi

# ── 5. bin/agent-call.sh — the lane's own worktree reaches the guard ─────────
# HARNESS_LANE_WT is what bin/iron-law-guard.sh reads into its allow-list, so a
# build can still clean the worktree it owns while $HARNESS/builds stays protected.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$T_SENTINEL_DIR/argv.txt"
env > "$T_SENTINEL_DIR/env.txt"
echo '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0.01}'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/claude" "$T/fakebin/billing-mode.sh" "$T/bin/beat.sh"

call() { # call <stage> [env assignments...]
  local stage="$1"; shift
  rm -f "$T/argv.txt" "$T/env.txt"
  ( cd "$T" && export T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    "${CLEANENV[@]}" "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-opus-5 600 "$T/out.txt" "hi" >/dev/null 2>&1 )
}

call execute
grep -qFx "HARNESS_LANE_WT=$T" "$T/env.txt" \
  && ok || bad "the execute lane's own worktree never reached the guard, so cleaning it would be refused"
call chat
! grep -q '^HARNESS_LANE_WT=' "$T/env.txt" \
  && ok || bad "the chat lane got HARNESS_LANE_WT — unmarked lanes must stay unmarked"

# ── 6. the operator doc says what family 6 refuses ──────────────────────────
grep -q 'Family 6' "$DIR/docs/OPERATOR-SETUP.md" \
  && ok || bad "docs/OPERATOR-SETUP.md documents no Family 6 — operators cannot read what the guard now refuses"

echo "iron-law-arm: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
