#!/bin/bash
# bin/data-lane-apply.sh <project> <pr> <build-dir> — the ahead-of-merge data
# lane's apply step (BH-4920; slices BH-4923, BH-4925). A review that BLOCKed a
# PR only because its migration is not on prod yet names that file on a
# `DATA_LANE: <path>` line (bin/lib/data-lane.sh). This applies that one file,
# at the PR head the review read, through the app's own
# /api/internal/migrations/apply in mode "pre-merge", proves it with a read-only
# /api/internal/migrations/probe, records the answer in the harness-jobs ledger
# (kind=migration, key "<project> <file>"), writes the evidence file and posts
# one evidence comment on the PR. It never merges, enqueues or re-reviews.
#
# Gates, in order; every refusal returns before any POST:
#   lane gate    lane_gate_or_exit data-lane (flags/lane-off-data-lane, all-off)
#   paused       flags/paused-<project>                      -> busy-shaped 75
#   dedupe       flock -n locks/data-lane-<project>-<pr>.lock -> 75, never waits
#   head         the PR head via REST, the diff from git     -> 75 unreadable
#   candidate    dl_candidate on <build-dir>/review.md, and dl_reviewed_sha
#                must equal the PR head                        -> 3
#   classifier   bin/check-migration-appliable.sh on the file at the head
#                FLAGGED -> ledger "flagged ..." then 2
#   targets      one read-only SELECT ... LIMIT 0 per ADD COLUMN (the column),
#                CREATE TABLE and CREATE INDEX (the table); any ALTER TABLE,
#                CREATE TABLE, CREATE INDEX or ADD it cannot turn into one, or
#                none at all -> 3 not-candidate: never apply what cannot be proven
#   configured   DATA_LANE_APP_BASE and MIGRATION_TOKEN from env/<project>.env
#                (never a settings row: it is the host the token is sent to,
#                tests/lanes-registry-test.sh section 17)       -> 5 no-path
#   ledger       same FP applied/already-applied -> no apply POST: probe only if
#                <build-dir>/data-lane-probe.md has no "fp=<FP>" line, then the
#                comment step; same FP failed/flagged -> 3, no POST, no alert;
#                unknown -> one hold alert, no POST, 75
# Then job_open kind=migration, ONE apply POST, and ok:true with a LITERAL status
# of applied or already-applied is the only success. A failure writes the ledger
# row "failed apply ..." FIRST, then exactly one lane-alert, and returns 1.
# A success is then probed: ONE POST of the targets, a pass only when ok:true
# and every target sent comes back ok:true under its exact string. A miss writes
# "failed probe PR#<n> head=<h12> fp=<FP>" FIRST, then exactly one lane-alert,
# no probe file, no comment, and returns 1. No retry of either: the next run
# reads that row and stops at the ledger gate. A pass writes the ledger row,
# then <build-dir>/data-lane-probe.md (dl_probe_file; atomic, with head= and
# fp= lines), then the comment step: one "DATA-LANE-APPLIED:" comment tagged
# <!-- dl-fp:<FP> -->, posted only when no comment carries the tag. A probe
# file that cannot be written answers comment-pending 75 with no comment. A listing
# that cannot be read in full, or a failed POST, is logged only and answers
# comment-pending 75, so the caller re-runs it and the ledger gate brings it
# straight back to the comment step.
#
# Stdout is ONE outcome word: applied | already-applied | failed | flagged |
# not-candidate | no-path | comment-pending | busy | paused. A lane-off run
# prints nothing and exits 0 (the gate's contract), so callers key on the word
# and the ledger row, never on rc 0 alone. rc: 0 applied (probed, comment on
# the PR), 1 failed, 2 flagged (and bad usage), 3 not-candidate, 5 no-path,
# 75 come back later (busy, paused, comment-pending).
# usage: data-lane-apply.sh <project> <pr> <build-dir>
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
PROJECT="${1:-}"; PR="${2:-}"; BUILD="${3:-}"
case "$PR" in ''|*[!0-9]*) echo "usage: data-lane-apply.sh <project> <pr> <build-dir>" >&2; exit 2 ;; esac
[ -n "$PROJECT" ] && [ -n "$BUILD" ] || { echo "usage: data-lane-apply.sh <project> <pr> <build-dir>" >&2; exit 2; }
PR=$((10#$PR)) # "007" is PR 7: one lock name, and a JSON number jq accepts

# >>> lane gate (BH-1165) — exits 0 when flags/all-off or flags/lane-off-data-lane is set.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit data-lane
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    data-lane
BIN="$(cd "$(dirname "$0")" && pwd)"
LOG="$HARNESS/logs/$PROJECT.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOGLINE() { echo "$(STAMP) data-lane: $*" >> "$LOG"; }
OUT() { LOGLINE "PR#$PR $2"; echo "$1"; exit "$3"; } # OUT <word> <log text> <rc>
mkdir -p "$HARNESS/locks" "$HARNESS/logs"

[ -f "$HARNESS/flags/paused-$PROJECT" ] && OUT paused "project paused — re-offer next tick" 75
exec 9>"$HARNESS/locks/data-lane-$PROJECT-$PR.lock"
flock -n 9 || OUT busy "another run holds the lock — skipped" 75

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# Again below the env load, so a settings row survives it (registry section 16).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    data-lane
# shellcheck source=/dev/null
[ -f "$BIN/jobs-client.sh" ] && . "$BIN/jobs-client.sh"
# BH-4153: on a box with a worker configured, paused-<p> is a harness_flags row
# and no flags/ file is written for it, so the file test above cannot see it.
# flag_active reads the row (or its last good cache), and a pause that cannot
# be read is ON: a paused project gets no prod apply (BH-4923's rule).
if command -v flag_active >/dev/null 2>&1 && flag_active "paused-$PROJECT" >/dev/null 2>&1; then
  OUT paused "project paused — re-offer next tick" 75
fi
# shellcheck source=bin/lib/data-lane.sh
. "$BIN/lib/data-lane.sh" || OUT not-candidate "bin/lib/data-lane.sh unreadable" 3
# shellcheck source=bin/lib/gh-rest.sh
. "$BIN/lib/gh-rest.sh" || OUT busy "bin/lib/gh-rest.sh unreadable" 75
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$BIN/lib/gh-app-auth.sh" ] && . "$BIN/lib/gh-app-auth.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/data-lane.XXXXXX") || OUT busy "mktemp failed" 75
trap 'rm -rf "$TMP"' EXIT

SLUG=$("$BIN/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || SLUG=""
[ -n "$SLUG" ] || OUT busy "no repo slug in fleet.conf for $PROJECT" 75
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
gh_rest GET "repos/$SLUG/pulls/$PR" > "$TMP/pr.json" || OUT busy "PR head unreadable (gh rc $?)" 75
HEAD=$(jq -r '.head.sha // empty' "$TMP/pr.json" 2>/dev/null)
BASEREF=$(jq -r '.base.ref // empty' "$TMP/pr.json" 2>/dev/null)
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] && [ -n "$BASEREF" ] || OUT busy "PR head unreadable (no head sha / base ref)" 75
H12=${HEAD:0:12}

RDIR="${DATA_LANE_REPO_DIR:-/root/repos/$PROJECT}"
git -C "$RDIR" cat-file -e "$HEAD^{commit}" 2>/dev/null || git -C "$RDIR" fetch -q origin "$HEAD" "$BASEREF" 2>/dev/null
MB=$(git -C "$RDIR" merge-base "origin/$BASEREF" "$HEAD" 2>/dev/null) \
  && git -C "$RDIR" diff --name-only "$MB" "$HEAD" > "$TMP/diff" 2>/dev/null \
  || OUT busy "cannot diff $H12 against origin/$BASEREF in $RDIR" 75

CAND=$(dl_candidate "$BUILD/review.md" "$TMP/diff") || OUT not-candidate "review is not a data-lane candidate" 3
FILE=${CAND#*$'\t'}
RSHA=$(dl_reviewed_sha "$BUILD") || RSHA=""
dl_sha_is "$RSHA" "$HEAD" || OUT not-candidate "$FILE: review read ${RSHA:0:12}, PR head is $H12" 3

mkdir -p "$TMP/m/$(dirname "$FILE")"
git -C "$RDIR" show "$HEAD:$FILE" > "$TMP/m/$FILE" 2>/dev/null || OUT not-candidate "$FILE: not readable at $H12" 3
FP=$(dl_fp "$TMP/m/$FILE") || OUT not-candidate "$FILE: fingerprint failed" 3
TAIL="PR#$PR head=$H12 fp=$FP"
KEY="$PROJECT $FILE"
ledger_put() { # ledger_put <status> — rc 1 when the row was not recorded
  type job_ledger_put >/dev/null 2>&1 && job_ledger_put migration "$KEY" "$1" >/dev/null 2>&1 && return 0
  LOGLINE "$FILE: ledger write failed (status '$1' not recorded)"; return 1
}

"$BIN/check-migration-appliable.sh" "$PROJECT" "$TMP/m" "$TMP/m/$FILE" > "$TMP/classify" 2>&1; CRC=$?
case "$CRC" in
  0) ;;
  1) ledger_put "flagged $TAIL"; OUT flagged "$FILE: FLAGGED by check-migration-appliable — never applied ahead of merge" 2 ;;
  *) OUT not-candidate "$FILE: classifier could not read it (rc $CRC)" 3 ;;
esac

# The probe targets, before any POST: what cannot be proven is never applied.
# One read-only SELECT per ADD COLUMN, CREATE TABLE and CREATE INDEX, built only
# from validated identifiers re-quoted with ", so no other text from the file
# reaches the probe. A bare identifier is folded to lower case first, as
# Postgres folds it: ALTER TABLE Client ADD Status creates client.status. Every ALTER TABLE / CREATE TABLE / CREATE INDEX in the file
# (and every ADD) must be matched, or the file is not a candidate.
dl_targets() ( # dl_targets <file> -> one SQL per line; rc 1 when incomplete. A
  # subshell, so nocasematch never outlives it.
  local txt id s m n=0 adds=0 occ t c kw='^(CONSTRAINT|PRIMARY|UNIQUE|FOREIGN|CHECK|EXCLUDE|COLUMN|IF|ON|ONLY)$'
  id='("[A-Za-z_][A-Za-z0-9_]*"|`[A-Za-z_][A-Za-z0-9_]*`|[A-Za-z_][A-Za-z0-9_]*)'; s='[[:space:]]+'
  local e='([[:space:](;]|$)' # the name ends here: never a schema prefix such as public."x"
  txt=$(sed 's/--.*$//' "$1" | tr '\n\t\r' '   ')
  occ=$(printf '%s\n' "$txt" | grep -oiE "ALTER${s}TABLE|CREATE${s}TABLE|CREATE${s}(UNIQUE${s})?INDEX" | wc -l)
  adds=$(printf '%s\n' "$txt" | grep -oiE "(^|[^A-Za-z0-9_\"\`])ADD${s}" | wc -l)
  unq() { case "$1" in \"*|\`*) printf '%s' "${1:1:${#1}-2}" ;; *) [[ "$1" =~ $kw ]] && return 1; printf '%s' "${1,,}" ;; esac; }
  local alt="ALTER${s}TABLE${s}(IF${s}EXISTS${s})?${id}${s}ADD${s}(COLUMN${s})?(IF${s}NOT${s}EXISTS${s})?${id}${e}"
  local ct="CREATE${s}TABLE${s}(IF${s}NOT${s}EXISTS${s})?${id}${e}"
  local ci="CREATE${s}(UNIQUE${s})?INDEX${s}(CONCURRENTLY${s})?(IF${s}NOT${s}EXISTS${s})?${id}${s}ON${s}(ONLY${s})?${id}${e}"
  shopt -s nocasematch
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [[ "$m" =~ ^$alt$ ]]; then t=$(unq "${BASH_REMATCH[2]}") && c=$(unq "${BASH_REMATCH[5]}") || return 1
      n=$((n+1)); printf 'SELECT "%s" FROM "%s" LIMIT 0\n' "$c" "$t"
    elif [[ "$m" =~ ^$ct$ ]]; then t=$(unq "${BASH_REMATCH[2]}") || return 1
      n=$((n+1)); printf 'SELECT 1 FROM "%s" LIMIT 0\n' "$t"
    elif [[ "$m" =~ ^$ci$ ]]; then unq "${BASH_REMATCH[4]}" >/dev/null && t=$(unq "${BASH_REMATCH[6]}") || return 1
      n=$((n+1)); printf 'SELECT 1 FROM "%s" LIMIT 0\n' "$t"
    fi
  done < <(printf '%s\n' "$txt" | grep -oiE "$alt|$ct|$ci")
  [ "$n" -gt 0 ] && [ "$n" = "$occ" ] && [ "$adds" = "$(printf '%s\n' "$txt" | grep -oiE "$alt" | wc -l)" ]
)
dl_targets "$TMP/m/$FILE" > "$TMP/targets.raw" && awk '!s[$0]++' "$TMP/targets.raw" > "$TMP/targets" \
  || OUT not-candidate "$FILE: no complete probe target set — not applied" 3

APP_BASE="${DATA_LANE_APP_BASE:-}"
[ -n "$APP_BASE" ] && [ -n "${MIGRATION_TOKEN:-}" ] \
  || OUT no-path "$FILE: no apply path (DATA_LANE_APP_BASE or MIGRATION_TOKEN unset in env/$PROJECT.env)" 5

PROVEN=0; STATUS=""
ST=$(dl_ledger_status "$PROJECT" "$FILE"); LRC=$?
case "$LRC" in
  0) case "$ST" in
       *" fp=$FP")
         case "$ST" in
           applied\ *|already-applied\ *) STATUS=${ST%% *}; PROVEN=1 ;;
           *) OUT not-candidate "$FILE: ledger holds '$ST' at this fp — no POST, no retry" 3 ;;
         esac ;;
     esac ;;
  1) ;;
  *) "$BIN/lane-alert.sh" --id "data-lane-hold:$PROJECT" --severity warn data-lane \
       "[$PROJECT] data-lane: migration ledger unreadable, $FILE for PR#$PR held unapplied until it answers" >/dev/null 2>&1 || true
     OUT busy "$FILE: ledger unknown — held, no POST" 75 ;;
esac

JOB=""
job_close() { # job_close <status> <verdict> <detail>
  [ -n "$JOB" ] || return 0
  job_update "$JOB" status="$1" stage=apply >/dev/null 2>&1 || true
  job_event "$JOB" apply "$2" "$3" >/dev/null 2>&1 || true
}
# The token rides in a 0600 header file, never on argv (ps) or in a log line.
( umask 077; printf 'Authorization: Bearer %s\n' "$MIGRATION_TOKEN" > "$TMP/auth" )
PF=$(dl_probe_file "$BUILD")

# probe — ONE read-only POST of the targets; rc 0 only when ok:true and every
# target sent came back ok:true under its exact string (a partial answer is a miss).
probe() {
  jq -n --arg f "$FILE" --arg h "$HEAD" --rawfile t "$TMP/targets" \
    '{file:$f,head_sha:$h,targets:($t|split("\n")|map(select(length>0)))}' > "$TMP/probe-body.json" || return 1
  curl -sS -m 60 -X POST -H @"$TMP/auth" -H "Content-Type: application/json" \
    --data-binary @"$TMP/probe-body.json" -o "$TMP/presp" -w '%{http_code}' \
    "$APP_BASE/api/internal/migrations/probe" > "$TMP/pcode" 2>"$TMP/pcurl.err"; PCURL_RC=$?
  PCODE=$(cat "$TMP/pcode" 2>/dev/null)
  [ "$PCURL_RC" = 0 ] && [ "${PCODE:0:1}" = 2 ] || return 1
  jq -e --slurpfile b "$TMP/probe-body.json" '$b[0].targets as $t
    | .ok==true and ([$t[] as $x | any(.results[]?; .target==$x and .ok==true)] | all)' "$TMP/presp" >/dev/null 2>&1
}
# probe_miss — the miss path: ledger row FIRST, then one alert, then rc 1.
probe_miss() {
  local resp note=""
  resp=$(head -c 200 "$TMP/presp" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
  ledger_put "failed probe $TAIL" || note=" The failure was NOT recorded in the ledger, so a re-run may probe again."
  "$BIN/lane-alert.sh" --id "data-lane:$PROJECT:$FILE:$FP" --severity warn data-lane \
    "[$PROJECT] data-lane: $FILE for PR#$PR (head $H12) answered $STATUS but the read-only probe did not find everything it adds: curl rc ${PCURL_RC:-?}, HTTP ${PCODE:-000}, response: ${resp:-<empty>}.$note Not retried." >/dev/null 2>&1 || true
  job_close parked FAILED "probe PR#$PR head=$H12 HTTP ${PCODE:-000}"
  OUT failed "$FILE: $STATUS but the probe failed (curl rc ${PCURL_RC:-?}, HTTP ${PCODE:-000}) — ledgered, alerted, not retried" 1
}
# write_probe_file <apply-response-file|ledger status> — atomic, so the resolver
# never reads a half-written file. No token or env value goes in it.
write_probe_file() {
  {
    echo "# Data lane probe: $FILE"; echo
    echo "project=$PROJECT"; echo "pr=$PR"; echo "head=$HEAD"; echo "fp=$FP"; echo
    echo '```sql'; cat "$TMP/m/$FILE"; echo '```'; echo
    echo "## Apply response"
    if [ -f "$1" ]; then head -c 2000 "$1"; echo; else echo "ledger: $1"; fi
    echo; echo "## Probe rows"
    sed 's/^/- ok  /' "$TMP/targets"
  } > "$PF.tmp.$$" && mv -f "$PF.tmp.$$" "$PF" || { rm -f "$PF.tmp.$$"; LOGLINE "$FILE: probe file write failed"; return 1; }
}
# dl_comment — one DATA-LANE-APPLIED: comment per FP, deduped by its hidden tag.
# An unreadable listing is UNKNOWN, never "absent": no POST, comment-pending 75.
dl_comment() {
  local tag="<!-- dl-fp:$FP -->" page=1 len
  while :; do
    gh_rest GET "repos/$SLUG/issues/$PR/comments" -F per_page=100 -F "page=$page" > "$TMP/cpage" 2>/dev/null \
      && len=$(jq -e 'if type=="array" then length else error end' "$TMP/cpage" 2>/dev/null) || return 75
    jq -e --arg t "$tag" 'any(.[]; (.body // "") | contains($t))' "$TMP/cpage" >/dev/null 2>&1 \
      && { CMSG="evidence comment already posted"; return 0; }
    [ "$len" -lt 100 ] && break
    [ "$page" -ge 10 ] && return 75
    page=$((page+1))
  done
  {
    echo "DATA-LANE-APPLIED: $FILE"
    echo "We applied this migration to production ahead of the merge, at head $H12."
    echo "A read-only probe then found every column and table it adds, so the only blocking finding is answered."
    echo
    sed 's/^/- ok  /' "$TMP/targets"
    echo "$tag"
  } > "$TMP/comment.md"
  gh_rest_comment "$SLUG" "$PR" "$TMP/comment.md" || return 75
  CMSG="evidence comment posted"
}
# NOFILE — the evidence file is the resolver's handoff, so no comment is posted
# without it: comment-pending 75, and the re-run probes again and rewrites it.
NOFILE() { OUT comment-pending "$FILE: $STATUS and probed, evidence file $PF not written, retried next run" 75; }
finish() { # the comment step, then the outcome word and ONE log line
  CMSG=""
  if dl_comment; then
    LOGLINE "$FILE PR#$PR $STATUS (head $H12, fp ${FP:0:12}, probed, $CMSG)"
    echo "$STATUS"; exit 0
  fi
  OUT comment-pending "$FILE: $STATUS and probed, evidence comment not posted, retried next run" 75
}

if [ "$PROVEN" = 1 ]; then # the ledger already says applied at this FP: no apply POST
  if ! grep -qxF "fp=$FP" "$PF" 2>/dev/null; then
    probe || probe_miss
    write_probe_file "$STATUS" || NOFILE
  fi
  finish
fi

if type job_open >/dev/null 2>&1; then
  JOB=$(job_open "$PROJECT" "$FILE" migration apply "data-lane/$PROJECT" 2>/dev/null); JRC=$?
  [ "$JRC" = 9 ] && case "$JOB" in REFUSED*) OUT busy "$FILE: job refused ($JOB)" 75 ;; esac
  [ "$JRC" = 0 ] || JOB=""
fi

jq -n --arg repo "$SLUG" --argjson pr "$PR" --arg h "$HEAD" --arg f "$FILE" --rawfile s "$TMP/m/$FILE" \
  '{mode:"pre-merge",repo:$repo,pr:$pr,head_sha:$h,file:$f,statements:$s,actor:"archie-data-lane"}' > "$TMP/body.json"
curl -sS -m 300 -X POST -H @"$TMP/auth" -H "Content-Type: application/json" \
  --data-binary @"$TMP/body.json" -o "$TMP/resp" -w '%{http_code}' \
  "$APP_BASE/api/internal/migrations/apply" > "$TMP/code" 2>"$TMP/curl.err"; CURL_RC=$?
CODE=$(cat "$TMP/code" 2>/dev/null)
STATUS=$(jq -r 'if .ok == true and (.status == "applied" or .status == "already-applied") then .status else empty end' "$TMP/resp" 2>/dev/null)

if [ "$CURL_RC" = 0 ] && [ "${CODE:0:1}" = 2 ] && [ -n "$STATUS" ]; then
  probe || probe_miss
  ledger_put "$STATUS $TAIL" || true
  job_close done APPLIED "PR#$PR head=$H12 $STATUS"
  write_probe_file "$TMP/resp" || NOFILE
  finish
fi

RESP=$(head -c 200 "$TMP/resp" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
NOTE=""; ledger_put "failed apply $TAIL" || NOTE=" The failure was NOT recorded in the ledger, so a re-run may POST again."
"$BIN/lane-alert.sh" --id "data-lane:$PROJECT:$FILE:$FP" --severity warn data-lane \
  "[$PROJECT] data-lane: pre-merge apply of $FILE for PR#$PR (head $H12) failed: curl rc $CURL_RC, HTTP ${CODE:-000}, response: ${RESP:-<empty>}.$NOTE Not retried." >/dev/null 2>&1 || true
job_close parked FAILED "PR#$PR head=$H12 HTTP ${CODE:-000}"
OUT failed "$FILE: apply failed (curl rc $CURL_RC, HTTP ${CODE:-000}) — ledgered, alerted, not retried" 1
