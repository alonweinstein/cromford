#!/bin/bash
# tests/preplan-skip-small.p2-test.sh — P2: a pre-plan is not bought when it
# adds nothing (bin/lib/preplan-lib.sh:preplan_small_reason).
# Run from anywhere: tests/preplan-skip-small.p2-test.sh   (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. Seven days of cost rows (2026-09-25): preplan $4.4K
# ran ON TOP OF plan $6.5K. A pre-plan buys latency, never correctness — the
# build's PLAN stage plans from scratch whenever no fresh pre-plan is there. So
# for a ticket where the pre-plan saves nothing the session is pure spend:
#   - triage sized it S (`size=S` on its READY-QUEUE line): a small plan is a
#     few minutes of the build's own PLAN stage, and the pre-plan of it costs
#     the same session twice when the build starts before it lands;
#   - it is copy/docs work (`kind=copy|docs` on the queue line, or the board's
#     own title prefix read through bin/kind-gate.sh's vocabulary);
#   - its build is ALREADY RUNNING, so its PLAN stage is planning it right now.
# The decision is deterministic, knob-gated (PREPLAN_SKIP_SMALL, a settings row
# on the preplan-tick lane, default 1), logged once per key, and made at BOTH
# the tick (saves the slot) and the choke point in bin/run-preplan.sh (saves the
# money on a launch that came from anywhere else).
#
# The integration half drives the REAL bin/preplan-tick.sh and counts what it
# launched, because "the skip is in the code" and "the session was not bought"
# are two different claims.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the launch, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/plans" \
         "$T/state" "$T/prompts" "$T/repos/proj"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh kind-gate.sh; do
  cp "$DIR/bin/$f" "$T/bin/"
done
: > "$T/env/global.env"
. "$T/bin/lib/preplan-lib.sh"

command -v preplan_small_reason >/dev/null 2>&1 && ok \
  || { bad "bin/lib/preplan-lib.sh must define preplan_small_reason"; echo "preplan-skip-small.p2: $PASS passed, $FAIL failed"; exit 1; }

q() { printf '%s\n' "$@" > "$T/logs/READY-QUEUE.log"; }
skip() { preplan_small_reason "$T" proj "$1" "${2:-}" >/dev/null 2>&1; }
why()  { preplan_small_reason "$T" proj "$1" "${2:-}" 2>/dev/null; }

# --- A. the decision --------------------------------------------------------
q 'AB-1 1 — ready project=proj size=S'
skip AB-1 && ok || bad "A1 a queue line carrying size=S (triage's size) must skip the pre-plan"
case "$(why AB-1)" in *size=S*) ok ;; *) bad "A1 the reason must name the size (got: $(why AB-1))" ;; esac

q 'AB-1 1 — ready project=proj size=M'
skip AB-1 && bad "A2 size=M must NOT skip — only S is small" || ok
q 'AB-1 1 — ready project=proj SIZE: XS'
skip AB-1 && ok || bad "A2 'SIZE: XS' is small too"
q 'AB-1 1 — ready project=proj resize=S'
skip AB-1 && bad "A2 'resize=S' is not a size token (word boundary)" || ok
q 'AB-1 1 — ready project=proj'
skip AB-1 && bad "A2 a line with no size/kind token must pre-plan as today" || ok

q 'AB-1 1 — ready project=proj kind=copy'
skip AB-1 && ok || bad "A3 kind=copy must skip"
q 'AB-1 1 — ready project=proj kind=Copy'
skip AB-1 && ok || bad "A3 kind=Copy (any case) must skip"
# S6 (#2294 review): the tag vocabulary is EXACTLY the one the triage contract
# prints — bug|feature|copy|migration|infra, the KIND set bin/kind-gate.sh
# settles on. `docs` is not in it (docs work is KIND copy), so a line nobody's
# prompt would write is not a second spelling this lib quietly honours.
grep -q "kind=<bug|feature|copy|migration|infra>" "$DIR/catalog/agent-contracts/triage-system-append.txt" && ok \
  || bad "A3 S6 the triage contract must name the kind= tag vocabulary bug|feature|copy|migration|infra"
q 'AB-1 1 — ready project=proj kind=docs'
skip AB-1 && bad "A3 S6 kind=docs is outside the tag vocabulary the prompt writes, so it is not a skip" || ok
q 'AB-1 1 — ready project=proj kind=feature size=L'
skip AB-1 && bad "A3 kind=feature size=L must pre-plan" || ok

# A4 the knob and the flag
q 'AB-1 1 — ready project=proj size=S'
PREPLAN_SKIP_SMALL=0 preplan_small_reason "$T" proj AB-1 >/dev/null 2>&1 \
  && bad "A4 PREPLAN_SKIP_SMALL=0 must turn the skip off" || ok
printf 'PREPLAN_SKIP_SMALL=0\n' > "$T/env/global.env"
skip AB-1 && bad "A4 PREPLAN_SKIP_SMALL=0 in env/global.env must turn the skip off" || ok
: > "$T/env/global.env"
touch "$T/flags/preplan-skip-small-off"
skip AB-1 && bad "A4 flags/preplan-skip-small-off must turn the skip off" || ok
rm -f "$T/flags/preplan-skip-small-off"
skip AB-1 && ok || bad "A4 with the flag gone the skip is back"
[ "$(preplan_skip_small_on "$T")" = 1 ] && ok || bad "A4 the knob defaults ON (got: $(preplan_skip_small_on "$T"))"

# A5 a build already running for this key
q 'AB-9 9 — ready project=proj size=L'
skip AB-9 "$(printf 'AB-3\nAB-9\n')" && ok || bad "A5 a key that is mid-build must not be pre-planned"
case "$(why AB-9 "$(printf 'AB-9\n')")" in *build*) ok ;; *) bad "A5 the reason must say a build is running (got: $(why AB-9 AB-9))" ;; esac
skip AB-9 "$(printf 'AB-90\n')" && bad "A5 AB-90 building is not AB-9 building (exact key match)" || ok

# A6 the board's own title prefix (in-app board: gate.json + keymap)
q 'AB-4 44 — ready project=proj'
printf '{"b1":[{"id":"44","title":"Docs: update the FAQ page","status":"open"},{"id":"45","title":"Fix: header overlaps","status":"open"}]}' > "$T/state/proj.gate.json"
printf '{"44":"AB-4","AB-4":"44","45":"AB-5","AB-5":"45"}' > "$T/state/proj.keymap.json"
skip AB-4 && ok || bad "A6 a board title 'Docs: …' reads as KIND copy (bin/kind-gate.sh vocabulary) and must skip"
case "$(why AB-4)" in *copy*) ok ;; *) bad "A6 the reason must name the kind (got: $(why AB-4))" ;; esac
skip AB-5 && bad "A6 'Fix: …' is a bug, which is exactly what gets a plan" || ok

# A7 GitHub-Issues board: key suffix is the issue number
rm -f "$T/state/proj.keymap.json"
printf '{"issues":[{"number":7,"title":"copy: tweak the hero line","state":"OPEN"}],"prs":[]}' > "$T/state/proj.gate.json"
q ''
skip AB-7 && ok || bad "A7 a GitHub-Issues title 'copy: …' must skip"
skip AB-8 && bad "A7 an issue the fingerprint does not hold must pre-plan (fail-open)" || ok

# A8 nothing readable at all fails OPEN (pre-plans as today)
rm -f "$T/state/proj.gate.json" "$T/logs/READY-QUEUE.log"
skip AB-1 && bad "A8 no queue line, no fingerprint: the lane must pre-plan as it did" || ok

# --- B. the real tick launches only what is worth buying ---------------------
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-name.sh"
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tqueued\nAB-2\t2\tqueued\n'
SH
cat > "$T/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$3" >> "$HARNESS/launched.txt"
SH
# I1 (#2294 review): a skipped key must still leave the file list dep-verify,
# overlap-guard, overlap-schedule and train.sh read. The stub stands in for the
# real bin/planned-files-cheap.sh (section D pins that one) and records whether
# it was told to stay on the free tiers.
PFC='#!/bin/bash
echo "$1 $2 free=${PLANNED_FILES_FREE_ONLY:-0}" >> "$HARNESS/pfc.txt"
mkdir -p "$HARNESS/plans/$1-$2" && printf "SOURCE: ticket-body\nsrc/a.ts\n" > "$HARNESS/plans/$1-$2/planned-files.txt"'
printf '%s\n' "$PFC" > "$T/bin/planned-files-cheap.sh"
# jobs-client is optional to the lib; an absent one is "no ledger rows".
chmod +x "$T/bin/box-name.sh" "$T/bin/preplan-candidates.sh" "$T/bin/run-preplan.sh" "$T/bin/planned-files-cheap.sh"
( cd "$T/repos/proj" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo x > a && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
q 'AB-1 1 — ready project=proj size=S' 'AB-2 2 — ready project=proj size=L'
: > "$T/launched.txt"; : > "$T/logs/preplan.log"
tick() { PREPLAN_PARALLEL=3 bash "$T/bin/preplan-tick.sh" >/dev/null 2>&1; sleep 0.3; }
tick; wait_for 10 grep -qx AB-2 "$T/launched.txt"
grep -qx AB-2 "$T/launched.txt" && ok || bad "B1 the size=L ticket must still be pre-planned (launched: $(tr '\n' ' ' < "$T/launched.txt"))"
grep -qx AB-1 "$T/launched.txt" && bad "B1 the size=S ticket must NOT be pre-planned" || ok
grep -q '\[proj/AB-1\] PREPLAN_SKIP small' "$T/logs/preplan.log" && ok \
  || bad "B2 the skip must be logged with its reason (log: $(tail -3 "$T/logs/preplan.log"))"
[ -s "$T/plans/proj-AB-1/planned-files.txt" ] && ok \
  || bad "B5 I1: after a skip the key still has plans/<p>-<KEY>/planned-files.txt (dep-verify/overlap-guard read it)"
grep -qx 'proj AB-1 free=1' "$T/pfc.txt" 2>/dev/null && ok \
  || bad "B5 I1: the skip runs planned-files-cheap.sh on its FREE tiers only (got: $(cat "$T/pfc.txt" 2>/dev/null))"
[ -e "$T/plans/proj-AB-1/plan.md" ] && bad "B5 the list is not a plan: no plan.md a build could adopt" || ok
tick
N=$(grep -c '\[proj/AB-1\] PREPLAN_SKIP small' "$T/logs/preplan.log")
[ "$N" = 1 ] && ok || bad "B3 the skip line is written once per key, not once per tick (got $N)"
N=$(grep -c 'AB-1' "$T/pfc.txt" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "B3 the file list is built once per key, not every tick (got ${N:-0} runs)"
PREPLAN_SKIP_SMALL=0 bash "$T/bin/preplan-tick.sh" >/dev/null 2>&1; wait_for 10 grep -qx AB-1 "$T/launched.txt"
grep -qx AB-1 "$T/launched.txt" && ok || bad "B4 with the knob off the tick pre-plans the S ticket as it always did"

# --- C. the choke point in bin/run-preplan.sh -------------------------------
# The REAL lane, with the billable call stubbed and counted (the bh-580 shape).
C="$T/c"; mkdir -p "$C/bin/lib" "$C/env" "$C/flags" "$C/logs" "$C/plans" "$C/locks" "$C/repos/proj"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$C" proj || exit 1
cp "$DIR/bin/run-preplan.sh" "$C/bin/"
cp "$DIR/bin/lib/preplan-lib.sh" "$C/bin/lib/"
cp "$DIR/bin/kind-gate.sh" "$C/bin/"
: > "$C/env/global.env"
cat > "$C/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "${CALLS:?}"
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$C/bin/git"
printf '%s\n' "$PFC" > "$C/bin/planned-files-cheap.sh"
chmod +x "$C/bin/agent-call.sh" "$C/bin/git" "$C/bin/planned-files-cheap.sh"
printf 'AB-1 1 — ready project=proj size=S\nAB-2 2 — ready project=proj size=M\n' > "$C/logs/READY-QUEUE.log"
lane() { PATH="$C/bin:$PATH" CALLS="$C/calls.txt" HARNESS="$C" REPOS_ROOT="$C/repos" \
           bash "$C/bin/run-preplan.sh" proj 1 "$1" >/dev/null 2>&1; }
: > "$C/calls.txt"
lane AB-1; RC=$?
[ "$RC" = 0 ] && ok || bad "C1 a small-skipped pre-plan is a DECISION: rc 0 (got $RC)"
[ -s "$C/calls.txt" ] && bad "C1 the size=S key must not reach agent-call.sh (calls: $(cat "$C/calls.txt"))" || ok
[ -e "$C/plans/proj-AB-1/plan.md" ] && bad "C2 a skipped pre-plan leaves no plan.md a build could adopt" || ok
[ -s "$C/plans/proj-AB-1/planned-files.txt" ] && ok \
  || bad "C2 I1: the choke point's skip also leaves planned-files.txt"
grep -qx 'proj AB-1 free=1' "$C/pfc.txt" 2>/dev/null && ok || bad "C2 I1: on the free tiers only (got: $(cat "$C/pfc.txt" 2>/dev/null))"
grep -q '\[proj/AB-1\] PREPLAN_SKIP small' "$C/logs/preplan.log" 2>/dev/null && ok \
  || bad "C3 the choke point logs its skip"
lane AB-2
grep -qx preplan "$C/calls.txt" && ok || bad "C4 a size=M key still reaches the billable call (calls: $(cat "$C/calls.txt"))"

# --- D. the REAL planned-files-cheap.sh stays on its free tiers when asked ---
# The skip is supposed to cost nothing. Tiers 1-2 (body paths, codegraph
# importers) are free; tier 3 is a model call. PLANNED_FILES_FREE_ONLY=1 must
# stop before tier 3, and must still write the list when tier 1 found paths.
D="$T/d"; mkdir -p "$D/bin/lib" "$D/env" "$D/logs" "$D/plans" "$D/state"
cp "$DIR/bin/planned-files-cheap.sh" "$D/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$D/bin/lib/"
cp "$DIR/bin/lib/preplan-lib.sh" "$D/bin/lib/"
: > "$D/env/global.env"
printf '#!/bin/bash\necho "$1" >> "$HARNESS/model-calls.txt"\nexit 0\n' > "$D/bin/agent-call.sh"
chmod +x "$D/bin/agent-call.sh" "$D/bin/planned-files-cheap.sh"
printf 'Make the header wording friendlier. No file named.\n' > "$D/body-none.txt"
printf 'Fix the label in src/lib/header.ts please.\n' > "$D/body-path.txt"
pfc() { HARNESS="$D" PLANNED_FILES_REPO="$D/norepo" PLANNED_FILES_MODEL=floor-model \
          PLANNED_FILES_BODY_FILE="$1" PLANNED_FILES_FREE_ONLY="${2:-1}" \
          bash "$D/bin/planned-files-cheap.sh" proj "$3" >/dev/null 2>&1; }
pfc "$D/body-none.txt" 1 AB-5
[ -e "$D/model-calls.txt" ] && bad "D1 free-only must never reach the tier-3 model call" || ok
pfc "$D/body-path.txt" 1 AB-6
grep -qx 'src/lib/header.ts' "$D/plans/proj-AB-6/planned-files.txt" 2>/dev/null && ok \
  || bad "D2 free-only still writes the tier-1 list (got: $(cat "$D/plans/proj-AB-6/planned-files.txt" 2>/dev/null))"
pfc "$D/body-none.txt" 0 AB-7
[ -s "$D/model-calls.txt" ] && ok || bad "D3 without free-only the script is unchanged: tier 3 is still asked"

echo "preplan-skip-small.p2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
