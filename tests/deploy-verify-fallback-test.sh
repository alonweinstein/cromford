#!/bin/bash
# tests/deploy-verify-fallback-test.sh — bin/deploy-verify.sh must never page
# about a token it cannot read with.
#
# THE INCIDENT (2026-09-14). The hub's default PAT 404s on example-org/project-5
# and the admin PAT answers "Resource not accessible" for its deployments, so
# the gate polled an API that could never answer, waited its 20 minutes and
# alerted "no successful production deployment within 20 min" — on merges whose
# CI and whose "Deploy Worker to Railway" job had both gone green. Every
# project-5 merge produced that page. The verification that IS available on
# those repos is the prod smoke check, and the honest answer is to run it and
# say so, not to fail closed on an unreadable API.
#
# Driven end to end with gh/curl/beat stubbed: the claims are about which branch
# the script takes, and a grep for the fallback passes just as happily on a
# script that never reaches it.
# Run from anywhere: tests/deploy-verify-fallback-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$T/fakebin" "$T/build"
cp "$DIR/bin/deploy-verify.sh" "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj https://tproj.example - 2 box-t 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
printf 'DEPLOY_HOOK_URL=https://hooks.example/deploy\nDEPLOY_HOOK_WAIT=0\n' > "$H/env/tproj.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> '"$T"'/beat.txt\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# gh: $T/mode decides what the deployments API answers.
#   404  — the repo is invisible to this token (project-5)
#   403  — the PAT has no Deployments:read (project-3, 2026-07-28)
#   ok   — readable, and $T/dstate is the deployment's state
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
MODE=\$(cat "$T/mode" 2>/dev/null || echo ok)
case "\$*" in
  *"repos/o/tproj "*|*"repos/o/tproj"|*"repos/o/tproj -q"*) exit 0 ;;   # the visibility probe
  *deployments/*statuses*) cat "$T/dstate" 2>/dev/null || echo success ;;
  *deployments*)
    case "\$MODE" in
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      403) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
      *)   echo '[{"id":77,"environment":"production","created_at":"2026-09-14T03:00:00Z"}]' ;;
    esac ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# curl: a hook POST is recorded; a smoke check answers $T/code.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
case "\$*" in
  *"-X POST"*) printf '%s\n' "\$*" >> "$T/hook.txt"; exit 0 ;;
esac
cat "$T/code" 2>/dev/null || echo 200
exit 0
EOF
chmod +x "$T/fakebin/curl"

RUN() { # RUN -> rc, with the pipeline log and ALERTS reset
  : > "$T/build/pipeline.log"; : > "$H/logs/ALERTS.log"; : > "$T/hook.txt"; : > "$T/gh.txt"
  ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      bash "$H/bin/deploy-verify.sh" tproj o/tproj deadbeefdeadbeef "$T/build" >/dev/null 2>&1 )
}
PIPE() { cat "$T/build/pipeline.log"; }

# ============================================================================
# 1. An invisible repo (404) verifies by smoke and says so — it does NOT page.
# ============================================================================
echo 404 > "$T/mode"; echo 200 > "$T/code"
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "an unreadable deployments API must exit 0 on a healthy prod smoke (rc=$RC)"
grep -q 'deployments unreadable for o/tproj: smoke-only' <<<"$(PIPE)" && ok \
  || bad "the fallback must log 'deployments unreadable for <slug>: smoke-only' (got: $(PIPE))"
grep -q 'DEPLOY-VERIFY FAILED' "$H/logs/ALERTS.log" \
  && bad "a 404 from the deployments API must never alert as a failed deploy" || ok
grep -q 'prod answers 200' <<<"$(PIPE)" && ok || bad "the smoke result must be recorded (got: $(PIPE))"
[ -s "$T/hook.txt" ] && ok || bad "the fallback must still fire the project's deploy hook"

# ============================================================================
# 2. The project-3 branch (403 "Resource not accessible") keeps working unchanged.
# ============================================================================
echo 403 > "$T/mode"
RUN
grep -q 'smoke-only' <<<"$(PIPE)" && ok || bad "a 403 PAT must still take the smoke-only path (got: $(PIPE))"
grep -q 'DEPLOY-VERIFY FAILED' "$H/logs/ALERTS.log" && bad "the 403 branch must not alert on a healthy prod" || ok
# ...and a prod that is genuinely down is still a FAIL, smoke-only or not.
echo 503 > "$T/code"
RUN; RC=$?
[ "$RC" = 1 ] && ok || bad "smoke-only must still FAIL on a dead prod (rc=$RC)"
grep -q 'DEPLOY-VERIFY FAILED' "$H/logs/ALERTS.log" && ok || bad "a dead prod must write one ALERTS line"
echo 200 > "$T/code"

# ============================================================================
# 3. A readable API is unchanged: success verifies, failure pages.
# ============================================================================
echo ok > "$T/mode"; echo success > "$T/dstate"
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "a successful production deployment must verify (rc=$RC)"
grep -q 'deploy-verify OK' <<<"$(PIPE)" && ok || bad "the readable path must log deploy-verify OK (got: $(PIPE))"
grep -q 'smoke-only' <<<"$(PIPE)" && bad "a readable deployments API must not claim smoke-only" || ok
echo failure > "$T/dstate"
RUN; RC=$?
[ "$RC" = 1 ] && ok || bad "a failed production deployment must still FAIL (rc=$RC)"
grep -q 'deployment state=failure' "$H/logs/ALERTS.log" && ok || bad "the failed deploy must name its state in the alert"

# ============================================================================
# 4. The token is resolved through the #301 resolver, not assumed.
# ============================================================================
grep -q 'gh_repo_use_token' "$DIR/bin/deploy-verify.sh" && ok \
  || bad "bin/deploy-verify.sh must resolve its gh token through bin/lib/gh-repo-token.sh"

echo "deploy-verify-fallback-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
