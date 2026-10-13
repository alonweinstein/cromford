#!/bin/bash
# tests/deploy-queue-rows.bh-1026-test.sh — BH-1026.1: the `deploy_queue` ROWS,
# the request that writes one, and the train that claims one before it fires a
# deploy hook.
#
# WHAT IS UNDER TEST, and why each half is driven rather than read:
#
#   * the four `deploy_queue_*` helpers, against a fake worker AND against a
#     dead one. The fail-open contract is the whole reason this layer exists:
#     rc 1 and NOTHING on stdout when the worker is unreachable. A helper that
#     printed its payload on a failure would have the train read an empty batch
#     as "nothing queued" — which is a deploy that silently never departs.
#   * bin/deploy-request.sh and bin/deploy-train.sh THEMSELVES, not extracts of
#     them, against a stubbed `curl` that is the jobs worker, the project's
#     version endpoint and the deploy hook at once. The ORDER of the requests in
#     the sink is the claim-before-hook property, and it is only observable by
#     running the real script.
#   * the negative that costs the most: with the flag OFF, or with the worker
#     down, the lane must behave byte for byte as it does today — the file dir
#     is still written and still read. "The worker did not answer" is never
#     "nothing queued".
#
# THE FILE DIR IS NOT GONE. bin/deploy-request.sh writes it in every mode, and
# the train reads it whenever the rows are not available. That is deliberate for
# this slice and §3/§7/§8 are what pin it.
#
# Run from anywhere: tests/deploy-queue-rows.bh-1026-test.sh   (exit 0 = pass)
# No network, no LLM. One clock anchor (NOW), everything derived from it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date +%s)
TAB=$(printf '\t')

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/env" "$H/locks" "$H/state/deploy-queue/p" \
         "$T/fakebin" "$T/calls" "$T/builds/b1"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
# a fixture that copies it must copy its modules too.
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh

# a two-commit repo standing in for /root/repos/<project>; origin/main = HEAD
git init -q "$T/repo" && (cd "$T/repo" \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" \
  && git push -q origin HEAD:main && git update-ref refs/remotes/origin/main HEAD)
TARGET=$(git -C "$T/repo" rev-parse HEAD)
OLD=$(git -C "$T/repo" rev-parse HEAD~1)

printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_BOX=box-a\nJOBS_RETRIES=0\nJOBS_TIMEOUT=5\nJOBS_ALERT=0\n' \
  > "$H/env/global.env"
printf 'VERSION_URL=https://version.invalid/api/version\nDEPLOY_HOOK_URL=https://hook.invalid/deploy\nDEPLOY_ROLLBACK=off\n' \
  > "$H/env/p.env"

cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
echo "org/repo"
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$SINK_DIR/beat"
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$SINK_DIR/gh"; echo "https://github.com/org/repo/pull/1"
SH
# flock is Linux-only; the train's per-box slot lock is not what this suite is
# about — the CLAIM is the cross-box guard, and that is what is driven.
cat > "$T/fakebin/flock" <<'SH'
#!/bin/bash
exit 0
SH

# ── the fake worker, the version endpoint and the deploy hook, as one curl ────
# $DQ_STORE is the deploy_queue table as TSV:
#   project  sha  status  build_dir  claimed_by  enqueued_at  departed_at  reason  updated_at
# with `-` for NULL. It implements the four routes as the worker does: put is
# idempotent on (project, sha) and RE-OPENS a terminal row, list filters and
# orders by enqueued_at, claim takes only a `queued` row (or a `claimed` one
# older than stale_min that never departed), depart is refused unless `claimed`.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *hook.invalid*)    echo "hook" >> "$SINK_DIR/hook"; exit "${HOOK_RC:-0}" ;;
  *version.invalid*) printf '{"sha":"%s"}' "$(cat "$LIVE_FILE" 2>/dev/null)"; exit 0 ;;
esac
# Everything below is the jobs worker. CURL_MODE=down takes out THIS host only,
# so a train can be run with a dead worker and a live production endpoint.
[ "${CURL_MODE:-up}" = down ] && exit 7
NOWISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
row_json() {
  awk -F'\t' '
    function j(v) { return (v == "-") ? "null" : "\"" v "\"" }
    { printf "{\"project\":\"%s\",\"sha\":\"%s\",\"status\":\"%s\",\"build_dir\":%s,\"claimed_by\":%s,\"enqueued_at\":\"%s\",\"departed_at\":%s,\"reason\":%s,\"updated_at\":\"%s\"}",
        $1, $2, $3, j($4), j($5), $6, j($7), j($8), $9 }'
}
dq_get() { awk -F'\t' -v p="$1" -v s="$2" '$1==p && $2==s {print; exit}' "$DQ_STORE"; }
dq_del() {
  awk -F'\t' -v p="$1" -v s="$2" '!($1==p && $2==s)' "$DQ_STORE" > "$DQ_STORE.t" && mv "$DQ_STORE.t" "$DQ_STORE"
}
case "$M $URL" in
  "GET "*/api/settings/*)
    K="${URL##*/}"; V=absent
    [ "$K" = deploy_queue_rows ] && V="${FLAG_DQ:-0}"
    case "$V" in
      absent|none) printf '{}\n404\n' ;;
      *) printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "$V" ;;
    esac
    ;;
  "POST "*/api/deploy-queue/claim)
    if [ "${CLAIM_MODE:-}" = down-after-1 ]; then
      N=$(cat "$SINK_DIR/claimn" 2>/dev/null); N=$(( ${N:-0} + 1 )); echo "$N" > "$SINK_DIR/claimn"
      [ "$N" -gt 1 ] && exit 7
    fi
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    BOX=$(jq -r '.box // ""' <<<"$BODY"); SM=$(jq -r '.stale_min // 0' <<<"$BODY")
    case "$SM" in ''|*[!0-9]*) SM=0 ;; esac
    CUR=$(dq_get "$P" "$S")
    [ -n "$CUR" ] || { printf '{"error":"nothing queued"}\n404\n'; exit 0; }
    TAKE=no
    if [ "${CLAIM_MODE:-}" != lose ]; then
      [ "$(cut -f3 <<<"$CUR")" = queued ] && TAKE=yes
      if [ "$(cut -f3 <<<"$CUR")" = claimed ] && [ "$(cut -f7 <<<"$CUR")" = "-" ] && [ "$SM" -gt 0 ]; then
        U=$(date -u -d "$(cut -f9 <<<"$CUR")" +%s 2>/dev/null); U="${U:-0}"
        [ $(( $(date +%s) - U )) -ge $(( SM * 60 )) ] && TAKE=yes
      fi
    fi
    if [ "$TAKE" = yes ]; then
      NEW=$(awk -F'\t' -v OFS='\t' -v b="$BOX" -v n="$NOWISO" '{ $3="claimed"; $5=b; $9=n; print }' <<<"$CUR")
      dq_del "$P" "$S"; printf '%s\n' "$NEW" >> "$DQ_STORE"
      printf '{"deploy":%s,"claimed":true,"as_of":"%s"}\n200\n' "$(row_json <<<"$NEW")" "$NOWISO"
    else
      printf '{"error":"another claimant took this departure","refused":true,"scope":"deploy-queue","deploy":%s}\n409\n' \
        "$(row_json <<<"$CUR")"
    fi
    ;;
  "POST "*/api/deploy-queue/depart)
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    ST=$(jq -r '.status // ""' <<<"$BODY"); R=$(jq -r '.reason // "-"' <<<"$BODY")
    case "$ST" in done|failed|queued) ;; *) printf '{"error":"bad status"}\n400\n'; exit 0 ;; esac
    CUR=$(dq_get "$P" "$S")
    [ -n "$CUR" ] || { printf '{"error":"nothing queued"}\n404\n'; exit 0; }
    if [ "$(cut -f3 <<<"$CUR")" != claimed ]; then
      printf '{"error":"departure refused: row is %s, not claimed","refused":true,"deploy":%s}\n409\n' \
        "$(cut -f3 <<<"$CUR")" "$(row_json <<<"$CUR")"
      exit 0
    fi
    NEW=$(awk -F'\t' -v OFS='\t' -v s="$ST" -v r="$R" -v n="$NOWISO" \
      '{ $3=s; if (s=="queued") { $5="-"; $7="-" } else { $7=n }; $8=r; $9=n; print }' <<<"$CUR")
    dq_del "$P" "$S"; printf '%s\n' "$NEW" >> "$DQ_STORE"
    printf '{"deploy":%s,"as_of":"%s"}\n200\n' "$(row_json <<<"$NEW")" "$NOWISO"
    ;;
  "POST "*/api/deploy-queue)
    P=$(jq -r '.project // ""' <<<"$BODY"); S=$(jq -r '.sha // ""' <<<"$BODY")
    B=$(jq -r '.build_dir // "-"' <<<"$BODY")
    [[ "$S" =~ ^[0-9a-f]{7,64}$ ]] || { printf '{"error":"bad sha"}\n400\n'; exit 0; }
    CUR=$(dq_get "$P" "$S")
    case "$(cut -f3 <<<"$CUR")" in
      queued|claimed) printf '{"deploy":%s,"duplicate":true}\n200\n' "$(row_json <<<"$CUR")"; exit 0 ;;
    esac
    [ "$B" = "-" ] && [ -n "$CUR" ] && B=$(cut -f4 <<<"$CUR")
    [ -n "$CUR" ] && dq_del "$P" "$S"
    printf '%s\t%s\tqueued\t%s\t-\t%s\t-\t-\t%s\n' "$P" "$S" "$B" "$NOWISO" "$NOWISO" >> "$DQ_STORE"
    printf '{"deploy":{"project":"%s","sha":"%s","status":"queued"},"duplicate":false,"as_of":"%s"}\n201\n' \
      "$P" "$S" "$NOWISO"
    ;;
  "GET "*/api/deploy-queue*)
    P=""; case "$URL" in *project=*) P="${URL##*project=}"; P="${P%%&*}" ;; esac
    ST=""; case "$URL" in *status=*) ST="${URL##*status=}"; ST="${ST%%&*}" ;; esac
    SM=0;  case "$URL" in *stale_min=*) SM="${URL##*stale_min=}"; SM="${SM%%&*}" ;; esac
    case "$SM" in ''|*[!0-9]*) SM=0 ;; esac
    sort -t"$(printf '\t')" -k6,6 -k2,2 "$DQ_STORE" | awk -F'\t' -v p="$P" -v st="$ST" -v sm="$SM" -v now="$(date +%s)" '
      function j(v) { return (v == "-") ? "null" : "\"" v "\"" }
      BEGIN { printf "{\"deploy_queue\":[" }
      (p == "" || $1 == p) && (st == "" || $3 == st) {
        if (sm + 0 > 0) {
          if ($3 != "claimed" || $7 != "-") next
          cmd = "date -u -d \"" $9 "\" +%s"; u = 0; cmd | getline u; close(cmd)
          if (now - u < sm * 60) next
        }
        if (n++) printf ","
        printf "{\"project\":\"%s\",\"sha\":\"%s\",\"status\":\"%s\",\"build_dir\":%s,\"claimed_by\":%s,\"enqueued_at\":\"%s\",\"departed_at\":%s,\"reason\":%s,\"updated_at\":\"%s\"}",
          $1, $2, $3, j($4), j($5), $6, j($7), j($8), $9
      }
      END { print "]}" }'
    echo 200
    ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/"* "$H/bin/"*.sh

DQ_STORE="$T/dq.tsv"; : > "$DQ_STORE"
DQDIR="$H/state/deploy-queue/p"
SINK="$T/req.txt"
: > "$T/live"

# env <snippet> — one call in a clean subshell with the fixture wired up. The
# knobs come from the CALLER's environment so a case reads as one line:
#   FLAG_DQ=1 CURL_MODE=down lib '…'
run() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           JOBS_ALERT=0 REQ_SINK="$SINK" DQ_STORE="$DQ_STORE" SINK_DIR="$T/calls" \
           LIVE_FILE="$T/live" CURL_MODE="${CURL_MODE:-up}" FLAG_DQ="${FLAG_DQ:-0}" \
           CLAIM_MODE="${CLAIM_MODE:-}" HOOK_RC="${HOOK_RC:-0}"
    bash -c "$1" ) 2>/dev/null
}
CLIENT='. "$HARNESS/bin/jobs-client.sh" || exit 1'
lib() { run "$CLIENT
$1"; }

# train — one real departure, with the fixture's knobs in the environment.
train() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" \
           REQ_SINK="$SINK" DQ_STORE="$DQ_STORE" SINK_DIR="$T/calls" LIVE_FILE="$T/live" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_DQ="${FLAG_DQ:-0}" CLAIM_MODE="${CLAIM_MODE:-}" \
           HOOK_RC="${HOOK_RC:-0}" TRAIN_POLLS=2 TRAIN_POLL_SECS=0 \
           DEPLOY_TRAIN_REPO_DIR="$T/repo" \
           DEPLOY_CLAIM_STALE_MIN="${DEPLOY_CLAIM_STALE_MIN:-30}"
    "$DIR/bin/deploy-train.sh" p ) 2>/dev/null
}
# request — one real bin/deploy-request.sh, the production entry point every
# merge path calls after a verified merge.
request() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" \
           REQ_SINK="$SINK" DQ_STORE="$DQ_STORE" SINK_DIR="$T/calls" LIVE_FILE="$T/live" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_DQ="${FLAG_DQ:-0}" \
           DEPLOY_QUEUE_ROWS="${DEPLOY_QUEUE_ROWS:-}"
    "$DIR/bin/deploy-request.sh" p org/repo "$1" "${2:-$T/builds/b1}" ) 2>/dev/null
}

reset_tick() { : > "$SINK"; rm -f "$T/calls/hook" "$T/calls/beat" "$T/calls/gh" "$T/calls/claimn"; }
# TEST-CHANGE: BH-3154 — a knob-on train now leaves state/deploy-hold-armed/<p>,
# and an armed box keeps reading the held list with the knob off (so a hold is
# never dropped silently). reset_all is a fresh box, so it clears that marker
# like every other piece of box state; §7 stays "a box that never saw the knob
# on", and tests/deploy-train-hold.bh-3154-test.sh §10 drives the armed case.
reset_all()  { reset_tick; : > "$DQ_STORE"; rm -f "$DQDIR"/* "$H/logs/"*.log; scratch_rm "$H/state/deploy-hold-armed"; }
rows_n()  { awk 'END{print NR+0}' "$DQ_STORE"; }
field()   { awk -F'\t' -v s="$2" -v c="$3" '$2==s {print $c; exit}' "$DQ_STORE"; }
files_n() { ls -A "$DQDIR" 2>/dev/null | awk 'END{print NR+0}'; }
# grep -c, never grep -q, on a pipe: a short-circuiting consumer turns a true
# assertion red under pipefail.
sink_n()  { grep -cF "$1" "$SINK"; }
line_of() { grep -nF "$1" "$SINK" | head -1 | cut -d: -f1; }

# ══ 1. THE FAIL-OPEN CONTRACT: a dead worker is rc 1 and SILENCE ════════════
# Not one of these may print a payload, a stack trace or an empty success. The
# train reads an empty batch as "nothing queued", so a helper that printed on a
# failure is a deploy that never departs and never alerts.
for CALL in "deploy_queue_put p $TARGET /b" "deploy_queue_list p queued" \
            "deploy_queue_claim p $TARGET" "deploy_queue_depart p $TARGET done x"; do
  OUT=$(CURL_MODE=down lib "$CALL; echo \"rc=\$?\"")
  [ "$OUT" = "rc=1" ] \
    && ok || bad "1 '$CALL' on a dead worker must be rc 1 with empty stdout, got: $(printf '%s' "$OUT" | cat -A)"
done

# ══ 2. THE FOUR HELPERS AGAINST A LIVE WORKER ══════════════════════════════
reset_all
[ "$(lib "deploy_queue_put p $TARGET /b")" = queued ] && ok || bad "2 a first put must print 'queued'"
[ "$(lib "deploy_queue_put p $TARGET /b")" = duplicate ] && ok || bad "2 a second put must print 'duplicate'"
[ "$(rows_n)" = 1 ] && ok || bad "2 a repeat request for one sha must be ONE row, got $(rows_n)"
lib "deploy_queue_put p $OLD /b2" >/dev/null

OUT=$(lib "deploy_queue_list p queued")
[ "$(printf '%s\n' "$OUT" | awk 'END{print NR}')" = 2 ] \
  && ok || bad "2 the list must print one line per queued row, got: $OUT"
[ "$(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print NF}')" = 8 ] \
  && ok || bad "2 the list TSV must be 8 fields, got $(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print NF}')"

OUT=$(lib "deploy_queue_claim p $TARGET")
[ "$OUT" = "$TARGET${TAB}box-a" ] \
  && ok || bad "2 a claim must print sha<TAB>claimed_by, got: $(printf '%s' "$OUT" | cat -A)"
OUT=$(lib "deploy_queue_claim p $TARGET; echo \"rc=\$?\"")
[ "$OUT" = "rc=9" ] \
  && ok || bad "2 a lost claim is rc 9 with EMPTY stdout (never the 409 payload), got: $(printf '%s' "$OUT" | cat -A)"
OUT=$(lib "deploy_queue_claim p ffffffffffffffffffffffffffffffffffffffff; echo \"rc=\$?\"")
[ "$OUT" = "rc=2" ] \
  && ok || bad "2 a sha with no row is rc 2 — a real answer, not an outage, got: $(printf '%s' "$OUT" | cat -A)"

OUT=$(lib "deploy_queue_depart p $OLD done x; echo \"rc=\$?\"")
[ "$OUT" = "rc=9" ] && ok || bad "2 departing an UNCLAIMED row must be refused rc 9, got: $OUT"
[ "$(field p "$OLD" 7)" = "-" ] && ok || bad "2 a refused departure must not stamp departed_at"

OUT=$(lib "deploy_queue_depart p $TARGET done 'VERIFIED live at deadbeef (batch of 2)'")
[ "$OUT" = done ] && ok || bad "2 a departure must print the status it wrote, got: $OUT"
[ "$(field p "$TARGET" 7)" != "-" ] && ok || bad "2 departed_at must be stamped on a real departure"
[ "$(field p "$TARGET" 5)" = box-a ] && ok || bad "2 a terminal row keeps the box that ran the departure"

# the REASON is the last TSV field and survives its own spaces as ONE field.
OUT=$(lib "deploy_queue_list p done")
[ "$(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print $8}')" = "VERIFIED live at deadbeef (batch of 2)" ] \
  && ok || bad "2 the reason is field 8 and keeps its spaces, got: $(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print $8}')"

# the release: claimed → queued, claimant and departed_at cleared.
lib "deploy_queue_claim p $OLD" >/dev/null
[ "$(lib "deploy_queue_depart p $OLD queued 'production still not serving deadbeef'")" = queued ] \
  && ok || bad "2 a release must print 'queued'"
[ "$(field p "$OLD" 5)" = "-" ] && [ "$(field p "$OLD" 7)" = "-" ] \
  && ok || bad "2 a released row carries no claimant and no departed_at"

# the four dispatch verbs, through the REAL bin/jobs-client.sh entry point.
OUT=$(run "\"\$HARNESS/bin/jobs-client.sh\" deploy-list p queued")
[ "$(printf '%s\n' "$OUT" | grep -cF "$OLD")" = 1 ] \
  && ok || bad "2 jobs-client.sh deploy-list must print the queued row, got: $OUT"
OUT=$(run "\"\$HARNESS/bin/jobs-client.sh\" deploy-put p $TARGET /b3; echo \"rc=\$?\"")
[ "$(printf '%s\n' "$OUT" | grep -c '^rc=0$')" = 1 ] \
  && ok || bad "2 jobs-client.sh deploy-put must exit 0, got: $OUT"
OUT=$(run "\"\$HARNESS/bin/jobs-client.sh\" deploy-claim p $TARGET" 2>/dev/null)
[ "$OUT" = "$TARGET${TAB}box-a" ] && ok || bad "2 jobs-client.sh deploy-claim, got: $(printf '%s' "$OUT" | cat -A)"
OUT=$(run "\"\$HARNESS/bin/jobs-client.sh\" deploy-depart p $TARGET failed 'nope'")
[ "$OUT" = failed ] && ok || bad "2 jobs-client.sh deploy-depart, got: $OUT"
OUT=$(( ( PATH="$T/fakebin:$PATH" HARNESS="$H" "$H/bin/jobs-client.sh" deploy-frob ) 2>&1 >/dev/null ); echo "rc=$?")
[ "$(printf '%s\n' "$OUT" | grep -c 'deploy-depart <project> <sha>')" = 1 ] \
  && ok || bad "2 the usage string must name the four new verbs, got: $OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^rc=2$')" = 1 ] \
  && ok || bad "2 an unknown verb must still exit 2, got: $OUT"

# ══ 3. THE REQUEST: the row FIRST, then the file — and the file ALWAYS ══════
reset_all
FLAG_DQ=1 request "$TARGET"; RC=$?
[ "$RC" = 0 ] && ok || bad "3 deploy-request.sh must exit 0 (rc=$RC)"
[ "$(rows_n)" = 1 ] && ok || bad "3 flag on must write one deploy_queue row, got $(rows_n)"
[ "$(files_n)" = 1 ] && ok || bad "3 the file is written in EVERY mode, got $(files_n) files"
# The ROW is written BEFORE the file: a crash between the two must lose the
# file, which the train re-adopts, never the row nothing would ever re-create.
[ "$(field p "$TARGET" 4)" = "$T/builds/b1" ] \
  && ok || bad "3 the row must carry the build dir the request named"

# A DEAD WORKER RESOLVES THE FLAG OFF (the settings read fails, the documented
# env fallback is 0) — so this is the unarmed path: file, rc 0, silence.
reset_all
CURL_MODE=down FLAG_DQ=1 request "$TARGET"; RC=$?
[ "$RC" = 0 ] && ok || bad "3 a dead worker must not fail the request (rc=$RC)"
[ "$(rows_n)" = 0 ] && ok || bad "3 a dead worker writes no row"
[ "$(files_n)" = 1 ] && ok || bad "3 a dead worker still writes the file — that is the whole fallback"
[ ! -f "$H/logs/deploy-train.log" ] \
  && ok || bad "3 an unarmed lane says nothing, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

# ARMED THROUGH THE ENV FALLBACK (DEPLOY_QUEUE_ROWS=1 in env/global.env is the
# only way a lane is on while the worker is down) and the put therefore FAILS:
# one log line, and the file is still written. That ordering is the contract —
# the row may be lost, the file may not.
reset_all
CURL_MODE=down DEPLOY_QUEUE_ROWS=1 request "$TARGET"; RC=$?
[ "$RC" = 0 ] && ok || bad "3 a failed row write must not fail the request (rc=$RC)"
[ "$(rows_n)" = 0 ] && ok || bad "3 the row really did not land"
[ "$(files_n)" = 1 ] && ok || bad "3 and the file is written anyway — never the reverse"
[ "$(grep -c 'deploy_queue row for' "$H/logs/deploy-train.log" 2>/dev/null)" = 1 ] \
  && ok || bad "3 a failed row write logs EXACTLY one line, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

# …and the same, with the worker UP and answering 400 (a sha the route refuses).
# A row write that fails against a live worker must look no different.
reset_all
FLAG_DQ=1 request "not-a-sha"; RC=$?
[ "$RC" = 0 ] && [ "$(rows_n)" = 0 ] && [ "$(files_n)" = 1 ] \
  && ok || bad "3 a 4xx on the row write still writes the file (rc=$RC rows=$(rows_n) files=$(files_n))"
[ "$(grep -c 'deploy_queue row for' "$H/logs/deploy-train.log" 2>/dev/null)" = 1 ] \
  && ok || bad "3 a 4xx logs one line too, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

reset_all
FLAG_DQ=0 request "$TARGET" >/dev/null
[ "$(files_n)" = 1 ] && ok || bad "3 flag off still writes the file"
[ "$(grep -c '/api/deploy-queue' "$SINK")" = 0 ] \
  && ok || bad "3 flag off must make NO deploy-queue request at all: $(cat "$SINK")"
[ ! -f "$H/logs/deploy-train.log" ] \
  && ok || bad "3 flag off is silent, got: $(cat "$H/logs/deploy-train.log" 2>/dev/null)"

# A box with no jobs-client.sh at all (the conductor fixtures and
# tests/deploy-verify-fallback-test.sh drive exactly this): file, rc 0, silence.
reset_all
mv "$H/bin/jobs-client.sh" "$T/jobs-client.sh.hidden"
FLAG_DQ=1 request "$TARGET"; RC=$?
mv "$T/jobs-client.sh.hidden" "$H/bin/jobs-client.sh"
[ "$RC" = 0 ] && [ "$(files_n)" = 1 ] && [ ! -f "$H/logs/deploy-train.log" ] \
  && ok || bad "3 no client on the box must be today byte for byte (rc=$RC files=$(files_n))"

# ══ 4. THE TRAIN, FLAG ON: claim every member BEFORE the hook fires ════════
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=1 request "$TARGET" >/dev/null
FLAG_DQ=1 request "$OLD" "$T/builds/b1" >/dev/null
reset_tick
FLAG_DQ=1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "4 a verified departure exits 0 (rc=$RC)"
C1=$(line_of "/api/deploy-queue/claim {\"project\":\"p\",\"sha\":\"$TARGET\"")
C2=$(line_of "/api/deploy-queue/claim {\"project\":\"p\",\"sha\":\"$OLD\"")
HK=$(line_of "hook.invalid")
[ -n "$C1" ] && [ -n "$C2" ] && [ -n "$HK" ] \
  && ok || bad "4 both claims and the hook must appear in the sink (c1=$C1 c2=$C2 hook=$HK)"
[ -n "$C1" ] && [ -n "$HK" ] && [ "$C1" -lt "$HK" ] && [ "$C2" -lt "$HK" ] \
  && ok || bad "4 EVERY member is claimed BEFORE the hook fires (c1=$C1 c2=$C2 hook=$HK)"
[ "$(grep -cF "/api/deploy-queue/claim {\"project\":\"p\",\"sha\":\"$TARGET\"" "$SINK")" = 1 ] \
  && ok || bad "4 each sha is claimed exactly once per tick"
[ "$(awk 'END{print NR+0}' "$T/calls/hook")" = 1 ] \
  && ok || bad "4 the hook fires once for the whole batch, got $(awk 'END{print NR+0}' "$T/calls/hook" 2>/dev/null)"
[ "$(field p "$TARGET" 3)" = done ] && [ "$(field p "$OLD" 3)" = done ] \
  && ok || bad "4 both rows must be done ($(field p "$TARGET" 3) / $(field p "$OLD" 3))"
[ "$(field p "$TARGET" 7)" != "-" ] \
  && ok || bad "4 departed_at is stamped after the verify returns"
[ "$(field p "$TARGET" 5)" = box-a ] \
  && ok || bad "4 a departed row keeps the box that ran it"
[ "$(files_n)" = 0 ] && ok || bad "4 the files of a departed batch are removed, got $(files_n)"
[ "$(grep -c 'train VERIFIED live at' "$H/logs/deploy-train.log")" = 1 ] \
  && ok || bad "4 the VERIFIED log line is unchanged"

# ══ 5. A SECOND TRAIN ON THE SAME TICK DEPARTS NOTHING ═════════════════════
# The per-box flock never guarded across boxes. The claim CAS does: every claim
# answers 409, so there is no batch, no hook, and nothing is departed.
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=1 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=1 CLAIM_MODE=lose train; RC=$?
[ "$RC" = 0 ] && ok || bad "5 a train that claims nothing still exits 0 (rc=$RC)"
[ ! -f "$T/calls/hook" ] \
  && ok || bad "5 ZERO hooks when every claim was lost, got: $(cat "$T/calls/hook" 2>/dev/null)"
[ "$(grep -c '/api/deploy-queue/depart' "$SINK")" = 0 ] \
  && ok || bad "5 a train that departed nothing must not stamp anything"
[ "$(grep -c 'claimed elsewhere' "$H/logs/deploy-train.log")" -ge 1 ] \
  && ok || bad "5 the log must say why it departed nothing, got: $(cat "$H/logs/deploy-train.log")"
[ "$(files_n)" = 1 ] && ok || bad "5 the files stay put — the other train owns them"
[ "$(field p "$TARGET" 3)" = queued ] && ok || bad "5 the row is untouched"

# ══ 6. A HOOK THAT NEVER ARRIVED RELEASES THE BATCH ════════════════════════
reset_all
printf '%s' "$OLD" > "$T/live"          # production is still serving the old sha
FLAG_DQ=1 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=1 HOOK_RC=22 train; RC=$?
[ "$RC" = 0 ] && ok || bad "6 a failed verify exits 0 (rc=$RC)"
[ "$(field p "$TARGET" 3)" = queued ] \
  && ok || bad "6 a failed verify RELEASES the row to queued, got '$(field p "$TARGET" 3)'"
[ "$(field p "$TARGET" 7)" = "-" ] && ok || bad "6 a released row has NOT departed"
[ "$(field p "$TARGET" 5)" = "-" ] \
  && ok || bad "6 a released row carries no claimant, or the next train reads it as in flight"
[ "$(files_n)" = 1 ] && ok || bad "6 the files stay queued exactly as they do today"
[ "$(grep -c 'DEPLOY TRAIN: production is NOT serving' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "6 the alert still fires: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
# …and the NEXT tick picks the same sha up EXACTLY ONCE and departs it.
printf '%s' "$TARGET" > "$T/live"
reset_tick
FLAG_DQ=1 train
[ "$(grep -cF "/api/deploy-queue/claim {\"project\":\"p\",\"sha\":\"$TARGET\"" "$SINK")" = 1 ] \
  && ok || bad "6 the next tick claims the released sha exactly once"
[ "$(field p "$TARGET" 3)" = done ] && ok || bad "6 and departs it done"
[ "$(files_n)" = 0 ] && ok || bad "6 and clears its file"

# ══ 7. FLAG OFF IS TODAY, BYTE FOR BYTE ════════════════════════════════════
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=0 request "$TARGET" >/dev/null
reset_tick
FLAG_DQ=0 train; RC=$?
[ "$RC" = 0 ] && ok || bad "7 flag off exits 0 (rc=$RC)"
[ "$(files_n)" = 0 ] && ok || bad "7 the ls -tr batch departs and its files are removed"
[ "$(grep -c '/api/deploy-queue' "$SINK")" = 0 ] \
  && ok || bad "7 flag off must make ZERO deploy-queue requests: $(grep '/api/deploy-queue' "$SINK")"
[ "$(awk 'END{print NR+0}' "$T/calls/hook")" = 1 ] && ok || bad "7 the hook still fires once"

# ══ 8. A DEAD WORKER WITH THE FLAG ON IS FLAG-OFF ══════════════════════════
# "The worker did not answer" is never "nothing queued" (D9/D11). The files are
# there, and they depart exactly as in §7.
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=0 request "$TARGET" >/dev/null       # a file, deliberately with no row
reset_tick
CURL_MODE=down FLAG_DQ=1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "8 a dead worker exits 0 (rc=$RC)"
[ "$(files_n)" = 0 ] && ok || bad "8 the file batch must still depart, got $(files_n) left"
[ "$(rows_n)" = 0 ] && ok || bad "8 nothing was written to the table"
[ "$(awk 'END{print NR+0}' "$T/calls/hook")" = 1 ] && ok || bad "8 the hook fires as it does today"

# ══ 9. A CLAIM THAT WENT QUIET IS RE-OFFERED; A LIVE ONE IS NOT ════════════
reset_all
printf '%s' "$TARGET" > "$T/live"
STALE_ISO=$(date -u -d "@$((NOW - 2700))" '+%Y-%m-%dT%H:%M:%SZ')
FRESH_ISO=$(date -u -d "@$((NOW - 300))"  '+%Y-%m-%dT%H:%M:%SZ')
printf 'p\t%s\tclaimed\t/b\tdead-box\t%s\t-\t-\t%s\n' "$TARGET" "$STALE_ISO" "$STALE_ISO" >> "$DQ_STORE"
printf 'p\t%s\tclaimed\t/b\tlive-box\t%s\t-\t-\t%s\n' "$OLD" "$FRESH_ISO" "$FRESH_ISO" >> "$DQ_STORE"
reset_tick
FLAG_DQ=1 DEPLOY_CLAIM_STALE_MIN=30 train
[ "$(grep -cF "\"sha\":\"$TARGET\",\"box\":\"box-a\",\"stale_min\":30" "$SINK")" = 1 ] \
  && ok || bad "9 a 45-minute-old claim is re-offered with stale_min in the body: $(grep claim "$SINK")"
[ "$(field p "$TARGET" 3)" = done ] && ok || bad "9 and it departs"
[ "$(grep -cF "/api/deploy-queue/claim {\"project\":\"p\",\"sha\":\"$OLD\"" "$SINK")" = 0 ] \
  && ok || bad "9 a 5-minute-old claim is a LIVE train and must not even be asked for"
[ "$(field p "$OLD" 5)" = live-box ] && ok || bad "9 and it keeps its claimant"

# DEPLOY_CLAIM_STALE_MIN=0 turns the age re-offer OFF entirely.
reset_all
printf '%s' "$TARGET" > "$T/live"
printf 'p\t%s\tclaimed\t/b\tdead-box\t%s\t-\t-\t%s\n' "$TARGET" "$STALE_ISO" "$STALE_ISO" >> "$DQ_STORE"
reset_tick
FLAG_DQ=1 DEPLOY_CLAIM_STALE_MIN=0 train
[ "$(grep -c 'stale_min' "$SINK")" = 0 ] \
  && ok || bad "9 at 0 no request may carry stale_min: $(grep stale_min "$SINK")"
[ "$(grep -c 'status=claimed' "$SINK")" = 0 ] \
  && ok || bad "9 at 0 the second list is not made at all: $(grep 'status=claimed' "$SINK")"
[ "$(field p "$TARGET" 3)" = claimed ] \
  && ok || bad "9 at 0 a stranded claim stays stranded (that is what off means)"

# ══ 10. A WORKER THAT DIES MID-CLAIM DEPARTS NOTHING (D12) ═════════════════
# Half a batch is not a batch: what was already claimed is released, one line
# says so, and no hook fires.
reset_all
printf '%s' "$TARGET" > "$T/live"
FLAG_DQ=1 request "$TARGET" >/dev/null
FLAG_DQ=1 request "$OLD" >/dev/null
reset_tick
FLAG_DQ=1 CLAIM_MODE=down-after-1 train; RC=$?
[ "$RC" = 0 ] && ok || bad "10 a mid-claim outage exits 0 (rc=$RC)"
[ ! -f "$T/calls/hook" ] \
  && ok || bad "10 no hook may fire on a half-claimed batch: $(cat "$T/calls/hook" 2>/dev/null)"
[ "$(grep -c '/api/deploy-queue/depart' "$SINK")" -ge 1 ] \
  && ok || bad "10 the shas already claimed must be released back: $(cat "$SINK")"
[ "$(grep -c 'mid-claim' "$H/logs/deploy-train.log")" -ge 1 ] \
  && ok || bad "10 the log must name the outage: $(cat "$H/logs/deploy-train.log")"
[ "$(files_n)" = 2 ] && ok || bad "10 the files stay queued, got $(files_n)"

# ══ 11. A FILE WITH NO ROW IS ADOPTED, NOT ORPHANED ════════════════════════
# The request in §3 that met a dead worker left a file and no row. Once the
# worker is back, a rows-mode train reads rows — so without adoption that
# deploy would wait for somebody to turn the knob back off.
reset_all
printf '%s' "$TARGET" > "$T/live"
CURL_MODE=down FLAG_DQ=1 request "$TARGET" >/dev/null
[ "$(rows_n)" = 0 ] && [ "$(files_n)" = 1 ] \
  && ok || bad "11 the fixture needs a file with no row (rows=$(rows_n) files=$(files_n))"
reset_tick
FLAG_DQ=1 train
[ "$(grep -cF "POST https://jobs.invalid/api/deploy-queue {\"project\":\"p\",\"sha\":\"$TARGET\"" "$SINK")" -ge 1 ] \
  && ok || bad "11 the orphan file must be adopted as a row: $(cat "$SINK")"
[ "$(field p "$TARGET" 3)" = done ] && ok || bad "11 and depart, got '$(field p "$TARGET" 3)'"
[ "$(files_n)" = 0 ] && ok || bad "11 and its file is removed"

echo "deploy-queue-rows.bh-1026-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
