#!/bin/bash
# tests/served-sha-autodeploy.bh-4938-test.sh — the auto-deploy hook
# bin/lib/served-sha-watch.d/20-autodeploy.sh (BH-4938, child 3 of #4916): when
# SERVED_SHA_AUTODEPLOY=1 and prod is stuck behind main HEAD with no deployment
# for it, ask Vercel for ONE production deploy of that sha, follow it, page if
# it never serves, and confirm (and resolve) when it does.
#
# Every case runs the REAL bin/served-sha-watch.sh through ssw_fx_run in the
# scratch harness tests/lib/served-sha-fixture.sh builds (stub curl answering
# Vercel, stub gh answering GitHub, lane-alert.sh replaced by a recorder).
#   D1     knob unset / 0 / true -> no POST, no ledger, no alert
#   D2     knob 1 -> one POST with main's full sha, ref main, the served
#          deployment's name; ledger requested + id; the token appears nowhere
#   D3     two more ticks while still behind -> still one POST
#   D4     prod serves it -> confirm line, state gone, nothing to resolve
#   D5     still behind after the lag -> one critical alert, once
#   D4b    then in sync (knob off) -> the alert is resolved
#   D6a-g  dep building/ready/failed/unread, verdict wait, unreadable, no
#          deployment name -> no POST
#   D7a-e  POST 500 / 2xx with no id / unreadable state / ledger unwritable /
#          no answer (000)
#   D8     a new HEAD gets its own (one) request
#   M3/M4  the ledger moved after the POST, the dep=none check dropped -> red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/served-sha-autodeploy.bh-4938-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/served-sha-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
HOOK="$DIR/bin/lib/served-sha-watch.d/20-autodeploy.sh"
[ -s "$HOOK" ] || bad "setup: $HOOK is missing or empty"

ssw_fx_setup || bad "setup: ssw_fx_setup failed"
H="$T/h"
HD="$H/bin/lib/served-sha-watch.d"
LOG="$H/logs/served-sha-watch.log"
SF="$H/state/served-sha-watch/demo-os.json"
H40=2b2272a4e1f0c3d5b6a7980112233445566778899
H40=${H40:0:40}
S40=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
N40=0123456789abcdef0123456789abcdef01234567
AID="served-autodeploy:demo-os:${H40:0:12}"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok formats a pinned epoch, reads no clock

install_hook() { # install_hook [src] — the hook (or a mutant) as the driver loads it
  # scratch-closure-allow: the driver loads hooks by glob, which scratch_install_closure does not follow; ssw_fx_reset empties the dir per case
  mkdir -p "$HD" && cp "${1:-$HOOK}" "$HD/20-autodeploy.sh"
}
base() { # alert, no deployment for HEAD; the served deployment is named demo-os-web, not the project
  ssw_fx_head "$H40" "$(iso $((NOW-1500)))"; ssw_fx_served "$S40"; ssw_fx_compare ahead
  ssw_fx_list '{"deployments":[]}'
  jq -c '.name = "demo-os-web"' "$T/fx/dep.json" > "$T/fx/dep.tmp" && mv "$T/fx/dep.tmp" "$T/fx/dep.json"
}
fresh() { ssw_fx_reset; base; install_hook "${1:-}"; }
posts() { grep -c '^POST ' "$T/req/argv.lines"; }
alerts() { [ -f "$T/alerts.txt" ] && grep -c -- "$1" "$T/alerts.txt" || echo 0; }
dj() { jq -r "$1" "$SF" 2>/dev/null; }
row() { jq -nc --arg s "$H40" --arg st "$1" '{deployments:[{uid:"dpl_r", state:$st, meta:{githubCommitSha:$s}}]}'; }
tick() { # tick <seconds after NOW> [VAR=value ...] — one ssw_fx_run, the knobs scoped to it
  local k="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done; SERVED_SHA_NOW=$((NOW + k)) ssw_fx_run )
}

# ── D1: knob not exactly 1 -> nothing ─────────────────────────────────────────
for k in unset 0 true; do
  fresh; printf '{"id":"dpl_x"}' > "$T/fx/post.json"
  if [ "$k" = unset ]; then tick 0; else tick 0 SERVED_SHA_AUTODEPLOY="$k"; fi
  [ "$(dj .last_verdict)" = alert ] || bad "D1[$k] precondition: verdict alert, got $(cat "$SF" 2>&1)"
  [ "$(posts)" = 0 ] && [ "$(dj '.deploy // "none"')" = none ] && [ ! -e "$T/alerts.txt" ] \
    && ok || bad "D1[$k] knob $k must not POST/ledger/alert: $(cat "$T/req/argv.lines") $(cat "$SF" 2>&1)"
done

# ── D2-D4: the observable outcome ─────────────────────────────────────────────
fresh; printf '{"id":"dpl_x"}' > "$T/fx/post.json"
tick 0 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 1 ] && ok || bad "D2 exactly one POST: $(cat "$T/req/argv.lines")"
pl=$(grep '^POST ' "$T/req/argv.lines" | head -1)
[ "$(awk '{print $2}' <<< "$pl")" = "https://vercel.stub/v13/deployments?teamId=team_x" ] \
  && ok || bad "D2 POST url: $pl"
pb=$(awk '{print $3}' <<< "$pl")
jq -e --arg h "$H40" '.target == "production" and .gitSource.type == "github" and .gitSource.sha == $h
    and .gitSource.ref == "main" and .gitSource.org == "example-org" and .gitSource.repo == "demo-os"
    and .project == "prj_x" and .name == "demo-os-web"' <<< "$pb" >/dev/null 2>&1 \
  && ok || bad "D2 POST body: $pb"
grep -q 'Content-Type: application/json' "$T/req/stdin.lines" && ok || bad "D2 POST sends Content-Type json: $(cat "$T/req/stdin.lines")"
[ "$(dj .deploy.sha)" = "$H40" ] && [ "$(dj .deploy.rc)" = requested ] && [ "$(dj .deploy.id)" = dpl_x ] \
  && [ "$(dj .deploy.at)" = "$NOW" ] && ok || bad "D2 ledger: $(cat "$SF" 2>&1)"
grep -q "demo-os: auto-deploy of ${H40:0:8} requested\$" "$LOG" && ok || bad "D2 log line: $(cat "$LOG")"
! grep -q "$SSW_FX_TOKEN" <<< "$(cat "$T/req/argv.lines" "$LOG" "$T/alerts.txt" 2>/dev/null)" \
  && ok || bad "D2 the token leaked into argv, log or alerts"
[ ! -e "$T/alerts.txt" ] && ok || bad "D2 a good request sends no alert: $(cat "$T/alerts.txt")"

tick 300 SERVED_SHA_AUTODEPLOY=1; tick 600 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 1 ] && [ "$(dj .deploy.rc)" = requested ] && ok || bad "D3 still one POST after two ticks: $(cat "$T/req/argv.lines")"
[ ! -e "$T/alerts.txt" ] && ok || bad "D3 no alert before the lag: $(cat "$T/alerts.txt")"

ssw_fx_served "$H40"; tick 900 SERVED_SHA_AUTODEPLOY=1
grep -q "demo-os: auto-deploy of ${H40:0:8} confirmed: prod serves it" "$LOG" && ok || bad "D4 confirm line: $(cat "$LOG")"
[ ! -e "$SF" ] && ok || bad "D4 state removed on in-sync"
[ "$(alerts -- --resolve)" = 0 ] && ok || bad "D4 nothing opened, nothing resolved: $(cat "$T/alerts.txt")"
[ "$(posts)" = 1 ] && ok || bad "D4 still one POST"

# ── D5 + D4b: follow-up after the lag, then resolve (knob off) ────────────────
fresh; printf '{"id":"dpl_x"}' > "$T/fx/post.json"
tick 0 SERVED_SHA_AUTODEPLOY=1; tick 1200 SERVED_SHA_AUTODEPLOY=1
[ "$(alerts "--severity critical --id $AID served-sha-watch")" = 1 ] \
  && grep -q "requested 20m ago, prod still serves ${S40:0:8}" "$T/alerts.txt" \
  && ok || bad "D5 one follow-up alert: $(cat "$T/alerts.txt" 2>&1)"
[ "$(dj .deploy.alerted)" = true ] && ok || bad "D5 alerted recorded: $(cat "$SF" 2>&1)"
tick 1500 SERVED_SHA_AUTODEPLOY=1
[ "$(alerts "$AID")" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "D5 still one alert, one POST: $(cat "$T/alerts.txt") / $(posts)"
ssw_fx_served "$H40"; tick 1800
[ "$(alerts "^--resolve --id $AID served-sha-watch .*confirmed")" = 1 ] \
  && ok || bad "D4b resolve on confirm, knob off: $(cat "$T/alerts.txt")"

# ── D6: negatives that must not POST ─────────────────────────────────────────
neg() { # neg <name> <want-verdict>
  [ "$(posts)" = 0 ] && ok || bad "$1 must not POST: $(cat "$T/req/argv.lines")"
  [ -z "$2" ] || [ "$(dj .last_verdict)" = "$2" ] || bad "$1 precondition: verdict $2, state $(cat "$SF" 2>&1)"
}
for s in BUILDING:D6a READY:D6b ERROR:D6c; do
  fresh; ssw_fx_list "$(row "${s%%:*}")"; tick 0 SERVED_SHA_AUTODEPLOY=1; neg "${s#*:} dep ${s%%:*}" alert
done
fresh; echo 500 > "$T/fx/list.code"; tick 0 SERVED_SHA_AUTODEPLOY=1; neg "D6d dep unread" alert
fresh; ssw_fx_head "$H40" "$(iso $((NOW-600)))"; tick 0 SERVED_SHA_AUTODEPLOY=1; neg "D6e verdict wait" wait
fresh; echo 500 > "$T/fx/alias.code"; tick 0 SERVED_SHA_AUTODEPLOY=1; neg "D6f verdict unreadable" ""
fresh; jq -c 'del(.name)' "$T/fx/dep.json" > "$T/fx/d" && mv "$T/fx/d" "$T/fx/dep.json"
tick 0 SERVED_SHA_AUTODEPLOY=1; neg "D6g no deployment name" alert
grep -q 'demo-os: auto-deploy skipped (name unknown)' "$LOG" && [ "$(dj '.deploy // "none"')" = none ] \
  && ok || bad "D6g logs name unknown, no ledger: $(cat "$LOG")"

# ── D7: failures ─────────────────────────────────────────────────────────────
fresh; printf '{"error":{"code":"x"}}' > "$T/fx/post.json"; echo 500 > "$T/fx/post.code"
tick 0 SERVED_SHA_AUTODEPLOY=1; tick 300 SERVED_SHA_AUTODEPLOY=1; tick 1500 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 1 ] && [ "$(dj .deploy.rc)" = failed:500 ] && ok || bad "D7a one POST, rc failed:500: $(cat "$SF" 2>&1)"
[ "$(alerts "--severity critical --id $AID served-sha-watch")" = 1 ] \
  && grep -q "demo-os: auto-deploy request failed (HTTP 500) for ${H40:0:8}" "$T/alerts.txt" \
  && ok || bad "D7a one failed-request alert, no follow-up on top: $(cat "$T/alerts.txt" 2>&1)"

fresh; printf '{}' > "$T/fx/post.json"
tick 0 SERVED_SHA_AUTODEPLOY=1; tick 300 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 1 ] && [ "$(dj .deploy.rc)" = requested-empty ] && [ "$(dj '.deploy.id // "none"')" = none ] \
  && ok || bad "D7b 2xx without id is requested-empty, never retried: $(cat "$SF" 2>&1)"

fresh; mkdir -p "$SF"; tick 0 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 0 ] && grep -q 'demo-os: state file unreadable, auto-deploy skipped (fail closed)' "$LOG" \
  && ok || bad "D7c unreadable state fails closed: $(cat "$LOG") / $(posts)"

d7d() { scratch_rm "$H/state/served-sha-watch" 2>/dev/null; : > "$H/state/served-sha-watch"; tick 0 SERVED_SHA_AUTODEPLOY=1; }
fresh; d7d
[ "$(posts)" = 0 ] && grep -q 'demo-os: auto-deploy ledger write failed, no request sent' "$LOG" \
  && ok || bad "D7d no ledger, no POST: $(cat "$LOG") / $(posts)"

fresh; echo 000 > "$T/fx/post.code"; tick 0 SERVED_SHA_AUTODEPLOY=1; tick 300 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 1 ] && [ "$(dj .deploy.rc)" = failed:000 ] && grep -q '(HTTP 000)' "$T/alerts.txt" 2>/dev/null \
  && ok || bad "D7e no answer is failed:000, never retried: $(cat "$SF" 2>&1)"

# ── D8: a new HEAD gets its own request ──────────────────────────────────────
fresh; printf '{"id":"dpl_x"}' > "$T/fx/post.json"; tick 0 SERVED_SHA_AUTODEPLOY=1
ssw_fx_head "$N40" "$(iso $((NOW-1500)))"; tick 300 SERVED_SHA_AUTODEPLOY=1; tick 600 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" = 2 ] && [ "$(dj .deploy.sha)" = "$N40" ] && grep '^POST ' "$T/req/argv.lines" | tail -1 | grep -q "\"sha\":\"$N40\"" \
  && ok || bad "D8 one POST per sha: $(cat "$T/req/argv.lines")"

# ── M: break the hook, confirm the cases go red ──────────────────────────────
mutate() { # mutate <name> <sed-expr> -> $T/mut.sh differs from the hook
  sed "$2" "$HOOK" > "$T/mut.sh"
  ! cmp -s "$HOOK" "$T/mut.sh" && ok || bad "$1 mutation changed nothing"
}
mutate M3 '/# ssw-ad: ledger/{h;d}; /# ssw-ad: post/G'
fresh "$T/mut.sh"; d7d
[ "$(posts)" -ge 1 ] && ok || bad "M3 ledger after the POST must make D7d POST"
mutate M4 '/# ssw-ad: dep-none/d'
fresh "$T/mut.sh"; ssw_fx_list "$(row READY)"; tick 0 SERVED_SHA_AUTODEPLOY=1
[ "$(posts)" -ge 1 ] && ok || bad "M4 dropping dep=none must make D6b POST"

echo "served-sha-autodeploy.bh-4938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
