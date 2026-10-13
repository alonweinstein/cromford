#!/bin/bash
# tests/harness-sync-d1-batch.bh-1538-test.sh — bin/harness-sync.sh applies
# only the CHANGED statements of a worker's schema.sql, several per round trip,
# and never holds the deploy lock while it does.
#
# WHY (BH-1538, 2026-09-22). worker/jobs/schema.sql had grown to 116
# statements. harness-sync re-applied every one of them after any edit, one
# `wrangler d1 execute --command` round trip each (~5 s), while holding
# locks/harness-sync.lock. Every other sync exited 20 on the busy lock and
# fleet-propagate DEFERRED on it, so the hub ran code 12 commits behind main for
# 30+ minutes after every schema change.
#
# What is proved here, each against a fake npx that records instead of calling
# Cloudflare:
#   B1. a cold apply (no stamp) of 116 statements costs at most
#       ceil(116 / D1_BATCH_MAX_STMTS) round trips, in file order, and deploys;
#   B2. a ONE-statement change afterwards costs exactly ONE round trip, and that
#       round trip carries only the new statement;
#   B3. a batch that fails is re-run one statement at a time: the ALERTS line
#       names the statement that broke, the deploy is skipped, nothing stamps;
#   B4. a batch refused where every statement passes alone (multi-statement
#       `--command` not accepted) completes one statement per round trip, says
#       so in the log, and still deploys;
#   B5. the deploy lock is FREE while the schema applies — fleet-propagate and
#       the next harness-sync see an idle lock, not a 30-minute one;
#   B6. bin/ deploys while another run's schema apply is still pending (its
#       worker lock is held): exit 0, the new bin/ is live, no worker deploys,
#       and the next run picks the worker up;
#   B7. an apply past the settings threshold writes one ALERTS line (and one
#       only), below it writes none, and the check runs per ROUND TRIP (B7b);
#   B8. THE RACE the lock release opened (#1548 review C1): a pull that lands
#       while `wrangler deploy` bundles must never put code live that reads a
#       statement not yet applied, and when that statement's apply then fails,
#       the new code must stay OFF (the ALERTS line's "deploy SKIPPED" is true).
# Run from anywhere: tests/harness-sync-d1-batch.bh-1538-test.sh (exit 0 = pass)
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
  || { echo "git/flock missing — skipping"; exit 0; }
# shellcheck source=bin/lib/d1-schema.sh
. "$DIR/bin/lib/d1-schema.sh" || exit 1

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"
printf 'CLOUDFLARE_ACCOUNT_ID=test-account\nCLOUDFLARE_API_TOKEN=not-a-real-token\n' > "$T/env/cloudflare.env"

# ── the fake npx. One line per call: cwd | lock state | argv (newlines in the
# SQL flattened to ` / ` so a batch is one line and its statements countable).
#   NPX_FAIL_MATCH=<s>  fail any d1 execute whose SQL contains <s>
#   NPX_FAIL_MULTI=1    fail any d1 execute carrying more than one statement
# `lock=held|free` is whether locks/harness-sync.lock could be taken at the
# moment of the call — B5's whole subject.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
LOCK="$T/locks/harness-sync.lock"
APPLIED="$T/applied.sql"
BUNDLES="$T/bundles.log"
RACE_HOOK="$T/race-hook.sh"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
lk=free; flock -n "$LOCK" true 2>/dev/null || lk=held
args=$(printf '%s ' "$@" | sed ':a;N;$!ba;s/\n/ \/ /g' | tr '\t' ' ')
printf '%s | lock=%s | %s\n' "$PWD" "$lk" "$args" >> "$NPX_LOG"
if [ "${3:-}" = "d1" ] && [ "${4:-}" = "execute" ]; then
  sql="${!#}"
  if [ -n "${NPX_FAIL_MATCH:-}" ]; then
    case "$sql" in *"$NPX_FAIL_MATCH"*) echo "fake npx: forced failure on $NPX_FAIL_MATCH" >&2; exit 1 ;; esac
  fi
  # a statement ENDS a line with `;` — the fixture's `-- row N; …` comments
  # hold one mid-line and must not count
  if [ "${NPX_FAIL_MULTI:-}" = 1 ] && [ "$(printf '%s\n' "$sql" | grep -c ';[[:space:]]*$')" -gt 1 ]; then
    echo "fake npx: multi-statement --command refused" >&2; exit 1
  fi
  printf '%s\n' "$sql" >> "$APPLIED"
fi
# `wrangler deploy`: an armed race hook moves the checkout FIRST (the pull a
# concurrent harness-sync makes), then this records what the bundle reads (the
# cwd's src/index.js, which is what wrangler would bundle) and whether every
# table it reads had been applied by then.
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ]; then
  [ -x "$RACE_HOOK" ] && { "$RACE_HOOK" >>"$RACE_HOOK.log" 2>&1; rm -f "$RACE_HOOK"; }
  if [ -f src/index.js ]; then
    code=$(cat src/index.js); ok=yes
    for t in $(grep -o 'reads t_[a-z0-9_]*' src/index.js | sed 's/reads //'); do
      grep -q "CREATE TABLE IF NOT EXISTS $t " "$APPLIED" 2>/dev/null || ok=no
    done
    printf 'BUNDLE [%s] applied=%s\n' "$code" "$ok" >> "$BUNDLES"
  fi
fi
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

# ── origin + clone, one worker with a D1 binding and a 116-statement schema ──
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" "$T/ck/worker/jobs"
printf '#!/bin/bash\necho v1\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{
  "name": "jobs-test",
  "main": "src/index.js",
  "d1_databases": [ { "binding": "DB", "database_name": "jobs-test-db", "database_id": "0000" } ]
}
EOF
NSTMT=116
{ echo "-- a schema the size of worker/jobs's on 2026-09-22"
  for i in $(seq 1 "$NSTMT"); do
    printf 'CREATE TABLE IF NOT EXISTS t_%03d (\n  id INTEGER PRIMARY KEY  -- row %d; the note is free text\n);\n' "$i" "$i"
  done; } > "$T/ck/worker/jobs/schema.sql"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

FAIL_MATCH=""; FAIL_MULTI=""; ALERT_S=""
sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH" \
           NPX_FAIL_MATCH="$FAIL_MATCH" NPX_FAIL_MULTI="$FAIL_MULTI" \
           HARNESS_SYNC_SCHEMA_ALERT_S="$ALERT_S"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
# reset_run also drops the BH-1555 progress file: every case in this suite is
# about batching, not resume, and each one must start from the statement count
# it names. The one case that IS about resume (B3r) clears the logs by hand.
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; rm -f "$T/state/worker-schema-progress-jobs"; }
d1_lines() { grep -F 'd1 execute' "$NPXLOG" 2>/dev/null; }
d1_count() { d1_lines | grep -c . ; }
deployed() { grep -F 'wrangler deploy' "$NPXLOG" 2>/dev/null | grep -c . ; }
commit() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }

# S0. SAFETY PROBE (same as harness-sync-d1.bh-1000): a dirty checkout must
# refuse into $T, or this suite would rsync the fixture over a live harness.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS — refusing to run the deploy path"
  echo "harness-sync-d1-batch.bh-1538-test: 0 pass, 1 fail"; exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ============================================================================
# B1 + B5. cold apply: ceil(116 / chunk) round trips at most, all statements
#          in file order, the deploy lock free throughout, then the deploy.
# ============================================================================
ALERT_S=100000
sync
MAXRT=$(( (NSTMT + D1_BATCH_MAX_STMTS - 1) / D1_BATCH_MAX_STMTS ))
[ "$RC" = 0 ] && ok || bad "B1: a clean cold apply must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(d1_count)" -ge 1 ] && [ "$(d1_count)" -le "$MAXRT" ] \
  && ok || bad "B1: a cold $NSTMT-statement apply must take 1..$MAXRT round trips, took $(d1_count)"
SENT=$(d1_lines | grep -o 'CREATE TABLE IF NOT EXISTS t_[0-9]*' | sed 's/.*t_//')
[ "$(printf '%s\n' "$SENT" | grep -c .)" = "$NSTMT" ] \
  && ok || bad "B1: every one of the $NSTMT statements must be sent exactly once, sent $(printf '%s\n' "$SENT" | grep -c .)"
[ "$SENT" = "$(seq -f '%03g' 1 "$NSTMT")" ] \
  && ok || bad "B1: statements must go in file order"
[ "$(d1_lines | grep -c -- '--remote --yes --command')" = "$(d1_count)" ] \
  && ok || bad "B1: every round trip is a --remote --yes --command call: $(d1_lines | head -2)"
[ "$(grep -c -- '--file' "$NPXLOG")" = 0 ] && ok || bad "B1: --file must never appear (OAuth code 10000)"
[ "$(d1_lines | grep -c 'lock=held')" = 0 ] \
  && ok || bad "B5: the deploy lock must be FREE while the schema applies; held on $(d1_lines | grep -c 'lock=held') of $(d1_count) round trips"
[ "$(deployed)" = 1 ] && ok || bad "B1: the worker must deploy after its apply: $(cat "$NPXLOG")"
LAST_D1=$(grep -nF 'd1 execute' "$NPXLOG" | tail -1 | cut -d: -f1)
DEP=$(grep -nF 'wrangler deploy' "$NPXLOG" | head -1 | cut -d: -f1)
[ -n "$LAST_D1" ] && [ -n "$DEP" ] && [ "$LAST_D1" -lt "$DEP" ] \
  && ok || bad "B1: the apply must finish before the deploy"
grep -q "schema.sql applied ($NSTMT statements; $(d1_count) round trip(s); full apply) to jobs-test-db" "$ULOG" \
  && ok || bad "B1: the applied line must carry statements, round trips and mode: $(grep 'applied' "$ULOG")"
grep -q "schema apply: statement $NSTMT/$NSTMT on" "$ULOG" \
  && ok || bad "B1: progress N/M must be logged per round trip: $(grep 'schema apply' "$ULOG" | tail -2)"
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" \
  = "$(git -C "$T/ck" hash-object worker/jobs/schema.sql) jobs-test-db" ] \
  && ok || bad "B1: the stamp is the blob sha and its database"
[ ! -s "$ALERTS" ] && ok || bad "B1: a clean apply writes no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# B2. ONE new statement = ONE round trip carrying only that statement.
# ============================================================================
reset_run
printf 'CREATE INDEX IF NOT EXISTS ix_new ON t_001(id);\n' >> "$T/ck/worker/jobs/schema.sql"
commit "one new statement"
sync
[ "$RC" = 0 ] && ok || bad "B2: exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_count)" = 1 ] && ok || bad "B2: a one-statement change must be ONE round trip, took $(d1_count): $(d1_lines | cut -c1-200)"
[ "$(d1_lines | grep -c 'ix_new')" = 1 ] && ok || bad "B2: the round trip must carry the new statement"
[ "$(d1_lines | grep -c 'CREATE TABLE')" = 0 ] \
  && ok || bad "B2: already-applied statements must not be re-sent: $(d1_lines | cut -c1-200)"
grep -q 'schema.sql applied (1 statements; 1 round trip(s); delta vs ' "$ULOG" \
  && ok || bad "B2: the applied line must say it was a delta: $(grep 'applied' "$ULOG")"
[ "$(deployed)" = 1 ] && ok || bad "B2: the worker deploys after the delta"

# B2b. an EDITED statement is new text, so it is re-sent; nothing else is.
reset_run
sed -i.bak 's/CREATE TABLE IF NOT EXISTS t_050 (/CREATE TABLE IF NOT EXISTS t_050 ( -- edited/' "$T/ck/worker/jobs/schema.sql"
rm -f "$T/ck/worker/jobs/schema.sql.bak"
commit "one statement edited"
sync
[ "$(d1_count)" = 1 ] && [ "$(d1_lines | grep -c 't_050')" = 1 ] && [ "$(d1_lines | grep -c 't_049\|t_051')" = 0 ] \
  && ok || bad "B2b: an edited statement alone must be re-sent: $(d1_lines | cut -c1-200)"

# B2c. comment-only edit: no statement changed, no round trip, still stamps + deploys.
reset_run
printf -- '-- a trailing comment; nothing to apply\n' >> "$T/ck/worker/jobs/schema.sql"
commit "comment only"
sync
[ "$(d1_count)" = 0 ] && ok || bad "B2c: a comment-only edit must make no round trip, made $(d1_count)"
[ "$(deployed)" = 1 ] && ok || bad "B2c: and still deploys"
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" \
  = "$(git -C "$T/ck" hash-object worker/jobs/schema.sql) jobs-test-db" ] \
  && ok || bad "B2c: and stamps the new blob"

# ============================================================================
# B3. a failing batch falls back to one statement at a time and NAMES the bad
#     statement; no deploy, no stamp. Cold (stamp removed) so the bad statement
#     sits inside a multi-statement chunk.
# ============================================================================
reset_run
rm -f "$T/state/worker-schema-applied-jobs" "$T/state/worker-deployed-jobs"
FAIL_MATCH="t_045 "
sync
[ "$RC" = 0 ] && ok || bad "B3: one worker's failed apply must not fail the sync, got $RC"
[ "$(deployed)" = 0 ] && ok || bad "B3: a failed apply must NOT deploy: $(grep 'wrangler deploy' "$NPXLOG")"
[ ! -f "$T/state/worker-schema-applied-jobs" ] && ok || bad "B3: a failed apply must not stamp the schema"
[ ! -f "$T/state/worker-deployed-jobs" ] && ok || bad "B3: a failed apply must not stamp the worker"
[ "$(grep -c . "$ALERTS")" = 1 ] && ok || bad "B3: exactly one ALERTS line, got: $(cat "$ALERTS")"
grep -q 'worker/jobs schema.sql statement 45/117 failed against D1 jobs-test-db (CREATE TABLE IF NOT EXISTS t_045' "$ALERTS" \
  && ok || bad "B3: the ALERTS line must name statement 45/117 and quote its head: $(cat "$ALERTS")"
grep -q 'SKIPPED' "$ALERTS" && ok || bad "B3: the ALERTS line says the deploy was skipped"
# the fallback stopped AT the bad statement: statements after it were never sent singly
[ "$(d1_lines | grep -c 'CREATE TABLE IF NOT EXISTS t_046 (')" -le 1 ] \
  && ok || bad "B3: the per-statement fallback must stop at the first failure"
grep -q 'one statement at a time' "$ULOG" && ok || bad "B3: the fallback must be logged: $(tail -3 "$ULOG")"

# ============================================================================
# B3r (BH-1555, lead review B2). The retry after B3 RESUMES at the statement
#     that failed: statements 1-44 landed on B3's per-statement fallback, so
#     they are never re-sent; 45 goes first, the apply completes, stamps,
#     removes its progress file and deploys.
# ============================================================================
: > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"
[ "$(cat "$T/state/worker-schema-progress-jobs" 2>/dev/null | awk '{print $NF}')" = 44 ] \
  && ok || bad "B3r: precondition — B3 must leave progress 44 (statements 1-44 landed): $(cat "$T/state/worker-schema-progress-jobs" 2>/dev/null)"
FAIL_MATCH=""
sync
[ "$RC" = 0 ] && ok || bad "B3r: exit 0, got $RC"
grep -q 'resuming at statement 45/117' "$ULOG" \
  && ok || bad "B3r: the resume must be logged as 'resuming at statement 45/117': $(tail -5 "$ULOG")"
[ "$(d1_lines | grep -cE 'CREATE TABLE IF NOT EXISTS t_0(0[1-9]|[1-3][0-9]|4[0-4]) \(')" = 0 ] \
  && ok || bad "B3r: statements 1-44 already landed and must not be re-sent: $(d1_lines | head -1 | cut -c1-200)"
case "$(d1_lines | head -1)" in
  *"CREATE TABLE IF NOT EXISTS t_045 ("*) ok ;;
  *) bad "B3r: the first round trip must start at t_045: $(d1_lines | head -1 | cut -c1-200)" ;;
esac
grep -q 'schema.sql applied (117 statements;' "$ULOG" \
  && ok || bad "B3r: the applied line counts the whole apply, resumed part included: $(tail -3 "$ULOG")"
[ "$(deployed)" = 1 ] && ok || bad "B3r: the resumed apply must deploy: $(tail -5 "$ULOG")"
[ -s "$T/state/worker-schema-applied-jobs" ] && ok || bad "B3r: the resumed apply must stamp the schema"
[ ! -e "$T/state/worker-schema-progress-jobs" ] && ok || bad "B3r: a completed apply must remove its progress file"
[ ! -s "$ALERTS" ] && ok || bad "B3r: a completed apply writes no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# B4. multi-statement --command refused, every statement fine alone: the apply
#     completes one per round trip, says so, and deploys.
#     Cold again (both stamps removed): B3r completed the apply, and B4 is the
#     same full 117-statement apply it was when it ran straight after B3.
# ============================================================================
reset_run
rm -f "$T/state/worker-schema-applied-jobs" "$T/state/worker-deployed-jobs"
FAIL_MATCH=""; FAIL_MULTI=1
sync
[ "$RC" = 0 ] && ok || bad "B4: exit 0, got $RC"
[ "$(deployed)" = 1 ] && ok || bad "B4: a batch-only refusal must still end in a deploy: $(tail -5 "$ULOG")"
[ ! -s "$ALERTS" ] && ok || bad "B4: a completed apply writes no ALERTS line: $(cat "$ALERTS")"
grep -q 'batched --command failed where every statement' "$ULOG" \
  && ok || bad "B4: the batch refusal must be logged in words: $(tail -5 "$ULOG")"
# one refused batch, then every statement alone: never a second refused batch
[ "$(d1_count)" = "$((117 + 1))" ] \
  && ok || bad "B4: expected 1 refused batch + 117 single round trips, got $(d1_count)"
FAIL_MULTI=""

# ============================================================================
# B6. bin/ deploys while another run's schema apply is pending.
# ============================================================================
reset_run
exec 6>"$T/locks/harness-sync-workers.lock"
flock -n 6 || bad "B6: precondition — could not take the worker lock"
printf '#!/bin/bash\necho v2\n' > "$T/ck/bin/x.sh"
printf 'CREATE INDEX IF NOT EXISTS ix_b6 ON t_002(id);\n' >> "$T/ck/worker/jobs/schema.sql"
commit "bin moves and the schema moves"
sync
[ "$RC" = 0 ] && ok || bad "B6: a sync behind a busy worker phase must exit 0, got $RC: $(cat "$T/out.txt")"
grep -q 'echo v2' "$T/bin/x.sh" 2>/dev/null \
  && ok || bad "B6: bin/ must deploy while a schema apply is pending: $(cat "$T/bin/x.sh")"
[ "$(d1_count)" = 0 ] && [ "$(deployed)" = 0 ] \
  && ok || bad "B6: the worker phase must be left to the run that holds it: $(cat "$NPXLOG")"
[ -e "$T/state/harness-sync-workers-pending" ] \
  && ok || bad "B6: the skipped run must leave the pending marker for the holder"
grep -q 'worker phase busy' "$ULOG" && ok || bad "B6: the skip must be logged: $(tail -3 "$ULOG")"
exec 6>&-
reset_run
sync
[ "$(d1_count)" = 1 ] && [ "$(d1_lines | grep -c 'ix_b6')" = 1 ] && [ "$(deployed)" = 1 ] \
  && ok || bad "B6: the next run picks the pending worker up: $(cat "$NPXLOG" | cut -c1-200)"
[ ! -e "$T/state/harness-sync-workers-pending" ] \
  && ok || bad "B6: and consumes the marker"

# ============================================================================
# B7. the slow-apply alert: at threshold 0 every apply pages exactly once;
#     at a large threshold none does.
# ============================================================================
reset_run
ALERT_S=0
rm -f "$T/state/worker-schema-applied-jobs" "$T/state/worker-deployed-jobs"
sync
[ "$(grep -c 'schema apply to D1 jobs-test-db has run' "$ALERTS")" = 1 ] \
  && ok || bad "B7: past the threshold, exactly ONE ALERTS line: $(cat "$ALERTS")"
grep -q 'lane.fleet-propagate.harness_sync_schema_alert_s' "$ALERTS" \
  && ok || bad "B7: the alert names the settings row that moves it: $(cat "$ALERTS")"
[ "$(deployed)" = 1 ] && ok || bad "B7: a slow apply that succeeds still deploys"
reset_run
ALERT_S=100000
rm -f "$T/state/worker-schema-applied-jobs" "$T/state/worker-deployed-jobs"
sync
[ ! -s "$ALERTS" ] && ok || bad "B7: under the threshold, no ALERTS line: $(cat "$ALERTS")"
# B7b. the check runs after EVERY round trip, not per chunk: on the
# per-statement path a 40-statement chunk is ~200 s and fleet-propagate's
# `timeout 300` would kill a per-chunk check before it fired. With batching
# refused, the page must name statement 1, the first single that landed.
reset_run
ALERT_S=0; FAIL_MULTI=1
rm -f "$T/state/worker-schema-applied-jobs" "$T/state/worker-deployed-jobs"
sync
[ "$(grep -c 'has run' "$ALERTS")" = 1 ] && grep -q 'at statement 1/' "$ALERTS" \
  && ok || bad "B7b: on the per-statement path the alert must fire at the first round trip past the threshold: $(cat "$ALERTS")"
FAIL_MULTI=""; ALERT_S=100000

# ============================================================================
# B8. THE RACE (#1548 review C1). The worker phase runs OUTSIDE the deploy
#     lock, so a concurrent harness-sync can `git pull` the checkout while
#     `wrangler deploy` bundles. Here the pull lands inside the deploy and
#     brings a schema.sql statement (t_race) together with code that reads it.
#     Whatever goes live must only read tables that were applied first.
# ============================================================================
reset_run; : > "$T/bundles.log"
mkdir -p "$T/ck/worker/jobs/src"
printf 'export default "reads t_001";\n' > "$T/ck/worker/jobs/src/index.js"
commit "the worker's code reads t_001"
git clone -q -b main "$T/origin" "$T/ck2" 2>/dev/null
git -C "$T/ck2" config user.email t@t; git -C "$T/ck2" config user.name t
{ printf '#!/bin/bash\n'
  printf 'cd %q && git pull -q origin main 2>/dev/null\n' "$T/ck2"
  printf 'printf %q >> worker/jobs/schema.sql\n' 'CREATE TABLE IF NOT EXISTS t_race (id INTEGER PRIMARY KEY);\n'
  printf 'printf %q > worker/jobs/src/index.js\n' 'export default "reads t_race";\n'
  printf 'git add -A >/dev/null && git commit -qm race && git push -q origin HEAD:main\n'
  printf 'git -C %q pull -q --ff-only origin main 2>/dev/null\n' "$T/ck"
} > "$T/race-hook.sh"
chmod +x "$T/race-hook.sh"
sync
[ "$RC" = 0 ] && ok || bad "B8: the racing run must exit 0, got $RC: $(cat "$T/out.txt")"
[ ! -e "$T/race-hook.sh" ] && ok || bad "B8: precondition: the race hook never fired (no deploy ran)"
grep -q 'reads t_race' "$T/ck/worker/jobs/src/index.js" \
  && ok || bad "B8: precondition: the pull did not move the checkout mid-deploy"
[ "$(grep -c 'applied=no' "$T/bundles.log")" = 0 ] \
  && ok || bad "B8: a bundle went live reading a table that was never applied: $(cat "$T/bundles.log")"
# the next run owes the moved worker: its apply FAILS, so the new code must not go live
reset_run
FAIL_MATCH="t_race"
sync
FAIL_MATCH=""
grep -q 'statement 1/1 failed against D1 jobs-test-db (CREATE TABLE IF NOT EXISTS t_race' "$ALERTS" \
  && ok || bad "B8: the failed t_race apply must page: $(cat "$ALERTS")"
[ "$(grep -c 'reads t_race' "$T/bundles.log")" = 0 ] \
  && ok || bad "B8: code reading t_race went live although its apply failed (ALERTS says SKIPPED): $(cat "$T/bundles.log")"
# and once the apply succeeds, the new code follows it
reset_run
sync
[ "$(grep -c 'reads t_race";\] applied=yes' "$T/bundles.log")" = 1 ] \
  && ok || bad "B8: after a clean apply the t_race code must deploy, on its schema: $(cat "$T/bundles.log")"
[ "$(grep -c 'applied=no' "$T/bundles.log")" = 0 ] \
  && ok || bad "B8: no bundle may ever read an unapplied table: $(cat "$T/bundles.log")"
[ -z "$(ls -d "$T"/state/worker-snap.* 2>/dev/null)" ] \
  && ok || bad "B8: every pass must remove its snapshot: $(ls -d "$T"/state/worker-snap.* 2>/dev/null)"

echo "harness-sync-d1-batch.bh-1538-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
