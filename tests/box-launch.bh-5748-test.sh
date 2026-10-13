#!/bin/bash
# tests/box-launch.bh-5748-test.sh — bin/box-launch.sh makes one Orgo box, puts
# the harness on it, registers it, bootstraps it and smokes it, and never buys
# a second computer.
#
# Runs the REAL bin/box-launch.sh with the REAL Orgo seam in a scratch repo
# root (fleet.conf, a fixture catalog/orgo-plans.json, a stub box-register.sh,
# a git origin) and a scratch harness root. Stubbed: curl (plays Orgo, keeps a
# computer list), ssh and scp (play the box under $T/box), box-register.sh.
#   A1  short ram pool: NEEDS PURCHASE, rc 3, no POST
#   A2  create 403 RAM_ADDON: NEEDS PURCHASE, rc 3, no orgo_id
#   A3  dry run: only GET /computers, no ssh, no state, PLAN lines, summary
#   A4  --apply with no / a wrong --confirm-monthly-usd: COST line, rc 2, no call
#   A5  a re-run after a failure at the tailnet step: still one POST
#   A6  lost state: the computer is adopted by name, still one POST
#   A7  happy path: summary, ssh order, envfile match, register argv, no secret
#   A8  register not merged: WAITING, rc 4, no bootstrap
#   A9  env differ: rc 1, no migrate
#   A10 smoke fail: rc 1, smoke=FAIL
#   A11 second full run: no POST, no scp
#   A12 refusals: rc 2, no Orgo call
#   A13 the repo's catalog/orgo-plans.json parses and has the plan fields
#   A14 unreadable list, list HTTP 500, 2xx with no id, running timeout,
#       ghapp rc 3, lock held
#   A15 harness: the clone gets the hub-minted token; no token = rc 1; a
#       harness-sync failure = rc 1 and no stamp
#   A16 a stale capacity stamp with no orgo_id re-reads the pool; a dry run
#       for a name already on the account plans an adopt, not a POST
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

[ -f "$DIR/bin/box-launch.sh" ] || { echo "FAIL: missing $DIR/bin/box-launch.sh"; exit 1; }
R="$T/repo"; H="$T/h"
mkdir -p "$R/bin" "$R/catalog" "$H/env" "$T/fakebin" "$T/box/env" "$T/orgo"
scratch_install_closure bin/box-launch.sh "$R" >/dev/null || { echo "FAIL: closure install"; exit 1; }

cat > "$R/catalog/orgo-plans.json" <<'EOF'
{"accounts": {
  "fixture-acct": {"plan": "startup_v2", "key_env": "ORGO_API_KEY", "template_ref": "tpl-fixture",
    "cost_account": "fixture-cost", "register_like": "project-6-os",
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": 10, "vcpus": 40, "ram_gb": 32, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}},
  "fixture-notpl": {"plan": "startup_v2", "key_env": "ORGO_API_KEY", "template_ref": null,
    "cost_account": "fixture-cost", "register_like": null,
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": 10, "vcpus": 40, "ram_gb": 32, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}},
  "fixture-nopool": {"plan": "startup_v2", "key_env": "ORGO_API_KEY", "template_ref": "tpl-fixture",
    "cost_account": "fixture-cost", "register_like": null,
    "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
    "pool": {"computers": null, "vcpus": null, "ram_gb": null, "disk_gb": null},
    "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
    "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}}
}}
EOF

# box-register stub: logs its argv, writes nothing.
cat > "$R/bin/box-register.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/register.log"
echo "NEXT: git add fleet.conf"
exit "${STUB_REG_RC:-0}"
EOF
chmod +x "$R/bin/box-register.sh"

# gh-token stub: the hub's short-lived token for the harness clone.
cat > "$R/bin/gh-token.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/ghtoken.log"
[ -n "${STUB_GHTOKEN_EMPTY:-}" ] && exit 1
echo fixture-ghtoken-555
EOF
chmod +x "$R/bin/gh-token.sh"

# alert-line stub: the real helper also beats; this one only appends the line.
cat > "$R/bin/alert-line.sh" <<'EOF'
#!/bin/bash
while [ "${1:-}" = --project ] || [ "${1:-}" = --severity ] || [ "${1:-}" = --id ]; do shift 2; done
mkdir -p "$HARNESS/logs" && printf 'fixture-ts %s\n' "$*" >> "$HARNESS/logs/ALERTS.log"
EOF
chmod +x "$R/bin/alert-line.sh"

# The box's address must be in 100.64/10: bin/box-launch.sh's tailnet step
# accepts nothing else, so an RFC 5737 fixture cannot stand in here. The values
# are assembled at run time (D64, bin/fixture-hygiene.sh).
TSIP="100.$((64)).0.77"; OLDIP="100.$((64)).0.5"; export STUB_TS_IP="$TSIP"

# Git: origin-no main does not name the box; origin-yes main does.
G() { git -C "$R" -c user.name=fixture -c user.email=fixture@example.com "$@"; }
printf 'widget-os acme/widget - - 1 node-old %s\n' "$OLDIP" > "$R/fleet.conf"
G init -q -b main && G add fleet.conf && G commit -qm no || { echo "FAIL: git fixture"; exit 1; }
git init -q --bare "$T/origin-no.git"; git init -q --bare "$T/origin-yes.git"
G remote add origin "$T/origin-no.git" && G push -q origin main || { echo "FAIL: git push no"; exit 1; }
printf 'widget-os acme/widget - - 1 node-newbox %s\n' "$TSIP" > "$R/fleet.conf"
G commit -qam yes && G push -q "$T/origin-yes.git" main && G reset -q --hard HEAD~1 || { echo "FAIL: git push yes"; exit 1; }

printf 'FIXTURE_TOKEN=fixture-global-secret\n' > "$H/env/global.env"
printf 'W=fixture-widget-secret\n' > "$H/env/widget-os.env"
printf 'APP=fixture-app-secret\n' > "$H/env/github-app.env"
printf 'ssh-ed25519 AAAAC3fixture hub@fixture\n' > "$T/hub.pub"

# curl playing Orgo. seq.log gets "METHOD PATH"; bodies.log the request bodies.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET url="" data=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift ;;
    --data-binary) data=1; shift ;;
    -m|-H|-w) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
body=""
[ "$data" = 1 ] && body=$(cat)
p=${url#*://*/api}
L="$STUB_DIR/orgo/list.json"
printf '%s %s\n' "$m" "$p" >> "$STUB_DIR/seq.log"
[ -n "$body" ] && printf '%s %s %s\n' "$m" "$p" "$body" >> "$STUB_DIR/bodies.log"
case "$m $p" in
  "GET /computers")
    printf '%s\n%s' "${STUB_LIST_RAW:-$(cat "$L")}" "${STUB_LIST_CODE:-200}" ;;
  "POST /computers")
    if [ -n "${STUB_POST_BODY:-}" ]; then printf '%s\n%s' "$STUB_POST_BODY" "${STUB_POST_CODE:-200}"; exit 0; fi
    jq --argjson b "$body" '. + [{id: "c-fixture-1", name: $b.name, cpu: $b.cpu, ram: $b.ram, status: "running"}]' "$L" > "$L.t" && mv "$L.t" "$L"
    printf '%s\n%s' '{"id":"c-fixture-1"}' 200 ;;
  "POST /computers/"*/bash)
    out="" rc=0
    if [[ "$body" == *"tailscale ip -4"* ]]; then
      if [ -n "${STUB_TS_FAIL:-}" ]; then out="tailscale: not logged in"; rc=1; else out="started"$'\n'"$STUB_TS_IP"; fi
    fi
    printf '%s\n%s' "$(jq -nc --arg o "$out"$'\n'"__RC=$rc" '{output: $o}')" 200 ;;
  "GET /computers/"*)
    printf '{"status":"%s"}\n%s' "${STUB_STATUS:-RUNNING}" 200 ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
EOF
# ssh playing the box. ssh.log gets "SSH <command>" and "  | <stdin line>".
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift  # root@<ip>
cmd="$*" in=""
printf 'SSH %s\n' "$cmd" >> "$STUB_DIR/ssh.log"
# The harness step: token on the first stdin line, then the script. The token
# goes to the box record, never to ssh.log. The script runs for real with
# /root/ mapped to $STUB_DIR/boxroot/ and box-only gh/git/harness-sync stubs.
if [[ "$cmd" == "IFS= read -r GH_TOKEN && export GH_TOKEN && exec bash -s -- "* ]]; then
  IFS= read -r tok; printf '%s\n' "$tok" > "$STUB_DIR/box/token-received"
  in=$(cat); printf '%s\n' "$in" | sed 's/^/  | /' >> "$STUB_DIR/ssh.log"
  mkdir -p "$STUB_DIR/boxroot"
  printf '%s\n' "$in" | sed "s#/root/#$STUB_DIR/boxroot/#g" \
    | GH_TOKEN="$tok" PATH="$STUB_DIR/boxbin:$PATH" bash -s -- "${cmd##* }"
  exit $?
fi
if [ "${1:-}" = bash ] && [ "${2:-}" = -s ]; then
  in=$(cat); printf '%s\n' "$in" | sed 's/^/  | /' >> "$STUB_DIR/ssh.log"
fi
case "$cmd" in
  true) exit "${STUB_SSH_TRUE_RC:-0}" ;;
  *"bin/lib/env-path.sh && harness_env_dir /root/harness") echo /root/harness/env ;;
  "sha256sum /root/harness/env/"*)
    f="$STUB_DIR/box/env/${cmd##*/}"; [ -f "$f" ] || exit 1
    printf '%s  /root/harness/env/%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${cmd##*/}" ;;
  *migrate-env-dir.sh*) exit "${STUB_MIGRATE_RC:-0}" ;;
  *ensure-box-gh-app-default.sh*) exit "${STUB_GHAPP_RC:-0}" ;;
esac
case "$in" in
  *bootstrap-machine.sh*) exit "${STUB_BOOT_RC:-0}" ;;
  *SMOKE_PASS*) if [ -n "${STUB_SMOKE_FAIL:-}" ]; then echo "smoke sshd FAIL"; exit 1; fi; echo SMOKE_PASS ;;
esac
exit 0
EOF
cat > "$T/fakebin/scp" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
name=${2##*/}
printf 'SCP %s\n' "$name" >> "$STUB_DIR/ssh.log"
cp "$1" "$STUB_DIR/box/env/$name" || exit 1
[ -n "${STUB_SCP_CORRUPT:-}" ] && printf 'x\n' >> "$STUB_DIR/box/env/$name"
exit 0
EOF
# Box-only gh, git and the box's harness-sync: each records whether the
# credential env it ran with carries the token.
mkdir -p "$T/boxbin"
cat > "$T/boxbin/gh" <<'EOF'
#!/bin/bash
printf 'gh %s token=%s helper=%s\n' "$1 $2" "${GH_TOKEN:-none}" "${GIT_CONFIG_VALUE_1:-none}" >> "$STUB_DIR/box/cred.log"
[ "$1 $2" = "repo clone" ] || exit 1
mkdir -p "$4/.git" "$4/bin" "$4/prompts" && : > "$4/fleet.conf"
EOF
cat > "$T/boxbin/git" <<'EOF'
#!/bin/bash
printf 'git %s token=%s\n' "$*" "${GH_TOKEN:-none}" >> "$STUB_DIR/box/cred.log"
exit 0
EOF
chmod +x "$T/boxbin/gh" "$T/boxbin/git"
chmod +x "$T/fakebin/curl" "$T/fakebin/ssh" "$T/fakebin/scp"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_BOX_PREFIX=node- HARNESS_REPO=acme/harness-fixture \
       ORGO_API_BASE=https://orgo.fixture/api BOX_LAUNCH_HUB_PUBKEY="$T/hub.pub" BOX_LAUNCH_POLL_S=1

SEQ="$T/seq.log"; SSHL="$T/ssh.log"; STF="$H/state/box-launch/newbox.json"
ARGS=(newbox --project widget-os --account fixture-acct)
APPLY=(--apply --confirm-monthly-usd 73)   # 1 + 4*10 + 8*4
reset() {
  for d in "$H/state" "$H/logs" "$H/locks" "$T/box/env" "$SEQ" "$SSHL" "$T/bodies.log" "$T/register.log" "$T/ghtoken.log" "$T/boxroot" "$T/box/token-received" "$T/box/cred.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$T/box/env"
  printf '[]\n' > "$T/orgo/list.json"
  unset STUB_LIST_RAW STUB_LIST_CODE STUB_POST_BODY STUB_POST_CODE STUB_TS_FAIL STUB_STATUS STUB_SSH_TRUE_RC \
        STUB_MIGRATE_RC STUB_GHAPP_RC STUB_BOOT_RC STUB_SMOKE_FAIL STUB_SCP_CORRUPT STUB_REG_RC BOX_LAUNCH_DEADLINE_S \
        STUB_GHTOKEN_EMPTY
  export ORGO_API_KEY=fixture-orgo-key BOX_LAUNCH_TS_AUTHKEY=fixture-tskey-123
  G remote set-url origin "$T/origin-yes.git"
}
run() { bash "$R/bin/box-launch.sh" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
n()     { [ -f "$2" ] || { echo 0; return; }; grep -cE "$1" "$2"; return 0; }
nposts() { n '^POST /computers$' "$SEQ"; }
lastl() { tail -n 1 "$T/out"; }
lineno() { grep -nE "$1" "$SSHL" 2>/dev/null | head -1 | cut -d: -f1; }
ctx() { echo "rc=$RC out=[$(cat "$T/out")] err=[$(cat "$T/err")]"; }

# --- A1 short ram pool --------------------------------------------------------
reset
printf '[{"id":"a","name":"x","cpu":4,"ram":16},{"id":"b","name":"y","cpu":4,"ram":12}]\n' > "$T/orgo/list.json"
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 3 ] && ok || bad "A1 $(ctx)"
grep -qxF 'NEEDS PURCHASE: ram-gb 4 $16/mo' "$T/out" && ok || bad "A1 no NEEDS PURCHASE line: $(ctx)"
[ "$(grep -c '^NEEDS PURCHASE' "$T/out")" = 1 ] && ok || bad "A1 only ram is short"
[ "$(nposts)" = 0 ] && ok || bad "A1 POSTed"
[ "$(jq -r '.orgo_id // empty' "$STF" 2>/dev/null)" = "" ] && ok || bad "A1 orgo_id in state"
lastl | grep -q '^box-launch: box=newbox orgo=- ip=- ' && ok || bad "A1 summary not last: $(lastl)"

# --- A2 create 403 RAM_ADDON ---------------------------------------------------
reset
export STUB_POST_BODY='{"error":"RAM_ADDON required"}' STUB_POST_CODE=403
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 3 ] && ok || bad "A2 $(ctx)"
grep -qxF 'NEEDS PURCHASE: ram-gb 8 $32/mo' "$T/out" && ok || bad "A2 no NEEDS PURCHASE ram-gb: $(ctx)"
[ "$(nposts)" = 1 ] && ok || bad "A2 posts=$(nposts)"
[ "$(jq -r '.orgo_id // empty' "$STF" 2>/dev/null)" = "" ] && ok || bad "A2 orgo_id in state"

# --- A3 dry run makes no POST --------------------------------------------------
reset
run "${ARGS[@]}"
[ "$RC" = 0 ] && ok || bad "A3 $(ctx)"
[ "$(cat "$SEQ" 2>/dev/null)" = "GET /computers" ] && ok || bad "A3 Orgo calls=[$(cat "$SEQ" 2>/dev/null)]"
[ ! -s "$SSHL" ] && ok || bad "A3 ssh was called"
[ ! -e "$H/state/box-launch" ] && [ ! -e "$H/locks" ] && ok || bad "A3 dry run wrote state or a lock"
grep -q '^PLAN create POST /computers name=node-newbox specs=4c/8gb/-gb \$73/mo' "$T/out" && ok || bad "A3 no PLAN create: $(ctx)"
[ "$(grep -c '^PLAN ' "$T/out")" = 12 ] && ok || bad "A3 want 12 PLAN lines (every step but capacity): $(ctx)"
[ "$(lastl)" = "box-launch: box=newbox orgo=- ip=- specs=4c/8gb/-gb usd_mo=73 smoke=PENDING" ] && ok || bad "A3 summary=[$(lastl)]"
[ ! -s "$T/register.log" ] && ok || bad "A3 box-register was called"
# no key: no call at all, and still a plan
unset ORGO_API_KEY
run "${ARGS[@]}"
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && [ "$(n . "$SEQ")" = 1 ] && grep -q '^PLAN capacity not read (ORGO_API_KEY unset)' "$T/out" \
  && ok || bad "A3 no-key dry run: $(ctx)"

# --- A4 apply without / with a wrong confirm -----------------------------------
for c in none 72 abc; do
  reset
  if [ "$c" = none ]; then run "${ARGS[@]}" --apply; else run "${ARGS[@]}" --apply --confirm-monthly-usd "$c"; fi
  [ "$RC" = 2 ] && ok || bad "A4 confirm=$c $(ctx)"
  grep -qxF 'COST: box newbox $73/mo — re-run with --confirm-monthly-usd 73' "$T/out" && ok || bad "A4 confirm=$c no COST line: $(ctx)"
  [ ! -s "$SEQ" ] && ok || bad "A4 confirm=$c called Orgo: $(cat "$SEQ")"
done

# --- A5 re-run after a failure at the tailnet step -----------------------------
reset
export STUB_TS_FAIL=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && ok || bad "A5 run1 $(ctx)"
[ "$(nposts)" = 1 ] && ok || bad "A5 run1 posts=$(nposts)"
[ "$(jq -r .orgo_id "$STF" 2>/dev/null)" = c-fixture-1 ] && ok || bad "A5 orgo_id not persisted"
lastl | grep -q '^box-launch: box=newbox orgo=c-fixture-1 ip=- ' && ok || bad "A5 run1 summary=[$(lastl)]"
unset STUB_TS_FAIL
run "${ARGS[@]}" --apply
[ "$RC" = 0 ] && ok || bad "A5 run2 (no confirm needed once created) $(ctx)"
[ "$(nposts)" = 1 ] && ok || bad "A5 second computer bought: posts=$(nposts)"

# --- A6 lost state: adopted by name --------------------------------------------
reset
export STUB_TS_FAIL=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && [ "$(nposts)" = 1 ] && ok || bad "A6 run1 $(ctx)"
rm -f "$STF"
unset STUB_TS_FAIL
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 0 ] && ok || bad "A6 run2 $(ctx)"
[ "$(nposts)" = 1 ] && ok || bad "A6 second computer bought: posts=$(nposts)"
[ "$(jq -r .orgo_id "$STF" 2>/dev/null)" = c-fixture-1 ] && ok || bad "A6 state orgo_id=$(jq -r .orgo_id "$STF" 2>/dev/null)"

# --- A7 happy path -------------------------------------------------------------
reset
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 0 ] && ok || bad "A7 $(ctx)"
[[ "$(lastl)" =~ ^box-launch:\ box=newbox\ orgo=c-fixture-1\ ip=100\.64\.0\.77\ specs=4c/8gb/-gb\ usd_mo=[0-9]+\ smoke=PASS$ ]] \
  && ok || bad "A7 summary=[$(lastl)]"
post=$(grep '^POST /computers {' "$T/bodies.log" | sed 's#^POST /computers ##')
jq -e '.name=="node-newbox" and .template_ref=="tpl-fixture" and .cpu==4 and .ram==8 and (has("disk")|not)' <<< "$post" >/dev/null 2>&1 \
  && ok || bad "A7 create body=[$post]"
grep -q '^POST /computers/c-fixture-1/bash .*tailscale up' "$T/bodies.log" && ok || bad "A7 no tailscale up"
grep -q '^POST /computers/c-fixture-1/bash .*authorized_keys' "$T/bodies.log" && ok || bad "A7 no authorized_keys"
[ "$(jq -r .ip "$STF")" = "$TSIP" ] && ok || bad "A7 state ip"
a=$(lineno 'gh repo clone|pull --ff-only'); b=$(lineno '^SCP global.env$'); c=$(lineno 'migrate-env-dir.sh')
d=$(lineno 'ensure-box-gh-app-default.sh widget-os'); e=$(lineno 'bootstrap-machine.sh'); f=$(lineno 'SMOKE_PASS')
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] && [ -n "$f" ] \
  && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && [ "$e" -lt "$f" ] \
  && ok || bad "A7 ssh order a=$a b=$b c=$c d=$d e=$e f=$f"
for x in global.env widget-os.env github-app.env; do
  grep -qxF "envfile $x match" "$T/out" && ok || bad "A7 no 'envfile $x match'"
done
grep -q 'github-app.pem' "$SSHL" && bad "A7 copied an absent optional file" || ok
grep -q '^SSH \. /root/harness/bin/lib/env-path.sh && harness_env_dir /root/harness$' "$SSHL" && ok || bad "A7 the box env dir must come from the box's resolver"
[ "$(cat "$T/register.log")" = "newbox --ip $TSIP --project widget-os --account fixture-cost --like project-6-os --root $R --apply" ] \
  && ok || bad "A7 register argv=[$(cat "$T/register.log")]"
grep -q '^NEXT: git add' "$T/out" && ok || bad "A7 box-register output not passed through"
[ "$(cat "$T/box/token-received" 2>/dev/null)" = fixture-ghtoken-555 ] && ok || bad "A7 the box did not get the hub token"
[ "$(cat "$T/ghtoken.log" 2>/dev/null)" = "$HARNESS_REPO" ] && ok || bad "A7 gh-token argv=[$(cat "$T/ghtoken.log" 2>/dev/null)]"
grep -qxF 'gh repo clone token=fixture-ghtoken-555 helper=!gh auth git-credential' "$T/box/cred.log" 2>/dev/null \
  && ok || bad "A7 the clone ran without the credential: [$(cat "$T/box/cred.log" 2>/dev/null)]"
[ -f "$T/boxroot/harness/fleet.conf" ] && ok || bad "A7 the harness was not copied into the box runtime"
leak=$(grep -rlE 'fixture-ghtoken|fixture-tskey|fixture-global-secret|fixture-widget-secret|fixture-app-secret|fixture-orgo-key' \
       "$T/out" "$T/err" "$H/logs" "$H/state" "$SSHL" 2>/dev/null)
[ -z "$leak" ] && ok || bad "A7 a secret leaked into: $leak"
grep -q '[0-9a-f]\{64\}' "$T/out" "$T/err" && bad "A7 a hash was printed" || ok
for s in capacity create running tailnet hubkey harness envfiles migrate ghapp register merged bootstrap smoke; do
  jq -e --arg s "$s" '.steps[$s]' "$STF" >/dev/null 2>&1 || bad "A7 step $s not stamped"
done
[ "$(jq -r .smoke "$STF")" = PASS ] && ok || bad "A7 smoke not recorded"
grep -q '^box-launch:newbox:tailnet rc=0$' "$H/logs/restore-drill.log" && ok || bad "A7 Orgo bash rc line missing"

# --- A11 second full run --------------------------------------------------------
rm -f "$SEQ" "$SSHL" "$T/register.log"
unset ORGO_API_KEY BOX_LAUNCH_TS_AUTHKEY
run "${ARGS[@]}" --apply
[ "$RC" = 0 ] && ok || bad "A11 $(ctx)"
[ ! -s "$SEQ" ] && [ ! -s "$SSHL" ] && [ ! -s "$T/register.log" ] && ok || bad "A11 a done step ran again"
[[ "$(lastl)" == *" smoke=PASS" ]] && [ "$(wc -l < "$T/out")" = 1 ] && ok || bad "A11 out=[$(cat "$T/out")]"

# --- A8 register not merged ------------------------------------------------------
reset
G remote set-url origin "$T/origin-no.git"
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 4 ] && ok || bad "A8 $(ctx)"
grep -q '^WAITING: commit the box-register change' "$T/out" && ok || bad "A8 no WAITING line"
grep -q 'bootstrap-machine.sh' "$SSHL" && bad "A8 bootstrap ran before the merge" || ok
lastl | grep -qF "ip=$TSIP " && lastl | grep -q ' smoke=PENDING$' && ok || bad "A8 summary=[$(lastl)]"
G remote set-url origin "$T/origin-yes.git"
run "${ARGS[@]}" --apply
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && [ "$(n . "$T/register.log")" = 1 ] && ok || bad "A8 resume after merge $(ctx)"

# --- A9 env differ ----------------------------------------------------------------
reset
export STUB_SCP_CORRUPT=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && ok || bad "A9 $(ctx)"
grep -qxF 'envfile global.env differ' "$T/out" && ok || bad "A9 no differ line"
grep -q 'migrate-env-dir.sh' "$SSHL" && bad "A9 migrate ran after a differ" || ok
jq -e '.steps.envfiles' "$STF" >/dev/null 2>&1 && bad "A9 envfiles stamped" || ok

# --- A10 smoke fail ---------------------------------------------------------------
reset
export STUB_SMOKE_FAIL=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && ok || bad "A10 $(ctx)"
lastl | grep -q ' smoke=FAIL$' && ok || bad "A10 summary=[$(lastl)]"
grep -q 'smoke sshd FAIL' "$T/out" && ok || bad "A10 failing check not shown"

# --- A12 refusals: rc 2 and no Orgo call -------------------------------------------
refuse_case() {  # <label> <args...>
  local l="$1"; shift
  rm -f "$SEQ"
  run "$@"
  [ "$RC" = 2 ] && ok || bad "A12 $l $(ctx)"
  [ ! -s "$SEQ" ] && ok || bad "A12 $l called Orgo"
}
reset
refuse_case "hyphen id" new-box --project widget-os --account fixture-acct "${APPLY[@]}"
refuse_case "hub id" hub --project widget-os --account fixture-acct "${APPLY[@]}"
refuse_case "vcpus 8" "${ARGS[@]}" --vcpus 8 "${APPLY[@]}"
refuse_case "vcpus 0" "${ARGS[@]}" --vcpus 0 "${APPLY[@]}"
refuse_case "vcpus abc" "${ARGS[@]}" --vcpus abc
refuse_case "mem 6" "${ARGS[@]}" --mem-gb 6 "${APPLY[@]}"
refuse_case "disk with no price" "${ARGS[@]}" --disk-gb 50
refuse_case "unknown account" newbox --project widget-os --account fixture-nope "${APPLY[@]}"
refuse_case "unknown project" newbox --project nope-os --account fixture-acct "${APPLY[@]}"
refuse_case "null template_ref" newbox --project widget-os --account fixture-notpl "${APPLY[@]}"
refuse_case "null pool" newbox --project widget-os --account fixture-nopool "${APPLY[@]}"
unset BOX_LAUNCH_TS_AUTHKEY
refuse_case "no tailscale key" "${ARGS[@]}" "${APPLY[@]}"
export BOX_LAUNCH_TS_AUTHKEY=fixture-tskey-123
BOX_LAUNCH_HUB_PUBKEY="$T/none.pub" refuse_case "no hub pubkey" "${ARGS[@]}" "${APPLY[@]}"
mkdir -p "$H/state/box-launch"
printf '{"id":"newbox","project":"other-os","account":"fixture-acct","orgo_id":"c-other","specs":{"vcpus":4,"mem_gb":8,"disk_gb":null},"steps":{"create":"t"}}\n' > "$STF"
refuse_case "state mismatch" "${ARGS[@]}" "${APPLY[@]}"
grep -q 'state says' "$T/err" && ok || bad "A12 state mismatch message"
[ "$(jq -r .project "$STF")" = other-os ] && ok || bad "A12 state mismatch rewrote the state"
# dry run on a null pool / null template still plans, and says --apply refuses
reset
run newbox --project widget-os --account fixture-nopool
[ "$RC" = 0 ] && [ ! -s "$SEQ" ] && grep -q '^PLAN --apply refuses until configured: pool computers vcpus ram_gb not recorded' "$T/out" \
  && ok || bad "A12 dry run null pool $(ctx)"

# --- A13 the repo's catalog --------------------------------------------------------
REAL="$DIR/catalog/orgo-plans.json"
jq -e '.accounts | length > 0' "$REAL" >/dev/null 2>&1 && ok || bad "A13 $REAL does not parse"
jq -e '.accounts[] | has("plan") and has("key_env") and has("template_ref") and has("cost_account") and has("register_like")
       and .limits.max_vcpus_per_computer == 4 and .limits.ram_tiers_gb == [4,8,16,32]
       and (.pool | has("computers") and has("vcpus") and has("ram_gb") and has("disk_gb"))
       and .prices_usd_mo.computer == 1 and .prices_usd_mo.vcpu == 10 and .prices_usd_mo.ram_gb == 4
       and (.defaults | has("vcpus") and has("mem_gb") and has("disk_gb"))' "$REAL" >/dev/null 2>&1 \
  && ok || bad "A13 a plan field is missing or wrong"
missing=$(jq -r --slurpfile c "$DIR/catalog/cost-accounts.json" '.accounts[].cost_account | . as $k | select(($c[0].accounts | has($k)) | not)' "$REAL")
[ -z "$missing" ] && ok || bad "A13 cost_account not in catalog/cost-accounts.json: $missing"
# The real catalog drives a real dry run: it plans and refuses --apply on its nulls.
cp "$REAL" "$R/catalog/orgo-plans.json.real"
acct=$(jq -r '.accounts | keys[0]' "$REAL")
mv "$R/catalog/orgo-plans.json" "$R/catalog/orgo-plans.json.fixture"; cp "$REAL" "$R/catalog/orgo-plans.json"
reset
run newbox --project widget-os --account "$acct"
[ "$RC" = 0 ] && lastl | grep -q 'specs=4c/8gb/-gb usd_mo=73 smoke=PENDING$' && ok || bad "A13 real catalog dry run $(ctx)"
run newbox --project widget-os --account "$acct" "${APPLY[@]}"
[ "$RC" = 2 ] && grep -q 'not configured: .*template_ref not recorded' "$T/err" && [ ! -s "$SEQ" ] && ok || bad "A13 real catalog apply $(ctx)"
mv "$R/catalog/orgo-plans.json.fixture" "$R/catalog/orgo-plans.json"; rm -f "$R/catalog/orgo-plans.json.real"

# --- A14 failure paths ---------------------------------------------------------------
reset
export STUB_LIST_RAW='{"items":[]}'
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'unreadable computer list' "$T/err" && ok || bad "A14 unknown list shape $(ctx)"
export STUB_LIST_RAW='[{"id":"a","name":"x","ram":8}]'
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "A14 entry with no cpu read as zero $(ctx)"
unset STUB_LIST_RAW; export STUB_LIST_CODE=500
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'HTTP 500' "$T/err" && ok || bad "A14 list 500 $(ctx)"
reset
export STUB_POST_BODY='{}'
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && [ "$(n 'node-newbox computer may exist' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A14 2xx no id $(ctx)"
[ "$(jq -r '.orgo_id // empty' "$STF" 2>/dev/null)" = "" ] && ok || bad "A14 2xx no id wrote an orgo_id"
reset
export STUB_STATUS=starting BOX_LAUNCH_DEADLINE_S=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && grep -q 'not running after 1s' "$T/err" && ok || bad "A14 running timeout $(ctx)"
[ "$(jq -r .orgo_id "$STF" 2>/dev/null)" = c-fixture-1 ] && ok || bad "A14 timeout lost the orgo_id"
reset
export STUB_GHAPP_RC=3
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 0 ] && [ "$(jq -r .steps.ghapp "$STF")" = "done-warn logout deferred" ] && ok || bad "A14 ghapp rc 3 $(ctx)"
reset
export STUB_GHAPP_RC=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && ! grep -q 'box-launch' "$T/register.log" 2>/dev/null && [ ! -s "$T/register.log" ] && ok || bad "A14 ghapp rc 1 $(ctx)"
reset
mkdir -p "$H/locks"
exec 8>"$H/locks/box-launch-newbox.lock"; flock -n 8
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 0 ] && grep -qx 'box-launch: newbox already running' "$T/out" && [ ! -s "$SEQ" ] && ok || bad "A14 lock held $(ctx)"
exec 8>&-

# --- A15 harness credential and harness-sync rc ---------------------------------------
reset
export STUB_GHTOKEN_EMPTY=1
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && grep -q 'harness: bin/gh-token.sh .* printed no token on the hub' "$T/err" && ok || bad "A15 no token $(ctx)"
[ ! -s "$T/box/cred.log" ] && ! grep -q 'read -r GH_TOKEN' "$SSHL" && ok || bad "A15 no token still reached the box"
jq -e '.steps.harness' "$STF" >/dev/null 2>&1 && bad "A15 no token stamped harness" || ok
unset STUB_GHTOKEN_EMPTY
run "${ARGS[@]}" --apply
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && ok || bad "A15 resume after a token $(ctx)"
reset
mkdir -p "$T/boxroot/harness-checkout/.git" "$T/boxroot/harness/bin"
cat > "$T/boxroot/harness/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
printf 'sync token=%s\n' "${GH_TOKEN:-none}" >> "$STUB_DIR/box/cred.log"
exit 20
EOF
chmod +x "$T/boxroot/harness/bin/harness-sync.sh"
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 1 ] && grep -q 'harness: clone/sync on the box failed' "$T/err" && ok || bad "A15 sync rc 20 $(ctx)"
jq -e '.steps.harness' "$STF" >/dev/null 2>&1 && bad "A15 sync rc 20 stamped harness" || ok
grep -q '^SCP ' "$SSHL" && bad "A15 envfiles ran after a sync failure" || ok
grep -qx 'git -C .*harness-checkout pull --ff-only -q token=fixture-ghtoken-555' "$T/box/cred.log" \
  && grep -qx 'sync token=fixture-ghtoken-555' "$T/box/cred.log" && ok || bad "A15 pull/sync cred=[$(cat "$T/box/cred.log" 2>/dev/null)]"
grep -rqE 'fixture-ghtoken' "$T/out" "$T/err" "$H/logs" "$H/state" "$SSHL" 2>/dev/null && bad "A15 the token leaked" || ok

# --- A16 stale capacity stamp; dry-run adopt --------------------------------------------
reset
mkdir -p "$H/state/box-launch"
jq -n '{id:"newbox", project:"widget-os", account:"fixture-acct", host:"node-newbox", orgo_id:null, ip:null,
        specs:{vcpus:4, mem_gb:8, disk_gb:null}, usd_mo:73, steps:{capacity:"2026-10-09T00:00:00Z"}}' > "$STF"
printf '[{"id":"a","name":"x","cpu":4,"ram":16},{"id":"b","name":"y","cpu":4,"ram":12}]\n' > "$T/orgo/list.json"
run "${ARGS[@]}" "${APPLY[@]}"
[ "$RC" = 3 ] && [ "$(nposts)" = 0 ] && grep -qxF 'NEEDS PURCHASE: ram-gb 4 $16/mo' "$T/out" && ok || bad "A16 stale capacity stamp $(ctx)"
reset
printf '[{"id":"c-9","name":"node-newbox","cpu":4,"ram":8}]\n' > "$T/orgo/list.json"
run "${ARGS[@]}"
[ "$RC" = 0 ] && grep -qx 'PLAN create adopt node-newbox from the Orgo account, no POST' "$T/out" && ok || bad "A16 dry-run adopt $(ctx)"
grep -q '^PLAN create POST' "$T/out" && bad "A16 dry run plans a POST for an adopted name" || ok

echo "box-launch: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
