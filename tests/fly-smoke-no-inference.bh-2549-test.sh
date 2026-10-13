#!/bin/bash
# tests/fly-smoke-no-inference.bh-2549-test.sh — BH-2559 (BH-2549.1): the fly
# builder's SMOKE job probes the claude credential through cred_probe (a free
# GET) and spends no inference. Drives the REAL _run_job extracted from
# fly/builder-runner.sh, with a harness whose agent-call.sh and a PATH claude
# both record any call and fail.
#
#   S1 curl 200 JSON -> RESULT `SMOKE_OK claude credential alive host=builder-proj`;
#      neither agent-call.sh nor claude was invoked;
#   S2 curl 401 -> RESULT `SMOKE_FAIL DEAD 401`; stubs not called;
#   S3 a harness with no cred-probe.sh -> `SMOKE_FAIL harness not synced`;
#      stubs not called, curl not called;
#   S4 curl 429 -> `SMOKE_FAIL INCONCLUSIVE…`, never SMOKE_OK.
# Run from anywhere: bash tests/fly-smoke-no-inference.bh-2549-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^_run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/runjob.sh"
grep -q 'SMOKE' "$T/runjob.sh" || bad "could not extract _run_job's SMOKE branch from fly/builder-runner.sh"

mkdir -p "$T/h/bin/lib" "$T/empty" "$T/path" "$T/job"
cp "$DIR/bin/lib/cred-probe.sh" "$DIR/bin/lib/endpoints.sh" "$T/h/bin/lib/"
for f in "$T/h/bin/agent-call.sh" "$T/path/claude"; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/called"\nexit 99\n' "$(basename "$f")" "$T" > "$f"; chmod +x "$f"
done
cat > "$T/path/curl" <<STUB
#!/bin/bash
echo "\$*" >> "$T/curl.log"
o=""; w=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$o" ] && printf '%s' '{"data":[]}' > "\$o"
printf '%s' "\${w//%\{http_code\}/\$STUB_CODE}"
STUB
chmod +x "$T/path/curl"
echo '{"key":"SMOKE","ticket_id":"","attempt":0}' > "$T/job/job.json"

smoke() {  # smoke <harness-dir> <curl code> -> RESULT (first line of the result file)
  rm -f "$T/called" "$T/curl.log" "$T/job/result.txt"
  env -u CRED_PROBE_LIB -u EXECUTE_MODEL PATH="$T/path:$PATH" STUB_CODE="$2" TMPDIR="$T/job" \
      CLAUDE_CODE_OAUTH_TOKEN=fixture ENDPOINT_ANTHROPIC=https://stub.invalid \
      HARNESS="$1" JOB="$T/job/job.json" JOBDIR="$T/job" RESULT_FILE="$T/job/result.txt" PROJECT=proj \
      bash -c '
    log() { :; }; load_env() { :; }; model_routes_warm() { :; }
    start_heartbeat() { :; }; stop_heartbeat() { :; }; beat() { :; }
    . "$1"; _run_job' _ "$T/runjob.sh" >/dev/null 2>&1
  SRC=$?
  RESULT=$(head -1 "$T/job/result.txt" 2>/dev/null)
}
not_called() { [ ! -s "$T/called" ] && ok || bad "$1: an inference stub was invoked: $(cat "$T/called")"; }

smoke "$T/h" 200
[ "$RESULT" = "SMOKE_OK claude credential alive host=builder-proj" ] && ok || bad "S1 200 -> '$RESULT'"
[ "$SRC" -eq 0 ] && ok || bad "S1 _run_job rc=$SRC"
not_called S1
[ -s "$T/curl.log" ] && ok || bad "S1 the probe never reached curl"

smoke "$T/h" 401
[ "$RESULT" = "SMOKE_FAIL DEAD 401" ] && ok || bad "S2 401 -> '$RESULT'"
not_called S2

smoke "$T/empty" 200
[ "$RESULT" = "SMOKE_FAIL harness not synced" ] && ok || bad "S3 no harness -> '$RESULT'"
not_called S3
[ -s "$T/curl.log" ] && bad "S3 curl was called with no harness" || ok

smoke "$T/h" 429
[[ "$RESULT" == "SMOKE_FAIL INCONCLUSIVE"* ]] && ok || bad "S4 429 -> '$RESULT'"
not_called S4

echo "fly-smoke-no-inference.bh-2549: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
