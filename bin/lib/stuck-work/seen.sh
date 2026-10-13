# shellcheck shell=bash
# bin/lib/stuck-work/seen.sh — BH-3789 (BH-3781.0): sw_first_seen, the clock
# anchor both stuck-work fact readers share. Sourced, never executed. Needs
# job_ledger_row / job_ledger_put (bin/jobs-client.sh) already loaded.
#
#   sw_first_seen <key>  -> the epoch first recorded for <key> in jobs ledger
#                           kind `stuck_work_seen`, or `?` when unreadable.
#
# PUT /api/ledger is an upsert, so the anchor is written ONLY when
# job_ledger_row answers rc 2 (no row): a present row is never re-written, and
# a present row whose first_seen does not parse is `?`, never overwritten. A
# failed write is also `?`: printing now without a stored anchor would restart
# the clock every tick. rc 1 only for an empty key (a caller bug); otherwise rc 0.
# STUCK_WORK_NOW replaces the clock only under HARNESS_TEST_SANDBOX=1.
#
# THE MEMO. An anchor never changes once written, so the answer is also kept
# at state/stuck-work/seen/<sha1 of key> (one line, the epoch) and read from
# there first: no ledger GET on any tick after the first. The memo is written
# only after a good ledger answer (a parsed row, or a PUT that succeeded), never
# for `?`. A memo that is not all digits is ignored and replaced. The root is
# ${HARNESS:-${H:-}}, and under HARNESS_TEST_SANDBOX=1 only an explicit HARNESS
# (facts-pr.sh's _swf_state_dir rule, repeated: this file loads first). No root
# = no memo, the ledger as before. SWF_COUNT_FILE gets SEEN-HIT / SEEN-MISS.

# _sw_seen_dir — print the memo dir (created); rc 1 = no memo.
_sw_seen_dir() {
  local h="${HARNESS:-}"
  [ -n "$h" ] || [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] || h="${H:-}"
  [ -n "$h" ] && mkdir -p "$h/state/stuck-work/seen" 2>/dev/null || return 1
  printf '%s' "$h/state/stuck-work/seen"
}
_sw_seen_count() { [ "$(type -t _swf_count)" = function ] && _swf_count "$1" "$2"; return 0; }
# _sw_seen_keep <memo-file|""> <epoch> — write the memo through a temp file.
_sw_seen_keep() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null
  rm -f "$1.tmp.$$" 2>/dev/null
  return 0
}

sw_first_seen() {
  local key="${1:-}" now row rc v d memo=""
  [ -n "$key" ] || return 1
  now=$(date -u +%s)
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${STUCK_WORK_NOW:-}" =~ ^[0-9]+$ ]]; then
    now=$STUCK_WORK_NOW
  fi
  if d=$(_sw_seen_dir); then
    memo="$d/$(printf '%s' "$key" | sha1sum | cut -c1-40)"
    if [ -r "$memo" ]; then
      v=$(cat "$memo" 2>/dev/null)
      if [[ "$v" =~ ^[0-9]+$ ]]; then _sw_seen_count SEEN-HIT "$key"; echo "$v"; return 0; fi
    fi
  fi
  if [ "$(type -t job_ledger_row)" != function ] || [ "$(type -t job_ledger_put)" != function ]; then
    echo '?'; return 0
  fi
  _sw_seen_count SEEN-MISS "$key"
  row=$(job_ledger_row stuck_work_seen "$key"); rc=$?
  case "$rc" in
    0)
      v=$(printf '%s' "$row" | jq -r '.detail | fromjson? | .first_seen // empty | select(type=="number")' 2>/dev/null)
      if [[ "$v" =~ ^[0-9]+$ ]]; then _sw_seen_keep "$memo" "$v"; echo "$v"; else echo '?'; fi ;;
    2)
      if job_ledger_put stuck_work_seen "$key" seen "{\"first_seen\":$now}" >/dev/null 2>&1; then
        _sw_seen_keep "$memo" "$now"
        echo "$now"
      else
        echo '?'
      fi ;;
    *) echo '?' ;;
  esac
  return 0
}
