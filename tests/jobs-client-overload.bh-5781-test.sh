#!/bin/bash
# BH-5781: _jobs_req retries a 503 whose payload says "overloaded" ONCE, after a
# short wait, and never retries any other answer: a 503 with another error, a
# 200 whose body happens to say "overloaded", or a 500.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
# HARNESS=$T: jobs-client.sh roots its log at HARNESS, so the log lines this
# suite counts land in the scratch tree, never in a live harness.
export JOBS_URL=https://jobs.invalid
H="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$T/bin" "$T/logs"
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_STATE"
# Record the request body (the argument after --data-binary) for each call.
prev=""; for a in "$@"; do [ "$prev" = --data-binary ] && printf '%s\n' "$a" >> "$STUB_STATE.bodies"; prev="$a"; done
ovl='{"error":"settings unavailable","detail":"D1_ERROR: D1 DB is overloaded. Requests queued for too long."}'
case "$STUB_PLAN:$n" in
  ovl-then-ok:0) printf '%s\n503' "$ovl" ;;
  ovl-then-ok:*) printf '{"ok":true}\n200' ;;
  ovl-twice:*)   printf '%s\n503' "$ovl" ;;
  503-other:*)   printf '{"error":"hub_lease schema not applied"}\n503' ;;
  200-says-overloaded:*) printf '{"note":"worker was overloaded earlier"}\n200' ;;
  500-overloaded:*) printf 'overloaded\n500' ;;
  edge-page:0)   printf '<html>Worker overloaded</html>\n503' ;;
  edge-page:*)   printf '{"ok":true}\n200' ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
run() { # run <plan> [method] [body] -> prints "rc=<rc> calls=<n> out=<body>"
  echo 0 > "$T/state"; rm -f "$T/state.bodies" "$T/logs/jobs-client.log"
  local out rc
  out=$(cd "$T" && PATH="$T/bin:$PATH" STUB_STATE="$T/state" STUB_PLAN="$1" HARNESS="$T" HARNESS_SECRET=x JOBS_ALERT=0 \
    JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_SLEEP=0 JOBS_OVERLOAD_JITTER_S=0 \
    bash -c 'source "$1"; _jobs_req "$2" /api/settings/closeout_aged_table "$3"' bash "$H/bin/jobs-client.sh" "${2:-GET}" "${3:-}" 2>/dev/null); rc=$?
  echo "rc=$rc calls=$(cat "$T/state") out=$out"
}
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "ok   $1 -> $3"; else echo "FAIL $1 -> $3 (want $2)"; fail=1; fi
}
# O1: an overload answer is retried once, and a 200 on the retry is a success.
check "O1 overload then ok" 'rc=0 calls=2 out={"ok":true}' "$(run ovl-then-ok)"
# O2: two overloads -> rc 1 after 2 calls, ONE log line that names the retry.
check "O2 overload twice" 'rc=1 calls=2 out=' "$(run ovl-twice)"
n=$(grep -c . "$T/logs/jobs-client.log" 2>/dev/null); n=${n:-0}
check "O2 one log line" 1 "$n"
grep -q 'after overload retry' "$T/logs/jobs-client.log" 2>/dev/null && echo "ok   O2 log names the overload retry" \
  || { echo "FAIL O2 log does not name the overload retry: $(cat "$T/logs/jobs-client.log" 2>/dev/null)"; fail=1; }
# O3: a 503 that is NOT an overload is not retried.
check "O3 other 503" 'rc=1 calls=1 out=' "$(run 503-other)"
# O4: a 200 that mentions "overloaded" is a success, not retried.
check "O4 200 says overloaded" 'rc=0 calls=1 out={"note":"worker was overloaded earlier"}' "$(run 200-says-overloaded)"
# O4b: a 500 is never retried, whatever its body says.
check "O4b 500 says overloaded" 'rc=1 calls=1 out=' "$(run 500-overloaded)"
# O5: JOBS_OVERLOAD_RETRIES=0 switches the retry off.
r=$(JOBS_OVERLOAD_RETRIES=0 run ovl-then-ok)
check "O5 retries=0" 'rc=1 calls=1 out=' "$r"
# O6: a POST retry sends the same body again.
check "O6 POST overload then ok" 'rc=0 calls=2 out={"ok":true}' "$(run ovl-then-ok POST '{"k":"v"}')"
b=$(cat "$T/state.bodies" 2>/dev/null)
check "O6 same body twice" $'{"k":"v"}\n{"k":"v"}' "$b"
# O7: a non-JSON 503 edge page that says "overloaded" is retried too.
check "O7 edge page" 'rc=0 calls=2 out={"ok":true}' "$(run edge-page)"
exit $fail
