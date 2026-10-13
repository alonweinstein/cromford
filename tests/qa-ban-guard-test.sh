#!/bin/bash
# tests/qa-ban-guard-test.sh — the QA-account ban machinery, DRIVEN.
#
# WHAT IS BEING PINNED, and why each property is driven rather than grepped:
#
#   1. A BANNED ACCOUNT IS DETECTED BEFORE THE TICKET IS MINTED. Clerk answers
#      200 to POST /v1/sign_in_tokens for a banned user; the refusal only shows
#      up in the browser. So "we minted a ticket" proves nothing, and the only
#      guard that works is reading `banned` first. Grepping for the call would
#      not show that its failure is thrown rather than logged.
#   2. THE BAN IS ALWAYS RESTORED. On success, on a failing command, on a
#      command that is killed. The EXIT trap is the whole mechanism, and a trap
#      can only be proven by killing the thing it is attached to.
#   3. A FAILED RESTORE IS THE EXIT CODE. A drive that passed while leaving a
#      privileged account live in production is not a pass.
#   4. RESTORE MEANS RESTORE. An account that was ACTIVE at rest must come back
#      active — blindly banning on the way out would disable the QA lane for
#      every project whose QA user is not privileged.
#   5. A LANDING ON /sign-in FAILS, WITH A NON-ZERO EXIT. The old smoke check
#      printed FAIL: and exited 0, so `$?` said the sign-in worked.
#
# Clerk is a fake `curl` on PATH backed by a one-word state file, so the whole
# ban lifecycle runs for real with no network and no secrets.
# Run from anywhere: tests/qa-ban-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state"
for F in qa-clerk-ban.sh qa-account.sh qa-unbanned.sh qa-session.sh; do
  cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
done
# BH-1941: qa-clerk-ban.sh resolves the Clerk base URL through bin/lib/endpoints.sh.
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"
# beat.sh is faked: the real one talks to the console/Telegram, and the property
# under test is "the alert path FIRES", not what it reaches.
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "${BEAT_SINK:-/dev/null}"
exit 0
EOF
chmod +x "$T/bin/beat.sh"
echo '{"project-3":{"admin":{"email":"qa@example.test","user_id":"user_BANNEDATREST"},"member":{"email":"m@example.test","user_id":"user_ACTIVEATREST"}}}' > "$T/state/qa-accounts.json"
printf 'QA_CLERK_SECRET_KEY=sk_test_not_a_real_key\n' > "$T/env/project-3.env"

# --- the fake Clerk ---------------------------------------------------------
# One file per user holds "banned" or "active". POST /ban and /unban write it;
# GET reads it. The failure modes each project a real one: a 5xx on the write, a
# write that answers 200 without changing anything (a proxy, a scoped key), and
# a user object with no `banned` field at all.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; PREV=""
for A in "$@"; do [ "$PREV" = "-X" ] && METHOD="$A"; PREV="$A"; done
UID_="${URL##*/v1/users/}"; UID_="${UID_%%/*}"
SF="$CLERK_STATE_DIR/$UID_"
[ -f "$SF" ] || echo active > "$SF"
case "$URL" in
  */ban)
    [ "${CLERK_FAIL_BAN:-}" = 1 ] && { printf '500'; exit 0; }
    [ "${CLERK_BAN_NOOP:-}" = 1 ] || echo banned > "$SF"
    printf '200'; exit 0 ;;
  */unban)
    [ "${CLERK_FAIL_UNBAN:-}" = 1 ] && { printf '500'; exit 0; }
    [ "${CLERK_UNBAN_NOOP:-}" = 1 ] || echo active > "$SF"
    printf '200'; exit 0 ;;
esac
[ "$METHOD" = GET ] || { printf '405'; exit 0; }
[ "${CLERK_GET_DOWN:-}" = 1 ] && exit 7
[ "${CLERK_GET_SHAPELESS:-}" = 1 ] && { printf '{"id":"%s"}' "$UID_"; exit 0; }
if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
printf '{"id":"%s","banned":%s}' "$UID_" "$B"
EOF
chmod +x "$T/fakebin/curl"
export CLERK_STATE_DIR="$T/clerk"; mkdir -p "$CLERK_STATE_DIR"
echo banned > "$CLERK_STATE_DIR/user_BANNEDATREST"
echo active > "$CLERK_STATE_DIR/user_ACTIVEATREST"
export PATH="$T/fakebin:$PATH"
export HARNESS="$T" QA_ACCOUNTS="$T/state/qa-accounts.json"

BAN="$T/bin/qa-clerk-ban.sh"
UNB="$T/bin/qa-unbanned.sh"
state_of() { cat "$CLERK_STATE_DIR/$1"; }

# ===========================================================================
# bin/qa-account.sh — one lookup
# ===========================================================================
[ "$("$T/bin/qa-account.sh" project-3 admin)" = user_BANNEDATREST ] \
  && ok || bad "qa-account.sh does not resolve a role to its user id"
[ "$("$T/bin/qa-account.sh" project-3 user_RAW)" = user_RAW ] \
  && ok || bad "a raw user id must resolve to itself"
"$T/bin/qa-account.sh" project-3 nosuchrole >/dev/null 2>&1 \
  && bad "an unknown role must exit non-zero, never fall through to a default" || ok

# ===========================================================================
# bin/qa-clerk-ban.sh — status/ban/unban, and the states it refuses to guess
# ===========================================================================
[ "$("$BAN" project-3 user_BANNEDATREST status)" = banned ] && ok || bad "status of a banned user"
[ "$("$BAN" project-3 user_ACTIVEATREST status)" = active ] && ok || bad "status of an active user"

OUT=$(CLERK_GET_DOWN=1 "$BAN" project-3 user_ACTIVEATREST status 2>/dev/null); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] \
  && ok || bad "an unreadable Clerk must exit non-zero and print NOTHING (got rc=$RC out='$OUT')"
OUT=$(CLERK_GET_SHAPELESS=1 "$BAN" project-3 user_ACTIVEATREST status 2>/dev/null); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] \
  && ok || bad "a user object with no \`banned\` field must fail, never read as active (rc=$RC out='$OUT')"
# The read-back is the point: a write that answers 200 without changing anything
# must be reported as the state Clerk actually holds.
[ "$(CLERK_UNBAN_NOOP=1 "$BAN" project-3 user_BANNEDATREST unban)" = banned ] \
  && ok || bad "unban must report the READ-BACK state, not the write's status code"
[ "$(state_of user_BANNEDATREST)" = banned ] && ok || bad "the no-op unban should not have changed state"
"$BAN" project-3 notauserid status >/dev/null 2>&1 \
  && bad "a non-Clerk id must be rejected" || ok

# ===========================================================================
# bin/qa-unbanned.sh — the window and its restore
# ===========================================================================
# 1. happy path: banned at rest -> active during -> banned after
OBS="$T/observed.txt"
"$UNB" project-3 admin -- bash -c 'cat "$CLERK_STATE_DIR/user_BANNEDATREST" > "$1"' _ "$OBS"
RC=$?
[ "$RC" = 0 ] && ok || bad "a successful command must return 0 (got $RC)"
[ "$(cat "$OBS")" = active ] && ok || bad "the account must be ACTIVE while the command runs (was $(cat "$OBS"))"
[ "$(state_of user_BANNEDATREST)" = banned ] && ok || bad "the ban must be restored afterwards"

# 2. a FAILING command still restores, and its rc is preserved
"$UNB" project-3 admin -- bash -c 'exit 42'; RC=$?
[ "$RC" = 42 ] && ok || bad "the command's own rc must survive the trap (got $RC)"
[ "$(state_of user_BANNEDATREST)" = banned ] && ok || bad "a failing command must still restore the ban"

# 3. a KILLED command still restores. This is the property the whole EXIT-trap
#    shape exists for: a drive that dies mid-screen must not leave a privileged
#    account live in production.
"$UNB" project-3 admin -- bash -c 'kill -TERM $$' >/dev/null 2>&1
[ "$(state_of user_BANNEDATREST)" = banned ] && ok || bad "a killed command must still restore the ban"

# 4. RESTORE MEANS RESTORE: an account active at rest comes back ACTIVE
"$UNB" project-3 member -- true
[ "$(state_of user_ACTIVEATREST)" = active ] \
  && ok || bad "an account that was ACTIVE at rest must not be banned on the way out"

# 5. a FAILED restore is loud AND is the exit code
echo banned > "$CLERK_STATE_DIR/user_BANNEDATREST"
: > "$T/logs/ALERTS.log"; export BEAT_SINK="$T/beats.txt"; : > "$BEAT_SINK"
CLERK_FAIL_BAN=1 "$UNB" project-3 admin -- true >/dev/null 2>&1; RC=$?
[ "$RC" = 90 ] && ok || bad "a failed re-ban must be the exit code 90, whatever the command returned (got $RC)"
grep -q 'QA ACCOUNT LEFT UNBANNED' "$T/logs/ALERTS.log" \
  && ok || bad "a failed re-ban must write an ALERTS.log line naming the account"
grep -q 'fleet_alert' "$T/beats.txt" && ok || bad "a failed re-ban must fire a fleet_alert beat"
grep -q 'sk_test' "$T/logs/ALERTS.log" "$T/beats.txt" \
  && bad "a secret reached a log or a beat" || ok
unset BEAT_SINK
echo banned > "$CLERK_STATE_DIR/user_BANNEDATREST"

# 6. an unban that does not TAKE drives nothing at all
CLERK_UNBAN_NOOP=1 "$UNB" project-3 admin -- bash -c 'touch "$1"' _ "$T/should-not-exist" >/dev/null 2>&1; RC=$?
[ "$RC" = 91 ] && [ ! -e "$T/should-not-exist" ] \
  && ok || bad "an unban that did not take must run NOTHING and exit 91 (rc=$RC)"
# ...and an unreadable ban state is the same refusal, not an optimistic drive.
CLERK_GET_DOWN=1 "$UNB" project-3 admin -- bash -c 'touch "$1"' _ "$T/blind" >/dev/null 2>&1; RC=$?
[ "$RC" = 91 ] && [ ! -e "$T/blind" ] \
  && ok || bad "an unreadable ban state must refuse to drive (rc=$RC)"

# 7. usage errors are usage errors, not silent successes
"$UNB" project-3 admin >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "a missing -- must exit 2"
"$UNB" project-3 admin -- >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "an empty command must exit 2"

# ===========================================================================
# bin/qa-session.sh — the banned account names its own way out
# ===========================================================================
# The fake curl answers Clerk's users API; a session POST lands on the
# `405` branch, which is the "not a 2xx" path this assertion is about.
OUT=$(QA_CLERK_SECRET_KEY=sk_test_x "$T/bin/qa-session.sh" project-3 admin 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "a failed session mint must exit non-zero"
grep -q 'qa-unbanned.sh\|clerk session-create' <<<"$OUT" \
  && ok || bad "a failed mint must say what to do about it (got: $OUT)"

# ===========================================================================
# bin/qa-drive.mjs — the sign-in contract, with a stubbed Clerk and page
# ===========================================================================
if command -v node >/dev/null 2>&1; then
  cat > "$T/drive-test.mjs" <<'EOF'
import { signIn, isAuthWall, screenFailures } from process.env.QA_DRIVE_PATH;
EOF
  # ESM has no dynamic literal import in that form; use import() instead.
  cat > "$T/drive-test.mjs" <<EOF
const M = await import("file://$DIR/bin/qa-drive.mjs");
const fail = [];
const T = (name, cond) => { if (!cond) fail.push(name); };

T("isAuthWall(/sign-in)", M.isAuthWall("/sign-in"));
T("isAuthWall(/sign-up/continue)", M.isAuthWall("/sign-up/continue"));
T("isAuthWall(/clients)", !M.isAuthWall("/clients"));

// screenFailures is the ONE place that decides what counts as an observed
// defect, so the CLI and any reader agree on the word "FAIL".
const clean = { path: "/c", viewport: "1280", status: 200, landedOnAuthWall: false,
  consoleErrors: [], failedRequests: [], horizontalScroll: false, nativeDialog: null, error: null };
T("a clean screen has no failures", M.screenFailures(clean).length === 0);
T("an auth-wall landing fails", M.screenFailures({ ...clean, landedOnAuthWall: true }).length === 1);
T("a 500 fails", M.screenFailures({ ...clean, status: 500 }).length === 1);
T("a console error fails", M.screenFailures({ ...clean, consoleErrors: ["boom"] }).length === 1);
T("a native dialog fails", M.screenFailures({ ...clean, nativeDialog: "confirm: sure?" }).length === 1);
// horizontal scroll is a 375px law: at 1280 a wide page is not a finding.
T("375px horizontal scroll fails",
  M.screenFailures({ ...clean, viewport: "375", horizontalScroll: true }).length === 1);
T("1280px horizontal scroll is not a finding",
  M.screenFailures({ ...clean, horizontalScroll: true }).length === 0);

const page = (urls) => {
  let i = 0;
  return {
    _url: urls[0],
    goto: async function () { this._url = urls[Math.min(++i, urls.length - 1)]; },
    waitForURL: async function () {},
    waitForTimeout: async function () {},
    url: function () { return this._url; },
  };
};
const stubFetch = (banned) => async (url, opts) => {
  if (String(url).includes("/sign_in_tokens"))
    return { ok: true, status: 200, json: async () => ({ token: "tkt" }) };
  return { ok: true, status: 200, json: async () => ({ id: "user_x", banned }) };
};

// 1. A BANNED user must fail BEFORE the ticket is minted, by name.
globalThis.fetch = stubFetch(true);
let minted = false;
const spy = globalThis.fetch;
globalThis.fetch = async (u, o) => { if (String(u).includes("sign_in_tokens")) minted = true; return spy(u, o); };
let err = null;
try {
  await M.signIn(page(["about:blank", "https://app.test/dashboard"]),
    { base: "https://app.test", userId: "user_x", clerkKey: "k" });
} catch (e) { err = String(e); }
T("a banned user throws", err !== null && /BANNED/.test(err));
T("a banned user never gets a ticket minted", minted === false);

// 2. A bounce BACK to /sign-in is a failure even though waitForURL was satisfied.
globalThis.fetch = stubFetch(false);
err = null;
try {
  await M.signIn(page(["about:blank", "https://app.test/sign-in?redirect=1"]),
    { base: "https://app.test", userId: "user_x", clerkKey: "k" });
} catch (e) { err = String(e); }
T("a bounce back to /sign-in throws", err !== null && /sign-in/.test(err));

// 3. A real landing returns the landed URL.
err = null;
let landed = null;
try {
  landed = await M.signIn(page(["about:blank", "https://app.test/dashboard"]),
    { base: "https://app.test", userId: "user_x", clerkKey: "k" });
} catch (e) { err = String(e); }
T("a real landing returns the url", err === null && landed === "https://app.test/dashboard");

// 4. An unreadable ban state is never "not banned".
globalThis.fetch = async (url) =>
  String(url).includes("/sign_in_tokens")
    ? { ok: true, status: 200, json: async () => ({ token: "t" }) }
    : { ok: false, status: 503, json: async () => ({}) };
err = null;
try { await M.isBanned("user_x", "k"); } catch (e) { err = String(e); }
T("an unreadable user read throws", err !== null);

if (fail.length) { console.log("MJSFAIL:" + fail.join(" | ")); process.exit(1); }
console.log("MJSOK");
EOF
  OUT=$(node "$T/drive-test.mjs" 2>&1)
  grep -q MJSOK <<<"$OUT" && ok || bad "qa-drive.mjs contract: $OUT"

  # The exit-code contract of the smoke check, driven rather than grepped: it
  # used to print FAIL: and exit 0, which is the whole bug.
  OUT=$(node "$DIR/bin/qa-signin-check.mjs" 2>&1); RC=$?
  [ "$RC" != 0 ] && grep -q '^FAIL:' <<<"$OUT" \
    && ok || bad "qa-signin-check.mjs must exit non-zero when it prints FAIL (rc=$RC, out=$OUT)"
else
  echo "node missing — skipping the qa-drive.mjs contract (NOT a pass)"
fi

# ===========================================================================
# The skill teaches the fixed procedure, not the old one
# ===========================================================================
SK="$DIR/skills/qa-prod-drive/SKILL.md"
grep -q 'qa-unbanned.sh' "$SK" && ok || bad "the skill never names the unban wrapper"
grep -q 'EXIT trap' "$SK" && ok || bad "the skill does not say the ban is restored from an EXIT trap"
grep -qi 'landed on .*/sign-in is a FAIL\|`/sign-in` is a FAIL' "$SK" \
  && ok || bad "the skill must state that a /sign-in landing is a FAIL"
grep -q 'Reactivate unbans' "$SK" \
  && bad "the skill still tells the reader unbanning is never its job — that is the guidance that produced the blind drives" || ok

echo "qa-ban-guard-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
