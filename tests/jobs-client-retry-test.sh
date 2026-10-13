#!/bin/bash
# jobs-client retries a TRANSPORT failure once, never an HTTP answer, and stays
# fail-open when the worker is really down.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
H="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$T/bin" "$T/logs"
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_STATE"
case "$STUB_PLAN:$n" in
  blip:0) exit 28 ;;                    # first attempt times out
  blip:*) printf '{"ok":true}\n200'; exit 0 ;;
  down:*) exit 28 ;;
  http500:*) printf 'boom\n500'; exit 0 ;;
esac
STUB
chmod +x "$T/bin/curl"
run() { # run <plan> -> prints "rc=<rc> calls=<n> out=<body>"
  echo 0 > "$T/state"
  local out rc
  out=$(cd "$T" && PATH="$T/bin:$PATH" STUB_STATE="$T/state" STUB_PLAN="$1" HARNESS_SECRET=x JOBS_HARNESS="$T" JOBS_RETRY_SLEEP=0 \
    bash -c 'source "$1"; _jobs_req GET /api/ping' bash "$H/bin/jobs-client.sh" 2>/dev/null); rc=$?
  echo "rc=$rc calls=$(cat "$T/state") out=$out"
}
fail=0
r=$(run blip);    [ "$r" = 'rc=0 calls=2 out={"ok":true}' ] && echo "ok   blip -> $r"    || { echo "FAIL blip -> $r"; fail=1; }
r=$(run down);    [ "$r" = 'rc=1 calls=2 out=' ]           && echo "ok   down -> $r"    || { echo "FAIL down -> $r"; fail=1; }
r=$(run http500); [ "$r" = 'rc=1 calls=1 out=' ]           && echo "ok   http500 -> $r" || { echo "FAIL http500 (no retry on an HTTP answer) -> $r"; fail=1; }
exit $fail
