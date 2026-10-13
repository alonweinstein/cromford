#!/bin/bash
# The jobs client must find HARNESS_SECRET in <HARNESS>/env/global.env when the
# caller's environment lacks it (cron-launched hub lanes), and must never
# override a secret the caller already set. Red on main 2026-09-11: fly-dispatch
# pulled zero queued rows for six hours because it sourced only env/fly.env.
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/env" "$T/logs" "$T/flags"
printf 'HARNESS_SECRET="fixture-secret"\nJOBS_URL=https://jobs.example.invalid\n' > "$T/env/global.env"
pass=0; fail=0
ok() { pass=$((pass+1)); }; bad() { fail=$((fail+1)); echo "FAIL: $1"; }
# 1. unset in the environment -> read from the env file
got=$(env -i HOME="$T" PATH="$PATH" HARNESS="$T" bash -c ". \"$HERE/bin/jobs-client.sh\" >/dev/null 2>&1; printf '%s|%s' \"\${HARNESS_SECRET:-}\" \"\${JOBS_URL:-}\"")
[ "$got" = "fixture-secret|https://jobs.example.invalid" ] && ok || bad "secret/url not read from env file (got '$got')"
# 2. already set by the caller -> untouched
got=$(env -i HOME="$T" PATH="$PATH" HARNESS="$T" HARNESS_SECRET=caller JOBS_URL=https://caller.invalid bash -c ". \"$HERE/bin/jobs-client.sh\" >/dev/null 2>&1; printf '%s|%s' \"\$HARNESS_SECRET\" \"\$JOBS_URL\"")
[ "$got" = "caller|https://caller.invalid" ] && ok || bad "caller values overridden (got '$got')"
# 3. no env file -> _jobs_req still refuses (rc 1) rather than crashing
got=$(env -i HOME="$T" PATH="$PATH" HARNESS="$T/nope" bash -c ". \"$HERE/bin/jobs-client.sh\" >/dev/null 2>&1; _jobs_req GET /api/x >/dev/null 2>&1; echo \$?")
[ "$got" = "1" ] && ok || bad "missing env file should leave _jobs_req refusing with rc 1 (got '$got')"
echo "jobs-client-self-env-test: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
