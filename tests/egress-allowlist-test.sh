#!/bin/bash
# tests/egress-allowlist-test.sh — the egress allowlist on build stages
# (BH-4492, wave 5 of BH-4475). A stage process reaching an unlisted host is
# refused and logged; registries are reachable in execute and not in review;
# the evidence block lists the refusal.
#
#   P1..P6  bin/egress-proxy.py alone: `serve` behind `fwd`, no privilege
#   L1..L5  bin/lib/egress.sh driven directly (rows, absence, fallback, probe)
#   A1..A6  the REAL bin/agent-call.sh with a fake `claude` that runs curl from
#           inside whatever the stage was launched in
#   E1..E3  the REAL bin/evidence-summary.sh on those build dirs
#   S       worker/jobs/test/egress-seed.bh-4492.test.js, when node is here
#
# A2-A5 need a network namespace (root: `unshare -n`, else `unshare -rn`). A
# machine without one prints a SKIP line naming the test host and those cases
# count as nothing, never as passes. Real-registry reachability is asserted
# only when the outside probe answers; otherwise a named SKIP (offline).
#
# Run from anywhere: tests/egress-allowlist-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/egress.sh"
PROXY="$DIR/bin/egress-proxy.py"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
NOW=$(date +%s)
REAL_CURL=$(command -v curl)

BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null; done; __scratch_exit_trap' EXIT
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
waitfor() { local i; for i in $(seq 1 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
# settings <json-values> — a fresh settings cache under $T/state
settings() { mkdir -p "$T/state"; jq -nc --argjson v "$1" --argjson fa "$NOW" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
EXEC_SEED="api.anthropic.com platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com openrouter.ai api.fireworks.ai generativelanguage.googleapis.com registry.npmjs.org registry.yarnpkg.com pypi.org files.pythonhosted.org"
REVIEW_SEED="api.anthropic.com platform.claude.com api.x.ai api.openai.com chatgpt.com auth.openai.com openrouter.ai api.fireworks.ai generativelanguage.googleapis.com"

# The hermetic upstream: an allowed "host" that is 127.0.0.1:$UP outside the
# namespace. Its access log is the proof of a hit.
UP=$(freeport)
mkdir -p "$T/www"; echo hello > "$T/www/index.html"
( cd "$T/www" && exec python3 -m http.server --bind 127.0.0.1 "$UP" ) > /dev/null 2> "$T/up.log" &
BG="$BG $!"
for _i in $(seq 1 50); do "$REAL_CURL" -s -o /dev/null "http://127.0.0.1:$UP/" && break; sleep 0.1; done
uphits() { grep -c '"GET ' "$T/up.log" 2>/dev/null; }
ONLINE=0; "$REAL_CURL" -sf -o /dev/null --max-time 5 https://registry.npmjs.org/-/ping && ONLINE=1

# code <out-file> — curl's "<http_code> <http_connect>"
pcurl() { "$REAL_CURL" -s -o /dev/null -w '%{http_code} %{http_connect}' --max-time 8 "$@" 2>/dev/null; }

# =============================================================================
# P — the proxy alone
# =============================================================================
[ -r "$PROXY" ] && ok || bad "P0 $PROXY missing"
mkdir -p "$T/p"
python3 "$PROXY" serve --sock "$T/p/s" --stage execute --log "$T/p/egress.log" --id p1 \
  --hosts "127.0.0.1:$UP *.example.org evil.test:8443 registry.npmjs.org" 2>"$T/p/serve.err" &
SERVE=$!; BG="$BG $SERVE"
waitfor "$T/p/s" || bad "P1 serve socket never appeared: $(cat "$T/p/serve.err" 2>/dev/null | head -3)"
python3 "$PROXY" fwd --listen 127.0.0.1:0 --sock "$T/p/s" --port-file "$T/p/port" 2>"$T/p/fwd.err" &
BG="$BG $!"
waitfor "$T/p/port" && sleep 0.1
PORT=$(cat "$T/p/port" 2>/dev/null)
X="http://127.0.0.1:${PORT:-1}"

# P1 — allowed plain HTTP reaches the upstream
H0=$(uphits)
R=$(pcurl -x "$X" "http://127.0.0.1:$UP/")
[ "${R%% *}" = 200 ] && ok || bad "P1 allowed upstream via proxy: '$R', want 200"
[ "$(uphits)" -gt "$H0" ] && ok || bad "P1 the upstream saw no hit"

# P2 — unlisted https: 403 on CONNECT, exactly one DENY line
R=$(pcurl -x "$X" https://unlisted.example/)
[ "${R##* }" = 403 ] && ok || bad "P2 unlisted CONNECT: '$R', want connect 403"
[ "$(grep -c 'stage=execute DENY unlisted.example:443 via=proxy' "$T/p/egress.log")" = 1 ] && ok \
  || bad "P2 DENY lines for unlisted.example: $(grep -c 'unlisted.example' "$T/p/egress.log")"

# P3 — the matcher, through the real proxy and through `match`
for tgt in https://example.org/ https://registry.npmjs.org.evil.test/ https://evil.test/ https://10.9.8.7/; do
  R=$(pcurl -x "$X" "$tgt")
  [ "${R##* }" = 403 ] && ok || bad "P3 $tgt: '$R', want connect 403"
done
for hp in example.org:443 registry.npmjs.org.evil.test:443 evil.test:443 10.9.8.7:443; do
  grep -q "stage=execute DENY $hp via=proxy" "$T/p/egress.log" && ok || bad "P3 no DENY line for $hp"
done
# allowed by the list: the proxy goes upstream (502 when the name does not
# resolve) and writes no DENY for it
R=$(pcurl -x "$X" https://sub.example.org/)
[ "${R##* }" != 403 ] && ok || bad "P3 sub.example.org refused under *.example.org: '$R'"
grep -q 'DENY sub.example.org' "$T/p/egress.log" && bad "P3 sub.example.org was logged as DENY" || ok
M=$(for c in sub.example.org:443 example.org:443 a.b.example.org:80 example.org.evil:443 evil.test:8443 \
             evil.test:443 Registry.NPMJS.org.:443 registry.npmjs.org:22 127.0.0.1:$UP 127.0.0.1:443 '[::1]:443'; do
      python3 "$PROXY" match --hosts "127.0.0.1:$UP *.example.org evil.test:8443 registry.npmjs.org" "$c" >/dev/null 2>&1 && printf a || printf d; done)
[ "$M" = "adadadadadd" ] && ok || bad "P3 match table '$M', want adadadadadd"

# P4 — plain-HTTP keep-alive: the SECOND request line is checked too
P4=$(python3 - "$PORT" "$UP" <<'EOF'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=8)
up = sys.argv[2]
s.sendall((f"GET http://127.0.0.1:{up}/ HTTP/1.1\r\nHost: 127.0.0.1:{up}\r\n\r\n"
           "GET http://unlisted.example/ HTTP/1.1\r\nHost: unlisted.example\r\n\r\n").encode())
buf = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        buf += d
except socket.timeout:
    pass
import re
print(" ".join(re.findall(r"HTTP/1\.[01] ([0-9]{3}) ", buf.decode("latin-1"))))
EOF
)
[ "$P4" = "200 403" ] && ok || bad "P4 keep-alive statuses '$P4', want '200 403'"
grep -q 'stage=execute DENY unlisted.example:80 via=proxy' "$T/p/egress.log" && ok || bad "P4 no DENY for the second request line"

# P5 — 600 refusals: 500 DENY lines, one DENY-CAPPED, exact END count
mkdir -p "$T/p5"
python3 "$PROXY" serve --sock "$T/p5/s" --stage review --log "$T/p5/egress.log" --id p5 --hosts api.anthropic.com 2>/dev/null &
P5PID=$!; BG="$BG $P5PID"
waitfor "$T/p5/s"
python3 - "$T/p5/s" <<'EOF'
import socket, sys
for i in range(600):
    s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
    s.sendall(f"CONNECT h{i}.unlisted.example:443 HTTP/1.1\r\n\r\n".encode())
    s.recv(4096); s.close()
EOF
kill -TERM "$P5PID"; wait "$P5PID" 2>/dev/null
[ "$(grep -c ' DENY ' "$T/p5/egress.log")" = 500 ] && ok || bad "P5 DENY lines $(grep -c ' DENY ' "$T/p5/egress.log"), want 500"
[ "$(grep -c ' DENY-CAPPED' "$T/p5/egress.log")" = 1 ] && ok || bad "P5 DENY-CAPPED lines $(grep -c 'DENY-CAPPED' "$T/p5/egress.log"), want 1"
grep -qE 'stage=review END allow=0 deny=600 id=p5$' "$T/p5/egress.log" && ok || bad "P5 END line: $(grep END "$T/p5/egress.log")"

# P6 — the proxy exits when its parent dies
mkdir -p "$T/p6"
bash -c 'python3 "$1" serve --sock "$2/s" --stage execute --log "$2/egress.log" --id p6 --hosts x.test 2>/dev/null & echo $! > "$2/pid"; sleep 0.5' _ "$PROXY" "$T/p6"
P6PID=$(cat "$T/p6/pid" 2>/dev/null); BG="$BG $P6PID"
gone=0; for _i in $(seq 1 30); do kill -0 "$P6PID" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
[ "$gone" = 1 ] && ok || bad "P6 proxy $P6PID still alive 3s after its parent exited"

# =============================================================================
# L — the lib
# =============================================================================
# hosts <stage> -> "rc|EG_HOSTS|EG_SOURCE|EG_REASON"
hosts() { HARNESS="$T" bash -c '. "$1"; eg_hosts "$2"; rc=$?; echo "$rc|$EG_HOSTS|$EG_SOURCE|$EG_REASON"' _ "$LIB" "$1" 2>/dev/null; }
FB=$(bash -c '. "$1"; echo "$EG_FALLBACK_HOSTS"' _ "$LIB" 2>/dev/null)
[ "$FB" = "${REVIEW_SEED% generativelanguage.googleapis.com}" ] && ok || bad "L0 EG_FALLBACK_HOSTS '$FB', want the review seed minus gemini's host"
settings '{"egress.stage.execute.hosts":"registry.npmjs.org, api.anthropic.com"}'
[ "$(hosts execute)" = "0|registry.npmjs.org api.anthropic.com|row|" ] && ok || bad "L1 row: '$(hosts execute)'"
settings '{"egress.stage.execute.hosts":"  Registry.NPMJS.org,,*.Example.org\t127.0.0.1:8080 "}'
[ "$(hosts execute)" = "0|registry.npmjs.org *.example.org 127.0.0.1:8080|row|" ] && ok || bad "L1 normalised: '$(hosts execute)'"
# L1g — a *.suffix entry is never globbed against the caller's CWD
mkdir -p "$T/cwd"; : > "$T/cwd/x.example.org"
L1G=$(cd "$T/cwd" && hosts execute)
[ "$L1G" = "0|registry.npmjs.org *.example.org 127.0.0.1:8080|row|" ] && ok || bad "L1g globbed against CWD: '$L1G'"
rm -rf "$T/state"
[ "$(hosts execute)" = "1|||no-settings-cache" ] && ok || bad "L2 no cache: '$(hosts execute)'"
settings '{}'
[ "$(hosts execute)" = "1|||no-row" ] && ok || bad "L2 no row: '$(hosts execute)'"
settings '{"egress.stage.execute.hosts":" OFF "}'
[ "$(hosts execute)" = "1|||off" ] && ok || bad "L2 off: '$(hosts execute)'"
printf '{not json' > "$T/state/settings-cache.json"
[ "$(hosts execute)" = "0|$FB|fallback:settings-unreadable|" ] && ok || bad "L3 corrupt cache: '$(hosts execute)'"
settings '{"egress.stage.execute.hosts":"registry.npmjs.org reg!stry api.anthropic.com"}'
[ "$(hosts execute)" = "0|$FB|fallback:row-unreadable:egress.stage.execute.hosts|" ] && ok || bad "L3 bad entry: '$(hosts execute)'"
settings '{"egress.stage.execute.hosts":" , "}'
[ "$(hosts execute)" = "0|$FB|fallback:row-unreadable:egress.stage.execute.hosts|" ] && ok || bad "L3 empty row: '$(hosts execute)'"
grep -q 'registry' <<<"$FB" && bad "L3 the fallback list carries a registry" || ok
mkdir -p "$T/stubns"; printf '#!/bin/bash\nexit 1\n' > "$T/stubns/unshare"; chmod +x "$T/stubns/unshare"
L4=$(PATH="$T/stubns:$PATH" bash -c '. "$1"; eg_mechanism; echo "$?|$EG_REASON"' _ "$LIB" 2>/dev/null)
[ "$L4" = "1|unshare-refused" ] && ok || bad "L4 refused unshare: '$L4'"
L5=$(HARNESS="$T" bash -c 'set -euo pipefail; . "$1"
  for f in eg_hosts eg_mechanism eg_begin eg_end; do declare -F "$f" >/dev/null || echo "undefined:$f"; done
  echo sourced' _ "$LIB" 2>&1)
[ "$(tail -1 <<<"$L5")" = sourced ] && ok || bad "L5 sourcing under set -eu: $L5"
grep -q '^undefined:' <<<"$L5" && bad "L5 missing: $L5" || ok
grep -q '/root/harness' <<<"$(grep -v '^[[:space:]]*#' "$LIB" 2>/dev/null)" && bad "L5 the lib carries a /root/harness literal" || ok

# =============================================================================
# the agent-call fixture (as tests/budget-stop-tracer-test.sh)
# =============================================================================
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/builds" "$T/logs" "$T/bin"
echo '{"lanes":[]}' > "$T/budgets.json"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
# The stage process: say where it runs, then run each probe with whatever
# proxy env it inherited.
{
  echo "ns $(readlink /proc/self/ns/net)"
  echo "acct ${CLAUDE_CODE_OAUTH_TOKEN:-none}"
  echo "proxy ${HTTPS_PROXY:-none}"
  if [ -r "${EG_PROBES:-}" ]; then
    while read -r label args; do
      [ -n "$label" ] || continue
      out=$(eval "\"\$REAL_CURL\" -s -o /dev/null -w '%{http_code} %{http_connect}' --max-time 5 $args" 2>/dev/null); rc=$?
      echo "probe $label $out rc=$rc"
    done < "$EG_PROBES"
  fi
} >> "$SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
cp "$DIR/bin/alert-line.sh" "$T/bin/alert-line.sh" 2>/dev/null
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
OUTER_NS=$(readlink /proc/self/ns/net)
reset() { : > "$T/sink"; : > "$T/probes"; : > "$T/logs/ALERTS.log"; rm -rf "$T/flags"; mkdir -p "$T/flags"; }
probe() { printf '%s\n' "$*" >> "$T/probes"; }
# call <stage> <out> [VAR=VAL ...] -> prints the rc; stderr to $T/err
call() {
  local st="$1" out="$2"; shift 2
  mkdir -p "$(dirname "$out")"
  ( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID \
          HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
    export SINK="$T/sink" EG_PROBES="$T/probes" REAL_CURL="$REAL_CURL" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok-a1 ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$st" testproj claude-fable-5-1 60 "$out" "hello" >/dev/null 2>"$T/err" )
  echo $?
}
sinkv() { awk -v k="$1" '$1=="probe" && $2==k {print $3" "$4" "$5}' "$T/sink" | tail -1; }
NSOK=""; NSWHY=""
if [ "$(id -u)" = 0 ]; then unshare -n true 2>/dev/null && NSOK=1 || NSWHY="unshare -n refused"
else unshare -rn true 2>/dev/null && NSOK=1 || NSWHY="unshare -rn refused (no user namespaces)"; fi
command -v unshare >/dev/null || { NSOK=""; NSWHY="no unshare"; }
nsskip() { skip "$1: no network namespace on this machine ($NSWHY) — run on the test host: bin/remote-gate.sh . tests/egress-allowlist-test.sh"; }

# A1 — execute, armed: the stage runs in its own namespace and reaches the
# allowed upstream through the fence; its account env still reaches it
if [ -n "$NSOK" ]; then
  reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED 127.0.0.1:$UP\"}"
  probe 'up --noproxy "" -x $HTTP_PROXY http://127.0.0.1:'"$UP"'/'
  H0=$(uphits)
  R=$(call execute "$T/builds/a1/execute-run.txt")
  [ "$R" = 0 ] && ok || bad "A1 rc=$R: $(head -3 "$T/err")"
  NS=$(awk '$1=="ns"{print $2}' "$T/sink")
  [ -n "$NS" ] && [ "$NS" != "$OUTER_NS" ] && ok || bad "A1 the stage ran in the outer namespace ('$NS')"
  [ "$(sinkv up)" = "200 000 rc=0" ] && ok || bad "A1 upstream through the fence: '$(sinkv up)'"
  [ "$(uphits)" -gt "$H0" ] && ok || bad "A1 the upstream saw no hit"
  grep -q '^acct tok-a1$' "$T/sink" && ok || bad "A1 the runner lost its account env: $(grep acct "$T/sink")"
  grep -q "stage=execute runner=claude state=enforced source=row hosts=$(( $(wc -w <<<"$EXEC_SEED") + 1 )) " "$T/builds/a1/egress-state.txt" 2>/dev/null \
    && ok || bad "A1 state line: $(cat "$T/builds/a1/egress-state.txt" 2>/dev/null)"
  A1ID=$(awk '$3=="INNER"{print $NF}' "$T/builds/a1/egress.log" 2>/dev/null | sed 's/^id=//' | tail -1)
  [ -n "$A1ID" ] && ok || bad "A1 no INNER line in egress.log: $(cat "$T/builds/a1/egress.log" 2>/dev/null)"
  [ -n "$A1ID" ] && [ -e "/tmp/bhe.$A1ID" ] && bad "A1 the proxy tmp dir /tmp/bhe.$A1ID was left behind" || ok
else nsskip A1; fi

# A1b — no row for plan, and a call outside builds/: unfenced, byte-for-byte
reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED\",\"egress.stage.review.hosts\":\"$REVIEW_SEED\"}"
R=$(call plan "$T/builds/a1b/plan-run.txt")
[ "$R" = 0 ] && ok || bad "A1b plan rc=$R: $(head -3 "$T/err")"
[ "$(awk '$1=="ns"{print $2}' "$T/sink")" = "$OUTER_NS" ] && ok || bad "A1b plan ran fenced"
grep -q '^proxy none$' "$T/sink" && ok || bad "A1b plan got a proxy env: $(grep proxy "$T/sink")"
grep -q 'stage=plan runner=claude state=not-armed source=- .*reason=no-row' "$T/builds/a1b/egress-state.txt" 2>/dev/null \
  && ok || bad "A1b plan state line: $(cat "$T/builds/a1b/egress-state.txt" 2>/dev/null)"
reset
R=$(call execute "$T/other/triage-out.txt")
[ "$R" = 0 ] && ok || bad "A1b triage rc=$R: $(head -3 "$T/err")"
[ "$(awk '$1=="ns"{print $2}' "$T/sink")" = "$OUTER_NS" ] && ok || bad "A1b a call outside builds/ ran fenced"
[ -e "$T/other/egress-state.txt" ] && bad "A1b a state file was written outside builds/" || ok

# A2 — execute: an unlisted host is refused and logged; the registry is allowed
if [ -n "$NSOK" ]; then
  reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED 127.0.0.1:$UP\"}"
  probe 'unl https://unlisted.example/'
  probe 'npm https://registry.npmjs.org/-/ping'
  R=$(call execute "$T/builds/a2/execute-run.txt")
  [ "$R" = 0 ] && ok || bad "A2 rc=$R: $(head -3 "$T/err")"
  [ "$(sinkv unl | cut -d' ' -f2)" = 403 ] && ok || bad "A2 unlisted host: '$(sinkv unl)', want connect 403"
  grep -q 'stage=execute DENY unlisted.example:443 via=proxy' "$T/builds/a2/egress.log" 2>/dev/null && ok \
    || bad "A2 no DENY line: $(cat "$T/builds/a2/egress.log" 2>/dev/null)"
  grep -q 'DENY registry.npmjs.org' "$T/builds/a2/egress.log" 2>/dev/null && bad "A2 the registry was refused in execute" || ok
  if [ "$ONLINE" = 1 ]; then
    [ "$(sinkv npm)" = "200 200 rc=0" ] && ok || bad "A2 registry through the fence: '$(sinkv npm)', want 200"
  else skip "A2 registry reachability (offline)"; fi
  grep -q 'state=enforced .*deny=1 ' "$T/builds/a2/egress-state.txt" 2>/dev/null && ok \
    || bad "A2 state line: $(cat "$T/builds/a2/egress-state.txt" 2>/dev/null)"
else nsskip A2; fi

# A3 — review: registries are NOT reachable, the model API is
if [ -n "$NSOK" ]; then
  reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED 127.0.0.1:$UP\",\"egress.stage.review.hosts\":\"$REVIEW_SEED\"}"
  probe 'npm https://registry.npmjs.org/-/ping'
  probe 'up --noproxy "" -x $HTTP_PROXY http://127.0.0.1:'"$UP"'/'
  probe 'ant https://api.anthropic.com/'
  R=$(call review "$T/builds/a3/review-run.txt")
  [ "$R" = 0 ] && ok || bad "A3 rc=$R: $(head -3 "$T/err")"
  [ "$(sinkv npm | cut -d' ' -f2)" = 403 ] && ok || bad "A3 registry in review: '$(sinkv npm)', want connect 403"
  grep -q 'stage=review DENY registry.npmjs.org:443 via=proxy' "$T/builds/a3/egress.log" 2>/dev/null && ok || bad "A3 no DENY for the registry"
  [ "$(sinkv up | cut -d' ' -f1)" = 403 ] && ok || bad "A3 execute-only upstream in review: '$(sinkv up)', want 403"
  grep -q "stage=review DENY 127.0.0.1:$UP via=proxy" "$T/builds/a3/egress.log" 2>/dev/null && ok || bad "A3 no DENY for the upstream"
  grep -q 'DENY api.anthropic.com' "$T/builds/a3/egress.log" 2>/dev/null && bad "A3 the model API was refused in review" || ok
  [ "$(sinkv ant | cut -d' ' -f2)" != 403 ] && ok || bad "A3 api.anthropic.com: '$(sinkv ant)'"
else nsskip A3; fi

# A4 — a process that ignores the proxy env is refused (and logged when the
# AnyIP route went in)
if [ -n "$NSOK" ]; then
  reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED 127.0.0.1:$UP\"}"
  probe "dl --noproxy '*' --max-time 3 http://127.0.0.1:$UP/"
  probe "dx --noproxy '*' --max-time 3 http://203.0.113.7/"
  H0=$(uphits)
  R=$(call execute "$T/builds/a4/execute-run.txt")
  [ "$R" = 0 ] && ok || bad "A4 rc=$R: $(head -3 "$T/err")"
  [ "$(uphits)" = "$H0" ] && ok || bad "A4 a direct connect reached the outside upstream"
  case "$(sinkv dl)" in *rc=0) bad "A4 direct to 127.0.0.1:$UP succeeded: '$(sinkv dl)'" ;; *) ok ;; esac
  case "$(sinkv dx)" in *rc=0) bad "A4 direct to 203.0.113.7 succeeded: '$(sinkv dx)'" ;; *) ok ;; esac
  if grep -q 'direct_log=on' "$T/builds/a4/egress-state.txt" 2>/dev/null; then
    grep -q 'stage=execute DENY-DIRECT 203.0.113.7:80 via=direct' "$T/builds/a4/egress.log" 2>/dev/null && ok \
      || bad "A4 no DENY-DIRECT line: $(cat "$T/builds/a4/egress.log" 2>/dev/null)"
    grep -q 'direct=1$' "$T/builds/a4/egress-state.txt" && ok || bad "A4 state direct count: $(cat "$T/builds/a4/egress-state.txt")"
  else skip "A4 DENY-DIRECT logging (the AnyIP route was refused here; refusal asserted only)"; fi
else nsskip A4; fi

# A5 — an unreadable cache fails closed to the model hosts; the call completes.
# A corrupt cache also makes the budget stop (BH-4488/4489, bs_gate on every
# stage) refuse before the fence is reached, so A5 turns that gate off with its
# own kill switch (flags/budget-stop-off): this case pins the FENCE's fallback;
# tests/budget-stop*.sh pin the budget gate's.
if [ -n "$NSOK" ]; then
  reset; mkdir -p "$T/state" "$T/flags"; printf '{not json' > "$T/state/settings-cache.json"
  : > "$T/flags/budget-stop-off"
  probe 'npm https://registry.npmjs.org/-/ping'
  R=$(call review "$T/builds/a5/review-run.txt")
  rm -f "$T/flags/budget-stop-off"
  [ "$R" = 0 ] && ok || bad "A5 rc=$R: $(head -3 "$T/err")"
  grep -q "stage=review runner=claude state=enforced source=fallback:settings-unreadable hosts=$(wc -w <<<"$FB") " "$T/builds/a5/egress-state.txt" 2>/dev/null \
    && ok || bad "A5 state line: $(cat "$T/builds/a5/egress-state.txt" 2>/dev/null)"
  [ "$(sinkv npm | cut -d' ' -f2)" = 403 ] && ok || bad "A5 registry under the fallback: '$(sinkv npm)', want 403"
else nsskip A5; fi

# A6 — no namespace on the box: the call runs unfenced, one state line per
# call, ONE alert per stage per day (runs everywhere)
reset; settings "{\"egress.stage.execute.hosts\":\"$EXEC_SEED\"}"
R1=$(call execute "$T/builds/a6/execute-run.txt" PATH="$T/stubns:$T/fakebin:$PATH")
R2=$(call execute "$T/builds/a6/execute-run.txt" PATH="$T/stubns:$T/fakebin:$PATH")
[ "$R1/$R2" = 0/0 ] && ok || bad "A6 rcs $R1/$R2, want 0/0: $(head -3 "$T/err")"
[ "$(awk '$1=="ns"{print $2}' "$T/sink" | sort -u)" = "$OUTER_NS" ] && ok || bad "A6 the call did not run in the outer namespace"
[ "$(grep -c 'stage=execute runner=claude state=not-enforced .*reason=unshare-refused' "$T/builds/a6/egress-state.txt" 2>/dev/null)" = 2 ] \
  && ok || bad "A6 state lines: $(cat "$T/builds/a6/egress-state.txt" 2>/dev/null)"
[ "$(grep -c 'EGRESS ALLOWLIST NOT ENFORCED' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "A6 alert lines: $(grep -c 'EGRESS' "$T/logs/ALERTS.log"), want 1"
grep -q 'execute/testproj.*unshare-refused' "$T/logs/ALERTS.log" && ok || bad "A6 alert text: $(cat "$T/logs/ALERTS.log")"

# =============================================================================
# E — the evidence block
# =============================================================================
ES="$DIR/bin/evidence-summary.sh"
if [ -n "$NSOK" ]; then
  E1=$(bash "$ES" "$T/builds/a2" 2 "" 2>&1)
  E1ROW=$(grep '^| egress allowlist |' <<<"$E1")
  [ -n "$E1ROW" ] && ok || bad "E1 no egress allowlist row: $(tail -5 <<<"$E1")"
  grep -q 'execute: enforced' <<<"$E1ROW" && ok || bad "E1 row state: $E1ROW"
  grep -qF '`unlisted.example:443` (execute)' <<<"$E1ROW" && ok || bad "E1 row does not list the refusal: $E1ROW"
  grep -qF '1 refused' <<<"$E1ROW" && ok || bad "E1 row count: $E1ROW"
else nsskip E1; fi
E2ROW=$(bash "$ES" "$T/builds/a6" 2 "" 2>&1 | grep '^| egress allowlist |')
grep -qF 'execute: NOT ENFORCED (unshare-refused)' <<<"$E2ROW" && ok || bad "E2 row: '$E2ROW'"
# E3 — no state file: the render is byte-identical to the script before this change
mkdir -p "$T/e3" "$T/esold"
cp "$DIR/bin/size-scope.sh" "$T/esold/" 2>/dev/null
if git -C "$DIR" show 46a346c408027b93b49e92f64dab8e1bfd8ceff2:bin/evidence-summary.sh > "$T/esold/evidence-summary.sh" 2>/dev/null; then
  for m in "" --json; do
    NEW=$(bash "$ES" $m "$T/e3" 2 "why" 2>&1); OLD=$(bash "$T/esold/evidence-summary.sh" $m "$T/e3" 2 "why" 2>&1)
    [ "$NEW" = "$OLD" ] && ok || bad "E3 ${m:-table} render changed with no egress-state.txt: $(diff <(echo "$OLD") <(echo "$NEW") | head -5)"
  done
else skip "E3 byte-compare (the pre-change blob is not in this clone)"; fi
grep -q 'egress' <<<"$(bash "$ES" "$T/e3" 2 "" 2>&1)" && bad "E3 an egress row with no state file" || ok

# =============================================================================
# S — the seeded rows (node --test), when node is here
# =============================================================================
SEED_TEST="$DIR/worker/jobs/test/egress-seed.bh-4492.test.js"
[ -r "$SEED_TEST" ] && ok || bad "S $SEED_TEST missing"
if command -v node >/dev/null 2>&1; then
  S=$(cd "$DIR/worker/jobs" && node --test test/egress-seed.bh-4492.test.js 2>&1); SRC=$?
  [ "$SRC" = 0 ] && ok || bad "S node --test egress-seed rc=$SRC: $(tail -20 <<<"$S")"
else skip "S node missing"; fi

echo "egress-allowlist-test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
