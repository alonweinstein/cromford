#!/bin/bash
# tests/triage-gate-linear-fingerprint-test.sh — bin/triage-gate.sh on a
# project whose tracker_adapter row is `linear`, outside --buildable: the
# fingerprint, the board diff, --pending, --thread and --signal all read Linear
# (bin/lib/tracker/linear.sh), and none of them reads GitHub issue #<n>.
#
#   F1  --seed stores the in-app shape {"CRO": [...]} from one TrkFingerprint
#       read, own team and label, own comments filtered out server-side (isMe)
#   F2  an unchanged board is SKIP no-change; the comment order Linear answers
#       in does not move it
#   F3  a newer human comment, or a description edit, is RUN board-changed
#   F4  --pending writes the live fingerprint
#   F5  a Linear read that fails is RUN gate-fetch-failed / --pending exit 1;
#       a page with no cursor fails too; two pages are one board
#   F6  --thread is the in-app kind with the key's own user as the self actor;
#       another team's key, or an issue Linear moved, is exit 1 with nothing
#   F7  --signal: our own comment edited moves nothing, a human's does
#   F8  a context that does not load: SKIP token-unresolved, --pending/--signal
#       exit 1, --seed SEED-FAILED, one ALERTS line per project per day
#   F9  no LINEAR_API_KEY in the env file, or a Jira env, costs no settings
#       call outside --buildable; GitHub is never asked on a Linear project
#
# No network: a `curl` stub plays api.linear.app/graphql from
# tests/fixtures/triage-gate-linear/ and the jobs worker's settings route.
#   HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-linear-fingerprint-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

KEY=tok-FIXTURE-SENTINEL-4078
S="$T/ls"
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$S"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  o/l  https://lin.example  -  9
ghp      o/r  https://gh.example   -  9
jirap    o/j  https://j.example    -  9
CONF
cat > "$T/h/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TL_STATE/alerts"
SH
chmod +x "$T/h/bin/alert-line.sh"
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0 PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_FIX="$DIR/tests/fixtures/triage-gate-linear" TL_KEY_EXPECT="$KEY"

cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|-m|--max-time|--connect-timeout) shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
case "$url" in
  https://jobs.example/api/settings/*)
    key="${url##*/}"; echo "$key" >> "$S/settings.log"
    f="$S/setting-$key"
    [ -r "$f" ] && reply "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) reply 404 '{}' ;;
  https://api.linear.app/graphql) ;;
  *) echo "OFFBASE $url" >> "$S/reqs"; printf '000'; exit 7 ;;
esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
cp "$data" "$S/last-$op.json"
printf '%s %s\n' "$op" "$(jq -r '.variables.id // .variables.after // ""' "$data")" >> "$S/reqs"
[ "$auth" = "$TL_KEY_EXPECT" ] || reply 401 '{"errors":[{"message":"Authentication required"}]}'
[ -e "$S/linear-down" ] && reply 503 'upstream'
case "$op" in
  TrkFingerprint)
    v=$(cat "$S/fp" 2>/dev/null || echo a)
    if [ "$v" = paged ]; then
      [ "$(jq -r '.variables.after // ""' "$data")" = cursor-fixture-1 ] && reply 200 "$(cat "$TL_FIX/fp-p2.json")"
      reply 200 "$(cat "$TL_FIX/fp-p1.json")"
    fi
    reply 200 "$(cat "$TL_FIX/fp-$v.json")" ;;
  TrkThread) reply 200 "$(cat "$TL_FIX/th-$(cat "$S/th" 2>/dev/null || echo a).json")" ;;
esac
reply 400 '{"errors":[{"message":"the stub has no such operation"}]}'
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$TL_STATE/gh.log"
exit 1
SH
chmod +x "$T/stub/curl" "$T/stub/gh"

row()   { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$S/setting-$1"; }
fresh() { rm -f "$S/reqs" "$S/settings.log" "$S/gh.log" "$S"/last-*.json; }
nreq()  { cat "$S/reqs" 2>/dev/null | grep -c .; }
printf 'LINEAR_API_KEY=%s\n' "$KEY" > "$T/h/env/linproj.env"
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
GATE="$DIR/bin/triage-gate.sh"
G="$T/h/state/linproj.gate.json"

# --- F1 -------------------------------------------------------------------
fresh
out=$("$GATE" linproj --seed)
[ "$out" = "SEEDED 2 tickets" ] && ok || bad "F1 --seed: $out"
jq -e 'keys == ["CRO"] and (.CRO | map(.id) == ["CRO-1", "CRO-2"]) and (.CRO[0].key == "CRO-1")' "$G" >/dev/null 2>&1 && ok \
  || bad "F1 the stored fingerprint is the in-app shape keyed by team: $(cat "$G" 2>/dev/null)"
jq -e '.CRO[0] | .lastActivityAt == "2026-10-02T10:00:00.000Z" and .status == "Todo" and .labels == ["ai-build", "area:web"] and (.body | test("^[0-9a-f]{16}$"))' "$G" >/dev/null 2>&1 && ok \
  || bad "F1 a ticket carries the newest comment time, state, labels and a body digest: $(jq -c '.CRO[0]' "$G" 2>/dev/null)"
jq -e '.CRO[1].lastActivityAt == "" and .CRO[1].commentCount == null' "$G" >/dev/null 2>&1 && ok || bad "F1 no comments is an empty lastActivityAt"
[ "$(cat "$S/reqs")" = "TrkFingerprint " ] && ok || bad "F1 exactly one Linear read: $(cat "$S/reqs" 2>/dev/null)"
jq -e '.variables.team == "CRO" and .variables.label == "ai-build" and (.query | test("isMe: \\{ eq: false \\}"))' "$S/last-TrkFingerprint.json" >/dev/null 2>&1 && ok \
  || bad "F1 the read names the team, the label and leaves our own comments out"
[ ! -e "$S/gh.log" ] && ok || bad "F1 GitHub was asked: $(cat "$S/gh.log")"

# --- F2 -------------------------------------------------------------------
fresh
[ "$("$GATE" linproj)" = "SKIP no-change (2 tickets)" ] && ok || bad "F2 an unchanged board: $("$GATE" linproj)"
echo swapped > "$S/fp"
[ "$("$GATE" linproj)" = "SKIP no-change (2 tickets)" ] && ok || bad "F2 the comment order Linear answers in must not move the fingerprint"
[ ! -e "$S/gh.log" ] && ok || bad "F2 GitHub was asked: $(cat "$S/gh.log")"

# --- F3 -------------------------------------------------------------------
echo comment > "$S/fp"
[ "$("$GATE" linproj)" = "RUN board-changed" ] && ok || bad "F3 a newer human comment wakes the tick"
[ -s "$T/h/state/linproj.gate.pending" ] && ok || bad "F3 the moved board is left in gate.pending"
echo body > "$S/fp"
[ "$("$GATE" linproj)" = "RUN board-changed" ] && ok || bad "F3 a description edit wakes the tick"

# --- F4 -------------------------------------------------------------------
rm -f "$T/h/state/linproj.gate.pending"; echo comment > "$S/fp"
"$GATE" linproj --pending; rc=$?
[ "$rc" = 0 ] && jq -e '.CRO[0].lastActivityAt == "2026-10-03T09:00:00.000Z"' "$T/h/state/linproj.gate.pending" >/dev/null 2>&1 && ok \
  || bad "F4 --pending writes the live board (rc=$rc)"

# --- F5 -------------------------------------------------------------------
: > "$S/linear-down"
[ "$("$GATE" linproj)" = "RUN gate-fetch-failed" ] && ok || bad "F5 a Linear outage is the fail-open RUN"
"$GATE" linproj --pending; [ "$?" = 1 ] && ok || bad "F5 --pending on an outage exits 1"
rm -f "$S/linear-down"
echo nocursor > "$S/fp"
[ "$("$GATE" linproj)" = "RUN gate-fetch-failed" ] && ok || bad "F5 a next page with no cursor is a failed read"
echo paged > "$S/fp"; fresh
[ "$("$GATE" linproj --seed)" = "SEEDED 3 tickets" ] && grep -q '^TrkFingerprint cursor-fixture-1$' "$S/reqs" && ok \
  || bad "F5 two pages are one board: $(cat "$S/reqs" 2>/dev/null)"
echo a > "$S/fp"; "$GATE" linproj --seed >/dev/null

# --- F6 -------------------------------------------------------------------
fresh
doc=$("$GATE" linproj --thread CRO-1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$doc" | jq -e '.kind == "inapp" and .self_actors == "u-me" and (.doc.ticket.comments | map(.id) == ["c-1", "c-2"])
  and .doc.ticket.comments[1].author.userId == "u-me"' >/dev/null 2>&1 && ok || bad "F6 --thread CRO-1 (rc=$rc): $doc"
out=$("$GATE" linproj --thread OTH-1); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ! grep -q 'OTH-1' "$S/reqs" && ok || bad "F6 another team's key is never sent (rc=$rc)"
echo moved > "$S/th"
out=$("$GATE" linproj --thread CRO-1); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F6 an issue Linear answers from another team is refused (rc=$rc): $out"
"$GATE" linproj --thread 12; [ "$?" = 1 ] && ok || bad "F6 a bare number is not a Linear key"
[ ! -e "$S/gh.log" ] && ok || bad "F6 GitHub was asked: $(cat "$S/gh.log")"

# --- F7 -------------------------------------------------------------------
echo a > "$S/th"; s0=$("$GATE" linproj --signal CRO-1)
echo self > "$S/th"; s1=$("$GATE" linproj --signal CRO-1)
echo human > "$S/th"; s2=$("$GATE" linproj --signal CRO-1)
printf '%s' "$s0" | grep -qxE '[0-9a-f]{16}' && ok || bad "F7 --signal prints a digest: $s0"
[ -n "$s0" ] && [ "$s0" = "$s1" ] && ok || bad "F7 our own comment edited must not move the signal ($s0 vs $s1)"
[ -n "$s2" ] && [ "$s0" != "$s2" ] && ok || bad "F7 a human's comment edited moves the signal"
echo a > "$S/th"

# --- F8 -------------------------------------------------------------------
printf 'LINEAR_API_KEY=\n' > "$T/h/env/linproj.env"; rm -f "$S/alerts"; fresh
[ "$("$GATE" linproj)" = "SKIP token-unresolved" ] && ok || bad "F8 an empty key: $("$GATE" linproj)"
"$GATE" linproj --pending; [ "$?" = 1 ] && ok || bad "F8 --pending exits 1"
"$GATE" linproj --signal CRO-1 >/dev/null; [ "$?" = 1 ] && ok || bad "F8 --signal exits 1"
case "$("$GATE" linproj --seed)" in SEED-FAILED*) ok ;; *) bad "F8 --seed fails" ;; esac
[ "$("$GATE" linproj --buildable CRO-1)" = "BLOCKED token-unresolved" ] && ok || bad "F8 --buildable is blocked"
[ "$(grep -c . "$S/alerts" 2>/dev/null)" = 1 ] && grep -q 'LINEAR_API_KEY' "$S/alerts" && ok \
  || bad "F8 one ALERTS line a day, naming the cause: $(cat "$S/alerts" 2>/dev/null)"
[ "$(nreq)" = 0 ] && [ ! -e "$S/gh.log" ] && ok || bad "F8 nothing is read on a context that did not load"
printf 'LINEAR_API_KEY=%s\n' "$KEY" > "$T/h/env/linproj.env"

# --- F9 -------------------------------------------------------------------
# (ready_queue_rows is the ready-queue lib's own row, asked on every board.)
fresh; "$GATE" ghp >/dev/null 2>&1
! grep -q '^tracker' "$S/settings.log" 2>/dev/null && [ "$(nreq)" = 0 ] && ok || bad "F9 a GitHub project paid a tracker settings call: $(cat "$S/settings.log" 2>/dev/null)"
printf 'JIRA_BASE=https://jira.example\n' > "$T/h/env/jirap.env"; fresh; "$GATE" jirap >/dev/null 2>&1
! grep -q '^tracker' "$S/settings.log" 2>/dev/null && ok || bad "F9 Jira stays --buildable only: $(cat "$S/settings.log" 2>/dev/null)"

echo "triage-gate-linear-fingerprint: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
