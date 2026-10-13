#!/bin/bash
# bin/archie-learn.sh — BH-4066 (BH-3966.5): Archie's learning loop. The only
# way a skill changes on the hub, the skill-usage ledger, and the weekly
# learning report.
#
#   archie-learn.sh edit    <skill> <new SKILL.md> [--case <dir>]... --why <text>
#   archie-learn.sh correct <skill> <new SKILL.md> --case <dir> [--case <dir>]... --why <text>
#   archie-learn.sh correct facts --why <text>
#   archie-learn.sh propose <name> <dir>        <dir> = SKILL.md + replays/ (2+ cases)
#   archie-learn.sh adopt   <name>              only after the operator said yes
#   archie-learn.sh unused                      UNUSED <skill> last_used=<iso|never>
#   archie-learn.sh [report]                    the archie-learn hub lane, daily
#
# EDIT / CORRECT. The new SKILL.md (frontmatter `name: <skill>`) and each
# --case dir (input.md, expected, recorded.txt; the expected word must be in
# the new SKILL.md's `verdicts:`) are checked first; any refusal is rc 2, one
# line, and no write. `correct` needs at least one --case and logs a
# `correction` line before its outcome (the weekly overrule count reads it).
# The current skill (the learned copy if there is one, else the checkout's,
# with its replays/) is staged in a temp dir, SKILL.md replaced, the cases
# appended as the next free NN-<slug>, and bin/archie-skill-replay.sh runs
# EVERY case of the skill on the stage. The model is $ARCHIE_REPLAY_MODEL_CMD,
# default bin/archie-replay-model.sh (stage archie-replay through agent-call).
#   rc != 0  `rejected`, the FAIL lines printed and logged, rc 1, nothing moves.
#   rc 0     promote: the new learned dir is built beside the old one, the live
#            /root/orchestrator/.claude/skills/<skill>/SKILL.md installed
#            through a temp file + mv, the `.archie-learned` marker touched
#            (bin/sync-skills.sh then never overwrites it), the learned dir
#            swapped in. Only then: the diff to stdout and learned/history/,
#            and the `promoted` line. Any failed step restores the old live
#            SKILL.md and marker and logs `promote-failed`, rc 1.
# `correct facts` is log-only: facts.md is plain text Archie edits himself; the
# ticket gates skill edits, not facts.
# One edit at a time: flock -n locks/archie-learn.lock; held = rc 3, no wait.
#
# PROPOSE / ADOPT. A proposal runs the same gate on a staged copy and, green,
# lands in learned/proposals/<name>/ only. It is never installed. `adopt`
# re-runs the gate on the proposal and installs it the way a promote does.
#
# UNUSED. Updates state/archie-learn/skill-usage.tsv (skill, first_seen,
# last_used) from the orchestrator's Claude Code transcripts: an invocation is
# an assistant `tool_use` named `Skill`, its `input.skill` the skill. Every live
# skill gets first_seen = now the first time it is seen. A skill is flagged when
# first_seen and last_used (or never) are both older than
# ARCHIE_SKILL_UNUSED_DAYS (settings row, default 30). Flagging deletes nothing.
# It shares the report's lock (locks/archie-learning.lock), so it never
# rewrites skill-usage.tsv beside a running report: held = rc 3.
#
# REPORT, in this order: lane_gate_or_exit / lane_env_apply archie-learn;
# ARCHIE_LEARN_ENABLED=0 exits; flock -n locks/archie-learning.lock (held =
# skip); the whole run under timeout 600 (D21); the usage update; W = the last
# closed ISO week. state/archie-learn/weekly/<W>.sent exists = done, exit. Else
# the report (rework rate, overrule rate, cost per check, skill counts, factory
# fixes shipped from bin/archie-fm-improve.sh section (BH-4587), prune
# candidates, skills learned here) is written to weekly/<W>.md, then ONE Telegram
# message from Archie (bin/archie-tg-send.sh, BH-4779; akey archie-learning:<W>),
# then <W>.sent only on send rc 0. A failed send is retried by the next daily run. A number that cannot be read,
# or a zero denominator, is `not measured (<why>)`, never 0.
#
# Logs: logs/archie-learning.log, one line per event:
#   <ts> correction <skill|facts> why=<text>
#   <ts> promoted|rejected|promote-failed <skill> kind=<edit|correction> …
#   <ts> proposed|proposal-rejected|adopted|adopt-rejected <name> …
#   <ts> report <W> sent|not sent (rc=<n>)
# OFF: ARCHIE_LEARN_ENABLED=0 (report), flags/lane-off-archie-learn,
# bin/harness-ctl.sh off archie-learn. Registry: catalog/lanes.d/
# archie-learn.json. Note: docs/notes/2026-10-04-BH-4066-archie-learning.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
ORC="${ARCHIE_ORC_DIR:-/root/orchestrator}"
MODE="${1:-report}"
[ $# -gt 0 ] && shift
if [ "$MODE" = report ] && [ "${ARCHIE_LEARN_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  ARCHIE_LEARN_TIMED=1 exec timeout 600 bash "$0" report "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_LEARN_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_LEARN_FIXTURE"
fi
command -v jq >/dev/null 2>&1 || { echo "archie-learn: jq is required" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOWISO=$(iso "$NOW")
LOG="$H/logs/archie-learning.log"
ST="$H/state/archie-learn"
SKSRC="${ARCHIE_SKILLS_SRC:-${HARNESS_CHECKOUT:-/root/harness-checkout}/orchestrator/skills}"
LIVE="$ORC/.claude/skills"
LSK="$ORC/learned/skills"
PROP="$ORC/learned/proposals"
log() { mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$NOWISO" "$*" >> "$LOG"; }
refuse() { echo "archie-learn: $*" >&2; exit 2; }
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-learn

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

# frontmatter <SKILL.md>: the lines between the first two `---` lines.
frontmatter() { awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f && /^---[[:space:]]*$/ {exit} f' "$1" 2>/dev/null | tr -d '\r'; }
vocab_of() { frontmatter "$1" | sed -n 's/^verdicts:[[:space:]]*//p' | head -1 | tr '|' '\n' | tr -d ' \t' | grep -v '^$' | tr '\n' ' '; }
verdict_of() { tr -d '\r' < "$1" | sed -n 's/^VERDICT:[[:space:]]*//p' | tail -1 | tr -d '[:space:]' | tr 'A-Z' 'a-z'; }
ncases() { local n=0 c; for c in "$1"/replays/*/; do [ -d "$c" ] && n=$((n + 1)); done; echo "$n"; }
one_line() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# check_skill_md <file> <name>: readable, non-empty, `name: <name>` in its frontmatter.
check_skill_md() {
  [ -r "$1" ] && [ -s "$1" ] || refuse "$1 is not a readable, non-empty SKILL.md"
  frontmatter "$1" | grep -qE "^name: *$2 *\$" || refuse "$1 has no 'name: $2' in its frontmatter"
}
# check_case <dir> <vocab>
check_case() {
  local f e
  [ -d "$1" ] || refuse "case $1 is not a directory"
  for f in input.md expected recorded.txt; do [ -s "$1/$f" ] || refuse "case $1 has no $f"; done
  e=$(verdict_of "$1/expected")
  [ -n "$e" ] || refuse "case $1: expected has no VERDICT: line"
  case " $2" in *" $e "*) ;; *) refuse "case $1 expects '$e', which is not in verdicts: $2" ;; esac
}
check_why() {
  [ -n "${1//[[:space:]]/}" ] || refuse "--why is required: say what the operator corrected or why the skill changes"
  [ "${#1}" -le 300 ] || refuse "--why is ${#1} chars; keep it to 300"
}
valid_name() { [[ $1 =~ ^[a-z0-9-]+$ ]] && [ "$1" != facts ]; }

take_lock() { # take_lock <name>: flock -n, never a wait
  mkdir -p "$H/locks" 2>/dev/null
  exec 9>"$H/locks/$1.lock" || { echo "archie-learn: cannot open locks/$1.lock" >&2; exit 3; }
  flock -n 9 || { echo "archie-learn: another $1 run is going, try again" >&2; exit 3; }
}

# gate <stage-root> <skill> <out-file>: every replay of the skill, rc of the runner.
gate() {
  ARCHIE_REPLAY_MODEL_CMD="${ARCHIE_REPLAY_MODEL_CMD:-$SELF/archie-replay-model.sh}" \
    "$SELF/archie-skill-replay.sh" --root "$1" --skill "$2" > "$3" 2>&1
}

# recover_learned <name>: a promote killed between its two learned-dir mvs
# leaves the only learned copy (with the operator's correction cases) at .<name>.old.
# Put it back before anything resolves the learned copy or clears .old.
recover_learned() {
  [ -d "$LSK/.$1.old" ] && [ ! -e "$LSK/$1" ] && mv "$LSK/.$1.old" "$LSK/$1"
  return 0
}

# install <name> <staged skill dir>: the learned dir and the live SKILL.md,
# marker included. rc 1 = nothing changed (the old live file and marker are
# restored).
install_skill() {
  local n="$1" stg="$2" ldir="$LIVE/$1" bak="" hadmk=0 hadlive=0
  mkdir -p "$LSK" "$ORC/learned/history" "$ldir" 2>/dev/null && [ -d "$LSK" ] && [ -d "$ldir" ] || return 1
  recover_learned "$n"
  rm -rf "${LSK:?}/.$n.new" "${LSK:?}/.$n.old"
  cp -r "$stg" "$LSK/.$n.new" || { rm -rf "${LSK:?}/.$n.new"; return 1; }
  [ -f "$ldir/.archie-learned" ] && hadmk=1
  if [ -f "$ldir/SKILL.md" ]; then
    hadlive=1; bak="$ldir/.SKILL.md.bak"
    cp -p "$ldir/SKILL.md" "$bak" || { rm -rf "${LSK:?}/.$n.new"; return 1; }
  fi
  restore() {
    if [ "$hadlive" = 1 ]; then mv -f "$bak" "$ldir/SKILL.md"; else rm -f "$ldir/SKILL.md"; fi
    [ "$hadmk" = 1 ] || rm -f "$ldir/.archie-learned"
    rm -rf "${LSK:?}/.$n.new" "$ldir/.SKILL.md.tmp"
    [ -d "$LSK/.$n.old" ] && [ ! -e "$LSK/$n" ] && mv "$LSK/.$n.old" "$LSK/$n"
    return 1
  }
  cp "$stg/SKILL.md" "$ldir/.SKILL.md.tmp" && mv -f "$ldir/.SKILL.md.tmp" "$ldir/SKILL.md" || { restore; return 1; }
  touch "$ldir/.archie-learned" || { restore; return 1; }
  if [ -d "$LSK/$n" ]; then mv "$LSK/$n" "$LSK/.$n.old" || { restore; return 1; }; fi
  mv "$LSK/.$n.new" "$LSK/$n" || { restore; return 1; }
  rm -rf "${LSK:?}/.$n.old" "$bak"
  return 0
}

# ═════ edit / correct ════════════════════════════════════════════════════════
edit() {
  local kind="$1"; shift
  local skill="${1:-}" new="${2:-}" why="" have=0 c base vocab old
  local -a cases=()
  if [ "$kind" = correction ] && [ "$skill" = facts ]; then
    shift
    while [ $# -gt 0 ]; do
      case "$1" in --why) [ $# -ge 2 ] || refuse "--why needs a value"; why="$2"; have=1; shift 2 ;; *) refuse "correct facts takes only --why" ;; esac
    done
    [ "$have" = 1 ] || refuse "--why is required"
    check_why "$why"
    log "correction facts why=$(one_line "$why")"
    echo "Logged the correction to facts. Edit $ORC/facts.md yourself if you haven't."
    return 0
  fi
  [ $# -ge 2 ] || refuse "usage: archie-learn.sh $([ "$kind" = correction ] && echo correct || echo edit) <skill> <new SKILL.md> [--case <dir>]... --why <text>"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --case) [ $# -ge 2 ] || refuse "--case needs a dir"; cases+=("$2"); shift 2 ;;
      --why)  [ $# -ge 2 ] || refuse "--why needs a value"; why="$2"; have=1; shift 2 ;;
      *) refuse "unknown argument $1" ;;
    esac
  done
  valid_name "$skill" || refuse "'$skill' is not a skill name (a-z, 0-9, -)"
  if [ -d "$LSK/$skill/replays" ]; then base="$LSK/$skill"
  elif [ -d "$SKSRC/$skill/replays" ]; then base="$SKSRC/$skill"
  elif [ -f "$LIVE/$skill/SKILL.md" ] || [ -f "$SKSRC/$skill/SKILL.md" ]; then
    refuse "$skill has no replays to gate on (no learned copy and none in $SKSRC); nothing changed"
  else refuse "no skill $skill; for a new skill use propose"; fi
  [ "$have" = 1 ] || refuse "--why is required"
  check_why "$why"
  [ "$kind" = correction ] && [ ${#cases[@]} -eq 0 ] && refuse "correct needs at least one --case: the correction as a replay"
  check_skill_md "$new" "$skill"
  vocab=$(vocab_of "$new")
  [ -n "$vocab" ] || refuse "$new has no verdicts: line"
  for c in "${cases[@]}"; do check_case "$c" "$vocab"; done

  take_lock archie-learn
  # Under the lock, so a running promote's .old is never taken from it.
  recover_learned "$skill"
  [ -d "$LSK/$skill/replays" ] && base="$LSK/$skill"
  local stg out grc nn slug fails rc=0
  stg=$(mktemp -d "${TMPDIR:-/tmp}/archie-learn.XXXXXX") || { echo "archie-learn: no temp dir" >&2; exit 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$stg'" EXIT
  old="$base/SKILL.md"
  cp -r "$base" "$stg/$skill" && cp "$new" "$stg/$skill/SKILL.md" || { echo "archie-learn: staging failed" >&2; exit 1; }
  for c in "${cases[@]}"; do
    nn=$(find "$stg/$skill/replays" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p' | sort -n | tail -1)
    nn=$(( 10#${nn:-0} + 1 ))
    slug=$(basename "$c" | tr 'A-Z' 'a-z' | sed -E 's/^[0-9]+-//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    cp -r "$c" "$stg/$skill/replays/$(printf '%02d' "$nn")-${slug:-case}" || { echo "archie-learn: staging failed" >&2; exit 1; }
  done
  [ "$kind" = correction ] && log "correction $skill why=$(one_line "$why")"
  out="$stg/gate.out"
  gate "$stg" "$skill" "$out"; grc=$?
  # >>> replay gate
  if [ "$grc" != 0 ]; then
    fails=$(grep '^FAIL ' "$out" | paste -sd ';' -)
    log "rejected $skill kind=$kind why=$(one_line "$why") failed=${fails:-runner rc $grc}"
    grep '^FAIL ' "$out"
    echo "Rejected: the edit to $skill failed its replays, so the old skill stays live."
    return 1
  fi
  # <<< replay gate
  local d
  d=$(diff -u --label "a/$skill/SKILL.md" --label "b/$skill/SKILL.md" "$old" "$stg/$skill/SKILL.md")
  if ! install_skill "$skill" "$stg/$skill"; then
    log "promote-failed $skill kind=$kind why=$(one_line "$why")"
    echo "archie-learn: the replays passed but installing $skill failed; the old skill stays live" >&2
    return 1
  fi
  printf '%s\n' "$d" > "$ORC/learned/history/$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ)-$skill.diff" 2>/dev/null || rc=1
  log "promoted $skill kind=$kind cases=+${#cases[@]} why=$(one_line "$why")"
  printf '%s\n' "$d"
  echo "Promoted $skill: all $(ncases "$LSK/$skill") replays passed."
  [ "$rc" = 0 ] || echo "archie-learn: the history diff could not be written" >&2
  return 0
}

# ═════ propose / adopt ═══════════════════════════════════════════════════════
known_skill() { [ -e "$SKSRC/$1" ] || [ -e "$LSK/$1" ] || [ -e "$LIVE/$1" ]; }

propose() {
  local name="${1:-}" src="${2:-}" stg grc desc
  [ $# -eq 2 ] || refuse "usage: archie-learn.sh propose <name> <dir>"
  valid_name "$name" || refuse "'$name' is not a skill name (a-z, 0-9, -)"
  known_skill "$name" && refuse "$name already exists; change it with edit"
  [ -d "$src" ] || refuse "$src is not a directory"
  check_skill_md "$src/SKILL.md" "$name"
  take_lock archie-learn
  stg=$(mktemp -d "${TMPDIR:-/tmp}/archie-learn.XXXXXX") || exit 1
  # shellcheck disable=SC2064
  trap "rm -rf '$stg'" EXIT
  cp -r "$src" "$stg/$name" || exit 1
  gate "$stg" "$name" "$stg/gate.out"; grc=$?
  if [ "$grc" != 0 ]; then
    log "proposal-rejected $name failed=$(grep '^FAIL ' "$stg/gate.out" | paste -sd ';' -)"
    grep '^FAIL ' "$stg/gate.out"
    echo "Not proposing $name: its own replays failed."
    return 1
  fi
  mkdir -p "$PROP" && rm -rf "${PROP:?}/.$name.new" && cp -r "$stg/$name" "$PROP/.$name.new" \
    && rm -rf "${PROP:?}/$name" && mv "$PROP/.$name.new" "$PROP/$name" \
    || { echo "archie-learn: could not stage the proposal" >&2; return 1; }
  log "proposed $name cases=$(ncases "$PROP/$name")"
  desc=$(frontmatter "$PROP/$name/SKILL.md" | sed -n 's/^description:[[:space:]]*//p' | head -1)
  echo "Proposed skill $name: $desc Say yes and I'll adopt it."
}

adopt() {
  local name="${1:-}" stg grc
  [ $# -eq 1 ] || refuse "usage: archie-learn.sh adopt <name>"
  valid_name "$name" || refuse "'$name' is not a skill name (a-z, 0-9, -)"
  [ -f "$PROP/$name/SKILL.md" ] || refuse "no proposal $name; propose it first"
  [ -e "$LIVE/$name" ] && refuse "$name is already live; change it with edit"
  take_lock archie-learn
  stg=$(mktemp -d "${TMPDIR:-/tmp}/archie-learn.XXXXXX") || exit 1
  # shellcheck disable=SC2064
  trap "rm -rf '$stg'" EXIT
  cp -r "$PROP/$name" "$stg/$name" || exit 1
  gate "$stg" "$name" "$stg/gate.out"; grc=$?
  if [ "$grc" != 0 ]; then
    log "adopt-rejected $name failed=$(grep '^FAIL ' "$stg/gate.out" | paste -sd ';' -)"
    grep '^FAIL ' "$stg/gate.out"
    echo "Not adopting $name: its replays failed this time. The proposal stays."
    return 1
  fi
  if ! install_skill "$name" "$stg/$name"; then
    log "promote-failed $name kind=adopt"
    echo "archie-learn: installing $name failed; nothing is live" >&2
    return 1
  fi
  rm -rf "${PROP:?}/$name"
  log "adopted $name cases=$(ncases "$LSK/$name")"
  echo "Adopted $name. It's live for the next turn."
}

# ═════ unused: the skill-usage ledger ════════════════════════════════════════
# usage_update: sets UNUSED_LIST (one `UNUSED …` line per flag) and PARSED.
usage_update() {
  local days tdir ul since cut f s fs lu line t
  days=$(knob_int ARCHIE_SKILL_UNUSED_DAYS "${ARCHIE_SKILL_UNUSED_DAYS:-30}" 30 1 365)
  tdir="${ARCHIE_TRANSCRIPTS_DIR:-/root/.claude/projects/-root-orchestrator}"
  ul="$ST/skill-usage.tsv"
  mkdir -p "$ST" 2>/dev/null
  declare -A FS=() LU=()
  if [ -f "$ul" ]; then
    while IFS=$'\t' read -r s fs lu; do
      [[ $s =~ ^[a-z0-9:_-]+$ ]] && [[ $fs =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || continue
      FS[$s]=$fs; LU[$s]=$lu
    done < "$ul"
  fi
  for f in "$LIVE"/*/SKILL.md; do
    [ -f "$f" ] || continue
    s=$(basename "$(dirname "$f")")
    [ -n "${FS[$s]:-}" ] || { FS[$s]=$NOWISO; LU[$s]=""; }
  done
  # Bounded: only transcripts touched inside the window are read (D21), and a
  # cheap grep keeps jq off the lines that cannot be a Skill call.
  PARSED=0
  since="@$((NOW - (days + 1) * 86400))"
  while IFS=$'\t' read -r t s; do
    [ -n "$s" ] && [ -n "${FS[$s]+x}" ] || continue
    PARSED=$((PARSED + 1))
    [[ $t > ${LU[$s]:-} ]] && LU[$s]=$t
  done < <(
    [ -d "$tdir" ] && find "$tdir" -maxdepth 1 -name '*.jsonl' -type f -newermt "$since" -print0 2>/dev/null \
      | xargs -0 -r grep -h '"name":"Skill"' 2>/dev/null \
      | jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | (.timestamp // "") as $t
          | select($t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"))
          | .message.content[]? | select(type == "object" and .type == "tool_use" and .name == "Skill")
          | [($t[0:19] + "Z"), (.input.skill // "" | tostring)] | @tsv' 2>/dev/null
  )
  {
    for s in "${!FS[@]}"; do printf '%s\t%s\t%s\n' "$s" "${FS[$s]}" "${LU[$s]:-}"; done | sort
  } > "$ul.tmp" && mv -f "$ul.tmp" "$ul" || log "warn: could not write $ul"
  cut=$(iso $((NOW - days * 86400)))
  UNUSED_LIST=""
  for s in $(printf '%s\n' "${!FS[@]}" | sort); do
    [ -f "$LIVE/$s/SKILL.md" ] || continue
    [[ ${FS[$s]} > $cut ]] && continue
    lu=${LU[$s]:-}
    [ -n "$lu" ] && [[ $lu > $cut ]] && continue
    line="UNUSED $s last_used=${lu:-never}"
    UNUSED_LIST="${UNUSED_LIST:+$UNUSED_LIST$'\n'}$line"
  done
  UNUSED_DAYS=$days
}

unused() {
  take_lock archie-learning
  usage_update
  [ -n "$UNUSED_LIST" ] && printf '%s\n' "$UNUSED_LIST"
  return 0
}

# ═════ report ════════════════════════════════════════════════════════════════
# rework_latest: `<week>\t<rate>` of the last cromford row, rc 1 unreadable.
rework_latest() {
  python3 - "$H/logs/outcome-rework-rollup.csv" <<'PY' 2>/dev/null
import csv, re, sys
try:
    rows = list(csv.reader(open(sys.argv[1], newline="")))
except OSError:
    sys.exit(1)
if not rows or not {"week", "project", "rate"} <= set(rows[0]):
    sys.exit(1)
h = rows[0]
last = None
for r in rows[1:]:
    if len(r) == len(h) and r[h.index("project")] == "cromford":
        last = r
if last is None or not re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", last[h.index("rate")].strip()):
    sys.exit(1)
print("%s\t%s" % (last[h.index("week")], last[h.index("rate")].strip()))
PY
}

# spend <query> <field>: the number, rc 1 when the worker did not answer it.
spend() {
  local r
  command -v _jobs_req >/dev/null 2>&1 || return 1
  r=$(_jobs_req GET "/api/metrics/llm-spend?$1") || return 1
  jq -er --arg f "$2" '.[$f] | numbers' <<<"$r" 2>/dev/null
}

# in_week <file> <regex>: the lines of <file> stamped inside W that match.
in_week() { awk -v a="$WS_ISO" -v b="$WE_ISO" -v re="$2" '$1 >= a && $1 <= b && $0 ~ re' "$1" 2>/dev/null; }

compose_report() {
  local rw wk rate corr calls usd checks prom rej prop adop prune div s fx rc
  printf 'Archie learning, week %s (%s to %s)\n' "$W" "${WS_ISO:0:10}" "${WE_ISO:0:10}"
  if rw=$(rework_latest) && [ -n "$rw" ]; then
    IFS=$'\t' read -r wk rate <<<"$rw"
    printf 'Rework rate %s%% (cromford, week %s)\n' "$rate" "$wk"
  else
    echo "Rework rate not measured (logs/outcome-rework-rollup.csv has no cromford row)"
  fi
  corr=$(in_week "$LOG" '^[^ ]+ correction ' | wc -l | tr -d ' ')
  if ! calls=$(spend "lane=orc-monitor&since=$WS_ISO&until=$WE_ISO" calls); then
    echo "Overrule rate not measured (the spend ledger did not answer for orc-monitor turns)"
  elif awk -v c="$calls" 'BEGIN { exit !(c + 0 > 0) }'; then
    printf 'Overrule rate %s%% (%s of %s turns)\n' "$(awk -v a="$corr" -v b="$calls" 'BEGIN { printf "%.0f", a * 100 / b }')" "$corr" "$calls"
  else
    echo "Overrule rate not measured (no answered turns this week; $corr corrections)"
  fi
  checks=$(in_week "$H/logs/archie.log" '^[^ ]+ due=[0-9]+ checked=[0-9]+' | sed -n 's/.* checked=\([0-9][0-9]*\).*/\1/p' | awk '{ s += $1 } END { print s + 0 }')
  if ! usd=$(spend "lane=archie&stage=archie&since=$WS_ISO&until=$WE_ISO" usd); then
    echo "Cost per check not measured (the spend ledger did not answer for the archie lane)"
  elif [ "$checks" -gt 0 ]; then
    printf 'Cost per check $%s (%s checks)\n' "$(awk -v u="$usd" -v c="$checks" 'BEGIN { v = u / c; printf (v < 0.01 && v > 0 ? "%.4f" : "%.2f"), v }')" "$checks"
  else
    echo "Cost per check not measured (no initiative checks this week)"
  fi
  prom=$(in_week "$LOG" '^[^ ]+ promoted ' | wc -l | tr -d ' ')
  rej=$(in_week "$LOG" '^[^ ]+ rejected ' | wc -l | tr -d ' ')
  prop=$(in_week "$LOG" '^[^ ]+ proposed ' | wc -l | tr -d ' ')
  adop=$(in_week "$LOG" '^[^ ]+ adopted ' | wc -l | tr -d ' ')
  printf 'Skills: %s promoted, %s rejected, %s proposed, %s adopted\n' "$prom" "$rej" "$prop" "$adop"
  fx=$(timeout 120 "$H/bin/archie-fm-improve.sh" section "$WS_ISO" "$WE_ISO" 2>/dev/null); rc=$?
  { [ "$rc" = 0 ] && [ -n "$fx" ] && printf '%s\n' "$fx"; } || printf 'Factory fixes shipped: not measured (bin/archie-fm-improve.sh section rc=%s)\n' "$rc"
  prune=$(printf '%s\n' "$UNUSED_LIST" | awk '/^UNUSED /{print $2}' | paste -sd ' ' - | sed 's/ /, /g')
  printf 'Unused %s+ days, prune candidates: %s\n' "$UNUSED_DAYS" "${prune:-none}"
  div=""
  # A marked skill whose live SKILL.md the repo already carries byte for byte
  # was upstreamed; bin/sync-skills.sh clears its marker on the next deploy.
  for s in "$LIVE"/*/.archie-learned; do
    [ -f "$s" ] || continue
    s=$(basename "$(dirname "$s")")
    cmp -s "$LIVE/$s/SKILL.md" "$SKSRC/$s/SKILL.md" && continue
    div="${div:+$div, }$s"
  done
  printf 'Learned here, not in the repo yet: %s\n' "${div:-none}"
  printf 'Skill usage: %s invocations parsed from the last %s days of transcripts\n' "$PARSED" "$((UNUSED_DAYS + 1))"
}

deliver() { # deliver <report text>: one Telegram message from Archie (BH-4779), rc of archie-tg-send.sh
  "$H/bin/archie-tg-send.sh" "archie-learning:$W" "$1" >/dev/null 2>&1
}

report() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-learn
  case "${ARCHIE_LEARN_ENABLED:-1}" in
    0) exit 0 ;;
    1) ;;
    *) log "warn: ARCHIE_LEARN_ENABLED=${ARCHIE_LEARN_ENABLED} is not 0 or 1; using the default 1" ;;
  esac
  mkdir -p "$H/locks" 2>/dev/null
  exec 9>"$H/locks/archie-learning.lock" || exit 0
  flock -n 9 || exit 0
  usage_update
  # W = the last closed ISO week: Monday 00:00Z of this week, minus seven days.
  local mon text rc
  mon=$(( NOW - NOW % 86400 - ($(date -u -d "@$NOW" +%u) - 1) * 86400 ))
  W=$(date -u -d "@$((mon - 7 * 86400))" +%G-W%V)
  WS_ISO=$(iso $((mon - 7 * 86400))); WE_ISO=$(iso $((mon - 1)))
  mkdir -p "$ST/weekly" 2>/dev/null
  [ -f "$ST/weekly/$W.sent" ] && exit 0
  text=$(compose_report)
  # Written BEFORE the send: what was reported survives a lost send.
  printf '%s\n' "$text" > "$ST/weekly/.$W.tmp" && mv -f "$ST/weekly/.$W.tmp" "$ST/weekly/$W.md" \
    || { log "report $W not sent (the report file could not be written)"; exit 0; }
  deliver "$text"; rc=$?
  if [ "$rc" = 0 ]; then
    : > "$ST/weekly/$W.sent"
    log "report $W sent"
  else
    log "report $W not sent (rc=$rc); the next run retries"
  fi
  exit 0
}

case "$MODE" in
  edit)    edit edit "$@"; exit $? ;;
  correct) edit correction "$@"; exit $? ;;
  propose) propose "$@"; exit $? ;;
  adopt)   adopt "$@"; exit $? ;;
  unused)  unused; exit $? ;;
  report)  report ;;
  *) echo "usage: archie-learn.sh edit|correct|propose|adopt|unused|report (see the header)" >&2; exit 2 ;;
esac
