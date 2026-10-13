#!/bin/bash
# tests/account-pin-probe.bh-3559-test.sh — BH-3559: the pin checks its own work.
#
#   P1 token file -> "<p> <label> ok file", rc 0
#   P2 no file, the PROJECT env's token is labelled with an alias -> "ok live"
#   P3 neither -> UNRESOLVABLE, rc 1; one alert with --alert, none without
#   P4 unpinned and `shared` -> "unpinned", rc 0, no alert
#   P5 no token in stdout or the probe log
#   S1 claude-auth-check's account_pin_sweep: the hub probe runs, ssh goes once
#      to the pinned project's owning box and never to an unpinned one's
#   S2 a pin the owning box cannot resolve -> one alert from that box naming
#      the box and the label
#   S3 ssh rc 127 (probe not deployed) -> could-not-probe, zero alerts
#
# DRIVEN: the real bin/account-pin-probe.sh and the real account_pin_sweep.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PROJECT_3_TOK="sk-ant-oat01-FIXTURE-project-3-box-token"
MK_TOK="sk-ant-oat01-FIXTURE-project-6-token"
fp12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
PROBE="$DIR/bin/account-pin-probe.sh"
echo '{}' > "$T/empty-catalog.json"

# mktree <root> — a harness tree with a lane-alert stub, the real libs, and a
# settings cache pinning project-3 to own:project-3.
mktree() {
  local r="$1"
  mkdir -p "$r/bin" "$r/env/accounts.d" "$r/state" "$r/logs" "$r/catalog"
  ln -sfn "$DIR/bin/lib" "$r/bin/lib"
  ln -sf "$DIR/bin/auth-fingerprint.sh" "$r/bin/auth-fingerprint.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alert-sink"\n' "$r" > "$r/bin/lane-alert.sh"
  printf '#!/bin/bash\nexec bash "%s" "$@"\n' "$PROBE" > "$r/bin/account-pin-probe.sh"
  chmod +x "$r/bin/"*.sh
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$MK_TOK" > "$r/env/global.env"
  cp "$DIR/catalog/account-aliases.json" "$r/catalog/account-aliases.json"
  printf '{"%s":"claude:project-3-dedicated"}\n' "$(fp12 "$PROJECT_3_TOK")" > "$r/state/auth-accounts.local.json"
  cache "$r" '{"account.project-3":"own:project-3"}'
}
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$2" '{fetched_at:$fa,values:$v,seeded:{}}' > "$1/state/settings-cache.json"; }
alerts() { cat "$1/alert-sink" 2>/dev/null | grep -c -- '--severity warn'; }

B="$T/box"; mktree "$B"
probe() { # <harness> [args...] -> stdout; rc in $PRC
  local h="$1"; shift
  OUTP=$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ACCOUNT_OWN_PROJECTS -u HARNESS_ENV_DIR -u ACCOUNT_ALIASES_CATALOG \
    HARNESS="$h" HOME="$h" JOBS_URL= AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" ACCOUNT_PIN_BOX=box-project-3-1 \
    bash "$PROBE" "$@" 2>/dev/null); PRC=$?
}

# ---- P1 file ----------------------------------------------------------------
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$B/env/accounts.d/own:project-3.env"
probe "$B" project-3
[ "$OUTP" = "project-3 own:project-3 ok file" ] && [ "$PRC" = 0 ] && ok || bad "P1 got '$OUTP' rc=$PRC"
rm -f "$B/env/accounts.d/own:project-3.env"

# ---- P2 per-project env token under an alias label ---------------------------
probe "$B" project-3
[ "$OUTP" = "project-3 own:project-3 UNRESOLVABLE" ] && ok || bad "P2 pre: global project-6 alone must not resolve, got '$OUTP'"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$B/env/project-3.env"
probe "$B" project-3
[ "$OUTP" = "project-3 own:project-3 ok live" ] && [ "$PRC" = 0 ] && ok || bad "P2 got '$OUTP' rc=$PRC"
rm -f "$B/env/project-3.env"

# ---- P3 neither ---------------------------------------------------------------
rm -f "$B/alert-sink"
probe "$B" project-3
[ "$OUTP" = "project-3 own:project-3 UNRESOLVABLE" ] && [ "$PRC" = 1 ] && ok || bad "P3 got '$OUTP' rc=$PRC"
[ "$(alerts "$B")" = 0 ] && ok || bad "P3 alerted without --alert"
probe "$B" --alert project-3
[ "$PRC" = 1 ] && ok || bad "P3 --alert rc=$PRC"
[ "$(alerts "$B")" = 1 ] && ok || bad "P3 --alert: $(alerts "$B") alerts"
grep -q -- '--id account-pin-box-project-3-1-project-3 account-pin box-project-3-1: pinned account own:project-3 for project-3 .*(probe)' "$B/alert-sink" \
  && ok || bad "P3 alert text: $(cat "$B/alert-sink" 2>/dev/null)"
# recovery through the probe resolves it
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$B/env/project-3.env"
probe "$B" --alert project-3
grep -q -- '--resolve --id account-pin-box-project-3-1-project-3' "$B/alert-sink" && ok || bad "P3 ok did not resolve"
[ -e "$B/state/account-pin/project-3.alerted" ] && bad "P3 stamp left after resolve" || ok
rm -f "$B/env/project-3.env" "$B/alert-sink"

# ---- P4 unpinned / shared -------------------------------------------------------
probe "$B" --alert project-5-os
[ "$OUTP" = "project-5-os unpinned" ] && [ "$PRC" = 0 ] && ok || bad "P4 got '$OUTP' rc=$PRC"
cache "$B" '{"account.project-3":"shared"}'
probe "$B" --alert project-3
[ "$OUTP" = "project-3 unpinned" ] && [ "$PRC" = 0 ] && ok || bad "P4 shared got '$OUTP' rc=$PRC"
[ "$(alerts "$B")" = 0 ] && ok || bad "P4 alerted on an unpinned project"
cache "$B" '{"account.project-3":"own:project-3"}'

# ---- P5 no token anywhere ---------------------------------------------------------
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$B/env/accounts.d/own:project-3.env"
probe "$B" project-3 project-5-os
for tok in "$PROJECT_3_TOK" "$MK_TOK"; do
  grep -qF "$tok" <<<"$OUTP" && bad "P5 token on stdout" || ok
  grep -qF "$tok" "$B/logs/account-pin-probe.log" "$B/alert-sink" 2>/dev/null && bad "P5 token in the log/alert" || ok
done
[ "$(grep -c 'project-3 own:project-3 ok file' "$B/logs/account-pin-probe.log")" -ge 1 ] && ok || bad "P5 probe log missing lines"
rm -f "$B/env/accounts.d/own:project-3.env"

# ---- S: the hub sweep ---------------------------------------------------------------
HUB="$T/hub"; mktree "$HUB"
mkdir -p "$T/fakebin"
cat > "$HUB/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --projects) printf 'project-3\nproject-5-os\n' ;;
  --tailnet-ip-of-box) case "$2" in box-project-3-1) echo 192.0.2.2 ;; box-project-5-1) echo 192.0.2.3 ;; esac ;;
esac
EOF
cat > "$HUB/bin/box-for.sh" <<'EOF'
#!/bin/bash
case "$1" in project-3) echo box-project-3-1 ;; project-5-os) echo box-project-5-1 ;; *) exit 1 ;; esac
EOF
# fake ssh: records the target, then runs the command on the scratch box tree.
cat > "$T/fakebin/ssh" <<EOF
#!/bin/bash
while [ "\${1:-}" = -o ]; do shift 2; done
printf '%s %s\n' "\$1" "\$2" >> "$T/ssh-sink"
[ -n "\${SSH_RC:-}" ] && exit "\$SSH_RC"
cmd="\${2/\/root\/harness\/bin\/account-pin-probe.sh/bash $PROBE}"
env -u CLAUDE_CODE_OAUTH_TOKEN HARNESS="$B" HOME="$B" ACCOUNT_PIN_BOX=box-project-3-1 bash -c "\$cmd"
EOF
chmod +x "$HUB/bin/"*.sh "$T/fakebin/ssh"
sweep() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HUB" HOME="$HUB" JOBS_URL= AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" ACCOUNT_PIN_BOX=hub "$@"
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ACCOUNT_OWN_PROJECTS HARNESS_ENV_DIR ACCOUNT_ALIASES_CATALOG
    AUTH_CHECK_LIB=1 . "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1
    command -v account_pin_sweep >/dev/null || { echo "no account_pin_sweep" >&2; exit 9; }
    account_pin_sweep ) >/dev/null 2>&1
  echo $?
}

# S1: the hub holds the token file; the owning box resolves live via its project env
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$HUB/env/accounts.d/own:project-3.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$B/env/project-3.env"
rm -f "$T/ssh-sink" "$B/alert-sink" "$HUB/alert-sink" "$B/logs/account-pin-probe.log" "$HUB/logs/account-pin-probe.log"
RC=$(sweep)
[ "$RC" = 0 ] && ok || bad "S1 sweep rc=$RC"
grep -q '^[0-9TZ:-]* project-3 own:project-3 ok file$' "$HUB/logs/account-pin-probe.log" 2>/dev/null && ok || bad "S1 hub probe did not run: $(cat "$HUB/logs/account-pin-probe.log" 2>/dev/null)"
[ "$(grep -c . "$T/ssh-sink" 2>/dev/null)" = 1 ] && ok || bad "S1 expected one ssh: $(cat "$T/ssh-sink" 2>/dev/null)"
grep -q '^root@192.0.2.2 /root/harness/bin/account-pin-probe.sh --alert project-3$' "$T/ssh-sink" && ok || bad "S1 ssh target/cmd: $(cat "$T/ssh-sink" 2>/dev/null)"
grep -q '192.0.2.3' "$T/ssh-sink" && bad "S1 probed the unpinned project's box" || ok
grep -q 'project-3 own:project-3 ok live' "$B/logs/account-pin-probe.log" 2>/dev/null && ok || bad "S1 box probe line: $(cat "$B/logs/account-pin-probe.log" 2>/dev/null)"
[ "$(alerts "$B")" = 0 ] && [ "$(alerts "$HUB")" = 0 ] && ok || bad "S1 alerted on a healthy fleet"

# S2: a pin written with a label nothing resolves
cache "$HUB" '{"account.project-3":"own:typo"}'; cache "$B" '{"account.project-3":"own:typo"}'
rm -f "$T/ssh-sink" "$B/alert-sink" "$HUB/alert-sink"
sweep >/dev/null
[ "$(alerts "$B")" = 1 ] && ok || bad "S2 owning box alerts: $(alerts "$B")"
grep -q 'box-project-3-1: pinned account own:typo for project-3' "$B/alert-sink" 2>/dev/null && ok || bad "S2 alert text: $(cat "$B/alert-sink" 2>/dev/null)"
[ "$(alerts "$HUB")" = 1 ] && ok || bad "S2 hub alerts: $(alerts "$HUB")"

# S3: probe not deployed on the box
scratch_rm "$B/state/account-pin"; rm -f "$T/ssh-sink" "$B/alert-sink" "$HUB/alert-sink" "$HUB/logs/account-pin-probe.log"
cache "$HUB" '{"account.project-3":"own:project-3"}'
sweep SSH_RC=127 >/dev/null
grep -q 'could-not-probe project-3 rc=127: project-3' "$HUB/logs/account-pin-probe.log" 2>/dev/null && ok || bad "S3 no could-not-probe line: $(cat "$HUB/logs/account-pin-probe.log" 2>/dev/null)"
[ "$(alerts "$B")" = 0 ] && [ "$(alerts "$HUB")" = 0 ] && ok || bad "S3 alerted on an unreachable probe"

# The hourly lane calls the sweep once, as its last step. Running the whole lane
# needs model routes and live probes, so this pins the call site structurally:
# the last two non-blank lines of the script are the call and the exit.
[ "$(grep -v '^[[:space:]]*$' "$DIR/bin/claude-auth-check.sh" | tail -2 | tr '\n' ' ')" = "account_pin_sweep exit 0 " ] \
  && ok || bad "S4 claude-auth-check.sh no longer ends with account_pin_sweep; exit 0"

echo "account-pin-probe.bh-3559: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
