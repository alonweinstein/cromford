#!/bin/bash
# tests/model-prices-deploy-sync.bh-1566-test.sh — a newly priced model is in
# the model_prices table after the deploy that brings it, not at 04:30Z (BH-1566).
#
# WHY. #1523 priced Opus 5.5 in catalog/model-prices.json and the refresh MAP,
# and the jobs DB still had no `claude-opus-5-5` row until the next 04:30Z
# refresh. For up to a day every box costed Opus 5.5 calls from a
# state/model-prices.json with no row for it (the reader chain takes the FIRST
# readable table, so the catalog row the box already had never counted), and
# the model_routes PUT refused the model. bin/model-prices-deploy-sync.sh runs
# from bin/harness-sync.sh's deploy path, keyed on the commit that last touched
# the price inputs, so it runs once per change.
#
# Harnessed against a scratch $HARNESS and a scratch git checkout: a FIXTURE
# jobs-client whose model_prices_get/put read and write a JSON "table", a
# recording update-model-prices.sh (the refresh; a no-op unless a case hands it
# prices, i.e. OpenRouter down), a hub-lease.sh stub, a recording lane-alert.sh,
# and the REAL bin/model-prices-sync.sh, bin/lib/hub-box.sh, bin/lib/lane-gate.sh.
#
#   S    the ticket's acceptance, end to end through the real bin/harness-sync.sh
#   A-J  the script itself (see each case)
#
# SCRIPT= points the unit cases at another copy (red-first against main).
# Run from anywhere: tests/model-prices-deploy-sync.bh-1566-test.sh  (0 = pass)
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
# FIXTURE jobs-client (tests/model-prices-deploy-sync.bh-1566-test.sh)
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
# FIXTURE update-model-prices (tests/model-prices-deploy-sync.bh-1566-test.sh)
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

# ── the unit harness ─────────────────────────────────────────────────────────
H="$T/h"; CK="$T/ck"
mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$CK/catalog" "$CK/bin"
stubs "$H" "$H/bin"
git -C "$CK" init -q
git -C "$CK" config user.email t@t; git -C "$CK" config user.name t
catalog "$CK/catalog/model-prices.json" 1
printf '{"claude-opus-5-5":"anthropic/claude-opus-5.5"}\n' > "$CK/catalog/model-slugs.json"
printf '#!/bin/bash\n# FIXTURE MAP holder\n' > "$CK/bin/update-model-prices.sh"
printf 'unrelated\n' > "$CK/README"
git -C "$CK" add -A >/dev/null; git -C "$CK" commit -qm "price opus 5.5"
KEY1=$(git -C "$CK" rev-parse HEAD)

DONE="$H/state/model-prices-deploy-synced"
CALLS="$H/calls.log"; ALERTS="$H/alerts.log"; LOG="$H/logs/update-runners.log"

# reset — the state just after a deploy of $KEY1 landed: the table and the
# box's state file both lack claude-opus-5-5, nothing stamped, no switches.
reset() {
  table "$H/db.json"
  cp "$H/db.json" "$H/state/model-prices.json"
  rm -f "$H"/state/model-prices-deploy-* "$H/get-fail" "$H/put-fail" "$H/lease-lost" \
        "$H/refresh-prices" "$H/flags/lane-off-update-model-prices"
  scratch_rm "$H/state/lane-gate"
  : > "$CALLS"; : > "$ALERTS"; : > "$LOG"
}
run() { # run <box-name>
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" HUB_BOX_NAME=hubbox BOX_NAME="$1"
    bash "$H/bin/model-prices-deploy-sync.sh" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
n()      { local c; c=$(grep -c -e "$1" "$2" 2>/dev/null); echo "${c:-0}"; }
has()    { jq -e --arg m "$2" '(.per_token // .) | has($m)' "$1" >/dev/null 2>&1; }
field()  { jq -r --arg m "$2" --arg k "$3" '(.per_token // .)[$m][$k] // "none"' "$1" 2>/dev/null; }
# rate_is <file> <model> <key> <number> — compared as numbers, never as text
# (jq prints 3.1e-06 as 0.0000031 on some versions).
rate_is() { jq -e --arg m "$2" --arg k "$3" --argjson v "$4" '(.per_token // .)[$m][$k] == $v' "$1" >/dev/null 2>&1; }

# ============================================================================
# A. THE DEFECT, on the hub. The refresh prices nothing (OpenRouter down), so
#    the committed catalog row is the only price there is: it goes into the
#    table as source=catalog, and the hub's own state file picks it up.
# ============================================================================
reset
run hubbox
[ "$RC" = 0 ] && ok || bad "A: rc must be 0, got $RC: $(cat "$T/err.txt")"
[ "$(n '^refresh$' "$CALLS")" = 1 ] && ok || bad "A: the refresh must run once on a new key, calls: $(tr '\n' '|' < "$CALLS")"
[ "$(n '^put ' "$CALLS")" = 1 ] && ok || bad "A: exactly one POST, calls: $(tr '\n' '|' < "$CALLS")"
grep -qx 'put catalog claude-opus-5-5' "$CALLS" && ok \
  || bad "A: the POST must carry ONLY the missing model, as source catalog, calls: $(tr '\n' '|' < "$CALLS")"
has "$H/db.json" claude-opus-5-5 && ok || bad "A: claude-opus-5-5 must be in the table after the deploy"
rate_is "$H/db.json" claude-opus-5-5 prompt 6e-6 && ok \
  || bad "A: the seeded row must carry the catalog rate 6e-06, got $(field "$H/db.json" claude-opus-5-5 prompt)"
has "$H/state/model-prices.json" claude-opus-5-5 && ok || bad "A: the box's state/model-prices.json must be pulled with the new model"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "A: the key must be stamped, got '$(cat "$DONE" 2>/dev/null)'"
[ "$(n '--resolve' "$ALERTS")" -le 1 ] && [ "$(n '--severity' "$ALERTS")" = 0 ] && ok \
  || bad "A: a clean run raises no alert, got: $(tr '\n' '|' < "$ALERTS")"

# ============================================================================
# B. ONCE PER CHANGE. The same key again costs nothing: no refresh, no GET, no
#    POST. This is every deploy that does not touch a price input.
# ============================================================================
: > "$CALLS"
run hubbox
[ "$RC" = 0 ] && [ ! -s "$CALLS" ] && ok \
  || bad "B: a stamped key must make no call at all, rc=$RC calls: $(tr '\n' '|' < "$CALLS")"

# ============================================================================
# C. NEGATIVE. The refresh itself priced the model (OpenRouter up). Nothing is
#    missing, so nothing is POSTed, and the table keeps the refresh's live rate
#    rather than the catalog's.
# ============================================================================
reset
printf '{"claude-opus-5-5":{"prompt":5.5e-6,"completion":2.75e-5,"slug":"anthropic/claude-opus-5.5"}}\n' > "$H/refresh-prices"
run hubbox
[ "$(n '^put ' "$CALLS")" = 0 ] && ok || bad "C: nothing missing after the refresh, so no POST, calls: $(tr '\n' '|' < "$CALLS")"
rate_is "$H/db.json" claude-opus-5-5 prompt 5.5e-6 && ok \
  || bad "C: the refresh's rate must stand, got $(field "$H/db.json" claude-opus-5-5 prompt)"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "C: the key must be stamped"

# ============================================================================
# D. NEGATIVE. A model the table already has is never overwritten by the
#    catalog, even on a run that does POST (sonnet: table 3.1e-6, catalog 3e-6).
# ============================================================================
reset
run hubbox
rate_is "$H/db.json" claude-sonnet-5 prompt 3.1e-6 && ok \
  || bad "D: an existing row must keep its live rate, got $(field "$H/db.json" claude-sonnet-5 prompt)"
[ "$(field "$H/db.json" claude-sonnet-5 source)" = "openrouter" ] && ok \
  || bad "D: an existing row must keep its source, got $(field "$H/db.json" claude-sonnet-5 source)"

# ============================================================================
# E. The table cannot be read. No stamp, one alert under a stable id, and the
#    next deploy does NOT re-run the refresh (it already ran for this key); the
#    next deploy with the worker back seeds, stamps and resolves the alert.
# ============================================================================
reset
: > "$H/get-fail"
run hubbox
[ "$RC" = 0 ] && ok || bad "E: a failed read must not fail the deploy, rc=$RC"
[ ! -e "$DONE" ] && ok || bad "E: a failed read must leave the key unstamped"
[ "$(n '--id model-prices-deploy-sync' "$ALERTS")" = 1 ] && grep -q -- '--severity warn' "$ALERTS" && ok \
  || bad "E: one warn alert under --id model-prices-deploy-sync, got: $(tr '\n' '|' < "$ALERTS")"
rm -f "$H/get-fail"; : > "$CALLS"; : > "$ALERTS"
run hubbox
[ "$(n '^refresh$' "$CALLS")" = 0 ] && ok || bad "E: the refresh must not re-run for a key it already ran for, calls: $(tr '\n' '|' < "$CALLS")"
has "$H/db.json" claude-opus-5-5 && ok || bad "E: the retry must seed the missing model"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "E: the retry must stamp the key"
grep -q -- '--resolve --id model-prices-deploy-sync' "$ALERTS" && ok \
  || bad "E: the good run must resolve the alert, got: $(tr '\n' '|' < "$ALERTS")"

# ============================================================================
# F. The POST fails. No stamp, the alert fires, the model is still missing.
# ============================================================================
reset
: > "$H/put-fail"
run hubbox
[ ! -e "$DONE" ] && ok || bad "F: a failed POST must leave the key unstamped"
[ "$(n '--id model-prices-deploy-sync' "$ALERTS")" = 1 ] && ok \
  || bad "F: a failed POST raises the alert, got: $(tr '\n' '|' < "$ALERTS")"

# ============================================================================
# G. A box that is not the hub never refreshes and never POSTs. It pulls; when
#    the hub has not pushed yet it stays unstamped and says so ONCE per key.
# ============================================================================
reset
run box1
[ "$(n '^refresh$' "$CALLS")" = 0 ] && [ "$(n '^put ' "$CALLS")" = 0 ] && ok \
  || bad "G: a non-hub box must not refresh or POST, calls: $(tr '\n' '|' < "$CALLS")"
[ ! -e "$DONE" ] && ok || bad "G: the table lacks the model, so the box must not stamp"
[ "$(n 'claude-opus-5-5' "$LOG")" = 1 ] && ok || bad "G: one log line naming the missing model, got: $(cat "$LOG")"
run box1
[ "$(n 'claude-opus-5-5' "$LOG")" = 1 ] && ok || bad "G: the second miss for the same key must not log again, got: $(cat "$LOG")"
# the hub pushes
python3 - "$H/db.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["per_token"]["claude-opus-5-5"] = {"prompt": 6e-6, "completion": 3e-5, "source": "catalog"}
json.dump(d, open(sys.argv[1], "w"))
PY
run box1
has "$H/state/model-prices.json" claude-opus-5-5 && ok || bad "G: once the hub has pushed, the box pulls the model"
[ "$(cat "$DONE" 2>/dev/null)" = "$KEY1" ] && ok || bad "G: and stamps the key"

# ============================================================================
# H. The configured hub that does not hold the lease (a standby) is a box.
# ============================================================================
reset
: > "$H/lease-lost"
run hubbox
[ "$(n '^refresh$' "$CALLS")" = 0 ] && [ "$(n '^put ' "$CALLS")" = 0 ] && ok \
  || bad "H: a hub without the lease must not refresh or POST, calls: $(tr '\n' '|' < "$CALLS")"

# ============================================================================
# I. The price lane's own off-switch stops its deploy-time writes too.
# ============================================================================
reset
: > "$H/flags/lane-off-update-model-prices"
run hubbox
[ "$(n '^refresh$' "$CALLS")" = 0 ] && [ "$(n '^put ' "$CALLS")" = 0 ] && ok \
  || bad "I: lane-off-update-model-prices must stop the refresh and the POST, calls: $(tr '\n' '|' < "$CALLS")"

# ============================================================================
# J. A new commit that touches a price input re-arms the key; one that does not
#    leaves it alone.
# ============================================================================
reset
run hubbox
printf 'more\n' >> "$CK/README"; git -C "$CK" commit -qam "docs only"
: > "$CALLS"; run hubbox
[ ! -s "$CALLS" ] && ok || bad "J: a commit that touches no price input must not re-run, calls: $(tr '\n' '|' < "$CALLS")"
printf '{"claude-opus-5-5":"anthropic/claude-opus-5.5","x":"y/x"}\n' > "$CK/catalog/model-slugs.json"
git -C "$CK" commit -qam "slug map"
: > "$CALLS"; run hubbox
[ "$(n '^refresh$' "$CALLS")" = 1 ] && ok || bad "J: a slug-map commit must re-run the refresh, calls: $(tr '\n' '|' < "$CALLS")"
[ "$(cat "$DONE" 2>/dev/null)" = "$(git -C "$CK" rev-parse HEAD)" ] && ok || bad "J: the new key must be stamped"

# ============================================================================
# S. THE TICKET'S ACCEPTANCE, end to end. A real origin and clone, the real
#    bin/harness-sync.sh deploy path, on the hub: a commit that prices a new
#    model in the catalog makes it priced in the table WITHIN THAT ONE DEPLOY.
# ============================================================================
E="$T/e"
mkdir -p "$E/logs" "$E/state" "$E/locks" "$E/flags" "$E/env" "$E/bin" "$E/prompts" "$E/fly" "$E/catalog"
cp "$DIR/bin/alert-line.sh" "$E/bin/"
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$E/ck" 2>/dev/null
git -C "$E/ck" config user.email t@t; git -C "$E/ck" config user.name t
mkdir -p "$E/ck/bin" "$E/ck/prompts" "$E/ck/fly" "$E/ck/catalog"
stubs "$E" "$E/ck/bin"
printf 'p\n' > "$E/ck/prompts/p.md"; printf 'f\n' > "$E/ck/fly/f.txt"; printf 'fleet\n' > "$E/ck/fleet.conf"
catalog "$E/ck/catalog/model-prices.json" 0
git -C "$E/ck" add -A >/dev/null; git -C "$E/ck" commit -qm seed
git -C "$E/ck" branch -M main 2>/dev/null
git -C "$E/ck" push -q origin main
git -C "$E/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1
table "$E/db.json"; cp "$E/db.json" "$E/state/model-prices.json"
: > "$E/calls.log"; : > "$E/alerts.log"
deploy() {
  ( export HARNESS="$E" HARNESS_CHECKOUT="$E/ck" HUB_BOX_NAME=hubbox BOX_NAME=hubbox
    bash "$DIR/bin/harness-sync.sh" ) >"$T/sout.txt" 2>"$T/serr.txt"
  RC=$?
}
# SAFETY PROBE first (the shape tests/harness-sync-catalog-reset.bh-1042 uses):
# a dirty checkout refuses at rc 30 BEFORE any rsync, into $HARNESS/logs. If the
# line is not in the scratch tree, harness-sync is not honouring $HARNESS and
# the deploy below would rsync this fixture over the live /root/harness.
echo probe >> "$E/ck/bin/hub-lease.sh"
deploy
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$E/logs/ALERTS.log" 2>/dev/null; then
  bad "S: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — not running the deploy path"
else
  git -C "$E/ck" checkout -q -- bin/hub-lease.sh
  : > "$E/logs/ALERTS.log"; rm -f "$E/state/harness-sync-last-refused"
  deploy
  [ "$RC" = 0 ] && ok || bad "S: the first deploy must exit 0, got $RC: $(cat "$T/sout.txt") $(cat "$T/serr.txt")"
  # A PR prices claude-opus-5-5 and merges.
  git -C "$T" clone -q -b main "$T/origin" "$T/dev" 2>/dev/null
  git -C "$T/dev" config user.email t@t; git -C "$T/dev" config user.name t
  catalog "$T/dev/catalog/model-prices.json" 1
  git -C "$T/dev" commit -qam "price claude-opus-5-5"; git -C "$T/dev" push -q origin main
  has "$E/db.json" claude-opus-5-5 && bad "S: fixture error, the table must lack the model before the deploy" || ok
  deploy
  [ "$RC" = 0 ] && ok || bad "S: the pricing deploy must exit 0, got $RC: $(cat "$T/sout.txt") $(cat "$T/serr.txt")"
  # BH-1890: harness-sync starts the hook DETACHED, so it may still be running
  # when the deploy returns. Wait (bounded, 20 s) for it to stamp this deploy's
  # key, then check what it did.
  KEYS=$(git -C "$E/ck" rev-parse HEAD); i=0
  while [ "$(cat "$E/state/model-prices-deploy-synced" 2>/dev/null)" != "$KEYS" ] && [ "$i" -lt 100 ]; do
    sleep 0.2; i=$((i+1))
  done
  [ -f "$E/logs/model-prices-deploy-sync.log" ] && ok \
    || bad "S: the detached hook must write to its own logs/model-prices-deploy-sync.log"
  has "$E/db.json" claude-opus-5-5 && ok \
    || bad "S: THE TICKET: after the deploy that brings it, claude-opus-5-5 must be in model_prices (it waited for 04:30Z), calls: $(tr '\n' '|' < "$E/calls.log")"
  [ "$(field "$E/db.json" claude-opus-5-5 source)" = "catalog" ] && ok \
    || bad "S: the deploy-time row is the committed catalog's (source catalog), got $(field "$E/db.json" claude-opus-5-5 source)"
  has "$E/state/model-prices.json" claude-opus-5-5 && ok \
    || bad "S: the hub's own state/model-prices.json must price the model in the same pass"
fi

echo "model-prices-deploy-sync.bh-1566-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
