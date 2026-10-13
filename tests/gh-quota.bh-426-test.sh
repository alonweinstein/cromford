#!/bin/bash
# tests/gh-quota.bh-426-test.sh — the GitHub quota gauge (BH-426): what
# `--status` reports, what the hub pushes, when it pages, what it counts, and
# how many calls the merge path actually makes.
#
# THE WALL THIS MEASURES. bin/lib/gh-budget.sh pages when a bucket hits ZERO,
# which is after the lane has already failed; nothing said how much was left
# before that, and `fleet_status` carried no GitHub number at all. So:
#   A  bin/gh-token.sh --status [--json] — REST and GraphQL remaining/limit and
#      reset time for EVERY token this box holds, App rows plus both PATs,
#      deduped by value. `?/?` is a failure and 0/0 is not headroom.
#   B  bin/fleet-status-push.sh pushes `gh_quota` beside `quota` — PRESENT with
#      one row per token when the helper answered, ABSENT (never null, never
#      []) when it did not, and shed under the 64000-byte backstop.
#   C  the 20-percent alert: one ALERTS line per token per reset window, naming
#      the identity, both buckets and the top three callers. 20% exactly is not
#      low, 0/0 is unknown not zero, an unreadable token is logged not paged.
#   D  the counter in bin/lib/gh-limit-logger.sh — one line per wrapped call,
#      with stdout, stderr and rc byte-identical to the unwrapped call.
#   E  the two merge-path lanes that never sourced the logger.
#   F  the merge path over that counter: a tick over N open PRs issues at most
#      one GraphQL listing per harness author and N REST reads, and never a
#      `gh pr view` per PR (delivered by main's REST conversions; pinned here).
#
# EVERY section drives the REAL script or the REAL lib and asserts on ARTIFACTS
# — PUSH.json, BEATS.jsonl, logs/ALERTS.log, logs/gh-quota.log, logs/gh-rate.log
# and logs/gh-calls/*.log. Three sections carry a MUTANT of the shipped code and
# assert that the mutant is caught (D1), so none of them can pass by accident.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/gh-quota.bh-426-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN GH_LIMIT_IDENTITY GH_CALL_CALLER HARNESS H

# ONE clock anchor for the whole file. Every reset epoch, hour bucket and file
# age below is derived from it, so this suite cannot pick its own red minute.
NOW=$(date -u +%s)
iso_at() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }
RESET_R=$(( NOW + 1800 ))
RESET_G=$(( NOW + 2400 ))
ISO_R=$(iso_at "$RESET_R")
ISO_G=$(iso_at "$RESET_G")
HOURF=$(date -u -d "@$NOW" +%Y%m%d%H)

# ═════════════════════════════════════════════════════════════════════════════
# A. bin/gh-token.sh --status [--json], the real CLI
# ═════════════════════════════════════════════════════════════════════════════
A="$T/a"
mkdir -p "$A/bin" "$A/state/gh-app-tokens" "$A/env" "$A/logs" "$A/bodies" "$T/fakebin"
cp "$DIR/bin/gh-token.sh" "$A/bin/"; chmod +x "$A/bin/gh-token.sh"
mkdir -p "$A/bin/lib"; cp "$DIR/bin/lib/env-path.sh" "$A/bin/lib/"

# The stubbed GitHub: ONE body per token value, keyed off the Authorization
# header, so one run can hold a healthy token, a deprecated-shape one, a refused
# one and one that answers nothing at all. A token with no body file answers an
# EMPTY body, which is the other half of "unreadable".
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
AUTH=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -H) case "\$2" in Authorization:*) AUTH="\${2#Authorization: }" ;; esac; shift 2 ;;
    -m|-X|-d) shift 2 ;;
    *) shift ;;
  esac
done
B="\${GHQ_BODIES:-$A/bodies}/\${AUTH#token }.json"
[ -f "\$B" ] && cat "\$B"
exit 0
SH
chmod +x "$T/fakebin/curl"
# No keyring identity anywhere in this suite: a box with no GH_TOKEN must report
# no pat:default row rather than borrowing one from `gh auth token`.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

body() { printf '%s' "$2" > "$A/bodies/$1.json"; }
body ghs_alpha "$(jq -nc --argjson r "$RESET_R" --argjson g "$RESET_G" \
  '{resources:{core:{remaining:4996,limit:5000,reset:$r},graphql:{remaining:4400,limit:5000,reset:$g}}}')"
body ghs_beta  "$(jq -nc --argjson r "$RESET_R" '{rate:{remaining:4000,limit:5000,reset:$r}}')"
body ghs_gamma "$(jq -nc --argjson r "$RESET_R" --argjson g "$RESET_G" \
  '{resources:{core:{remaining:10,limit:5000,reset:$r},graphql:{remaining:0,limit:5000,reset:$g}}}')"
body pattok    "$(jq -nc --argjson r "$RESET_R" --argjson g "$RESET_G" \
  '{resources:{core:{remaining:4000,limit:5000,reset:$r},graphql:{remaining:4000,limit:5000,reset:$g}}}')"
body admintok  "$(jq -nc --argjson r "$RESET_R" --argjson g "$RESET_G" \
  '{resources:{core:{remaining:3000,limit:5000,reset:$r},graphql:{remaining:3000,limit:5000,reset:$g}}}')"
body ghs_dead  '{"message":"Bad credentials"}'

cache() { # cache <slug> <token> [expires_at]
  jq -nc --arg s "$1" --arg t "$2" --arg e "${3:-2099-01-01T00:00:00Z}" \
    '{repo:$s,token:$t,expires_at:$e,minted_at:"2026-09-22T00:00:00Z"}' \
    > "$A/state/gh-app-tokens/$(printf '%s' "$1" | tr / -).json"
}
cache Org/alpha ghs_alpha
cache Org/beta  ghs_beta
cache Org/gamma ghs_gamma
printf 'GH_ADMIN_TOKEN=admintok\n' > "$A/env/github-admin.env"

status() { # status [--json] ; stdout on fd 1, stderr to $A/err.txt
  env PATH="$T/fakebin:$PATH" HARNESS="$A" HARNESS_ENV_DIR="$A/env" \
      GH_APP_API_BASE="http://api.test" GH_TOKEN=pattok \
      "$A/bin/gh-token.sh" --status "$@" 2>"$A/err.txt"
}

# A1 — five distinct tokens, five rows, in both forms.
S=$(status); E=$(cat "$A/err.txt")
[ "$(grep -c . <<<"$S")" = 5 ] && ok || bad "A1: --status must print one line per token (5), got: '$S'"
J=$(status --json); EJ=$(cat "$A/err.txt")
[ "$(jq -r 'length' <<<"$J" 2>/dev/null)" = 5 ] && ok || bad "A1: --status --json must print 5 objects, got: '$J'"
[ "$(jq -r '[.[].identity] | sort | join(",")' <<<"$J" 2>/dev/null)" = "Org/alpha,Org/beta,Org/gamma,pat:admin,pat:default" ] \
  && ok || bad "A1: the five identities must be the three App rows and both PATs, got: '$(jq -c '[.[].identity]' <<<"$J")'"

# A2 — a .resources.core + .graphql body: every number and both reset times.
R=$(jq -c '.[] | select(.identity == "Org/alpha")' <<<"$J")
[ "$(jq -r '.rest_remaining' <<<"$R")" = 4996 ] && ok || bad "A2: rest_remaining must be 4996, got '$R'"
[ "$(jq -r '.rest_limit' <<<"$R")" = 5000 ] && ok || bad "A2: rest_limit must be 5000, got '$R'"
[ "$(jq -r '.graphql_remaining' <<<"$R")" = 4400 ] && ok || bad "A2: graphql_remaining must be 4400, got '$R'"
[ "$(jq -r '.graphql_limit' <<<"$R")" = 5000 ] && ok || bad "A2: graphql_limit must be 5000, got '$R'"
[ "$(jq -r '.resets_at.rest' <<<"$R")" = "$ISO_R" ] && ok || bad "A2: resets_at.rest must be $ISO_R, got '$R'"
[ "$(jq -r '.resets_at.graphql' <<<"$R")" = "$ISO_G" ] && ok || bad "A2: resets_at.graphql must be $ISO_G, got '$R'"
[ "$(jq -r '.kind' <<<"$R")" = app ] && ok || bad "A2: an App cache file is kind app, got '$R'"
[ "$(jq -r '.expires_at' <<<"$R")" = "2099-01-01T00:00:00Z" ] && ok || bad "A2: the App row keeps its expiry, got '$R'"
grep -q '^Org/alpha remaining=4996/5000 expires_at=2099-01-01T00:00:00Z graphql=4400/5000 ' <<<"$S" \
  && ok || bad "A2: the text line must carry both buckets, got: '$S'"
grep -q "rest_resets_at=$ISO_R graphql_resets_at=$ISO_G" <<<"$S" \
  && ok || bad "A2: the text line must carry both reset times, got: '$S'"

# A3 — a .rate-only body (GitHub's deprecated shape): the REST pair is real, the
# GraphQL bucket is UNKNOWN and says so, and nothing is printed on stderr for it.
R=$(jq -c '.[] | select(.identity == "Org/beta")' <<<"$J")
[ "$(jq -r '[.rest_remaining,.rest_limit,.graphql_remaining,.graphql_limit,.unreadable,.graphql_unreadable] | join(",")' <<<"$R")" \
  = "4000,5000,0,0,false,true" ] && ok \
  || bad "A3: a .rate-only body fills REST and flags graphql_unreadable, got '$R'"
[ "$(jq -r '.resets_at.graphql' <<<"$R")" = null ] && ok || bad "A3: an unknown graphql reset must be null, got '$R'"
grep -q 'Org/beta' <<<"$EJ" && bad "A3: a readable REST bucket must write no stderr note, got: '$EJ'" || ok

# A4 — Bad credentials and an empty body: 0/0 everywhere, unreadable, ONE stderr
# line per refused token, naming the identity and nothing else.
cache Org/dead ghs_dead
cache Org/void ghs_void          # no body file: the empty-answer half
J2=$(status --json); E2=$(cat "$A/err.txt")
for ID in Org/dead Org/void; do
  R=$(jq -c --arg i "$ID" '.[] | select(.identity == $i)' <<<"$J2")
  [ "$(jq -r '[.rest_remaining,.rest_limit,.graphql_remaining,.graphql_limit,.unreadable] | join(",")' <<<"$R")" \
    = "0,0,0,0,true" ] && ok || bad "A4: $ID must report 0/0 and unreadable:true, got '$R'"
  [ "$(jq -r '.resets_at.rest' <<<"$R")" = null ] && ok || bad "A4: $ID must carry no reset time, got '$R'"
  [ "$(grep -c "\--status $ID:" <<<"$E2")" = 1 ] && ok \
    || bad "A4: $ID must produce exactly one stderr note, got: '$E2'"
done
grep -q 'Org/alpha' <<<"$E2" && bad "A4: the stderr note must name only the tokens that failed, got: '$E2'" || ok
scratch_rm "$A/state/gh-app-tokens/Org-dead.json"; scratch_rm "$A/state/gh-app-tokens/Org-void.json"

# A5 — the admin PAT IS the default PAT (the normal case on a one-PAT box):
# ONE row, and it keeps the identity a lane resolves first.
J3=$(env PATH="$T/fakebin:$PATH" HARNESS="$A" HARNESS_ENV_DIR="$A/env" \
      GH_APP_API_BASE="http://api.test" GH_TOKEN=admintok \
      "$A/bin/gh-token.sh" --status --json 2>/dev/null)
[ "$(jq -r 'length' <<<"$J3")" = 4 ] && ok || bad "A5: one token under two names is ONE row (4 total), got '$J3'"
[ "$(jq -r '[.[] | select(.kind == "pat") | .identity] | join(",")' <<<"$J3")" = "pat:default" ] \
  && ok || bad "A5: the deduped PAT row keeps pat:default, got '$J3'"

# A6 — no `?/?` anywhere, and every numeric field really is a number.
grep -q '?/?' <<<"$S$J$E$EJ" && bad "A6: --status printed '?/?'" || ok
[ "$(jq -r '[.[] | .rest_remaining,.rest_limit,.graphql_remaining,.graphql_limit | type] | unique | join(",")' <<<"$J")" \
  = "number" ] && ok || bad "A6: every remaining/limit must be a JSON number, got '$J'"

# A7 — no token VALUE on stdout or stderr, in either form.
grep -qE 'ghs_alpha|ghs_beta|ghs_gamma|pattok|admintok' <<<"$S$J$J3$E$EJ$E2" \
  && bad "A7: a token value reached --status output" || ok

# A8 — a box with no cache directory and no PAT: [] and rc 0, never a bare
# absence a consumer would read as an error.
mkdir -p "$T/a0/bin/lib" "$T/a0/env"
cp "$DIR/bin/gh-token.sh" "$T/a0/bin/"; chmod +x "$T/a0/bin/gh-token.sh"
cp "$DIR/bin/lib/env-path.sh" "$T/a0/bin/lib/"
OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$T/a0" HARNESS_ENV_DIR="$T/a0/env" \
      GH_APP_API_BASE="http://api.test" "$T/a0/bin/gh-token.sh" --status --json 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "[]" ] && ok || bad "A8: no tokens must print [] at rc 0, got rc=$RC '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# D. the counter in bin/lib/gh-limit-logger.sh, the real lib
# ═════════════════════════════════════════════════════════════════════════════
D="$T/d"
mkdir -p "$D/h/logs" "$D/bin/lib" "$D/fakebin"
cp "$DIR/bin/lib/gh-limit-logger.sh" "$D/bin/lib/"
# The gh binary. GH_MODE picks which refusal (or success) it answers with, so
# one stub covers "stdout and rc must be untouched" and "a rate limit is logged".
cat > "$D/fakebin/gh" <<'SH'
#!/bin/bash
case "${GH_MODE:-ok}" in
  ratelimit) echo "GraphQL: API rate limit already exceeded for installation ID 1" >&2; exit 1 ;;
  perm)      echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
  *)         printf '{"ok":true}\n'; exit 0 ;;
esac
SH
chmod +x "$D/fakebin/gh"
# A REAL lane file, named, that sources the lib and makes wrapped calls: the
# caller name in the counter line is $0's basename, so the name has to come from
# a file on disk and not from an inline `bash -c`.
cat > "$D/demo-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$GHLL_LIB" || exit 9
for A in "repos/o/r/pulls/1" "repos/o/r/pulls/2" "rate_limit"; do
  gh api "$A" >/dev/null 2>&1 || true
done
SH
chmod +x "$D/demo-lane.sh"
dcalls() { cat "$D/h/logs/gh-calls/"*.log 2>/dev/null; }

# D1 — one line per wrapped call: epoch, caller, argv1, argv2.
env PATH="$D/fakebin:$PATH" HARNESS="$D/h" GHLL_LIB="$D/bin/lib/gh-limit-logger.sh" \
  bash "$D/demo-lane.sh"
[ -f "$D/h/logs/gh-calls/$HOURF.log" ] && ok \
  || bad "D1: the counter must write logs/gh-calls/$HOURF.log, got: $(ls "$D/h/logs/gh-calls" 2>/dev/null)"
[ "$(dcalls | grep -c .)" = 3 ] && ok || bad "D1: three wrapped calls must write three lines, got: '$(dcalls)'"
[ "$(dcalls | grep -c '^[0-9]\{10\} demo-lane.sh api repos/o/r/pulls/[12]$')" = 2 ] && ok \
  || bad "D1: each line is '<epoch> <caller> <argv1> <argv2>', got: '$(dcalls)'"
[ "$(dcalls | awk -v n="$NOW" '$1+0 >= n-60 && $1+0 <= n+600' | grep -c .)" = 3 ] && ok \
  || bad "D1: every epoch must be this run's, got: '$(dcalls)'"
scratch_rm "$D/h/logs/gh-calls"
env PATH="$D/fakebin:$PATH" HARNESS="$D/h" GHLL_LIB="$D/bin/lib/gh-limit-logger.sh" \
  GH_CALL_CALLER=merge-conductor bash "$D/demo-lane.sh"
[ "$(dcalls | grep -c ' merge-conductor api ')" = 3 ] && ok \
  || bad "D1: GH_CALL_CALLER must override the caller name, got: '$(dcalls)'"

# D2 — the wrapper is still transparent. stdout BYTES and rc, success and
# failure, must equal what the unwrapped binary answers.
wrapped() { ( export PATH="$D/fakebin:$PATH" HARNESS="$D/h" GH_MODE="$1"
              . "$D/bin/lib/gh-limit-logger.sh"; gh api repos/o/r 2>"$D/werr"; echo "rc=$?" ) }
raw()     { ( export PATH="$D/fakebin:$PATH" GH_MODE="$1"
              command gh api repos/o/r 2>"$D/rerr"; echo "rc=$?" ) }
for M in ok ratelimit perm; do
  WO=$(wrapped "$M"); WE=$(cat "$D/werr"); RO=$(raw "$M"); RE=$(cat "$D/rerr")
  [ "$WO" = "$RO" ] && [ "$WE" = "$RE" ] && ok \
    || bad "D2: GH_MODE=$M — wrapped ('$WO' / '$WE') must match unwrapped ('$RO' / '$RE')"
done
[ "$(grep -c 'gh-limit identity=' "$D/h/logs/gh-rate.log" 2>/dev/null)" = 1 ] && ok \
  || bad "D2: only the rate-limit refusal is logged as one, got: '$(cat "$D/h/logs/gh-rate.log" 2>/dev/null)'"

# D3 — a logs/ we cannot write changes NOTHING: same rc, same stdout, no stderr
# noise, nothing created. $T/notafile is a regular FILE, so mkdir -p under it
# cannot work — an unwritable log inside the scratch tree, never a real path.
: > "$D/notafile"
OUT=$( ( export PATH="$D/fakebin:$PATH" HARNESS="$D/notafile/nope" GH_MODE=ok
         . "$D/bin/lib/gh-limit-logger.sh"; gh api repos/o/r; echo "rc=$?" ) 2>"$D/d3err" )
[ "$OUT" = '{"ok":true}
rc=0' ] && ok || bad "D3: an unwritable counter must not change stdout or rc, got '$OUT'"
[ ! -s "$D/d3err" ] && ok || bad "D3: an unwritable counter must stay silent, got '$(cat "$D/d3err")'"
[ ! -e "$D/notafile/nope" ] && ok || bad "D3: nothing may be created under an unwritable path"

# D4 — the writer prunes its own directory at 180 minutes (D21), on the hour
# boundary, and never the file it just wrote.
scratch_rm "$D/h/logs/gh-calls"; mkdir -p "$D/h/logs/gh-calls"
OLDF="$D/h/logs/gh-calls/2026010100.log"
printf '%s stale-lane api x\n' "$(( NOW - 14400 ))" > "$OLDF"
touch -d "@$(( NOW - 14400 ))" "$OLDF"
FRESHNAME="$D/h/logs/gh-calls/2026010101.log"
printf '%s fresh-by-mtime api x\n' "$NOW" > "$FRESHNAME"
env PATH="$D/fakebin:$PATH" HARNESS="$D/h" GHLL_LIB="$D/bin/lib/gh-limit-logger.sh" \
  bash "$D/demo-lane.sh"
[ ! -e "$OLDF" ] && ok || bad "D4: a counter file older than 180 minutes must be pruned"
[ -e "$FRESHNAME" ] && ok || bad "D4: pruning is by MTIME, not by the hour in the name"
[ -s "$D/h/logs/gh-calls/$HOURF.log" ] && ok || bad "D4: the file just written must survive its own prune"

# D4 mutant (D1 of build-discipline): a lib copy with the counter append removed
# must fail the assertion D1 makes. A suite that stays green under this mutation
# would be asserting nothing.
MUT="$D/mutant.sh"
sed '/>> "\$dir\/\$hr.log"/d; /printf .%s %s %s %s\\n. "\$ep"/d' \
  "$DIR/bin/lib/gh-limit-logger.sh" > "$MUT"
cmp -s "$DIR/bin/lib/gh-limit-logger.sh" "$MUT" \
  && bad "D4: the mutant is identical to the shipped lib — the mutation did not apply" || ok
scratch_rm "$D/h/logs/gh-calls"
env PATH="$D/fakebin:$PATH" HARNESS="$D/h" GHLL_LIB="$MUT" bash "$D/demo-lane.sh"
[ "$(dcalls | grep -c .)" = 0 ] && ok \
  || bad "D4: with the append removed the counter must be empty (so D1 goes red), got: '$(dcalls)'"

# ═════════════════════════════════════════════════════════════════════════════
# B/C. bin/fleet-status-push.sh — the real lane, driven whole
# ═════════════════════════════════════════════════════════════════════════════
B="$T/b"
mkdir -p "$B/bin/lib" "$B/logs" "$B/state" "$B/flags" "$B/env" "$T/bfake"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/box-for.sh" "$B/bin/"
cp "$DIR/bin/lib/gh-quota.sh" "$DIR/bin/lib/env-path.sh" "$B/bin/lib/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$B/env/global.env"
printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$B/fleet.conf"
# The watchdog POST and the helper's /rate_limit read go through the same curl on
# a real box, so this stub answers both: the status push is captured, anything
# else falls through to section A's per-token bodies.
cat > "$T/bfake/curl" <<SH
#!/bin/bash
case "\$*" in
  *harness-watchdog*|*/api/status*) cat > "$T/PUSH.json"; exit 0 ;;
esac
AUTH=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -H) case "\$2" in Authorization:*) AUTH="\${2#Authorization: }" ;; esac; shift 2 ;;
    -m|-X|-d) shift 2 ;;
    *) shift ;;
  esac
done
BODY="$A/bodies/\${AUTH#token }.json"
[ -f "\$BODY" ] && cat "\$BODY"
exit 0
SH
chmod +x "$T/bfake/curl"
# Every beat, one per line: the fleet_status snapshot and any fleet_alert land in
# the same file on a real box, and the assertions pick them apart by kind.
cat > "$B/bin/beat.sh" <<SH
#!/bin/bash
printf '%s\n' "\$1" >> "$T/BEATS.jsonl"
exit 0
SH
chmod +x "$B/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$B/bin/lane-alert.sh"; chmod +x "$B/bin/lane-alert.sh"
# The knob store. An empty value file is "no row" (setting_get's own rc 2), which
# is what a fresh worker answers and what the code fallback exists for.
cat > "$B/bin/jobs-client.sh" <<SH
#!/bin/bash
setting_get() {
  local v; v=\$(cat "$T/setting-value" 2>/dev/null)
  [ -n "\$v" ] || return 2
  printf '%s' "\$v"
}
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
SH
chmod +x "$B/bin/jobs-client.sh"
: > "$T/setting-value"
# The helper, stubbed: MODE picks "answers rows", "exits 1" or "prints an object
# that is not an array". Section B7 swaps in the REAL bin/gh-token.sh.
cat > "$B/bin/gh-token.sh" <<SH
#!/bin/bash
case "\$(cat "$T/ghq-mode" 2>/dev/null)" in
  fail)     exit 1 ;;
  notarray) printf '{"rows":[]}\n'; exit 0 ;;
  *)        cat "$T/ghq-rows.json" ;;
esac
SH
chmod +x "$B/bin/gh-token.sh"
printf 'rows' > "$T/ghq-mode"

# row <identity> <rest_rem> <rest_lim> <gql_rem> <gql_lim> <reset-iso> [unreadable]
row() {
  jq -nc --arg i "$1" --argjson rr "$2" --argjson rl "$3" --argjson gr "$4" --argjson gl "$5" \
     --arg iso "$6" --argjson u "${7:-false}" \
    '{identity:$i, kind:(if ($i|startswith("pat:")) then "pat" else "app" end),
      slug:(if ($i|startswith("app:")) then ($i|ltrimstr("app:")) else null end),
      rest_remaining:$rr, rest_limit:$rl, graphql_remaining:$gr, graphql_limit:$gl,
      resets_at:{rest:$iso, graphql:$iso}, expires_at:null,
      unreadable:$u, graphql_unreadable:false}'
}
rows() { printf '%s\n' "$@" | jq -sc '.' > "$T/ghq-rows.json"; }
brun() {
  rm -f "$T/PUSH.json"
  env PATH="$T/bfake:$PATH" HARNESS="$B" FLEET_CONF="$B/fleet.conf" \
    bash "$DIR/bin/fleet-status-push.sh" >/dev/null 2>&1
}
q()     { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }
snapb() { jq -c 'select(.kind == "fleet_status")' "$T/BEATS.jsonl" 2>/dev/null | tail -1; }
alertb(){ jq -c 'select(.kind == "fleet_alert")' "$T/BEATS.jsonl" 2>/dev/null; }
ghqlog(){ cat "$B/logs/gh-quota.log" 2>/dev/null; }
# grep -c prints 0 and exits 1 when it matches nothing, so the count is READ from
# the assignment, never from an `|| echo 0` that would print a second zero.
alerts(){ local n; n=$(grep -c '\[gh-quota\] GitHub quota low' "$B/logs/ALERTS.log" 2>/dev/null); printf '%s' "${n:-0}"; }
creset() { : > "$B/logs/ALERTS.log"; rm -f "$B/flags/"alerted-gh-quota-* ; : > "$B/logs/gh-quota.log"
           rm -f "$T/BEATS.jsonl"; }

# ── B1-B3: three rows reach the payload and the console beat, unchanged ──────
rows "$(row app:Org/alpha 4996 5000 4400 5000 "$ISO_R")" \
     "$(row app:Org/beta  4000 5000 4000 5000 "$ISO_R")" \
     "$(row pat:default   3000 5000 3000 5000 "$ISO_R")"
creset; brun
[ "$(q '.gh_quota | length')" = 3 ] && ok || bad "B1: .gh_quota must carry one row per token, got: $(q '.gh_quota|tojson')"
[ "$(jq -r '.gh_quota | length' <<<"$(snapb)")" = 3 ] && ok \
  || bad "B1: the console beat must carry the same key, got: $(snapb)"
q 'has("quota")' | grep -qx true && ok || bad "B1: the Anthropic quota block must still be there"
[ "$(q '[.gh_quota[0] | has("identity"), has("rest_remaining"), has("graphql_remaining"), has("resets_at")] | all')" = true ] \
  && ok || bad "B2: every row needs identity, rest_remaining, graphql_remaining, resets_at — got $(q '.gh_quota[0]|tojson')"
[ "$(q '.gh_quota[0].identity')" = "app:Org/alpha" ] && ok \
  || bad "B3: the rows must pass through unchanged, got $(q '.gh_quota[0]|tojson')"
[ "$(q '.gh_quota[0].rest_remaining')" = 4996 ] && ok || bad "B3: numbers must pass through unchanged"

# ── B4: the helper cannot cost the dead-man push ─────────────────────────────
# Three failure shapes, one rule: the key is ABSENT, never null and never [],
# the push is still a valid snapshot, and logs/gh-quota.log names the reason.
for MODE in fail notarray missing; do
  creset
  case "$MODE" in
    missing) mv "$B/bin/gh-token.sh" "$B/bin/gh-token.sh.off" ;;
    *)       printf '%s' "$MODE" > "$T/ghq-mode" ;;
  esac
  brun
  jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "B4/$MODE: the push must still be valid JSON"
  [ "$(q 'has("gh_quota")')" = false ] && ok || bad "B4/$MODE: gh_quota must be ABSENT, got $(q '.gh_quota|tojson')"
  [ "$(q '.gh_quota')" = null ] && ok || bad "B4/$MODE: an absent key must read as null through jq, never as []"
  [ "$(q 'has("projects")')" = true ] && ok || bad "B4/$MODE: the rest of the snapshot must be untouched"
  case "$MODE:$(ghqlog)" in
    fail:*helper-failed*|notarray:*nonjson*|missing:*helper-missing*) ok ;;
    *) bad "B4/$MODE: logs/gh-quota.log must name the reason, got: '$(ghqlog)'" ;;
  esac
  [ "$(alerts)" = 0 ] && ok || bad "B4/$MODE: a helper that answered nothing must not page"
  case "$MODE" in missing) mv "$B/bin/gh-token.sh.off" "$B/bin/gh-token.sh" ;; esac
done
printf 'rows' > "$T/ghq-mode"

# ── B5: the 64000-byte backstop still fits ──────────────────────────────────
# The pad rides in on stale_owed, which the worker reads as a per-project count
# map — one long key is the cheapest way to push the snapshot past the cap
# without inventing a fleet of projects.
creset
jq -n --arg k "$(printf 'p%.0s' $(seq 1 61000))" '{($k):{count:3}}' > "$B/state/stale-owed.json"
brun
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "B5: an oversized payload must be trimmed, got $(q 'keys|tojson')"
[ "$(q 'has("gh_quota")')" = false ] && ok || bad "B5: gh_quota must be shed with the other 2026-09-14 fields"
scratch_rm "$B/state/stale-owed.json"; rm -f "$B/state/stale-owed-reported.json"

# ── B6/B7: the REAL helper, and no token value anywhere in the payload ───────
# This is the one section that runs the shipped bin/gh-token.sh end to end from
# the lane that consumes it: five real cache/PAT tokens, one curl per token, and
# the payload must carry their identities and none of their values.
creset
cp "$DIR/bin/gh-token.sh" "$B/bin/gh-token.sh"; chmod +x "$B/bin/gh-token.sh"
mkdir -p "$B/state/gh-app-tokens"
cp "$A/state/gh-app-tokens/"*.json "$B/state/gh-app-tokens/"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$B/env/github-admin.env"
rm -f "$T/PUSH.json" "$T/BEATS.jsonl"
env PATH="$T/bfake:$PATH" HARNESS="$B" FLEET_CONF="$B/fleet.conf" \
    GH_APP_API_BASE="http://api.test" GH_TOKEN=pattok \
    bash "$DIR/bin/fleet-status-push.sh" >/dev/null 2>&1
[ "$(q '.gh_quota | length')" = 5 ] && ok \
  || bad "B7: the real helper must report all five tokens, got $(q '.gh_quota|tojson')"
[ "$(q '[.gh_quota[].identity] | sort | join(",")')" = "Org/alpha,Org/beta,Org/gamma,pat:admin,pat:default" ] \
  && ok || bad "B7: the identities must come through, got $(q '[.gh_quota[].identity]|tojson')"
grep -qE 'ghs_alpha|ghs_beta|ghs_gamma|pattok|admintok' "$T/PUSH.json" \
  && bad "B6: a token value reached the pushed payload" || ok
grep -qE 'ghs_alpha|ghs_beta|ghs_gamma|pattok|admintok' "$B/logs/ALERTS.log" 2>/dev/null \
  && bad "C7: a token value reached logs/ALERTS.log" || ok
# Org/gamma is at 0% graphql and 0.2% REST, so the real helper's own numbers
# page — which is the whole gauge, driven once end to end.
grep -q '\[gh-quota\] GitHub quota low for app:Org/gamma' "$B/logs/ALERTS.log" && ok \
  || bad "B7: a genuinely drained token must page from the real helper's numbers, got: '$(cat "$B/logs/ALERTS.log" 2>/dev/null)'"
# Back to the canned stub for the alert sections.
cp "$B/bin/gh-token.sh" "$T/real-gh-token.sh"
cat > "$B/bin/gh-token.sh" <<SH
#!/bin/bash
case "\$(cat "$T/ghq-mode" 2>/dev/null)" in
  fail)     exit 1 ;;
  notarray) printf '{"rows":[]}\n'; exit 0 ;;
  *)        cat "$T/ghq-rows.json" ;;
esac
SH
chmod +x "$B/bin/gh-token.sh"
scratch_rm "$B/state/gh-app-tokens"; rm -f "$B/env/github-admin.env"

# ── C1: 15% REST, three ticks, ONE line ─────────────────────────────────────
mkdir -p "$B/logs/gh-calls"
: > "$B/logs/gh-calls/$HOURF.log"
for I in $(seq 1 7);  do printf '%s merge-conductor api x\n'  "$NOW" >> "$B/logs/gh-calls/$HOURF.log"; done
for I in $(seq 1 4);  do printf '%s merge-sweep api x\n'      "$NOW" >> "$B/logs/gh-calls/$HOURF.log"; done
for I in $(seq 1 2);  do printf '%s blocked-resolver api x\n' "$NOW" >> "$B/logs/gh-calls/$HOURF.log"; done
printf '%s review-prs api x\n' "$NOW" >> "$B/logs/gh-calls/$HOURF.log"
for I in $(seq 1 50); do printf '%s stale-lane api x\n' "$(( NOW - 7200 ))" >> "$B/logs/gh-calls/$HOURF.log"; done
rows "$(row app:Org/alpha 750 5000 4400 5000 "$ISO_R")"
creset
brun; brun; brun
[ "$(alerts)" = 1 ] && ok || bad "C1: three ticks in one reset window must write exactly ONE line, got $(alerts): $(cat "$B/logs/ALERTS.log")"
grep -q '\[gh-quota\] GitHub quota low for app:Org/alpha: rest 750 of 5000 left (15% left)' "$B/logs/ALERTS.log" \
  && ok || bad "C1: the line must name the identity and the low bucket, got: '$(cat "$B/logs/ALERTS.log")'"
grep -q "resets at $ISO_R" "$B/logs/ALERTS.log" && ok \
  || bad "C1: the line must carry the reset time, got: '$(cat "$B/logs/ALERTS.log")'"
[ "$(alertb | jq -r '.akey' | grep -cE '^ghquota:app:Org/alpha:[0-9]+$')" = 1 ] \
  && ok || bad "C1: exactly one fleet_alert beat, keyed on credential+fire epoch, got: '$(alertb)'"
grep -qE '^[0-9]+ 15$' "$B/flags/alerted-gh-quota-app_Org_alpha" 2>/dev/null && ok \
  || bad "C1: the dedupe flag must be keyed on the credential and hold '<epoch> 15', got: $(ls "$B/flags" | tr '\n' ' ')"

# ── C6: the top-three clause, in count order, from the counter ──────────────
grep -q 'top callers last hour: merge-conductor 7, merge-sweep 4, blocked-resolver 2$' "$B/logs/ALERTS.log" \
  && ok || bad "C6: the line must end with the top three callers in count order, got: '$(cat "$B/logs/ALERTS.log")'"

# ── C2: a NEW reset window inside 2h is NOT a new line (BH-4717.2) ─────────
RESET_R2=$(( RESET_R + 3600 )); ISO_R2=$(iso_at "$RESET_R2")
rows "$(row app:Org/alpha 750 5000 4400 5000 "$ISO_R2")"
brun
[ "$(alerts)" = 1 ] && ok || bad "C2: a new reset epoch inside the 2h window must not write a second line, got $(alerts): $(cat "$B/logs/ALERTS.log")"

# ── C3: healthy is silent; either budget being low is enough ────────────────
creset
rows "$(row app:Org/alpha 1250 5000 1250 5000 "$ISO_R")"
brun
[ "$(alerts)" = 0 ] && ok || bad "C3: 25% on both buckets is not low, got: '$(cat "$B/logs/ALERTS.log")'"
creset
rows "$(row app:Org/alpha 5000 5000 750 5000 "$ISO_R")"
brun
[ "$(alerts)" = 1 ] && ok || bad "C3: a low GRAPHQL bucket beside a healthy REST one must page, got: '$(cat "$B/logs/ALERTS.log")'"
grep -q 'graphql 750 of 5000 left (15% left)' "$B/logs/ALERTS.log" && ok \
  || bad "C3: the line must report the graphql bucket, got: '$(cat "$B/logs/ALERTS.log")'"
# Exactly AT the threshold is not below it.
creset
rows "$(row app:Org/alpha 1000 5000 1000 5000 "$ISO_R")"
brun
[ "$(alerts)" = 0 ] && ok || bad "C3: exactly 20% is not low, got: '$(cat "$B/logs/ALERTS.log")'"

# ── C4: unknown is logged, never paged ──────────────────────────────────────
creset
rows "$(row app:Org/alpha 0 0 0 0 "" true)"
brun
[ "$(alerts)" = 0 ] && ok || bad "C4: an unreadable token must not page, got: '$(cat "$B/logs/ALERTS.log")'"
grep -q 'unreadable token app:Org/alpha' "$B/logs/gh-quota.log" && ok \
  || bad "C4: an unreadable token must be logged once, got: '$(ghqlog)'"
creset
rows "$(row app:Org/alpha 0 0 0 0 "$ISO_R")"
brun
[ "$(alerts)" = 0 ] && ok || bad "C4: 0/0 is unknown, never 0% left, got: '$(cat "$B/logs/ALERTS.log")'"

# ── C5: the threshold is DB-driven, and a bad row falls back loudly ─────────
creset
rows "$(row app:Org/alpha 1250 5000 1250 5000 "$ISO_R")"
printf '30' > "$T/setting-value"; brun
[ "$(alerts)" = 1 ] && ok || bad "C5: with gh_quota_alert_pct=30 a 25% row must page, got: '$(cat "$B/logs/ALERTS.log")'"
creset
printf 'abc' > "$T/setting-value"; brun
[ "$(alerts)" = 0 ] && ok || bad "C5: an unusable knob must fall back to 20, so 25% stays quiet"
[ "$(grep -c "gh_quota_alert_pct='abc'" "$B/logs/gh-quota.log")" = 1 ] && ok \
  || bad "C5: the bad value must be named once, got: '$(ghqlog)'"
: > "$T/setting-value"

# ── C6b: an empty counter says so, rather than trailing off ─────────────────
creset
scratch_rm "$B/logs/gh-calls"
rows "$(row app:Org/alpha 750 5000 4400 5000 "$ISO_R")"
brun
grep -q 'top callers last hour: none recorded$' "$B/logs/ALERTS.log" && ok \
  || bad "C6b: with no counter the clause must read 'none recorded', got: '$(cat "$B/logs/ALERTS.log")'"

# ── C7 mutant: with the threshold compare neutralised, C1 must go red ───────
CMUT="$T/gh-quota-mutant.sh"
sed 's/(($rp >= 0) and ($rp < $pct))/(($rp >= 0) and ($rp < 0))/; s/(($gp >= 0) and ($gp < $pct))/(($gp >= 0) and ($gp < 0))/' \
  "$DIR/bin/lib/gh-quota.sh" > "$CMUT"
cmp -s "$DIR/bin/lib/gh-quota.sh" "$CMUT" \
  && bad "C7: the mutant is identical to the shipped lib — the mutation did not apply" || ok
creset
cp "$CMUT" "$B/bin/lib/gh-quota.sh"
brun
[ "$(alerts)" = 0 ] && ok \
  || bad "C7: with the threshold compare removed nothing may page (so C1 goes red), got: '$(cat "$B/logs/ALERTS.log")'"
cp "$DIR/bin/lib/gh-quota.sh" "$B/bin/lib/gh-quota.sh"
creset; brun
[ "$(alerts)" = 1 ] && ok || bad "C7: the shipped lib must page again once the mutant is reverted"

# ═════════════════════════════════════════════════════════════════════════════
# E. the two merge-path lanes that never sourced the identity logger
# ═════════════════════════════════════════════════════════════════════════════
# Each lane is run WHOLE against a gh stub that refuses every call with GitHub's
# own GraphQL rate-limit wording on stderr. Before this ticket neither lane
# sourced bin/lib/gh-limit-logger.sh, so those refusals named nothing and their
# calls were invisible to the top-callers clause in section C.
elane() { # elane <lane-basename> — "<gh-limit lines>|<counter lines with this caller>"
  local lane="$1" root="$2"
  printf '%s|%s' \
    "$(grep -c 'gh-limit identity=' "$root/logs/gh-rate.log" 2>/dev/null)" \
    "$(cat "$root/logs/gh-calls/"*.log 2>/dev/null | grep -c " $lane ")"
}
# The refusing GitHub, shared by both lanes.
mk_gh_refuse() { # mk_gh_refuse <path> <argv-log>
  cat > "$1" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$2"
echo "GraphQL: API rate limit already exceeded for installation ID 1" >&2
exit 1
SH
  chmod +x "$1"
}

# ── E1: bin/merge-queue.sh ──────────────────────────────────────────────────
E1="$T/e1"
mkdir -p "$E1/bin/lib/mc" "$E1/logs" "$E1/state/merge-queue/eproj" "$E1/flags" "$E1/locks" \
         "$E1/env" "$T/e1fake"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$E1/bin/"
cp "$DIR"/bin/lib/{merge-conductor-lib,gh-rest,gh-pr-list,main-red-gate,gh-budget,gh-limit-logger,gh-pr-merge,env-path,lane-gate,gh-app-auth,gh-repo-token}.sh \
   "$E1/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$E1/bin/lib/mc/"
chmod +x "$E1/bin/"*.sh
printf 'eproj Org/eproj - - 2 box-e\n' > "$E1/fleet.conf"
: > "$E1/env/global.env"
touch "$E1/state/merge-queue/eproj/42"
printf '#!/bin/bash\nprintf ghs_efixture\n' > "$E1/bin/gh-token.sh"; chmod +x "$E1/bin/gh-token.sh"
printf '#!/bin/bash\nexit 0\n' > "$E1/bin/beat.sh"; chmod +x "$E1/bin/beat.sh"
mk_gh_refuse "$T/e1fake/gh" "$T/e1-argv.log"
env PATH="$T/e1fake:$PATH" HARNESS="$E1" FLEET_CONF="$E1/fleet.conf" \
  GH_LIMIT_IDENTITY=app:Org/eproj bash "$E1/bin/merge-queue.sh" eproj >/dev/null 2>&1
E1R=$(elane merge-queue.sh "$E1")
[ "${E1R%%|*}" -ge 1 ] && ok \
  || bad "E1: merge-queue.sh must log the refused identity to logs/gh-rate.log, got '$E1R' (calls: $(head -3 "$T/e1-argv.log" 2>/dev/null | tr '\n' ';'))"
[ "${E1R##*|}" -ge 1 ] && ok \
  || bad "E1: merge-queue.sh's calls must reach the counter under its own name, got '$E1R'"
grep -q 'identity=unset' "$E1/logs/gh-rate.log" \
  && bad "E1: the line must name an identity, not 'unset': $(head -1 "$E1/logs/gh-rate.log")" || ok

# ── E2: bin/blocked-resolver.sh ─────────────────────────────────────────────
E2="$T/e2"
mkdir -p "$E2/bin/lib/mc" "$E2/logs" "$E2/state/merge-conductor" "$E2/state/build-queue/tproj" \
         "$E2/flags" "$E2/locks" "$E2/env" "$E2/builds" "$T/e2fake" "$T/e2repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$E2/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$E2" || exit 1
cp "$DIR"/bin/lib/{gh-rest,gh-pr-list,merge-conductor-lib,rebuild-ledger,gh-limit-logger,gh-app-auth,gh-repo-token,gh-budget,env-path,lane-gate,main-red-gate}.sh \
   "$E2/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$E2/bin/lib/mc/"
chmod +x "$E2/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$E2/fleet.conf"
: > "$E2/env/global.env"
for F in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh \
         internal-token-for.sh gh-token.sh lane-alert.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$E2/bin/$F"; chmod +x "$E2/bin/$F"
done
printf '#!/bin/bash\nexit 0\n' > "$T/e2fake/flock"; chmod +x "$T/e2fake/flock"
mk_gh_refuse "$T/e2fake/gh" "$T/e2-argv.log"
ESHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' 'o/tproj#7' "$NOW" "$ESHA" "$ESHA" \
  'conflict-unresolvable' 'https://github.com/o/tproj/pull/7' > "$E2/state/merge-conductor/pr-state.tsv"
env PATH="$T/e2fake:$PATH" HARNESS="$E2" FLEET_CONF="$E2/fleet.conf" REPOS_ROOT="$T/e2repos" \
  BR_SSH=/bin/true GH_LIMIT_IDENTITY=app:o/tproj \
  bash "$E2/bin/blocked-resolver.sh" >/dev/null 2>&1
E2R=$(elane blocked-resolver.sh "$E2")
[ "${E2R%%|*}" -ge 1 ] && ok \
  || bad "E2: blocked-resolver.sh must log the refused identity to logs/gh-rate.log, got '$E2R' (calls: $(head -3 "$T/e2-argv.log" 2>/dev/null | tr '\n' ';'))"
[ "${E2R##*|}" -ge 1 ] && ok \
  || bad "E2: blocked-resolver.sh's calls must reach the counter under its own name, got '$E2R'"
grep -q 'identity=unset' "$E2/logs/gh-rate.log" \
  && bad "E2: the line must name an identity, not 'unset': $(head -1 "$E2/logs/gh-rate.log")" || ok

# ═════════════════════════════════════════════════════════════════════════════
# F. the merge path, MEASURED — one listing per author, N REST reads, no views
# ═════════════════════════════════════════════════════════════════════════════
# Acceptance 3 of the ticket, pinned rather than built: main already converted
# every per-PR read on this path to REST (mc_pr_view over bin/lib/gh-rest.sh,
# BH-783/784/994). What was missing was a way to KNOW, and the counter from
# section D is it. The mutant at the end replaces mc_pr_view's body with the
# `gh pr view --json` call it used to be, and F1 must go red on it.
mk_conductor() { # mk_conductor <root> — the tick fixture; nothing GitHub-writing
  local h="$1"
  mkdir -p "$h/bin/lib/mc" "$h/bin/lib/jobs" "$h/logs" "$h/state" "$h/flags" "$h/locks" \
           "$h/builds" "$h/env"
  cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$h/bin/"
  cp "$DIR"/bin/lib/{gh-pr-list,merge-conductor-lib,gh-rest,main-red-gate,gh-budget,gh-limit-logger,env-path}.sh \
     "$h/bin/lib/"
  cp "$DIR"/bin/lib/mc/*.sh "$h/bin/lib/mc/"
  cp "$DIR"/bin/lib/jobs/*.sh "$h/bin/lib/jobs/"
  chmod +x "$h/bin/"*.sh
  printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$h/fleet.conf"
  : > "$h/env/global.env"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$h/bin/agent-call.sh"; chmod +x "$h/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$h/bin/beat.sh"; chmod +x "$h/bin/beat.sh"
  # One build record per PR, APPROVE bound to the head the list reports. Without
  # them every row classifies HEAD_MOVED off the LIST alone and the tick never
  # reads a PR at all — which would make "N REST reads" a count of zero and this
  # whole section vacuous.
  local n
  for n in 11 12 13; do
    mkdir -p "$h/builds/demo-os-TK-$n-2026091200$n"
    echo "PR_CREATED https://github.com/example-org/demo-os/pull/$n" > "$h/builds/demo-os-TK-$n-2026091200$n/RESULT"
    printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$h/builds/demo-os-TK-$n-2026091200$n/review.md"
    echo cccccccc3333 > "$h/builds/demo-os-TK-$n-2026091200$n/reviewed-sha"
  done
}
FH="$T/f/h"; mkdir -p "$T/f" "$T/ffake"
mk_conductor "$FH"
cp "$DIR/tests/lib/rest-emit.sh" "$T/ffake/restpr"; chmod +x "$T/ffake/restpr"
FSHA=cccccccc3333
cat > "$T/ffake/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/f-argv.log"
case "\$*" in
  *"pr merge"*|*push*|*"pr comment"*|*"issue close"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB: \$*" >> "$T/f-writes.log"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$FSHA","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$FSHA","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$FSHA","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  # TEST-CHANGE (BH-1585): the open list is a REST page now (its merge state is
  # read per PR by the arm below). The same three PRs, in the REST shape.
  *"repos/example-org/demo-os/pulls?state=open"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    for n in 11 12 13; do printf '{"number":%s,"html_url":"https://github.com/example-org/demo-os/pull/%s","draft":false,"state":"open","user":{"login":"operator","type":"User"},"labels":[],"head":{"ref":"ticket/pb-%s","sha":"$FSHA","repo":{"full_name":"example-org/demo-os"}},"base":{"ref":"main","repo":{"full_name":"example-org/demo-os"}},"updated_at":"2026-09-12T00:00:00Z"}\n' \$n \$n \$n; done | jq -sc . ;;
  *"pr view"*) printf '{"state":"OPEN","headRefOid":"$FSHA"}\n' ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/1"*)
    restpr OPEN "$FSHA" "ticket/pb-\${*##*/}" main "" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/ffake/gh"
printf '#!/bin/bash\nprintf "{\\"error\\":\\"not found\\"}\\n404\\n"\n' > "$T/ffake/curl"
chmod +x "$T/ffake/curl"
ftick() { # ftick <harness-root>
  scratch_rm "$1/logs/gh-calls" 2>/dev/null
  : > "$T/f-argv.log"; : > "$T/f-writes.log"
  ( cd "$T/f" && env PATH="$T/ffake:$PATH" HARNESS="$1" HARNESS_SECRET=x \
      bash "$1/bin/merge-conductor.sh" >/dev/null 2>&1 )
}
fcount() { cat "$1/logs/gh-calls/"*.log 2>/dev/null | grep -c "$2"; }

ftick "$FH"
[ "$(fcount "$FH" ' pr view')" = 0 ] && ok \
  || bad "F1: the merge path must issue NO per-PR gh pr view, got $(fcount "$FH" ' pr view'): $(cat "$FH/logs/gh-calls/"*.log)"
FL=$(fcount "$FH" ' pr list')
# ASSERTION CHANGED (BH-1585, behaviour changed on purpose): the open list was
# one GraphQL `gh pr list` per harness author (1..2); it is a REST page now, so
# the merge path makes NO GraphQL listing at all. The REST reads replacing it
# are counted in F3.
[ "$FL" = 0 ] && ok \
  || bad "F2: the merge path must make no GraphQL listing (BH-1585), got $FL"
# gh_rest always spells its reads `gh api -i -X GET`. Since BH-1586 the CI run
# list goes through gh_rest too, so a bare ` api -i` no longer isolates the
# per-PR reads this section is about — and the counter logs only the first
# two words of an argv, never the path. So the per-PR count is read off the
# stub's own full-argv log for the tick just run: FPR matches only the per-PR
# object/diff read (`…/pulls/<n>`), one per open PR.
FPR='api -i -X GET repos/[^ ]*/pulls/[0-9]'
fargv() { grep -c "$1" "$T/f-argv.log" 2>/dev/null; }
# ASSERTION CHANGED (BH-1634): the floor was 3, which the list's own lazy
# merge-state reads (one per open PR, BH-1585) satisfy on their own, so F3 no
# longer noticed mc_pr_diff going missing. Three open PRs give 3 lazy
# merge-state reads plus 3 mc_pr_diff reads: 6. The mutant case below reads the
# same floor, so the two cannot drift apart.
F3_FLOOR=6
[ "$(fargv "$FPR")" -ge "$F3_FLOOR" ] && ok \
  || bad "F3: three open PRs give 3 lazy merge-state reads plus 3 mc_pr_diff reads over REST (>=$F3_FLOOR per-PR 'api -i' calls), got $(fargv "$FPR"): $(cat "$T/f-argv.log")"
FH_PR=$(fargv "$FPR")
[ ! -s "$T/f-writes.log" ] && ok || bad "F: an observe-only tick used a write verb: $(cat "$T/f-writes.log")"

# F mutant (D1). The per-PR read on this tick path is mc_pr_diff, and this
# rewrites its body into the `gh pr view --json` GraphQL read that the pre-BH-783
# conductor used — the exact regression F1 and F3 exist to catch. Both must go
# red on it: three `pr view` calls appear and the three REST reads disappear.
FM="$T/fm/h"; mkdir -p "$T/fm"
mk_conductor "$FM"
awk '
  /^mc_pr_diff\(\) \{$/ {
    print
    print "  gh pr view \"${1:-}\" --json files -q . > \"${2:?outfile}\" 2>/dev/null || return 75"
    skip = 1; next }
  skip && /^\}$/ { print; skip = 0; next }
  skip { next }
  { print }' "$DIR/bin/lib/mc/classify.sh" > "$FM/bin/lib/mc/classify.sh"
cmp -s "$DIR/bin/lib/mc/classify.sh" "$FM/bin/lib/mc/classify.sh" \
  && bad "F: the mutant classifier is identical to the shipped one — the mutation did not apply" || ok
ftick "$FM"
[ "$(fcount "$FM" ' pr view')" -ge 3 ] && ok \
  || bad "F: with the per-PR read back on GraphQL the counter must record one pr view per PR (so F1 goes red), got: $(cat "$FM/logs/gh-calls/"*.log 2>/dev/null)"
# ASSERTION CHANGED (BH-1585): the open list now makes its own per-PR REST
# reads (mergeable_state), so the mutant's per-PR total no longer drops below 3.
# What it loses is still its three mc_pr_diff REST reads: it must make at least
# three FEWER per-PR reads than the real tick did.
[ "$(fargv "$FPR")" -le $(( FH_PR - 3 )) ] && ok \
  || bad "F: the mutant must ALSO lose the per-PR REST reads (so F3 goes red), got $(fargv "$FPR") vs $FH_PR"
# BH-1634: F3's own predicate, run on the mutant. The mutant keeps the three
# lazy merge-state reads and loses the three mc_pr_diff reads, so F3 fails
# with only the lazy reads left.
[ "$(fargv "$FPR")" -lt "$F3_FLOOR" ] && ok \
  || bad "F3 must fail with only the lazy reads: the mutant (no mc_pr_diff REST read) still made $(fargv "$FPR") per-PR reads, which satisfies F3's floor of $F3_FLOOR"

echo "gh-quota.bh-426-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
