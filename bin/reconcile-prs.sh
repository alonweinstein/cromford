#!/bin/bash
# PR truth reconciler — cron every 10 min. Console rows say "unmerged"; GitHub
# decides. Any PR merged outside the queue (orchestrator gh merge, manual merge
# on github.com) gets its build row corrected so /needs never shows stale
# Merge buttons.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-reconcile-prs
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off reconcile-prs.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit reconcile-prs
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    reconcile-prs
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
# >>> one box (BH-1583) — this lane reads the SAME fleet-wide console list on
# every box it is installed on, so only the box the settings row
# lane.reconcile-prs.reconcile_prs_owner names runs it (registry default `hub`).
# Every other box stops here, before any console or GitHub read, and says so
# once per owner value. The reads themselves (one closed-PR list per repo, a
# capped per-PR fallback, the 404 backoff) live in bin/lib/reconcile-read.sh.
# shellcheck source=bin/lib/hub-box.sh
[ -r "$HARNESS/bin/lib/hub-box.sh" ] && . "$HARNESS/bin/lib/hub-box.sh"
# shellcheck source=bin/lib/reconcile-read.sh
. "$HARNESS/bin/lib/reconcile-read.sh" 2>/dev/null \
  || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') reconcile-prs: bin/lib/reconcile-read.sh missing — tick not run" >> "$HARNESS/logs/reconcile.log"; exit 0; }
# shellcheck source=bin/lib/reconcile-owner-beat.sh
. "$HARNESS/bin/lib/reconcile-owner-beat.sh" 2>/dev/null || rcr_owner_beat() { :; }
rcr_knobs_ok || exit 0
rcr_owner_skip && exit 0
# <<< one box
# The fan-in assertion (BH-186): every console row this tick enumerates is
# accounted with its outcome, and a tick that lost one says so. A box without
# the lib reconciles exactly as before: no ledger, and the body runs bare.
# shellcheck source=bin/lib/fanin.sh
. "$HARNESS/bin/lib/fanin.sh" 2>/dev/null || {
  fanin_begin() { :; }; fanin_enumerate() { :; }; fanin_end() { :; }
  fanin_run() { shift 2; "$@"; }
}
exec 5>"$HARNESS/locks/reconcile.lock"
flock -n 5 || exit 0
# The jobs ledger learns that a closed-unmerged PR is over, so the ticket stops
# looking owned. Fail-open: a box without the client reconciles exactly as it
# always has (BH-866).
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
# Only the owner box gets here (rcr_owner_skip above), so only the owner beats.
rcr_owner_beat
# BH-1295 REVIEW FIX (F1, round 2): armed BEFORE any gh_rest GET runs, not
# just before the report call — gh-rest-etag.sh's _gh_etag_count is a no-op
# with nothing exported, so an unarmed tick would count nothing and the
# report at the bottom would read fetched=0 cached=0 forever.
# BH-1322: the file lives under the box's own state dir, not $TMPDIR, and the
# EXIT trap removes it on every normal exit and on SIGTERM. A SIGKILL runs no
# trap; _gh_etag_counts_sweep (from the next lane to report) is the backstop.
export GH_ETAG_COUNT_FILE="$HARNESS/state/gh-etag/counts/reconcile-prs.$$"
# The reconcile memory is flushed ONCE per tick: after the summary on a normal
# tick, from the EXIT trap on one that stops early. command -v keeps a box whose
# reconcile-read.sh predates the stub from printing "command not found".
_rcr_flush_once() {
  [ -n "${RCR_FLUSHED:-}" ] && return 0
  RCR_FLUSHED=1
  command -v rcr_memory_flush >/dev/null 2>&1 && rcr_memory_flush
  return 0
}
trap 'rm -f "$GH_ETAG_COUNT_FILE"; _rcr_flush_once; rcr_tick_end' EXIT
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
# BH-1292 (I2): 300s, not the lib's 1800s default. The wake launch that stamps
# this lane arrives 15-45s after the closure, so it finds the closure younger
# than MC_CLOSED_SETTLE (180s, bin/lib/mc/settle.sh) and does NOT clear the row
# — 300s is past that settle window with margin and still inside the 600s cron
# period, so the first tick after it both runs and finds the closure settled.
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip reconcile-prs fleet 300 && exit 0
# <<< wake backstop

# A CLOSED PR MAY BE MID-KICK (2026-09-15). The merge conductor closes a PR and
# reopens it one REST call later (mc_kick_ci) to fire the `pull_request`
# workflow a base change does not fire. That happens under the conductor's own
# per-project lock, which this lane does not take and cannot see — and this
# lane's answer to CLOSED is PERMANENT (the console row is cleared and nothing
# puts it back). So a closure younger than MC_CLOSED_SETTLE is skipped and
# re-read on the next */10 pass. bin/merge-sweep.sh asks the same question for
# the same reason; the one copy of it lives in the conductor's lib.
# shellcheck source=bin/lib/merge-conductor-lib.sh
# BH-994/BH-1295: mc_pr_view is also this lane's read of PR state below. Before
# that conversion a missing lib only cost mc_closed_settled (fails open,
# return 0); the state read itself was independent of the lib. `return 75`
# here would change that: every read skipped, no row ever cleared, on a box
# that has never needed the lib for this before. The fallback instead
# re-derives the SAME REST-shaped object mc_pr_view would hand back, over
# `gh api` — REST, never GraphQL (the standing fleet rule gh_rest exists for:
# a GraphQL rate limit kills a lane mid-session, and a no-lib fallback is
# exactly the path firing when things are already degraded) — so both call
# sites below see no difference at all.
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then . "$HARNESS/bin/lib/merge-conductor-lib.sh"
else
  mc_closed_settled() { return 0; }
  mc_pr_view() { # mc_pr_view <pr-url> <jq-expr> -- no lib: gh api REST, translated
    local url="${1:-}" slug num j
    slug=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$url")
    num=$(grep -oE '[0-9]+$' <<<"$url")
    [ -n "$slug" ] && [ -n "$num" ] || return 75
    j=$(gh api "repos/$slug/pulls/$num" \
          -q '{STATE:(if (.merged_at // null) != null then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end), closed_at:.closed_at, merged_at:.merged_at, merge_commit_sha:.merge_commit_sha}' 2>/dev/null) || return 75
    [ -n "$j" ] || return 75
    printf '%s' "$j" | jq -r "${2:-.}" 2>/dev/null || return 75
  }
fi
# THE IDENTITY EACH READ GOES OUT ON (#469). This lane reads PRs across every
# repo the console names (since BH-1583 on ONE box, one list per repo), so it
# is still a real spender of the shared bucket. gh_default_auth_for_slug asks
# for a repo-scoped App token per repo and falls back to today's PAT. It is NOT
# given bin/lib/gh-repo-token.sh on purpose: this lane runs no visibility probe
# and pages for nothing, and adding a probe per PR per tick to every box is a
# cost this ticket has no reason to introduce.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
# rcr_auth <slug> — the identity hook bin/lib/reconcile-read.sh calls before
# every read it makes (BH-1583: once per repo for the list, and once more before
# each capped single read). rc ignored on purpose: this lane's contract is
# "GitHub decides", and an unmintable repo falls back to the PAT inside the
# helper. The PR-url form of the old fallback is kept for a box whose
# gh-app-auth predates gh_default_auth_for_slug.
rcr_auth() {
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then gh_default_auth_for_slug "$1" >/dev/null 2>&1 || true
  else command -v gh_auth_for_url >/dev/null 2>&1 && gh_auth_for_url "https://github.com/$1/pull/0" || true; fi
}

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/builds/unmerged") || exit 0
MERGED="[]"
CLOSED="[]"
# BH-1583: ONE closed-PR list read per repo named in the console list, before
# the loop. The identity each goes out on is armed per repo inside rcr_page /
# rcr_auth (gh_default_auth_for_slug, #469) — rc ignored on purpose: this
# lane's contract is "GitHub decides", and an unmintable repo falls back to the
# PAT inside the helper. A box that cannot make its tick dir reads nothing.
rcr_tick_begin || exit 0
rcr_fetch_pages "$RESP"
# ONE ROW, ONE OUTCOME (BH-186). The per-row body is a function that fanin_run
# calls in THIS shell (it appends to MERGED and CLOSED), and every way out of it
# is a `return` with RCR_OUTCOME set — never `continue`, `break` or `exit`: bash
# lets a `continue` in a function act on the caller's loop, which would skip the
# accounting, and the fan-in check would name the row as missing.
rcr_one_pr() {
  local BKEY="$1" URL="$2"
  [ -n "$URL" ] || { RCR_OUTCOME=skipped:no-url; return 0; }
  # THE MERGE FACT, NEVER THE CLOSED STATE (BH-866). `state == CLOSED` is true of
  # every merged PR and of every abandoned one, so a lane that classifies on it
  # reports work that never shipped as shipped: project-4 #1579 (auto-closed when its
  # base branch was deleted) and #1541 (closed as superseded) both reached the
  # console as merged/deployed rows. `mergedAt` is the only field that says a
  # merge happened. Field ORDER matters: state first, so the two-field stubs
  # that already drive this lane still parse.
  # BH-1583: answered from this tick's page for the repo, a proved-open
  # watermark, a remembered settled answer, or — capped per tick — one REST
  # read through mc_pr_view (never `gh pr view`, GraphQL). RCR_STATE uses the
  # same MERGED/OPEN/CLOSED words mc_rest_pr_json always did, so the checks
  # below need no change. Nothing answered = empty STATE = neither list.
  rcr_pr_state "$URL"
  STATE="$RCR_STATE"; CLOSED_AT="$RCR_CLOSED_AT"; MERGED_AT="$RCR_MERGED_AT"
  # BH-3971: MERGED needs `merged_at`. The word alone is not the fact, so it is
  # read as unanswered this pass, and the memo it may have come from is dropped
  # so the next pass re-derives it from GitHub.
  if [ -n "${MERGED_AT:-}" ]; then STATE=MERGED
  elif [ "$STATE" = "MERGED" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $BKEY ($URL) reads MERGED with no merged_at — not a merge fact, skipped this pass" >> "$HARNESS/logs/reconcile.log"
    rcr_forget_terminal "$URL"; STATE=""
  fi
  case "$STATE" in "") RCR_OUTCOME=skipped:unread ;; OPEN) RCR_OUTCOME=skipped:open ;; esac
  # A settled answer is kept for good: this lane's answer to CLOSED and MERGED
  # is already permanent, and a row the console keeps listing must not cost a
  # read on every tick once it falls off the recent-closed page.
  if [ "$STATE" = MERGED ] || { [ "$STATE" = CLOSED ] && mc_closed_settled "${CLOSED_AT:-}"; }; then
    rcr_remember_terminal "$URL"
  fi
  # CLOSED-not-merged (superseded/abandoned) must ALSO clear its console row —
  # three stale Merge buttons sat on /needs since Jul 24 (#320/#960/#138). No
  # ship beat and no deploy gate for these: nothing shipped. They get their own
  # terminal, `pr_closed`, which returns the ticket to the launchable pool.
  if [ "$STATE" = "CLOSED" ] && ! mc_closed_settled "${CLOSED_AT:-}"; then
    RCR_OUTCOME=skipped:closed-unsettled
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $BKEY ($URL) reads CLOSED but has not settled (closed $CLOSED_AT, window ${MC_CLOSED_SETTLE:-180}s) — skipped this pass, it may be a merge-conductor CI kick" >> "$HARNESS/logs/reconcile.log"
  elif [ "$STATE" = "CLOSED" ]; then
    # The LEDGER ROW FIRST, then the console, then the log. The row is an
    # idempotent upsert on the PR url and it is what bin/lib/ticket-identity.sh
    # and closeout_terminal read, so it survives a console that never answers.
    # Same kind/status vocabulary bin/merge-sweep.sh:655 writes, so every
    # existing reader understands it without a change.
    #
    # ONCE PER ROW, NOT ONCE PER PASS. `/api/builds/reconcile` lives in the
    # console repo and does not know the `closed` key yet (the human step in
    # this PR's body, example-org/cromford-console#36). Until it does, this
    # row stays in `/api/builds/unmerged` and every */10 pass meets it again —
    # so the PUT and the log line would repeat forever for a PR that closed
    # once. The marker is written only when the row is actually IN the ledger,
    # which is what makes a failed PUT retry next pass instead of being marked
    # done on the attempt. The console list below is still sent every pass: that
    # is the message the console has to receive to retire the row.
    CMARK="$HARNESS/state/reconcile-closed/$(printf '%s' "$BKEY" | tr -c 'A-Za-z0-9._-' '_')"
    if [ ! -e "$CMARK" ]; then
      CDONE=0
      if command -v job_ledger_put >/dev/null 2>&1; then
        job_ledger_put merge "$URL" closed "reconcile-prs: closed unmerged (pr_closed)" >/dev/null 2>&1 && CDONE=1
      else
        CDONE=1   # no jobs client on this box: there is nothing left to retry
      fi
      if [ "$CDONE" = 1 ]; then
        mkdir -p "$HARNESS/state/reconcile-closed" 2>/dev/null && : > "$CMARK" 2>/dev/null || true
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') cleared CLOSED (unmerged) PR row $BKEY ($URL) as pr_closed — nothing shipped, the ticket is launchable again (said once; the console list is re-sent every pass until /api/builds/reconcile learns the closed key)" >> "$HARNESS/logs/reconcile.log"
      fi
    fi
    CLOSED=$(jq -c --arg b "$BKEY" '. + [$b]' <<<"$CLOSED")
    RCR_OUTCOME=closed
  fi
  if [ "$STATE" = "MERGED" ]; then
    MERGED=$(jq -c --arg b "$BKEY" '. + [$b]' <<<"$MERGED")
    RCR_OUTCOME=merged
    # Ship beat (2026-07-23, per the operator): ping Telegram when a tier-2 PR is
    # actually merged, not just opened. akey dedupes per build; the board
    # what-shipped comment was posted at PR-open, so merged == fully done.
    # The project comes from the REGISTRY (bin/project-of.sh), never from a
    # string operation on the key. This used to be `PROJ="${BKEY%%-os-*}-os"`,
    # which assumes every fleet project's name ends in "-os" — true of the
    # original four and of nothing enrolled since. For a project-5 build key
    # there is no "-os-" to cut on, so PROJ came out as the WHOLE key with "-os"
    # stapled on and the slug below as "example-org/pool-project-5-TK-419-…-os":
    # a repo that does not exist. No project-5, project-6, project-7 or
    # project-8 PR has ever been reconciled here. `pool-` is the hub's
    # copy prefix, stripped the same way merge-sweep.sh and mc_issue_of strip it.
    PROJ=$("$HARNESS/bin/project-of.sh" --prefix "${BKEY#pool-}" 2>/dev/null || true)
    if [ -z "$PROJ" ]; then
      # The console row is still cleared above; only the project-scoped work is
      # skipped, and it says so rather than inventing a project name.
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $BKEY ($URL) merged but names no fleet project — row reconciled, no ship beat, no deploy gate" >> "$HARNESS/logs/reconcile.log"
      RCR_OUTCOME=merged:no-project; return 0
    fi
    KEY=$(sed -E "s/^(pool-)?${PROJ}-//; s/-[0-9]{12,}$//" <<<"$BKEY")
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJ" --arg akey "shipped:$BKEY" \
      --arg l "$KEY merged and live — board already commented ($URL)" \
      '{kind:"ticket_shipped",project:$p,akey:$akey,line:$l}')"
    # Tier-2 deploy gate (2026-07-27): human-merged harness PRs get the same
    # post-merge prod verification as tier-1 auto-merges. Runs once per build
    # (this loop only sees a PR in the merged state once, then reconciles it).
    # The slug is the registry's too — it is the only thing that knows an owner
    # is not always "example-org" and that project-2's repo name carries a typo.
    SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJ" repo 2>/dev/null || true)
    [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || { RCR_OUTCOME=merged:no-slug; return 0; }
    # BH-1583: the merge sha came with the state read above — no second read.
    MSHA="$RCR_MSHA"
    if [ -n "$MSHA" ]; then
      DVDIR="$HARNESS/builds/reconcile-$BKEY"; mkdir -p "$DVDIR"
      # Route through deploy-request: train-verified projects (VERSION_URL) go to the
      # deploy train; legacy deploy-verify only where no train exists. (2026-07-29:
      # legacy verify polls the GitHub deployments API, which is blind to the
      # train's hook-fired deploys — it false-alarmed on already-verified merges.)
      # Only the box that OWNS a project's deploys (its env has DEPLOY_HOOK_URL)
      # runs the deploy gate — the hub reconciles every project's console rows,
      # and gating a project it can't deploy produced blind false alarms
      # (project-4 TK-21, 2026-07-29 13:00Z). The owning box's machinery covers it.
      if grep -q "^DEPLOY_HOOK_URL=" "$HENV/$PROJ.env" 2>/dev/null; then
        (setsid "$HARNESS/bin/deploy-request.sh" "$PROJ" "$SLUG" "$MSHA" "$DVDIR" </dev/null >"$DVDIR/deploy-verify.log" 2>&1 &)
      fi
    fi
  fi
}
# Enumerate every row the console listed (a url-less one included) BEFORE any
# is worked; the id is the build key, or row#<n> for a row without one.
mapfile -t RCR_ROWS < <(jq -r '.builds[]? | [.bkey, .pr_url] | @tsv' <<<"$RESP")
RCR_IDS=()
fanin_begin reconcile-prs fleet "$HARNESS/logs/reconcile.log"
for RCR_ROW in "${RCR_ROWS[@]}"; do
  IFS=$'\t' read -r BKEY URL <<<"$RCR_ROW"
  RCR_IDS+=("${BKEY:-row#$(( ${#RCR_IDS[@]} + 1 ))}")
  fanin_enumerate "${RCR_IDS[-1]}"
done
RCR_I=0
for RCR_ROW in "${RCR_ROWS[@]}"; do
  IFS=$'\t' read -r BKEY URL <<<"$RCR_ROW"
  fanin_run "${RCR_IDS[$RCR_I]}" RCR_OUTCOME rcr_one_pr "$BKEY" "$URL"
  RCR_I=$((RCR_I + 1))
done
fanin_end
# Forget PRs the console no longer lists — only when it answered with a list,
# so a console blip cannot wipe the watermarks that keep open PRs read-free.
jq -e '.builds | type == "array"' <<<"$RESP" >/dev/null 2>&1 && rcr_prune
rcr_tick_summary
_rcr_flush_once

COUNT=$(jq 'length' <<<"$MERGED")
CCOUNT=$(jq 'length' <<<"$CLOSED")
post_reconcile() { # post_reconcile <json-body> -> prints the http status, or ""
  local out
  out=$(curl -s --max-time 20 -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
    -d "$1" "$CONSOLE_URL/api/builds/reconcile" 2>/dev/null)
  local code="${out##*$'\n'}"
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '' ;; esac
}
if [ "$COUNT" -gt 0 ] || [ "$CCOUNT" -gt 0 ]; then
  HTTP=$(post_reconcile "$(jq -nc --argjson m "$MERGED" --argjson c "$CLOSED" '{merged:$m,closed:$c}')")
  # The console repo is not this one, and it learns the `closed` key in its own
  # PR (see the PR body's human steps). Until it does, a console that refuses
  # the whole POST must not take the MERGED rows down with it — so a non-2xx
  # answer is retried once with the payload the console has always accepted, and
  # the refusal is said out loud rather than swallowed. An answer we cannot read
  # a status from is today's behaviour: fire and forget.
  # ...and ONLY when there was a `closed` list to drop. With CCOUNT=0 the
  # payload the console just refused is already the one it has always accepted,
  # so a non-2xx is an outage (a 500, an expired secret) — re-POSTing the
  # identical body buys nothing and "console refused closed list" would be a
  # false sentence in the log of every console blip.
  case "$HTTP" in
    2*|"") : ;;
    *) if [ "$CCOUNT" -gt 0 ]; then
         echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') console refused closed list (http $HTTP) — retrying with merged only; the $CCOUNT pr_closed row(s) keep their console state and stay in the jobs ledger" >> "$HARNESS/logs/reconcile.log"
         post_reconcile "$(jq -nc --argjson m "$MERGED" '{merged:$m}')" >/dev/null
       else
         echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') console answered http $HTTP on reconcile (nothing closed in this pass, so nothing was dropped and nothing is retried)" >> "$HARNESS/logs/reconcile.log"
       fi ;;
  esac
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') reconciled $COUNT externally-merged PR(s), $CCOUNT closed unmerged (pr_closed)" >> "$HARNESS/logs/reconcile.log"
fi
command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report reconcile-prs
exit 0
