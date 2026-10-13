#!/bin/bash
# tests/ssh-forward-hardening-test.sh — bin/poll-commands.sh hands nothing to
# another box over ssh any more (BH-2657), and a hostile console value that
# rides the replacement (a box_console_commands row) stays DATA.
#
# Section 1 is a file-wide invariant read from the SOURCE on purpose: its value
# is catching the ssh call somebody adds next year. Section 2 does not settle
# for a string: it runs the handler blocks extracted verbatim against a stub
# jobs worker, and an injection would announce itself by a file on disk.
# Run from anywhere: tests/ssh-forward-hardening-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/poll-commands.sh"
mkdir -p "$T/bin" "$T/logs" "$T/fakebin"
cd "$T" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- 1. no ssh or scp hand-off is left ----------
# The eight sites (seven handlers) became box_console_commands rows. A new ssh
# forward would bring back everything BH-2528 removed: a remote shell string
# built from console values, and a poller that waits on a far sshd while it
# holds poller.lock.
N=$(grep -cE '\b(ssh|scp)\b +-o|timeout [0-9]+ (ssh|scp)' "$SRC")
[ "$N" = 0 ] && ok || bad "bin/poll-commands.sh has $N ssh/scp hand-off(s):
$(grep -nE '\b(ssh|scp)\b +-o|timeout [0-9]+ (ssh|scp)' "$SRC")"
ROOTAT=$(grep -n 'root@' "$SRC" || true)
[ -z "$ROOTAT" ] && ok || bad "bin/poll-commands.sh still names root@<box>:
$ROOTAT"
# Sanity: the pattern above does find an ssh hand-off when there is one, so a
# zero is a real zero and not a grep that matches nothing.
printf '        timeout 30 ssh -o ConnectTimeout=10 "root@$BOX" true\n' > "$T/probe.sh"
[ "$(grep -cE '\b(ssh|scp)\b +-o|timeout [0-9]+ (ssh|scp)' "$T/probe.sh")" = 1 ] \
  && ok || bad "the ssh pattern no longer matches an ssh line — is this test still looking at the right thing?"

# ---------- 2. hostile values ride the row as JSON data ----------
cp -r "$DIR/bin/lib" "$T/bin/lib"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$T/bin/"
cat > "$T/fleet.conf" <<'EOF'
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
for s in ssh scp; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> %s/SSH.calls\nexit 0\n' "$s" "$T" > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"
done
# Stub jobs worker: record {method,url,body}, answer 200.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$BODY" | jq -Rsc --arg m "$METHOD" --arg u "$URL" '{method:$m, url:$u, body:.}' >> "$REQ_SINK"
printf '{"created":true}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ntrue\n' > "$T/bin/product-cmd.sh"; chmod +x "$T/bin/product-cmd.sh"
printf '#!/bin/bash\ntrue\n' > "$T/bin/run-triage.sh"; chmod +x "$T/bin/run-triage.sh"

extract() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$SRC" | sed -e "1s/^    ${1})//" -e '$s/ ;;$//'
}
for H in run_triage update_company_map; do
  extract "$H" > "$T/$H.body"
  [ -s "$T/$H.body" ] || { echo "FAIL: could not extract $H — markers missing?"; exit 1; }
done

run() { # run <handler> <project> <payload>
  HARNESS="$T" BEAT="$T/bin/beat.sh" ID=c1 PROJECT="$2" TYPE="$1" PAYLOAD="$3" OK=false RESULT="" \
    PATH="$T/fakebin:$PATH" REQ_SINK="$T/REQ.log" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
      . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$HARNESS/bin/lib/cron-lines.sh"
      . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/$1.body"
}
body() { jq -r 'select(.url|endswith("/api/box-console-commands"))|.body' "$T/REQ.log"; }

# A project crafted to survive box-for.sh: fleet-conf.sh looks its row up with a
# REGEX, so an alternation whose FIRST branch is a real project resolves to that
# project's box while the rest of the string rides along. Content and project
# both carry the shell metacharacters that used to reach a remote shell.
HOSTILE_P="remote-os|x; touch $T/PWNED; \`touch $T/PWNED\`"
HOSTILE_C="\$(touch $T/PWNED); echo x > $T/PWNED; \`touch $T/PWNED\`"
PL=$(jq -nc --arg c "$HOSTILE_C" '{content:$c}')
for H in run_triage update_company_map; do
  rm -f "$T/PWNED"; : > "$T/SSH.calls"; : > "$T/REQ.log"
  OUT=$(run "$H" "$HOSTILE_P" "$PL" 2>&1)
  # A detached launch would land a moment later; wait before trusting a miss.
  for _ in $(seq 1 20); do [ -f "$T/PWNED" ] && break; sleep 0.05; done
  [ -f "$T/PWNED" ] && bad "$H: INJECTED COMMAND EXECUTED (out=$OUT)" || ok
  [ -s "$T/SSH.calls" ] && bad "$H: ssh/scp called: $(cat "$T/SSH.calls")" || ok
  B=$(body)
  [ "$(grep -c . <<<"$B")" = 1 ] \
    && [ "$(jq -r .project <<<"$B")" = "$HOSTILE_P" ] \
    && [ "$(jq -r .payload <<<"$B")" = "$PL" ] \
    && [ "$(jq -r .box <<<"$B")" = remote ] \
    && ok || bad "$H: the hostile values must arrive as JSON data in exactly one POST (out=$OUT body=$B)"
done

# The same handlers queue a real project, and say queued, not launched.
for H in run_triage update_company_map; do
  : > "$T/SSH.calls"; : > "$T/REQ.log"
  OUT=$(run "$H" remote-os '{"content":"a map"}')
  grep -q 'OK=true RESULT=queued for box-remote' <<<"$OUT" && [ "$(body | grep -c .)" = 1 ] && [ ! -s "$T/SSH.calls" ] \
    && ok || bad "$H: a legitimate project must be queued (out=$OUT)"
done

echo "ssh-forward-hardening-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
