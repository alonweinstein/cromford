#!/bin/bash
# tests/env-path-port-a-test.sh — the batch-A bin/ readers must find their env
# files through bin/lib/env-path.sh, so a migrated box reads /etc/harness/env
# (or $HARNESS_ENV_DIR) instead of a literal /root/harness/env. The same port
# must leave the copy-one-script scratch trees alone: with no bin/lib/env-path.sh
# next to the script the inline fallback prints $HARNESS/env, exactly today's path.
# No clock, no network — curl is stubbed and every URL is .invalid.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then . "$(dirname "$0")/lib/scratch.sh" || exit 1
else T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX"); export T; trap 'rm -rf "$T"' EXIT; fi
# The shared helper hands out a 0555 tree; every fixture below writes under it.
chmod u+w "$T" 2>/dev/null || true
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# jobs_secret <env assignments...> — source bin/jobs-client.sh from a clean
# environment the way a cron lane does and print the secret it resolved.
jobs_secret() {
  local script="$1"; shift
  env -i PATH="$PATH" HOME="$T" "$@" bash -c \
    ". \"$script\" >/dev/null 2>&1; printf %s \"\${HARNESS_SECRET:-}\""
}

# ---------------------------------------------------------------------------
# 1. jobs-client through the resolver: no $HARNESS/env, so rule 3 (the etc dir)
# ---------------------------------------------------------------------------
mkdir -p "$T/a" "$T/etc"
printf 'HARNESS_SECRET="from-etc"\n' > "$T/etc/global.env"
GOT=$(jobs_secret "$DIR/bin/jobs-client.sh" HARNESS="$T/a" ETC_HARNESS_ENV="$T/etc")
[ "$GOT" = "from-etc" ] && ok || bad "1: jobs-client rule 3 got '$GOT' want from-etc"

# 1b. rule 1: HARNESS_ENV_DIR wins over a real $HARNESS/env
mkdir -p "$T/b/env" "$T/envdir"
printf 'HARNESS_SECRET="from-harness-env"\n' > "$T/b/env/global.env"
printf 'HARNESS_SECRET="from-envdir"\n' > "$T/envdir/global.env"
GOT=$(jobs_secret "$DIR/bin/jobs-client.sh" HARNESS="$T/b" HARNESS_ENV_DIR="$T/envdir" ETC_HARNESS_ENV="$T/etc")
[ "$GOT" = "from-envdir" ] && ok || bad "1b: jobs-client rule 1 got '$GOT' want from-envdir"

# ---------------------------------------------------------------------------
# 2. Fallback: the script copied alone, without the RESOLVER, keeps $HARNESS/env
# ---------------------------------------------------------------------------
# BH-1194: bin/jobs-client.sh is a shim over bin/lib/jobs/, so even a
# copied-alone tree carries its own modules or it cannot load at all. The
# condition this case is about is unchanged and is checked as such: no
# bin/lib/env-path.sh next to the script, so the inline fallback answers.
mkdir -p "$T/h/bin" "$T/h/env"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
[ -e "$T/h/bin/lib/env-path.sh" ] && bad "2: fixture broken, $T/h/bin/lib/env-path.sh exists" || ok
printf 'HARNESS_SECRET="fixture-secret"\n' > "$T/h/env/global.env"
GOT=$(jobs_secret "$T/h/bin/jobs-client.sh" HARNESS="$T/h" ETC_HARNESS_ENV="$T/etc")
[ "$GOT" = "fixture-secret" ] && ok || bad "2: copy-one-script fallback got '$GOT' want fixture-secret"

# 2b. rule 2: a real $HARNESS/env beats the etc dir when the lib IS present
GOT=$(jobs_secret "$DIR/bin/jobs-client.sh" HARNESS="$T/b" ETC_HARNESS_ENV="$T/etc")
[ "$GOT" = "from-harness-env" ] && ok || bad "2b: jobs-client rule 2 got '$GOT' want from-harness-env"

# ---------------------------------------------------------------------------
# 3. bin/file-health-ticket.sh has no root variable: its three literals must
#    resolve too. It stops at the ":?no internal token" guard, before any curl,
#    and names the file it could not read.
# ---------------------------------------------------------------------------
mkdir -p "$T/hed"
OUT=$(env -i PATH="$PATH" HOME="$T" HARNESS="$T/nope" HARNESS_ENV_DIR="$T/hed" \
  bash "$DIR/bin/file-health-ticket.sh" probeproj https://prod.invalid https://pr.invalid 2>&1 || true)
# One line, so its own FAIL-shaped output cannot masquerade as this suite's.
OUT1=$(printf %s "$OUT" | tr '\n' ' ')
case "$OUT" in
  *"$T/hed/probeproj.env"*) ok ;;
  *) bad "3: file-health-ticket did not name $T/hed/probeproj.env, said: $OUT1" ;;
esac
case "$OUT" in
  *"/root/harness/env/"*) bad "3: file-health-ticket still names a literal env dir: $OUT1" ;;
  *) ok ;;
esac

# ---------------------------------------------------------------------------
# 3b. alerts-groom's MSNIP runs in ANOTHER shell (bash -c locally, bash -s over
#     ssh), which never inherits the parent's $HENV — the string must resolve
#     the dir itself. Extracted as shipped; the only edit is the install root,
#     so the target box's copy of the resolver can live in scratch.
# ---------------------------------------------------------------------------
mkdir -p "$T/remote/bin/lib" "$T/ag" "$T/agbin"
cp "$DIR/bin/lib/env-path.sh" "$T/remote/bin/lib/"
MSNIP=$(awk "/MSNIP='/ { sub(/^.*MSNIP='/, \"\"); inside=1 }
             inside { if (/'\$/) { sub(/'\$/, \"\"); print; exit } print }" "$DIR/bin/alerts-groom.sh")
[ -n "$MSNIP" ] && ok || bad "3b: could not extract MSNIP from bin/alerts-groom.sh"
MSNIP=${MSNIP//\/root\/harness/$T/remote}
printf 'AG_INTERNAL_API_TOKEN="not-the-migration-token"\nAG_MIGRATION_TOKEN="fixture-migration-token"\n' \
  > "$T/ag/probeproj.env"
cat > "$T/agbin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$MSNIP_CURL_LOG"
printf '%s' '{"pending":[]}'
STUB
chmod +x "$T/agbin/curl"

: > "$T/ag-c.log"
GOT=$(env -i PATH="$T/agbin:$PATH" HOME="$T" HARNESS_ENV_DIR="$T/ag" MSNIP_CURL_LOG="$T/ag-c.log" \
  bash -c "$MSNIP" _ probeproj https://mig.invalid 2>/dev/null || true)
[ "$GOT" = "0" ] && ok || bad "3b (bash -c): MSNIP printed '$GOT' want 0"
grep -q 'Bearer fixture-migration-token' "$T/ag-c.log" && ok \
  || bad "3b (bash -c): project migration token never reached curl: $(cat "$T/ag-c.log")"
grep -q 'https://mig.invalid/api/internal/migrations/status' "$T/ag-c.log" && ok \
  || bad "3b (bash -c): migrations status URL never called: $(cat "$T/ag-c.log")"

: > "$T/ag-s.log"
GOT=$(printf %s "$MSNIP" | env -i PATH="$T/agbin:$PATH" HOME="$T" HARNESS_ENV_DIR="$T/ag" \
  MSNIP_CURL_LOG="$T/ag-s.log" bash -s -- probeproj https://mig.invalid 2>/dev/null || true)
[ "$GOT" = "0" ] && ok || bad "3b (bash -s): MSNIP printed '$GOT' want 0"
grep -q 'Bearer fixture-migration-token' "$T/ag-s.log" && ok \
  || bad "3b (bash -s): project migration token never reached curl: $(cat "$T/ag-s.log")"

# ---------------------------------------------------------------------------
# 4. Every file in this slice still parses. A missing file is a failure, not a
#    skip — the list is the slice, written out so a dropped port is loud.
# ---------------------------------------------------------------------------
SLICE="account-capacity.sh account-pick.sh alert-flush.sh alert-triage.sh alerts-groom.sh
alerts-medic.sh apply-migrations.sh beat.sh blocked-resolver.sh board-invariants.sh
box-chat.sh cap-loss-detector.sh capture-ticket-shape.sh check-migration-prs.sh
claude-auth-check.sh cli-update.sh cli-version-check.sh clock-sync.sh cost-readout.sh
cost-reconcile.sh cost-report.sh cost-rollup.sh cost-rows-push.sh decompose-parent-close.sh
deploy-request.sh deploy-train.sh deploy-verify.sh dora-digest.sh draft-proposal.sh
extra-usage-track.sh file-health-ticket.sh flaky-detect.sh flaky-quarantine.sh
fleet-propagate.sh fleet-status-push.sh gh-token.sh harness-sync.sh healthcheck.sh
jobs-client.sh jobs-watchdog.sh lander.sh lane-alert.sh lane-probe.sh load-project.sh
locks-mint-digest.sh main-red-detector.sh merge-conductor.sh merge-queue.sh merge-sweep.sh
migration-autopilot.sh collaborator-5-watch.sh"
N=0
for b in $SLICE; do
  N=$((N+1))
  if [ -f "$DIR/bin/$b" ]; then
    bash -n "$DIR/bin/$b" 2>/dev/null && ok || bad "4: bash -n failed on bin/$b"
  else
    bad "4: slice file missing: bin/$b"
  fi
done
[ "$N" -eq 51 ] && ok || bad "4: slice list holds $N files, want 51"

echo "env-path-port-a-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
