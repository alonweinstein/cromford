#!/bin/bash
# bin/e2e-smoke.sh <project> <repo-slug> <sha> <out-dir> [repo-dir]
#
# E2E smoke stage (SDLC playbook item 2). Until now a build session verified
# itself with typecheck + `npm run build` only, so a behaviour regression — a
# page that 500s, a component that throws on mount — reached the reviewer and
# then prod with nothing having LOADED it. This stage loads it, against the
# branch's own Vercel PREVIEW deployment, before the reviewer reads the diff.
#
# NEVER PROD. The URL comes from bin/wait-preview.sh, which resolves PREVIEW
# deployments for one sha out of the hub's deploy-snapshot relay (boxes hold no
# Vercel token) and falls back to the GitHub Deployments API. Nothing here
# reads vercel.conf's prod domain, and nothing self-fetches a VERCEL_URL /
# *.vercel.app address — the preview URL is Vercel's own alias for that sha.
#
# FAIL-OPEN ON INFRASTRUCTURE, LOUD ON DEFECTS. No Vercel lane for the project,
# no preview for the sha, a protected preview, playwright missing — every one of
# those is a recorded SKIP with a reason, never a silent pass and never a block.
# Only a route that 5xx'd, threw, or logged a console error is a FAIL.
#
# Writes <out-dir>/e2e.md whose LAST LINE is exactly "E2E: PASS", "E2E: FAIL"
# or "E2E: SKIP" — the line bin/run-build.sh feeds to the reviewer and
# bin/merge-sweep.sh refuses to merge over.
#
# PERSONAS. When the repo carries qa/personas.json, the route smoke is followed
# by one signed-in drive per persona the diff touches (bin/lib/qa-personas.sh
# scopes them; bin/qa-unbanned.sh owns the QA account's ban state; the flow
# engine is bin/qa-drive.mjs, always with --preview so a write flow runs here
# and nowhere else). Each flow lands as one `FLOW <persona> <flow> …` row in
# e2e.md. A persona that could not be driven — no QA account, no QA env, a
# declined unban window, a drive that printed nothing, the E2E_MAX_PERSONAS cap
# — is recorded as `blocked`, which never fails the stage; only a `fail` row
# does, and only alongside the smoke's own verdict.
#
# Exit: 0 = PASS, 3 = SKIP (recorded, non-blocking), 4 = FAIL.
#
# Path overrides exist for tests only; cron and run-build.sh set none of them:
# HARNESS, VERCEL_CONF, E2E_ROUTES_FILE, WAIT_PREVIEW, E2E_NODE, E2E_TIMEOUT,
# E2E_CHANGED_FILES, E2E_QA_UNBANNED, E2E_QA_ACCOUNT, E2E_MAX_PERSONAS,
# QA_PERSONAS_PER_AREA (the env fallback of the qa.personas_per_area row).
set -uo pipefail
PROJECT="${1:?project}"; SLUG="${2:?repo-slug}"; SHA="${3:?sha}"; OUT="${4:?out-dir}"
REPO="${5:-$PWD}"
HARNESS="${HARNESS:-/root/harness}"
SELF=$(cd "$(dirname "$0")" && pwd)
VERCEL_CONF="${VERCEL_CONF:-$HARNESS/vercel.conf}"
ROUTES_FILE="${E2E_ROUTES_FILE:-$HARNESS/catalog/e2e-smoke-routes.json}"
WAIT_PREVIEW="${WAIT_PREVIEW:-$HARNESS/bin/wait-preview.sh}"
NODE_BIN="${E2E_NODE:-node}"
mkdir -p "$OUT"

PERSONAS_NOTE=""   # "" = no personas lane to report; "invalid — …" = recorded
SCOPED=""          # path of the scoped document once a persona is in scope

# SKIP <reason> — the honest non-verdict. It is written to e2e.md in the same
# shape a PASS/FAIL is, because a stage that stays silent when it could not run
# is indistinguishable from one that ran and found nothing (the 2026-08-14
# lesson that put the QA gate's "EMPTY IS NOT PASS" rule in run-build.sh).
SKIP() {
  { echo "E2E smoke did not run: $1"
    echo "This is a SKIP, not a pass — nothing about this diff was verified in a browser."
    [ -n "$PERSONAS_NOTE" ] && echo "PERSONAS: $PERSONAS_NOTE"
    echo "E2E COVERAGE: routes=0 failed=0"
    echo "E2E: SKIP"; } > "$OUT/e2e.md"
  cat "$OUT/e2e.md"
  exit 3
}

# --- 1. Does this project even have a Vercel lane? ---------------------------
# vercel.conf is the registry of which product has a Vercel project at all.
# A project absent from it can never have a preview, so waiting on one would
# burn the timeout to reach a conclusion the config already knows.
[ -s "$VERCEL_CONF" ] || SKIP "no vercel.conf at $VERCEL_CONF"
awk -v p="$PROJECT" '$1 !~ /^#/ && $1 == p {found=1} END {exit !found}' "$VERCEL_CONF" \
  || SKIP "$PROJECT has no Vercel project in vercel.conf — no preview deployments exist for it"

command -v "$NODE_BIN" >/dev/null 2>&1 || SKIP "node is not on PATH"
[ -r "$SELF/e2e-smoke.mjs" ] || SKIP "bin/e2e-smoke.mjs is missing on this box"

# --- 2. Routes: the project's declared smoke list + the diff's own new pages --
ROUTES=$(jq -r --arg p "$PROJECT" \
  '((.projects[$p] // ._default_routes // ["/"]) | .[])' "$ROUTES_FILE" 2>/dev/null)
[ -n "$ROUTES" ] || ROUTES="/"

# Routes this diff ADDS or CHANGES, derived from app-router page files so the
# smoke actually loads the new code rather than only the home page. Static
# segments only: a [id] route needs a real record to be meaningful and this
# stage will not go looking for one in a shared production database.
if [ -n "${E2E_BASE_REF:-}" ] && git -C "$REPO" rev-parse --verify -q "$E2E_BASE_REF" >/dev/null 2>&1; then
  # path -> route: drop everything above app/, drop the page file, erase route
  # groups "(app)", then keep only static routes. A [id] route needs a real
  # record to mean anything and this stage will not go hunting for one in a
  # database the preview shares with production.
  CHANGED=$(git -C "$REPO" diff --name-only "$E2E_BASE_REF"...HEAD 2>/dev/null \
    | grep -E '(^|/)app/(.*/)?page\.(t|j)sx?$' \
    | sed -E 's#^(.*/)?app/##; s#page\.[tj]sx?$##; s#\([^)]*\)/##g; s#/+$##' \
    | sed -E 's#^#/#' | grep -v '\[' | sort -u)
  [ -n "$CHANGED" ] && ROUTES=$(printf '%s\n%s\n' "$ROUTES" "$CHANGED" | awk 'NF' | awk '!seen[$0]++')
fi

# --- 2b. Personas: which of them does THIS diff touch? -----------------------
# Scoped here, before the preview wait, because the answer can end the stage:
# run-build.sh now enters this stage for any repo carrying qa/personas.json, so
# a diff with no UI file and no persona in scope has to end exactly where it
# always did — in the SKIP it would have got from the gate, not after ten
# minutes of waiting on a preview nobody is going to load.
#
# An invalid file is RECORDED and the route smoke continues. A schema defect in
# a client repo's qa/ directory is not a reason to stop verifying the diff, and
# it is not a reason to pretend the personas passed either.
UI_RE='\.(tsx|jsx|css)$|(^|/)app/|(^|/)components/|(^|/)pages/'   # run-build.sh's gate, verbatim
if [ -f "$REPO/qa/personas.json" ]; then
  mkdir -p "$OUT/e2e-flows"
  CF="$OUT/e2e-flows/changed-files.txt"
  DF="$OUT/e2e-flows/diff-files.txt"; : > "$DF"
  # UICF is what the "no UI files" question is asked of: the diff alone, the
  # same list run-build.sh's gate reads. Only when there is no diff to read
  # (test override, unresolvable base) does it fall back to the scoping list.
  UICF="$CF"
  if [ -n "${E2E_BASE_REF:-}" ] && git -C "$REPO" rev-parse --verify -q "$E2E_BASE_REF" >/dev/null 2>&1; then
    git -C "$REPO" diff --name-only "$E2E_BASE_REF"...HEAD 2>/dev/null > "$DF"
    UICF="$DF"
  fi
  if [ -n "${E2E_CHANGED_FILES:-}" ]; then
    cp "$E2E_CHANGED_FILES" "$CF" 2>/dev/null; UICF="$CF"
  else
    { cat "$DF"; cat "$OUT/planned-files.txt" 2>/dev/null; } | awk 'NF' | sort -u > "$CF"
  fi
  AF=""; [ -f "$REPO/qa/apps.json" ] && AF="$REPO/qa/apps.json"
  if [ -r "$SELF/lib/qa-personas.sh" ]; then
    . "$SELF/lib/qa-personas.sh"
    # BH-5204: one persona per changed app area. The per-area knob is the
    # qa.personas_per_area settings row when lane-gate.sh is on this box (the
    # size-threshold.sh pattern: sourced quietly, any failure leaves env then 1).
    if ! command -v _lg_setting_lookup >/dev/null 2>&1 && [ -r "$SELF/lib/lane-gate.sh" ]; then
      # shellcheck source=lib/lane-gate.sh
      . "$SELF/lib/lane-gate.sh" >/dev/null 2>&1 || true
      set -uo pipefail
    fi
    if command -v _lg_settings_refresh >/dev/null 2>&1 \
       && { command -v _jobs_req >/dev/null 2>&1 || [ -r "$HARNESS/bin/jobs-client.sh" ]; }; then
      _lg_settings_refresh >/dev/null 2>&1 || true
      set -uo pipefail
    fi
    PER_AREA=$(qa_personas_per_area 2>>"$OUT/e2e-run.txt")
    SC=$(qa_personas_pick "$REPO/qa/personas.json" "$AF" "$CF" preview "$PER_AREA" 2>"$OUT/e2e-flows/personas.err")
    if [ $? -ne 0 ]; then
      PERSONAS_NOTE="invalid — $(head -1 "$OUT/e2e-flows/personas.err" 2>/dev/null | head -c 200)"
    elif [ "$SC" = NONE ]; then
      grep -qiE "$UI_RE" "$UICF" 2>/dev/null \
        || SKIP "no UI-touching files in the diff, or $PROJECT has no Vercel project in vercel.conf."
    else
      SCOPED="$OUT/e2e-flows/scoped.json"
      printf '%s\n' "$SC" > "$SCOPED"
    fi
  else
    PERSONAS_NOTE="invalid — bin/lib/qa-personas.sh missing on this box"
  fi
fi

# --- 3. The preview URL for THIS sha -----------------------------------------
[ -x "$WAIT_PREVIEW" ] || SKIP "bin/wait-preview.sh is missing on this box"
# 600s, matching the post-PR QA wait, and the number is set by the RELAY not by
# the build: wait-preview.sh reads state/vercel-deploys/<project>.json, which the
# hub's vercel-deploy-snapshot.sh refreshes on a */10 cron. A shorter wait would
# usually expire before the snapshot ever moved and would report a skip about our
# own polling rather than about Vercel. Even at 600s a build that pushes just
# after a relay tick can miss the refresh and skip honestly — that is the
# fail-open working, and it is why nothing downstream reads a SKIP as a pass.
# stderr goes to its OWN file, never into $PREVIEW. wait-preview.sh narrates its
# polling on stderr while the URL comes back on stdout, and `2>&1` would splice
# that chatter into the address the browser is handed — with no ordering
# guarantee that a `tail -1` could undo. The narration is still wanted, but as
# the SKIP's reason, not as part of a URL.
WPERR=$(mktemp); trap 'rm -f "$WPERR"' EXIT
PREVIEW=$(PROJECT="$PROJECT" "$WAIT_PREVIEW" "$SLUG" "$SHA" "${E2E_TIMEOUT:-600}" 2>"$WPERR") || \
  SKIP "no usable preview deployment for $SHA ($(tail -1 "$WPERR" 2>/dev/null | head -c 200 || echo 'wait-preview gave no reason'))"
PREVIEW=$(printf '%s' "$PREVIEW" | tr -d '\r' | tail -1)
case "$PREVIEW" in
  https://*) ;;
  *) SKIP "wait-preview returned no URL for $SHA (stdout: $(printf '%s' "$PREVIEW" | head -c 120))" ;;
esac

# --- 4. Drive it -------------------------------------------------------------
# The smoke's own stdout is the record; e2e.md is written by the script itself
# so a killed node still leaves whatever it had. A non-0/4 exit is the script
# saying it could not run, which is a SKIP, not a verdict about the diff.
ROUTES="$ROUTES" timeout "${E2E_RUN_TIMEOUT:-600}" \
  "$NODE_BIN" "$SELF/e2e-smoke.mjs" "$PREVIEW" "$OUT" "$REPO" > "$OUT/e2e-run.txt" 2>&1
RC=$?
case "$RC" in
  0) tail -1 "$OUT/e2e.md" 2>/dev/null | grep -qx 'E2E: PASS' || SKIP "the smoke exited 0 without writing a PASS verdict" ;;
  4) tail -1 "$OUT/e2e.md" 2>/dev/null | grep -qx 'E2E: FAIL' || SKIP "the smoke exited 4 without writing a FAIL verdict" ;;
  *) SKIP "the smoke could not run (rc=$RC): $(tail -3 "$OUT/e2e-run.txt" 2>/dev/null | tr '\n' ' ' | head -c 300)" ;;
esac
SMOKE_RC=$RC

# --- 5. Drive the personas the diff touched ----------------------------------
# Only once the route smoke has reached a verdict: a preview whose pages do not
# even load is not worth unbanning a privileged QA account for. A FAILED smoke
# still drives — the flows say WHICH screens are broken, which is the part a
# reviewer of a red stage actually needs.
if [ -n "$SCOPED" ]; then
  FLOWS="$OUT/e2e-flows/flows.txt"; : > "$FLOWS"
  MAXP="${E2E_MAX_PERSONAS:-4}"
  case "$MAXP" in
    ''|*[!0-9]*) echo "E2E_MAX_PERSONAS='${E2E_MAX_PERSONAS:-}' is not a number — using the default of 4" >> "$OUT/e2e-run.txt"
                 MAXP=4 ;;
  esac
  QA_ACCOUNT="${E2E_QA_ACCOUNT:-$SELF/qa-account.sh}"
  QA_UNBANNED="${E2E_QA_UNBANNED:-$SELF/qa-unbanned.sh}"
  N=0; DRIVEN=0
  while IFS=$'\t' read -r PID PROLE; do
    [ -n "$PID" ] || continue
    N=$((N+1))
    # Every refusal below is a row per flow, never an absent persona: a flow
    # nobody drove has to be visible as one nobody drove.
    if [ -z "${QA_CLERK_SECRET_KEY:-}" ]; then
      qa_personas_blocked_rows "$SCOPED" "$PID" "no QA env" >> "$FLOWS"; continue
    fi
    if [ "$N" -gt "$MAXP" ]; then
      qa_personas_blocked_rows "$SCOPED" "$PID" "not driven (persona cap)" >> "$FLOWS"; continue
    fi
    if [ ! -x "$QA_UNBANNED" ]; then
      qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned.sh missing on this box" >> "$FLOWS"; continue
    fi
    PUID=$(HARNESS="$HARNESS" "$QA_ACCOUNT" "$PROJECT" "$PROLE" 2>/dev/null) || {
      qa_personas_blocked_rows "$SCOPED" "$PID" "no QA account for $PROJECT/$PROLE" >> "$FLOWS"; continue; }
    PDIR="$OUT/e2e-flows/$PID"; mkdir -p "$PDIR"
    HARNESS="$HARNESS" QA_TEST_USER_ID="$PUID" "$QA_UNBANNED" "$PROJECT" "$PROLE" -- \
      timeout "${E2E_RUN_TIMEOUT:-600}" "$NODE_BIN" "$SELF/qa-drive.mjs" "$PREVIEW" "$REPO" "$PDIR" \
      --flows "$SCOPED" --persona "$PID" --preview \
      > "$OUT/e2e-flows/$PID.txt" 2>&1 </dev/null
    PRC=$?; DRIVEN=$((DRIVEN+1))
    case "$PRC" in
      75) qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned rc=75 (QA account busy, nothing was touched)" ;;
      90) qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned rc=90 (re-ban failed)" ;;
      91) qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned rc=91 (ban state unreadable or unban did not take)" ;;
      # rc alone is not a verdict: a drive that printed rows meant them, and a
      # drive that printed none proved nothing whatever its exit code says.
      *)  if grep -q '^FLOW ' "$OUT/e2e-flows/$PID.txt" 2>/dev/null
          then grep '^FLOW ' "$OUT/e2e-flows/$PID.txt"
          else qa_personas_blocked_rows "$SCOPED" "$PID" "drive emitted no FLOW rows (rc=$PRC)"; fi ;;
    esac >> "$FLOWS"
  done < <(qa_personas_list "$SCOPED")

  # flows= counts pass plus fail only (docs/E2E-POLICY.md § Personas); blocked
  # is counted on its own and skipped is counted nowhere.
  read -r NF NG NB <<EOF
$(awk '$1=="FLOW" {if ($4=="pass" || $4=="fail") f++; if ($4=="fail") g++; if ($4=="blocked") b++}
       END {printf "%d %d %d\n", f, g, b}' "$FLOWS")
EOF
  COV=$(grep -a -m1 '^E2E COVERAGE:' "$OUT/e2e.md" 2>/dev/null)
  NROUTES=$(printf '%s' "$COV" | grep -oE 'routes=[0-9]+' | head -1 | cut -d= -f2); NROUTES="${NROUTES:-0}"
  NFAILED=$(printf '%s' "$COV" | grep -oE 'failed=[0-9]+' | head -1 | cut -d= -f2); NFAILED="${NFAILED:-0}"
  VERDICT=PASS; EXIT_RC=0
  { [ "$SMOKE_RC" = 4 ] || [ "$NG" -gt 0 ]; } && { VERDICT=FAIL; EXIT_RC=4; }
  # Rewritten through a temp file, not in place: the smoke's own rows are the
  # INPUT to this, and a `>` on the file being read would leave a record with
  # no routes in it. The FLOW rows sit before the coverage line so that
  # E2E_SETTLE's tail of e2e.md carries them to the reviewer.
  { awk '/^E2E COVERAGE:/{exit} /^E2E: (PASS|FAIL|SKIP)$/{exit} {print}' "$OUT/e2e.md"
    printf 'PERSONAS: %s\n' "$(qa_personas_pick_note "$SCOPED")"
    printf 'Personas: %s in scope, %s driven (mode preview)\n' "$N" "$DRIVEN"
    cat "$FLOWS"
    printf 'E2E COVERAGE: routes=%s failed=%s flows=%s flows_failed=%s flows_blocked=%s\n' \
      "$NROUTES" "$NFAILED" "$NF" "$NG" "$NB"
    printf 'E2E: %s\n' "$VERDICT"; } > "$OUT/e2e.md.new" && mv "$OUT/e2e.md.new" "$OUT/e2e.md"
  cat "$OUT/e2e.md"
  exit "$EXIT_RC"
fi

# No persona lane ran, so the coverage line keeps its two-field form. A recorded
# defect in the personas file still rides in the record, immediately before that
# line, where E2E_SETTLE's tail will pick it up.
if [ -n "$PERSONAS_NOTE" ]; then
  awk -v note="PERSONAS: $PERSONAS_NOTE" \
      '/^E2E COVERAGE:/ && !done {print note; done=1} {print}' "$OUT/e2e.md" > "$OUT/e2e.md.new" \
    && mv "$OUT/e2e.md.new" "$OUT/e2e.md"
fi
cat "$OUT/e2e.md"
exit "$SMOKE_RC"
