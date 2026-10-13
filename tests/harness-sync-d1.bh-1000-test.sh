#!/bin/bash
# tests/harness-sync-d1.bh-1000-test.sh — bin/harness-sync.sh applies a worker's
# schema.sql to D1 BEFORE it deploys that worker. Since BH-1538 the statements
# travel several per `--command` round trip and only what changed is sent;
# tests/harness-sync-d1-batch.bh-1538-test.sh owns those two properties, and
# the round-trip counts below are the BH-1538 ones.
#
# WHY (BH-1000). On 2026-09-19 the hub deployed worker/jobs with a `hub_lease`
# table that existed only in schema.sql — applying it was a hand step and
# nobody did it. Every lease read threw an uncaught D1 error, the 52 `check &&`
# lanes on the hub stopped for half an hour, and nothing paged. So the deploy
# step now carries the schema, and it carries it as one
# `wrangler d1 execute <db> --remote --command "<stmt>"` per statement: `--file`
# fails under the hub's OAuth login with `Authentication error [code: 10000]`,
# which is why S1 asserts there is no `--file` anywhere in the argv log.
#
# THE NEGATIVE CARRIES THE WEIGHT (S2): a failed apply must SKIP the deploy and
# leave the stamp alone. A deploy that ran anyway would be the incident again —
# code in production ahead of its schema — and a stamp written after a failed
# apply would make the box stop retrying.
#
# Run from anywhere: tests/harness-sync-d1.bh-1000-test.sh   (exit 0 = all pass)
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

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"

# ── credentials the worker block needs to exist at all (fake, and never read
#    by anything but the fake npx below) ──────────────────────────────────────
printf 'CLOUDFLARE_ACCOUNT_ID=test-account\nCLOUDFLARE_API_TOKEN=not-a-real-token\n' > "$T/env/cloudflare.env"

# ── a fake npx that RECORDS instead of deploying ─────────────────────────────
# It logs cwd + the full argv (newlines flattened so one invocation is one
# line), and honours NPX_FAIL_D1=<n> to fail the n-th `d1 execute`, and
# NPX_FAIL_MATCH=<s> to fail every `d1 execute` whose SQL contains <s> — since
# BH-1538 a statement travels in a batch first and alone second, so "statement
# 2 fails" is a property of its TEXT, not of a call number.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
NPX_D1_COUNT="$T/d1-count"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
args=$(printf '%s ' "$@" | tr '\n\t' '  ')
printf '%s | %s\n' "$PWD" "$args" >> "$NPX_LOG"
if [ "${3:-}" = "d1" ] && [ "${4:-}" = "execute" ]; then
  n=$(( $(cat "$NPX_D1_COUNT" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$NPX_D1_COUNT"
  if [ -n "${NPX_FAIL_D1:-}" ] && [ "$n" = "$NPX_FAIL_D1" ]; then
    echo "fake npx: forced failure on d1 execute #$n" >&2
    exit 1
  fi
  case "${!#}" in *"${NPX_FAIL_MATCH:-%%never%%}"*)
    echo "fake npx: forced failure on $NPX_FAIL_MATCH" >&2; exit 1 ;; esac
fi
exit 0
EOF
chmod +x "$T/fakebin/npx"

# rsync is what harness-sync deploys bin/ and prompts/ with, and it is not
# installed on every box this suite runs on. Nothing here asserts on the rsync —
# the subject is the D1 apply — so when the real tool is absent a cp stand-in
# takes its place rather than skipping the whole suite. Where rsync exists (CI,
# the hub) the real one is used.
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

# ── a real bare origin and a real clone, same shape as harness-sync-stamps ───
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" \
         "$T/ck/worker/jobs" "$T/ck/worker/plain"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"

# wrangler.jsonc: JSON with comments, and the FIRST database_name in the file
# sits inside a comment. jq cannot read this file at all, and a reader that
# ignored comments would deploy the schema into "decoy-db".
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{
  // "database_name": "decoy-db"  — an old binding, left as a comment
  "name": "jobs-test",
  "main": "src/index.js",
  "d1_databases": [
    { "binding": "DB", "database_name": "jobs-test-db", "database_id": "0000" }
  ]
}
EOF
# Three statements. The middle one holds a `;` inside a string literal and the
# file opens with a full-line comment that also holds one: both are the split
# bugs this whole block exists to avoid.
cat > "$T/ck/worker/jobs/schema.sql" <<'EOF'
-- t_one; the first table. This comment is not a statement; it must be dropped.
CREATE TABLE IF NOT EXISTS t_one (
  id   INTEGER PRIMARY KEY,
  note TEXT                       -- the row's own note; free text
);

INSERT OR IGNORE INTO t_one (id, note) VALUES
  (1, 'one build per repo; raise this row');

CREATE INDEX IF NOT EXISTS ix_three ON t_one(note);
EOF
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

FAIL_D1=""; FAIL_MATCH=""
sync() { # sync [--check] -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH" \
           NPX_FAIL_D1="$FAIL_D1" NPX_FAIL_MATCH="$FAIL_MATCH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; rm -f "$T/d1-count"; }
d1_lines()   { grep -F 'd1 execute' "$NPXLOG" 2>/dev/null; }
d1_count()   { d1_lines | grep -c . ; }
# "did worker <name> deploy in this run" — the fake logs its cwd, which is the
# worker directory the deploy ran from.
deployed()   { grep -F 'wrangler deploy' "$NPXLOG" 2>/dev/null | grep -cF "/worker/$1 "; }

# ── S0. SAFETY PROBE, before anything else ──────────────────────────────────
# harness-sync's deploy path rsyncs $CHECKOUT/{bin,prompts,fly,catalog} into
# $HARNESS and copies fleet.conf over it. If it does not honour $HARNESS, every
# deploy below lands on the REAL /root/harness. Behavioural, not a grep: a DIRTY
# checkout refuses at rc 30 and writes its REFUSED line to $HARNESS/logs/ALERTS.log
# before reaching any rsync. Not in the scratch tree = abort without deploying.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $ALERTS) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-d1.bh-1000-test: 0 pass, 1 fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ============================================================================
# S1. the schema goes on before the code does — three statements, in file
#     order, by --command, then the deploy. BH-1538: all three fit one chunk,
#     so they travel in ONE round trip (was three).
# ============================================================================
sync
[ "$RC" = 0 ] && ok || bad "a clean deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(d1_count)" = 1 ] \
  && ok || bad "expected ONE batched d1 execute call, got $(d1_count): $(cat "$NPXLOG")"
mapfile -t D1 < <(d1_lines)
case "${D1[0]:-}" in *"CREATE TABLE IF NOT EXISTS t_one"*"INSERT OR IGNORE INTO t_one"*"CREATE INDEX IF NOT EXISTS ix_three"*) ok ;;
  *) bad "the round trip must carry the CREATE TABLE, the INSERT and the CREATE INDEX, in file order: ${D1[0]:-<none>}" ;; esac
case "${D1[0]:-}" in *"INSERT OR IGNORE INTO t_one"*"one build per repo; raise this row"*) ok ;;
  *) bad "the INSERT must travel whole, including its ';'-bearing literal: ${D1[0]:-<none>}" ;; esac
case "${D1[0]:-}" in *"t_one; the first table"*) bad "the full-line comment must be dropped, not sent: ${D1[0]}" ;; *) ok ;; esac
case "${D1[0]:-}" in *"--command"*) ok ;; *) bad "the apply must use --command: ${D1[0]:-<none>}" ;; esac
# wrangler's own --yes, not npx's: `d1 execute` against a REMOTE database
# prompts from a TTY, and `timeout 120` would turn a hand-run harness-sync's
# prompt into a false "statement 1/N failed" ALERT and a skipped deploy.
[ "$(grep -c -- 'd1 execute .* --yes --command' "$NPXLOG")" = "$(d1_count)" ] \
  && ok || bad "every apply call must pass wrangler's --yes so a TTY prompt cannot look like a failure: $(cat "$NPXLOG")"
[ "$(grep -c -- '--file' "$NPXLOG")" = 0 ] \
  && ok || bad "--file must never appear: it 401s under the hub's OAuth login. $(grep -- '--file' "$NPXLOG")"
[ "$(grep -cF 'jobs-test-db' "$NPXLOG")" = "$(d1_count)" ] \
  && ok || bad "every apply call must name the jsonc's database_name: $(cat "$NPXLOG")"
[ "$(grep -cF 'decoy-db' "$NPXLOG")" = 0 ] \
  && ok || bad "a commented-out binding was used as the database name: $(cat "$NPXLOG")"
LAST_D1=$(grep -nF 'd1 execute' "$NPXLOG" | tail -1 | cut -d: -f1)
FIRST_DEPLOY=$(grep -nF 'wrangler deploy' "$NPXLOG" | head -1 | cut -d: -f1)
[ -n "$LAST_D1" ] && [ -n "$FIRST_DEPLOY" ] && [ "$LAST_D1" -lt "$FIRST_DEPLOY" ] \
  && ok || bad "every apply must precede every deploy (last d1 line $LAST_D1, first deploy line $FIRST_DEPLOY): $(cat "$NPXLOG")"
[ "$(deployed jobs)" = 1 ] && ok || bad "worker jobs must deploy after a clean apply: $(cat "$NPXLOG")"
[ -s "$T/state/worker-deployed-jobs" ] \
  && ok || bad "a deployed worker must be stamped"
# The stamp is the blob sha AND the database the statements landed in. The sha
# alone answers "is this schema applied?" with "is this schema applied
# SOMEWHERE?", and the two questions come apart the moment the binding moves
# (BH-1000 review round 1, I2).
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" \
  = "$(git -C "$T/ck" hash-object worker/jobs/schema.sql) jobs-test-db" ] \
  && ok || bad "a clean apply must stamp the schema BLOB sha AND its database, or S5's skip can never fire: $(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)"
grep -q 'schema.sql applied (3 statements; 1 round trip(s); full apply) to jobs-test-db' "$ULOG" \
  && ok || bad "the apply must be logged: $(cat "$ULOG")"
# the worker with no schema.sql deploys exactly as it did before this change
[ "$(deployed plain)" = 1 ] && ok || bad "worker plain (no schema.sql) must still deploy: $(cat "$NPXLOG")"
[ "$(d1_lines | grep -cF '/worker/plain ')" = 0 ] \
  && ok || bad "worker plain has no D1 binding and no schema.sql — it must run no d1 execute"
[ ! -s "$ALERTS" ] && ok || bad "a clean run must write no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# S2. THE NEGATIVE. Statement 2 fails: no deploy, no stamp, one ALERTS line
#     naming the statement — and the other worker in the same run is untouched.
#     BH-1538: the batch carrying it fails first, then the three are re-sent
#     one at a time and the apply stops at statement 2 — 1 + 2 round trips.
# ============================================================================
reset_run
# The schema stamp from S1 is burned with the deploy stamps: S1 applied this
# exact schema.sql, and since BH-1000 fix round 1 an unchanged schema is
# skipped (S5 owns that). Clearing it is what keeps THIS case about a failing
# apply rather than about the skip.
rm -f "$T/state/worker-deployed-jobs" "$T/state/worker-deployed-plain" \
      "$T/state/worker-schema-applied-jobs" "$T/state/worker-schema-applied-plain"
FAIL_MATCH="one build per repo"
sync
[ "$RC" = 0 ] && ok || bad "one worker's failed apply must not fail the whole sync, got $RC: $(cat "$T/out.txt")"
[ "$(d1_count)" = 3 ] \
  && ok || bad "the apply must STOP at the first failure (expected the batch + 2 singles = 3 calls, got $(d1_count)): $(cat "$NPXLOG")"
[ "$(d1_lines | grep -F 'CREATE INDEX IF NOT EXISTS ix_three' | grep -cv 'CREATE TABLE')" = 0 ] \
  && ok || bad "statement 3 must never be sent alone after statement 2 failed: $(cat "$NPXLOG")"
[ "$(deployed jobs)" = 0 ] \
  && ok || bad "a worker whose schema did not apply must NOT deploy — that is the incident: $(cat "$NPXLOG")"
[ ! -f "$T/state/worker-deployed-jobs" ] \
  && ok || bad "a failed apply must not stamp the worker, or the box stops retrying"
[ ! -f "$T/state/worker-schema-applied-jobs" ] \
  && ok || bad "a failed apply must not stamp the SCHEMA either, or the next run skips the apply it never finished"
[ "$(grep -c . "$ALERTS")" = 1 ] \
  && ok || bad "exactly one ALERTS line, got $(grep -c . "$ALERTS"): $(cat "$ALERTS")"
grep -q 'statement 2/3' "$ALERTS" \
  && ok || bad "the ALERTS line must name which statement failed: $(cat "$ALERTS")"
grep -q 'worker/jobs schema.sql statement 2/3 failed against D1 jobs-test-db' "$ALERTS" \
  && ok || bad "the ALERTS line must name the worker and the database: $(cat "$ALERTS")"
grep -q 'SKIPPED' "$ALERTS" \
  && ok || bad "the ALERTS line must say the deploy was skipped: $(cat "$ALERTS")"
grep -q "one build per repo" "$ALERTS" \
  && ok || bad "the ALERTS line must quote the head of the failing statement: $(cat "$ALERTS")"
[ "$(grep -c 'schema.sql applied' "$ULOG")" = 1 ] \
  && ok || bad "a failed apply must not log an 'applied' line (S1's line is the only one): $(grep -c 'schema.sql applied' "$ULOG")"
[ "$(deployed plain)" = 1 ] \
  && ok || bad "the other worker must still deploy in the same run: $(cat "$NPXLOG")"
[ -s "$T/state/worker-deployed-plain" ] && ok || bad "worker plain must be stamped in the same run"

# ============================================================================
# S3. the retry: with the fault cleared, the next run RESUMES at the statement
#     that failed and deploys.
#     CONTRACT CHANGE (BH-1555, lead review B2 — deliberate, not a relaxation):
#     until BH-1555 nothing remembered a partial apply and the retry restarted
#     at statement 1. Now every statement D1 accepted is recorded in
#     state/worker-schema-progress-jobs, so S2's statement 1 (which landed on
#     the per-statement fallback before statement 2 failed) is NOT re-sent. The
#     retry is still exactly one round trip, and it still ends in the deploy.
#     S3b below pins the old from-the-top path: without the progress file the
#     retry starts at statement 1 exactly as before.
# ============================================================================
reset_run
: > "$ULOG"
FAIL_MATCH=""
sync
[ "$RC" = 0 ] && ok || bad "the retry run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_count)" = 1 ] && [ "$(d1_lines | grep -c 'ix_three')" = 1 ] \
  && ok || bad "the retry must apply the 2 remaining statements in one batch, got $(d1_count): $(cat "$NPXLOG")"
mapfile -t D1R < <(d1_lines)
case "${D1R[0]:-}" in
  *"CREATE TABLE IF NOT EXISTS t_one"*) bad "the retry must NOT re-send statement 1, which S2 already landed: ${D1R[0]}" ;;
  *"one build per repo"*) ok ;;
  *) bad "the retry must resume at statement 2 (the one that failed): ${D1R[0]:-<none>}" ;;
esac
grep -q 'resuming at statement 2/3' "$ULOG" \
  && ok || bad "the resume must be logged as 'resuming at statement 2/3': $(cat "$ULOG")"
[ "$(deployed jobs)" = 1 ] && ok || bad "the retry must deploy the worker: $(cat "$NPXLOG")"
[ -s "$T/state/worker-deployed-jobs" ] && ok || bad "the retry must stamp the worker"
[ ! -e "$T/state/worker-schema-progress-jobs" ] \
  && ok || bad "a completed apply must remove its progress file"
[ ! -s "$ALERTS" ] && ok || bad "a successful retry must write no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# S3b. deleting the progress file restores the pre-BH-1555 recovery: fail the
#      same way as S2, remove state/worker-schema-progress-jobs by hand, and
#      the retry applies all 3 statements from the top in one batch.
# ============================================================================
reset_run
rm -f "$T/state/worker-deployed-jobs" "$T/state/worker-schema-applied-jobs"
FAIL_MATCH="one build per repo"
sync
[ -s "$T/state/worker-schema-progress-jobs" ] \
  && ok || bad "S3b: precondition — the failed apply must leave a progress file: $(cat "$ULOG" | tail -3)"
rm -f "$T/state/worker-schema-progress-jobs"
reset_run
FAIL_MATCH=""
sync
[ "$RC" = 0 ] && ok || bad "S3b: the retry run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_count)" = 1 ] && [ "$(d1_lines | grep -c 'ix_three')" = 1 ] \
  && ok || bad "S3b: without progress the retry must apply all 3 statements from the top (one batch), got $(d1_count): $(cat "$NPXLOG")"
mapfile -t D1R < <(d1_lines)
case "${D1R[0]:-}" in *"CREATE TABLE IF NOT EXISTS t_one"*) ok ;; *) bad "S3b: without progress the retry must start at statement 1: ${D1R[0]:-<none>}" ;; esac
[ "$(deployed jobs)" = 1 ] && ok || bad "S3b: the retry must deploy the worker: $(cat "$NPXLOG")"
[ -s "$T/state/worker-deployed-jobs" ] && ok || bad "S3b: the retry must stamp the worker"
[ ! -s "$ALERTS" ] && ok || bad "S3b: a successful retry must write no ALERTS line: $(cat "$ALERTS")"

# ============================================================================
# S4. wrangler.toml is read too — the other config format is not a silent skip
# ============================================================================
reset_run
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
# database_name = "decoy-toml-db"
[[d1_databases]]
binding = "DB"
preview_database_name = "preview-toml-db"
database_name = "toml-db"
EOF
printf 'CREATE TABLE IF NOT EXISTS t_toml (id INTEGER PRIMARY KEY);\n' > "$T/ck/worker/plain/schema.sql"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "plain gains a d1 binding and a schema"
git -C "$T/ck" push -q origin main
sync
[ "$RC" = 0 ] && ok || bad "the toml run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_lines | grep -cF 'toml-db')" = 1 ] \
  && ok || bad "a wrangler.toml database_name must be honoured: $(cat "$NPXLOG")"
[ "$(d1_lines | grep -cF 'decoy-toml-db')" = 0 ] \
  && ok || bad "a commented-out toml binding was used as the database name: $(cat "$NPXLOG")"
# `preview_database_name` ENDS in the key we are looking for, so an unanchored
# match takes the preview database — and the schema lands in the wrong D1 while
# every log line reads as a success.
[ "$(d1_lines | grep -cF 'preview-toml-db')" = 0 ] \
  && ok || bad "preview_database_name was matched as database_name — the schema went to the preview DB: $(cat "$NPXLOG")"
[ "$(d1_lines | grep -cF '/worker/plain ')" = 1 ] \
  && ok || bad "the toml worker's apply must run from its own directory: $(cat "$NPXLOG")"
[ "$(deployed plain)" = 1 ] && ok || bad "the toml worker must deploy after its apply: $(cat "$NPXLOG")"
grep -q 'schema.sql applied (1 statements; 1 round trip(s); full apply) to toml-db' "$ULOG" \
  && ok || bad "the toml worker's apply must be logged: $(tail -3 "$ULOG")"

# ============================================================================
# S5. ONCE PER SCHEMA, NOT ONCE PER DEPLOY (BH-1000 fix round 1).
#     harness-sync runs under fleet-propagate's `timeout 300` on the */5 deploy
#     path, and worker/jobs's real schema.sql is ~70 statements x one remote
#     wrangler round trip. Re-applying all of them every time index.js changes
#     is a live chance of being killed mid-apply — which leaves the worker
#     undeployed and unstamped, writes no ALERTS line (that one fires only on a
#     FAILED statement), and restarts from statement 1 five minutes later,
#     forever. So an unchanged schema.sql is skipped, and the deploy still runs.
# ============================================================================
reset_run
printf 'export default { fetch: () => new Response("v2") };\n' > "$T/ck/worker/jobs/code.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "worker/jobs code moves, schema.sql does not"
git -C "$T/ck" push -q origin main
sync
[ "$RC" = 0 ] && ok || bad "S5: a code-only worker change must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_lines | grep -cF 'jobs-test-db')" = 0 ] \
  && ok || bad "S5: an unchanged schema.sql must run NO d1 execute — that is the timeout this fix removes: $(cat "$NPXLOG")"
[ "$(deployed jobs)" = 1 ] \
  && ok || bad "S5: the worker must still deploy when its schema is already applied: $(cat "$NPXLOG")"
grep -q 'worker jobs schema.sql unchanged' "$ULOG" \
  && ok || bad "S5: the skip must be logged, not silent: $(tail -3 "$ULOG")"
[ ! -s "$ALERTS" ] && ok || bad "S5: a skipped apply is not an alert: $(cat "$ALERTS")"

# S5b. the stamp is keyed on the schema BLOB: an edit re-applies. BH-1538: it
#      re-applies WHAT CHANGED — the previous blob is read back out of git and
#      only the new statement is sent (was: every statement, in full). The
#      stamp still moves to the new blob, which S5c proves.
reset_run
printf 'CREATE INDEX IF NOT EXISTS ix_four ON t_one(id);\n' >> "$T/ck/worker/jobs/schema.sql"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "schema.sql gains a fourth statement"
git -C "$T/ck" push -q origin main
sync
[ "$RC" = 0 ] && ok || bad "S5b: the schema-change run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_count)" = 1 ] \
  && ok || bad "S5b: a one-statement edit must be ONE round trip, got $(d1_count): $(cat "$NPXLOG")"
mapfile -t D1S < <(d1_lines)
case "${D1S[0]:-}" in *"CREATE TABLE IF NOT EXISTS t_one"*) bad "S5b: an already-applied statement was re-sent: ${D1S[0]}" ;; *) ok ;; esac
case "${D1S[0]:-}" in *"ix_four"*) ok ;; *) bad "S5b: the new statement must be applied: ${D1S[0]:-<none>}" ;; esac
[ "$(deployed jobs)" = 1 ] && ok || bad "S5b: the worker must deploy after the re-apply: $(cat "$NPXLOG")"
grep -q 'schema.sql applied (1 statements; 1 round trip(s); delta vs ' "$ULOG" \
  && ok || bad "S5b: the re-apply must be logged as a delta with its count: $(tail -3 "$ULOG")"

# S5c. and the very next code-only change skips again (the new stamp took)
reset_run
printf 'export default { fetch: () => new Response("v3") };\n' > "$T/ck/worker/jobs/code.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "worker/jobs code moves again"
git -C "$T/ck" push -q origin main
sync
[ "$(d1_lines | grep -cF 'jobs-test-db')" = 0 ] \
  && ok || bad "S5c: the stamp written after the re-apply must skip the next deploy's apply: $(cat "$NPXLOG")"
[ "$(deployed jobs)" = 1 ] && ok || bad "S5c: and the code still deploys: $(cat "$NPXLOG")"

# ============================================================================
# S6. A present schema.sql that reads as ZERO statements is a FAILURE, not a
#     no-op: "applied (0 statements)" followed by a deploy is the incident with
#     a tidier log. No deploy, no stamp, one ALERTS line.
# ============================================================================
reset_run
rm -f "$T/state/worker-deployed-jobs" "$T/state/worker-schema-applied-jobs"
: > "$T/ck/worker/jobs/schema.sql"
printf -- '-- a comment and nothing else; no statement here\n' > "$T/ck/worker/jobs/schema.sql"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "schema.sql reads as nothing"
git -C "$T/ck" push -q origin main
sync
[ "$RC" = 0 ] && ok || bad "S6: one worker's empty schema must not fail the whole sync, got $RC: $(cat "$T/out.txt")"
[ "$(deployed jobs)" = 0 ] \
  && ok || bad "S6: a worker whose schema read as 0 statements must NOT deploy: $(cat "$NPXLOG")"
[ ! -f "$T/state/worker-deployed-jobs" ] \
  && ok || bad "S6: a 0-statement read must not stamp the worker"
[ ! -f "$T/state/worker-schema-applied-jobs" ] \
  && ok || bad "S6: a 0-statement read must not stamp the schema"
[ "$(grep -c '0 statements' "$ALERTS")" = 1 ] \
  && ok || bad "S6: exactly one ALERTS line naming the empty read: $(cat "$ALERTS")"
[ "$(grep -c 'schema.sql applied (0 statements' "$ULOG")" = 0 ] \
  && ok || bad "S6: 'applied (0 statements)' must never be logged as a success: $(tail -3 "$ULOG")"

# ============================================================================
# S7. THE STAMP NAMES ITS DATABASE (BH-1000 review round 1, I2).
#     "This schema is applied" is only ever true OF A DATABASE. Keyed on the
#     blob sha alone, pointing the worker at a different D1 — a new binding, a
#     restored database, a rename — leaves the stamp matching, so the apply is
#     skipped forever and the code deploys onto an empty database that answers
#     `503 <table> schema not applied` until a human deletes the stamp file.
#
#     S6 left schema.sql readable as zero statements, so S7a first puts a real
#     schema back and lets it apply and stamp. S7b then moves the BINDING and
#     nothing else — the blob sha is byte-identical across the two runs, so a
#     re-apply there can only have come from the database half of the stamp.
# ============================================================================
reset_run
cat > "$T/ck/worker/jobs/schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS t_one (id INTEGER PRIMARY KEY, note TEXT);
INSERT OR IGNORE INTO t_one (id, note) VALUES (1, 'seed');
CREATE INDEX IF NOT EXISTS ix_three ON t_one(note);
EOF
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "a real schema.sql again"
git -C "$T/ck" push -q origin main
sync
SHA_BEFORE=$(git -C "$T/ck" hash-object worker/jobs/schema.sql)
[ "$RC" = 0 ] && ok || bad "S7a: the restoring run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" = "$SHA_BEFORE jobs-test-db" ] \
  && ok || bad "S7a: the stamp must carry the blob sha AND the database it applied to: $(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)"

# S7b. the binding moves, schema.sql does NOT
reset_run
sed -i 's/"database_name": "jobs-test-db"/"database_name": "jobs-test-db2"/' "$T/ck/worker/jobs/wrangler.jsonc"
printf 'export default { fetch: () => new Response("v4") };\n' > "$T/ck/worker/jobs/code.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "worker/jobs points at another D1; schema.sql is untouched"
git -C "$T/ck" push -q origin main
[ "$(git -C "$T/ck" hash-object worker/jobs/schema.sql)" = "$SHA_BEFORE" ] \
  && ok || bad "S7b: precondition — schema.sql must be byte-identical to S7a's, or this case proves nothing"
sync
[ "$RC" = 0 ] && ok || bad "S7b: the re-pointed run must exit 0, got $RC: $(cat "$T/out.txt")"
[ "$(d1_lines | grep -cF 'jobs-test-db2')" = 1 ] \
  && [ "$(d1_lines | grep -F 'jobs-test-db2' | grep -c 'CREATE TABLE IF NOT EXISTS t_one.*INSERT OR IGNORE.*ix_three')" = 1 ] \
  && ok || bad "S7b: a new database must get the WHOLE schema (not a skip, not a delta): $(cat "$NPXLOG")"
[ "$(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)" = "$SHA_BEFORE jobs-test-db2" ] \
  && ok || bad "S7b: the stamp must name the database it applied to: $(cat "$T/state/worker-schema-applied-jobs" 2>/dev/null)"
[ "$(deployed jobs)" = 1 ] && ok || bad "S7b: and the worker still deploys: $(cat "$NPXLOG")"

# S7c. the very next code-only change skips again — the pair stamp took, and
#      this run is the proof that S7b measured the DATABASE and not a lost stamp.
reset_run
printf 'export default { fetch: () => new Response("v5") };\n' > "$T/ck/worker/jobs/code.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm "worker/jobs code moves once more"
git -C "$T/ck" push -q origin main
sync
[ "$(d1_count)" = 0 ] \
  && ok || bad "S7c: an unchanged schema on an unchanged database must still skip: $(cat "$NPXLOG")"
[ "$(deployed jobs)" = 1 ] && ok || bad "S7c: and the code still deploys: $(cat "$NPXLOG")"

echo "harness-sync-d1.bh-1000-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
