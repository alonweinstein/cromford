#!/bin/bash
# tests/archie-skill-replays.bh-4064-test.sh — BH-4064 (BH-3966.3): Archie's
# skills (orchestrator/skills/<name>/SKILL.md), their recorded replay cases,
# the runner bin/archie-skill-replay.sh, and the sync that deploys the skills to
# /root/orchestrator/.claude/skills on the hub.
#
# The ticket names this suite tests/archie-skill-replays-test.sh; harness
# convention is one new suite per ticket, so it lives here.
#
# Every runner case DRIVES bin/archie-skill-replay.sh with a stub model
# (ARCHIE_REPLAY_MODEL_CMD) or with its default recorded replayer. Nothing here
# calls a vendor.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/archie-skill-replay.sh"
SKILLS="$DIR/orchestrator/skills"
FIVE="steward-initiative triage-thread rollout-review cost-watch brief-operator"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A stub model: records the prompt it was given, then replays the case's own
# recording. <prompt-file> <case-dir> is the runner's contract.
mkdir -p "$T/stubs" "$T/calls"
cat > "$T/stubs/record" <<EOF
#!/bin/bash
c=\$(basename "\$(dirname "\$(dirname "\$2")")")__\$(basename "\$2")
cp "\$1" "$T/calls/\$c.txt"
cat "\$2/recorded.txt"
EOF
printf '#!/bin/bash\necho "VERDICT: hold"\n' > "$T/stubs/hold"
printf '#!/bin/bash\necho "VERDICT: beat"\nexit 1\n' > "$T/stubs/exit1"
printf '#!/bin/bash\necho "I think this one is fine."\n' > "$T/stubs/prose"
printf '#!/bin/bash\nprintf "VERDICT: Beat\\nVERDICT: SILENT\\r\\n"\n' > "$T/stubs/twice"
printf '#!/bin/bash\necho "VERDICT: maybe"\n' > "$T/stubs/maybe"
chmod +x "$T/stubs/"*

run() { "$RUNNER" "$@" > "$T/out" 2>"$T/err"; echo $?; }
cases_on_disk() { find "$1" -type d -path '*/replays/*' ! -path '*/replays/*/*' | wc -l | tr -d ' '; }

# --- R1 real tree passes with the stubbed model ------------------------------
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" run)
N=$(cases_on_disk "$SKILLS")
P=$(grep -c '^PASS ' "$T/out")
if [ "$RC" = 0 ] && tail -1 "$T/out" | grep -qE '^archie-skill-replay: 5 skills, [0-9]+ passed, 0 failed$' \
   && [ "$P" = "$N" ] && [ "$N" -ge 10 ] && ! grep -q '^FAIL' "$T/out"; then ok
else bad "R1 real tree: rc=$RC pass=$P cases=$N: $(cat "$T/out" "$T/err")"; fi
[ "$(find "$T/calls" -type f | wc -l | tr -d ' ')" = "$N" ] && ok || bad "R1 the stub model was not called once per case"

# --- R2 every shipped skill is present and shaped -----------------------------
for S in $FIVE; do
  F="$SKILLS/$S/SKILL.md"
  [ -f "$F" ] || { bad "R2 $S: no SKILL.md"; continue; }
  FM=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$F")
  grep -qx "name: $S" <<<"$FM" || bad "R2 $S: name: does not match its dir"
  D=$(sed -n 's/^description: *//p' <<<"$FM")
  [ "${#D}" -ge 40 ] || bad "R2 $S: description shorter than 40 chars"
  V=$(sed -n 's/^verdicts: *//p' <<<"$FM")
  [ -n "$V" ] || bad "R2 $S: no verdicts: line"
  grep -q '^# ' "$F" || bad "R2 $S: no # heading"
  NC=$(cases_on_disk "$SKILLS/$S")
  { [ "$NC" -ge 2 ] && [ "$NC" -le 3 ]; } || bad "R2 $S: $NC replay cases, want 2..3"
  for C in "$SKILLS/$S"/replays/*/; do
    for f in input.md expected recorded.txt; do [ -s "$C$f" ] || bad "R2 $S/$(basename "$C"): no $f"; done
    E=$(sed -n 's/^VERDICT: *//p' "$C/expected" | tr -d '\r ')
    grep -qw -- "$E" <<<"$(tr '|' ' ' <<<"$V")" || bad "R2 $S/$(basename "$C"): expected '$E' not in '$V'"
  done
  ok
done
# the an early engagement lesson is one of triage-thread's cases
grep -lq 'waiting-on-client' "$SKILLS"/triage-thread/replays/*/expected && ok \
  || bad "R2 triage-thread has no waiting-on-client case"

# --- R3 missing replays dir fails the run, and the run continues --------------
cp -r "$SKILLS" "$T/root3"; rm -rf "$T/root3/brief-operator/replays"
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" run --root "$T/root3")
if [ "$RC" = 1 ] && grep -qx 'FAIL brief-operator no replays/ dir' "$T/out" \
   && grep -q '^PASS cost-watch/' "$T/out" && grep -q '^PASS triage-thread/' "$T/out"; then ok
else bad "R3 missing replays: rc=$RC $(cat "$T/out")"; fi

# --- R4 a skill without enough replays fails ----------------------------------
mk_skill() { # mk_skill <root> <name> <ncases>
  mkdir -p "$1/$2/replays"
  printf -- '---\nname: %s\ndescription: a scratch skill for the replay runner suite\nverdicts: yes | no\n---\n\n# %s\n\nSay yes.\n' "$2" "$2" > "$1/$2/SKILL.md"
  local i; for i in $(seq 1 "$3"); do
    mkdir -p "$1/$2/replays/0$i-c"; echo "case $i" > "$1/$2/replays/0$i-c/input.md"
    echo "VERDICT: yes" > "$1/$2/replays/0$i-c/expected"; printf 'Yes.\nVERDICT: yes\n' > "$1/$2/replays/0$i-c/recorded.txt"
  done
}
mk_skill "$T/root4" one 1
RC=$(run --root "$T/root4")
[ "$RC" = 1 ] && grep -qx 'FAIL one needs at least 2 replay cases, has 1' "$T/out" && ok || bad "R4 one case: rc=$RC $(cat "$T/out")"
mk_skill "$T/root4b" none 0
RC=$(run --root "$T/root4b")
[ "$RC" = 1 ] && grep -q 'FAIL none needs at least 2 replay cases, has 0' "$T/out" && ok || bad "R4 zero cases: rc=$RC $(cat "$T/out")"
mk_skill "$T/root4c" two 2
RC=$(run --root "$T/root4c")
[ "$RC" = 0 ] && tail -1 "$T/out" | grep -qx 'archie-skill-replay: 1 skills, 2 passed, 0 failed' && ok || bad "R4 control two cases: rc=$RC $(cat "$T/out")"
# a case dir with no files is a FAIL, never skipped
mkdir -p "$T/root4c/two/replays/03-empty"
RC=$(run --root "$T/root4c")
[ "$RC" = 1 ] && grep -q '^FAIL two/03-empty ' "$T/out" && ok || bad "R4 empty case dir: rc=$RC $(cat "$T/out")"

# --- R5 a verdict mismatch fails -----------------------------------------------
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/hold" run --skill triage-thread)
WC=$(grep -l 'waiting-on-client' "$SKILLS"/triage-thread/replays/*/expected | head -1 | xargs dirname | xargs basename)
[ "$RC" = 1 ] && grep -qx "FAIL triage-thread/$WC expected=waiting-on-client got=hold" "$T/out" && ok \
  || bad "R5 mismatch: rc=$RC $(cat "$T/out")"

# --- R6 no verdict or a model failure is a FAIL ---------------------------------
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/exit1" run --root "$T/root4c")
[ "$RC" = 1 ] && grep -q '^FAIL two/01-c expected=yes got=none$' "$T/out" && ! grep -q '^PASS' "$T/out" && ok \
  || bad "R6 model rc!=0: rc=$RC $(cat "$T/out")"
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/prose" run --root "$T/root4c")
[ "$RC" = 1 ] && grep -q '^FAIL two/01-c expected=yes got=none$' "$T/out" && ok || bad "R6 prose: rc=$RC $(cat "$T/out")"
rm -rf "$T/root4c/two/replays/03-empty"
rm -f "$T/root4c/two/replays/02-c/recorded.txt"
RC=$(run --root "$T/root4c")
[ "$RC" = 1 ] && grep -q '^FAIL two/02-c expected=yes got=none$' "$T/out" && grep -q '^PASS two/01-c yes$' "$T/out" && ok \
  || bad "R6 missing recorded.txt: rc=$RC $(cat "$T/out")"

# --- R7 last VERDICT wins, normalized --------------------------------------------
mkdir -p "$T/root7"; mk_skill "$T/root7" pick 2
sed -i 's/^verdicts:.*/verdicts: silent | beat | escalate/' "$T/root7/pick/SKILL.md"
printf 'VERDICT: silent \r\n' > "$T/root7/pick/replays/01-c/expected"
printf 'VERDICT: Silent\n'    > "$T/root7/pick/replays/02-c/expected"
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/twice" run --root "$T/root7")
[ "$RC" = 0 ] && grep -qx 'PASS pick/01-c silent' "$T/out" && grep -qx 'PASS pick/02-c silent' "$T/out" && ok \
  || bad "R7 last verdict wins: rc=$RC $(cat "$T/out")"

# --- R8 expected outside the vocabulary is a structural FAIL ---------------------
printf 'VERDICT: maybe\n' > "$T/root7/pick/replays/01-c/expected"
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/maybe" run --root "$T/root7")
[ "$RC" = 1 ] && grep -q '^FAIL pick/01-c expected maybe not in verdicts' "$T/out" && ! grep -q '^PASS pick/01-c' "$T/out" && ok \
  || bad "R8 out-of-vocabulary expected: rc=$RC $(cat "$T/out")"

# --- R9 prompt composition ---------------------------------------------------------
P9=$(find "$T/calls" -name 'cost-watch__*' | sort | head -1)
C9="$SKILLS/cost-watch/replays/$(basename "$P9" .txt | sed 's/^cost-watch__//')"
if [ -f "$P9" ]; then
  H9=$(grep -m1 '^# ' "$SKILLS/cost-watch/SKILL.md")
  grep -qxF -- "$H9" "$P9" || bad "R9 prompt lacks the SKILL.md heading"
  ! grep -q '^verdicts:' "$P9" || bad "R9 prompt carries the frontmatter"
  ! grep -q '^name: cost-watch' "$P9" || bad "R9 prompt carries the frontmatter name"
  AFTER=$(awk 'f; /^=== CASE ===$/{f=1}' "$P9")
  FIRST_IN=$(head -1 "$C9/input.md")
  grep -qxF -- "$FIRST_IN" <<<"$AFTER" || bad "R9 input.md is not after === CASE ==="
  tail -1 "$P9" | grep -qx 'End with exactly one line: VERDICT: <one of ok | warn | stop>' || bad "R9 last line: $(tail -1 "$P9")"
  ok
else bad "R9 no recorded prompt for cost-watch"; fi

# --- R10 empty root and usage --------------------------------------------------------
mkdir -p "$T/empty"
RC=$(run --root "$T/empty"); [ "$RC" = 1 ] && grep -q '^FAIL no skills under ' "$T/out" && ok || bad "R10 empty root: rc=$RC $(cat "$T/out")"
RC=$(run --root "$T/absent"); [ "$RC" = 2 ] && ok || bad "R10 missing root: rc=$RC"
: > "$T/afile"
RC=$(run --root "$T/afile"); [ "$RC" = 2 ] && ok || bad "R10 root is a file: rc=$RC"
RC=$(run --skill nope); [ "$RC" = 2 ] && ok || bad "R10 --skill nope: rc=$RC"
RC=$(run --bogus); [ "$RC" = 2 ] && ok || bad "R10 unknown flag: rc=$RC"
RC=$(run --skill cost-watch)
[ "$RC" = 0 ] && [ "$(grep -c '^PASS ' "$T/out")" = "$(cases_on_disk "$SKILLS/cost-watch")" ] \
  && ! grep -q '^PASS' <<<"$(grep -v '^PASS cost-watch/' "$T/out")" && tail -1 "$T/out" | grep -q ': 1 skills,' && ok \
  || bad "R10 --skill cost-watch: rc=$RC $(cat "$T/out")"
RC=$(ARCHIE_SKILLS_ROOT="$T/root4c" run); [ "$RC" = 1 ] && grep -q '^FAIL two/02-c' "$T/out" && ok || bad "R10 ARCHIE_SKILLS_ROOT ignored: rc=$RC"

# --- R11 the default model makes no vendor call ----------------------------------
mkdir -p "$T/vbin"
for b in claude curl agent-call.sh; do
  printf '#!/bin/bash\necho %s >> "%s/vendor-calls"\nexit 0\n' "$b" "$T" > "$T/vbin/$b"; chmod +x "$T/vbin/$b"
done
RC=$(env -u ARCHIE_REPLAY_MODEL_CMD PATH="$T/vbin:$PATH" "$RUNNER" > "$T/out" 2>&1; echo $?)
[ "$RC" = 0 ] && [ ! -e "$T/vendor-calls" ] && tail -1 "$T/out" | grep -q ', 0 failed$' && ok \
  || bad "R11 default model: rc=$RC vendor=$(cat "$T/vendor-calls" 2>/dev/null) $(tail -3 "$T/out")"

# --- R12 the sync deploys orchestrator skills without replays -------------------
mkdir -p "$T/orc/.claude/skills/unowned"; echo keep > "$T/orc/.claude/skills/unowned/SKILL.md"
HARNESS_CHECKOUT="$DIR" SKILLS_SUBDIR=orchestrator/skills CLAUDE_SKILLS_DIR="$T/orc/.claude/skills" \
  HARNESS_LOG_DIR="$T" "$DIR/bin/sync-skills.sh" > "$T/out" 2>&1
for S in $FIVE; do [ -f "$T/orc/.claude/skills/$S/SKILL.md" ] || bad "R12 $S not deployed: $(cat "$T/out")"; done
[ -z "$(find "$T/orc/.claude/skills" -name replays)" ] && ok || bad "R12 replays/ was deployed"
[ "$(cat "$T/orc/.claude/skills/unowned/SKILL.md")" = keep ] && ok || bad "R12 unowned skill did not survive"
[ ! -e "$T/orc/.claude/skills/README.md" ] && ok || bad "R12 README.md deployed as a skill"

# --- R13 the harness-sync wiring, driven from the real line ------------------------
LINE=$(awk '/^# >>> orchestrator skills/{f=1;next} /^# <<< orchestrator skills/{f=0} f' "$DIR/bin/harness-sync.sh" | grep -v '^#')
if [ -n "$LINE" ] && grep -q 'sync-skills.sh' <<<"$LINE"; then
  mkdir -p "$T/h/bin" "$T/h/logs" "$T/orc13"; cp "$DIR/bin/sync-skills.sh" "$T/h/bin/"
  ( HARNESS="$T/h" CHECKOUT="$DIR" ORCHESTRATOR_DIR="$T/orc13"; eval "$LINE" ) >/dev/null 2>&1
  for S in $FIVE; do [ -f "$T/orc13/.claude/skills/$S/SKILL.md" ] || bad "R13 $S not deployed by the harness-sync line"; done
  grep -q "skills synced: 5 deployed, 0 skipped -> $T/orc13/.claude/skills" "$T/h/logs/agent-rules.log" 2>/dev/null && ok \
    || bad "R13 log line missing: $(cat "$T/h/logs/agent-rules.log" 2>/dev/null)"
  BEFORE=$(find "$T" | sort | md5sum)
  ( HARNESS="$T/h" CHECKOUT="$DIR" ORCHESTRATOR_DIR="$T/absent13"; eval "$LINE" ) >/dev/null 2>&1
  [ "$(find "$T" | sort | md5sum)" = "$BEFORE" ] && ok || bad "R13 absent orchestrator dir still wrote something"
  # the default destination is /root/orchestrator, never ~/.claude/skills
  grep -q 'ORCHESTRATOR_DIR:-/root/orchestrator}/.claude/skills' <<<"$LINE" && ok || bad "R13 default destination"
else bad "R13 no orchestrator skills block in bin/harness-sync.sh"; fi

# --- R14 fleet path -------------------------------------------------------------------
FP=$(awk '/^POOL_EXEMPT_PATHS=/{print;next} /^is_pool_exempt\(\)|^is_fleet_path\(\)/{f=1} f{print} f&&/^}/{f=0}' "$DIR/bin/fleet-propagate.sh")
if ( . "$DIR/bin/lib/fleet-paths.sh" || exit 1; eval "$FP"; is_fleet_path orchestrator/skills/brief-operator/SKILL.md && is_pool_exempt orchestrator/skills/brief-operator/SKILL.md \
     && is_fleet_path bin/x.sh && ! is_pool_exempt bin/x.sh && is_pool_exempt catalog/x.json ); then ok
else bad "R14 orchestrator/ is not a pool-exempt fleet path"; fi

# --- R15 De-AI check on brief-operator sends --------------------------------------------
NS=0
for C in "$SKILLS"/brief-operator/replays/*/; do
  grep -qx 'VERDICT: send' "$C/expected" || continue
  NS=$((NS+1)); R="$C/recorded.txt"
  L1=$(head -1 "$R")
  { [ -n "$L1" ] && ! grep -q 'https://' <<<"$L1"; } || bad "R15 $(basename "$C"): first line must be the recommendation, before any link"
  grep -q 'https://' "$R" || bad "R15 $(basename "$C"): no direct link"
  [ "$(grep -o ' — ' "$R" | wc -l)" -le 1 ] || bad "R15 $(basename "$C"): more than one em dash"
done
[ "$NS" -ge 1 ] && ok || bad "R15 brief-operator has no send case"

# --- R16 no model strings -------------------------------------------------------------
if grep -rEn 'claude-(opus|sonnet|haiku|fable)' "$SKILLS" "$RUNNER" 2>/dev/null; then bad "R16 model id string found"; else ok; fi

echo "archie-skill-replays: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
