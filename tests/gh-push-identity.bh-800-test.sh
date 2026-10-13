#!/bin/bash
# tests/gh-push-identity.bh-800-test.sh — bin/lib/gh-push-identity.sh: WHO is
# about to push, and whether GitHub's branch protection lets that identity push.
#
# THE CASE THIS PINS (BH-800, 2026-09-18). `mergeState=BLOCKED` on a branch with
# NO required status checks and NO required reviews is not a PR that is not
# ready — there is no check for it to be waiting on. It is GitHub saying the
# token in hand is not in the branch's push allow-list. The hub's two merge
# lanes read that word as "not ready" and retried it 42 times in 40 minutes
# while nothing could ever land.
#
# AND THE NARROWING THE REVIEW OF #846 ASKED FOR. "Nothing required" is a bigger
# set than "no checks and no reviews": conversation resolution and a branch lock
# both block a merge with `required_status_checks == null`, and `restrictions ==
# null` means there is no allow-list to be absent from. Those are `protected`
# and `unexplained` respectively — never a page naming an identity that no list
# ever excluded.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a classification that
# gates a fleet ALERT and rewrites a log line, so the negatives carry the
# weight: a branch with a real required check, an identity that IS on the
# allow-list, a 403 that is not a 404. `grep -q identity bin/lib/...` passes
# just as happily on a classifier that never reaches the branch.
#
# Run from anywhere: tests/gh-push-identity.bh-800-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/fakebin"
export T
export GH_SINK="$T/gh.txt"; : > "$GH_SINK"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"
chmod +x "$T/h/bin/beat.sh"

# The gh stub: every argv lands in $GH_SINK, and the protection endpoint answers
# whatever $T/protmode-<slug-key> says. gh's own failure shape is reproduced
# exactly — nonzero rc and `(HTTP nnn)` on STDERR — because that suffix is the
# only thing the reader is allowed to classify on (D9/D10/D35, the #796 family).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api user -q .login")
    cat "$T/userlogin" 2>/dev/null; exit 0 ;;
  # BH-1586: the protection read is gh_rest (`gh api -i -X GET …`), which judges
  # the HTTP STATUS LINE, so every arm answers a whole HTTP response.
  *"/protection"*)
    KEY=$(printf '%s' "$*" | sed -nE 's#.*repos/([^/]+)/([^/]+)/branches.*#\1_\2#p')
    MODE=$(cat "$T/protmode-$KEY" 2>/dev/null || echo ok)
    r() { printf 'HTTP/1.1 %s Stub\r\n\r\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; exit 0; }
    case "$MODE" in
      ok)   r 200 "$(cat "$T/protection.json")" ;;
      404)  r 404 '{"message":"Branch not protected"}' ;;
      403)  r 403 '{"message":"Resource not accessible by integration"}' ;;
      adminonly)
        if [ "${GH_TOKEN:-}" = admintok ]; then r 200 "$(cat "$T/protection.json")"; fi
        r 403 '{"message":"Resource not accessible by integration"}' ;;
      body)   r 200 '{"message":"Not Found"}' ;;
      notjson) r 200 'Not Found' ;;
      *)      r 404 '{"message":"Not Found"}' ;;
    esac ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
# A `date` that can be pushed to tomorrow, and ONLY for the day stamp the alert
# dedups on. Everything else (the ALERTS timestamp) falls through to the real
# one, so the rollover case is driven rather than simulated by deleting a flag.
cat > "$T/fakebin/date" <<'SH'
#!/bin/bash
if [ -n "${FAKE_DAY:-}" ] && [ "$*" = "-u +%Y%m%d" ]; then printf '%s\n' "$FAKE_DAY"; exit 0; fi
exec /bin/date "$@"
SH
chmod +x "$T/fakebin/date"
export PATH="$T/fakebin:$PATH"

cp "$DIR/bin/lib/gh-push-identity.sh" "$T/h/bin/lib/" 2>/dev/null || {
  echo "FAIL: bin/lib/gh-push-identity.sh does not exist"; echo "gh-push-identity: 0 passed, 1 failed"; exit 1; }
# BH-1586: the protection read goes through gh_rest and the policy cache, so the
# fixture tree carries them as a box does. No lane-gate here, so the cache TTL
# resolves to 0 (off) and every U6/U7 count below is the process cache's alone.
cp "$DIR"/bin/lib/gh-rest*.sh "$DIR/bin/lib/gh-policy-cache.sh" "$T/h/bin/lib/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/gh-push-identity.sh"

v() { gh_push_blocked_verdict "$1" "$2"; }
NOTHING='"required_status_checks":null,"required_pull_request_reviews":null'
TICKET_PROT="{$NOTHING,
  \"restrictions\":{\"users\":[{\"login\":\"operator\"},{\"login\":\"hstevens\"},{\"login\":\"rmalik\"},{\"login\":\"dkatz\"},{\"login\":\"jnguyen\"}],\"apps\":[]}}"

# ---------------------------------------------------------------------------
# U1 — `protected`: the branch genuinely gates the merge on something, so
#      BLOCKED means what the lanes have always read it to mean. FOUR shapes,
#      because #846 only knew the first two and the review of it found the
#      other two produce a false page (a branch with conversation resolution
#      on and no checks reads as "nothing required" to a two-field test).
# ---------------------------------------------------------------------------
[ "$(v '{"required_status_checks":{"contexts":[]},"required_pull_request_reviews":null,"restrictions":null}' operator)" = protected ] \
  && ok || bad "U1: required_status_checks PRESENT with an empty contexts list is still a gate (got $(v '{"required_status_checks":{"contexts":[]},"required_pull_request_reviews":null,"restrictions":null}' operator))"
[ "$(v '{"required_status_checks":null,"required_pull_request_reviews":{},"restrictions":null}' operator)" = protected ] \
  && ok || bad "U1: a required review means BLOCKED is a PR state"
[ "$(v "{$NOTHING,\"required_conversation_resolution\":{\"enabled\":true},\"restrictions\":{\"users\":[{\"login\":\"operator\"}],\"apps\":[]}}" somebody-else)" = protected ] \
  && ok || bad "U1: required_conversation_resolution alone blocks the merge — protected, not an identity error"
[ "$(v "{$NOTHING,\"lock_branch\":{\"enabled\":true},\"restrictions\":{\"users\":[{\"login\":\"operator\"}],\"apps\":[]}}" somebody-else)" = protected ] \
  && ok || bad "U1: lock_branch alone blocks the merge — protected, not an identity error"
# ...and neither of those two fields reads as a gate when it is switched OFF.
[ "$(v "{$NOTHING,\"required_conversation_resolution\":{\"enabled\":false},\"lock_branch\":{\"enabled\":false},\"restrictions\":{\"users\":[{\"login\":\"operator\"}],\"apps\":[]}}" somebody-else)" = identity ] \
  && ok || bad "U1: enabled:false is not a gate — this is the ticket's own shape and must still classify"

# ---------------------------------------------------------------------------
# U2 — `unexplained`: nothing required AND no `restrictions` at all. There is
#      no allow-list to be absent from, so the block came from something this
#      read does not cover (a ruleset, a merge queue). #846 answered `identity`
#      here and the review called it a false page; this assertion is that one
#      INVERTED on purpose.
# ---------------------------------------------------------------------------
[ "$(v "{$NOTHING,\"restrictions\":null}" app/cromford)" = unexplained ] \
  && ok || bad "U2: restrictions null is unexplained, never an identity error (got $(v "{$NOTHING,\"restrictions\":null}" app/cromford))"
[ "$(v "{$NOTHING}" app/cromford)" = unexplained ] \
  && ok || bad "U2: a protection document with no restrictions key at all is unexplained"

# ---------------------------------------------------------------------------
# U3 — `unexplained`: we could not name the identity. An ALERT that tells an
#      admin to add `unknown` to a push allow-list is a fabricated instruction
#      (D26), so an unnameable identity never pages either.
# ---------------------------------------------------------------------------
[ "$(v "$TICKET_PROT" unknown)" = unexplained ] \
  && ok || bad "U3: identity 'unknown' must not page as an identity error (got $(v "$TICKET_PROT" unknown))"
[ "$(v "$TICKET_PROT" "")" = unexplained ] \
  && ok || bad "U3: an empty identity must not page as an identity error (got $(v "$TICKET_PROT" ""))"

# ---------------------------------------------------------------------------
# U4 — the App shape compares against `restrictions.apps[].slug` ONLY. A USER
#      named cromford does not allow-list the cromford App: GitHub
#      keeps two separate lists and a push permission does not cross them.
# ---------------------------------------------------------------------------
APPPROT="{$NOTHING,\"restrictions\":{\"users\":[],\"apps\":[{\"slug\":\"cromford\"}]}}"
USERPROT="{$NOTHING,\"restrictions\":{\"users\":[{\"login\":\"cromford\"}],\"apps\":[]}}"
[ "$(v "$APPPROT" app/cromford)" = allowlisted ] \
  && ok || bad "U4: app/<slug> must match restrictions.apps[].slug"
[ "$(v "$APPPROT" "cromford[bot]")" = allowlisted ] \
  && ok || bad "U4: <slug>[bot] is the same actor as app/<slug>"
[ "$(v "$USERPROT" app/cromford)" = identity ] \
  && ok || bad "U4: a USER login must NOT allow-list a same-named App (got $(v "$USERPROT" app/cromford))"
[ "$(v "$USERPROT" "cromford[bot]")" = identity ] \
  && ok || bad "U4: a USER login must NOT allow-list a same-named App, in [bot] spelling either"
[ "$(v "$APPPROT" app/other-app)" = identity ] \
  && ok || bad "U4: a DIFFERENT app must not read as allow-listed"

# ---------------------------------------------------------------------------
# U5 — the PAT shape compares against `restrictions.users[].login` ONLY, case
#      folded once at both ends (D17). An App slug does not allow-list a PAT of
#      the same name — the other half of U4's rule.
# ---------------------------------------------------------------------------
[ "$(v "{$NOTHING,\"restrictions\":{\"users\":[{\"login\":\"operator\"}],\"apps\":[]}}" operator)" = allowlisted ] \
  && ok || bad "U5: the login compare must be case-insensitive (operator vs operator)"
[ "$(v "$APPPROT" cromford)" = identity ] \
  && ok || bad "U5: an App slug must NOT allow-list a same-named PAT user (got $(v "$APPPROT" cromford))"
[ "$(v "$TICKET_PROT" somebody-else)" = identity ] \
  && ok || bad "U5: the ticket's own shape — five human logins, an identity that is not one of them"
[ "$(v "{$NOTHING,\"restrictions\":{\"users\":[],\"apps\":[]}}" operator)" = identity ] \
  && ok || bad "U5: a restrictions block with both lists empty admits nobody"

# The allow-list summary the log line carries, so a reader can tell the shapes
# apart without opening GitHub.
[ "$(gh_push_allowlist_summary '{"restrictions":null}')" = "none listed" ] \
  && ok || bad "summary: restrictions null must say 'none listed' (got $(gh_push_allowlist_summary '{"restrictions":null}'))"
[ "$(gh_push_allowlist_summary "{$NOTHING,\"restrictions\":{\"users\":[],\"apps\":[]}}")" = "empty" ] \
  && ok || bad "summary: an empty allow-list says so"
[ "$(gh_push_allowlist_summary "$TICKET_PROT")" = "operator,hstevens,rmalik,dkatz,jnguyen" ] \
  && ok || bad "summary: the listed users must be named (got $(gh_push_allowlist_summary "$TICKET_PROT"))"
[ "$(gh_push_allowlist_summary "$APPPROT")" = "app:cromford" ] \
  && ok || bad "summary: a listed app must be named (got $(gh_push_allowlist_summary "$APPPROT"))"

# ---------------------------------------------------------------------------
# U6 — the protection read. Classified ONLY by the HTTP status (gh_rest's
#      0/44/75 since BH-1586); a 403 is not a 404 and neither is read from the
#      body (D9/D10/D35, the #796 family).
# ---------------------------------------------------------------------------
printf '%s\n' "$TICKET_PROT" | jq -c . > "$T/protection.json"
echo 404 > "$T/protmode-o_r404"
[ "$(gh_branch_protection o/r404 main)" = "unprotected" ] \
  && ok || bad "U6: 404 means the branch is not protected (got $(gh_branch_protection o/r404 main))"
echo 403 > "$T/protmode-o_r403"
[ "$(gh_branch_protection o/r403 main)" = "unreadable 403" ] \
  && ok || bad "U6: a 403 on every token is 'unreadable 403', never 'unprotected' (got $(gh_branch_protection o/r403 main))"
# The admin ladder: the current token 403s, env/github-admin.env's PAT answers.
echo adminonly > "$T/protmode-o_radm"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$T/h/env/github-admin.env"
: > "$GH_SINK"
# Same shell, not a command substitution: the cache assertion below is about
# this process, and `$( )` would fork a fresh one.
GH_TOKEN=ghs_fake gh_branch_protection o/radm main > "$T/adm.txt"
OUTADM=$(cat "$T/adm.txt")
[ "$(cut -f1 <<<"$OUTADM")" = ok ] && [ -n "$(cut -f2 <<<"$OUTADM")" ] \
  && ok || bad "U6: the admin token must answer after the current token 403s (got '$OUTADM')"
[ "$(grep -c "branches/main/protection" "$GH_SINK")" = 2 ] \
  && ok || bad "U6: the ladder must be exactly 2 calls (got $(grep -c "branches/main/protection" "$GH_SINK"))"
[ "$(gh_push_blocked_verdict "$(cut -f2 <<<"$OUTADM")" somebody-else)" = identity ] \
  && ok || bad "U6: the json the ladder returned must still classify"
# rc 0 with a Not-Found BODY is JSON we were handed, not an error: the reader
# never classifies on prose, and the verdict function reads keys, not text.
echo body > "$T/protmode-o_rbody"
[ "$(gh_branch_protection o/rbody main)" = "$(printf 'ok\t{"message":"Not Found"}')" ] \
  && ok || bad "U6: an rc-0 JSON body must never be classified as unprotected (got $(gh_branch_protection o/rbody main))"
# rc 0 with a body that is not JSON at all is not a document to classify: the
# rung failed, so the ladder moves on and the answer is unreadable — never
# `unprotected`, which would read as "this branch has no protection".
echo notjson > "$T/protmode-o_rtext"
[ "$(gh_branch_protection o/rtext main)" = "unreadable unparseable" ] \
  && ok || bad "U6: an unparseable rc-0 body is unreadable, never unprotected (got $(gh_branch_protection o/rtext main))"

# ---------------------------------------------------------------------------
# U7 — one read per (repo, branch) per process; a second branch is its own key.
# ---------------------------------------------------------------------------
: > "$GH_SINK"
echo ok > "$T/protmode-o_rcache"
gh_branch_protection o/rcache main >/dev/null
gh_branch_protection o/rcache main >/dev/null
[ "$(grep -c "o/rcache/branches/main/protection" "$GH_SINK")" = 1 ] \
  && ok || bad "U7: a cached (repo, branch) must cost one gh call (got $(grep -c "o/rcache/branches/main/protection" "$GH_SINK"))"
gh_branch_protection o/rcache release >/dev/null
[ "$(grep -c "o/rcache/branches/release/protection" "$GH_SINK")" = 1 ] \
  && ok || bad "U7: a second branch of the same repo is its own read"

# ---------------------------------------------------------------------------
# U8 — the identity word, and the alert. An App installation token can never
#      call /user (403), so its word comes from the configured slug and the
#      call is never made; a PAT's word is its login; nothing resolvable is the
#      word `unknown`, never a plausible login (D26). The alert is one line per
#      (lane, repo, identity, UTC day), and no token VALUE goes anywhere near a
#      log, a beat or a filename.
# ---------------------------------------------------------------------------
: > "$GH_SINK"; : > "$T/userlogin"
[ "$(GH_TOKEN=ghs_x gh_token_identity)" = "app/cromford" ] \
  && ok || bad "U8: a ghs_ token with no env/github-app.env must read app/cromford (got $(GH_TOKEN=ghs_x gh_token_identity))"
grep -q "api user" "$GH_SINK" && bad "U8: /user must never be called on an App installation token" || ok
printf 'GH_APP_SLUG="Cromford"\n' > "$T/h/env/github-app.env"
[ "$(GH_TOKEN=ghs_x2 gh_token_identity)" = "app/cromford" ] \
  && ok || bad "U8: GH_APP_SLUG must be slugged the way GitHub slugs it (got $(GH_TOKEN=ghs_x2 gh_token_identity))"
rm -f "$T/h/env/github-app.env"
echo operator > "$T/userlogin"
[ "$(GH_TOKEN=ghp_x gh_token_identity)" = "operator" ] \
  && ok || bad "U8: a PAT's identity is its /user login (got $(GH_TOKEN=ghp_x gh_token_identity))"
: > "$T/userlogin"
[ "$(GH_TOKEN=ghp_x2 gh_token_identity)" = "unknown" ] \
  && ok || bad "U8: an unresolvable identity must be the word unknown (got $(GH_TOKEN=ghp_x2 gh_token_identity))"
echo operator > "$T/userlogin"
GH_TOKEN=ghp_cache gh_token_identity >/dev/null
BEFORE=$(grep -c "api user" "$GH_SINK" || true)
GH_TOKEN=ghp_cache gh_token_identity >/dev/null
[ "$(grep -c "api user" "$GH_SINK" || true)" = "$BEFORE" ] \
  && ok || bad "U8: the identity must be cached per token fingerprint (extra /user call)"

: > "$T/h/logs/ALERTS.log"; : > "$T/beats.txt"
GH_TOKEN=ghs_x gh_identity_alert merge-sweep o/r app/cromford main
GH_TOKEN=ghs_x gh_identity_alert merge-sweep o/r app/cromford main
[ "$(grep -c "IDENTITY_NOT_PERMITTED o/r app/cromford" "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "U8: exactly one ALERT per (lane, repo, identity, day) (got $(grep -c IDENTITY_NOT_PERMITTED "$T/h/logs/ALERTS.log"))"
[ "$(grep -c IDENTITY_NOT_PERMITTED "$T/beats.txt")" = 1 ] \
  && ok || bad "U8: exactly one beat per (lane, repo, identity, day) (got $(grep -c IDENTITY_NOT_PERMITTED "$T/beats.txt"))"
grep -q "protection/restrictions" "$T/h/logs/ALERTS.log" \
  && ok || bad "U8: the ALERT must name exactly what is needed and from whom"
ls "$T/h/flags/"alerted-identity-not-permitted-merge-sweep-o_r-app_cromford-* >/dev/null 2>&1 \
  && ok || bad "U8: the dedup flag file must exist ($(ls "$T/h/flags" 2>/dev/null | tr '\n' ' '))"
# A config gap that comes back tomorrow is news again — the dedup is per day,
# not for ever.
FAKE_DAY=20991231 GH_TOKEN=ghs_x gh_identity_alert merge-sweep o/r app/cromford main
[ "$(grep -c "IDENTITY_NOT_PERMITTED o/r app/cromford" "$T/h/logs/ALERTS.log")" = 2 ] \
  && ok || bad "U8: the next UTC day must page again (got $(grep -c "IDENTITY_NOT_PERMITTED o/r app/cromford" "$T/h/logs/ALERTS.log"))"
# A different identity on the same repo is a different page.
GH_TOKEN=ghp_x gh_identity_alert merge-sweep o/r operator main
[ "$(grep -c "IDENTITY_NOT_PERMITTED o/r " "$T/h/logs/ALERTS.log")" = 3 ] \
  && ok || bad "U8: a second identity on the same repo must page on its own"
grep -rq 'ghs_x\|ghp_x\|admintok' "$T/h/logs/" 2>/dev/null \
  && bad "U8: a token VALUE reached a log" || ok
grep -q 'ghs_x\|ghp_x\|admintok' "$T/beats.txt" 2>/dev/null \
  && bad "U8: a token VALUE reached a beat" || ok
grep -q 'ghs_x\|ghp_x\|admintok' <<<"$(ls "$T/h/flags/" 2>/dev/null)" \
  && bad "U8: a token VALUE reached a flag filename" || ok

echo "gh-push-identity.bh-800: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
