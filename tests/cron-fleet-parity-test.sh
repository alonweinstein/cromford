#!/bin/bash
# tests/cron-fleet-parity-test.sh — the registry and the crontabs describe the
# SAME fleet, and the checked-in cron/*.cron files are GENERATED artifacts.
#
# THE INCIDENT THIS PINS (2026-08-30). project-7 was onboarded onto
# box-project-6-1 with load-project.sh -> bootstrap-machine.sh, which
# installs its crons LIVE from fleet.conf. The next morning at 05:17
# update-runners.sh re-applied the REPO file cron/project-6.cron, which had
# never heard of project-7, and the seven lines vanished. The lane was dead for
# ten hours and nothing alerted, because nothing was broken: two writers, one
# deriving from the registry and one copying a hand-maintained file, and no
# reconciliation between them.
#
# So the assertions are about the RELATIONSHIP between the two planes:
#   a. every (project, box) row in fleet.conf has a triage lane in that box's
#      rendered crontab — the registry can never name a lane nobody runs;
#   b. render-crontab.sh <box> == cron/<box>.cron for every box — the files are
#      generated, so any difference is drift, and drift is what wiped the lane;
#   c. the renderer is idempotent — render(render(x)) == render(x), or the daily
#      tick would rewrite the crontab forever and every run would look like news;
#   d. everything OUTSIDE the managed markers survives byte-for-byte — the
#      renderer must be safe to point at a live crontab full of box-specific
#      lines it has never heard of.
#
# Run from anywhere: tests/cron-fleet-parity-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
RENDER="$DIR/bin/render-crontab.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$RENDER" ] || { echo "FAIL: bin/render-crontab.sh missing or not executable"; exit 1; }

# ---------------------------------------------------------------------------
# 0. the box-id mapping, in one place
# ---------------------------------------------------------------------------
# fleet.conf's box column holds HOSTNAMES (box-project-3-2); cron files are
# named by BOX ID (project-3). Nothing else in the fleet spells the relationship, so
# a second spelling of it is how the two planes drift apart again.
# shellcheck source=/dev/null
. "$DIR/bin/lib/cron-lines.sh"
while read -r IN WANT; do
  [ -n "$IN" ] || continue
  GOT=$(cron_box_id_for "$IN")
  [ "$GOT" = "$WANT" ] && ok || bad "cron_box_id_for '$IN' = '$GOT', expected '$WANT'"
done <<'EOF'
box-project-4-1 project-4
box-project-3-2 project-3
box-project-6-1 project-6
box-small small
box-project-10-1 project-10
local hub
box-hub hub
EOF

# ---------------------------------------------------------------------------
# 1. a fixture fleet: preservation, ordering, conditionals, idempotency
# ---------------------------------------------------------------------------
mkdir -p "$T/cron" "$T/prompts"
cat > "$T/fleet.conf" <<'EOF'
# fixture registry — same columns as the live one:
#   <project> <repo> <prod> <board-prefix> <cron-offset> [box]
alpha-os  Acme/alpha-os  https://alpha.example  /api/board  2 box-fix
beta      Acme/beta      -                      -           5 box-fix
gamma     Acme/gamma     https://gamma.example  -           7 box-other
EOF
# alpha has a product prompt, beta does not: run-product.sh ALERTS and exits 1
# when prompts/product-<project>.md is missing, so an unconditional weekly line
# is a guaranteed Monday alert forever.
: > "$T/prompts/product-alpha-os.md"

# A base crontab full of lines the renderer has never heard of, in an awkward
# order, with one project line buried in the middle of them.
cat > "$T/cron/fix.cron" <<'EOF'
SHELL=/bin/bash
# a hand comment that must survive
@reboot /usr/sbin/sshd
*/5 * * * * /root/harness/bin/watchdog-ping.sh box-fix
2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os
17 5 * * * /root/harness/bin/update-runners.sh
0 14 * * 0 /root/harness/bin/security-scan.sh alpha-os
58 * * * * /root/harness/bin/extra-usage-track.sh fix >/dev/null 2>&1
EOF
R1="$T/r1"; "$RENDER" --root "$T" fix > "$R1" 2>"$T/err1"
[ -s "$R1" ] && ok || bad "renderer produced nothing for the fixture box: $(cat "$T/err1")"

# d. non-managed lines survive verbatim, in their original relative order.
NONMANAGED='SHELL=/bin/bash
# a hand comment that must survive
@reboot /usr/sbin/sshd
*/5 * * * * /root/harness/bin/watchdog-ping.sh box-fix
17 5 * * * /root/harness/bin/update-runners.sh
0 14 * * 0 /root/harness/bin/security-scan.sh alpha-os
58 * * * * /root/harness/bin/extra-usage-track.sh fix >/dev/null 2>&1'
GOT=$(grep -v '^# \(BEGIN\|END\) fleet-managed ' "$R1" | grep -vF '/root/harness/bin/run-triage.sh ' \
      | grep -vF '/root/harness/bin/run-product.sh ' | grep -vF '/root/harness/bin/healthcheck.sh ' \
      | grep -vF '/root/harness/bin/apply-migrations.sh ' | grep -vF '/root/harness/bin/merge-queue.sh ' \
      | grep -vF '/root/harness/bin/deploy-train.sh ' | grep -vF '/root/harness/bin/review-prs.sh ')
[ "$GOT" = "$NONMANAGED" ] && ok || bad "non-managed lines were not preserved verbatim:
--- got ---
$GOT
--- want ---
$NONMANAGED"

# security-scan.sh takes a project argument but is NOT one of the managed
# scripts, so it must be left exactly where the operator put it.
grep -qxF '0 14 * * 0 /root/harness/bin/security-scan.sh alpha-os' "$R1" && ok \
  || bad "a project-argument line outside the managed set was rewritten or dropped"

# The block lands where the first project line was, not appended at the end.
[ "$(grep -n '# BEGIN fleet-managed project=alpha-os' "$R1" | cut -d: -f1)" = 5 ] && ok \
  || bad "the managed block did not replace the first project line's position (got line $(grep -n '# BEGIN fleet-managed project=alpha-os' "$R1" | cut -d: -f1))"

# Both of this box's projects are rendered, in fleet.conf order.
ORDER=$(grep -o 'project=[a-z-]*' "$R1" | sed 's/project=//' | uniq | tr '\n' ' ')
[ "$ORDER" = "alpha-os beta " ] && ok || bad "blocks not emitted in fleet.conf order (got: $ORDER)"
grep -q 'run-triage.sh gamma' "$R1" && bad "another box's project leaked into this box's crontab" || ok

# The conditionals, each stated where it is decided.
grep -q '5 9 \* \* 1 /root/harness/bin/run-product.sh beta' "$R1" \
  && bad "run-product must be gated on prompts/product-<project>.md — beta has none and would ALERT every Monday" || ok
grep -q '2 9 \* \* 1 /root/harness/bin/run-product.sh alpha-os' "$R1" \
  && ok || bad "alpha-os has a product prompt and must get its weekly line"
grep -q 'healthcheck.sh beta' "$R1" \
  && bad "healthcheck must be gated on a real prod URL — beta's is '-'" || ok
grep -q 'healthcheck.sh alpha-os' "$R1" || bad "alpha-os has a prod URL and must get its healthcheck"
ok

# The offset drives the triage minutes, from the registry, not the file.
grep -qxF '5,15,25,35,45,55 * * * * /root/harness/bin/run-triage.sh beta' "$R1" && ok \
  || bad "beta's triage minutes must come from its fleet.conf offset (5)"

# c. idempotency — render(render(x)) == render(x)
cp "$R1" "$T/cron/fix.cron"
R2="$T/r2"; "$RENDER" --root "$T" fix > "$R2"
cmp -s "$R1" "$R2" && ok || bad "renderer is not idempotent:
$(diff "$R1" "$R2" | head -20)"

# A HAND-ADDED duplicate of a managed line (the drift shape: someone installs a
# lane by hand and the file grows a second copy) must collapse, not double.
{ cat "$R1"; echo '9,19,29,39,49,59 * * * * /root/harness/bin/run-triage.sh beta'; } > "$T/cron/fix.cron"
R3="$T/r3"; "$RENDER" --root "$T" fix > "$R3"
[ "$(grep -c 'run-triage.sh beta' "$R3")" = 1 ] && ok \
  || bad "a stray hand-added triage line for an owned project must collapse into the block (got $(grep -c 'run-triage.sh beta' "$R3"))"
cmp -s "$R1" "$R3" && ok || bad "collapsing a stray line must land back on the canonical render:
$(diff "$R1" "$R3" | head -20)"

# CRLF. A managed line that ends \r\n is a line the absorber must still own.
# The trap: the tail anchor was ([ \t]|$), and a \r sits between the project
# name and end-of-record — so the old line is PRESERVED as non-managed *and* a
# fresh block is generated, and the box carries the lane twice, permanently.
# Idempotence keeps passing the whole time, because the doubled state is stable.
# Files acquire CRLF from a Windows editor, a clipboard round-trip, or a scp
# through a tool that "helpfully" converts.
printf '2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os\r\n*/5 * * * * /root/harness/bin/watchdog-ping.sh box-fix\r\n' > "$T/crlf.cron"
CRLF_OUT=$("$RENDER" --root "$T" --base "$T/crlf.cron" fix)
[ "$(grep -c 'run-triage.sh alpha-os' <<<"$CRLF_OUT")" = 1 ] && ok \
  || bad "a CRLF-terminated managed line was preserved AND regenerated — the lane would run twice forever (got $(grep -c 'run-triage.sh alpha-os' <<<"$CRLF_OUT") copies)"
grep -q 'watchdog-ping' <<<"$CRLF_OUT" && ok || bad "the CRLF box line must still be preserved"

# A box with NO projects in the registry is left completely alone — the hub and
# a parked box both live here, and inventing blocks for them is how a stopped
# box comes back to life.
cp "$T/cron/fix.cron" "$T/cron/other2.cron"
"$RENDER" --root "$T" other2 > "$T/r4"
cmp -s "$T/cron/other2.cron" "$T/r4" && ok || bad "a box with no fleet.conf projects must render byte-identical to its base"

# ---------------------------------------------------------------------------
# 2. THE REGISTRY-TO-CRONTAB CONTRACT, against the real fleet
# ---------------------------------------------------------------------------
# a. every (project, box) row has a triage lane on that box.
while read -r P; do
  [ -n "$P" ] || continue
  B=$("$DIR/bin/box-for.sh" "$P" 2>/dev/null) || { bad "$P: box-for.sh could not resolve a box"; continue; }
  ID=$(cron_box_id_for "$B")
  OUT=$("$RENDER" "$ID" 2>&1) || { bad "$P: render-crontab.sh $ID failed: $OUT"; continue; }
  grep -qF "/root/harness/bin/run-triage.sh $P" <<<"$OUT" && ok \
    || bad "fleet.conf assigns $P to $B (cron/$ID.cron) but the rendered crontab has no triage lane for it — this is the project-7 incident"
done < <("$DIR/bin/fleet-conf.sh" --projects)

# b. the checked-in files ARE the render. They are generated artifacts kept in
# the repo for visibility; a difference means someone hand-edited one, which is
# precisely the plane that silently wiped a live lane.
for F in "$(rendered_cron_dir)"/*.cron; do
  ID=$(basename "$F" .cron)
  if "$RENDER" "$ID" 2>/dev/null | diff -u "$F" - > "$T/d-$ID"; then
    ok
  else
    bad "cron/$ID.cron differs from render-crontab.sh $ID — regenerate it, never hand-edit:
$(head -25 "$T/d-$ID")"
  fi
done

# c. idempotency on the real files too.
for F in "$(rendered_cron_dir)"/*.cron; do
  ID=$(basename "$F" .cron)
  "$RENDER" "$ID" > "$T/once-$ID" 2>/dev/null || continue
  "$RENDER" --base "$T/once-$ID" "$ID" > "$T/twice-$ID" 2>/dev/null
  cmp -s "$T/once-$ID" "$T/twice-$ID" && ok \
    || bad "render is not idempotent for $ID: $(diff "$T/once-$ID" "$T/twice-$ID" | head -10)"
done

# ---------------------------------------------------------------------------
# 3. update-runners refuses to apply a render that would DROP a live lane
# ---------------------------------------------------------------------------
# The guard, extracted verbatim so the test cannot drift from the shipped code,
# and driven with the incident's own inputs: a live crontab that runs a lane the
# rendered output does not.
awk '/^# >>> crontab drift guard/{f=1;next} /^# <<< crontab drift guard/{exit} f' \
  "$DIR/bin/update-runners.sh" > "$T/guard.sh"
[ -s "$T/guard.sh" ] && ok || bad "could not extract the drift guard from update-runners.sh — markers missing?"

ALERTS_OUT=""
guard() { # guard <live-file> <rendered-file> <projects...> -> rc; sets $ALERTS_OUT
  local L="$1" R="$2"; shift 2
  local A="$T/alerts"; : > "$A"
  local RC=0
  LIVE=$(cat "$L") RENDERED=$(cat "$R") BOX_PROJECTS="$*" BOX_ID=fix HARNESS_ALERTS="$A" \
    bash -c 'set -uo pipefail; STAMP(){ echo TS; }; . "$1"; exit "$DRIFT_RC"' _ "$T/guard.sh" || RC=$?
  ALERTS_OUT=$(cat "$A")
  return "$RC"
}

# the incident itself: a live lane the render does not carry.
printf '2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os\n5,15,25,35,45,55 * * * * /root/harness/bin/run-triage.sh beta\n' > "$T/live"
printf '2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/rend"
guard "$T/live" "$T/rend" alpha-os beta; G=$?
[ "$G" != 0 ] && ok || bad "a render that drops a LIVE lane must refuse (rc=$G)"
grep -q 'DROP the live triage lane for beta' <<<"$ALERTS_OUT" && ok \
  || bad "the refusal must name the lane it saved: '$ALERTS_OUT'"
grep -q 'alpha-os' <<<"$ALERTS_OUT" && bad "a lane that is fine must not be alerted about" || ok

# the incident's other half: a registry lane that was never installed at all.
printf '2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/live"
printf '2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os\n5,15,25,35,45,55 * * * * /root/harness/bin/run-triage.sh beta\n' > "$T/rend"
guard "$T/live" "$T/rend" alpha-os beta; G=$?
[ "$G" = 0 ] && ok || bad "installing a MISSING lane must still apply (rc=$G)"
grep -q 'CRONTAB GAP.*beta' <<<"$ALERTS_OUT" && ok \
  || bad "a lane that was never installed must alert even though it applies: '$ALERTS_OUT'"

# the normal case: nothing to say, nothing to refuse.
cp "$T/rend" "$T/live"
guard "$T/live" "$T/rend" alpha-os beta; G=$?
[ "$G" = 0 ] && [ -z "$ALERTS_OUT" ] && ok || bad "a matching render must be silent (rc=$G alerts='$ALERTS_OUT')"

# ---------------------------------------------------------------------------
# 4. THE APPLY PATH FAILS CLOSED
# ---------------------------------------------------------------------------
# Deriving the crontab is only safe if a derivation that GOES WRONG cannot be
# installed. Three ways it can go wrong, and every one of them used to end with
# a box in a worse state than doing nothing:
#
#   B1  `render | crontab -` — crontab consumes stdin BEFORE the pipeline's
#       failure surfaces, so a render that dies pipes ZERO BYTES into crontab
#       and set -e aborts too late. On a populated box that is every lane, the
#       @reboot sshd/cron/tailscaled line and the watchdog ping, gone: the box
#       is unreachable after its next reboot and pings nothing in the meantime.
#   B2  a dangling `# BEGIN fleet-managed` with no END silently deleted
#       EVERYTHING after it and still exited 0 with plausible non-empty output
#       (run-triage present, so neither the empty check nor the drift guard
#       fires). B1 is exactly what can create one, so they compound.
#   B3  update-runners never checked the render's exit status at all —
#       command substitution swallows it.

# --- B2 first: it is the one the other two are measured against -------------
mkdir -p "$T/cron"
cat > "$T/cron/dangle.cron" <<'EOF'
# BEGIN fleet-managed project=alpha-os
2,12,22,32,42,52 * * * * /root/harness/bin/run-triage.sh alpha-os
@reboot /usr/sbin/sshd; /usr/sbin/cron; setsid -f /usr/sbin/tailscaled
*/5 * * * * /root/harness/bin/watchdog-ping.sh box-fix
EOF
sed 's/box-fix/box-dangle/' "$T/fleet.conf" > "$T/f2.conf"
cp "$T/fleet.conf" "$T/fleet.conf.bak"
sed 's/box-fix/box-dangle/' "$T/fleet.conf.bak" > "$T/fleet.conf"
OUT=$("$RENDER" --root "$T" dangle 2>"$T/dangle.err"); RC=$?
[ "$RC" != 0 ] && ok || bad "a dangling BEGIN marker must make the render FAIL, not silently swallow the rest of the file (rc=$RC)"
grep -qi 'unterminated\|dangling\|BEGIN' "$T/dangle.err" && ok \
  || bad "the failure must name the unterminated marker: $(cat "$T/dangle.err")"
# Fail CLOSED, not "best effort": it emits NOTHING. The dangerous shape was a
# plausible-looking truncated crontab — run-triage present, @reboot and the ping
# gone — that exits 0 and sails past every downstream check. Emitting nothing
# means no caller can install a truncation even if it ignores the exit status.
[ -z "$OUT" ] && ok \
  || bad "a dangling marker still emitted an installable crontab; a caller that ignores the rc would install a truncation: $OUT"
cp "$T/fleet.conf.bak" "$T/fleet.conf"

# --- B1: the bootstrap apply path -------------------------------------------
# The block is extracted VERBATIM from bootstrap-machine.sh and driven with a
# fake `crontab` that records every invocation, so the assertion is "the live
# crontab was never written", not "the code looks careful".
awk '/^# >>> crontab render\+apply/{f=1;next} /^# <<< crontab render\+apply/{exit} f' \
  "$DIR/bin/bootstrap-machine.sh" > "$T/apply.sh"
[ -s "$T/apply.sh" ] && ok || bad "could not extract the render+apply block from bootstrap-machine.sh — markers missing?"

mkdir -p "$T/fakebin" "$T/stubbin"
cat > "$T/fakebin/crontab" <<EOF
#!/bin/bash
{ echo "CRONTAB CALLED: \$*"; cat "\${1:--}" 2>/dev/null; } >> "$T/crontab-calls"
EOF
chmod +x "$T/fakebin/crontab"

# stub_render <exit-code> <stdout...>
stub_render() {
  local rc="$1"; shift
  { echo '#!/bin/bash'; [ -n "${1:-}" ] && printf 'printf "%%s\\n" %q\n' "$1"; echo "exit $rc"; } > "$T/stubbin/render-crontab.sh"
  chmod +x "$T/stubbin/render-crontab.sh"
}
apply() { # apply -> rc; the fake crontab's record is $T/crontab-calls
  : > "$T/crontab-calls"
  printf 'existing line\n' > "$T/cronbase"
  ( PATH="$T/fakebin:$PATH" HERE="$T/stubbin" BOX_ID=fix CRONBASE="$T/cronbase" \
    bash -c 'set -euo pipefail; . "$1"' _ "$T/apply.sh" >/dev/null 2>&1 )
}

stub_render 1 ""
apply; RC=$?
[ "$RC" != 0 ] && ok || bad "a FAILED render must abort the bootstrap apply (rc=$RC)"
[ ! -s "$T/crontab-calls" ] && ok \
  || bad "a failed render still reached crontab(1) — on a populated box that installs an EMPTY crontab and kills @reboot + the ping: $(cat "$T/crontab-calls")"

stub_render 0 ""
apply; RC=$?
[ "$RC" != 0 ] && ok || bad "an EMPTY render must abort the bootstrap apply (rc=$RC)"
[ ! -s "$T/crontab-calls" ] && ok \
  || bad "an empty render was installed: $(cat "$T/crontab-calls")"

stub_render 0 "1 2 3 4 5 /root/harness/bin/run-triage.sh alpha-os"
apply; RC=$?
[ "$RC" = 0 ] && ok || bad "a GOOD render must still apply (rc=$RC)"
grep -q 'run-triage.sh alpha-os' "$T/crontab-calls" && ok \
  || bad "a good render never reached crontab(1): $(cat "$T/crontab-calls")"

# --- B3: update-runners must check the render's exit status ------------------
awk '/^# >>> crontab render$/{f=1;next} /^# <<< crontab render$/{exit} f' \
  "$DIR/bin/update-runners.sh" > "$T/render-block.sh"
[ -s "$T/render-block.sh" ] && ok || bad "could not extract the render block from update-runners.sh — markers missing?"

render_block() { # render_block <stub-rc> <stub-stdout> -> rc; sets $ALERTS_OUT/$RENDERED_OUT
  local A="$T/alerts2"; : > "$A"
  stub_render "$1" "${2:-}"
  mkdir -p "$T/co/bin"; cp "$T/stubbin/render-crontab.sh" "$T/co/bin/"
  local RC=0
  RENDERED_OUT=$(CHECKOUT="$T/co" BOX_ID=fix CRONF="$T/cron/fix.cron" HARNESS_ALERTS="$A" LOG="$T/ur.log" \
    bash -c 'set -uo pipefail; STAMP(){ echo TS; }; . "$1"; printf "%s" "$RENDERED"; exit "$RENDER_RC"' \
    _ "$T/render-block.sh") || RC=$?
  ALERTS_OUT=$(cat "$A")
  return "$RC"
}

render_block 1 "some output"; G=$?
[ "$G" != 0 ] && ok || bad "update-runners must FAIL CLOSED on a non-zero render (rc=$G)"
grep -q 'RENDER FAILED' <<<"$ALERTS_OUT" && ok || bad "a failed render must alert: '$ALERTS_OUT'"
[ -z "$RENDERED_OUT" ] && ok \
  || bad "a failed render's partial output must not survive into the apply path: '$RENDERED_OUT'"

render_block 0 ""; G=$?
[ "$G" != 0 ] && ok || bad "an EMPTY render must fail closed too (rc=$G)"
grep -q 'RENDER FAILED' <<<"$ALERTS_OUT" && ok || bad "an empty render must alert: '$ALERTS_OUT'"

render_block 0 "1 2 3 4 5 /root/harness/bin/run-triage.sh alpha-os"; G=$?
[ "$G" = 0 ] && ok || bad "a good render must succeed (rc=$G)"
[ -z "$ALERTS_OUT" ] && ok || bad "a good render must be silent: '$ALERTS_OUT'"
grep -q 'run-triage.sh alpha-os' <<<"$RENDERED_OUT" && ok || bad "the render's output must reach the caller"

echo "cron-fleet-parity-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
