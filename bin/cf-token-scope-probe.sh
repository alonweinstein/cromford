#!/bin/bash
# bin/cf-token-scope-probe.sh — prove the hub's Cloudflare token cannot write
# Workers secrets or D1, while it can still read the Pages project (BH-3905).
#
# WHY: #3905 moves worker deploys off the hub into CI, and its acceptance 1 is
# "from the hub, `wrangler secret put` and `wrangler d1 execute ... INSERT INTO
# verdicts` both fail with an auth error. Record the run output." This script
# makes that record. Run it BY HAND on the hub after runbook step R3 (the hub's
# token narrowed to Cloudflare Pages: Read); see
# docs/notes/2026-10-03-BH-3905-deploy-off-hub.md, step R4.
#
#   bin/cf-token-scope-probe.sh
#
# PROBES (each wrangler call under `timeout 120`, run from <checkout>/worker/jobs
# with env/cloudflare.env sourced in a subshell):
#   P1 `wrangler secret put BH3905_SCOPE_PROBE --name harness-jobs` fails with an
#      auth error. If it SUCCEEDS the probe secret is deleted at once, P1 FAILs and
#      one ALERTS line is written through bin/alert-line.sh.
#   P2 `wrangler d1 execute harness-jobs --remote` of an INSERT INTO verdicts ...
#      WHERE 0 (inserts nothing even when allowed) fails with an auth error.
#   P3 the same with `SELECT 1`: the hub keeps no D1 access at all.
#   P4 positive control: the Pages project GET pipeline-health's drift check makes
#      answers HTTP 200 with success:true. Without it a dead token would pass P1-P3.
#   P5 `wrangler whoami` with every Cloudflare credential unset says "not
#      authenticated": no cached `wrangler login` session on the box.
# Only an auth error is a PASS for P1-P3. A timeout, a network error, or a
# "database not found" proves nothing about the token and is a FAIL.
#
# OUTPUT: one `P<n> PASS|FAIL <reason>` line per probe, then a summary line; the
# raw output of every call goes to state/cf-scope-probe/<UTC>.txt. The token is
# never printed: it lives only in the subshell env, reaches curl on stdin, and
# every byte printed or written passes through the scrub (the one
# bin/console-pages-deploy.sh uses).
#
# EXIT: 0 all five PASS; 1 any FAIL; 2 a precondition is missing
# (env/cloudflare.env unreadable, <checkout>/worker/jobs/wrangler.jsonc absent).
#
# ENV: HARNESS (default /root/harness), HARNESS_CHECKOUT (default
# /root/harness-checkout), HARNESS_ENV_DIR (bin/lib/env-path.sh's resolver).
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/console-pages.sh
. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/console-pages.sh" 2>/dev/null \
  || { echo "cf-scope-probe: bin/lib/console-pages.sh missing" >&2; exit 2; }
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
CFENV="$HENV/cloudflare.env"
WJ="$CHECKOUT/worker/jobs"

[ -r "$CFENV" ] || { echo "cf-scope-probe: $CFENV is not readable — nothing to probe"; exit 2; }
[ -f "$WJ/wrangler.jsonc" ] || { echo "cf-scope-probe: $WJ/wrangler.jsonc missing — set HARNESS_CHECKOUT"; exit 2; }

OUT="$H/state/cf-scope-probe/$(date -u +%Y%m%dT%H%M%SZ).txt"
mkdir -p "$(dirname "$OUT")" || { echo "cf-scope-probe: cannot create $(dirname "$OUT")"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-scope-probe.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

CP_TOK=$( set -a; . "$CFENV" >/dev/null 2>&1; printf '%s' "${CLOUDFLARE_API_TOKEN:-}" )
scrub() { # scrub [file] — the literal token and any Bearer value out of every line
  CP_TOK="$CP_TOK" awk '{t=ENVIRON["CP_TOK"]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)); gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print}' "$@"
}
cf() { # cf <cmd...> — in worker/jobs with cloudflare.env in THIS subshell only; output to $TMP/o, rc returned
  ( cd "$WJ" && set -a && . "$CFENV" && set +a && "$@" ) > "$TMP/o" 2>&1
}
is_auth_err() { # is_auth_err <file> — narrow on purpose: only words Cloudflare uses for a refused credential
  grep -Eqi 'Authentication error|code: 10000|\[code: 7403\]|not authorized|Unauthorized|(^|[^0-9])403([^0-9]|$)' "$1"
}
NPASS=0
record() { # record <n> <label> <rc> <PASS|FAIL> <reason> — raw output to the file first, then the verdict line
  { echo "== P$1 $2 (rc $3)"; scrub "$TMP/o"; } >> "$OUT"
  [ "$4" = PASS ] && NPASS=$((NPASS + 1))
  echo "P$1 $4 $5" | scrub | tee -a "$OUT"
}
auth_probe() { # auth_probe <n> <label> <rc> — PASS only on a non-zero rc AND an auth error
  if [ "$3" = 0 ]; then record "$1" "$2" "$3" FAIL "$2 SUCCEEDED — the hub token can do this"
  elif [ "$3" = 124 ]; then record "$1" "$2" "$3" FAIL "$2 timed out — inconclusive"
  elif is_auth_err "$TMP/o"; then record "$1" "$2" "$3" PASS "$2 refused with an auth error"
  else record "$1" "$2" "$3" FAIL "$2 failed without an auth error (rc $3) — inconclusive, see the output file"
  fi
}

# P1 — Workers secret write
printf 'bh3905-scope-probe' | cf timeout 120 npx --yes wrangler@4 secret put BH3905_SCOPE_PROBE --name harness-jobs; RC=$?
if [ "$RC" = 0 ]; then
  { echo "== P1 secret put (rc 0)"; scrub "$TMP/o"; } >> "$OUT"
  printf 'y\n' | cf timeout 120 npx --yes wrangler@4 secret delete BH3905_SCOPE_PROBE --name harness-jobs; DRC=$?
  { echo "== P1 secret delete (rc $DRC)"; scrub "$TMP/o"; } >> "$OUT"
  if [ "$DRC" = 0 ]; then
    echo "P1 FAIL: secret put SUCCEEDED — the hub token can edit Workers secrets; probe secret deleted (rc 0)" | scrub | tee -a "$OUT"
    WHAT="probe secret deleted"
  else
    echo "P1 FAIL: secret put SUCCEEDED — the hub token can edit Workers secrets; probe secret NOT deleted (rc $DRC), remove BH3905_SCOPE_PROBE from harness-jobs by hand" | scrub | tee -a "$OUT"
    WHAT="probe secret NOT deleted, remove BH3905_SCOPE_PROBE by hand"
  fi
  HARNESS="$H" "$H/bin/alert-line.sh" "[cf-scope-probe] hub CLOUDFLARE_API_TOKEN can still write Workers secrets (BH-3905 R3 not done; $WHAT); see state/cf-scope-probe/$(basename "$OUT")"
else
  auth_probe 1 "secret put" "$RC"
fi

# P2 — D1 write (WHERE 0: zero rows even if allowed, so no trigger fires)
cf timeout 120 npx --yes wrangler@4 d1 execute harness-jobs --remote --yes \
  --command "INSERT INTO verdicts (repo,pr,head_sha,verdict,source) SELECT 'probe/probe',0,'0000000000000000000000000000000000000000','BLOCK','box' WHERE 0"
auth_probe 2 "d1 INSERT" $?

# P3 — D1 read
cf timeout 120 npx --yes wrangler@4 d1 execute harness-jobs --remote --yes --command "SELECT 1"
auth_probe 3 "d1 SELECT" $?

# P4 — positive control: the token still reads the Pages project
: > "$TMP/o"; : > "$TMP/e"
P4=$( set -a; . "$CFENV" 2>/dev/null; set +a
  acct=$(console_pages_account_id "$CHECKOUT") || { echo "noacct"; exit 0; }
  printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN:-}" \
    | curl -sS --max-time 20 -H @- -o "$TMP/o" -w '%{http_code}' \
      "https://api.cloudflare.com/client/v4/accounts/$acct/pages/projects/$(console_pages_project)" 2>"$TMP/e"
  echo " rc $?" )
P4_CODE=${P4%% *}
touch "$TMP/o"; cat "$TMP/e" >> "$TMP/o" 2>/dev/null
if [ "$P4" = noacct ]; then record 4 "Pages GET" - FAIL "no Cloudflare account id (CLOUDFLARE_ACCOUNT_ID unset, none in worker/jobs/wrangler.jsonc)"
elif [ "$P4_CODE" != 200 ]; then record 4 "Pages GET" "${P4##* }" FAIL "Pages project GET answered HTTP ${P4_CODE:-none} — the token cannot read Pages, so P1-P3 prove nothing"
elif [ "$(jq -r '.success == true' "$TMP/o" 2>/dev/null)" != true ]; then record 4 "Pages GET" 0 FAIL "Pages project GET answered 200 without success:true"
else record 4 "Pages GET" 0 PASS "Pages project $(console_pages_project) readable (HTTP 200)"
fi

# P5 — no cached wrangler login: whoami with every credential unset
( cd "$WJ" && env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_API_KEY -u CLOUDFLARE_EMAIL timeout 120 npx --yes wrangler@4 whoami ) > "$TMP/o" 2>&1; RC=$?
if grep -qi 'not authenticated' "$TMP/o"; then record 5 "whoami (no env)" "$RC" PASS "wrangler whoami without a token is not authenticated"
else record 5 "whoami (no env)" "$RC" FAIL "wrangler whoami without a token is logged in — run npx wrangler logout"
fi

echo "cf-scope-probe: $NPASS/5 PASS — full output $OUT" | scrub | tee -a "$OUT"
[ "$NPASS" = 5 ]
