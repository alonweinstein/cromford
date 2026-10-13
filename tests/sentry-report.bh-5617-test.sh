#!/bin/bash
# tests/sentry-report.bh-5617-test.sh — BH-5617 (BH-5611.1): the bash Sentry
# reporter bin/lib/sentry-report.sh and the three lanes that failed silently.
#
# sentry_report <level> <lane> <reason> <message> [extra-json] posts one event
# to the Sentry envelope endpoint of HARNESS_SENTRY_DSN. A per-fingerprint
# ledger ([lane, project, reason], SENTRY_MAX_PER_FP_HOUR a rolling hour) runs
# BEFORE the send. It always returns 0 and prints nothing.
#
# The network is a fake curl ($T/bin/curl, through HARNESS_SENTRY_CURL): it
# keeps its argv, the `-K -` config it read on stdin and the --data-binary
# body, writes $FAKE_BODY to the -o file, prints $FAKE_CODE for -w and exits
# $FAKE_RC.
#
# S1 no DSN       S2 envelope      S3 cap          S3b registry knob
# S4 500/timeout  S5 kill switch   S6 call sites   S6b quiet output
# S7 leak check   S8 secret shape
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/sentry-report.bh-5617-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/sentry-report.sh"
LG="$DIR/bin/lib/lane-gate.sh"
# The key carries the word "fixture" (D47) and is not 32 hex, so the leak
# pattern this ticket adds never matches it.
FKEY=fixture0123public
FDSN="https://$FKEY@sentry.example.test/42"
FSHA=$(printf 'bh-5617 fixture head' | sha1sum | cut -c1-40)

export HARNESS="$T/h"
mkdir -p "$HARNESS/state" "$HARNESS/logs" "$HARNESS/flags" "$HARNESS/tmp" "$T/bin" "$T/co/.git"
printf '%s\n' "$FSHA" > "$T/co/.git/HEAD"
export HARNESS_CHECKOUT="$T/co" JOBS_BOX=box-t SENTRY_REPORT_NOW=1760000000
export HARNESS_SENTRY_CURL="$T/bin/curl" LANE_GATE_CACHE_S=0 SENTRY_MAX_PER_FP_HOUR=6
SRLOG="$HARNESS/logs/sentry-report.log"

reg() { # reg <file> <default> — a registry holding only the sentry-report lib
  jq -n --argjson d "$2" '{lanes: [], libs: [{id: "sentry-report", file: "bin/lib/sentry-report.sh",
    knobs: [{env: "SENTRY_MAX_PER_FP_HOUR", type: "int", default: $d, min: 0, max: 60,
             required: true, settable: true, zero_means: "off"}]}]}' > "$1"
}
reg "$T/reg6.json" 6; reg "$T/reg2.json" 2
export LANE_REGISTRY="$T/reg6.json"

cat > "$T/bin/curl" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/curl.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/curl.n"
printf '%s\n' "\$*" >> "$T/curl.calls"
cat > "$T/cfg.\$n"
out=""; body=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; --data-binary) body="\${2#@}"; shift ;; esac
  shift
done
[ -n "\$body" ] && cp "\$body" "$T/body.\$n"
[ -n "\$out" ] && printf '%s' "\${FAKE_BODY:-}" > "\$out"
if [ "\${FAKE_RC:-0}" != 0 ]; then printf '000'; exit "\$FAKE_RC"; fi
printf '%s' "\${FAKE_CODE:-200}"
EOF
chmod +x "$T/bin/curl"

reset() {
  scratch_rm "$HARNESS/state/sentry-report"; scratch_rm "$HARNESS/state/lane-gate"
  rm -f "$T"/cfg.* "$T"/body.* "$T/curl.calls" "$T/curl.n" "$HARNESS/flags/lane-off-sentry-report"
  : > "$SRLOG"
}
calls() { if [ -f "$T/curl.n" ]; then cat "$T/curl.n"; else echo 0; fi; }

[ -r "$LIB" ] || bad "bin/lib/sentry-report.sh does not exist"
# shellcheck source=/dev/null
. "$LG" 2>/dev/null || bad "lane-gate.sh did not source"
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null
command -v sentry_report >/dev/null 2>&1 || { bad "sentry_report is not defined"; sentry_report() { return 0; }; }

# ---- S1 no DSN --------------------------------------------------------------
reset; unset HARNESS_SENTRY_DSN
sentry_report error lane-x reason-x "m"; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 rc=$rc"
[ ! -e "$T/curl.calls" ] && ok || bad "S1 curl ran with no DSN"
[ -z "$(ls "$HARNESS/state/sentry-report/"*.sends 2>/dev/null)" ] && ok || bad "S1 a .sends ledger was written"
export HARNESS_SENTRY_DSN="$FDSN"

# ---- S2 well-formed envelope -------------------------------------------------
reset
sentry_report error lane-x reason-x 'boom "quoted"' '{"project":"proj-a","pr":"o/r#1"}'; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 rc=$rc"
[ "$(calls)" = 1 ] && ok || bad "S2 want 1 curl call, got $(calls)"
grep -q 'url = "https://sentry.example.test/api/42/envelope/"' "$T/cfg.1" 2>/dev/null && ok || bad "S2 config url: $(cat "$T/cfg.1" 2>/dev/null)"
grep -q "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$FKEY," "$T/cfg.1" 2>/dev/null && ok || bad "S2 auth header missing from the config"
! grep -q "$FKEY" "$T/curl.calls" 2>/dev/null && ok || bad "S2 the DSN key is on curl argv"
grep -q -- '--max-time 5' "$T/curl.calls" 2>/dev/null && ok || bad "S2 curl not bounded by --max-time 5"
[ "$(wc -l < "$T/body.1" 2>/dev/null)" = 3 ] && ok || bad "S2 the envelope is not 3 lines"
for i in 1 2 3; do
  sed -n "${i}p" "$T/body.1" 2>/dev/null | jq -e . >/dev/null 2>&1 && ok || bad "S2 envelope line $i does not parse"
done
L1=$(sed -n 1p "$T/body.1" 2>/dev/null); L2=$(sed -n 2p "$T/body.1" 2>/dev/null); L3=$(sed -n 3p "$T/body.1" 2>/dev/null)
jq -e '.event_id | test("^[0-9a-f]{32}$")' <<<"$L1" >/dev/null 2>&1 && ok || bad "S2 header event_id: $L1"
jq -e 'has("dsn") | not' <<<"$L1" >/dev/null 2>&1 && ok || bad "S2 the envelope header carries the dsn"
jq -e '.type == "event"' <<<"$L2" >/dev/null 2>&1 && ok || bad "S2 item header: $L2"
jq -e '.fingerprint == ["lane-x","proj-a","reason-x"]' <<<"$L3" >/dev/null 2>&1 && ok || bad "S2 fingerprint: $(jq -c .fingerprint <<<"$L3" 2>/dev/null)"
jq -e --arg s "$FSHA" '.tags == {lane:"lane-x", project:"proj-a", box:"box-t", harness_sha:$s, reason:"reason-x"}' <<<"$L3" >/dev/null 2>&1 \
  && ok || bad "S2 tags: $(jq -c .tags <<<"$L3" 2>/dev/null)"
jq -e '.level == "error" and .logger == "lane-x" and .message.formatted == "boom \"quoted\"" and .extra.pr == "o/r#1"' <<<"$L3" >/dev/null 2>&1 \
  && ok || bad "S2 event fields: $L3"
jq -e '.event_id' <<<"$L3" >/dev/null 2>&1 && [ "$(jq -r .event_id <<<"$L1")" = "$(jq -r .event_id <<<"$L3")" ] && ok || bad "S2 event_id differs between header and event"
! grep -q "$FKEY" "$T/body.1" 2>/dev/null && ok || bad "S2 the DSN key is in the envelope body"
jq -e '.level == "error"' <<<"$(sentry_report bogus lane-x reason-lv m; sed -n 3p "$T/body.2" 2>/dev/null)" >/dev/null 2>&1 \
  && ok || bad "S2 an unknown level did not become error"
# Invalid extra is kept, never dropped.
reset
sentry_report warning lane-x reason-x m 'not-json'
[ "$(calls)" = 1 ] && ok || bad "S2 invalid extra: want 1 send, got $(calls)"
jq -e '.extra.extra_raw == "not-json" and .level == "warning"' <<<"$(sed -n 3p "$T/body.1" 2>/dev/null)" >/dev/null 2>&1 \
  && ok || bad "S2 invalid extra not kept as extra_raw"
# Project falls back to $PROJECT, then '-'.
reset
PROJECT=proj-env sentry_report error lane-x reason-x m
jq -e '.fingerprint == ["lane-x","proj-env","reason-x"]' <<<"$(sed -n 3p "$T/body.1" 2>/dev/null)" >/dev/null 2>&1 \
  && ok || bad "S2 project did not fall back to PROJECT"

# ---- S3 cap -------------------------------------------------------------------
reset
for i in 1 2 3 4 5 6 7; do sentry_report error lane-x reason-x "m$i" '{"project":"proj-a"}' || bad "S3 call $i rc"; done
[ "$(calls)" = 6 ] && ok || bad "S3 want 6 sends of 7, got $(calls)"
[ "$(grep -c ' capped' "$SRLOG")" = 1 ] && ok || bad "S3 want one capped line, log: $(cat "$SRLOG")"
sentry_report error lane-x reason-x m8 '{"project":"proj-a"}'
[ "$(grep -c ' capped' "$SRLOG")" = 1 ] && ok || bad "S3 a second capped line in the same hour"
sentry_report error lane-x reason-y m '{"project":"proj-a"}'
[ "$(calls)" = 7 ] && ok || bad "S3 a different reason (fingerprint) did not send"
sentry_report error lane-x reason-x m '{"project":"proj-b"}'
[ "$(calls)" = 8 ] && ok || bad "S3 a different project (fingerprint) did not send"
sentry_report error lane-x reason-x m '{"project":"proj-a","pr":"o/r#9","head":"abc"}'
[ "$(calls)" = 8 ] && ok || bad "S3 a different PR/head made a new fingerprint"
SENTRY_REPORT_NOW=$((1760000000 + 3601)) sentry_report error lane-x reason-x m '{"project":"proj-a"}'
[ "$(calls)" = 9 ] && ok || bad "S3 the hour rolled and it still did not send"
reset
SENTRY_MAX_PER_FP_HOUR=0 sentry_report error lane-x reason-x m
[ "$(calls)" = 0 ] && ok || bad "S3 SENTRY_MAX_PER_FP_HOUR=0 still sent"
# A send that fails still counts (write -> send): no unbounded retries.
reset
for i in 1 2 3 4 5 6 7; do FAKE_CODE=500 sentry_report error lane-x reason-x m; done
[ "$(calls)" = 6 ] && ok || bad "S3 failed sends were not counted, got $(calls)"

# ---- S3b the cap resolves from the registry -----------------------------------
reset
( unset SENTRY_MAX_PER_FP_HOUR; export LANE_REGISTRY="$T/reg2.json"
  for i in 1 2 3; do sentry_report error lane-x reason-x m; done )
[ "$(calls)" = 2 ] && ok || bad "S3b registry default 2: want 2 sends, got $(calls)"
reset
( unset SENTRY_MAX_PER_FP_HOUR; export LANE_REGISTRY="$T/empty-reg.json"; echo '{"lanes":[],"libs":[]}' > "$LANE_REGISTRY"
  sentry_report error lane-x reason-x m )
[ "$(calls)" = 0 ] && ok || bad "S3b no cap anywhere still sent"
grep -q 'cap-unresolved' "$SRLOG" && ok || bad "S3b no cap-unresolved line"

# ---- S4 a stub 500, a timeout, set -euo pipefail -------------------------------
reset
FAKE_CODE=500 FAKE_BODY='{"detail":"bad envelope xyz"}' sentry_report error lane-x reason-x m; rc=$?
[ "$rc" = 0 ] && ok || bad "S4 rc=$rc on a 500"
[ "$(grep -c '500' "$SRLOG")" = 1 ] && grep -q 'bad envelope xyz' "$SRLOG" && ok || bad "S4 the 500 body was not logged: $(cat "$SRLOG")"
reset
FAKE_RC=28 sentry_report error lane-x reason-x m; rc=$?
[ "$rc" = 0 ] && ok || bad "S4 rc=$rc on a timeout"
[ "$(grep -c 'curl_rc=28' "$SRLOG")" = 1 ] && ok || bad "S4 the timeout was not logged once: $(cat "$SRLOG")"
reset
OUT=$(FAKE_CODE=503 bash -c 'set -euo pipefail; . "$1"; sentry_report error lane-x reason-x m "{}"; echo after' _ "$LIB" 2>&1)
[ "$OUT" = after ] && ok || bad "S4 caller under set -euo pipefail did not survive: $OUT"
OUT=$(bash -c 'set -euo pipefail; . "$1"; HARNESS_SENTRY_DSN=nope://x sentry_report error lane-x reason-x m; echo after' _ "$LIB" 2>&1)
[ "$OUT" = after ] && ok || bad "S4 malformed DSN under set -e: $OUT"
grep -q 'dsn-malformed' "$SRLOG" && ok || bad "S4 a malformed DSN logged nothing"
! grep -q "$FKEY" "$SRLOG" && ok || bad "S4 the log carries the DSN key"

# ---- S5 kill switch -------------------------------------------------------------
reset
touch "$HARNESS/flags/lane-off-sentry-report"
LANE_PAUSED_WHY=caller-value
sentry_report error lane-x reason-x m
[ "$(calls)" = 0 ] && ok || bad "S5a paused (lane-gate sourced) still sent"
[ "$LANE_PAUSED_WHY" = caller-value ] && ok || bad "S5a the caller's LANE_PAUSED_WHY changed: $LANE_PAUSED_WHY"
[ -z "$(ls "$HARNESS/state/sentry-report/"*.sends 2>/dev/null)" ] && ok || bad "S5a a paused call wrote the ledger"
OUT=$(bash -c '. "$1"; sentry_report error lane-x reason-x m; command -v lane_paused >/dev/null && echo has-lg; echo done' _ "$LIB" 2>&1)
[ "$OUT" = "done" ] && ok || bad "S5b without lane-gate: $OUT"
[ "$(calls)" = 0 ] && ok || bad "S5b paused (lane-gate sourced by the body) still sent"
rm -f "$HARNESS/flags/lane-off-sentry-report"; scratch_rm "$HARNESS/state/lane-gate"
sentry_report error lane-x reason-x m
[ "$(calls)" = 1 ] && ok || bad "S5 flag removed: want 1 send, got $(calls)"
bash -c '. "$1"; sentry_report error lane-x reason-z m' _ "$LIB"
[ "$(calls)" = 2 ] && ok || bad "S5b flag removed, no lane-gate: want 2 sends, got $(calls)"
reset; touch "$HARNESS/flags/all-off"
sentry_report error lane-x reason-x m
[ "$(calls)" = 0 ] && ok || bad "S5 all-off still sent"
rm -f "$HARNESS/flags/all-off"

# ---- S6 the three call sites (static, comment lines stripped) -------------------
code() { grep -v '^[[:space:]]*#' "$DIR/$1" 2>/dev/null; }
fnbody() { # fnbody <file> <fn> — the body of one top-level function
  code "$1" | awk -v f="$2" '$0 ~ "^"f"\\(\\) *\\{" {on=1} on {print} on && /^\}/ {exit}'
}
AEG=$(fnbody bin/lib/autoenqueue.sh _ae_gates)
SR_LN=$(grep -n 'sentry_report.*autoenqueue-ledger-unreadable' <<<"$AEG" | head -1 | cut -d: -f1)
SK_LN=$(grep -n '_ae_skip "$key" "$head" ledger' <<<"$AEG" | head -1 | cut -d: -f1)
[ -n "$SR_LN" ] && [ -n "$SK_LN" ] && [ "$SR_LN" -le "$SK_LN" ] && ok || bad "S6 _ae_gates: no sentry_report autoenqueue-ledger-unreadable before the ledger skip (sr=$SR_LN skip=$SK_LN)"
grep -q 'sentry_report.*review-prs-tmp-capped' <<<"$(code bin/review-prs.sh)" && ok || bad "S6 review-prs.sh: no sentry_report review-prs-tmp-capped"
grep -q 'RPOOL_CAP_BY' <<<"$(code bin/review-prs.sh)" && ok || bad "S6 review-prs.sh does not read RPOOL_CAP_BY"
grep -q 'bin/lib/sentry-report.sh' <<<"$(code bin/review-prs.sh)" && ok || bad "S6 review-prs.sh does not source bin/lib/sentry-report.sh"
grep -q 'sentry_report.*conductor-worker-deadline' <<<"$(fnbody bin/lib/fanin.sh mc_fanin_outcome)" && ok || bad "S6 mc_fanin_outcome: no sentry_report conductor-worker-deadline"
grep -q 'bin/lib/sentry-report.sh' <<<"$(code bin/merge-conductor.sh)" && ok || bad "S6 merge-conductor.sh does not source bin/lib/sentry-report.sh"

# rpool_init names the /tmp cap (behaviour). 1800 MB free, 1536 floor, 256 a
# worker: k = 1, capped by tmp.
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'tmpfs 9999999 1 %s 1%% /tmp\n' "$((1800 * 1024))"
EOF
chmod +x "$T/bin/df"
printf 'MemAvailable: %s kB\n' "$((64 * 1024 * 1024))" > "$T/meminfo"
OUT=$( PATH="$T/bin:$PATH" REVIEW_POOL_TMP_SWEEP='' REVIEW_POOL_MEMINFO="$T/meminfo" bash -c '
  . "$1"; rpool_init review-prs REVIEW 10 "$2/pool" ""; printf "%s %s" "$RPOOL_K" "${RPOOL_CAP_BY:-none}"' _ "$DIR/bin/lib/review-pool.sh" "$T" 2>&1)
[ "$OUT" = "1 tmp" ] && ok || bad "S6 rpool_init on 1800MB /tmp: want '1 tmp', got '$OUT'"
OUT=$( PATH="$T/bin:$PATH" REVIEW_POOL_TMP_SWEEP='' REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_BOX_MAX=2 bash -c '
  . "$1"; rpool_init review-prs REVIEW 10 "$2/pool" ""; printf "%s %s" "$RPOOL_K" "${RPOOL_CAP_BY:-none}"' _ "$DIR/bin/lib/review-pool.sh" "$T" 2>&1)
[ "$OUT" = "2 box_max" ] && ok || bad "S6 rpool_init with REVIEW_BOX_MAX=2: want '2 box_max', got '$OUT'"

# _ae_gates drives the reporter on its real G2 ledger skip (D2).
reset
OUT=$( bash -c '
  . "$1"; . "$2"
  mc_attempt_has() { return 1; }; mc_attempt_put() { return 0; }; mc_log() { :; }
  _ae_status() { return 1; }; _ae_ledger_code() { printf "http=503"; }
  AE_P=proj-ae; AE_SLUG=o/r; AE_PBASE=main; AE_HOLDS=""
  row=$(printf "7\thttps://github.com/o/r/pull/7\t%s\tticket/x\tfalse\t-\t-\t-\tfalse\t-\tmain\t-\t-" "$3")
  _ae_gates "$row"; echo "rc=$? gate=$AE_GATE"' _ "$DIR/bin/lib/autoenqueue.sh" "$LIB" "$FSHA" 2>&1)
[ "$OUT" = "rc=1 gate=ledger" ] && ok || bad "S6 _ae_gates ledger skip: $OUT"
[ "$(calls)" = 1 ] && ok || bad "S6 _ae_gates ledger skip: want 1 send, got $(calls)"
jq -e '.fingerprint == ["merge-conductor","proj-ae","autoenqueue-ledger-unreadable"] and .level == "warning" and .extra.ledger_code == "http=503"' \
  <<<"$(sed -n 3p "$T/body.1" 2>/dev/null)" >/dev/null 2>&1 && ok || bad "S6 _ae_gates event: $(sed -n 3p "$T/body.1" 2>/dev/null)"

# ---- S6b quiet output -------------------------------------------------------------
reset
OUT=$(HARNESS_SENTRY_DSN='' sentry_report error lane-x reason-q m 2>&1); [ -z "$OUT" ] && ok || bad "S6b no DSN printed: $OUT"
OUT=$(sentry_report error lane-x reason-q m 2>&1); [ -z "$OUT" ] && ok || bad "S6b 200 printed: $OUT"
OUT=$(FAKE_CODE=500 FAKE_BODY=nope sentry_report error lane-x reason-q2 m 2>&1); [ -z "$OUT" ] && ok || bad "S6b 500 printed: $OUT"
OUT=$(SENTRY_MAX_PER_FP_HOUR=1 sentry_report error lane-x reason-q m 2>&1); [ -z "$OUT" ] && ok || bad "S6b capped printed: $OUT"
touch "$HARNESS/flags/lane-off-sentry-report"
OUT=$(sentry_report error lane-x reason-q3 m 2>&1); [ -z "$OUT" ] && ok || bad "S6b paused printed: $OUT"
rm -f "$HARNESS/flags/lane-off-sentry-report"; scratch_rm "$HARNESS/state/lane-gate"
# mc_fanin_outcome: the outcome word stays exact with the reporter on.
reset
MCS="$T/mcstate"; mkdir -p "$MCS/worker-deadline"
printf '900\tagent-review\n' > "$MCS/worker-deadline/o_r_5.tick-1"
ROW=$(printf '5\turl\t%s\tbr\tfalse\tCLEAN\t-' "$FSHA")
OUT=$( MC_STATE_DIR="$MCS" MC_TICK_ID=tick-1 SLUG=o/r P=proj-mc bash -c '
  . "$1"; . "$2"
  mc_attempt_has() { return 1; }; mc_attempt_put() { return 0; }; mc_log() { :; }
  mc_handoff_id() { printf "%s" "$1" | tr "/#" "__"; }
  mc_fanin_outcome 143 "$3"' _ "$DIR/bin/lib/fanin.sh" "$LIB" "$ROW" 2>&1)
[ "$OUT" = killed:deadline ] && ok || bad "S6b mc_fanin_outcome printed '$OUT', want exactly killed:deadline"
[ "$(calls)" = 1 ] && ok || bad "S6b WORKER_DEADLINE: want 1 send, got $(calls)"
jq -e '.fingerprint == ["merge-conductor","proj-mc","conductor-worker-deadline"] and .extra.stage == "agent-review" and .extra.deadline_s == "900"' \
  <<<"$(sed -n 3p "$T/body.1" 2>/dev/null)" >/dev/null 2>&1 && ok || bad "S6b WORKER_DEADLINE event: $(sed -n 3p "$T/body.1" 2>/dev/null)"

# ---- S7 leak pattern --------------------------------------------------------------
mkdir -p "$T/leak-real" "$T/leak-fake"
LK=$(printf 'bh-5617 s7' | sha1sum | cut -c1-32)
printf 'dsn: https://%s@o1.%s.us.%s.io/123\n' "$LK" ingest sentry > "$T/leak-real/a.txt"
printf 'dsn: %s\n' "$FDSN" > "$T/leak-fake/a.txt"
OUT=$(python3 -I "$DIR/bin/share/leakcheck.py" "$T/leak-real" 2>&1)
grep -q 'sentry dsn' <<<"$OUT" && ok || bad "S7 a real DSN shape is not reported as sentry dsn: $OUT"
OUT=$(python3 -I "$DIR/bin/share/leakcheck.py" "$T/leak-fake" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S7 the fixture DSN is reported: $OUT"
# A legacy bare sentry.io host and a self-hosted server are the same shape.
for host in "%s.io" "errors.corp-net.test:9000/%s"; do
  scratch_rm "$T/leak-real"; mkdir -p "$T/leak-real"
  printf "dsn: https://%s@$host/77\n" "$LK" sentry sentry > "$T/leak-real/a.txt"
  OUT=$(python3 -I "$DIR/bin/share/leakcheck.py" "$T/leak-real" 2>&1)
  grep -q 'sentry dsn' <<<"$OUT" && ok || bad "S7 DSN on host '$host' is not reported as sentry dsn: $OUT"
done

# ---- S8 secret shape ---------------------------------------------------------------
REG="$T/lanes.json"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" > "$REG" 2>"$T/lanes-build.err" || bad "S8 lanes-build failed: $(head -3 "$T/lanes-build.err")"
[ "$(jq '[(.lanes[]?, .libs[]?) | .knobs[]? | select(.env == "HARNESS_SENTRY_DSN")] | length' "$REG" 2>/dev/null)" = 0 ] \
  && ok || bad "S8 HARNESS_SENTRY_DSN is registered as a knob"
jq -e '[.libs[] | select(.id == "sentry-report") | .knobs[] | select(.env == "SENTRY_MAX_PER_FP_HOUR")
        | select(.default == 6 and .required == true and .zero_means == "off")] | length == 1' "$REG" >/dev/null 2>&1 \
  && ok || bad "S8 lib sentry-report has no SENTRY_MAX_PER_FP_HOUR knob (default 6, required, zero_means off)"
OUT=$(python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ci", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("secret" if m.SECRET_RE.search("HARNESS_SENTRY_DSN") else "not-secret")' "$DIR/bin/config-inventory.py" 2>&1)
[ "$OUT" = secret ] && ok || bad "S8 config-inventory SECRET_RE does not match HARNESS_SENTRY_DSN: $OUT"

# ---- S9 no temp files left behind --------------------------------------------------
# The envelope and response files are removed on every return path: a 200, a
# non-200 and a curl failure all leave $HARNESS/tmp empty.
reset; scratch_rm "$HARNESS/tmp"; mkdir -p "$HARNESS/tmp"
sentry_report error lane-x reason-t1 m
FAKE_CODE=500 sentry_report error lane-x reason-t2 m
FAKE_RC=28 sentry_report error lane-x reason-t3 m
[ "$(calls)" = 3 ] && ok || bad "S9 want 3 sends, got $(calls)"
[ -z "$(ls -A "$HARNESS/tmp")" ] && ok || bad "S9 temp files left in \$HARNESS/tmp: $(ls -A "$HARNESS/tmp")"

# ---- S10 a capped call skips the lane-gate and knob reads ---------------------------
reset
for i in 1 2 3 4 5 6 7; do sentry_report error lane-x reason-c m; done
[ "$(calls)" = 6 ] && ok || bad "S10 want 6 sends, got $(calls)"
rm -f "$T/lp.n"
lane_paused() { echo x >> "$T/lp.n"; return 1; }
sentry_report error lane-x reason-c m
[ ! -e "$T/lp.n" ] && ok || bad "S10 a capped call ran lane_paused"
sentry_report error lane-x reason-d m
[ -s "$T/lp.n" ] && [ "$(calls)" = 7 ] && ok || bad "S10 an uncapped call skipped lane_paused or did not send"
# shellcheck source=/dev/null
. "$LG" 2>/dev/null || bad "S10 lane-gate.sh did not re-source"

echo "sentry-report.bh-5617: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
