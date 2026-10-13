#!/bin/bash
# bin/lib/fanin.sh — the fan-in assertion (BH-186): every PR a lane enumerates
# leaves through exactly one accounted outcome, and a run where
# enumerated != accounted says so.
#
# Sourced by bin/merge-conductor.sh and bin/reconcile-prs.sh, the two lanes that
# start PR work (the operator, 2026-09-24; merge-sweep no longer runs on cron and is not
# wired). Never executed.
#
# THE LEDGER. One scratch file per run, $HARNESS/state/fanin/<lane>/<scope>.<pid>:
#   E <id>             one line per enumerated PR
#   A <id> <outcome>   one line per accounted PR
#   X <id> signal=<SIG> after=<N>s   a worker wrapper TERMed/INTed/HUPed
#                      before its body returned (BH-4842): no A line, so the id
#                      stays missing, and the alert says why
#   T signal=<SIG> after=<N>s        the run's own shell signalled, written by
#                      the traps fanin_trap_run installs (caller opt-in)
# Appends take a flock on the file itself, because the conductor's per-PR
# workers write in parallel.
#
# THE STAGE (BH-4842). fanin_run_sub points FANIN_STAGE_FILE (a plain shell
# var, NOT exported) at <ledger dir>/.stage/<ledger name>/<id>, and mc_log
# overwrites it with every line the worker logs. A missing id's alert carries
# the last one, flattened and cut to FANIN_STAGE_MAX chars (160, a text-shape
# constant). fanin_end and the orphan reap delete the run's .stage dir.
#
# THE STREAK (BH-4842). <ledger dir>/.streak, TSV `id<TAB>count<TAB>epoch`,
# rewritten under a flock on .streak.lock by every report: a missing id +1, an
# id whose worker FINISHED removed, every other id untouched (deferred:solo,
# deferred:window, killed:deadline from mc_worker_bounded, a ` signal=` death
# and a lock-skip (skipped:locked, READY held:worker-locked) all keep it: a
# solo run killed at its deadline, or still holding the PR's lock while a
# batch fire skips it, must not send the PR back to batches), a row older than
# 7 days dropped. fanin_streak <id> reads it. A run killed
# between its alert and its rm is reported twice by design (below), and so
# counts twice: the PR is isolated one run sooner, no worse.
#
# ACCOUNTED BY CONSTRUCTION. The per-PR body only ever runs inside fanin_run
# (same shell) or fanin_run_sub (a subshell), and the wrapper writes the A line
# after the body returns, whichever return it took. What escapes the wrapper — a
# body that `exit`s the lane, a worker that is SIGKILLed — writes no A line, and
# that is what the check catches:
#   - the run reaches fanin_end: the id is named `missing:`;
#   - the run itself died: the next fanin_begin of the same lane+scope finds the
#     ledger (its pid is dead, and a zombie counts as dead), alerts with "(run died before fan-in)" and
#     deletes it. A dead ledger that is fully accounted is deleted silently.
#
# OUTPUT. fanin_end writes ONE line to the lane's own log on a non-empty run:
#   <ts> FANIN <lane> <scope>: enumerated N accounted M (<outcome> <n>, ...)
# and on a mismatch one alert through bin/lane-alert.sh --severity warn:
#   ALERT FANIN <lane> <scope>: enumerated N accounted M missing: <id>... [double: <id>...]
# The orphan path appends " (run died before fan-in)", then " run: signal=<SIG>
# after=<N>s" when the dead run left a T line. Either path then appends
# " why: <id> [signal=<SIG> after=<N>s] [stage: \"<line>\"]; ..." for each
# missing id that has a stamp or a stage; with neither, the text is unchanged.
# An empty run writes nothing; a healthy run sends no alert.
#
# FAIL-OPEN. Every function returns 0 and never fails its caller. With no ledger
# (fanin_begin not called, or the state dir unwritable) every function is a
# silent no-op, and the two run wrappers still run the body. The FANIN_* globals
# are deliberately NOT exported: a detached child that sources this lib must not
# append to its parent's ledger.

_fanin_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

_fanin_append() { # _fanin_append <file> <line>
  { flock 8 2>/dev/null; printf '%s\n' "$2" >&8; } 2>/dev/null 8>>"$1"
  return 0
}

# _fanin_pid_live <pid> — rc 0 when the pid is a running (or stopped) process.
# `kill -0` alone says yes to a zombie, and a SIGKILLed tick's ledger pid is an
# orphan zombie until PID 1 reaps it (BH-2247), so a zombie (stat state Z or X)
# is dead, and so is a pid that vanishes between the two checks. With no /proc
# (FANIN_PROC is a test seam for its root) the kill -0 answer stands.
_fanin_pid_live() {
  local proc="${FANIN_PROC:-/proc}" s
  kill -0 "$1" 2>/dev/null || return 1
  [ -d "$proc/self" ] || return 0
  s=$(cat "$proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) }
  case "${s%% *}" in Z|X) return 1 ;; esac
  return 0
}

# _fanin_stage_dir <ledger> — where the run's per-id stage files live. Dot-led,
# so fanin_begin's "<scope>.*" ledger glob never matches it.
_fanin_stage_dir() { printf '%s/.stage/%s' "${1%/*}" "${1##*/}"; }
_fanin_safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# _fanin_why <ledger> <missing ids> <xs> — "<id> [signal=… after=…s] [stage:
# \"…\"]; …" for each missing id with a stamp (xs: RS-separated id GS stamp)
# or a stage file; empty when no id has either.
_fanin_why() {
  local file="$1" sd id st stamp part out="" max="${FANIN_STAGE_MAX:-160}" seen=" " r
  case "$max" in ''|*[!0-9]*) max=160 ;; esac
  sd=$(_fanin_stage_dir "$file")
  for id in $2; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    stamp=""
    while IFS=$'\035' read -r -d $'\036' r st; do [ "$r" = "$id" ] && stamp="$st"; done <<<"${3:+$3$'\036'}"
    st=""
    [ -f "$sd/$(_fanin_safe_id "$id")" ] && st=$(tr '\t\n"' "  '" < "$sd/$(_fanin_safe_id "$id")" 2>/dev/null)
    st="${st% }"; st="${st:0:$max}"
    [ -n "$stamp" ] || [ -n "$st" ] || continue
    part="$id${stamp:+ $stamp}${st:+ stage: \"$st\"}"
    out="${out:+$out; }$part"
  done
  printf '%s' "$out"
}

# _fanin_streak_update <ledger> <missing ids> — the streak file (header). Never
# creates the file for a run with nothing missing, nor with no root (BH-2613:
# no root writes nothing, and fanin_streak reads it only under one); fail-open
# on every error.
_fanin_streak_update() {
  local file="$1" sf now tmp
  [ -n "${HARNESS:-${H:-}}" ] || return 0
  sf="${file%/*}/.streak"; tmp="$sf.tmp.$BASHPID"
  [ -n "$2" ] || [ -s "$sf" ] || return 0
  now=$(date +%s)
  ( flock -w 5 7 2>/dev/null || exit 0
    [ -f "$sf" ] || : > "$sf" 2>/dev/null || exit 0
    awk -v now="$now" -v miss="$2" '
      BEGIN { n = split(miss, mm, " "); for (i = 1; i <= n; i++) bump[mm[i]] = 1 }
      FNR == NR { if ($1 == "A") { id = $2; o = $0; sub(/^A [^ ]+ ?/, "", o); if (o !~ /^(deferred|killed):/ && o !~ /^skipped:locked/ && o !~ /held:worker-locked/ && o !~ / signal=/) clear[id] = 1 }
                  next }
      { split($0, f, "\t"); id = f[1]
        if (id == "" || f[3] !~ /^[0-9]+$/ || f[3] + 604800 < now) next
        if (id in bump) { print id "\t" (f[2] + 1) "\t" now; done[id] = 1 }
        else if (!(id in clear)) print $0 }
      END { for (id in bump) if (!(id in done)) print id "\t1\t" now }' "$file" "$sf" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$sf" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0
  ) 7>>"$sf.lock" 2>/dev/null
  return 0
}

# fanin_streak <id> — how many reports in a row named <id> missing in the lane
# of the current fanin_begin; 0 when absent, unreadable or no ledger root.
fanin_streak() {
  local h="${HARNESS:-${H:-}}" n
  [ -n "$h" ] && [ -n "${FANIN_LANE:-}" ] || { echo 0; return 0; }
  n=$(awk -F'\t' -v id="$1" '$1 == id { v = $2 } END { print v + 0 }' "$h/state/fanin/$FANIN_LANE/.streak" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
  return 0
}

# _fanin_report <ledger> <lane> <scope> <log> [note] — the tally, the summary
# line and the alert. With a note (the orphan path) only a mismatch is reported.
_fanin_report() {
  local file="$1" lane="$2" scope="$3" log="$4" note="${5:-}" res en ac missing double tally run xs why label text h
  [ -f "$file" ] || return 0
  res=$(awk '
    $1 == "E" { e[$2]++; en++; if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } next }
    $1 == "A" { a[$2]++; ac++; id = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); o = ($0 == "" ? "unlabelled" : $0)
                if (!(o in t)) oo[++m] = o; t[o]++
                if (!(id in seen)) { seen[id] = 1; order[++n] = id } next }
    $1 == "X" { id = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); x[id] = $0; next }
    $1 == "T" { $1 = ""; sub(/^ +/, ""); run = $0; next }
    END {
      mi = ""; db = ""; ta = ""; xs = ""
      for (i = 1; i <= n; i++) { id = order[i]
        for (k = a[id] + 0; k < e[id] + 0; k++) mi = mi " " id
        if (a[id] + 0 > e[id] + 0) db = db " " id
        if (a[id] + 0 < e[id] + 0 && (id in x)) xs = xs "\036" id "\035" x[id] }
      for (i = 1; i <= m; i++) ta = ta (i > 1 ? ", " : "") oo[i] " " t[oo[i]]
      printf "%d\037%d\037%s\037%s\037%s\037%s\037%s\n", en, ac, substr(mi, 2), substr(db, 2), ta, run, substr(xs, 2)
    }' "$file" 2>/dev/null) || return 0
  IFS=$'\037' read -r en ac missing double tally run xs <<<"$res"
  [ "${en:-0}" -gt 0 ] || [ "${ac:-0}" -gt 0 ] || return 0
  label="$lane${scope:+ $scope}"
  if [ -z "$note" ]; then
    printf '%s FANIN %s: enumerated %s accounted %s (%s)\n' "$(_fanin_stamp)" "$label" "$en" "$ac" "$tally" >> "$log" 2>/dev/null
  fi
  _fanin_streak_update "$file" "$missing"
  [ -n "$missing" ] || [ -n "$double" ] || return 0
  text="ALERT FANIN $label: enumerated $en accounted $ac"
  [ -n "$missing" ] && text="$text missing: $missing"
  [ -n "$double" ] && text="$text double: $double"
  [ -n "$note" ] && text="$text $note"
  [ -n "$run" ] && text="$text run: $run"
  why=$(_fanin_why "$file" "$missing" "$xs")
  [ -n "$why" ] && text="$text why: $why"
  [ -n "$note" ] && printf '%s %s\n' "$(_fanin_stamp)" "$text" >> "$log" 2>/dev/null
  # The alert goes through the root's lane-alert.sh or ALERTS.log; with no root
  # there is neither, and only the caller's $log line above is written.
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  if [ -x "$h/bin/lane-alert.sh" ]; then
    "$h/bin/lane-alert.sh" --severity warn "$lane" "$text" >/dev/null 2>&1 || true
  else
    printf '%s %s\n' "$(_fanin_stamp)" "$text" >> "$h/logs/ALERTS.log" 2>/dev/null
  fi
  return 0
}

# fanin_begin <lane> <scope> <logfile> — open this run's ledger. First reports
# and deletes the ledgers of dead runs of the same lane+scope. A ledger whose
# pid is alive is a parallel run and is left alone — unless the pid is this
# shell's own, which can only be a dead run's pid reused. A zombie pid is a
# dead run (_fanin_pid_live).
fanin_begin() {
  local lane="$1" scope="${2:-}" log="$3" dir safe f pid
  unset FANIN_FILE
  FANIN_LANE="$lane"; FANIN_SCOPE="$scope"; FANIN_LOG="$log"
  # No root = no ledger: FANIN_FILE stays unset, as when the mkdir fails.
  [ -n "${HARNESS:-${H:-}}" ] || return 0
  dir="${HARNESS:-${H:-}}/state/fanin/$lane"
  safe=$(printf '%s' "${scope:-run}" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$dir" 2>/dev/null || return 0
  for f in "$dir/$safe".*; do
    [ -f "$f" ] || continue
    pid="${f##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$BASHPID" ] && _fanin_pid_live "$pid" && continue
    _fanin_report "$f" "$lane" "$scope" "$log" "(run died before fan-in)"
    rm -rf "$(_fanin_stage_dir "$f")" 2>/dev/null
    rm -f "$f" 2>/dev/null
  done
  f="$dir/$safe.$BASHPID"
  : > "$f" 2>/dev/null || return 0
  FANIN_FILE="$f"
  return 0
}

fanin_enumerate() { # fanin_enumerate <id>
  [ -n "${FANIN_FILE:-}" ] || return 0
  _fanin_append "$FANIN_FILE" "E $1"
}

fanin_account() { # fanin_account <id> <outcome...>
  [ -n "${FANIN_FILE:-}" ] || return 0
  local id="$1"; shift
  _fanin_append "$FANIN_FILE" "A $id ${*:-unlabelled}"
}

# fanin_run <id> <outcome-var> <fn> [args...] — run fn in THIS shell (it may set
# the lane's globals), then account the outcome fn left in <outcome-var>, or
# `unlabelled`, plus ` rc=N` on a non-zero return. The body must hold no
# `continue`/`break`/`exit`: bash lets a `continue` in a function act on the
# caller's loop, which would skip the accounting — and the check would say so.
fanin_run() {
  local id="$1" var="$2" fn="$3" rc out
  shift 3
  printf -v "$var" '%s' ""
  "$fn" "$@"; rc=$?
  out="${!var:-unlabelled}"
  [ "$rc" = 0 ] || out="$out rc=$rc"
  fanin_account "$id" "$out"
  return 0
}

# fanin_run_sub <id> <outcome-fn> <fn> [args...] — run fn in a subshell, so even
# an `exit` inside it comes back here, then account `<outcome-fn> <rc> args...`
# (its stdout) plus ` rc=N` on a non-zero status, and ` signal=<SIG>` when that
# status is a signal death (rc >= 129) the wrapper itself survived, unless the
# outcome already starts `killed:`.
#
# SIGNALLED (BH-4842). The body runs as a background child the wrapper waits on,
# so a TERM/INT/HUP to the wrapper interrupts the wait at once: _fanin_sub_signal
# TERMs the body, writes `X <id> signal=<SIG> after=<N>s` and exits
# 128+n with no A line — the id stays missing and the alert says why. The traps
# the caller had are put back afterwards, so a foreground call leaks none, and
# a `&` wrapper gets none of its parent's (bash would show them to `trap -p`).
# FANIN_STAGE_FILE is set for the body only (header: THE STAGE).
fanin_run_sub() {
  local id="$1" ofn="$2" fn="$3" rc out saved sd
  shift 3
  local _FANIN_SUB_ID="$id" _FANIN_SUB_T0="$SECONDS" _FANIN_SUB_PID="" FANIN_STAGE_FILE=""
  if [ -n "${FANIN_FILE:-}" ]; then
    sd=$(_fanin_stage_dir "$FANIN_FILE")
    mkdir -p "$sd" 2>/dev/null && FANIN_STAGE_FILE="$sd/$(_fanin_safe_id "$id")"
  fi
  # In a subshell, bash shows the PARENT's traps until the subshell's first
  # `trap` call, and none of them is installed here. The no-op RETURN reset
  # clears that view, so `saved` holds only the traps this shell really has
  # and a `&` wrapper does not install its parent's _fanin_run_signal.
  trap - RETURN
  saved=$(trap -p TERM INT HUP)
  trap '_fanin_sub_signal TERM 143' TERM
  trap '_fanin_sub_signal INT 130' INT
  trap '_fanin_sub_signal HUP 129' HUP
  ( "$fn" "$@" ) <&0 &
  _FANIN_SUB_PID=$!
  wait "$_FANIN_SUB_PID"; rc=$?
  trap - TERM INT HUP
  eval "$saved"
  [ -n "${FANIN_FILE:-}" ] || return 0
  out=$("$ofn" "$rc" "$@" 2>/dev/null)
  [ -n "$out" ] || out=unlabelled
  [ "$rc" = 0 ] || out="$out rc=$rc"
  # An outcome that already names the kill (mc_fanin_outcome's killed:deadline,
  # BH-4918) says why on its own; the signal name is for every other death.
  case "$out" in killed:*) ;; *)
    [ "$rc" -ge 129 ] && [ "$rc" -le 192 ] && out="$out signal=$(kill -l $((rc - 128)) 2>/dev/null || echo $((rc - 128)))" ;;
  esac
  fanin_account "$id" "$out"
  return 0
}

# _fanin_sub_signal <SIG> <rc> — fanin_run_sub's trap (above). The body is
# always sent TERM: bash ignores INT in an async child of a non-interactive
# shell, so forwarding INT itself would leave the body running.
_fanin_sub_signal() {
  [ -n "${_FANIN_SUB_PID:-}" ] && kill -TERM "$_FANIN_SUB_PID" 2>/dev/null
  [ -n "${FANIN_FILE:-}" ] && _fanin_append "$FANIN_FILE" "X ${_FANIN_SUB_ID:-?} signal=$1 after=$((SECONDS - ${_FANIN_SUB_T0:-$SECONDS}))s"
  exit "$2"
}

# fanin_trap_run — caller opt-in, right after fanin_begin: a TERM/INT/HUP to the
# run's own shell writes `T signal=<SIG> after=<N>s` into the ledger and exits
# 128+n, so the next fanin_begin's "(run died before fan-in)" alert says how.
# The caller's EXIT trap still fires on that exit.
fanin_trap_run() {
  _FANIN_RUN_T0=$SECONDS
  trap '_fanin_run_signal TERM 143' TERM
  trap '_fanin_run_signal INT 130' INT
  trap '_fanin_run_signal HUP 129' HUP
  return 0
}
_fanin_run_signal() {
  [ -n "${FANIN_FILE:-}" ] && _fanin_append "$FANIN_FILE" "T signal=$1 after=$((SECONDS - ${_FANIN_RUN_T0:-$SECONDS}))s"
  exit "$2"
}

# fanin_end — tally, summary line, alert on a mismatch, delete the ledger. The
# alert goes out BEFORE the delete, so a run killed between the two re-reports
# on the next begin: a duplicate at worst, never a lost alert.
fanin_end() {
  [ -n "${FANIN_FILE:-}" ] || return 0
  _fanin_report "$FANIN_FILE" "$FANIN_LANE" "$FANIN_SCOPE" "$FANIN_LOG"
  rm -rf "$(_fanin_stage_dir "$FANIN_FILE")" 2>/dev/null
  rm -f "$FANIN_FILE" 2>/dev/null
  unset FANIN_FILE
  return 0
}

# ---- the merge conductor's outcome (bin/merge-conductor.sh tick_project) -----
# mc_fanin_outcome <rc> <row> — what one pr_worker left behind. The draft and
# UNVERIFIABLE early returns are read off the row itself; every other exit is
# the PR's pr-state.tsv state after the worker (mc_row_field, loaded by the
# driver), or skipped:no-row when it has none. Lives here, not in an mc module,
# so tests/mc/expected-map.d/ needs no row for it.
#
# LOCKED (BH-4842). A worker that found the PR's lock held by an earlier worker
# (a solo run still working it) did no work on the PR: pr_worker leaves
# <FANIN_STAGE_FILE>.locked, and this says `skipped:locked` instead of the
# row's state, or `READY held:worker-locked` for a READY row (the note the
# lock-skip writes, BH-4918). Both keep the streak; the row's state cleared it.
#
# TWO MORE WORDS (BH-4918). A worker mc_worker_bounded killed at its deadline is
# `killed:deadline`, never the state its row happened to be left in. A row the
# worker left READY is `READY held:<kind>` when the READY arm wrote a ready-why
# note for this head during this tick (MC_FANIN_T0, set by tick_project), and
# `READY unexplained` otherwise: no enqueue (that would have made it QUEUED) and
# no recorded hold. Both of those new outcomes write one log line and one warn
# alert per (PR, head), through the attempts ledger.
mc_fanin_outcome() {
  local num head draft mstate st key mark d stage f ts nh kind text
  IFS=$'\t' read -r num _ head _ draft mstate _ <<<"${2:-}"
  if [ "$draft" = true ]; then echo skipped:draft; return 0; fi
  if [ "$mstate" = UNVERIFIABLE ]; then echo skipped:unverifiable; return 0; fi
  key="${SLUG:-}#$num"
  mark=$(_mc_deadline_mark "$key")
  if [ -n "$mark" ] && [ -f "$mark" ]; then
    IFS=$'\t' read -r d stage < "$mark" 2>/dev/null
    rm -f "$mark" 2>/dev/null
    if ! mc_attempt_has "workerdeadline $key $head" 2>/dev/null; then
      mc_attempt_put "workerdeadline $key $head" 2>/dev/null
      text="worker killed after ${d:-?}s on ${head:0:8} at stage: ${stage:-unknown}"
      mc_log "$key WORKER_DEADLINE: $text" 2>/dev/null
      _mc_fanin_alert "WORKER_DEADLINE $key: $text"
      # BH-5617. fanin_run_sub reads this function's stdout as the outcome
      # word, so the reporter's output is discarded here as well.
      command -v sentry_report >/dev/null 2>&1 && sentry_report warning merge-conductor conductor-worker-deadline \
        "WORKER_DEADLINE: $text" \
        "$(jq -nc --arg p "${P:-}" --arg k "$key" --arg h "$head" --arg s "${stage:-unknown}" --arg d "${d:-}" '{project:$p,pr:$k,head:$h,stage:$s,deadline_s:$d}' 2>/dev/null)" >/dev/null 2>&1
    fi
    echo killed:deadline; return 0
  fi
  st=$(mc_row_field "$key" 2 2>/dev/null)
  if [ -n "${FANIN_STAGE_FILE:-}" ] && [ -f "$FANIN_STAGE_FILE.locked" ]; then
    rm -f "$FANIN_STAGE_FILE.locked" 2>/dev/null
    [ "$st" = READY ] || { echo skipped:locked; return 0; }
  fi
  if [ "$st" = READY ]; then
    f="${MC_STATE_DIR:-}/ready-why/$(mc_handoff_id "$key" 2>/dev/null)"
    ts=""; nh=""; kind=""
    [ -n "${MC_STATE_DIR:-}" ] && [ -r "$f" ] && IFS=$'\t' read -r ts nh kind _ < "$f" 2>/dev/null
    if [ -n "$kind" ] && [ "$nh" = "$head" ] && [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -ge "${MC_FANIN_T0:-0}" ]; then
      echo "READY held:$kind"; return 0
    fi
    if ! mc_attempt_has "readyunexplained $key $head" 2>/dev/null; then
      mc_attempt_put "readyunexplained $key $head" 2>/dev/null
      text="the worker left the row READY with no enqueue and no recorded hold this tick"
      mc_log "$key READY_UNEXPLAINED on ${head:0:8}: $text" 2>/dev/null
      _mc_fanin_alert "READY_UNEXPLAINED $key on ${head:0:8}: $text"
    fi
    echo "READY unexplained"; return 0
  fi
  echo "${st:-skipped:no-row}"
}

# mc_fanin_solo <slug> <num> <n> — BH-4842: hand a PR that has been missing from
# fan-in on <n> runs in a row to its own keyed conductor run (kw_conductor:
# detached, every lock fd closed, deduped per PR by MC_KEYED_WAKE_MIN_S). rc 0
# launched: the caller accounts it deferred:solo and drops it from its batch.
# rc 1 refused (keyed wake off, stamped too recently, no lib): the caller keeps
# the row, so a PR is never dropped without a run that will work it. The run it
# launches carries MC_FANIN_SOLO_RUN=1 (kw_conductor, KW_FANIN_SOLO), which is
# what keeps that run from soloing again.
mc_fanin_solo() {
  local slug="$1" num="$2" n="$3" h="${MC_H:-${HARNESS:-${H:-}}}"
  command -v kw_conductor >/dev/null 2>&1 || { [ -n "$h" ] && . "$h/bin/lib/keyed-wake.sh" 2>/dev/null; }
  if command -v kw_conductor >/dev/null 2>&1 \
     && KW_FANIN_SOLO=1 kw_conductor "$slug" "$num" "missing from fan-in on $n runs in a row — worked alone"; then
    mc_log "$slug#$num FANIN_SOLO: missing from fan-in on $n runs in a row — launched alone (keyed run)"
    return 0
  fi
  mc_log "$slug#$num FANIN_SOLO: missing from fan-in on $n runs in a row — solo launch refused (keyed wake off or launched <${MC_KEYED_WAKE_MIN_S:-120}s ago); kept in this run"
  return 1
}

# mc_fanin_mark_locked — pr_worker's lock-skip calls this (LOCKED, above):
# <FANIN_STAGE_FILE>.locked, read and removed by mc_fanin_outcome. Outside a
# fanin_run_sub body it does nothing. Always rc 0.
mc_fanin_mark_locked() {
  [ -n "${FANIN_STAGE_FILE:-}" ] && : > "$FANIN_STAGE_FILE.locked" 2>/dev/null
  return 0
}

# mc_window_cap — BH-4842, THE WINDOW. A keyed backstop run carries
# MC_WORKERS_DONE_BY, the epoch second by which every worker of the run must be
# gone: the backstop's worker cap (WD, its timeout minus 45 s, never under 30 s)
# after the run started. A worker started now may use what is left until then.
# Prints that as the worker's cap, never above MC_WORKER_DEADLINE_CAP_S, and
# rc 0 when it is at least 15 s; rc 1 when it is not, and the caller must not
# start the worker (15 s: under that a worker cannot read a PR and act on it).
# No deadline, or not a number: prints nothing, rc 0 (every run that is not a
# backstop fire is unchanged).
mc_window_cap() {
  local dl="${MC_WORKERS_DONE_BY:-}" left
  [[ "$dl" =~ ^[0-9]+$ ]] || return 0
  left=$(( dl - $(date +%s) ))
  [ "$left" -ge 15 ] || return 1
  [[ "${MC_WORKER_DEADLINE_CAP_S:-}" =~ ^[0-9]+$ ]] && [ "$MC_WORKER_DEADLINE_CAP_S" -gt 0 ] \
    && [ "$MC_WORKER_DEADLINE_CAP_S" -lt "$left" ] && left=$MC_WORKER_DEADLINE_CAP_S
  printf '%s\n' "$left"
}

# mc_window_defer <key> — hand a key the window had no room for back to the
# backstop: one line in MC_WINDOW_DEFER_FILE, appended under a flock (every
# project of the run writes it in parallel), and one log line. No file: the log
# line alone; the key stays a candidate and the next fire takes it anyway.
mc_window_defer() {
  local f="${MC_WINDOW_DEFER_FILE:-}"
  mc_log "$1 WINDOW_DEFERRED: under 15s of worker time left before this run's worker deadline — not started, ${MC_WINDOW_NEXT:-the next backstop fire takes it first}" 2>/dev/null
  [ -n "$f" ] || return 0
  { flock 8 2>/dev/null; printf '%s\n' "$1" >&8; } 2>/dev/null 8>>"$f"
  return 0
}

# _mc_fanin_alert <text> — one warn alert for the merge-conductor lane, through
# the root's lane-alert.sh. With no root, or no lane-alert.sh, the log line the
# caller already wrote is the whole record.
_mc_fanin_alert() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -x "$h/bin/lane-alert.sh" ] || return 0
  "$h/bin/lane-alert.sh" --severity warn merge-conductor "$1" >/dev/null 2>&1 || true
  return 0
}

# _mc_deadline_mark <key> — the marker a deadline kill leaves for this PR in this
# tick: $MC_STATE_DIR/worker-deadline/<id>.<MC_TICK_ID>. The tick id keeps two
# overlapping ticks of one project from reading each other's. Prints nothing
# without a state dir.
_mc_deadline_mark() {
  [ -n "${MC_STATE_DIR:-}" ] || return 0
  printf '%s/worker-deadline/%s.%s' "$MC_STATE_DIR" "$(mc_handoff_id "$1" 2>/dev/null)" "${MC_TICK_ID:-notick}"
}

# _mc_kill_tree <sig> <pid> — signal <pid> and every descendant in ITS session,
# children first. A descendant in another session was detached on purpose
# (`setsid nohup` rebase, re-review, deploy-verify, batch-resolve lanes) and is
# skipped, with everything under it. The tree is collected before anything is
# signalled. With no `ps`, only <pid> is signalled. Always rc 0.
_mc_kill_tree() {
  local sig="$1" root="$2" sid p k ks i=0 q
  [[ "$root" =~ ^[0-9]+$ ]] || return 0
  if ! command -v ps >/dev/null 2>&1; then kill -"$sig" "$root" 2>/dev/null; return 0; fi
  sid=$(ps -o sid= -p "$root" 2>/dev/null | tr -d ' ')
  q=("$root")
  while [ "$i" -lt "${#q[@]}" ]; do
    p=${q[$i]}; i=$((i + 1))
    for k in $(ps -o pid= --ppid "$p" 2>/dev/null); do
      ks=$(ps -o sid= -p "$k" 2>/dev/null | tr -d ' ')
      [ -n "$sid" ] && [ -n "$ks" ] && [ "$ks" != "$sid" ] && continue
      q+=("$k")
    done
  done
  for ((i = ${#q[@]} - 1; i >= 0; i--)); do kill -"$sig" "${q[$i]}" 2>/dev/null; done
  return 0
}

# mc_worker_bounded <row> — pr_worker under a deadline (BH-4918). The backstop
# runs the keyed conductor under `timeout`, which signals its whole process
# group, and every worker of the tick is in it: one worker stuck on a slow read
# took the healthy ones, and the tick's enqueue pass, down with it. This kills
# the slow worker alone, with its gh/curl children (which also frees the PR
# lock they inherited on fd 9), and leaves the marker mc_fanin_outcome reads.
#
# The deadline is MC_WORKER_DEADLINE_S (default 180, 0 = none, not a number =
# 180), never above MC_WORKER_DEADLINE_CAP_S when that is set: the backstop sets
# the cap from its own timeout, so the deadline always fires first, whatever the
# settings row says. Runs inside fanin_run_sub's subshell, and returns the
# worker's own status (143 or 137 when it was killed).
mc_worker_bounded() {
  local d cap mark w k rc stage dir t0
  d=${MC_WORKER_DEADLINE_S:-180}; [[ "$d" =~ ^[0-9]+$ ]] || d=180
  cap=${MC_WORKER_DEADLINE_CAP_S:-}
  if [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] && { [ "$d" = 0 ] || [ "$d" -gt "$cap" ]; }; then d=$cap; fi
  mark=$(_mc_deadline_mark "${SLUG:-}#${1%%$'\t'*}")
  if [ "$d" = 0 ] || [ -z "$mark" ]; then pr_worker "$@"; return; fi
  dir="${mark%/*}"; mkdir -p "$dir" 2>/dev/null
  pr_worker "$@" & w=$!
  (
    sleep "$d"
    # The stage is the last line this tick logged for the PR: already in the
    # log, so it puts nothing new (no argv, no token) in an alert.
    t0=$(date -u -d "@${MC_FANIN_T0:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    stage=$(tail -n 5000 "${MC_LOG:-/dev/null}" 2>/dev/null \
      | awk -v k="${SLUG:-}#${1%%$'\t'*}" -v t="$t0" '(index($0, k " ") || index($0, k ":")) && substr($0, 1, 19) >= t { l = $0 } END { print substr(l, 1, 300) }')
    printf '%s\t%s\n' "$d" "${stage//$'\t'/ }" > "$mark" 2>/dev/null
    _mc_kill_tree TERM "$w"; sleep 5; _mc_kill_tree KILL "$w"
  ) & k=$!
  wait "$w"; rc=$?
  _mc_kill_tree TERM "$k"; wait "$k" 2>/dev/null
  return "$rc"
}
