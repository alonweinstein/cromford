#!/bin/bash
# tests/run-decompose-labels.bh-637-test.sh — split children inherit the
# parent's labels (BH-637 §2).
#
# WHAT THIS PINS AND WHY. bin/run-decompose.sh filed every child with the
# literal `--label ai-build`. A parent carrying `ai-build,hotfix` therefore
# produced four ordinary children, so every consumer that selects on the hotfix
# label — the pre-plan order, the pool's spawn order, the dispatcher's pick, the
# merge lane — skipped them in silence and a human merged all four by hand. A
# split child is the same work as its parent and inherits its urgency with it.
#
# THE VOCABULARY IS A WHITELIST, never a copy of everything, and that is what
# most of this file asserts. `not-hotfix` is somebody saying this is NOT urgent
# and `hotfix-candidate` is somebody asking, so a substring or blanket copy
# would spend a cap exemption nobody granted. `bug` is out of the default set on
# purpose: bin/kind-gate.sh reads it as the KIND signal and bin/repro-gate.sh
# would then demand a reproduction from a contract child that is nothing but
# types.
#
# The REAL script is driven in its dry-run mode and the assertions are on the
# `gh issue create` command lines it prints and the lines it logs — never on its
# source.
#
# Run from anywhere: tests/run-decompose-labels.bh-637-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/lib/hotfix-lib.sh" "$T/h/bin/lib/" 2>/dev/null
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish  example-org/scoutish  https://scoutish.example  -  9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"
: > "$T/h/env/global.env"

SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow","after":[],"body":"Create the table.\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile.\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

# drive [meta-json] — a dry run of the real script. An empty first argument
# means NO ticket-meta.json in the build record, which is the resume/degrade
# shape. Extra arguments are env assignments.
drive() {
  local meta="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  [ -n "$meta" ] && printf '%s\n' "$meta" > "$T/b/ticket-meta.json"
  : > "$T/agent.log"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
        DECOMPOSE_DRY_RUN=1 "$@" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 )
}
creates() { grep '^DRYRUN gh issue create ' <<<"$1"; }

# ════════════════════════════════════════════════════════════════════════════
# 1. THE HOTFIX PARENT. Two children, both carrying the parent's urgency — and
#    nothing else the parent happens to be labelled with.
# ════════════════════════════════════════════════════════════════════════════
META='{"title":"parent","labels":[{"name":"ai-build"},{"name":"Hotfix"},{"name":"not-hotfix"},{"name":"hotfix-candidate"},{"name":"hotfixes"},{"name":"needs-design"},{"name":"bug"}]}'
OUT=$(drive "$META"); RC=$?
[ "$RC" = 0 ] && ok || bad "a clean dry run must exit 0 (rc=$RC): $OUT"
CR=$(creates "$OUT")
[ "$(grep -c . <<<"$CR")" = 2 ] && ok || bad "two children = two create commands (got: $OUT)"
N_OK=0
while IFS= read -r L; do
  case "$L" in *"--label ai-build --label hotfix "*) N_OK=$((N_OK+1)) ;; esac
done <<<"$CR"
[ "$N_OK" = 2 ] && ok \
  || bad "every child of a hotfix parent must be filed '--label ai-build --label hotfix' (got: $CR)"
# THE WHITELIST NEGATIVES: these are the names a substring or blanket copy gets
# wrong, and each one changes what the rest of the fleet does with the child.
for N in not-hotfix hotfix-candidate hotfixes needs-design bug; do
  grep -q -- "--label $N" <<<"$CR" \
    && bad "'$N' is not in the harness vocabulary and must never be copied to a child (got: $CR)" || ok
done
# and the applied set is LOGGED, per child, so a box can be grepped for it
grep -q 'child 1 labels: ai-build,hotfix' "$T/b/pipeline.log" \
  && ok || bad "the decomposer must log the label set it applied per child (got: $(cat "$T/b/pipeline.log" 2>/dev/null))"
grep -q 'child 2 labels: ai-build,hotfix' "$T/b/pipeline.log" \
  && ok || bad "the second child's label set must be logged too (got: $(cat "$T/b/pipeline.log" 2>/dev/null))"
grep -q 'inherited from parent #552' "$T/b/pipeline.log" \
  && ok || bad "the log line must name where the labels came from (got: $(cat "$T/b/pipeline.log" 2>/dev/null))"
# the command LOG the record keeps must say the same thing the run did
grep -q -- '--label ai-build --label hotfix ' "$T/b/decompose-gh.log" \
  && ok || bad "decompose-gh.log must record the real label args (got: $(cat "$T/b/decompose-gh.log" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
# 2. NO TICKET-META is not an error and not a guess: `ai-build` alone, logged.
#    (This is also the shape tests/run-decompose-issues-test.sh drives, whose
#    `--label ai-build` count of 3 must keep holding.)
# ════════════════════════════════════════════════════════════════════════════
OUT=$(drive ""); RC=$?
[ "$RC" = 0 ] && ok || bad "a run with no ticket-meta must still exit 0 (rc=$RC): $OUT"
CR=$(creates "$OUT")
[ "$(grep -c -- '--label' <<<"$CR")" = 2 ] && ok \
  || bad "with no parent labels each child gets exactly one --label (got: $CR)"
[ "$(grep -c -- '--label ai-build' <<<"$CR")" = 2 ] && ok \
  || bad "ai-build is applied whatever else happens — it IS the handoff (got: $CR)"
grep -q 'nothing inherited' "$T/b/pipeline.log" \
  && ok || bad "the log must say plainly that nothing was inherited (got: $(cat "$T/b/pipeline.log" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
# 3. THE OPERATOR LIST. `bug` is out of the default vocabulary; an operator who
#    wants it says so in env/global.env rather than editing a script.
# ════════════════════════════════════════════════════════════════════════════
printf 'DECOMPOSE_INHERIT_LABELS=bug, needs-design\n' > "$T/h/env/global.env"
OUT=$(drive '{"title":"p","labels":[{"name":"ai-build"},{"name":"bug"},{"name":"wontfix"}]}')
CR=$(creates "$OUT")
[ "$(grep -c -- '--label bug' <<<"$CR")" = 2 ] && ok \
  || bad "DECOMPOSE_INHERIT_LABELS=bug must put bug on every child (got: $CR)"
grep -q -- '--label wontfix' <<<"$CR" \
  && bad "a label outside the vocabulary must still not be copied (got: $CR)" || ok
: > "$T/h/env/global.env"

# ════════════════════════════════════════════════════════════════════════════
# 4. THE LABEL NAME IS A KNOB, not the literal `hotfix`: a fleet that renamed
#    HOTFIX_LABEL must inherit the name it actually uses.
# ════════════════════════════════════════════════════════════════════════════
printf 'HOTFIX_LABEL=urgent\n' > "$T/h/env/global.env"
OUT=$(drive '{"title":"p","labels":[{"name":"ai-build"},{"name":"urgent"},{"name":"hotfix"}]}')
CR=$(creates "$OUT")
[ "$(grep -c -- '--label urgent' <<<"$CR")" = 2 ] && ok \
  || bad "HOTFIX_LABEL=urgent must be the name that is inherited (got: $CR)"
grep -q -- '--label hotfix ' <<<"$CR" \
  && bad "with HOTFIX_LABEL=urgent the literal 'hotfix' is an ordinary label and must not be copied (got: $CR)" || ok
: > "$T/h/env/global.env"

# ════════════════════════════════════════════════════════════════════════════
# 5. A PARENT THAT NO LONGER CARRIES ai-build. This script takes the label off
#    the parent at the end of a split, so a RESUME reads a parent without it —
#    and must still file children a watcher can see.
# ════════════════════════════════════════════════════════════════════════════
OUT=$(drive '{"title":"p","labels":[{"name":"hotfix"}]}')
CR=$(creates "$OUT")
[ "$(grep -c -- '--label ai-build' <<<"$CR")" = 2 ] && ok \
  || bad "children must carry ai-build even when the parent has lost it (got: $CR)"
[ "$(grep -c -- '--label hotfix ' <<<"$CR")" = 2 ] && ok \
  || bad "and the hotfix label still comes across (got: $CR)"

# ════════════════════════════════════════════════════════════════════════════
# 6. A REAL RUN WITH NO TICKET-META asks GitHub once, rather than filing four
#    children that silently lost the lane their parent was in. This is the only
#    added GitHub call in the common path's fallback, so it is driven for real
#    (DECOMPOSE_DRY_RUN unset) against a recording stub — and a DRY run must
#    still never make it, because a dry run buys nothing.
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/fakebin"
export GH_CALLS="$T/gh.calls"; : > "$GH_CALLS"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
case "$1 $2" in
  "issue create") n=$(grep -c '^issue create' "$GH_CALLS"); echo "https://github.com/example-org/scoutish/issues/$((900+n))" ;;
  "issue view")   printf '{"labels":[{"name":"ai-build"},{"name":"hotfix"},{"name":"needs-design"}]}' ;;
  *)              echo '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\necho ghs_fresh\n' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"

rm -rf "$T/b"; mkdir -p "$T/b"
printf '%s\n' "$SPEC" > "$T/b/children.json"
printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
: > "$T/agent.log"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
         PATH="$T/fakebin:$PATH" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "a real run must exit 0 (rc=$RC): $OUT"
[ "$(grep -c '^issue view 552 .*--json labels' "$GH_CALLS")" = 1 ] && ok \
  || bad "with no ticket-meta a real run must read the parent's labels exactly once (got: $(cat "$GH_CALLS"))"
[ "$(grep -c '^issue create .*--label ai-build --label hotfix ' "$GH_CALLS")" = 2 ] && ok \
  || bad "the labels read from GitHub must reach the real create (got: $(cat "$GH_CALLS"))"
grep -q '^issue create .*--label needs-design' "$GH_CALLS" \
  && bad "the whitelist applies to the GitHub read too (got: $(cat "$GH_CALLS"))" || ok
grep -q 'read from GitHub' "$T/b/pipeline.log" \
  && ok || bad "the log must say the labels came from GitHub, not from the record (got: $(cat "$T/b/pipeline.log" 2>/dev/null))"

# and a DRY run with no ticket-meta buys nothing
: > "$GH_CALLS"
scratch_rm "$T/b"; mkdir -p "$T/b"
printf '%s\n' "$SPEC" > "$T/b/children.json"
printf 'SIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" PATH="$T/fakebin:$PATH" \
       DECOMPOSE_DRY_RUN=1 bash -c '"$1" scoutish 552 TK-552 "$2/b" 300 12' _ "$DEC" "$T" 2>&1 )
grep -q 'issue view' "$GH_CALLS" \
  && bad "a DRY run must never buy a label read (got: $(cat "$GH_CALLS"))" || ok

echo "run-decompose-labels.bh-637: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
