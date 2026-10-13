#!/bin/bash
# tests/merge-pr-release.bh-4917-test.sh — a "head moved" merge_pr refusal frees
# its command key on EVERY entry point, not just the console's Pages proxy.
#
# THE DEFECT (BH-4917, project-3 #467, 2026-10-06). The console worker keys a
# merge_pr on <project>:<ticket>:merge_pr and hands an existing row under that
# key back to every later request. bin/poll-commands.sh acks a head-moved
# refusal as a terminal `refused` row (BH-932), and #4439's rename only ran in
# the Pages proxy for a request carrying verdict_sha. A merge_pr from the MCP
# tool, Telegram or a box command got the old refusal back forever.
#
# THE FIX. After the ack, the poller (the one path every merge_pr goes through)
# calls mpr_release_head_moved (bin/lib/merge-pr-release.sh), which POSTs the
# id to the console's Pages endpoint /api/merge-pr/release
# (console-ui/functions/api/merge-pr/release.js). That renames the row to
# <key>:refused:<id> with one guarded UPDATE through the console's own
# CONSOLE_DB binding, so the hub needs no D1 access (BH-3905).
#
# WHAT THIS PINS (curl is stubbed on PATH; in `sqlite` mode the stub runs the
# REAL Pages onRequest against a SQLite table through node:sqlite, and those
# cases print SKIPPED without it):
#   A  lib, no HARNESS_SECRET: rc 3, no call, `not-configured`, no ALERT
#   B  the real endpoint renames a terminal head-moved row off its key
#   C  it leaves leased rows, other refusals, other types, already renamed
#      rows and other ids alone; a wrong secret is a 401 and changes nothing
#   D  unreachable / HTTP 401 / 404 / 503 / a garbage body: rc 4, one ALERT
#      naming the command and the cause, logged `failed`, never `released`
#   E  request shape: one POST to the Pages release url, body {id} as a
#      number, the secret on stdin and never in argv or a log, no D1 REST call
#   F  success with released 0: rc 1, `no-match`, no ALERT
#   G  the REAL poller blocks (lib source line, merge_pr handler, ack, release)
#      for an MCP-shaped payload (no sha, no verdict_sha): ack outcome refused,
#      then exactly one release call for that id
#   H  two commands under one key, end to end against a SQLite console: the
#      second merge_pr mints a NEW id under the SAME key, is bound to the
#      ledger's sha A again and refused again while head B has no verdict
#   I  rc 3/5/12/15 refusals and an rc 1 failure make no release call
#   J  a merge, a non-whitelisted url, and a non-merge_pr type make no call
#
# POLL_COMMANDS overrides the script the blocks come from (the repro runs this
# suite against origin/main's copy). Missing markers fail loudly.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${POLL_COMMANDS:-$DIR/bin/poll-commands.sh}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIPPED (no node:sqlite): $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

HAVE_SQLITE=0
node --no-warnings -e 'require("node:sqlite")' >/dev/null 2>&1 && HAVE_SQLITE=1

SLUG="example-org/project-3"
PR="https://github.com/example-org/project-3/pull/467"
SHA_A="7b8409701111aaaa2222bbbb3333cccc4444dddd"
TOKEN="hs-fixture-bh4917"
KEY="project-3:TK-467:merge_pr"

# ── the scratch harness: the lib's closure, the real alert-line.sh ──────────
mkdir -p "$T/h/logs" "$T/h/env" "$T/bin"
scratch_install_closure bin/lib/merge-pr-release.sh "$T/h" >/dev/null || { echo "FAIL: cannot install the lib closure"; exit 1; }
scratch_install_closure bin/alert-line.sh "$T/h" >/dev/null || { echo "FAIL: cannot install alert-line.sh"; exit 1; }
scratch_install_closure bin/lib/console-pages.sh "$T/h" >/dev/null || { echo "FAIL: cannot install console-pages.sh"; exit 1; }
unset CONSOLE_PAGES_URL HARNESS_SECRET
PAGES_URL="https://console.example.pages.dev/api/merge-pr/release"
cat > "$T/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo project-3; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$T/h/bin/fleet-conf.sh"
HS=""
cfg_on()  { HS="$TOKEN"; }
cfg_off() { HS=""; }

# ── the D1 stand-in: a SQLite console through node:sqlite ───────────────────
cat > "$T/d1.js" <<'JS'
const { DatabaseSync } = require('node:sqlite');
const [, , op, db, ...a] = process.argv;
if (!db || !db.startsWith('/')) { console.error('d1.js: the db path must be absolute'); process.exit(2); }
const d = new DatabaseSync(db);
d.exec(`CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY, ckey TEXT UNIQUE,
  type TEXT, project TEXT, payload TEXT, status TEXT, result TEXT)`);
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
if (op === 'seed') {      // seed <id> <ckey> <type> <status> <result>
  d.prepare('INSERT INTO commands (id, ckey, type, project, payload, status, result) VALUES (?,?,?,?,?,?,?)')
    .run(Number(a[0]), a[1], a[2], 'project-3', '{}', a[3], a[4]);
} else if (op === 'mint') {      // the worker's idempotent mint: hand back the row under the key, else a new one
  const row = d.prepare('SELECT id FROM commands WHERE ckey = ?').get(a[0]);
  if (row) out(Number(row.id));
  else out(Number(d.prepare("INSERT INTO commands (ckey, type, project, payload, status, result) VALUES (?, 'merge_pr', 'project-3', ?, 'pending', '')")
    .run(a[0], a[1]).lastInsertRowid));
} else if (op === 'ack') {       // ack <id> <body-json>: outcome refused is terminal (BH-932)
  const b = JSON.parse(a[1]);
  const st = b.outcome === 'refused' ? 'refused' : (b.ok ? 'done' : 'pending');
  d.prepare('UPDATE commands SET status = ?, result = ? WHERE id = ?').run(st, b.result, Number(a[0]));
} else if (op === 'get') {       // get <id> -> the row
  out(d.prepare('SELECT * FROM commands WHERE id = ?').get(Number(a[0])) || null);
} else if (op === 'bykey') {     // bykey <ckey> -> the row or null
  out(d.prepare('SELECT * FROM commands WHERE ckey = ?').get(a[0]) || null);
}
JS
D1() { node --no-warnings "$T/d1.js" "$1" "$T/console.db" "${@:2}"; }

# The REAL Pages endpoint against that SQLite console, CONSOLE_DB in D1's
# prepare/bind/run shape: pages.mjs <db> <body-file> <stdin-file> <out-file>
# reads the Authorization header the lib sent on curl's stdin and prints the
# HTTP status. The Pages project's own HARNESS_SECRET is $TOKEN.
cat > "$T/pages.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { onRequest } = await import(pathToFileURL('$DIR/console-ui/functions/api/merge-pr/release.js').href);
const [, , db, bodyFile, stdinFile, outFile] = process.argv;
const s = new DatabaseSync(db);
const CONSOLE_DB = { prepare: (sql) => { const st = s.prepare(sql);
  return { bind: (...a) => ({ run: async () => ({ success: true, meta: { changes: Number(st.run(...a).changes) } }) }) }; } };
const auth = (readFileSync(stdinFile, 'utf8').match(/^Authorization: (.*)\$/m) || [])[1] || '';
const res = await onRequest({ request: new Request('https://pages.example/api/merge-pr/release',
  { method: 'POST', headers: { authorization: auth, 'content-type': 'application/json' }, body: readFileSync(bodyFile, 'utf8') }),
  env: { HARNESS_SECRET: '$TOKEN', CONSOLE_DB } });
writeFileSync(outFile, await res.text());
process.stdout.write(String(res.status));
JS

# curl stub: records argv / stdin / body per call, answers per CURL_MODE.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
n=$(( $(grep -c . "$T/curl-argv.log" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$*" >> "$T/curl-argv.log"
cat > "$T/curl-stdin.$n"; cat "$T/curl-stdin.$n" >> "$T/curl-stdin.log"
o=""; body=""; prev=""
for x in "$@"; do
  [ "$prev" = -o ] && o="$x"
  [ "$prev" = --data-binary ] && body="${x#@}"
  prev="$x"
done
[ -n "$body" ] && cp "$body" "$T/curl-body.$n.json"
case "${CURL_MODE:-ok1}" in
  ok1)     printf '{"released":1}' > "$o"; printf 200 ;;
  zero)    printf '{"released":0}' > "$o"; printf 200 ;;
  http401) printf '{"error":"unauthorized"}' > "$o"; printf 401 ;;
  http404) printf 'Not Found' > "$o"; printf 404 ;;
  http503) printf '{"error":"CONSOLE_DB is not bound on this Pages project"}' > "$o"; printf 503 ;;
  garbage) printf '<html>bad gateway</html>' > "$o"; printf 200 ;;
  down)    printf 000; exit 28 ;;
  sqlite)  node --no-warnings "$T/pages.mjs" "$T/console.db" "$body" "$T/curl-stdin.$n" "$o" ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"
reset_calls() { rm -f "$T"/curl-*.log "$T"/curl-body.*.json "$T"/curl-stdin.* "$T/h/logs/ALERTS.log" "$T/h/logs/console-commands.log"; }

lib() { # lib <id> <mode> -> prints rc
  CURL_MODE="$2" T="$T" HARNESS="$T/h" HARNESS_SECRET="$HS" bash -c '
    set -uo pipefail
    . "$HARNESS/bin/lib/merge-pr-release.sh" || exit 99
    mpr_release_head_moved "$1" "$HARNESS/logs/console-commands.log"; echo $?' _ "$1"
}
clog() { cat "$T/h/logs/console-commands.log" 2>/dev/null; }
alerts() { nlines "$T/h/logs/ALERTS.log"; }

# ── A. not configured: no call, no ALERT ───────────────────────────────────
reset_calls; cfg_off
RC=$(lib 7 ok1)
[ "$RC" = 3 ] && ok || bad "A: no HARNESS_SECRET must be rc 3, got '$RC'"
[ ! -s "$T/curl-argv.log" ] && ok || bad "A: no HARNESS_SECRET must make no call, got: $(cat "$T/curl-argv.log")"
grep -q 'merge_pr 7 key release: not-configured' <<<"$(clog)" && ok || bad "A: must log not-configured, got '$(clog)'"
[ "$(alerts)" = 0 ] && ok || bad "A: not-configured must not ALERT"
reset_calls; cfg_on
RC=$(lib "7; drop" ok1)
{ [ "$RC" = 2 ] && [ ! -s "$T/curl-argv.log" ]; } && ok || bad "A: a non-numeric id must be rc 2 with no call, got '$RC'"

# ── E + G-lib. the request shape, and rc 0 on changes 1 ─────────────────────
reset_calls; cfg_on
RC=$(lib 7 ok1)
[ "$RC" = 0 ] && ok || bad "E: released 1 must be rc 0 (released), got '$RC'"
grep -q 'merge_pr 7 key release: released$' <<<"$(clog)" && ok || bad "E: must log released, got '$(clog)'"
[ "$(nlines "$T/curl-argv.log")" = 1 ] && ok || bad "E: exactly one call, got $(nlines "$T/curl-argv.log")"
ARGV=$(cat "$T/curl-argv.log")
grep -qF -- "-X POST" <<<"$ARGV" && grep -qF " $PAGES_URL" <<<"$ARGV" \
  && ok || bad "E: must POST the console Pages release url, got '$ARGV'"
grep -qF "api.cloudflare.com" <<<"$ARGV" && bad "E: the hub must never call the Cloudflare D1 REST API (BH-3905)" || ok
grep -qF -- "--max-time 15" <<<"$ARGV" && ok || bad "E: the call must be bounded at 15 s, got '$ARGV'"
jq -e '. == {id: 7} and (.id | type == "number")' "$T/curl-body.1.json" >/dev/null 2>&1 \
  && ok || bad "E: the body must be {id: 7} as a number, got '$(cat "$T/curl-body.1.json" 2>/dev/null)'"
grep -qF "$TOKEN" "$T/curl-argv.log" && bad "E: the secret must never be in curl's argv" || ok
grep -qF "Authorization: Bearer $TOKEN" "$T/curl-stdin.log" && ok || bad "E: the secret must reach curl on stdin"
grep -rqF "$TOKEN" "$T/h/logs" && bad "E: the secret must never reach a log" || ok
reset_calls
RC=$(CONSOLE_PAGES_URL=https://pages.example/ lib 7 ok1)
grep -qF " https://pages.example/api/merge-pr/release" "$T/curl-argv.log" && ok || bad "E: CONSOLE_PAGES_URL must override the console url, got '$(cat "$T/curl-argv.log")'"

# ── F. changes 0: no-match, not an error ───────────────────────────────────
reset_calls
RC=$(lib 7 zero)
[ "$RC" = 1 ] && ok || bad "F: released 0 must be rc 1, got '$RC'"
grep -q 'merge_pr 7 key release: no-match$' <<<"$(clog)" && ok || bad "F: must log no-match, got '$(clog)'"
[ "$(alerts)" = 0 ] && ok || bad "F: no-match must not ALERT"

# ── D. failures are failures ───────────────────────────────────────────────
for c in "down:unreachable" "http401:refused the hub's HARNESS_SECRET" "http404:not deployed with BH-4917" \
         "http503:CONSOLE_DB is not bound" "garbage:the answer carried no count"; do
  m=${c%%:*}; cause=${c#*:}
  reset_calls
  RC=$(lib 7 "$m")
  [ "$RC" = 4 ] && ok || bad "D($m): must be rc 4, got '$RC'"
  [ "$(alerts)" = 1 ] && ok || bad "D($m): exactly one ALERTS line, got $(alerts)"
  grep -q 'merge_pr 7 keeps its key' "$T/h/logs/ALERTS.log" 2>/dev/null && grep -qF "$cause" "$T/h/logs/ALERTS.log" \
    && ok || bad "D($m): the ALERT must name the command and '$cause', got '$(cat "$T/h/logs/ALERTS.log" 2>/dev/null)'"
  grep -q 'key release: failed (HTTP' <<<"$(clog)" && ok || bad "D($m): must log failed, got '$(clog)'"
  grep -q 'released' <<<"$(clog)" && bad "D($m): a failure must never log released" || ok
  grep -q 'D1 write\|CLOUDFLARE_API_TOKEN' "$T/h/logs/ALERTS.log" && bad "D($m): the remedy is never a hub D1 token (BH-3905)" || ok
done

# ── B + C. the SQL's semantics on a real SQLite table ──────────────────────
if [ "$HAVE_SQLITE" = 1 ]; then
  rm -f "$T/console.db"
  HM="refused: head moved since sha 7b840970 — Head branch was modified."
  D1 seed 7 "$KEY" merge_pr refused "$HM"
  D1 seed 3 "project-3:TK-1:merge_pr:refused:3" merge_pr refused "$HM"
  D1 seed 4 "project-3:TK-2:merge_pr" merge_pr leased "$HM"
  D1 seed 5 "project-3:TK-3:merge_pr" merge_pr refused "refused: GitHub would not merge — 405"
  D1 seed 6 "project-3:TK-4:chat" chat refused "$HM"
  reset_calls
  RC=$(HS="wrong-secret" lib 7 sqlite)
  { [ "$RC" = 4 ] && [ "$(D1 get 7 | jq -r .ckey)" = "$KEY" ]; } && ok || bad "C: a wrong secret must be refused (rc 4) and change nothing, got '$RC' '$(D1 get 7)'"
  reset_calls
  RC=$(lib 7 sqlite)
  [ "$RC" = 0 ] && ok || bad "B: the head-moved row must be released (rc 0), got '$RC'"
  [ "$(D1 get 7 | jq -r .ckey)" = "$KEY:refused:7" ] && ok || bad "B: row 7 must be renamed to $KEY:refused:7, got '$(D1 get 7)'"
  [ "$(D1 bykey "$KEY")" = null ] && ok || bad "B: nothing may sit under $KEY after the release, got '$(D1 bykey "$KEY")'"
  [ "$(D1 get 7 | jq -r '.status + "|" + .result')" = "refused|$HM" ] && ok || bad "B: the row is renamed, never rewritten or deleted"
  RC=$(lib 7 sqlite)
  { [ "$RC" = 1 ] && [ "$(D1 get 7 | jq -r .ckey)" = "$KEY:refused:7" ]; } && ok || bad "B: a replay must change nothing (rc 1), got '$RC' '$(D1 get 7)'"
  for c in 3:project-3:TK-1:merge_pr:refused:3 4:project-3:TK-2:merge_pr 5:project-3:TK-3:merge_pr 6:project-3:TK-4:chat; do
    cid=${c%%:*}; want=${c#*:}
    RC=$(lib "$cid" sqlite)
    { [ "$RC" = 1 ] && [ "$(D1 get "$cid" | jq -r .ckey)" = "$want" ]; } \
      && ok || bad "C: row $cid must keep '$want' (rc 1), got '$RC' '$(D1 get "$cid")'"
  done
  RC=$(lib 8 sqlite)
  { [ "$RC" = 1 ] && [ "$(D1 get 7 | jq -r .ckey)" = "$KEY:refused:7" ]; } && ok || bad "C: id 8 must match nothing, got '$RC'"
else
  skip "B"; skip "C"
fi

# ── G-J. the REAL poller blocks ─────────────────────────────────────────────
extract() { awk -v a="^    # >>> $1" -v b="^    # <<< $1" '$0 ~ a {f=1; next} $0 ~ b {exit} f {print}' "$SRC"; }
extract "merge_pr handler" | sed -e '1s/^    merge_pr)//' -e '$s/ ;;$//' > "$T/merge_pr.body"
extract "command ack" > "$T/ack.body"
extract "merge_pr key release" > "$T/release.body"
grep -m1 -F 'bin/lib/merge-pr-release.sh" ] && .' "$SRC" > "$T/source.line"
WIRED=1
[ -s "$T/merge_pr.body" ] || { bad "G: no merge_pr handler block in $SRC"; WIRED=0; }
[ -s "$T/ack.body" ] || { bad "G: no command ack block in $SRC"; WIRED=0; }
[ -s "$T/release.body" ] || { bad "G: no '# >>> merge_pr key release' block after the ack in $SRC — a head-moved refusal keeps its key"; WIRED=0; }
[ -s "$T/source.line" ] || { bad "G: $SRC never sources bin/lib/merge-pr-release.sh"; WIRED=0; }
if [ "$WIRED" = 1 ]; then
  RL=$(grep -n '^    # >>> merge_pr key release' "$SRC" | cut -d: -f1); AL=$(grep -n '^    # <<< command ack' "$SRC" | cut -d: -f1)
  [ "$((AL + 1))" = "$RL" ] && ok || bad "G: the release block must sit right after the ack (ack line $AL, release line $RL)"
fi

poll() { # poll <ID> <payload> <provider> <rest-rc> [type] -> OK/RESULT/OUTCOME lines
  : > "$T/rest-calls.log"
  ID="$1" PAYLOAD="$2" PROV="$3" STUB_RC="$4" TYPE="${5:-merge_pr}" T="$T" HARNESS="$T/h" HARNESS_SECRET="$HS" \
  CONSOLE_URL="https://console.example" PROJECT=project-3 bash -c '
    set -uo pipefail
    OK=false; RESULT=""; OUTCOME=""
    mc_queue_provider() { printf %s "$PROV"; }
    mc_pr_queued() { return 1; }
    mc_pr_view() { printf %s "$LIVE_HEAD"; }
    mc_enqueue_mergify() { printf "queue said nothing"; return "$STUB_RC"; }
    job_verdict() { printf "a\tb\tc\td\te\t%s\n" "$SHA_A"; }
    gh_pr_merge_rest() { printf "%s\n" "$*" >> "$T/rest-calls.log"; printf "Head branch was modified."; return "$STUB_RC"; }
    API() {
      local body="" prev="" url=""
      for x in "$@"; do [ "$prev" = -d ] && body="$x"; prev="$x"; url="$x"; done
      printf "%s\t%s\n" "$url" "$body" >> "$T/api.log"
      [ -s "$T/console.db" ] && [ "${APPLY_ACK:-0}" = 1 ] && node --no-warnings "$T/d1.js" ack "$T/console.db" "$ID" "$body"
      return 0
    }
    eval "$(cat "$T/source.line")"
    if [ "$TYPE" = merge_pr ]; then . "$T/merge_pr.body"; else OUTCOME=refused; RESULT="refused: head moved since sha 7b840970 — not a merge"; fi
    . "$T/ack.body"
    . "$T/release.body"
    printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"'
}
export SHA_A LIVE_HEAD="9999eeee8888ffff" APPLY_ACK=0
resof() { sed -n 's/^RESULT=//p' <<<"$1"; }

if [ "$WIRED" = 1 ]; then
  # ── G. MCP/Telegram/box shape: {pr_url} only ──────────────────────────────
  reset_calls; rm -f "$T/api.log"; cfg_on
  OUT=$(poll 101 "{\"pr_url\":\"$PR\"}" none 4)
  grep -q "^refused: head moved since sha ${SHA_A:0:8}" <<<"$(resof "$OUT")" \
    && ok || bad "G: the handler must refuse bound to the ledger sha ${SHA_A:0:8}, got '$(resof "$OUT")'"
  grep -qF " $SHA_A " "$T/rest-calls.log" && ok || bad "G: the REST merge must be bound to the ledger sha, got '$(cat "$T/rest-calls.log")'"
  [ "$(cut -f1 "$T/api.log")" = "https://console.example/api/commands/101/ack" ] && jq -e '.outcome == "refused" and .ok == false' <<<"$(cut -f2 "$T/api.log")" >/dev/null \
    && ok || bad "G: the ack must POST outcome refused for 101, got '$(cat "$T/api.log")'"
  [ "$(nlines "$T/curl-argv.log")" = 1 ] && ok || bad "G: exactly one release call after a head-moved ack, got $(nlines "$T/curl-argv.log")"
  jq -e '.id == 101' "$T/curl-body.1.json" >/dev/null 2>&1 && ok || bad "G: the release must be for command 101, got '$(cat "$T/curl-body.1.json" 2>/dev/null)'"
  grep -q 'merge_pr 101 key release: released' <<<"$(clog)" && ok || bad "G: console-commands.log must record the release, got '$(clog)'"
  # the Mergify lane's own head-moved refusal (rc 4 there) is the same stickiness
  reset_calls
  OUT=$(poll 104 "{\"pr_url\":\"$PR\"}" mergify 0)
  { grep -q '^refused: head moved' <<<"$(resof "$OUT")" && [ "$(nlines "$T/curl-argv.log")" = 1 ]; } \
    && ok || bad "G: a Mergify-lane head-moved refusal must release too, got '$(resof "$OUT")' calls $(nlines "$T/curl-argv.log")"
  # a release failure never stops the poller: the block still finishes
  reset_calls
  OUT=$(CURL_MODE=http401 poll 105 "{\"pr_url\":\"$PR\"}" none 4)
  grep -q '^OUTCOME=refused' <<<"$OUT" && ok || bad "G: a failed release must not abort the poller, got '$OUT'"

  # ── H. two commands, one key, against a SQLite console ────────────────────
  if [ "$HAVE_SQLITE" = 1 ]; then
    rm -f "$T/console.db"; reset_calls; rm -f "$T/api.log"
    MCP="{\"pr_url\":\"$PR\"}"
    ID1=$(D1 mint "$KEY" "$MCP")
    OUT1=$(APPLY_ACK=1 CURL_MODE=sqlite poll "$ID1" "$MCP" none 4)
    ID2=$(D1 mint "$KEY" "$MCP")
    [ "$ID2" != "$ID1" ] && ok || bad "H: after a head-moved refusal the next merge_pr under $KEY must mint a new command, got the old id $ID1 back"
    [ "$(D1 get "$ID1" | jq -r '.ckey + "|" + .status')" = "$KEY:refused:$ID1|refused" ] \
      && ok || bad "H: the first command must be kept, renamed and refused, got '$(D1 get "$ID1")'"
    OUT2=$(APPLY_ACK=1 CURL_MODE=sqlite poll "$ID2" "$MCP" none 4)
    grep -q "^refused: head moved since sha ${SHA_A:0:8}" <<<"$(resof "$OUT2")" \
      && ok || bad "H: head B with no verdict must be refused again, bound to ${SHA_A:0:8}, got '$(resof "$OUT2")'"
    [ "$(nlines "$T/rest-calls.log")" = 1 ] && grep -qF " $SHA_A " "$T/rest-calls.log" \
      && ok || bad "H: the second command must be evaluated fresh against the ledger sha, got '$(cat "$T/rest-calls.log")'"
    [ "$(D1 get "$ID2" | jq -r .ckey)" = "$KEY:refused:$ID2" ] && ok || bad "H: the second refusal must free the key too, got '$(D1 get "$ID2")'"
    [ "$(nlines "$T/curl-argv.log")" = 2 ] && ok || bad "H: one release per refusal, got $(nlines "$T/curl-argv.log")"
    : "$OUT1"
  else
    skip "H"
  fi

  # ── I. other refusals and failures keep their key ─────────────────────────
  for c in "none 3" "none 5" "none 1" "mergify 3" "mergify 4"; do
    set -- $c
    reset_calls
    if [ "$1" = mergify ]; then LIVE_HEAD="$SHA_A"; fi
    OUT=$(LIVE_HEAD="$LIVE_HEAD" poll 106 "{\"pr_url\":\"$PR\"}" "$1" "$2")
    LIVE_HEAD="9999eeee8888ffff"
    grep -q '^refused: head moved' <<<"$(resof "$OUT")" && bad "I($c): fixture must not be a head-moved refusal, got '$(resof "$OUT")'"
    [ ! -s "$T/curl-argv.log" ] && ok || bad "I($c): '$(resof "$OUT")' must make no release call"
  done

  # ── J. a merge, a non-whitelisted url, a non-merge_pr type ─────────────────
  reset_calls
  OUT=$(poll 107 "{\"pr_url\":\"$PR\"}" none 0)
  { grep -q '^merged ' <<<"$(resof "$OUT")" && [ ! -s "$T/curl-argv.log" ]; } && ok || bad "J: a merge must make no release call, got '$(resof "$OUT")'"
  reset_calls
  OUT=$(poll 108 '{"pr_url":"https://github.com/evil/repo/pull/1"}' none 4)
  { grep -q '^refused: not a whitelisted' <<<"$(resof "$OUT")" && [ ! -s "$T/curl-argv.log" ]; } && ok || bad "J: a non-whitelisted url must make no release call, got '$(resof "$OUT")'"
  reset_calls
  OUT=$(poll 109 '{}' none 4 chat)
  [ ! -s "$T/curl-argv.log" ] && ok || bad "J: a non-merge_pr type must make no release call even with a head-moved RESULT"
fi

echo "merge-pr-release.bh-4917: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
