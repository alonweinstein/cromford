#!/bin/bash
# bin/lane-shims/_fence.sh — the act-time iron-law fence for the NON-claude
# build lanes (SDLC item 8, 2026-09-06).
#
# WHY IT EXISTS. bin/iron-law-guard.sh is a Claude Code PreToolUse hook, so it
# only fences claude sessions. bin/agent-call.sh runs EXECUTE on codex for project-4
# and project-1, with `--dangerously-bypass-approvals-and-sandbox`: on those two
# projects the five iron laws — merging a PR, pushing main, prisma pointed at a
# live DB, a raw client writing prod, a Vercel deploy/promote — are PROMPT-ONLY
# at the exact stage that writes code. This is the runner-agnostic half of that
# guard, and the reason the guard's own header says it is not a sandbox applies
# here twice over.
#
# HOW. bin/agent-call.sh prepends this directory to PATH for the fenced lanes.
# Every other file in here is a shim named after a binary the classifier knows;
# each one execs this script with its own name, and this script
#   1. rebuilds the command line from argv,
#   2. asks bin/iron-law-guard.sh — THE SAME CLASSIFIER, fed the same PreToolUse
#      payload shape the CLI sends — whether it is one of the five,
#   3. refuses (or, under LANE_FENCE=warn, warns) if it is,
#   4. otherwise execs the real binary further down PATH, untouched.
# One classifier, two mechanisms: a rule added for the claude lane is live on
# the codex lane the same hour, and the two cannot drift into different laws.
#
# MODES — env LANE_FENCE, DEFAULT 1:
#   1     deny. The shipped default: SDLC item 8 asks for a fence that refuses,
#         and a warn-only iron law is exactly the prose that already exists.
#   warn  classify, file the finding, print the reason, then RUN the command.
#   0     off — bin/agent-call.sh does not put this directory on PATH at all.
#   anything else is treated as 1 and alerts (a typo'd flag is still a fence).
#
# NOT A SANDBOX, and it sees LESS than the hook does. Honest limits:
#   * it only catches a binary invoked BY NAME through PATH. `/usr/bin/git push`,
#     a python subprocess, or a wrapper the session writes itself all walk past
#     it — which is why bin/lane-fence.sh also installs a pre-push hook, where
#     git itself does the calling.
#   * the harness's own merge lanes are invoked by path
#     (/root/harness/bin/merge-sweep.sh), and no PATH shim can intercept a path.
#   * a command reached only inside a `bash -c` string is seen only when a
#     shimmed name is the word that runs it.
# It is a guardrail against the reach-for-the-obvious-command failure, which is
# the one that actually happens.
#
# FAIL-OPEN, LOUDLY. Every internal failure — no classifier on the box, no jq,
# an unreadable verdict — runs the command and writes ONE ALERTS line (once per
# day per cause) saying the lane is unfenced. Same trade and same reason as the
# hook: an inert fence is visible within a tick, whereas a fence that fails
# closed takes every build lane on the box down with it.
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
GUARD="${IRON_LAW_GUARD:-$HARNESS/bin/iron-law-guard.sh}"
LANE="${HARNESS_LANE:-}"
MODE="${LANE_FENCE:-1}"
SELFDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || SELFDIR=""
[ -n "$SELFDIR" ] || SELFDIR="$HARNESS/bin/lane-shims"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || TZ=UTC printf '%(%Y-%m-%d %H:%M:%SZ)T\n' -1; }

# One line per cause per day. The claude-lane hook can afford an alert per
# blocked call because it only ever writes one when it BLOCKS; this runs in
# front of `npm` and `git` too, so an unfenceable box would otherwise flood
# ALERTS.log with the same sentence a thousand times before anyone read it.
ALERT() { # ALERT <cause-key> <message>
  local flag="$HARNESS/flags/alerted-lane-fence-$1-$(date -u +%Y%m%d 2>/dev/null)"
  mkdir -p "$HARNESS/flags" "$HARNESS/logs" 2>/dev/null
  [ -e "$flag" ] && return 0
  : > "$flag" 2>/dev/null
  echo "$(STAMP) [${HARNESS_LANE_PROJECT:-unknown}] $2" >> "$HARNESS/logs/ALERTS.log" 2>/dev/null
  return 0
}
LOUD() { # broken fence: deny nothing, but say so where somebody reads it
  ALERT "inert" "act-time lane fence INERT in lane ${LANE:-none}: $1 — commands in this session are running UNGUARDED (merge/push/deploy/prod-write are prompt-only here). Fix $SELFDIR/_fence.sh."
}

# argv -> a shell-ish command line for the classifier. QUOTING IS NOT COSMETIC:
# the classifier reads `gh issue create --body "pr merge"` as safe precisely
# because the quote sits where a space would have to be, so an argument that
# merely NAMES a blocked verb must arrive still quoted.
quote_cmd() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      '') a="''" ;;
      *[!A-Za-z0-9._/=:@%+,^-]*) a="'${a//\'/\'\\\'\'}'" ;;
    esac
    out="$out $a"
  done
  printf '%s' "${out# }"
}

# SECRETS NEVER REACH A LOG. The hook sees the command as the model TYPED it
# (a bare "$DATABASE_URL"); a shim sees argv AFTER the shell expanded it, so the
# literal connection string is sitting in the fence's hands. Both consumers are
# durable and one travels: bin/iron-law-guard.sh writes the command into
# logs/findings.log, which bin/rule-miner.sh bundles into a GitHub PR body, and
# record() writes it into state/lane-fence/. That is iron law 3, and a fence
# that leaks a prod password while refusing a prod write has done net harm.
# Redacted ONCE, before classify and record, so no unredacted path exists.
# The classifier still reads everything it decides on: it keys on the HOST of a
# URL (is_local_db), never on userinfo, and never on a password flag's value.
# The `-p` rule requires a space and a value glued to the flag (mysql's
# -pSECRET), so `--prod` and a bare `-p` are untouched — over-redacting a flag
# the classifier reads would turn a leak fix into a hole.
redact() {
  printf '%s' "$1" | sed -E '
    s#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]'"'"'"]*@#\1***@#g
    s/((^|[[:space:]])(-{1,2}(password|pass|pwd|token|secret|api-key)|PGPASSWORD|MYSQL_PWD)[= ])[^[:space:]'"'"'"]+/\1***/g
    s/((^|[[:space:]])-p)[^-=[:space:]'"'"'"][^[:space:]'"'"'"]*/\1***/g
  ' 2>/dev/null || printf '%s' "$1"
}

# classify <mechanism> <command> [cwd]
#   rc 2 -> DENY, and the classifier's own reason is printed on stdout.
#   rc 0 -> allow, or the fence could not decide (which is an allow, loudly).
classify() {
  local mech="$1" cmd="$2" cwd="${3:-$PWD}" payload reason rc
  [ -x "$GUARD" ] || { LOUD "the iron-law classifier is missing at $GUARD"; return 0; }
  command -v jq >/dev/null 2>&1 || { LOUD "jq is not on PATH, so no command can be classified"; return 0; }
  payload=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{session_id:"lane-fence",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' 2>/dev/null) \
    || { LOUD "the classifier payload could not be built by jq"; return 0; }
  # stdout to /dev/null, stderr captured: the guard says nothing on an allow and
  # writes its whole reason to stderr on a block, which is the text the model has
  # to read. Its exit code is the verdict — 2 and only 2 is a block.
  reason=$(printf '%s' "$payload" | env HARNESS="$HARNESS" IRON_LAW_MECHANISM="$mech" bash "$GUARD" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" = 2 ] || return 0
  printf '%s\n' "$reason"
  return 2
}

# The attempt is a FACT, so it lands in the ledger and not only in a log line.
# The classifier has already written the mined finding (logs/findings.log); this
# adds the per-build rollup the console and a post-mortem can read: one
# `lane_fence` artifact row per job (PRIMARY KEY job_id+kind, so it upserts),
# ref = the count, detail = which verbs, which lane, which mode. The file under
# state/lane-fence/ is the documented fallback and the source of the count, for
# the fly builders and any box whose worker call fails.
record() { # record <verb> <mode> <command>
  local verb="$1" mode="$2" cmd="$3" key f n verbs detail
  key=$(printf '%s' "${JOB_ID:-${HARNESS_TICKET:-unknown}}" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$HARNESS/state/lane-fence" 2>/dev/null || return 0
  f="$HARNESS/state/lane-fence/$key.log"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(STAMP)" "${LANE:-none}" "$mode" "$verb" \
    "$(printf '%s' "$cmd" | cut -c1-200)" >> "$f" 2>/dev/null
  [ -n "${JOB_ID:-}" ] && [ -r "$HARNESS/bin/jobs-client.sh" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); case "$n" in ''|*[!0-9]*) return 0 ;; esac
  verbs=$(cut -f4 "$f" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
  detail=$(jq -nc --arg l "${LANE:-}" --arg p "${HARNESS_LANE_PROJECT:-}" --arg m "$mode" \
    --arg v "$verbs" --arg f "$f" --argjson n "$n" \
    '{blocked:$n,lane:$l,project:$p,mode:$m,verbs:($v|split(",")),fallback_file:$f}' 2>/dev/null) || return 0
  # Bounded and fail-open: the verdict is already decided and printed, so a slow
  # or unreachable worker must cost the refusal nothing.
  timeout 25 bash -c '. "$1" 2>/dev/null; job_artifact_put lane_fence "$2" "$3"' _ \
    "$HARNESS/bin/jobs-client.sh" "$n blocked by the lane fence ($verbs)" "$detail" >/dev/null 2>&1
  return 0
}

case "${1:-}" in
  --classify)   # used by bin/lane-fence.sh's pre-push hook: one verdict, no exec
    shift
    [ "$#" -ge 2 ] || { echo "usage: _fence.sh --classify <mechanism> <command> [cwd]" >&2; exit 64; }
    classify "$1" "$2" "${3:-$PWD}"; exit $?
    ;;
  --shim)
    shift
    [ "$#" -ge 1 ] || { echo "usage: _fence.sh --shim <name> [args...]" >&2; exit 64; }
    NAME="$1"; shift
    ;;
  *)
    echo "usage: _fence.sh --shim <name> [args...] | --classify <mechanism> <command> [cwd]" >&2
    exit 64
    ;;
esac

# The real binary, looked up with THIS directory removed from PATH so the lookup
# cannot find the shim again. PATH itself is left alone for the child: a nested
# call from inside the tool is still fenced.
# Looped, because ${a//x/y} does not re-scan what it just wrote: two ADJACENT
# copies of this dir (a fenced session that composes PATH again) leave one
# behind on a single pass, and the lookup below then finds the shim.
CLEAN=":$PATH:"
while :; do
  PREV="$CLEAN"; CLEAN="${CLEAN//:$SELFDIR:/:}"
  [ "$CLEAN" = "$PREV" ] && break
done
CLEAN="${CLEAN#:}"; CLEAN="${CLEAN%:}"
REAL=$(PATH="$CLEAN" command -v "$NAME" 2>/dev/null)
if [ "$REAL" = "$SELFDIR/$NAME" ]; then
  LOUD "the shim for $NAME resolves back to itself, so it cannot reach the real binary"
  printf '%s: the harness lane fence could not resolve the real binary\n' "$NAME" >&2
  exit 127
fi
[ -n "$REAL" ] || { printf '%s: command not found\n' "$NAME" >&2; exit 127; }
run() { exec "$REAL" "$@"; }

# Not a fenced lane at all (no marker) -> this shim has no opinion, exactly like
# the hook's own lane fence. A settings/PATH leak into another session must be
# inert rather than authoritative.
[ -n "$LANE" ] || run "$@"
case "$MODE" in
  0) run "$@" ;;
  1|warn) ;;
  *) ALERT "mode" "act-time lane fence: LANE_FENCE=$MODE is not a value this fence knows — treating it as 1 (deny). Set 1, warn or 0 in env/global.env."; MODE=1 ;;
esac

CMD=$(redact "$(quote_cmd "$NAME" "$@")")
# The classifier's OWN fast path, copied verbatim: a command naming none of these
# cannot match any of its five rules, and this shim also stands in front of npm,
# pnpm and yarn (the wrappers that reach prisma and vercel), where that is the
# overwhelming majority of calls. Two forks saved per `npm run build`.
case " $CMD " in
  *gh*|*git*|*prisma*|*psql*|*mysql*|*mariadb*|*mongo*|*vercel*|*vc\ *|*merge-*) ;;
  *) run "$@" ;;
esac

REASON=$(classify "PATH-shim($NAME)" "$CMD"); RC=$?
[ "$RC" = 2 ] || run "$@"

printf '%s\n' "$REASON" >&2
if [ "$MODE" = warn ]; then
  echo "LANE_FENCE=warn on this box: the command above was RUN ANYWAY and the attempt was filed. Set LANE_FENCE=1 to refuse it." >&2
  record "$NAME" warn "$CMD"
  run "$@"
fi
record "$NAME" deny "$CMD"
exit 2
