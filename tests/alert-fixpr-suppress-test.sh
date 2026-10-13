#!/bin/bash
# tests/alert-fixpr-suppress-test.sh — a family whose fix is an OPEN pull
# request is ANSWERED, not "not recently triaged". alert-triage must stop buying
# a session for it, keep saying "merge PR N" once a day, escalate louder once
# the PR has sat for FIXPR_STALE_HOURS, and go straight back to normal triage
# the moment that PR merges or closes.
#
# This runs the REAL bin/alert-triage.sh end to end, the way
# tests/triage-split-test.sh does: only the harness ROOT is repointed, so every
# decision below is made by the shipped code — the collector, the python family
# brake, the new fix-PR diversion, the answered loop, the dispatch loop and the
# post-session parse. agent-call.sh, beat.sh, gh, ssh, flock and timeout are
# stubbed because they are the only things that would leave this machine, page a
# human or cost money; what they RECEIVE is the assertion.
#
# WHAT IS AT STAKE. This feature SUPPRESSES alert triage, so the negatives carry
# the weight and come first in the ordering of what must never break: a gh that
# fails, a torn ledger, an entry with no url and the kill switch must each leave
# the lane on exactly the path it takes today. A suppression may only ever
# follow a positive `OPEN` read. Second: the suppression must not be silent — a
# family nobody triages and nobody mentions is an alert we deleted, so the lane
# log carries ANSWERED-PENDING-MERGE with the real count and the beat names the
# merge as the action, once a day, and louder once it goes stale. Third: a beat
# that failed to send may never leave a stamp behind, or the day's only "merge
# this" message is lost.
# Run from anywhere: tests/alert-fixpr-suppress-test.sh   (exit 0 = all pass)
set -uo pipefail
# tests/lib/scratch.sh is the shared scratch contract 267 sibling tests source;
# it ships in #609, which is BLOCKED today, so this file carries the same
# contract inline until then: $T, scratch_rm, cleanup on EXIT. Delete the
# else-branch the day #609 merges. Every recursive rm below names $T
# (checks/tests-scratch-only R2), and the source line precedes the first mktemp
# (R1).
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  # The unset and the root refusal are load-bearing, not ceremony: a $HARNESS
  # inherited from the caller makes the repointed script below read the LIVE
  # harness root — its state, its logs, its real agent-call.sh. That happened
  # once while this file was being written, at 18:53Z on 2026-09-17, and it
  # stamped three fixture families into the hub's own alert-families.json.
  if [ "$(id -u)" -eq 0 ] && [ -d "${HARNESS_ROOT_OVERRIDE:-/root/harness}" ] \
     && [ "${HARNESS_TEST_SANDBOX:-}" != "1" ]; then
    echo "$(basename "$0"): refusing to run as root next to a live harness (set HARNESS_TEST_SANDBOX=1)" >&2
    exit 1
  fi
  unset HARNESS H HARNESS_CHECKOUT
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  export T
  scratch_rm() { [ "${1#"$T"/}" != "$1" ] && rm -rf "$T/${1#"$T"/}"; }
  trap 'rm -rf "$T"' EXIT
fi
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read; every epoch below derives from it (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
URL="https://github.com/example-org/cromford/pull/573"   # the ticket's live case
URL2="https://github.com/example-org/cromford/pull/9001"

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$T/stub" "$T/calls"
: > "$H/env/global.env"
Q="$H/state/alert-quarantine.jsonl"
# BH-5942: proj-* is not in fleet.conf, so every line here belongs to the home
# project's run; its fix-PR ledger and 6h brake live under HP.
HP="$H/state/alert-triage/cromford"
LED="$HP/alert-fix-prs.json"

# the script under test, with only its harness root repointed
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
chmod +x "$H/bin/alert-triage.sh"

# the real orientation renderer and the real family key, so the prompt the lane
# builds and the key it stores are the production ones
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
# The REAL fix-PR state reader and the two libraries it arms and reads through:
# both of this lane's reads go through it, so the identity it picks and the
# protocol it speaks are under test rather than stubbed away (F1a/F1b/F1c).
mkdir -p "$H/bin/lib"
ln -sf "$DIR/bin/gh-pr-state.sh" "$H/bin/gh-pr-state.sh"
# BH-1485: gh-rest-var.sh rides with gh-rest.sh (sourced by path from beside it).
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1

# --- stubs --------------------------------------------------------------------
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <lane> <model> <turns> <outfile> <prompt>
# The real one writes only the session's LAST message to <outfile>, which is why
# the FIX-PR contract is a line in that message.
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
# The identity the SESSION inherits. A fix-PR state read that armed an App token
# in this shell would show up here as the wrong token (BH-470).
printf '%s' "${GH_TOKEN:-none}" > "$CALLDIR/token-$N"
{ [ -n "${FIXPR_STUB_LINE:-}" ] && printf '%s\n' "$FIXPR_STUB_LINE"
  printf 'handled=1 escalated=0 noise=0\n'; } > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"

cat > "$H/bin/beat.sh" <<'STUB'
#!/bin/bash
# beat.sh '<json>' — the real one's CONTRACT, not a friendlier version of it:
# without BEAT_STRICT=1 it returns 0 whether or not the console took the beat
# (bin/beat.sh:271), so a caller that forgets the flag learns nothing. Here that
# call records into $BEATS.nonstrict and succeeds — the caller sees a delivered
# beat that never arrived, and the assertion on that file is what proves the
# lane sets the flag. BEAT_FAIL=1 is a console outage (rc 1); BEAT_NOCONSOLE=1
# is a box with no console configured (rc 2, nothing to retry).
if [ "${BEAT_STRICT:-}" != 1 ]; then printf '%s\n' "$1" >> "$BEATS.nonstrict"; exit 0; fi
[ -n "${BEAT_NOCONSOLE:-}" ] && exit 2
[ -n "${BEAT_FAIL:-}" ] && exit 1
printf '%s\n' "$1" >> "$BEATS"
exit 0
STUB
chmod +x "$H/bin/beat.sh"

cat > "$T/stub/gh" <<'STUB'
#!/bin/sh
# gh stub: records argv AND the identity the call went out on, answers the REST
# pull read (`gh api -i -X GET repos/<o>/<r>/pulls/<n>`, what bin/lib/gh-rest.sh
# issues) from $PRSTATE, and fails when $PRFAIL exists. A failure prints NO
# status line, which is exactly what a network error looks like to gh_rest.
printf 'tok=%s %s\n' "${GH_TOKEN:-none}" "$*" >> "$GHLOG"
[ -f "$PRFAIL" ] && exit 1
case "$*" in
  *repos/*/pulls/*)
    case "$(cat "$PRSTATE" 2>/dev/null)" in
      MERGED) BODY='{"state":"closed","merged_at":"2026-09-01T00:00:00Z"}' ;;
      CLOSED) BODY='{"state":"closed","merged_at":null}' ;;
      *)      BODY='{"state":"open","merged_at":null}' ;;
    esac
    printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n%s\n' "$BODY"
    ;;
esac
exit 0
STUB
chmod +x "$T/stub/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

export BEATS="$T/beats.log" GHLOG="$T/gh-calls.log" PRSTATE="$T/pr-state" PRFAIL="$T/pr-fail"

# --- fixture: quarantine lines in the real format (epoch<TAB>beat-json) -------
mkline() { printf '%s\t{"kind":"fleet_alert","project":"proj-%s","akey":"akey-%s","line":"the %s subsystem is unhappy"}\n' "$NOW" "$1" "$1" "$1"; }
seed() { : > "$Q"; for m in "$@"; do mkline "$m" >> "$Q"; done; }
# The family key of a seeded marker, computed by the PRODUCTION entry point over
# the exact line the collector builds (source prefix included) — never a
# re-implementation of the normalization.
famkey() { python3 "$DIR/bin/alert_family.py" family "$(printf 'hub\t%s' "$(mkline "$1")")"; }

ledger() {  # ledger <fam> <url> <first_seen> [<beat_day>] [<stale_beat_at>]
  python3 - "$LED" "$@" <<'PY'
import json, sys
p, fam, url, first = sys.argv[1:5]
day = sys.argv[5] if len(sys.argv) > 5 else ""
stale = sys.argv[6] if len(sys.argv) > 6 else "0"
json.dump({fam: {"pr_url": url, "first_seen": int(first), "last_checked": int(first),
                 "suppressed_total": 0, "beat_day": day, "stale_beat_at": int(stale)}},
          open(p, "w"))
PY
}
led_get() {  # led_get <fam> <field> — "" when absent, ERR when the file is not json
  python3 - "$LED" "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("ERR"); raise SystemExit(0)
e = d.get(sys.argv[2])
print("" if not isinstance(e, dict) else e.get(sys.argv[3], ""))
PY
}
led_keys() {
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("ERR"); raise SystemExit(0)
print(" ".join(sorted(d)) if isinstance(d,dict) else "ERR")' "$LED"
}

run() {  # run [VAR=VAL ...] — one tick, at TNOW (default NOW)
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  # HARNESS is passed explicitly as well as sed-repointed: the script's default
  # is "${HARNESS:-/root/harness}", so an exported HARNESS in the caller's
  # environment would otherwise send this fixture at the live harness root.
  ( export HARNESS="$H" CALLDIR="$T/calls" PATH="$T/stub:$PATH" TRIAGE_NOW="${TNOW:-$NOW}"
    [ "$#" -gt 0 ] && export "$@"
    triage_tick "$H/bin/alert-triage.sh" ) >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
# One REST pull read = one state check. `pr view` is counted separately and must
# always be zero: it is the GraphQL read #768 was about.
ghviews()    { grep -c 'pulls/' "$GHLOG" 2>/dev/null || true; }
ghgraphql()  { grep -c 'pr view' "$GHLOG" 2>/dev/null || true; }

reset_all() {
  triage_tick_reset "$H"; mkdir -p "$HP"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"
  : > "$BEATS"; : > "$BEATS.nonstrict"; : > "$GHLOG"
  rm -f "$PRFAIL" "$H/flags/fixpr-suppress-off"
  : > "$H/env/global.env"; rm -f "$H/env/github-app.env" "$H/bin/gh-token.sh"
  echo '{}' > "$H/state/alert-families.json"
  echo '{}' > "$LED"
  : > "$H/state/alert-triage-deferred.tsv"
  : > "$Q"
  echo OPEN > "$PRSTATE"
  unset FIXPR_STUB_LINE TNOW 2>/dev/null || true
}

# ══ 1. an OPEN fix PR buys NO session ════════════════════════════════════════
reset_all
FA=$(famkey alpha)
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
run
[ "$(ncalls)" = 0 ] && ok || bad "an OPEN fix PR must buy no session (got $(ncalls) dispatches)"
grep -q "ANSWERED-PENDING-MERGE family=$FA lines=1 total=1 fix=$URL" "$H/logs/alert-triage.log" \
  && ok || bad "the lane log must carry ANSWERED-PENDING-MERGE with the url and the count (got: $(tail -2 "$H/logs/alert-triage.log"))"
grep -q 'repos/example-org/cromford/pulls/573' "$GHLOG" \
  && ok || bad "the PR state must be read deterministically over REST (got: $(cat "$GHLOG"))"
# #768: a rate-limited `gh pr view` answers an EMPTY STRING a decision path
# reads as "no such PR". This lane must never make that read (F1c).
[ "$(ghgraphql)" = 0 ] \
  && ok || bad "the state read must not go through GraphQL gh pr view (got: $(cat "$GHLOG"))"
[ "$(ghviews)" = 1 ] && ok || bad "one state read per answered family per tick (got $(ghviews))"
# the 6h brake must never learn about a family it did not triage, or the
# suppression would outlive the PR by six hours with no record of why
[ "$(cat "$HP/alert-families.json")" = '{}' ] \
  && ok || bad "an answered family must NOT be stamped into the 6h brake (got: $(cat "$HP/alert-families.json"))"
[ "$(led_get "$FA" last_checked)" -ge "$NOW" ] \
  && ok || bad "last_checked must move on a positive check (got $(led_get "$FA" last_checked), NOW=$NOW)"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "an answered line is answered, not deferred — the spool must stay empty"
# The pass line must be true in the state that renders it: these lines were not
# "repeats of families triaged <6h ago", nobody has ever triaged this one.
grep -q "all 1 line(s) are repeats (<6h) or answered by an open fix PR — no session" "$H/logs/alert-triage.log" \
  && ok || bad "the no-session pass line must say WHY there was no session (got: $(tail -1 "$H/logs/alert-triage.log"))"
! grep -q 'repeats of families triaged <6h ago' "$H/logs/alert-triage.log" \
  && ok || bad "an answered family must not be reported as a 6h repeat"

# ══ 2. exactly ONE beat per day, not one per tick ════════════════════════════
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
run
seed alpha
run
[ "$(grep -c "\"akey\":\"triage-fixpr:$FA\"" "$BEATS")" = 1 ] \
  && ok || bad "two ticks in one day must produce exactly ONE beat (got $(grep -c 'triage-fixpr:' "$BEATS"))"
grep -q "Merge it: $URL" "$BEATS" \
  && ok || bad "the beat must name the merge as the action, with the url (got: $(cat "$BEATS"))"
grep -q "ANSWERED-PENDING-MERGE family=$FA lines=1 total=2 " "$H/logs/alert-triage.log" \
  && ok || bad "the cumulative total must be real on the second tick (got: $(grep -c ANSWERED-PENDING "$H/logs/alert-triage.log") lines: $(tail -1 "$H/logs/alert-triage.log"))"
[ "$(ghviews)" = 2 ] && ok || bad "each tick re-reads the PR state (got $(ghviews))"
# F2: without BEAT_STRICT=1 the real beat.sh returns 0 for a beat the console
# never took, and the day would be stamped for a message nobody got.
[ ! -s "$BEATS.nonstrict" ] \
  && ok || bad "every beat must be sent with BEAT_STRICT=1 (non-strict sends: $(cat "$BEATS.nonstrict"))"

# ══ 3. MERGED (and CLOSED) drops the entry and triages normally ══════════════
for STATE in MERGED CLOSED; do
  reset_all
  seed alpha
  ledger "$FA" "$URL" "$((NOW - 3600))"
  echo "$STATE" > "$PRSTATE"
  run
  [ "$(ncalls)" = 1 ] && ok || bad "$STATE must send the family back to normal triage (got $(ncalls) dispatches)"
  [ "$(led_keys)" = "" ] && ok || bad "$STATE must drop the ledger entry (got: $(led_keys))"
  grep -q "is $STATE — entry dropped" "$H/logs/alert-triage.log" \
    && ok || bad "the drop must be declared in the lane log (got: $(tail -2 "$H/logs/alert-triage.log"))"
  [ "$(grep -c 'ANSWERED-PENDING-MERGE' "$H/logs/alert-triage.log")" = 0 ] \
    && ok || bad "$STATE must not be logged as answered"
done

# ══ 4. a family with no recorded PR is unaffected ════════════════════════════
reset_all
FB=$(famkey bravo)
seed alpha bravo
ledger "$FA" "$URL" "$((NOW - 3600))"
run
[ "$(ncalls)" = 1 ] && ok || bad "only the unanswered family may buy a session (got $(ncalls))"
grep -q 'the bravo subsystem' "$T/calls/prompt-0.txt" \
  && ok || bad "the session must be the family with no recorded PR"
! grep -q 'the alpha subsystem' "$T/calls/prompt-0.txt" \
  && ok || bad "the answered family's lines must not ride along in the other family's prompt"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if list(d)==[sys.argv[2]] else 1)' \
  "$HP/alert-families.json" "$FB" \
  && ok || bad "only the dispatched family may be stamped (got: $(cat "$HP/alert-families.json"))"
# ...and with NO ledger file at all, today's path is exactly today's path
reset_all
rm -f "$LED"
seed alpha bravo
run
[ "$(ncalls)" = 2 ] && ok || bad "a missing ledger must leave every family buying its session (got $(ncalls))"
[ "$(ghviews)" = 0 ] && ok || bad "a missing ledger must cost no gh reads (got $(ghviews))"

# ══ 5. past FIXPR_STALE_HOURS the line changes, and is emitted ONCE ══════════
# No FIXPR_STALE_HOURS in the environment: the 24h default is what is under test.
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 25 * 3600))"
run
grep -q 'FIX PR STALE' "$H/logs/alert-triage.log" \
  && ok || bad "a fix PR open past the stale window must be recorded in the lane log (got: $(tail -3 "$H/logs/alert-triage.log"))"
grep -q "open for 25h" "$H/logs/alert-triage.log" \
  && ok || bad "the stale line must carry the REAL hours open (got: $(tail -3 "$H/logs/alert-triage.log"))"
# F3: bin/poll-commands.sh re-beats every NEW ALERTS.log line on its own akey
# (hub cron, every minute). Writing the escalation there AND beating it paged
# twice a day for one stale PR. The beat below is the escalation; ALERTS.log
# stays out of it.
[ "$(grep -c 'FIX PR STALE' "$H/logs/ALERTS.log")" = 0 ] \
  && ok || bad "the stale escalation must not ALSO go to ALERTS.log — poll-commands re-beats it (got: $(cat "$H/logs/ALERTS.log"))"
[ "$(grep -c "\"akey\":\"triage-fixpr-stale:$FA\"" "$BEATS")" = 1 ] \
  && ok || bad "the stale escalation must beat once, on its own akey (got: $(cat "$BEATS"))"
[ "$(grep -c "\"akey\":\"triage-fixpr:$FA\"" "$BEATS")" = 0 ] \
  && ok || bad "the louder line REPLACES the day's daily beat, it does not add to it (got: $(cat "$BEATS"))"
[ "$(led_get "$FA" stale_beat_at)" -ge "$NOW" ] \
  && ok || bad "stale_beat_at must be stamped after the send (got: $(led_get "$FA" stale_beat_at))"
seed alpha
run
[ "$(grep -c 'FIX PR STALE' "$H/logs/alert-triage.log")" = 1 ] \
  && ok || bad "the stale escalation must be emitted ONCE, not every tick (got $(grep -c 'FIX PR STALE' "$H/logs/alert-triage.log"))"
[ "$(grep -c 'triage-fixpr-stale:' "$BEATS")" = 1 ] \
  && ok || bad "the stale beat must not repeat on the next tick (got: $(cat "$BEATS"))"
# the negative: under the configured window nothing escalates loudly
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 25 * 3600))"
run FIXPR_STALE_HOURS=48
[ "$(grep -c 'FIX PR STALE' "$H/logs/alert-triage.log")" = 0 ] \
  && ok || bad "25h under a 48h window must not escalate (got: $(tail -3 "$H/logs/alert-triage.log"))"
[ "$(grep -c "\"akey\":\"triage-fixpr:$FA\"" "$BEATS")" = 1 ] \
  && ok || bad "it must still send the ordinary daily beat (got: $(cat "$BEATS"))"

# ══ 6. a session that names an OPEN PR gets it recorded ═════════════════════
reset_all
seed alpha
run FIXPR_STUB_LINE="FIX-PR: $URL"
grep -q 'FIX-PR: https://github.com/<owner>/<repo>/pull/<n>' "$T/calls/prompt-0.txt" \
  && ok || bad "the prompt's step 4 must state the FIX-PR contract"
[ "$(led_get "$FA" pr_url)" = "$URL" ] \
  && ok || bad "a session naming an OPEN PR must be recorded under its family key (ledger: $(led_keys))"
grep -q "named fix PR $URL (OPEN) — recorded" "$H/logs/alert-triage.log" \
  && ok || bad "the recording must be declared in the lane log (got: $(tail -1 "$H/logs/alert-triage.log"))"
# the next occurrence buys nothing. The 6h brake is cleared first, or this
# assertion would pass on the TTL alone and prove nothing about the ledger.
echo '{}' > "$HP/alert-families.json"
seed alpha
run
[ "$(ncalls)" = 0 ] && ok || bad "the tick after a recording must buy no session (got $(ncalls))"
grep -q "ANSWERED-PENDING-MERGE family=$FA" "$H/logs/alert-triage.log" \
  && ok || bad "the tick after a recording must log the family as answered"
# negatives: a MERGED url at record time, a non-PR path, a mid-line mention, no url
for NEG in "MERGED:FIX-PR: $URL" \
           "OPEN:FIX-PR: https://github.com/example-org/cromford/issues/573" \
           "OPEN:see FIX-PR: $URL" \
           "OPEN:FIX-PR: PR #573"; do
  reset_all
  echo "${NEG%%:*}" > "$PRSTATE"
  seed alpha
  run FIXPR_STUB_LINE="${NEG#*:}"
  [ "$(led_keys)" = "" ] \
    && ok || bad "must NOT record [${NEG#*:}] at state ${NEG%%:*} (ledger: $(led_keys))"
done

# ══ 7. gh fails → fail OPEN (the session is bought, the entry is kept) ═══════
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
touch "$PRFAIL"
run
[ "$(ncalls)" = 1 ] && ok || bad "an unreadable PR state must NOT suppress (got $(ncalls) dispatches)"
[ "$(led_get "$FA" pr_url)" = "$URL" ] \
  && ok || bad "a failed check must keep the entry for the next tick (ledger: $(led_keys))"
grep -q 'could not be checked' "$H/logs/alert-triage.log" \
  && ok || bad "the failed check must say so in the lane log (got: $(tail -2 "$H/logs/alert-triage.log"))"
[ "$(grep -c 'ANSWERED-PENDING-MERGE' "$H/logs/alert-triage.log")" = 0 ] \
  && ok || bad "a family whose PR could not be read is not answered"

# ══ 8. a torn ledger → fail OPEN ════════════════════════════════════════════
reset_all
seed alpha
printf '{"%s":' "$FA" > "$LED"
run
[ "$(ncalls)" = 1 ] && ok || bad "an unparseable ledger must NOT suppress (got $(ncalls) dispatches)"
grep -q 'ledger unreadable' "$H/logs/alert-triage.log" \
  && ok || bad "an unparseable ledger must be declared, not silently empty (got: $(tail -2 "$H/logs/alert-triage.log"))"
[ "$(led_keys)" != ERR ] \
  && ok || bad "the ledger must be valid json again after the tick (got: $(cat "$LED"))"
# an entry with no pr_url is the same class of doubt
reset_all
seed alpha
python3 -c 'import json,sys; json.dump({sys.argv[2]: {"first_seen": 1}}, open(sys.argv[1], "w"))' "$LED" "$FA"
run
[ "$(ncalls)" = 1 ] && ok || bad "an entry with no pr_url must NOT suppress (got $(ncalls))"
[ "$(ghviews)" = 0 ] && ok || bad "an entry with no url has nothing to check (got $(ghviews) gh reads)"

# ══ 9. kill switch: today's behaviour back, entries still recorded ═══════════
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
touch "$H/flags/fixpr-suppress-off"
run
[ "$(ncalls)" = 1 ] && ok || bad "flags/fixpr-suppress-off must restore today's behaviour (got $(ncalls) dispatches)"
[ "$(ghviews)" = 0 ] && ok || bad "the kill switch must skip the check entirely (got $(ghviews) gh reads)"
[ "$(led_get "$FA" pr_url)" = "$URL" ] \
  && ok || bad "the kill switch must not discard the ledger (ledger: $(led_keys))"
[ "$(grep -c 'ANSWERED-PENDING-MERGE' "$H/logs/alert-triage.log")" = 0 ] \
  && ok || bad "nothing is answered while the kill switch is on"
reset_all
touch "$H/flags/fixpr-suppress-off"
seed alpha
run FIXPR_STUB_LINE="FIX-PR: $URL"
[ "$(led_get "$FA" pr_url)" = "$URL" ] \
  && ok || bad "entries must still be RECORDED while the kill switch is on (ledger: $(led_keys))"

# ══ 10. send THEN stamp: a beat that failed leaves no stamp behind ═══════════
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
run BEAT_FAIL=1
[ -z "$(led_get "$FA" beat_day)" ] \
  && ok || bad "a beat that did not send must leave beat_day unstamped (got: $(led_get "$FA" beat_day))"
seed alpha
run
[ "$(grep -c "\"akey\":\"triage-fixpr:$FA\"" "$BEATS")" = 1 ] \
  && ok || bad "the next tick must retry the send that failed (got: $(cat "$BEATS"))"
[ -n "$(led_get "$FA" beat_day)" ] \
  && ok || bad "a delivered beat must stamp the day (got: $(led_get "$FA" beat_day))"
# rc 2 is "this box has no console configured" — there is nothing to retry, so
# it counts as delivered. Without this a console-less box would re-run the whole
# answered loop's send every tick forever.
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
run BEAT_NOCONSOLE=1
[ -n "$(led_get "$FA" beat_day)" ] \
  && ok || bad "a box with no console configured (rc 2) must still stamp the day (got: $(led_get "$FA" beat_day))"

# ══ 11. a different PR named later replaces the url, keeping first_seen ══════
reset_all
seed alpha
ledger "$FA" "$URL" "$((NOW - 3600))"
echo '{}' > "$HP/alert-families.json"
touch "$H/flags/fixpr-suppress-off"   # so the family still buys its session
run FIXPR_STUB_LINE="FIX-PR: $URL2"
[ "$(led_get "$FA" pr_url)" = "$URL2" ] \
  && ok || bad "the latest word wins on the url (got: $(led_get "$FA" pr_url))"
[ "$(led_get "$FA" first_seen)" = "$((NOW - 3600))" ] \
  && ok || bad "an upsert must keep first_seen (got: $(led_get "$FA" first_seen))"

# ══ 12. the state read is ARMED, and it cannot cost the lane its own token ═══
# F1a/F1b. The per-tick read used to run bare (the keyring PAT) while the
# record-time read ran on the App token, so a PR the App installation can see
# and the PAT cannot was recorded OPEN and then "could not be checked" every
# tick forever. And the arming itself used to run in THIS shell, with
# gh_auth_reset restoring a snapshot taken before env/global.env was loaded —
# which unset GH_TOKEN for every later step of the same tick (BH-470).
arm_box() {  # an App-token box: github-app.env readable, gh-token.sh executable
  : > "$H/env/github-app.env"
  printf '#!/bin/sh\nprintf "app-token-%%s\\n" "$1"\n' > "$H/bin/gh-token.sh"
  chmod +x "$H/bin/gh-token.sh"
  printf 'GH_TOKEN=the-fleet-PAT\n' > "$H/env/global.env"
}
# BH-5942: the session now runs on its project run's App token
# (app-token-example-org/cromford, from llp_arm). The fix PR here is in
# ANOTHER repo, so the state read's token differs from the session's and a
# leak of the arming into the session still shows.
URL12="https://github.com/example-org/projfix-other/pull/573"
reset_all
arm_box
FB=$(famkey bravo)
seed alpha bravo
ledger "$FA" "$URL12" "$((NOW - 3600))"
run
grep -q 'tok=app-token-example-org/projfix-other .*pulls/573' "$GHLOG" \
  && ok || bad "the per-tick state read must run on the repo's App token (got: $(cat "$GHLOG"))"
[ "$(cat "$T/calls/token-0" 2>/dev/null)" = app-token-example-org/cromford ] \
  && ok || bad "the arming must not change the lane's own GH_TOKEN (the session saw: $(cat "$T/calls/token-0" 2>/dev/null))"
[ "$(ncalls)" = 1 ] && ok || bad "only the unanswered family may buy a session on an armed box (got $(ncalls))"
# and the record-time read is the same reader on the same identity
reset_all
arm_box
seed alpha
run FIXPR_STUB_LINE="FIX-PR: $URL12"
grep -q 'tok=app-token-example-org/projfix-other .*pulls/573' "$GHLOG" \
  && ok || bad "the record-time state read must run on the repo's App token too (got: $(cat "$GHLOG"))"
[ "$(ghgraphql)" = 0 ] \
  && ok || bad "neither read may go through GraphQL (got: $(cat "$GHLOG"))"
[ "$(led_get "$FA" pr_url)" = "$URL12" ] \
  && ok || bad "an armed box must still record the OPEN PR (ledger: $(led_keys))"
[ "$(cat "$T/calls/token-0" 2>/dev/null)" = app-token-example-org/cromford ] \
  && ok || bad "the session must still run on the lane's own token (saw: $(cat "$T/calls/token-0" 2>/dev/null))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
