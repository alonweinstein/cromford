#!/bin/bash
# tests/inapp-deps-contract.bh-3962-test.sh — BH-3962 (BH-3946.0): the in-app
# text-dependency lib skeleton and its three production hook points.
#
# The contract slice ships STUBS: bin/lib/inapp-deps.sh, its part files
# bin/lib/inapp-deps/core.sh and bin/lib/inapp-deps/release.sh, and the hooks
# in bin/triage-gate.sh (buildable arm, step 1e) and bin/lib/rt/scope.sh
# (inapp_released_lines). What this suite pins:
#   C1-C2b  the lib: nine public functions, no side effect at source, the exact
#           stub answers, the D43 root rule, the switch and the knob fallbacks.
#   C3      the REAL `triage-gate.sh x-os --buildable <id>`: with the stubs the
#           answer is byte-for-byte the no-lib answer; a mutated core.sh stub
#           IS the answer (so the hook is wired), except under the switch, on a
#           board that served `blocked`, and on a GitHub-Issues project.
#   C4      the REAL plain `triage-gate.sh x-os`: the stubs never print
#           `RUN inapp-deps-ready`; a mutated release.sh gate does, except under
#           the switch; a stale ready file is deleted unread.
#   C5      the REAL bin/run-triage.sh on a `RUN inapp-deps-ready` tick: the
#           tick is scoped (the reason is in scope.sh's lists), the stubs add no
#           line, a mutated inapp_deps_take_lines line reaches the prompt LAST,
#           and the switch drops it.
#   C6      _ts_enforce_reason (bin/lib/triage-state.sh) enforces on the reason.
# No network, no model.
# Run from anywhere: tests/inapp-deps-contract.bh-3962-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
FIX="$DIR/tests/fixtures/triage-gate-dependencies"
LIB="$DIR/bin/lib/inapp-deps.sh"
CORE="$DIR/bin/lib/inapp-deps/core.sh"
REL="$DIR/bin/lib/inapp-deps/release.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "inapp-deps-contract: jq missing, cannot run" >&2; exit 1; }
for f in "$LIB" "$CORE" "$REL"; do
  [ -r "$f" ] || { echo "inapp-deps-contract: missing $f" >&2; exit 1; }
done

mkdir -p "$T/bin/lib" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/fixture"

# ── the scratch harness (the shape of tests/triage-gate-buildable-deps.bh-900-test.sh)
cp "$DIR/bin/triage-gate.sh" "$T/bin/triage-gate.sh"
cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
cp "$DIR/bin/board-fetch.sh" "$T/bin/board-fetch.sh"
chmod +x "$T/bin/triage-gate.sh" "$T/bin/board-fetch.sh"

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  ghproj)
    case "${2:-}" in
      repo) echo "example-org/ghproj" ;;
      board_prefix|*) echo "-" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; FMT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -w) shift; FMT="\${1:-}" ;;
    -H) shift; : ;;
    -m) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
BODY="BOARD-FETCH stub: no route for \$URL"; HTTP="404"
case "\$URL" in
  */tickets/*)
    F="$T/fixture/ticket-\${URL##*/tickets/}.json"
    if [ -f "\$F" ]; then HTTP="200"; BODY=\$(cat "\$F"); fi
    ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s' "\$BODY"; fi
printf '%s' "\$FMT" | sed "s/%{http_code}/\$HTTP/g"
EOC
chmod +x "$T/bin/curl"
printf '#!/bin/bash\nexit 99\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"

export HARNESS="$T"
export PATH="$T/bin:$PATH"

# lib_on / lib_off / lib_mutate <part> <function> <output> — what $T/bin/lib holds.
lib_off() { rm -rf "$T/bin/lib/inapp-deps.sh" "$T/bin/lib/inapp-deps"; }
lib_on() {
  lib_off
  mkdir -p "$T/bin/lib/inapp-deps"
  cp "$LIB" "$T/bin/lib/inapp-deps.sh"
  cp "$CORE" "$REL" "$T/bin/lib/inapp-deps/"
}
lib_mutate() { # appends a redefinition, so the rest of the part file stays real
  printf '\n%s() { printf "%%s\\n" %q; }\n' "$2" "$3" >> "$T/bin/lib/inapp-deps/$1"
}
serve() { # serve <id> <list-fixture> [jq-mutation]
  jq -c --argjson id "$1" ".tickets[] | select(.id == \$id) ${3:+| $3}" "$FIX/$2" \
    > "$T/fixture/ticket-$1.json" || { bad "serve $1 $2 ${3:-}"; return 1; }
}
bgate() { bash "$T/bin/triage-gate.sh" "$1" "$2" "$3" 2>/dev/null; }

# ── C1. sourcing defines the nine functions, prints nothing, creates nothing ──
lib_on
touch "$T/marker"; sleep 1
C1=$( ( out=$(. "$T/bin/lib/inapp-deps.sh" 2>&1); printf '[%s]' "$out"
        for f in inapp_deps_on inapp_deps_state_dir inapp_deps_ready_file inapp_deps_lines \
                 inapp_deps_eval inapp_deps_buildable inapp_deps_gate inapp_deps_take_lines \
                 inapp_deps_hold_check; do
          . "$T/bin/lib/inapp-deps.sh" >/dev/null 2>&1
          declare -F "$f" >/dev/null || printf ' missing:%s' "$f"
        done ) )
[ "$C1" = "[]" ] && ok || bad "C1 sourcing must print nothing and define all nine: $C1"
NEW=$(find "$T/state" "$T/flags" "$T/logs" -newer "$T/marker" 2>/dev/null)
[ -z "$NEW" ] && ok || bad "C1 sourcing must create no file: $NEW"

# ── C1b / C1c / C1d. exact stub answers and the root rule ──────────────────
(
  . "$T/bin/lib/inapp-deps.sh"
  [ "$(inapp_deps_lines /dev/null "")" = "NONE" ] || echo "C1b lines: [$(inapp_deps_lines /dev/null "")]"
  [ "$(inapp_deps_eval x-os /dev/null /dev/null /dev/null)" = "$(printf 'VERDICT\tNONE\t\t\t')" ] \
    || echo "C1b eval: [$(inapp_deps_eval x-os /dev/null /dev/null /dev/null | od -c | head -2)]"
  o=$(inapp_deps_buildable "$T" x-os /dev/null 0); rc=$?
  [ -z "$o" ] && [ "$rc" = 0 ] || echo "C1b buildable: [$o] rc $rc"
  o=$(inapp_deps_gate "$T" x-os); rc=$?
  [ -z "$o" ] && [ "$rc" = 0 ] || echo "C1c gate: [$o] rc $rc"
  o=$(inapp_deps_take_lines "$T" x-os); rc=$?
  [ -z "$o" ] && [ "$rc" = 0 ] || echo "C1c take: [$o] rc $rc"
  [ "$(inapp_deps_hold_check /dev/null "")" = "unreadable" ] || echo "C1c hold_check: [$(inapp_deps_hold_check /dev/null "")]"
  [ "$(inapp_deps_state_dir "$T" x-os)" = "$T/state/inapp-deps/x-os" ] || echo "C1d state_dir: $(inapp_deps_state_dir "$T" x-os)"
  [ "$(inapp_deps_ready_file "$T" x-os)" = "$T/state/inapp-deps-ready-x-os" ] || echo "C1d ready_file: $(inapp_deps_ready_file "$T" x-os)"
  HARNESS="" H=""
  o=$(inapp_deps_state_dir "" x-os); rc=$?
  [ -z "$o" ] && [ "$rc" = 1 ] || echo "C1d empty-root state_dir: [$o] rc $rc"
  o=$(inapp_deps_ready_file "" x-os); rc=$?
  [ -z "$o" ] && [ "$rc" = 1 ] || echo "C1d empty-root ready_file: [$o] rc $rc"
  o=$(inapp_deps_ready_file "$T" ""); rc=$?
  [ -z "$o" ] && [ "$rc" = 1 ] || echo "C1d empty-project ready_file: [$o] rc $rc"
  [ "$(inapp_deps_on "")" = 0 ] || echo "C1d empty-root on: [$(inapp_deps_on "")]"
) > "$T/c1.out" 2>&1
[ -s "$T/c1.out" ] && bad "C1b-d: $(cat "$T/c1.out")" || ok

# ── C2. the kill switch ─────────────────────────────────────────────────────
rm -f "$T/flags/inapp-deps-off"
[ "$( . "$T/bin/lib/inapp-deps.sh"; inapp_deps_on "$T")" = 1 ] && ok || bad "C2 no switch must answer 1"
touch "$T/flags/inapp-deps-off"
[ "$( . "$T/bin/lib/inapp-deps.sh"; inapp_deps_on "$T")" = 0 ] && ok || bad "C2 flags/inapp-deps-off must answer 0"
rm -f "$T/flags/inapp-deps-off"

# ── C2b. knob fallbacks (no registry on the scratch box) ───────────────────
C2B=$( . "$T/bin/lib/inapp-deps.sh"; unset INAPP_DEPS_REMIND_S INAPP_DEPS_MAX_LOOKUPS
       _inapp_deps_knobs; echo "$INAPP_DEPS_REMIND_S $INAPP_DEPS_MAX_LOOKUPS" )
[ "$C2B" = "21600 10" ] && ok || bad "C2b fallbacks: [$C2B], want [21600 10]"
C2B=$( . "$T/bin/lib/inapp-deps.sh"; INAPP_DEPS_REMIND_S=abc INAPP_DEPS_MAX_LOOKUPS=-3
       _inapp_deps_knobs; echo "$INAPP_DEPS_REMIND_S $INAPP_DEPS_MAX_LOOKUPS" )
[ "$C2B" = "21600 10" ] && ok || bad "C2b non-integers reset: [$C2B], want [21600 10]"
C2B=$( . "$T/bin/lib/inapp-deps.sh"; INAPP_DEPS_REMIND_S=600 INAPP_DEPS_MAX_LOOKUPS=0
       _inapp_deps_knobs; echo "$INAPP_DEPS_REMIND_S $INAPP_DEPS_MAX_LOOKUPS" )
[ "$C2B" = "600 0" ] && ok || bad "C2b set values stand: [$C2B], want [600 0]"

# ── C3. the buildable arm, through the real CLI ────────────────────────────
serve 1826 tickets-old.json                                  # no `blocked` key
jq -c '.tickets[] | select(.id == 1826)' "$FIX/tickets-cap.json" > "$T/fixture/ticket-1828.json"  # blocked:false
jq -e '.blocked == false' "$T/fixture/ticket-1828.json" >/dev/null || bad "C3 fixture 1828 must carry blocked:false"
jq -e 'has("blocked") | not' "$T/fixture/ticket-1826.json" >/dev/null || bad "C3 fixture 1826 must carry no blocked key"
# A no-blocked ticket whose today answer is NOT OK, so "equal" is not OK==OK luck.
jq -c '.waitingOn = "client"' "$T/fixture/ticket-1826.json" > "$T/fixture/ticket-1829.json"

lib_off
BASE_1826=$(bgate x-os --buildable 1826)
BASE_1828=$(bgate x-os --buildable 1828)
BASE_1829=$(bgate x-os --buildable 1829)
BASE_S1826=$(bgate x-os --buildable-strict 1826)
BASE_GH=$(bgate ghproj --buildable 1)
[ "$BASE_1826" = OK ] && [ "$BASE_1829" = "BLOCKED waitingOn=client" ] && ok \
  || bad "C3 baselines: 1826=[$BASE_1826] 1829=[$BASE_1829]"

lib_on
[ "$(bgate x-os --buildable 1826)" = "$BASE_1826" ] && ok || bad "C3 stub 1826: [$(bgate x-os --buildable 1826)] want [$BASE_1826]"
[ "$(bgate x-os --buildable 1829)" = "$BASE_1829" ] && ok || bad "C3 stub 1829: [$(bgate x-os --buildable 1829)] want [$BASE_1829]"
[ "$(bgate x-os --buildable 1828)" = "$BASE_1828" ] && ok || bad "C3 stub 1828: [$(bgate x-os --buildable 1828)] want [$BASE_1828]"
[ "$(bgate x-os --buildable-strict 1826)" = "$BASE_S1826" ] && ok || bad "C3 stub strict: [$(bgate x-os --buildable-strict 1826)] want [$BASE_S1826]"
LEFT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'inapp-deps-raw.*' -newer "$T/marker" 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "C3 the raw-ticket temp file must be removed: $LEFT"

# D1: the hook is wired — a stub that answers IS the answer.
lib_mutate core.sh inapp_deps_buildable "BLOCKED dependencies TK-12"
[ "$(bgate x-os --buildable 1826)" = "BLOCKED dependencies TK-12" ] && ok \
  || bad "C3 mutated stub must be the answer: [$(bgate x-os --buildable 1826)]"
[ "$(bgate x-os --buildable 1829)" = "BLOCKED dependencies TK-12" ] && ok \
  || bad "C3 the arm runs before waitingOn: [$(bgate x-os --buildable 1829)]"
[ "$(bgate x-os --buildable 1828)" = "$BASE_1828" ] && ok \
  || bad "C3 blocked:false must not consult the arm: [$(bgate x-os --buildable 1828)] want [$BASE_1828]"
[ "$(bgate ghproj --buildable 1)" = "OK" ] && [ "$BASE_GH" = "OK" ] && ok \
  || bad "C3 a GitHub-Issues project answers OK: [$(bgate ghproj --buildable 1)]"
touch "$T/flags/inapp-deps-off"
[ "$(bgate x-os --buildable 1826)" = "$BASE_1826" ] && ok \
  || bad "C3 the switch makes the arm inert: [$(bgate x-os --buildable 1826)]"
rm -f "$T/flags/inapp-deps-off"
# Multi-line stub output: the gate's one-line contract holds.
lib_on
printf '\ninapp_deps_buildable() { printf "BLOCKED dependencies A\\nsecond line\\n"; }\n' >> "$T/bin/lib/inapp-deps/core.sh"
[ "$(bgate x-os --buildable 1826)" = "BLOCKED dependencies A" ] && ok \
  || bad "C3 only the first stub line is the answer: [$(bgate x-os --buildable 1826)]"
# A printed answer with a nonzero rc is still the answer (a launch gate must not
# fail open on an error-shaped return), plain and strict.
lib_on
printf '\ninapp_deps_buildable() { printf "BLOCKED unreadable\\n"; return 1; }\n' >> "$T/bin/lib/inapp-deps/core.sh"
[ "$(bgate x-os --buildable 1826)" = "BLOCKED unreadable" ] && ok \
  || bad "C3 a printed line with rc 1 must be the answer: [$(bgate x-os --buildable 1826)]"
[ "$(bgate x-os --buildable-strict 1826)" = "BLOCKED unreadable" ] && ok \
  || bad "C3 strict: a printed line with rc 1 must be the answer: [$(bgate x-os --buildable-strict 1826)]"
# More output than a pipe holds: the first line still answers, nothing is erased.
lib_on
printf '\ninapp_deps_buildable() { printf "BLOCKED dependencies BIG\\n"; seq 1 100000; }\n' >> "$T/bin/lib/inapp-deps/core.sh"
[ "$(bgate x-os --buildable-strict 1826)" = "BLOCKED dependencies BIG" ] && ok \
  || bad "C3 a long output must keep its first line: [$(bgate x-os --buildable-strict 1826)]"
# Nonzero rc with nothing printed still falls through to today's answer.
lib_on
printf '\ninapp_deps_buildable() { return 1; }\n' >> "$T/bin/lib/inapp-deps/core.sh"
[ "$(bgate x-os --buildable 1826)" = "$BASE_1826" ] && ok \
  || bad "C3 rc 1 with no output falls through: [$(bgate x-os --buildable 1826)] want [$BASE_1826]"

# ── C4. step 1e, through the real plain gate ───────────────────────────────
pgate() { bash "$T/bin/triage-gate.sh" x-os 2>/dev/null; }
lib_off
BASE_P=$(pgate)
[ "$BASE_P" != "RUN inapp-deps-ready" ] && ok || bad "C4 the no-lib baseline cannot be the new reason"
lib_on
STUB_P=$(pgate)
[ "$STUB_P" = "$BASE_P" ] && ok || bad "C4 stub plain answer [$STUB_P], want [$BASE_P]"
lib_mutate release.sh inapp_deps_gate "TK-12"
[ "$(pgate)" = "RUN inapp-deps-ready" ] && ok || bad "C4 mutated gate must answer RUN inapp-deps-ready: [$(pgate)]"
touch "$T/flags/inapp-deps-off"
[ "$(pgate)" = "$BASE_P" ] && ok || bad "C4 the switch makes 1e inert: [$(pgate)] want [$BASE_P]"
rm -f "$T/flags/inapp-deps-off"
# stale ready file: deleted unread on a stub run; a fresh one stays.
lib_on
RF="$T/state/inapp-deps-ready-x-os"
echo TK-1 > "$RF"; touch -d "@$(( $(date +%s) - 21601 ))" "$RF"
pgate >/dev/null
[ ! -e "$RF" ] && ok || bad "C4 a ready file older than INAPP_DEPS_REMIND_S must be deleted"
echo TK-1 > "$RF"
pgate >/dev/null
[ -e "$RF" ] && ok || bad "C4 a fresh ready file must be left for the scope"
rm -f "$RF"

# ── C5. the scope hook, through the real bin/run-triage.sh ─────────────────
# (the shape of tests/run-triage-inapp-release.bh-901-test.sh)
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
echo "SOP for x-os. Fetch the thread. Do the work." > "$H/prompts/x-os.md"
cat > "$T/fleet.conf" <<'EOC'
x-os   example-org/x-os    https://board.example  /api/board  2 box-1 10.0.0.1
EOC
sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
printf '#!/bin/sh\necho box-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
printf '%s %s\n' "\$1" "\${2:-}" >> "$H/gate-calls.log"
cp "$H/fixture/fp.json" "$H/state/\$1.gate.pending" 2>/dev/null
[ "\${2:-}" = "--pending" ] && exit 0
[ "\${2:-}" = "--buildable" ] && { echo OK; exit 0; }
echo "RUN inapp-deps-ready"
STUB
sed -e "s|/root/harness|$H|g" "$DIR/bin/gate-diff.sh" > "$H/bin/gate-diff.sh"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$H/bin/unblocked-children.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/decompose-parent-close.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H"/bin/*.sh
FP=$(jq -cS '[.tickets[] | {id,status,waitingOn,triageVerdict,commentCount,lastActivityAt,title}] | sort_by(.id) | {b1: .}' "$FIX/tickets-null.json")
printf '%s' "$FP" > "$H/fixture/fp.json"

hlib_off() { scratch_rm "$H/bin/lib/inapp-deps.sh"; scratch_rm "$H/bin/lib/inapp-deps"; }
hlib_on() {
  hlib_off; mkdir -p "$H/bin/lib/inapp-deps"
  cp "$LIB" "$H/bin/lib/inapp-deps.sh"; cp "$CORE" "$REL" "$H/bin/lib/inapp-deps/"
}
treset() {
  for d in "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds" "$H/gate-calls.log"; do scratch_rm "$d"; done
  mkdir -p "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  model_routes_fixture "$H" x-os || exit 1
  printf '%s' "$FP" > "$H/state/x-os.gate.json"
  : > "$H/logs/READY-QUEUE.log"
}
trun() { treset; HARNESS="$H" FLEET_CONF="$T/fleet.conf" CALLDIR="$T/calls" TRIAGE_SHARDS=0 \
           "$H/bin/run-triage.sh" x-os >/dev/null 2>&1; }
prompt() { cat "$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null; }
rel() { prompt | grep -E '^board [^:]+: (UNBLOCKED|REOFFER) ' || true; }
MUT='board 1: UNBLOCKED 40 "x"'

hlib_off; trun; P_OFF=$(prompt); R_OFF=$(rel)
[ -n "$P_OFF" ] && ok || bad "C5 the no-lib tick must produce a prompt"
grep -qx 'x-os --pending' "$H/gate-calls.log" 2>/dev/null && ok \
  || bad "C5 the reason must refresh the live fingerprint first (--pending): $(cat "$H/gate-calls.log" 2>/dev/null)"

hlib_on; trun
[ "$(rel)" = "$R_OFF" ] && ok || bad "C5 stub take_lines must add no line: [$(rel)] want [$R_OFF]"

hlib_on; lib_mutate_h() { printf '\n%s() { printf "%%s\\n" %q; }\n' "$1" "$2" >> "$H/bin/lib/inapp-deps/release.sh"; }
lib_mutate_h inapp_deps_take_lines "$MUT"
trun
[ "$(rel | tail -n1)" = "$MUT" ] && ok || bad "C5 the mutated take line must be the last release line: [$(rel)]"
# An unchanged board with a release line is a scoped tick (the reason is in
# scope.sh's board/queue arm), not the full SOP.
grep -q '^TICK SCOPE (deterministic' <<<"$(prompt)" && ok \
  || bad "C5 a RUN inapp-deps-ready tick with a line must be scoped: $(prompt | head -2)"
touch "$H/flags/inapp-deps-off"; trun
grep -qF "$MUT" <<<"$(prompt)" && bad "C5 the switch makes the scope hook inert" || ok
rm -f "$H/flags/inapp-deps-off"

# ── C6. triage-state enforces on the reason ────────────────────────────────
( . "$DIR/bin/lib/triage-state.sh" 2>/dev/null; GATE_REASON=inapp-deps-ready; _ts_enforce_reason ) && ok \
  || bad "C6 _ts_enforce_reason must accept inapp-deps-ready"
( . "$DIR/bin/lib/triage-state.sh" 2>/dev/null; GATE_REASON=inapp-deps; _ts_enforce_reason ) \
  && bad "C6 a near-miss reason must not be enforced" || ok

echo "inapp-deps-contract.bh-3962: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
