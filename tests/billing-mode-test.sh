#!/bin/bash
# tests/billing-mode-test.sh — bin/billing-mode.sh across runner x credential.
#
# The classification is per-BOX, not per-runner: the same `claude` runner is
# flat-rate where an OAuth token is present and per-token on the api-key box.
# Getting it backwards on one box mis-states the fleet's spend in whichever
# direction that box is busiest, so every combination is pinned.
#
# The conservative default matters as much as the positives: an unrecognised
# runner must be `unknown`, never a guess. Guessing subscription hides real
# cash; guessing metered invents spend that was never billed.
# Run from anywhere: tests/billing-mode-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BM="$DIR/bin/billing-mode.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# mode <expected> <runner> [env assignments...] — env is scrubbed each call so a
# leaked variable from the host cannot make a case pass for the wrong reason.
mode() {
  local want="$1" runner="$2"; shift 2
  local got
  got=$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u GROK_BILLING \
        -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u GEMINI_API_KEY \
        "$@" bash "$BM" "$runner" 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "runner=$runner ${*:-（no env)} -> got '$got', want '$want'"
}

# ---------- claude: the box decides ----------
mode subscription claude CLAUDE_CODE_OAUTH_TOKEN=tok
mode subscription claude                                   # neither credential
mode metered      claude ANTHROPIC_API_KEY=sk-x            # the project-10 api-key box
# Both present = the OAuth subscription serves the call, so it is not cash.
# Getting this one wrong is the expensive direction: it would count every call
# on every subscription box as spend.
mode subscription claude ANTHROPIC_API_KEY=sk-x CLAUDE_CODE_OAUTH_TOKEN=tok
# An empty string is not a credential.
mode subscription claude ANTHROPIC_API_KEY=

# ---------- codex: flat, even where an API key exists as a fallback ----------
mode subscription codex
mode subscription codex CODEX_API_KEY=sk-x
mode subscription codex OPENAI_API_KEY=sk-x

# ---------- grok: the switch that cost $460 in two days ----------
mode subscription grok
mode metered      grok GROK_BILLING=api
mode subscription grok GROK_BILLING=subscription
mode subscription grok GROK_BILLING=            # empty is not "api"

# ---------- vendors with no subscription tier ----------
mode metered openrouter
mode metered fireworks
# ...and they stay metered regardless of environment, because there is no plan
# under which those calls are free.
mode metered openrouter CLAUDE_CODE_OAUTH_TOKEN=tok
mode metered fireworks  GROK_BILLING=subscription

# ---------- gemini: same shape as claude, and for the same reason ----------
# agent-call accepts gemini via EITHER an OAuth creds file or GEMINI_API_KEY, so
# the runner name alone does not mean cash. HOME is redirected so the creds-file
# check is deterministic rather than depending on whoever runs the suite.
GH="$T/gh"; mkdir -p "$GH"
mkdir -p "$GH/.gemini"
gmode() {
  local want="$1"; shift
  local got; got=$(env -u GEMINI_API_KEY HOME="$GH" "$@" bash "$BM" gemini 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "gemini ${*:-(no env)} -> got '$got', want '$want'"
}
gmode subscription                                   # neither credential
gmode metered      GEMINI_API_KEY=k                  # api key, no creds file
: > "$GH/.gemini/oauth_creds.json"
gmode subscription                                   # creds file only
# Both present: OAuth serves the call, so it is not cash — the same rule that
# keeps the project-10 both-credentials box from overstating on the claude lane.
gmode subscription GEMINI_API_KEY=k
rm -f "$GH/.gemini/oauth_creds.json"

# ---------- the conservative default ----------
for R in "" "codexx" "claude-5" "some-new-runner" "grok "; do
  mode unknown "$R"
done

# ---------- it is a pure classifier ----------
# No writes, no network, no dependence on cwd — it is called once per agent call
# on every box, and a classifier with side effects would be a liability.
T=$(mktemp -d "$T/t-XXXXXX")
( cd "$T" && bash "$BM" claude >/dev/null 2>&1 )
[ -z "$(ls -A "$T")" ] && ok || bad "billing-mode.sh wrote something to cwd: $(ls -A "$T")"

echo "billing-mode-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
