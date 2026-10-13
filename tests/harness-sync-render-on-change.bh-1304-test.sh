#!/bin/bash
# tests/harness-sync-render-on-change.bh-1304-test.sh — bin/harness-sync.sh
# composes catalog/lanes.json for a worker only when that worker is about to
# deploy.
#
# WHY (BH-1304, item 3; BH-1247 review r4 § Suggestions). worker/jobs bundles
# catalog/lanes.json with a static ESM import, and that file is GENERATED and no
# longer committed, so harness-sync renders it into the checkout before the
# deploy. It rendered it BEFORE the change-key skip, which means every hub tick
# — one every five minutes, and the overwhelming majority of them deploy nothing
# — paid for a full jq composition of the registry it was about to throw away.
#
# The sources of that render are already inside the worker's change key (the
# `-lanes-<sha>` suffix), so an unchanged key means the bundle would be
# identical. Moving the render inside the "changed" branch is therefore free of
# behaviour and not free of cost: R2 is the case that pins it.
#
# WHAT MUST NOT CHANGE, and is asserted here because "none of this changes
# behaviour today" is the ticket's own claim: a changed key still renders BEFORE
# the deploy (R1, R3), a compose failure still writes its ALERTS line and still
# lets the deploy run and report its own failure (R4), and a worker that does
# not import the registry still never composes anything (R5).
#
# Everything below drives bin/harness-sync.sh itself against a scratch $HARNESS
# and a real bare origin + clone. `npx` and `bin/lanes-build.sh` are recorders:
# they append one line each to $T/calls.log, so ORDER is a property of one file.
#
# Run from anywhere: tests/harness-sync-render-on-change.bh-1304-test.sh
# (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "harness-sync-render-on-change.bh-1304-test: SKIPPED — git/flock missing"; exit 0; }

ALERTS="$T/logs/ALERTS.log"
CALLS="$T/calls.log"
: > "$CALLS"

# ── credentials the worker block needs to exist at all (fake, never read by
#    anything but the recorder below) ─────────────────────────────────────────
printf 'CLOUDFLARE_ACCOUNT_ID=test-account\nCLOUDFLARE_API_TOKEN=not-a-real-token\n' > "$T/env/cloudflare.env"

# ── the recorders ───────────────────────────────────────────────────────────
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
CALLS="$CALLS"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
args=$(printf '%s ' "$@" | tr '\n\t' '  ')
printf 'npx %s | %s\n' "$PWD" "$args" >> "$CALLS"
exit 0
EOF
chmod +x "$T/fakebin/npx"

if ! command -v rsync >/dev/null; then
  cat > "$T/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$T/fakebin/rsync"
fi

# ── a real bare origin and a real clone ─────────────────────────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog/lanes.d" \
         "$T/ck/worker/jobs/src"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf 'fleet\n' > "$T/ck/fleet.conf"
printf '{"version":1,"note":"fixture"}\n' > "$T/ck/catalog/lanes.d/_registry.json"
printf '{"id":"one","box":"hub","cadence_min":10}\n' > "$T/ck/catalog/lanes.d/one.json"

# The composer stand-in: it RECORDS and writes nothing. Every case here is about
# whether the render ran and in what order, so a recorder that produces no file
# keeps the fixture from drifting into "did the bytes land" — which is
# tests/registry-render-test.sh's question, not this suite's.
cat > "$T/ck/bin/lanes-build.sh" <<EOF
#!/bin/bash
CALLS="$CALLS"
FAILFLAG="$T/flags-lanes-build-fail"
EOF
cat >> "$T/ck/bin/lanes-build.sh" <<'EOF'
args=$(printf '%s ' "$@" | tr '\n\t' '  ')
printf 'lanes-build %s | %s\n' "$PWD" "$args" >> "$CALLS"
[ -e "$FAILFLAG" ] && exit 1
exit 0
EOF
chmod +x "$T/ck/bin/lanes-build.sh"

# worker/jobs IMPORTS the registry (the literal string is what opts a worker into
# the lane change key) and has NO d1_databases, so the schema block stays out of
# the way of what this suite measures.
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{
  "name": "jobs-test",
  "main": "src/index.js"
}
EOF
cat > "$T/ck/worker/jobs/src/index.js" <<'EOF'
import LANES_REGISTRY from "../../../catalog/lanes.json" with { type: "json" };
export default { fetch: () => new Response(JSON.stringify(LANES_REGISTRY)) };
EOF
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() { # sync -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$CALLS"; : > "$ALERTS"; }
lb_count()  { grep -c '^lanes-build ' "$CALLS" 2>/dev/null || true; }
deployed()  { grep -F 'wrangler deploy' "$CALLS" 2>/dev/null | grep -cF "/worker/$1 " || true; }
commit_push() { # commit_push <message>
  git -C "$T/ck" add -A >/dev/null
  git -C "$T/ck" commit -qm "$1"
  git -C "$T/ck" push -q origin main
}

# ── S0. SAFETY PROBE, before anything else ──────────────────────────────────
# harness-sync's deploy path rsyncs $CHECKOUT/{bin,prompts,fly,catalog} into
# $HARNESS. If it does not honour $HARNESS, every run below lands on the REAL
# /root/harness. Behavioural, not a grep: a DIRTY checkout refuses at rc 30 and
# writes its REFUSED line into $HARNESS/logs/ALERTS.log before reaching any
# rsync. Not in the scratch tree = abort without deploying.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $ALERTS) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-render-on-change.bh-1304-test: 0 pass, 1 fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ============================================================================
# R1. FIRST DEPLOY — the worker's key has never been stamped, so the registry is
#     composed, and it is composed BEFORE the deploy that bundles it.
# ============================================================================
sync
[ "$RC" = 0 ] && ok || bad "R1: a clean deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(lb_count)" = 1 ] \
  && ok || bad "R1: the registry must be composed exactly once, got $(lb_count): $(cat "$CALLS")"
grep -q '^lanes-build .* --write' "$CALLS" \
  && ok || bad "R1: the compose must be a --write into the checkout: $(cat "$CALLS")"
[ "$(deployed jobs)" = 1 ] && ok || bad "R1: worker jobs must deploy: $(cat "$CALLS")"
LB_LINE=$(grep -n '^lanes-build ' "$CALLS" | head -1 | cut -d: -f1)
DEP_LINE=$(grep -n 'wrangler deploy' "$CALLS" | head -1 | cut -d: -f1)
[ -n "$LB_LINE" ] && [ -n "$DEP_LINE" ] && [ "$LB_LINE" -lt "$DEP_LINE" ] \
  && ok || bad "R1: the compose must precede the deploy (compose line $LB_LINE, deploy line $DEP_LINE): $(cat "$CALLS")"
[ -s "$T/state/worker-deployed-jobs" ] && ok || bad "R1: a deployed worker must be stamped"
STAMP_R1=$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)
case "$STAMP_R1" in *-lanes-*) ok ;; *) bad "R1: the stamp must carry the lane sources' sha: '$STAMP_R1'" ;; esac
[ ! -s "$ALERTS" ] && ok || bad "R1: a clean run must write no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# R2. THE NO-OP TICK — THE TICKET. Nothing moved, so nothing deploys, and
#     nothing is composed either. This is the case that is red against a
#     harness-sync that renders ahead of the change-key skip.
# ============================================================================
reset_run
sync
[ "$RC" = 0 ] && ok || bad "R2: an unchanged tick must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(lb_count)" = 0 ] \
  && ok || bad "R2: a tick that deploys nothing must compose nothing, got $(lb_count) compose call(s): $(cat "$CALLS")"
[ "$(deployed jobs)" = 0 ] \
  && ok || bad "R2: an unchanged worker must not deploy: $(cat "$CALLS")"
[ "$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" = "$STAMP_R1" ] \
  && ok || bad "R2: the stamp must not move on a no-op tick"
[ ! -s "$ALERTS" ] && ok || bad "R2: a no-op tick must write no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# R3. A LANE-FILE-ONLY CHANGE still renders and still redeploys. The worker's
#     own tree is untouched, so this only works because the lane sources are in
#     the change key — and moving the render must not have moved that half of
#     the block.
# ============================================================================
reset_run
printf '{"id":"one","box":"hub","cadence_min":20}\n' > "$T/ck/catalog/lanes.d/one.json"
commit_push "a lane file moves; worker/jobs does not"
sync
[ "$RC" = 0 ] && ok || bad "R3: the lane-change run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(lb_count)" = 1 ] \
  && ok || bad "R3: a lane-file change must compose the registry once, got $(lb_count): $(cat "$CALLS")"
[ "$(deployed jobs)" = 1 ] \
  && ok || bad "R3: a lane-file change must redeploy the worker that bundles it: $(cat "$CALLS")"
STAMP_R3=$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)
[ -n "$STAMP_R3" ] && [ "$STAMP_R3" != "$STAMP_R1" ] \
  && ok || bad "R3: the stamp's lane half must move with the lane sources: '$STAMP_R3' vs '$STAMP_R1'"
LB_LINE=$(grep -n '^lanes-build ' "$CALLS" | head -1 | cut -d: -f1)
DEP_LINE=$(grep -n 'wrangler deploy' "$CALLS" | head -1 | cut -d: -f1)
[ -n "$LB_LINE" ] && [ -n "$DEP_LINE" ] && [ "$LB_LINE" -lt "$DEP_LINE" ] \
  && ok || bad "R3: the compose must still precede the deploy: $(cat "$CALLS")"

# ============================================================================
# R4. A COMPOSE FAILURE ON A CHANGED KEY KEEPS ITS ALERT — and keeps the deploy
#     too. wrangler is the thing that discovers it cannot resolve the module,
#     and it writes its own ALERTS line when it fails; skipping the deploy here
#     would be a behaviour change this ticket does not ask for.
# ============================================================================
reset_run
: > "$T/flags-lanes-build-fail"
printf 'import LANES_REGISTRY from "../../../catalog/lanes.json" with { type: "json" };\nexport default { fetch: () => new Response("v2" + JSON.stringify(LANES_REGISTRY)) };\n' \
  > "$T/ck/worker/jobs/src/index.js"
commit_push "worker/jobs code moves while the lane sources will not compose"
sync
[ "$RC" = 0 ] && ok || bad "R4: a compose failure must not fail the whole sync, got $RC: $(cat "$T/out.txt")"
[ "$(lb_count)" = 1 ] \
  && ok || bad "R4: the changed key must still attempt the compose once, got $(lb_count): $(cat "$CALLS")"
[ "$(grep -c . "$ALERTS")" = 1 ] \
  && ok || bad "R4: exactly one ALERTS line, got $(grep -c . "$ALERTS"): $(cat "$ALERTS")"
grep -q 'worker/jobs imports catalog/lanes.json and it could NOT be composed' "$ALERTS" \
  && ok || bad "R4: the ALERTS line must name the worker and the failure: $(cat "$ALERTS")"
[ "$(deployed jobs)" = 1 ] \
  && ok || bad "R4: the deploy still runs after a compose failure (unchanged behaviour): $(cat "$CALLS")"
rm -f "$T/flags-lanes-build-fail"

# ============================================================================
# R5. A WORKER THAT DOES NOT IMPORT THE REGISTRY NEVER COMPOSES. worker/jobs is
#     unchanged in this run, so every compose call in $CALLS would have to be
#     worker/plain's — and there must be none.
# ============================================================================
reset_run
mkdir -p "$T/ck/worker/plain/src"
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF
printf 'export default { fetch: () => new Response("plain") };\n' > "$T/ck/worker/plain/src/index.js"
commit_push "a worker that bundles no registry"
sync
[ "$RC" = 0 ] && ok || bad "R5: the new-worker run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(deployed plain)" = 1 ] && ok || bad "R5: worker plain must deploy: $(cat "$CALLS")"
[ "$(deployed jobs)" = 0 ] \
  && ok || bad "R5: worker jobs is unchanged in this run and must not deploy: $(cat "$CALLS")"
[ "$(lb_count)" = 0 ] \
  && ok || bad "R5: a worker that does not import the registry must compose nothing, got $(lb_count): $(cat "$CALLS")"
[ ! -s "$ALERTS" ] && ok || bad "R5: this run must write no ALERTS line: $(cat "$ALERTS")"

echo "harness-sync-render-on-change.bh-1304-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
