#!/bin/bash
# tests/webhook-rearm.bh-4058-test.sh — bin/webhook-rearm.sh adds the canonical
# events to every fleet repo's EXISTING doorbell hook, and nothing else.
#
# A scratch $HARNESS holds a copy of the real script, a stub fleet-conf.sh
# naming three repos, and (per case) stub token/budget libs. GitHub is
# $WEBHOOK_REARM_GH: a stub serving GET /repos/<r>/hooks from fixture files,
# recording every argv and stdin to $CALLS, and answering a PATCH by writing
# the new events into the fixture and echoing the hook. The App webhook is the
# $WEBHOOK_REARM_APP_HOOK stub.
#   R1  dry-run is the default: WOULD PATCH / OK / NO_REPO_HOOK, GETs only
#   R2  --apply: one PATCH to A's hook, events = old ∪ canonical, no config key
#   R3  --apply again: zero PATCH calls (idempotent)
#   R4  union never removes (release kept); ["*"] is OK; inactive is not patched;
#       two receiver hooks on one repo are each evaluated
#   R5  unreadable on every rung -> UNREADABLE; the PAT ladder's admin rung is
#       tried; a failed PATCH -> PATCH_FAILED, exit 1
#   R6  budget low -> exit 3, zero calls; unknown proceeds; low between repos
#       on --apply stops and names the repos not reached
#   R7  --print-events is the 11 events; a bad --repo exits 2 with no calls
#   R8  the App hook lacking events is reported, never written
#   R9  the hook secret never appears anywhere
#   R10 only --apply appends a summary line to logs/webhook-rearm.log
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/webhook-rearm.bh-4058-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; FIX="$T/fix"; CALLS="$T/gh-calls.txt"; APPCALLS="$T/app-calls.txt"
REC="https://jobs.test/webhooks/github"
OLD8='["pull_request","pull_request_review","check_suite","check_run","push","deployment_status","issues","issue_comment"]'
ALL11='["pull_request","pull_request_review","check_suite","check_run","push","deployment_status","issues","issue_comment","status","workflow_run","merge_group"]'
CANON=$(jq -r '.[]' <<<"$ALL11" | sort)
export HARNESS="$H" JOBS_URL="https://jobs.test" CALLS FIX APPCALLS
export WEBHOOK_REARM_GH="$T/gh" WEBHOOK_REARM_APP_HOOK="$T/app-hook"
unset GH_TOKEN

# hook <id> <url> <events-json> [active]
hook() { jq -nc --argjson id "$1" --arg u "$2" --argjson e "$3" --argjson a "${4:-true}" \
  '{id:$id, active:$a, events:$e, config:{url:$u, content_type:"json", secret:"SENTINEL"}}'; }

fresh() {
  scratch_rm "$H"; scratch_rm "$FIX"
  mkdir -p "$H/bin/lib" "$H/logs" "$FIX"
  : > "$CALLS"; : > "$APPCALLS"
  cp "$DIR/bin/webhook-rearm.sh" "$H/bin/webhook-rearm.sh"
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'pa\npb\npc\npdash\npdup\n'; exit 0; }
case "$1/$2" in
  pa/repo) echo example-org/a ;;
  pb/repo) echo example-org/b ;;
  pc/repo) echo example-org/c ;;
  pdash/repo) echo - ;;
  pdup/repo) echo example-org/a ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$H/bin/"*.sh
  printf '[%s,%s]' "$(hook 101 "$REC" "$OLD8")" "$(hook 909 https://other.example/hook '["push"]')" > "$FIX/example-org_a.json"
  printf '[%s]' "$(hook 201 "$REC" "$ALL11")" > "$FIX/example-org_b.json"
  printf '[%s]' "$(hook 303 https://other.example/x '["push"]')" > "$FIX/example-org_c.json"
  printf '%s\t%s\n' "$REC" "$(jq -r 'join(",")' <<<"$ALL11")" > "$T/app-hook.out"
}

cat > "$T/gh" <<'SH'
#!/bin/bash
{ printf 'ARGV:'; printf ' %s' "$@"; printf ' TOKEN=%s\n' "${GH_TOKEN:-}"; } >> "$CALLS"
method=GET path="" input=0
while [ $# -gt 0 ]; do
  case "$1" in -X) method=$2; shift ;; --input) input=1; shift ;; /*) path=$1 ;; esac
  shift
done
body=""
if [ "$input" = 1 ]; then body=$(cat); printf 'STDIN: %s\n' "$body" >> "$CALLS"; fi
p=${path%%\?*}
slug=$(sed -E 's#^/repos/([^/]+)/([^/]+)/hooks.*#\1_\2#' <<<"$p")
f="$FIX/$slug.json"
[ -f "$FIX/$slug.deny" ] && { echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
if [ -f "$FIX/$slug.adminonly" ] && [ "${GH_TOKEN:-}" != admin-tok ]; then
  echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1
fi
case "$method" in
  GET) cat "$f" ;;
  PATCH)
    [ -f "$FIX/patchfail" ] && { echo '{"message":"Validation Failed"}'; echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1; }
    id=${p##*/}
    jq --argjson id "$id" --argjson e "$(jq -c .events <<<"$body")" \
      'map(if .id == $id then .events = $e else . end)' "$f" > "$f.new" && mv "$f.new" "$f"
    jq -c --argjson id "$id" '.[] | select(.id == $id)' "$f" ;;
esac
SH
cat > "$T/app-hook" <<'SH'
#!/bin/bash
echo "ARGV: $*" >> "$APPCALLS"
cat "$(dirname "$0")/app-hook.out"
SH
chmod +x "$T/gh" "$T/app-hook"

RUN() { OUT=$("$H/bin/webhook-rearm.sh" "$@" 2>&1); RC=$?; }
npatch() { grep -c -- '-X PATCH' "$CALLS"; }
summary() { grep '^webhook-rearm mode=' <<<"$OUT"; }

# ── R1 dry-run default ───────────────────────────────────────────────────────
fresh; RUN
chk "R1 rc=$RC: $OUT" '[ "$RC" = 0 ]'
chk "R1 WOULD PATCH line: $OUT" 'grep -qx "WOULD PATCH example-org/a hook 101 add: merge_group status workflow_run" <<<"$OUT"'
chk "R1 OK b: $OUT" 'grep -q "^OK example-org/b hook 201" <<<"$OUT"'
chk "R1 NO_REPO_HOOK c: $OUT" 'grep -q "^NO_REPO_HOOK example-org/c" <<<"$OUT"'
chk "R1 dry-run made a PATCH: $(cat "$CALLS")" '[ "$(npatch)" = 0 ]'
chk "R1 GETs only, one per repo (dup + dash skipped): $(cat "$CALLS")" '[ "$(grep -c "^ARGV:" "$CALLS")" = 3 ]'
chk "R1 summary: $(summary)" 'summary | grep -q "repos=3 ok=1 would_patch=1 failed=0 unarmed=1 unreadable=0"'
chk "R1 dry-run body printed" 'grep -q "\"events\":\[" <<<"$OUT"'

# ── R2 --apply ──────────────────────────────────────────────────────────────
RUN --apply
chk "R2 rc=$RC: $OUT" '[ "$RC" = 0 ]'
chk "R2 one PATCH: $(cat "$CALLS")" '[ "$(npatch)" = 1 ]'
chk "R2 PATCH target" 'grep -q -- "-X PATCH /repos/example-org/a/hooks/101 " "$CALLS"'
PBODY=$(grep '^STDIN: ' "$CALLS" | head -n1 | sed 's/^STDIN: //')
chk "R2 PATCH events = old ∪ canonical: $PBODY" '[ "$(jq -r ".events[]" <<<"$PBODY")" = "$CANON" ]'
chk "R2 PATCH carries no config: $PBODY" '[ "$(jq -c "keys" <<<"$PBODY")" = "[\"events\"]" ]'
chk "R2 foreign hook ids untouched" '! grep -qE "/hooks/(909|303)" "$CALLS"'
chk "R2 PATCHED line" 'grep -q "^PATCHED example-org/a hook 101" <<<"$OUT"'
chk "R2 summary: $(summary)" 'summary | grep -q "mode=apply repos=3 ok=1 patched=1 failed=0 unarmed=1"'

# ── R3 re-run --apply against the patched stub: a no-op ─────────────────────
: > "$CALLS"; RUN --apply
chk "R3 rc=$RC" '[ "$RC" = 0 ]'
chk "R3 PATCH calls on a complete hook: $(cat "$CALLS")" '[ "$(npatch)" = 0 ]'
chk "R3 every repo OK/NO_REPO_HOOK: $OUT" 'grep -q "^OK example-org/a hook 101" <<<"$OUT" && grep -q "^OK example-org/b" <<<"$OUT"'

# ── R4 union, wildcard, inactive, two hooks ─────────────────────────────────
fresh
printf '[%s,%s,%s]' "$(hook 401 "$REC" '["push","release"]')" "$(hook 402 "$REC" '["*"]')" \
  "$(hook 403 "$REC" '["push"]' false)" > "$FIX/example-org_a.json"
RUN --apply --repo example-org/a
PBODY=$(grep '^STDIN: ' "$CALLS" | head -n1 | sed 's/^STDIN: //')
chk "R4 one PATCH only (401): $(cat "$CALLS")" '[ "$(npatch)" = 1 ] && grep -q -- "-X PATCH /repos/example-org/a/hooks/401 " "$CALLS"'
chk "R4 release kept: $PBODY" 'jq -e "index(\"release\")" <<<"$(jq -c .events <<<"$PBODY")" >/dev/null'
chk "R4 wildcard OK: $OUT" 'grep -q "^OK example-org/a hook 402" <<<"$OUT"'
chk "R4 inactive reported: $OUT" 'grep -q "^INACTIVE example-org/a hook 403" <<<"$OUT"'
chk "R4 --repo checked one repo" '! grep -q "example-org/b" "$CALLS"'

# ── R5 unreadable, the ladder, PATCH failure ────────────────────────────────
fresh; touch "$FIX/example-org_b.deny"
RUN --apply
chk "R5 unreadable rc=$RC" '[ "$RC" = 0 ]'
chk "R5 UNREADABLE b: $OUT" 'grep -q "^UNREADABLE example-org/b" <<<"$OUT"'
chk "R5 unreadable count" 'summary | grep -q "unreadable=1"'
fresh; touch "$FIX/example-org_b.adminonly"
cat > "$H/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_pat() { GH_REPO_PAT_RUNG=default; export GH_TOKEN=default-tok; }
gh_repo_next_rung() { [ "${GH_TOKEN:-}" = default-tok ] || return 1; export GH_TOKEN=admin-tok; }
gh_repo_token_reset() { unset GH_TOKEN; }
SH
RUN
chk "R5 ladder: admin rung read b: $OUT / $(cat "$CALLS")" 'grep -q "^OK example-org/b" <<<"$OUT" && grep -q "/repos/example-org/b/.*TOKEN=admin-tok" "$CALLS"'
chk "R5 ladder reset between repos" 'grep -q "/repos/example-org/c/.*TOKEN=default-tok" "$CALLS"'
fresh; touch "$FIX/patchfail"
RUN --apply
chk "R5 PATCH_FAILED rc=$RC: $OUT" '[ "$RC" = 1 ] && grep -q "^PATCH_FAILED example-org/a" <<<"$OUT"'
chk "R5 failed count" 'summary | grep -q "failed=1"'

# ── R6 budget ───────────────────────────────────────────────────────────────
fresh; printf 'gh_budget_low() { return 0; }\n' > "$H/bin/lib/gh-budget.sh"
RUN --apply
chk "R6 low rc=$RC: $OUT" '[ "$RC" = 3 ] && grep -q "budget low — no calls made, re-run later" <<<"$OUT"'
chk "R6 low made calls: $(cat "$CALLS" "$APPCALLS")" '[ ! -s "$CALLS" ] && [ ! -s "$APPCALLS" ]'
fresh; printf 'gh_budget_low() { return 2; }\n' > "$H/bin/lib/gh-budget.sh"
RUN
chk "R6 unknown proceeds rc=$RC" '[ "$RC" = 0 ] && summary | grep -q "repos=3"'
fresh
# healthy for the start check and repo 1, low before repo 2
printf 'gh_budget_low() { local n; n=$(cat "$HARNESS/bn" 2>/dev/null || echo 0); echo $((n+1)) > "$HARNESS/bn"; [ "$n" -ge 2 ] && return 0; return 1; }\n' > "$H/bin/lib/gh-budget.sh"
RUN --apply
chk "R6 mid-apply stop rc=$RC: $OUT" '[ "$RC" = 3 ] && summary | grep -q "not_reached=example-org/c"'
chk "R6 mid-apply stop: c never read" '! grep -q "/repos/example-org/c/" "$CALLS"'

# ── R7 --print-events, bad --repo ───────────────────────────────────────────
fresh; RUN --print-events
chk "R7 print-events rc=$RC" '[ "$RC" = 0 ]'
chk "R7 the 11 events: $OUT" '[ "$(sort <<<"$OUT")" = "$CANON" ] && [ "$(wc -l <<<"$OUT")" = 11 ]'
RUN --repo 'x;rm'
chk "R7 bad slug rc=$RC" '[ "$RC" = 2 ] && [ ! -s "$CALLS" ]'
RUN --bogus
chk "R7 unknown flag rc=$RC" '[ "$RC" = 2 ]'

# ── R8 the App hook ─────────────────────────────────────────────────────────
fresh; printf '%s\tpull_request,push,issues\n' "$REC" > "$T/app-hook.out"
RUN --apply
chk "R8 APP_HOOK missing line: $OUT" 'grep -q "^APP_HOOK missing:.* status" <<<"$OUT"'
chk "R8 App hook read once, no args: $(cat "$APPCALLS")" '[ "$(cat "$APPCALLS")" = "ARGV: " ]'
fresh; RUN
chk "R8 complete App hook: no line" '! grep -q "^APP_HOOK" <<<"$OUT"'

# ── R9 the secret ───────────────────────────────────────────────────────────
fresh; RUN; ALL="$OUT"; RUN --apply; ALL="$ALL$OUT"
chk "R9 secret leaked" '! grep -q SENTINEL <<<"$ALL" && ! grep -q SENTINEL "$CALLS" && ! grep -qs SENTINEL "$H/logs/webhook-rearm.log"'

# ── R10 the log ─────────────────────────────────────────────────────────────
fresh; RUN
chk "R10 dry-run logged a summary" '! grep -qs "webhook-rearm mode=" "$H/logs/webhook-rearm.log"'
RUN --apply
chk "R10 apply logged exactly one" '[ "$(grep -c "webhook-rearm mode=apply" "$H/logs/webhook-rearm.log")" = 1 ]'

echo "webhook-rearm (BH-4058): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
