#!/bin/bash
# tests/model-prices-deploy-sync.bh-1890-test.sh — the BH-1566 deploy price hook
# runs detached from harness-sync, and refuses to POST on an empty table read
# (BH-1890).
#
# WHY. bin/harness-sync.sh ran bin/model-prices-deploy-sync.sh in the
# foreground, inside bin/fleet-propagate.sh's `timeout 300`: a slow refresh
# (up to 150 s) plus a slow GET and POST pushed the whole deploy past its
# budget and recorded a false `hub=fail(rc=124)`. And a table GET that came back
# with no models (MIN=0 accepts it) made every catalog model look missing, so
# the hook POSTed the whole catalog over the live rates.
#
#   D1  a slow hook no longer holds harness-sync: rc 0 under `timeout 5`, and
#       the hook still finishes afterwards
#   D2  the hook's output goes to its own logs/model-prices-deploy-sync.log,
#       and harness-sync's stdout stays one status line
#   D3  the hook does not inherit its caller's locks: a flock the caller holds
#       on fd 9 around harness-sync (fleet-propagate's shape) is free once
#       harness-sync returns, while the hook is still running
#   E1  empty table read + non-empty state/model-prices.json: no POST, one
#       alert, no stamp, the state file untouched
#   E2  empty table + no state file (a fresh hub): the POST goes ahead
#   E3  the normal case: only the missing model is POSTed
#   E4  empty table + a parseable EMPTY state file: the POST goes ahead
#   E5  empty table + an unparseable state file: refused (fail closed)
#
# SCRIPT= points the E cases at another copy of the hook, HSYNC= points D1/D2
# at another harness-sync (red-first against main).
# Run from anywhere: tests/model-prices-deploy-sync.bh-1890-test.sh  (0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null \
  && command -v flock >/dev/null && command -v rsync >/dev/null && command -v timeout >/dev/null \
  || { echo "jq/python3/git/flock/rsync/timeout missing — skipping"; exit 0; }
SUT="${SCRIPT:-$DIR/bin/model-prices-deploy-sync.sh}"
HSYNC="${HSYNC:-$DIR/bin/harness-sync.sh}"

# The fixtures below are copied from tests/model-prices-deploy-sync.bh-1566-test.sh
# (not sourced from it: a suite is not a library).
# ── fixtures ─────────────────────────────────────────────────────────────────
# catalog <file> <with-new 0|1> — the committed catalog. Five models the table
# already has, plus (with-new=1) claude-opus-5-5, the model a PR just priced.
catalog() {
  python3 - "$1" "$2" <<'PY'
import json, sys
per = {
  "claude-fable-5-1": {"prompt": 1.5e-5, "completion": 7.5e-5, "cache_read": 1.5e-6, "cache_write": 1.875e-5, "slug": "anthropic/claude-fable-5.1"},
  "claude-opus-5":    {"prompt": 5e-6,   "completion": 2.5e-5, "cache_read": 5e-7,   "cache_write": 6.25e-6,  "slug": "anthropic/claude-opus-5"},
  "claude-sonnet-5":  {"prompt": 3e-6,   "completion": 1.5e-5, "cache_read": 3e-7,   "cache_write": 3.75e-6,  "slug": "anthropic/claude-sonnet-5"},
  "claude-haiku-4-5": {"prompt": 1e-6,   "completion": 5e-6,   "cache_read": 1e-7,   "cache_write": 1.25e-6,  "slug": "anthropic/claude-haiku-4.5"},
  "gpt-6-astra":      {"prompt": 2.5e-6, "completion": 1e-5,   "cache_read": 2.5e-7, "cache_write": None,     "slug": "openai/gpt-6-astra"},
}
if sys.argv[2] == "1":
    per["claude-opus-5-5"] = {"prompt": 6e-6, "completion": 3e-5, "cache_read": 6e-7, "cache_write": 7.5e-6,
                              "slug": "anthropic/claude-opus-5.5"}
json.dump({"updated_at": "2026-09-23T00:00:00Z", "source": "catalog", "per_token": per}, open(sys.argv[1], "w"), indent=2)
PY
}

# table <file> — the DB as it stood before the PR: the five old models, with
# sonnet at a LIVE rate that differs from the catalog (3.1e-6), so a seed that
# overwrote existing rows would show.
table() {
  python3 - "$1" <<'PY'
import json, sys
per = {m: {"prompt": 1e-6, "completion": 5e-6, "source": "openrouter"} for m in
       ["claude-fable-5-1", "claude-opus-5", "claude-haiku-4-5", "gpt-6-astra"]}
per["claude-sonnet-5"] = {"prompt": 3.1e-6, "completion": 1.5e-5, "source": "openrouter"}
json.dump({"updated_at": "2026-09-23T04:30:00Z", "source": "harness-jobs/model_prices", "per_token": per},
          open(sys.argv[1], "w"), indent=2)
PY
}

# stubs <harness> <bin-dir> — every FIXTURE the script calls, written into
# <bin-dir> with the scratch paths of <harness> baked in. <bin-dir> is
# <harness>/bin for the unit cases, and the CHECKOUT's bin/ for S (harness-sync
# rsyncs the checkout's bin/ over the live one, so a stub written only into the
# live bin/ would be overwritten by the deploy it is meant to observe).
stubs() {
  local h="$1" b="$2"
  mkdir -p "$b/lib"
  # FIXTURE jobs-client: sourceable (model_prices_get/put) and executable (every
  # verb answers rc 2, "no such row", so harness-sync's own calls stay inert).
  cat > "$b/jobs-client.sh" <<SH
#!/bin/bash
# FIXTURE jobs-client (tests/model-prices-deploy-sync.bh-1890-test.sh)
model_prices_get() {
  echo get >> "$h/calls.log"
  [ -f "$h/get-fail" ] && return 1
  python3 - "$h/db.json" "\$1" "\${MODEL_PRICES_MIN:-5}" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
if len(b.get("per_token") or {}) < int(sys.argv[3]): sys.exit(1)
json.dump(b, open(sys.argv[2], "w"), indent=2)
PY
}
model_prices_put() {
  echo "put \${2:-openrouter} \$(jq -r '.per_token | keys | join(",")' "\$1")" >> "$h/calls.log"
  [ -f "$h/put-fail" ] && return 1
  python3 - "$h/db.json" "\$1" "\${2:-openrouter}" <<'PY'
import json, sys
db = json.load(open(sys.argv[1])); new = json.load(open(sys.argv[2]))["per_token"]
for m, r in new.items():
    row = {k: r.get(k) for k in ("prompt", "completion", "cache_read", "cache_write", "slug")}
    row["source"] = sys.argv[3]
    db["per_token"][m] = row
json.dump(db, open(sys.argv[1], "w"), indent=2)
PY
}
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then exit 2; fi
SH
  chmod +x "$b/jobs-client.sh"
  # FIXTURE refresh: records the call; with $h/refresh-prices present it prices
  # those models into the table and the state file, as the real one would.
  cat > "$b/update-model-prices.sh" <<SH
#!/bin/bash
# FIXTURE update-model-prices (tests/model-prices-deploy-sync.bh-1890-test.sh)
echo refresh >> "$h/calls.log"
[ -f "$h/refresh-prices" ] || exit 0
python3 - "$h/db.json" "$h/state/model-prices.json" "$h/refresh-prices" <<'PY'
import json, os, sys
new = json.load(open(sys.argv[3]))
db = json.load(open(sys.argv[1]))
for m, r in new.items(): db["per_token"][m] = dict(r, source="openrouter")
json.dump(db, open(sys.argv[1], "w"), indent=2)
st = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {"per_token": {}}
st["per_token"].update(new)
json.dump(st, open(sys.argv[2], "w"), indent=2)
PY
exit 0
SH
  chmod +x "$b/update-model-prices.sh"
  cat > "$b/hub-lease.sh" <<SH
#!/bin/bash
# FIXTURE hub-lease
[ -f "$h/lease-lost" ] && exit 1
exit 0
SH
  chmod +x "$b/hub-lease.sh"
  cat > "$b/lane-alert.sh" <<SH
#!/bin/bash
# FIXTURE lane-alert
printf '%s\n' "\$*" >> "$h/alerts.log"
exit 0
SH
  chmod +x "$b/lane-alert.sh"
  cp "$DIR/bin/model-prices-sync.sh" "$b/model-prices-sync.sh"
  cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$b/lib/"
  [ -f "$DIR/bin/lib/lanes-load.sh" ] && cp "$DIR/bin/lib/lanes-load.sh" "$b/lib/"
  [ -f "$SUT" ] && cp "$SUT" "$b/model-prices-deploy-sync.sh"
  chmod +x "$b"/*.sh
}

n()   { local c; c=$(grep -c -e "$1" "$2" 2>/dev/null); echo "${c:-0}"; }
has() { jq -e --arg m "$2" '(.per_token // .) | has($m)' "$1" >/dev/null 2>&1; }
# wait_for <file> <seconds> — bounded poll, 0.2 s steps.
wait_for() {
  local i=0 max=$(( $2 * 5 ))
  while [ ! -e "$1" ] && [ "$i" -lt "$max" ]; do sleep 0.2; i=$((i+1)); done
  [ -e "$1" ]
}

# ============================================================================
# D. harness-sync launches the hook DETACHED. A real origin and clone, the real
#    bin/harness-sync.sh deploy path. The checkout's hook is a stub that prints
#    a marker, blocks until the test creates $E/hook-release (bounded, 30 s)
#    and then writes $E/hook-done — so the hook is provably still running
#    when harness-sync returns, whatever the load on the box.
# ============================================================================
E="$T/e"
mkdir -p "$E/logs" "$E/state" "$E/locks" "$E/flags" "$E/env" "$E/bin" "$E/prompts" "$E/fly" "$E/catalog"
cp "$DIR/bin/alert-line.sh" "$E/bin/"
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$E/ck" 2>/dev/null
git -C "$E/ck" config user.email t@t; git -C "$E/ck" config user.name t
mkdir -p "$E/ck/bin" "$E/ck/prompts" "$E/ck/fly" "$E/ck/catalog"
stubs "$E" "$E/ck/bin"
cat > "$E/ck/bin/model-prices-deploy-sync.sh" <<SH
#!/bin/bash
# FIXTURE slow hook (tests/model-prices-deploy-sync.bh-1890-test.sh)
echo "hook-stdout-marker"
i=0
while [ ! -e "$E/hook-release" ] && [ "\$i" -lt 150 ]; do sleep 0.2; i=\$((i+1)); done
echo done > "$E/hook-done"
SH
chmod +x "$E/ck/bin/model-prices-deploy-sync.sh"
printf 'p\n' > "$E/ck/prompts/p.md"; printf 'f\n' > "$E/ck/fly/f.txt"; printf 'fleet\n' > "$E/ck/fleet.conf"
catalog "$E/ck/catalog/model-prices.json" 0
git -C "$E/ck" add -A >/dev/null; git -C "$E/ck" commit -qm seed
git -C "$E/ck" branch -M main 2>/dev/null
git -C "$E/ck" push -q origin main
git -C "$E/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1
table "$E/db.json"; cp "$E/db.json" "$E/state/model-prices.json"
: > "$E/calls.log"; : > "$E/alerts.log"
deploy() { # deploy <timeout-seconds> [lockfile the caller holds on fd 9]
  ( export HARNESS="$E" HARNESS_CHECKOUT="$E/ck" HUB_BOX_NAME=hubbox BOX_NAME=hubbox
    if [ -n "${2:-}" ]; then exec 9>"$2"; flock -n 9 || exit 99; fi
    timeout "$1" bash "$HSYNC" ) >"$T/sout.txt" 2>"$T/serr.txt"
  RC=$?
}
# SAFETY PROBE first (as in the bh-1566 suite): a dirty checkout refuses at
# rc 30 BEFORE any rsync, into $HARNESS/logs. If the line is not in the scratch
# tree, harness-sync is not honouring $HARNESS and a deploy would rsync this
# fixture over the live /root/harness.
echo probe >> "$E/ck/bin/hub-lease.sh"
deploy 60
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$E/logs/ALERTS.log" 2>/dev/null; then
  bad "D: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — not running the deploy path"
else
  git -C "$E/ck" checkout -q -- bin/hub-lease.sh
  : > "$E/logs/ALERTS.log"; rm -f "$E/state/harness-sync-last-refused"
  S0=$(date +%s)
  deploy 5
  EL=$(( $(date +%s) - S0 ))
  [ "$RC" = 0 ] && ok \
    || bad "D1: a slow hook must not hold harness-sync past its timeout, rc=$RC (124 = killed): $(cat "$T/serr.txt")"
  [ "$EL" -lt 5 ] && ok || bad "D1: harness-sync must return in under 5 s, took ${EL}s"
  [ ! -e "$E/hook-done" ] && ok || bad "D1: harness-sync returned only after the hook finished (it ran in the foreground)"
  : > "$E/hook-release"
  wait_for "$E/hook-done" 15 && ok || bad "D1: the detached hook must still finish after harness-sync returns"
  grep -qx 'hook-stdout-marker' "$E/logs/model-prices-deploy-sync.log" 2>/dev/null && ok \
    || bad "D2: the hook's output must land in logs/model-prices-deploy-sync.log, got: $(cat "$E/logs/model-prices-deploy-sync.log" 2>&1)"
  ! grep -q 'hook-stdout-marker' "$T/sout.txt" && [ "$(wc -l < "$T/sout.txt")" = 1 ] && ok \
    || bad "D2: harness-sync's stdout must stay one status line, got: $(cat "$T/sout.txt")"
  # D3: fleet-propagate holds locks/fleet-propagate.lock on fd 9 around this
  # deploy. Once harness-sync returns, that lock must be free even though the
  # detached hook is still blocked on its release file.
  rm -f "$E/hook-release" "$E/hook-done"
  deploy 10 "$E/locks/fleet-propagate.lock"
  [ "$RC" = 0 ] && ok || bad "D3: the deploy under a caller-held fd 9 must succeed, rc=$RC: $(cat "$T/serr.txt")"
  [ ! -e "$E/hook-done" ] && ok || bad "D3: the hook must still be running when the lock is checked"
  flock -n "$E/locks/fleet-propagate.lock" true && ok \
    || bad "D3: the caller's fd-9 lock is still held after harness-sync returned — the detached hook inherited it"
  : > "$E/hook-release"
  wait_for "$E/hook-done" 15 && ok || bad "D3: the detached hook must still finish"
fi

# ============================================================================
# E. The REAL hook, on the hub, when the table GET reads back empty.
# ============================================================================
H="$T/h"; CK="$T/ck"
mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$CK/catalog" "$CK/bin"
stubs "$H" "$H/bin"
git -C "$CK" init -q
git -C "$CK" config user.email t@t; git -C "$CK" config user.name t
catalog "$CK/catalog/model-prices.json" 1
printf '{"claude-opus-5-5":"anthropic/claude-opus-5.5"}\n' > "$CK/catalog/model-slugs.json"
printf '#!/bin/bash\n# FIXTURE MAP holder\n' > "$CK/bin/update-model-prices.sh"
git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm "price opus 5.5"
KEY1=$(git -C "$CK" rev-parse HEAD)
DONE="$H/state/model-prices-deploy-synced"
CALLS="$H/calls.log"; ALERTS="$H/alerts.log"; LOG="$H/logs/update-runners.log"
LIVE="$H/state/model-prices.json"

# reset <table: empty|full> <live: full|absent|empty|garbage>
reset() {
  table "$H/db.json"; cp "$H/db.json" "$LIVE"
  [ "$1" = empty ] && printf '{"per_token":{}}\n' > "$H/db.json"
  case "$2" in
    absent)  rm -f "$LIVE" ;;
    empty)   printf '{"per_token":{}}\n' > "$LIVE" ;;
    garbage) printf 'not json\n' > "$LIVE" ;;
  esac
  rm -f "$H"/state/model-prices-deploy-*
  : > "$CALLS"; : > "$ALERTS"; : > "$LOG"
}
run() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" HUB_BOX_NAME=hubbox BOX_NAME=hubbox
    bash "$H/bin/model-prices-deploy-sync.sh" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
calls() { tr '\n' '|' < "$CALLS"; }

# E1. THE DEFECT: the table read has no models while this hub's state file
#     holds five. Nothing is POSTed, one alert, no stamp, the state file kept.
reset empty full
cp "$LIVE" "$T/live-before.json"
run
[ "$RC" = 0 ] && ok || bad "E1: a refusal must not fail the run, rc=$RC: $(cat "$T/err.txt")"
[ "$(n '^put ' "$CALLS")" = 0 ] && ok \
  || bad "E1: an empty table read must not POST the catalog over live rates, calls: $(calls)"
[ "$(n '--id model-prices-deploy-sync' "$ALERTS")" = 1 ] && grep -q -- '--severity warn' "$ALERTS" \
  && grep -q 'no models' "$ALERTS" && ok \
  || bad "E1: one warn alert under --id model-prices-deploy-sync naming 'no models', got: $(tr '\n' '|' < "$ALERTS")"
[ "$(n 'refused the catalog POST' "$LOG")" = 1 ] && ok || bad "E1: one update-runners.log line, got: $(cat "$LOG")"
[ ! -e "$DONE" ] && ok || bad "E1: a refusal must leave the key unstamped so the next deploy retries"
cmp -s "$LIVE" "$T/live-before.json" && ok || bad "E1: the hub's state/model-prices.json must be untouched"

# E2. A fresh hub: no state file, an empty table. The POST fills it.
reset empty absent
run
grep -qx 'put catalog claude-fable-5-1,claude-haiku-4-5,claude-opus-5,claude-opus-5-5,claude-sonnet-5,gpt-6-astra' "$CALLS" && ok \
  || bad "E2: a fresh hub must POST the whole catalog, calls: $(calls)"
[ "$(n '--severity' "$ALERTS")" = 0 ] && ok || bad "E2: no alert on a fresh hub, got: $(tr '\n' '|' < "$ALERTS")"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "E2: the key must be stamped"

# E3. The normal case: the table has the five, the new model is POSTed alone.
reset full full
run
grep -qx 'put catalog claude-opus-5-5' "$CALLS" && [ "$(n '^put ' "$CALLS")" = 1 ] && ok \
  || bad "E3: only the missing model is POSTed, calls: $(calls)"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "E3: the key must be stamped"

# E4. The state file parses and is empty: nothing to protect, the POST goes on.
reset empty empty
run
[ "$(n '^put catalog ' "$CALLS")" = 1 ] && ok || bad "E4: an empty state file must not block the POST, calls: $(calls)"
[ "$(n '--severity' "$ALERTS")" = 0 ] && ok || bad "E4: no alert, got: $(tr '\n' '|' < "$ALERTS")"

# E5. The state file does not parse: fail closed, refuse.
reset empty garbage
run
[ "$(n '^put ' "$CALLS")" = 0 ] && ok || bad "E5: an unparseable state file must refuse the POST, calls: $(calls)"
[ "$(n '--severity warn --id model-prices-deploy-sync' "$ALERTS")" = 1 ] && ok || bad "E5: one warn alert, got: $(tr '\n' '|' < "$ALERTS")"
[ ! -e "$DONE" ] && ok || bad "E5: no stamp"

echo "model-prices-deploy-sync.bh-1890-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
