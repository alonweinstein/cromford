#!/bin/bash
# tests/triage-plan-blocked-reoffer.bh-3825-test.sh — BH-3829 (slice 3 of
# #3825): a settled PLAN_BLOCKED result is re-offered once its blocker merges.
#
# THE INCIDENT. project-4 TK-2186 came back PLAN_BLOCKED on TK-2185 and its RESULT
# was marked COMMENTED, so it counted as settled. TK-2185 merged at 16:03Z and
# nothing moved TK-2186's triage-state hash or put it back in front of a
# session; an operator launched it by hand at 17:47Z.
#
#   P0  dark: no GATE_RELEASE_MAX_LAUNCHES = no scan, no offer, no merged-refs
#       file, and the pre-check hash is byte-identical to the tree without the lib
#   P1  2a: `hash --merged-refs` moves the hash for a merge after triaged_at only;
#       P1c the legacy-row transition sends a `|merged` ref to the model
#   P2  no map / {} / a missing file = byte-identical; after the re-triage
#       (ts_after_session -> record) the hash equals the stamp: it moved once
#   P3  ts_precheck (enforce) puts TK-2186 in the model set, off the unchanged list
#   P4  2b end to end: bin/gate-release.sh logs GATE_REOFFER and writes the
#       marker + keys file, bin/triage-gate.sh answers RUN gate-reoffer,
#       inapp_released_lines prints the REOFFER line and consumes the file, and
#       rt_scope's gate-reoffer arm reaches it
#   P5  one offer per GATE_RELEASE_REMIND_S; a stale keys file is deleted unread
#   P6  every negative: no GATE_REOFFER, no keys file
#   P7  _ts_work_keys emits the REOFFER key; ts_tick does not $0-end that tick
#   P8  a merge-gated queue line alone is a stated blocker
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-plan-blocked-reoffer.bh-3825-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok; else bad "$1: expected anything but [$3]"; fi; }
for c in jq python3 flock; do
  command -v "$c" >/dev/null 2>&1 || { echo "triage-plan-blocked-reoffer: $c missing, cannot run" >&2; exit 1; }
done
export PYTHONDONTWRITEBYTECODE=1

H="$T/h"
P=project-4
NOW=$(date +%s)
R_AT=$((NOW - 7200))      # the PLAN_BLOCKED RESULT
DEC_AT=$((R_AT + 600))    # the session's PLAN_BLOCKED decision (= the row's triaged_at)
M_AT=$((R_AT + 3780))     # TK-2185 merged
U=https://github.com/example-org/project-4/pull
S="$H/state/gate-release/$P"
D="$H/state/triage-state/$P"
KEYS="$H/state/gate-reoffer-keys-$P"
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }

mkdir -p "$H/bin/lib/gate-release" "$H/bin/lib/rt" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds" "$H/env" "$H/fixture"
# Test-first: each file is copied only when present, so on a tree without the
# slice every case fails on its assertion instead of crashing.
for f in bin/triage-state.py bin/triage-signal.py bin/triage-gate.sh bin/gate-release.sh \
         bin/lib/triage-state.sh bin/lib/triage-shards-lib.sh bin/lib/gate-release.sh bin/lib/split-chain.sh \
         bin/lib/ready-queue.sh bin/lib/lane-gate.sh bin/lib/lane-switch.sh bin/lib/hub-box.sh bin/lib/env-path.sh \
         bin/lib/board-creds.sh bin/lib/internal-token.sh bin/lib/rt/scope.sh bin/lib/gate-release/reoffer.sh; do
  [ -f "$DIR/$f" ] && cp "$DIR/$f" "$H/$f"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
: > "$H/env/global.env"

# --- stubs ---------------------------------------------------------------------
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ -f "$HARNESS/fixture/issues-board" ] && [ "$2" = board_prefix ] && { echo -; exit 0; }
case "$1/$2" in
  project-4/repo) echo example-org/project-4 ;;
  project-4/board_prefix) echo AR ;;
  *) exit 1 ;;
esac
SH
cat > "$H/bin/project-of.sh" <<'SH'
#!/bin/bash
case "$*" in TK-*) echo project-4 ;; *) exit 1 ;; esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/project-of.sh"
# The REST PR-state read: fixture/pr-<n> holds the answer, absent = 404.
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest_pr_state_var() {
  local _ghrv_v="$1" _ghrv_n="$3" _ghrv_st=""
  echo "$2 $3" >> "$HARNESS/fixture/gh-calls"
  _ghrv_st=$(cat "$HARNESS/fixture/pr-$_ghrv_n" 2>/dev/null)
  [ -n "$_ghrv_st" ] || { printf -v "$_ghrv_v" '%s' ""; return 44; }
  printf -v "$_ghrv_v" '%s' "$_ghrv_st"; return 0
}
SH
for t in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/fixture/calls"\nexit 22\n' "$t" "$H" > "$H/bin/$t"
  chmod +x "$H/bin/$t"
done

reset() {
  for _p in "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture" "$H/locks"; do scratch_rm "$_p"; done
  mkdir -p "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture" "$H/locks"
  return 0
}
res() { # res <dir-name> <line1> <mtime-epoch>
  mkdir -p "$H/builds/$1"; printf '%s\nTICKET_ID: x\n' "$2" > "$H/builds/$1/RESULT"
  touch -d "@$3" "$H/builds/$1/RESULT" "$H/builds/$1"
}
PB="$H/builds/$P-TK-2186-p1"
DECLINE="$(stamp "$DEC_AT") [$P] gate=results-sweep scope=1 TK-2186 :: skip :: PLAN_BLOCKED, thread says build after TK-2185 lands"
# world — the incident, as the box holds it: TK-2185 merged (#1817) after
# TK-2186's PLAN_BLOCKED result, which is COMMENTED, plus the session's line.
world() {
  reset
  res "$P-TK-2185-a1" "PR_MERGED $U/1817" "$M_AT"
  res "$P-TK-2186-p1" "PLAN_BLOCKED waiting on TK-2185" "$R_AT"
  touch -d "@$R_AT" "$PB/COMMENTED" "$PB"
  printf '%s\n' "$DECLINE" > "$H/logs/decisions.log"
  echo '{"TK-2185":"cm2185","cm2185":"TK-2185","TK-2186":"cm2186","cm2186":"TK-2186"}' > "$H/state/$P.keymap.json"
  echo '{"b1":[{"id":"cm2186","key":"TK-2186","title":"Fee mechanism","status":"todo","commentCount":2,"lastActivityAt":"2026-10-01T15:00:00Z"},{"id":"cm2185","key":"TK-2185","title":"Base fee table","status":"review","commentCount":1,"lastActivityAt":"2026-10-01T16:03:00Z"}]}' \
    > "$H/state/$P.gate.json"
  return 0
}
# drive [max] [now] — the real driver as a script; max "" = no knob at all.
drive() {
  [ -f "$H/bin/gate-release.sh" ] || return 99
  local max="${1-2}" now="${2:-$NOW}"
  if [ -n "$max" ]; then
    env PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= GR_NOW="$now" GATE_RELEASE_MAX_LAUNCHES="$max" \
      bash "$H/bin/gate-release.sh" "$P"
  else
    env -u GATE_RELEASE_MAX_LAUNCHES PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= GR_NOW="$now" \
      bash "$H/bin/gate-release.sh" "$P"
  fi
}
gate() { env PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= GATE_RELEASE_MAX_LAUNCHES=2 \
  bash "$H/bin/triage-gate.sh" "$P" 2>>"$T/gate.err"; }
# take — the tick's half, through the real scope stage file.
take() {
  ( export PATH="$H/bin:$PATH" HARNESS="$H" PROJECT="$P" BOX_NAME=test-box JOBS_URL= GATE_RELEASE_MAX_LAUNCHES="${1:-2}"
    . "$H/bin/lib/rt/scope.sh"; inapp_released_lines ) 2>/dev/null
}
glog() { local n; n=$(grep -c "$1" "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }
has() { [ -e "$1" ] && echo yes || echo no; }
REOFFER_LOG="GATE_REOFFER TK-2186: PLAN_BLOCKED result re-offered, TK-2185 merged (#1817)"

# =============================================================================
# P1 / P2 — bin/triage-state.py hash --merged-refs (2a)
# =============================================================================
world
Y="$T/py"; mkdir -p "$Y"
cp "$H/state/$P.gate.json" "$Y/world.json"
jq -n '{kind:"inapp",doc:{id:"cm2186",key:"TK-2186",title:"Fee mechanism",status:"todo",description:"remove the discount toggle",
  comments:[{id:"m1",authorName:"Client",body:"please",createdAt:"2026-10-01T14:00:00Z"}]}}' > "$Y/cm2186.raw"
printf 'cm2186\t%s\n' "$Y/cm2186.raw" > "$Y/batch.tsv"
REASON="DECISION skip: PLAN_BLOCKED, thread says build after TK-2185 lands"
rows() { # rows <triaged_at-epoch> [verdict_hash]
  jq -n --arg t "$(iso "$1")" --arg h "${2:-x}" --arg r "$REASON" \
    '[{ticket_key:"cm2186", verdict:"queued", waiting_on:"team", verdict_hash:$h, triaged_at:$t,
       next_recheck_at:"2099-01-01T00:00:00Z", reason:$r}]' > "$Y/rows.json"
}
mr() { printf '{"TK-2185":["1817",%s]}\n' "$1" > "$Y/mr.json"; }
hashpy() { python3 "$H/bin/triage-state.py" hash --world "$Y/world.json" --rows "$Y/rows.json" --batch "$Y/batch.tsv" "$@" 2>/dev/null; }
rows "$DEC_AT"; mr "$M_AT"
H0=$(hashpy); H0RC=$?
eq "P1 precondition: plain hash rc" "$H0RC" 0
H1=$(hashpy --merged-refs "$Y/mr.json"); H1RC=$?
eq "P1 hash --merged-refs rc" "$H1RC" 0
ne "P1 a merge after triaged_at moves the hash" "$(cut -f2 <<<"$H1")" "$(cut -f2 <<<"$H0")"
eq "P1 reason deps carry |merged" "$(cut -f6 <<<"$H1")" '[["ref:TK-2185","review|merged"]]'
eq "P1 base (thread-only) hash unmoved" "$(cut -f5 <<<"$H1")" "$(cut -f5 <<<"$H0")"
mr "$((DEC_AT - 60))"
eq "P1 a merge BEFORE triaged_at: hash == no map" "$(hashpy --merged-refs "$Y/mr.json")" "$H0"
mr "$M_AT"
# P1c — a legacy row (verdict_hash == base) whose reason ref merged goes to the model
BASE1=$(cut -f5 <<<"$H1")
rows "$DEC_AT" "$BASE1"
printf 'cm2186\tAR-2186\t%s\t-\t1\t-\t%s\t%s\n' "$(cut -f2 <<<"$H1")" "$BASE1" "$(cut -f6 <<<"$H1")" > "$Y/hashes.tsv"
DC=$(python3 "$H/bin/triage-state.py" decide --hashes "$Y/hashes.tsv" --rows "$Y/rows.json" --now "$NOW" --ttl 86400 \
  --defer-ttl 7200 --project "$P" --keymap "$H/state/$P.keymap.json" --gh 0 2>/dev/null)
eq "P1c legacy row: decision" "$(cut -f3 <<<"$DC")" llm
eq "P1c legacy row: note" "$(cut -f8 <<<"$DC")" reason-ref-settled
# P2 — no map, {} and a missing file are byte-identical to the plain call
rows "$DEC_AT"
echo '{}' > "$Y/empty.json"
eq "P2 empty map byte-identical" "$(hashpy --merged-refs "$Y/empty.json")" "$H0"
eq "P2 missing file byte-identical" "$(hashpy --merged-refs "$Y/nope.json")" "$H0"
eq "P2 empty arg byte-identical" "$(hashpy --merged-refs "")" "$H0"
# a thread ref is never suffixed: the same merge named only in the thread
jq '.doc.comments[0].body = "after TK-2185"' "$Y/cm2186.raw" > "$Y/t.raw"; printf 'cm2186\t%s\n' "$Y/t.raw" > "$Y/batch.tsv"
echo '[]' > "$Y/rows.json"
T0=$(hashpy); T1=$(hashpy --merged-refs "$Y/mr.json")
eq "P2 thread refs untouched" "$T1" "$T0"
printf 'cm2186\t%s\n' "$Y/cm2186.raw" > "$Y/batch.tsv"

# =============================================================================
# P0 / P3 / P2 (re-triage) — ts_precheck through bin/lib/triage-state.sh
# =============================================================================
ROWS="$T/rows.json"; echo '[]' > "$ROWS"
triage_state_list() { cat "$ROWS"; }
triage_state_put() { cp "$1" "$T/put.json"; }
LANE_TICK() { :; }
rt_gate_consume() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0 BOX_NAME=test-box JOBS_URL=
  PROJECT=$P; STAMP="2026-10-01 18:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON="${2:-results-sweep}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
seed_threads() {
  mkdir -p "$D"
  cp "$H/state/$P.gate.json" "$H/state/$P.gate.pending"
  cp "$Y/cm2186.raw" "$D/cm2186.raw"
  jq -n '{kind:"inapp",doc:{id:"cm2185",key:"TK-2185",title:"Base fee table",status:"review",description:"d",comments:[]}}' > "$D/cm2185.raw"
  python3 "$H/bin/triage-state.py" entries --world "$H/state/$P.gate.pending" > "$T/entries.tsv"
  while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$D/$k.entry"; done < "$T/entries.tsv"
}
col() { awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}' "$D/decisions.tsv" 2>/dev/null; }
pre() { ( unset GATE_RELEASE_MAX_LAUNCHES; [ -n "${1:-}" ] && export GATE_RELEASE_MAX_LAUNCHES="$1"; ts_precheck ) >/dev/null 2>&1; }
world; seed_threads
# pass 1: every row carries its reason, so the hash is the composite
jq -n --arg t "$(iso "$DEC_AT")" --arg r "$REASON" '[
  {ticket_key:"cm2186", verdict:"queued", waiting_on:"team", verdict_hash:"x", triaged_at:$t, next_recheck_at:"2099-01-01T00:00:00Z", reason:$r},
  {ticket_key:"cm2185", verdict:"triaged", waiting_on:"none", verdict_hash:"x", triaged_at:$t, next_recheck_at:"2099-01-01T00:00:00Z", reason:"x"}]' > "$ROWS"
tick_env shadow; pre ""
jq --arg a "$(col cm2186 5)" --arg b "$(col cm2185 5)" \
  'map(if .ticket_key=="cm2186" then .verdict_hash=$a else .verdict_hash=$b end)' "$ROWS" > "$ROWS.t" && mv "$ROWS.t" "$ROWS"
tick_env shadow; pre ""
eq "P0 precondition: both rows unchanged" "$(col cm2186 3) $(col cm2185 3)" "skip skip"
# P0 — dark: no knob, no merged-refs file, the hash of the tree without the lib
P0H=$(col cm2186 5)
eq "P0 dark: no merged-refs.json" "$(has "$D/merged-refs.json")" no
mv "$H/bin/lib/gate-release.sh" "$T/gr.away"
tick_env shadow; pre 2
eq "P0 dark hash == lib removed" "$(col cm2186 5)" "$P0H"
mv "$T/gr.away" "$H/bin/lib/gate-release.sh"
# P3 — enforce with the knob: TK-2186 goes to the model as changed
tick_env enforce; pre 2
eq "P3 merged-refs.json written" "$(jq -c '.["TK-2185"][0]' "$D/merged-refs.json" 2>/dev/null)" '"1817"'
eq "P3 TK-2186 decision" "$(col cm2186 3)" llm
eq "P3 TK-2186 reason" "$(col cm2186 4)" changed
eq "P3 TK-2185 still unchanged" "$(col cm2185 3)" skip
tick_env enforce
OUT3=$( GATE_RELEASE_MAX_LAUNCHES=2; export GATE_RELEASE_MAX_LAUNCHES; ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
UNCH=$(printf '%s' "$OUT3" | sed -n 's/.*status: \(.*\)\. Queue lines.*/\1/p')
case " $UNCH " in *" TK-2186 "*) bad "P3 TK-2186 must not be on the unchanged list: [$UNCH]" ;; *" TK-2185 "*) ok ;;
  *) bad "P3 the tick continues with TK-2185 unchanged: [$OUT3]" ;; esac
# P2 — the re-triage stamps without the map; the next hash equals the stamp
tick_env enforce; pre 2
printf 'tickets=1\nDECISION: TK-2186 :: defer :: TK-2185 merged, relaunch after the client confirms the fee\n' > "$T/o.txt"
rm -f "$T/put.json"; ts_after_session "$H" "$P" 0 "$T/o.txt" >/dev/null 2>&1
STAMPED=$(jq -r '.rows[]? | select(.ticket_key=="cm2186") | .verdict_hash' "$T/put.json" 2>/dev/null)
ne "P2 the re-triage stamped a row" "${STAMPED:-}" ""
jq -s '.[0] as $put | .[1] | map(select(.ticket_key=="cm2185")) + [$put.rows[] | select(.ticket_key=="cm2186")]' \
  "$T/put.json" "$ROWS" > "$ROWS.t" 2>/dev/null && mv "$ROWS.t" "$ROWS"
tick_env enforce; pre 2
eq "P2 after the re-triage: hash == stamp" "$(col cm2186 5)" "$STAMPED"
ne "P2 after the re-triage: not to the model again" "$(col cm2186 3)" llm
# a dotted key in a reason is prose: never looked up, never in the map
SAVED=$(cat "$ROWS")
jq 'map(.reason = "DECISION skip: PLAN_BLOCKED on TK-2185.0")' "$ROWS" > "$ROWS.t" && mv "$ROWS.t" "$ROWS"
tick_env enforce; pre 2
eq "P6 dotted reason key: empty merged-refs map" "$(jq -c . "$D/merged-refs.json" 2>/dev/null)" '{}'
printf '%s\n' "$SAVED" > "$ROWS"

# =============================================================================
# P7 — the REOFFER line keeps its key in the work set and the tick alive
# =============================================================================
RL='board gate: REOFFER TK-2186 "Fee mechanism" (PLAN_BLOCKED result project-4-TK-2186-p1 is not settled: TK-2185 (#1817) merged after it; re-read the thread and relaunch per the queue rules if nothing else blocks it. If you do not launch it this tick, write ONE line DECISION: TK-2186 :: defer :: <reason>)'
tick_env enforce gate-reoffer; TICK_SCOPE="$RL"
eq "P7 _ts_work_keys emits the REOFFER key" "$(_ts_work_keys | grep -v '^$')" TK-2186
OUT7=$( ts_precheck() { TS_MODE=enforce; TS_READY=1; TS_LLM=""; TS_LLM_KEYS=""; TS_SKIPSET=" "; TS_ENQ=""; TS_SUMMARY=x
          : > "$D/decisions.tsv"; }
        tick_env enforce gate-reoffer; TICK_SCOPE="$RL"; SCOPE_N=1
        ts_tick; echo "MARKER [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUT7" in *MARKER*"TRIAGE STATE"*) ok ;; *) bad "P7 a REOFFER tick is not ended at \$0: [$OUT7]" ;; esac
( GATE_REASON=gate-reoffer; _ts_enforce_reason ) && ok || bad "P7 gate-reoffer is an enforce reason"

# =============================================================================
# P4 — 2b end to end
# =============================================================================
world
out=$(drive); rc=$?
eq "P4 driver rc" "$rc" 0
eq "P4 driver summary" "$out" "gate-release $P: 1 action(s)"
eq "P4 GATE_REOFFER logged" "$(glog "$REOFFER_LOG\$")" 1
eq "P4 offered marker holds the epoch" "$(cat "$S/offered/TK-2186" 2>/dev/null)" "$NOW"
eq "P4 keys file" "$(cat "$KEYS" 2>/dev/null)" TK-2186
eq "P4 triage-gate answers" "$(gate)" "RUN gate-reoffer"
eq "P4 the gate never consumes the keys file" "$(has "$KEYS")" yes
TL=$(take)
case "$TL" in
  'board gate: REOFFER TK-2186 "Fee mechanism" (PLAN_BLOCKED result project-4-TK-2186-p1 is not settled: TK-2185 (#1817) merged after it;'*) ok ;;
  *) bad "P4 inapp_released_lines prints the REOFFER line: [$TL]" ;;
esac
case "$TL" in *'DECISION: TK-2186 :: defer :: <reason>)') ok ;; *) bad "P4 the line carries the defer instruction: [$TL]" ;; esac
eq "P4 keys file consumed" "$(has "$KEYS")" no
. "$H/bin/lib/triage-shards-lib.sh" 2>/dev/null
eq "P4 triage_shard_key places the line" "$(triage_shard_key board "$P" 0 "$TL" 2>/dev/null)" TK-2186
# rt_scope's gate-reoffer arm reaches inapp_released_lines (board unchanged: rc 2)
echo TK-2186 > "$KEYS"
mv "$H/bin/triage-gate.sh" "$T/tg.away"
printf '#!/bin/bash\necho "$*" >> "$HARNESS/fixture/pending"\nexit 0\n' > "$H/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$H/bin/gate-diff.sh"
printf '#!/bin/bash\ncat >/dev/null; exit 0\n' > "$H/bin/unblocked-children.sh"
chmod +x "$H/bin/triage-gate.sh" "$H/bin/gate-diff.sh" "$H/bin/unblocked-children.sh"
SC=$( export PATH="$H/bin:$PATH" HARNESS="$H" PROJECT="$P" BOX_NAME=test-box JOBS_URL= GATE_RELEASE_MAX_LAUNCHES=2
      STAMP="2026-10-01 18:00:00Z" LOG="$H/logs/$P.log" GATE_REASON=gate-reoffer PROMPT_TEXT="SOP" SCOPE_N=full TICK_SCOPE=""
      . "$H/bin/lib/rt/scope.sh"; rt_scope; printf '%s' "$TICK_SCOPE" ) 2>/dev/null
case "$SC" in 'board gate: REOFFER TK-2186 "Fee mechanism"'*) ok ;; *) bad "P4 rt_scope gate-reoffer builds the REOFFER scope: [$SC]" ;; esac
eq "P4 rt_scope fetched the live fingerprint" "$(cat "$H/fixture/pending" 2>/dev/null)" "$P --pending"
mv "$T/tg.away" "$H/bin/triage-gate.sh"; rm -f "$H/bin/gate-diff.sh" "$H/bin/unblocked-children.sh"

# =============================================================================
# P5 — once per window; a stale keys file is deleted unread
# =============================================================================
world; drive >/dev/null; rm -f "$KEYS"
out=$(drive)
eq "P5 inside the window: silent" "$out" ""
eq "P5 inside the window: one log line" "$(glog "$REOFFER_LOG")" 1
eq "P5 inside the window: no keys file" "$(has "$KEYS")" no
drive 2 "$((NOW + 21601))" >/dev/null
eq "P5 past the window: offered again" "$(glog "$REOFFER_LOG")" 2
touch -d "@$((NOW - 21700))" "$KEYS"
ne "P5 stale keys file: no RUN gate-reoffer" "$(gate)" "RUN gate-reoffer"
eq "P5 stale keys file deleted" "$(has "$KEYS")" no
echo TK-2186 > "$KEYS"; touch -d "@$((NOW - 21700))" "$KEYS"
eq "P5 take_lines: stale file prints nothing" "$(take)" ""
eq "P5 take_lines: stale file deleted" "$(has "$KEYS")" no

# =============================================================================
# P6 — negatives: no GATE_REOFFER, no keys file
# =============================================================================
none() {
  local out; out=$(drive "${2-2}")
  eq "P6 $1: no GATE_REOFFER" "$(glog GATE_REOFFER)" 0
  eq "P6 $1: no keys file" "$(has "$KEYS")" no
  eq "P6 $1: no offered marker" "$(has "$S/offered/TK-2186")" no
  eq "P6 $1: driver silent" "$out" ""
}
world; touch -d "@$((R_AT - 60))" "$H/builds/$P-TK-2185-a1/RESULT"; none "merge before the RESULT"
world; mkdir -p "$H/builds/$P-TK-2186-q2"; none "a newer dir in flight"
world; res "$P-TK-2186-q2" "PR_CREATED $U/1900" "$((NOW - 60))"; none "a newer PR_CREATED dir"
world; res "$P-TK-2186-p2" "PLAN_BLOCKED waiting on TK-2185 again" "$((NOW - 60))"; none "a newer PLAN_BLOCKED dir not yet COMMENTED"
world; echo '{"TK-2185":"cm2185"}' > "$H/state/$P.keymap.json"; none "closed (not in the keymap)"
world; echo 'not json' > "$H/state/$P.keymap.json"; none "unreadable keymap"
world; printf '%s\n' "$(stamp "$DEC_AT") [$P] gate=results-sweep scope=1 TK-2186 :: skip :: PLAN_BLOCKED on TK-2186 itself" > "$H/logs/decisions.log"; none "self-only blocker"
world; : > "$H/logs/decisions.log"; none "no decisions line, no queue line"
world; printf '%s\n%s\n' "$DECLINE" "$(stamp "$((DEC_AT + 60))") [$P] gate=board-changed scope=1 TK-2186 :: defer :: waiting on the client" > "$H/logs/decisions.log"
none "a later non-PLAN_BLOCKED decision"
world; printf '%s\n' "${DECLINE/$(stamp "$DEC_AT")/$(stamp "$((R_AT - 60))")}" > "$H/logs/decisions.log"; none "decision older than the RESULT"
world; rm -f "$PB/COMMENTED"; touch -d "@$R_AT" "$PB"; none "no COMMENTED"
world
LK="$H/locks/build-key-$P-TK-2186.lock"
( exec 7>"$LK"; flock -n 7 && exec sleep 30 ) & HOLDER=$!
for _ in $(seq 1 50); do ( flock -n 7 ) 7>"$LK" 2>/dev/null || break; sleep 0.1; done
none "build-key lock held"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
world; scratch_rm "$H/builds/$P-TK-2185-a1"; res "$P-TK-2185-c1" "PR_CREATED $U/1817" "$((R_AT + 60))"; echo open > "$H/fixture/pr-1817"
none "TK-2185 not merged"
eq "P6 TK-2185 not merged: one REST read" "$(grep -c . "$H/fixture/gh-calls" 2>/dev/null)" 1
world; printf '%s\n' "$(stamp "$DEC_AT") [$P] gate=results-sweep scope=1 TK-2186 :: skip :: PLAN_BLOCKED on TK-2185.0" > "$H/logs/decisions.log"; none "dotted key only"
world; echo "TK-2186 cm2186 — LAUNCH-QUEUE gate: TK-2185 merged; then QA by the client project=$P" > "$H/logs/READY-QUEUE.log"; none "prose queue gate vetoes"
world; touch "$H/fixture/issues-board"; none "GitHub-Issues board"
world; touch "$H/flags/gate-release-off"; none "kill switch"
world; none "dark (no knob)" ""
eq "P6 dark: no gate-release state at all" "$(has "$S")" no
# the kill switch, a keys file already on disk: take_lines re-verifies to nothing when dark
world; echo TK-2186 > "$KEYS"
eq "P6 dark take_lines prints nothing" "$(take 0)" ""

# =============================================================================
# P8 — the queue line alone states the blocker
# =============================================================================
world; : > "$H/logs/decisions.log"
echo "TK-2186 cm2186 LAUNCH-QUEUE gate: TK-2185 merged project=$P" > "$H/logs/READY-QUEUE.log"
drive >/dev/null
eq "P8 queue-line blocker offered" "$(glog "$REOFFER_LOG\$")" 1
eq "P8 keys file" "$(cat "$KEYS" 2>/dev/null)" TK-2186

echo "triage-plan-blocked-reoffer: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
