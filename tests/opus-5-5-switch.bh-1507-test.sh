#!/bin/bash
# tests/opus-5-5-switch.bh-1507-test.sh — every Opus lane moves to Opus 5.5
# (`claude-opus-5-5`), the reviewer too, priced, with a CLI floor (BH-1507).
#
# WHY. the operator, 2026-09-22: "use Opus 5.5 instead of Opus 5 everywhere the harness
# uses Opus", and the same day: the harness reviewer moves to Opus 5.5 too.
# Three things make that more than a string swap, and each has a section here:
#   A. COST-CAPTURE PARITY. A lane that runs on a model the price table does not
#      carry writes rows nobody can price. Both ids (the CLI's and OpenRouter's)
#      are priced before anything calls them, and the Opus 5 rows stay so the
#      history and any lane pinned to 5 still price.
#   B. EVERY DEFAULT MOVES — the Opus lanes and the review lanes. A missed one
#      is a lane quietly still on the old model. Each default is RESOLVED here
#      (the line is run with the variable unset), not grepped for a substring;
#      review-prs.sh, which passed claude-fable-5-1 literally, now asks
#      bin/lib/review-model.sh.
#   C/D. THE CLI FLOOR. Claude Code 2.1.278 refuses the id with "isn't described
#      by this version's model catalog". A box or a Fly image one release
#      behind must degrade to Opus 5 with one ALERTS line naming its CLI
#      version, never fail the build. The review lane's tail is Fable 5.1
#      instead. Driven through bin/agent-call.sh with a stub `claude` that
#      answers that exact string.
# Where a model is SET is not this ticket's business: #1510 moves every model
# id into a model_routes table, so this suite pins defaults and ladders only.
# #1510.1 DELETED the build lanes' literal defaults (run-build, rb/gates, the
# fly builder, blocked-resolver, review-autopilot/-rescue/-prs, postmerge-qa,
# cost-readout, bin/lib/review-model.sh): those lanes now read model_routes, so
# "the default resolves to 5.5" is proven where it now lives — against a stubbed
# worker answering #1507's table, in tests/model-routes-build-lanes.bh-1510-1-test.sh.
# The lanes #1510.2 has not converted keep their literal checks below. Section
# C/D drives agent-call against the same stubbed table: the ladder is a row now.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# The pipeline is read as the flatten (BH-478), never the raw driver.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NEW=claude-opus-5-5
# What a stale CLI really answers in agent-call's mode (`-p --output-format
# json`), captured from Claude Code 2.1.278 against claude-opus-5-5 (the #1523
# review reproduced the same on 2.1.267): rc 1, this envelope on stdout, the tag
# line on stderr.
STALE_JSON='{"type":"result","subtype":"success","is_error":true,"api_error_status":400,"duration_ms":912,"duration_api_ms":0,"num_turns":1,"result":"API Error: 400 Claude Code 2.1.278 does not support this model; version 2.1.280 or newer is required. Run '"'"'claude update'"'"', or pick a different model with --model.","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
STALE_ERR='[claude-code:unrecognized_model] {"model":"claude-opus-5-5","query_source":"sdk"}'
# The TEXT-mode warning (not what agent-call sees, kept as a second case).
CATALOG_ERR="There's an issue with the selected model ($NEW). It isn't described by this version's model catalog. Run --model to pick a different model."

# =============================================================================
# A. PRICES — both ids, the rates the ticket states, Opus 5 kept
# =============================================================================
PR="$DIR/catalog/model-prices.json"
for m in "$NEW" anthropic/claude-opus-5.5; do
  # Compared as numbers: jq keeps a literal's spelling (2E-7 vs 2e-07).
  jq -e --arg m "$m" '.per_token[$m] | .prompt == 0.000004 and .completion == 0.00002
      and .cache_read == 0.0000002 and .cache_write == 0.000005 and .slug == "anthropic/claude-opus-5.5"' "$PR" >/dev/null 2>&1 \
    && ok || bad "A1 $m is not priced at 4/20/0.2/5 per M with slug anthropic/claude-opus-5.5: $(jq -c --arg m "$m" '.per_token[$m]' "$PR")"
done
for m in claude-opus-5 anthropic/claude-opus-5; do
  jq -e --arg m "$m" '.per_token[$m].prompt' "$PR" >/dev/null 2>&1 \
    && ok || bad "A2 the $m row was dropped — history and pinned lanes stop pricing"
done
# The proof is a dollar figure, from the real pricing function.
. "$DIR/bin/lib/cost-row.sh"
P=$(MODEL_PRICES="$PR" cost_price_tokens "$NEW" 1000000 1000000 1000000 1000000)
[ "$P" = 29.200000 ] && ok || bad "A3 1M of each token class on $NEW priced '$P', expected 29.200000"
for m in "$NEW" anthropic/claude-opus-5.5; do
  [ "$(jq -r --arg m "$m" '.[$m] // empty' "$DIR/catalog/model-slugs.json")" = anthropic/claude-opus-5.5 ] \
    && ok || bad "A4 catalog/model-slugs.json does not map $m"
done
# A5 (BH-1510.4): the catalog A4 reads is the ONLY slug map — the bash MAP
# fallback in update-model-prices.sh is gone, so there is no second copy to
# keep in step.
[ "$(grep -c "^MAP='" "$DIR/bin/update-model-prices.sh")" = 0 ] \
  && ok || bad "A5 bin/update-model-prices.sh still carries a MAP='{…}' literal table"
[ "$(jq -r --arg m "$NEW" '.models[$m].min // empty' "$DIR/catalog/cli-min-versions.json")" = 2.1.280 ] \
  && ok || bad "A6 catalog/cli-min-versions.json has no 2.1.280 floor for $NEW"

# =============================================================================
# B. EVERY DEFAULT RESOLVES TO claude-opus-5-5
# =============================================================================
# resolve <file> <regex> <var-to-print>: run the matching line with every model
# variable unset and print the variable. The line is the shipped text.
resolve() {
  local f="$1" line; case "$f" in /*) ;; *) f="$DIR/$f" ;; esac
  line=$(grep -m1 -E "$2" "$f")
  [ -n "$line" ] || { echo "NO-LINE"; return; }
  env -i PATH="$PATH" bash -c "$line"$'\n'"printf '%s' \"\${$3}\"" 2>/dev/null
}
# inline <file> <VAR>: the first "${VAR:-default}" on a line of <file>, expanded.
inline() {
  local e; e=$(grep -oE "\\\$\\{$2:-[^}]*\\}" "$DIR/$1" | head -1)
  [ -n "$e" ] || { echo "NO-LINE"; return; }
  env -i bash -c "printf '%s' \"$e\""
}
chk() { [ "$2" = "$NEW" ] && ok || bad "B $1 resolves to '$2', not $NEW"; }
# BH-1510.2 MOVED THREE OF THESE DEFAULTS INTO THE DATABASE. The orchestrator's
# fallback, claude-auth-check's fallback and runner-bench's claude rung carry no
# default in code: they read model_routes roles `orchestrate` (rung 1),
# `auth.fallback` and `bench` (tests/model-route-other-lanes.bh-1510-2-test.sh
# drives each), whose rows carry claude-opus-5-5. Pinned here: no Opus literal
# is left in them, and each asks its role.
for f in bin/orchestrate.sh bin/claude-auth-check.sh bin/runner-bench.sh; do
  ! grep -qE 'claude-opus-5(-5)?' "$DIR/$f" && ok || bad "B $f still carries an Opus literal (the value is a model_routes row now)"
done
grep -q 'lane_model_ladder orchestrate' "$DIR/bin/orchestrate.sh" && ok || bad "B orchestrate.sh does not read role orchestrate"
grep -q 'lane_role_model auth.fallback' "$DIR/bin/claude-auth-check.sh" && ok || bad "B claude-auth-check.sh does not read role auth.fallback"
grep -q 'lane_model BENCH_CLAUDE_MODEL bench' "$DIR/bin/runner-bench.sh" && ok || bad "B runner-bench.sh does not read role bench"
for v in EXECUTE_MODEL QA_MODEL REVIEW_MODEL; do
  chk "env template $v" "$(sed -nE "s/^#$v=(.*)$/\\1/p" "$DIR/env-templates/lanes/050-model-tiering.env.example" | head -1)"
done
REG=$(rendered_registry)
kdef() { jq -r --arg i "$1" --arg e "$2" '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|.default' "$REG"; }
# BH-1510.2: these knobs default to "" — the model is the model_routes row the
# lane reads after the env var (build.execute.fallback, auth.fallback,
# postmerge.qa, build.review, rescue.review), and Opus 5.5 is that row's data.
for kv in blocked-resolver/EXECUTE_MODEL claude-auth-check/AUTH_FALLBACK_MODEL postmerge-qa/POSTMERGE_QA_MODEL \
          blocked-resolver/REVIEW_MODEL review-rescue/REVIEW_MODEL; do
  [ -z "$(kdef "${kv%/*}" "${kv#*/}")" ] && ok || bad "B knob $kv still defaults a model: $(kdef "${kv%/*}" "${kv#*/}")"
done

# =============================================================================
# C/D. FAILOVER ORDER AND THE CLI FLOOR — bin/agent-call.sh, driven
# =============================================================================
mkdir -p "$T/h/bin/lib" "$T/fakebin" "$T/h/flags" "$T/h/locks" "$T/h/logs" "$T/h/state"
# THE LADDER IS A ROW (#1510.1): a stubbed worker answers #1507's table, and the
# resolver agent-call sources is the real one.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_install "$T/fakebin"
mrs_table_1523 "$T/routes"
# The stub records every --model it is asked for. Per model it answers ok, a
# generic failure, or the 2.1.278 catalog refusal, from MODE_<model-with-_>.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --resume <sessionId>\n  --session-id <uuid>\n'; exit 0 ;;
  *" --version "*) echo "2.1.277 (Claude Code)"; exit 0 ;;
esac
m=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && m="$a"; prev="$a"; done
echo "$m" >> "$ORDER_SINK"
v="MODE_$(printf '%s' "$m" | tr -c 'A-Za-z0-9\n' '_')"
case "${!v:-ok}" in
  ok)      printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0 ;;
  stale)   printf '%s\n' "$STALE_JSON"; printf '%s\n' "$STALE_ERR" >&2; exit 1 ;;
  catalog) echo "$CATALOG_ERR" >&2; exit 1 ;;
  prose)   printf '{"result":"I changed the grep for does not support this model; version 2.1.280 or newer is required","is_error":false,"usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
  *)       printf '{"result":"I could not do it","is_error":true,"usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/h/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/h/bin/sync-agent-rules.sh"
cp "$DIR/bin/account-pick.sh" "$T/h/bin/account-pick.sh"
chmod +x "$T/fakebin/"* "$T/h/bin/"*.sh

# call <model> [ENV=VAL...] — one real agent-call run; prints its rc.
# STAGE=review in front of it drives the review lane instead of eval.
call() {
  local model="$1" stage="${STAGE:-eval}"; shift
  : > "$T/order"; : > "$T/h/logs/ALERTS.log"; : > "$T/h/logs/failovers.log"
  [ "${KEEP_FLAGS:-0}" = 1 ] || rm -f "$T/h/flags/alerted-cli-floor-"*
  ( export ORDER_SINK="$T/order" CATALOG_ERR STALE_JSON STALE_ERR PATH="$T/fakebin:$PATH" HARNESS="$T/h" HOME="$T" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid MRS_ROUTES="$T/routes" \
           LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 LADDER_TIER2_GROK=0 RUNNER_EVAL=claude \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
      "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj "$model" 600 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
order() { paste -sd, "$T/order"; }
floor_alerts() { grep -c 'CLI FLOOR' "$T/h/logs/ALERTS.log" 2>/dev/null; }

# C1. fable fails on something ordinary -> the Opus failover is 5.5, and a
# generic 5.5 failure does NOT buy a third run on Opus 5.
RC=$(call claude-fable-5-1 MODE_claude_fable_5_1=fail MODE_claude_opus_5_5=fail)
[ "$(order)" = "claude-fable-5-1,$NEW" ] \
  && ok || bad "C1 fable's failover must be $NEW and stop there on an ordinary failure, ran: $(order)"
grep -q "retrying as $NEW" "$T/h/logs/failovers.log" \
  && ok || bad "C1 failovers.log does not name $NEW as the retry: $(cat "$T/h/logs/failovers.log")"
# C2. fable in its credits cooldown goes straight to 5.5.
date +%s > "$T/h/state/model-cooldown-claude-fable-5-1"  # determinism: ok the cooldown is 6h wide; a stamp of now is inside it on any day
RC=$(call claude-fable-5-1)
[ "$(order)" = "$NEW" ] && [ "$RC" = 0 ] \
  && ok || bad "C2 a fable cooldown must serve $NEW directly, ran: $(order) rc=$RC"
rm -f "$T/h/state/model-cooldown-claude-fable-5-1"

# D1. THE 2.1.278 CLI, its REAL json envelope: fable fails, 5.5 is refused,
# Opus 5 serves. The call SUCCEEDS and says so once.
RC=$(call claude-fable-5-1 MODE_claude_fable_5_1=fail MODE_claude_opus_5_5=stale)
[ "$(order)" = "claude-fable-5-1,$NEW,claude-opus-5" ] && [ "$RC" = 0 ] \
  && ok || bad "D1 order must be fable,$NEW,claude-opus-5 with rc 0, ran: $(order) rc=$RC"
[ "$(floor_alerts)" = 1 ] && ok || bad "D1 expected exactly one CLI FLOOR line in ALERTS, got $(floor_alerts): $(cat "$T/h/logs/ALERTS.log")"
AL=$(grep 'CLI FLOOR' "$T/h/logs/ALERTS.log" | head -1)
# The version is the one the CLI named in its refusal (the stub's --version
# says 2.1.277 on purpose: the envelope is the better witness).
case "$AL" in *"claude 2.1.278 on "*) ok ;; *) bad "D1 the alert does not name the refusing CLI's version: $AL" ;; esac
case "$AL" in *"does not support $NEW — failing over to claude-opus-5. Run bin/cli-update.sh"*) ok ;;
  *) bad "D1 the alert must read exactly '… does not support $NEW — failing over to claude-opus-5. Run bin/cli-update.sh …': $AL" ;; esac
grep -q "$NEW unsupported by claude 2.1.278 — retrying as claude-opus-5\$" "$T/h/logs/failovers.log" \
  && ok || bad "D1 failovers.log must say exactly 'retrying as claude-opus-5': $(grep unsupported "$T/h/logs/failovers.log")"
# D1b. The same stale box again, same day: served again, NO second alert.
RC=$(KEEP_FLAGS=1 call "$NEW" MODE_claude_opus_5_5=stale)
[ "$(order)" = "$NEW,claude-opus-5" ] && [ "$RC" = 0 ] && [ "$(floor_alerts)" = 0 ] \
  && ok || bad "D1b a repeat refusal must still fail over but not page again, ran: $(order) rc=$RC alerts=$(floor_alerts)"
# D1c. The TEXT-mode warning is a floor too.
RC=$(call "$NEW" MODE_claude_opus_5_5=catalog)
[ "$(order)" = "$NEW,claude-opus-5" ] && [ "$RC" = 0 ] && [ "$(floor_alerts)" = 1 ] \
  && ok || bad "D1c the text-mode catalog warning must fail over with one alert, ran: $(order) rc=$RC alerts=$(floor_alerts)"
# D1d. Model PROSE quoting the phrase on an ordinary failure is not a floor.
RC=$(call "$NEW" MODE_claude_opus_5_5=prose)
[ "$(order)" = "$NEW" ] && [ "$(floor_alerts)" = 0 ] \
  && ok || bad "D1d a session's own text quoting the refusal must not read as a CLI floor, ran: $(order) alerts=$(floor_alerts)"
# D2. An execute lane pinned to 5.5 directly: refused -> Opus 5 serves.
RC=$(call "$NEW" MODE_claude_opus_5_5=stale)
[ "$(order)" = "$NEW,claude-opus-5" ] && [ "$RC" = 0 ] \
  && ok || bad "D2 a $NEW lane on a stale CLI must be served by claude-opus-5, ran: $(order) rc=$RC"
[ "$(floor_alerts)" = 1 ] && ok || bad "D2 expected one CLI FLOOR line, got $(floor_alerts)"
# D3. The same lane on a CLI that knows 5.5: one call, no floor, no alert.
RC=$(call "$NEW")
[ "$(order)" = "$NEW" ] && [ "$RC" = 0 ] && [ "$(floor_alerts)" = 0 ] \
  && ok || bad "D3 a healthy $NEW call must be one call with no alert, ran: $(order) rc=$RC alerts=$(floor_alerts)"
# D4. An ordinary 5.5 failure is not a floor: no Opus 5 retry.
RC=$(call "$NEW" MODE_claude_opus_5_5=fail)
[ "$(order)" = "$NEW" ] && [ "$(floor_alerts)" = 0 ] \
  && ok || bad "D4 an ordinary $NEW failure must not buy an Opus 5 run, ran: $(order)"
[ "$RC" != 0 ] && ok || bad "D4 a failed call reported rc 0"

# D5. THE REVIEW LANE: 5.5 first, Fable 5.1 as its last candidate, reached on
# an ordinary failure (the reviewer it ran on before), never Opus 5.
RC=$(STAGE=review call "$NEW" MODE_claude_opus_5_5=fail)
[ "$(order)" = "$NEW,claude-fable-5-1" ] && [ "$RC" = 0 ] \
  && ok || bad "D5 a failed $NEW review must be read on claude-fable-5-1, ran: $(order) rc=$RC"
grep -q "retrying as claude-fable-5-1" "$T/h/logs/failovers.log" \
  && ok || bad "D5 failovers.log does not name the Fable retry: $(cat "$T/h/logs/failovers.log")"
# D6. A review on the 2.1.278 CLI: refused, Fable serves, one CLI FLOOR line.
RC=$(STAGE=review call "$NEW" MODE_claude_opus_5_5=stale)
[ "$(order)" = "$NEW,claude-fable-5-1" ] && [ "$RC" = 0 ] && [ "$(floor_alerts)" = 1 ] \
  && ok || bad "D6 a stale-CLI review must be served by Fable with one alert, ran: $(order) rc=$RC alerts=$(floor_alerts)"
# D7. A healthy 5.5 review is one call.
RC=$(STAGE=review call "$NEW")
[ "$(order)" = "$NEW" ] && [ "$RC" = 0 ] && ok || bad "D7 a healthy review must be one $NEW call, ran: $(order)"

echo "opus-5-5-switch.bh-1507: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
