#!/bin/bash
# bin/lib/heartbeat.sh — the WRITER half of the lane-liveness heartbeat contract (BH-638), SOURCED
# by long-lived lanes, never executed: a dead lane and a lane with nothing to do both produce no
# output, and state/heartbeat/<lane>.<pid>.json is the difference. ONE FILE PER WRITER, keyed
# (lane, pid), because merge-conductor and blocked-resolver OVERLAP as their normal state (#818).
# NEVER FAILS THE CALLER: best-effort writes, rc 0 always, tmp+mv so the */5 reader sees no torn
# file. Seams: HB_NOW, HB_DIR, HB_PID, HB_STALE_MULT, HB_SILENT_FLOOR_S. Entry: docs/verification-map/lane-heartbeat.md.
[ -n "${_HEARTBEAT_LIB:-}" ] && return 0
_HEARTBEAT_LIB=1
hb_now() { printf '%s' "${HB_NOW:-$(date +%s)}"; }
# The root is HARNESS, then H (BH-2650). HB_DIR still wins. With neither, hb_dir prints "" and every
# path below prints "": nothing is written, no stamp is kept, and a read finds nothing.
_hb_root() { printf '%s' "${HARNESS:-${H:-}}"; }
hb_dir() { local r; r=$(_hb_root); printf '%s' "${HB_DIR:-${r:+$r/state/heartbeat}}"; }
# A lane name is a FILE NAME: anything outside [A-Za-z0-9._-] would be a path.
_hb_slug() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-64; }
_hb_num() { local v; v=$(printf '%s' "${1:-}" | tr -dc '0-9'); case "$v" in '') printf '0' ;; *) printf '%s' "$v" ;; esac; }
# $$, NOT $BASHPID: merge-conductor's per-project forks are all the SAME lane instance, and $$ is
# the one number every fork agrees on.
_hb_pid()  { _hb_num "${HB_PID:-$$}"; }
# --- The write-through to the one liveness fact (BH-1031, state→DB slice 6) ---
# THE FILE IS STILL THE WRITE-AHEAD and still the only thing this library needs
# to work: the DB beat is a copy, sent after the file is written, and its
# failure is never the caller's problem. What the copy buys is the half a file
# on one box structurally cannot do — being READABLE when that box is gone,
# which is the moment a dead lane most needs to be visible.
#
# DARK UNTIL THE FLAG IS ON. flags/lane-liveness-db is a DB row that
# bin/jobs-client.sh flag_sync writes down as a file (bin/heartbeat-reaper.sh
# reconciles it once per */5 pass); this side tests the FILE only, because a
# beat must not pay a network round trip to find out whether to beat.
#
# Seams: HB_DB (1/0 forces the decision), HB_DB_CMD (the client to call),
# HB_DB_MIN_GAP_S (the rate limit below).
hb_db_enabled() {
  case "${HB_DB:-}" in 1) return 0 ;; 0) return 1 ;; esac
  local r; r=$(_hb_root)
  [ -n "$r" ] && [ -f "$r/flags/lane-liveness-db" ]
}
# _hb_db_due <lane> <pid> — rc 0 when a BEAT is due, 1 when one landed recently.
#
# THE WRITE-THROUGH IS RATE-LIMITED AT THE WRITER. wake-loop runs every minute
# with four 15s cycles, so it beats four times a minute: that is six detached
# client spawns (a 2,700-line source plus a curl) and six D1 row writes per
# minute for one lane — ~8.6k writes a day against a stale floor of 600s, 40x
# oversampled for the fact the row carries. A beat inside the window changes
# nothing a reader can see, so it is not sent. The FILE is still written every
# single time: it is the write-ahead, and it is free.
#
# THE WINDOW IS 150s FOR EVERY LANE unless the caller exported HB_INTERVAL_S
# (round 2 on #1150): `hb_start` takes its rhythm POSITIONALLY and does not
# export it, so this reads the library default 300 and halves it. That is the
# intended conservative end — 150s is far under the row's own threshold for
# every lane (the worker floors that at 600s and otherwise uses 3x the declared
# rhythm), so this can never make a live lane read silent; a lane that wants
# fewer writes still sets HB_DB_MIN_GAP_S. start and done are NEVER gated — they are the launch and the
# exit, and each happens once — and a launch does not arm the gate either: the
# FIRST beat after one is the loop saying it actually entered its cycle, which
# is worth a write. Only repeats inside the window are dropped.
#
# THE STAMP LIVES BESIDE state/heartbeat, NEVER IN IT: that directory is the
# reader's input and every name in it is parsed as a lane file, so a second name
# per lane would be a second finding.
_hb_db_dir()   { local d; d=$(hb_dir); [ -n "$d" ] || return 0; printf '%s-db' "$d"; }
_hb_db_stamp() { local d; d=$(_hb_db_dir); [ -n "$d" ] || return 0; printf '%s/%s.%s' "$d" "$(_hb_slug "${1:-}")" "$(_hb_num "${2:-0}")"; }
_hb_db_due() {
  local iv win now st last
  iv=$(_hb_num "${HB_INTERVAL_S:-300}"); [ "$iv" -lt 1 ] && iv=300
  win=$(( iv / 2 )); [ "$win" -lt 1 ] && win=1
  case "${HB_DB_MIN_GAP_S:-}" in ''|*[!0-9]*) ;; *) win="${HB_DB_MIN_GAP_S}" ;; esac
  now=$(hb_now); st="$(_hb_db_stamp "$1" "$2")"
  # No stamp path (no root): every beat is due and none is stamped.
  [ -n "$st" ] || return 0
  last=$(cat "$st" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -ge "$win" ] || return 1
  mkdir -p "$(_hb_db_dir)" 2>/dev/null && printf '%s' "$now" > "$st" 2>/dev/null
  return 0
}
# _hb_db <lane> <event> <pid> <interval> <expect> <note> — best effort, rc 0 always.
_hb_db() {
  hb_db_enabled || return 0
  local r cmd; r=$(_hb_root)
  cmd="${HB_DB_CMD:-${r:+$r/bin/jobs-client.sh}}"
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 0
  # Backgrounded and detached: a lane's rhythm is its own, and a slow worker
  # must not stretch a 300 s loop into a 304 s one — or, on a hung socket, stop
  # it. fd 9 is closed first so a beat can never inherit the lane's own
  # exclusive lock (wake-loop holds one) and keep it alive past the lane.
  ( exec 9>&-; JOBS_TIMEOUT="${HB_DB_TIMEOUT:-5}" JOBS_RETRIES=0 \
      "$cmd" lane-proc-beat "$1" "$2" "$3" "$4" "$5" "$6" >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}
# hb_file <lane> [pid] — deterministic from (lane, pid), which is what lets hb_done delete by path
# on a box with no jq at all.
hb_file()  { local d; d=$(hb_dir); [ -n "$d" ] || return 0; printf '%s/%s.%s.json' "$d" "$(_hb_slug "${1:-}")" "$(_hb_num "${2:-$(_hb_pid)}")"; }
_hb_box()  { local r; r=$(_hb_root); { [ -n "$r" ] && cat "$r/state/box-name" 2>/dev/null; } || printf '%s' "${BOX_NAME:-}"; }
# A note comes from the caller, so it is escaped, not trusted; a non-numeric time reads 0 and hb_state says unparseable.
_hb_esc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
# EVERY TEMP NAME IS $BASHPID, NEVER $$: the forks SHARE $$, so a temp name built from it is shared
# too — one writer's `>` truncation lands inside another's read and erases the launch declaration.
# _hb_write <lane> <pid> <started> <last_tick> <interval> <deadline> <note> <blocks> <restart> <stale> <stale_at> [kind]
# An empty kind writes no "kind" key at all, so a lane that declares none gets today's bytes.
_hb_write() {
  local d f tmp kind=""; d="$(hb_dir)"; [ -n "$d" ] || return 0; mkdir -p "$d" 2>/dev/null || return 0
  f="$(hb_file "$1" "$2")"; tmp="$f.${BASHPID:-$$}.tmp"
  [ -n "${12:-}" ] && kind=",\"kind\":\"$(_hb_esc "${12}")\""
  printf '{"lane":"%s","pid":%s,"box":"%s","started_at":%s,"last_tick":%s,"interval":%s,"deadline":%s,"note":"%s","blocks":"%s","restart":"%s","stale":%s,"stale_at":%s%s}\n' \
    "$(_hb_esc "$1")" "$(_hb_num "$2")" "$(_hb_esc "$(_hb_box)")" "$(_hb_num "$3")" "$(_hb_num "$4")" \
    "$(_hb_num "$5")" "$(_hb_num "$6")" "$(_hb_esc "$7")" "$(_hb_esc "$8")" "$(_hb_esc "$9")" \
    "${10:-false}" "$(_hb_num "${11:-0}")" "$kind" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null; return 0
}
# hb_start <lane> [interval_s] [expect_s] [blocks] [restart-cmd] [kind] — the rhythm, the EXPECTED-BY
# (deadline = now + expect_s), what a silence blocks, and (opt-in) the reaper's relaunch command.
# expect_s 0 writes deadline 0 = no expected-by, for a loop that runs for ever on purpose
# (WAKE_LOOP_CYCLES=0) and must never read as overdue. kind `cron` (BH-4717) is a lane whose
# instances get killed on purpose: the reaper drops its dead files and judges it by the stamp
# hb_done leaves in hb_done_dir instead.
hb_start() {
  local lane="${1:-${HB_LANE:-}}" iv="${2:-${HB_INTERVAL_S:-300}}" ex="${3:-${HB_EXPECT_S:-3600}}" now dl
  [ -n "$lane" ] || return 0; HB_LANE="$lane"; HB_KIND="${6:-}"; now=$(hb_now)
  ex=$(_hb_num "$ex"); dl=0; [ "$ex" -gt 0 ] && dl=$(( now + ex ))
  _hb_write "$lane" "$(_hb_pid)" "$now" "$now" "$iv" "$dl" "" "${4:-}" "${5:-}" false 0 "$HB_KIND"
  _hb_db "$lane" start "$(_hb_pid)" "$(_hb_num "$iv")" "$ex" ""
  return 0
}
# hb_tick [lane] [note] — the one line a loop adopts. A tick never rewrites the launch's numbers,
# and with no file yet it writes a whole one at the defaults. IT NEVER TOUCHES THE REAPER'S MARK:
# stale/stale_at are the reader's fact, and a tick that cleared them would unmark an alive-overdue
# lane every pass, so the reaper would re-find, re-mark and re-fire the same id every 5 minutes.
hb_tick() {
  local lane="${1:-${HB_LANE:-}}" note="${2:-}" f now tmp wrote=0
  [ -n "$lane" ] || return 0; HB_LANE="$lane"; f="$(hb_file "$lane")"; now=$(hb_now)
  if [ -s "$f" ] && command -v jq >/dev/null 2>&1; then
    tmp="$f.${BASHPID:-$$}.tmp"
    if jq -c --argjson t "$now" --arg n "$note" \
         '.last_tick=$t | .note=$n' "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
      wrote=1
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  if [ "$wrote" = 0 ]; then
    # No file (or no jq to preserve one): a whole file at the defaults — the one-line-adoption path.
    local ex dl; ex=$(_hb_num "${HB_EXPECT_S:-3600}"); dl=0; [ "$ex" -gt 0 ] && dl=$(( now + ex ))
    _hb_write "$lane" "$(_hb_pid)" "$now" "$now" "${HB_INTERVAL_S:-300}" "$dl" "$note" "" "" false 0 "${HB_KIND:-}"
  fi
  # THE DB COPY, AFTER THE FILE, and only when one is due. It is sent whichever
  # branch above wrote — a lane that adopted the one-line beat with no jq on the
  # box is exactly the lane whose death nobody could see before this.
  #
  # NO interval_s, ON PURPOSE. The rhythm belongs to the LAUNCH (hb_start), and
  # the row's stale threshold derives from it: a beat carrying the library
  # default would rewrite blocked-resolver's declared 1800 to 300 on its first
  # tick, collapse the threshold from 5400s to 900s, and page `silent` for a
  # healthy 40-minute fix round while the file on the box read fresh.
  hb_db_enabled && _hb_db_due "$lane" "$(_hb_pid)" \
    && _hb_db "$lane" beat "$(_hb_pid)" "" "" "$note"
  return 0
}
# hb_done [lane] — only the caller's OWN file goes, so the instance that finishes first can never
# take an overlapping survivor's heartbeat with it.
# A kind:cron file leaves its completion stamp first (<now>\t<interval>, read without jq): that
# stamp, not the instance file, is what the reaper judges a cron lane by.
hb_done() {
  local lane="${1:-${HB_LANE:-}}" f d iv st
  [ -n "$lane" ] || return 0; f="$(hb_file "$lane")"
  if [ -n "$f" ] && grep -q '"kind":"cron"' "$f" 2>/dev/null; then
    d=$(hb_done_dir); iv=$(_hb_num "$(sed -n 's/.*"interval":\([0-9]*\).*/\1/p' "$f" 2>/dev/null)")
    if [ -n "$d" ] && mkdir -p "$d" 2>/dev/null; then
      st="$d/$(_hb_slug "$lane")"
      printf '%s\t%s\n' "$(hb_now)" "$iv" > "$st.${BASHPID:-$$}.tmp" 2>/dev/null \
        && mv -f "$st.${BASHPID:-$$}.tmp" "$st" 2>/dev/null || rm -f "$st.${BASHPID:-$$}.tmp" 2>/dev/null
    fi
  fi
  [ -n "$f" ] && [ -e "$f" ] && rm -f "$f" 2>/dev/null
  # The rate-limit stamp goes with it — it is (lane, pid) state like the file.
  f="$(_hb_db_stamp "$lane" "$(_hb_pid)")"
  [ -n "$f" ] && rm -f "$f" 2>/dev/null
  # THE ROW IS NOT DELETED, it is stamped: a finished lane and a lane that was
  # never there are different facts, and only the row can still tell them apart
  # tomorrow. proc_ended_at is what stops a clean exit from paging.
  _hb_db "$lane" done "$(_hb_pid)" "" "" ""
  return 0
}
# hb_done_dir — state/heartbeat-done, BESIDE state/heartbeat like the -db stamps: one
# <lane> file (<epoch>\t<interval>) per cron lane, plus the reaper's <lane>.paged marker.
hb_done_dir() { local d; d=$(hb_dir); [ -n "$d" ] || return 0; printf '%s-done' "$d"; }
# hb_cron_interval <lane> [fallback] — seconds between a cron lane's ticks, from the catalog
# cadence when the hour/day fields are all `*`: `*` 60, `*/N` N*60, a minute list its largest gap
# (wrap included), one minute 3600. Anything else falls back. Prints max(parsed, fallback).
hb_cron_interval() {
  local fb r cad m h dom mon dow rest iv=0 n prev first last gap
  fb=$(_hb_num "${2:-0}"); r=$(_hb_root)
  if [ -n "$r" ] && command -v jq >/dev/null 2>&1; then
    cad=$(jq -r '.cadence // ""' "$r/catalog/lanes.d/$(_hb_slug "${1:-}").json" 2>/dev/null)
    read -r m h dom mon dow rest <<<"$cad"
    if [ "${h:-}" = '*' ] && [ "${dom:-}" = '*' ] && [ "${mon:-}" = '*' ] && [ "${dow:-}" = '*' ]; then
      case "$m" in
        '*') iv=60 ;;
        '*/'*) n=${m#*/}; case "$n" in ''|*[!0-9]*) ;; *) [ "$n" -ge 1 ] && iv=$(( n * 60 )) ;; esac ;;
        *[!0-9,]*|'') ;;
        *,*) prev=""; first=""; gap=0
             for n in $(tr ',' '\n' <<<"$m" | grep . | sort -n); do
               [ "$((10#$n))" -le 59 ] || { gap=0; first=""; break; }
               n=$((10#$n)); [ -z "$first" ] && first=$n
               [ -n "$prev" ] && [ $(( n - prev )) -gt "$gap" ] && gap=$(( n - prev ))
               prev=$n; last=$n
             done
             if [ -n "$first" ]; then
               [ $(( 60 - last + first )) -gt "$gap" ] && gap=$(( 60 - last + first ))
               iv=$(( gap * 60 ))
             fi ;;
        *) [ "$((10#$m))" -le 59 ] && iv=3600 ;;
      esac
    fi
  fi
  [ "$iv" -gt "$fb" ] || iv=$fb
  printf '%s' "$iv"
}
# hb_mark_stale <file> <now> [true|false] — "the reaper paged this one" (true, the default) or "the
# condition is over" (false, which also zeroes stale_at so the next page is a first sighting).
# rc 1 if it could not be written, and the reaper says so.
hb_mark_stale() {
  local f="${1:-}" now tmp v="${3:-true}"; now=$(_hb_num "${2:-0}")
  case "$v" in false) v=false; now=0 ;; *) v=true ;; esac
  [ -r "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  tmp="$f.${BASHPID:-$$}.tmp"
  jq -c --argjson s "$v" --argjson n "$now" '.stale=$s | .stale_at=$n' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}
# hb_state <file> <now> [boot_at] [nomark] — ONE word on stdout; reads, writes nothing.
# marked (paged already) | fresh |
# silent (alive, now-last_tick > max(interval x HB_STALE_MULT, HB_SILENT_FLOOR_S)) |
# overdue (alive, past its expected-by) | dead (pid gone, or last_tick before the boot) |
# unparseable (no jq, bad JSON, missing field — REPORTED, never skipped: a liveness check that can
# go quiet is the bug it was built to end). `nomark` skips the `marked` short-circuit and answers
# with the word underneath, which is how the reaper asks whether a file it paged has recovered.
hb_state() {
  local f="${1:-}" now="${2:-0}" boot="${3:-}" nomark="${4:-}" pid lt iv dl stale mult floor thr age v
  [ -r "$f" ] || { printf 'unparseable\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unparseable\n'; return 0; }
  # Unit-separated, never tab: tab is IFS whitespace, so an absent field would shift every field
  # after it left — a missing pid would read as the last_tick.
  IFS=$'\037' read -r pid lt iv dl stale < <(
    jq -r '[(.pid//""),(.last_tick//""),(.interval//""),(.deadline//0),(.stale//false)]|map(tostring)|join("\u001f")' "$f" 2>/dev/null)
  [ "$nomark" = nomark ] || case "${stale:-}" in true) printf 'marked\n'; return 0 ;; esac
  for v in "${pid:-}" "${lt:-}" "${iv:-}"; do case "$v" in ''|*[!0-9]*) printf 'unparseable\n'; return 0 ;; esac; done
  [ "$pid" -gt 0 ] 2>/dev/null || { printf 'unparseable\n'; return 0; }
  case "${dl:-}"  in ''|*[!0-9]*) dl=0 ;; esac
  case "${now:-}" in ''|*[!0-9]*) now=0 ;; esac
  # A pid that answers kill -0 but last ticked before the boot is not this lane.
  if [ -n "$boot" ] && [ "$boot" -gt 0 ] 2>/dev/null && [ "$lt" -lt "$boot" ]; then printf 'dead\n'; return 0; fi
  kill -0 "$pid" 2>/dev/null || { printf 'dead\n'; return 0; }
  mult="${HB_STALE_MULT:-3}"; case "$mult" in ''|*[!0-9]*) mult=3 ;; esac
  # interval 0 (WAKE_LOOP_INTERVAL_S=0 is real) would make every gap a silence, so 1s is the floor.
  [ "$iv" -lt 1 ] && iv=1
  # BH-4717: a 15s lane read silent 46s after a tick. The floor is the least gap that counts as
  # silence for any lane; 0 turns it off and leaves interval x mult alone.
  floor="${HB_SILENT_FLOOR_S:-120}"; case "$floor" in ''|*[!0-9]*) floor=120 ;; esac
  thr=$(( iv * mult )); [ "$thr" -lt "$floor" ] && thr=$floor
  age=$(( now - lt ))
  [ "$age" -gt "$thr" ] && { printf 'silent\n'; return 0; }
  [ "$dl" -gt 0 ] && [ "$now" -gt "$dl" ] && { printf 'overdue\n'; return 0; }
  printf 'fresh\n'
  return 0
}
# hb_age_text <secs> — an age for a page: "<n>s" under a minute, "<n>m" from one up, no newline.
# Negative or non-numeric prints 0s. Whole minutes alone would print a 50s gap as "0m".
hb_age_text() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt 60 ]; then printf '%ss' "$n"; else printf '%sm' "$(( n / 60 ))"; fi
}
