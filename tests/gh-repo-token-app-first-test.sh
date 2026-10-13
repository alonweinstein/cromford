#!/bin/bash
# tests/gh-repo-token-app-first-test.sh — bin/lib/gh-repo-token.sh asks the App
# installation token FIRST, and says which of the three rungs it tried.
#
# WHY (BH-765, 2026-09-18). The probe knew two credentials: the default PAT and
# the org-admin PAT. Every one of its ~22 consumers therefore spent the ONE
# GH_ADMIN_TOKEN 5000/h bucket for repos the default PAT cannot see, while the
# App installation token — per installation, 6600/h here, already minted and
# cached on disk by bin/gh-token.sh — was never asked. The ladder is now
# app -> default -> admin, and the invisible-repo alert names what each rung
# answered instead of leaving an operator to guess.
#
# WHAT THIS SUITE PINS, driving the REAL lib in a scratch $HARNESS with a fake
# bin/gh-token.sh and a gh shim:
#   * which rung wins, per repo, and that the loser rungs are still asked
#   * an `app` verdict is never given to a token that is really the PAT (the
#     minter prints the PAT when a mint fails) or to one the repo 404s on
#   * an unarmed box spawns NO process at all for the App rung
#   * the lib and bin/gh-token.sh cannot recurse into each other
#   * the perishable `app` verdict is re-probed after GHRT_TOKEN_MIN_LIFE
#   * no token value reaches a log or a beat
#
# Run from anywhere: tests/gh-repo-token-app-first-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
: > "$T/env/github-app.env"          # armed: gh_auth_armed wants this readable
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# ── the fake minter ──────────────────────────────────────────────────────────
# Logs the argv it was called with, prints `apptok`, and — with $T/mint-fails —
# does what the real bin/gh-token.sh does when a mint fails: prints the PAT.
# With $T/pat-for-recurses it also does what the real script's pat_for does:
# source the lib and ask it which PAT can see the repo. That is the cycle this
# suite has to be able to reach, or the guard against it proves nothing.
cat > "$T/bin/gh-token.sh" <<'MINT'
#!/bin/bash
printf '%s\n' "$*" >> "$MINT_LOG"
if [ -z "${_GHRT_NO_APP:-}" ] && [ -f "$T/pat-for-recurses" ]; then
  # shellcheck source=/dev/null
  . "$T/bin/lib/gh-repo-token.sh"
  gh_repo_use_token "${!#}" >/dev/null 2>&1
fi
if [ -f "$T/mint-fails" ]; then printf '%s\n' "${GH_TOKEN:-pattok}"; else printf 'apptok\n'; fi
MINT
chmod +x "$T/bin/gh-token.sh"

# ── the gh shim ──────────────────────────────────────────────────────────────
# o/seen   — any token; o/apponly — only apptok; o/adminonly — only admintok;
# o/blind  — nobody. Every call is logged WITH the identity it went out on, so
# "which rung was asked" is read from behaviour, not from source text.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf 'GH_TOKEN=%s %s\n' "${GH_TOKEN:-unset}" "$*" >> "$GH_LOG"
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/apponly -q .id")   [ "${GH_TOKEN:-}" = apptok ]   && exit 0; exit 1 ;;
  "api repos/o/adminonly -q .id") [ "${GH_TOKEN:-}" = admintok ] && exit 0; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

MINT_LOG="$T/mint.log"; GH_LOG="$T/gh.log"
reset_logs() { : > "$MINT_LOG"; : > "$GH_LOG"; }
drive() { # drive <snippet> [GH_TOKEN value; unset when empty]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" BEAT_SINK="$T/beats.txt" \
           MINT_LOG="$MINT_LOG" GH_LOG="$GH_LOG"
    if [ -n "${2:-}" ]; then export GH_TOKEN="$2"; else unset GH_TOKEN; fi
    # shellcheck source=/dev/null
    . "$T/bin/lib/gh-repo-token.sh"; eval "$1" )
}
mints()  { grep -c . "$MINT_LOG" 2>/dev/null || true; }
apptok_calls() { grep -c '^GH_TOKEN=apptok ' "$GH_LOG" 2>/dev/null || true; }

# ── L1 — the App token wins a repo only it can see ───────────────────────────
reset_logs
[ "$(drive 'gh_repo_token_for o/apponly')" = app ] && ok \
  || bad "L1: a repo only the App token can see must route to it, got '$(drive 'gh_repo_token_for o/apponly')'"
reset_logs; drive 'gh_repo_token_for o/apponly >/dev/null'
[ "$(mints)" = 1 ] && ok || bad "L1: expected exactly one mint, log: $(cat "$MINT_LOG")"
grep -qx -- '--min-life 1800 o/apponly' "$MINT_LOG" && ok \
  || bad "L1: the mint must ask for a token with real life left, got: $(cat "$MINT_LOG")"

# ── L2 — the App token wins even when the default PAT can see the repo ───────
reset_logs
[ "$(drive 'gh_repo_token_for o/seen')" = app ] && ok \
  || bad "L2: the App rung must be asked before the default PAT"
reset_logs; drive 'gh_repo_token_for o/seen >/dev/null'
[ "$(apptok_calls)" = 1 ] && ok \
  || bad "L2: expected exactly one probe on the App token, log: $(cat "$GH_LOG")"

# ── L3 — an unarmed box spawns nothing at all on the App rung ────────────────
touch "$T/flags/gh-app-tokens-off"; reset_logs
[ "$(drive 'gh_repo_token_for o/seen')" = default ] && ok \
  || bad "L3: with App tokens off the ladder must fall straight to the default PAT"
[ "$(mints)" = 0 ] && ok || bad "L3: an unarmed box must not spawn the minter, log: $(cat "$MINT_LOG")"
rm -f "$T/flags/gh-app-tokens-off"

# ── L4 — an App token the repo 404s on falls through to the PATs ─────────────
reset_logs
[ "$(drive 'gh_repo_token_for o/adminonly')" = admin ] && ok \
  || bad "L4: an App token that cannot see the repo must fall through to the admin PAT"

# ── L5 — nobody can see it ───────────────────────────────────────────────────
[ "$(drive 'gh_repo_token_for o/blind')" = none ] && ok || bad "L5: a repo nobody sees must read none"
[ "$(drive 'gh_repo_use_token o/blind; echo rc=$? tok=${GH_TOKEN:-unset}')" = "rc=1 tok=unset" ] && ok \
  || bad "L5: use_token on a blind repo must rc 1 and leave the caller's token"

# ── L6 — a mint that printed the PAT is never labelled `app` ─────────────────
touch "$T/mint-fails"; reset_logs
[ "$(drive 'gh_repo_token_for o/seen' pattok)" = default ] && ok \
  || bad "L6: gh-token.sh prints the PAT when a mint fails — that must never read as an App token"
rm -f "$T/mint-fails"

# ── L7 — use_token exports the App token; reset puts the caller's back ───────
[ "$(drive 'gh_repo_use_token o/apponly; printf %s "${GH_TOKEN:-unset}"')" = apptok ] && ok \
  || bad "L7: use_token did not export the App token"
[ "$(drive 'gh_repo_use_token o/apponly; gh_repo_token_reset; printf %s "${GH_TOKEN:-unset}"')" = unset ] && ok \
  || bad "L7: reset must unset GH_TOKEN when the caller started without one"
[ "$(drive 'gh_repo_use_token o/apponly; gh_repo_token_reset; printf %s "${GH_TOKEN:-unset}"' pattok)" = pattok ] && ok \
  || bad "L7: reset must put back the token the caller started with"

# ── L8 — the lib and the minter cannot recurse into each other ───────────────
touch "$T/pat-for-recurses" "$T/mint-fails"; reset_logs
OUT=$(T="$T" MINT_LOG="$MINT_LOG" GH_LOG="$GH_LOG" timeout 20 bash -c '
  export PATH="$T/fakebin:$PATH" HARNESS="$T" BEAT_SINK="$T/beats.txt" \
         MINT_LOG="$MINT_LOG" GH_LOG="$GH_LOG" GH_TOKEN=pattok
  . "$T/bin/lib/gh-repo-token.sh"; gh_repo_token_for o/seen'); RC=$?
[ "$RC" = 0 ] && ok || bad "L8: the lib/minter pair did not terminate (rc=$RC; 124 = timeout)"
[ "$OUT" = default ] && ok || bad "L8: expected 'default' out of the guarded path, got '$OUT'"
rm -f "$T/pat-for-recurses" "$T/mint-fails"

# ── L9 — the words, and no token value anywhere near a log or a beat ─────────
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"; rm -f "$T"/flags/alerted-repo-invisible-*
drive 'gh_repo_invisible_alert lane o/blind "3 approved PRs skipped"'
grep -q 'Tried: tried the App installation token: could not see it; the default PAT: blind; the admin PAT: blind\.$' "$T/logs/ALERTS.log" \
  && ok || bad "L9: the alert must say what each rung answered: $(cat "$T/logs/ALERTS.log")"
rm -f "$T"/flags/alerted-repo-invisible-*
drive 'gh_repo_invisible_alert lane o/adminonly "a check skipped"'
grep -q 'the admin PAT: CAN see it — route this consumer through it\.$' "$T/logs/ALERTS.log" \
  && ok || bad "L9: a repo the admin PAT CAN see must say so: $(tail -1 "$T/logs/ALERTS.log")"
grep -rqE 'apptok|admintok' "$T/logs" "$T/beats.txt" \
  && bad "L9: a token VALUE reached a log or a beat" || ok

# ── L10 — the PAT-only question is still askable ─────────────────────────────
# bin/claude-auth-check.sh's canary says "DEFAULT GH TOKEN CANNOT SEE <repo>",
# which is a sentence about the PATs. Fed the merged verdict it would go silent
# on a repo the default PAT is blind to just because an App token saw it.
[ "$(drive 'gh_repo_pat_for o/apponly')" = none ] && ok \
  || bad "L10: gh_repo_pat_for must answer the PAT-only question"
[ "$(drive 'gh_repo_token_for o/apponly')" = app ] && ok \
  || bad "L10: …while gh_repo_token_for answers the ladder's"

# ── L11 — sourcing the lib twice does not capture an App token as the default ─
# bin/merge-conductor.sh sources it, then merge-conductor-lib.sh sources it
# again: without the load guard the second pass would read GH_TOKEN (by then an
# App token) as "the caller's" and reset to it for ever after.
OUT=$(drive 'gh_repo_use_token o/apponly; . "$T/bin/lib/gh-repo-token.sh"; gh_repo_token_reset; printf %s "${GH_TOKEN:-unset}"' pattok)
[ "$OUT" = pattok ] && ok || bad "L11: a second source captured the App token as the caller's, got '$OUT'"

# ── L12 — an `app` verdict is perishable ─────────────────────────────────────
# An installation token dies in an hour. A long-lived process (the fly-pool reap
# loop, the conductor) that cached `app` at minute 0 must re-probe, not hand out
# a verdict about a credential GitHub has since killed.
reset_logs
OUT=$(drive 'gh_repo_token_for o/apponly >/dev/null
             _GHRT_APP_AT[o/apponly]=$(( $(date +%s) - _GHRT_MIN_LIFE - 1 ))
             gh_repo_token_for o/apponly')
[ "$OUT" = app ] && ok || bad "L12: the re-probe must still answer app, got '$OUT'"
[ "$(mints)" = 2 ] && ok || bad "L12: an aged-out app verdict must be re-probed, mints: $(cat "$MINT_LOG")"

echo "gh-repo-token-app-first: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
