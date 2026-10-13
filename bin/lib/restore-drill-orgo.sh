#!/bin/bash
# bin/lib/restore-drill-orgo.sh — the Orgo API seam for the weekly restore
# drill (#400). Sourced by bin/restore-drill.sh, never run. Defines functions
# only.
#
# orgo <METHOD> <path> [json-body]
#   Calls ${ORGO_API_BASE:-https://www.orgo.ai/api}<path> with the bearer key
#   in $ORGO_API_KEY. Sets ORGO_HTTP (3-digit code, 000 on a transport failure)
#   and ORGO_BODY (the response body, empty on a transport failure). Returns 0
#   only on a 2xx. The key rides a process-substitution header file and the
#   body rides stdin, so neither shows up in argv or `ps`. An unset key is not
#   special-cased here: it sends an empty bearer and gets a 401.
#
# remote <computer_id> <label> <command>
#   Runs <command> on the computer through POST /computers/<id>/bash, with
#   `; echo __RC=$?` appended so the remote exit code comes back in the output.
#   Returns that code and sets REMOTE_OUT to the output before it. A non-2xx,
#   a body that does not parse, or a missing __RC line returns 255. Appends
#   exactly `<label> rc=<n>` to logs/restore-drill.log and never logs the
#   command, the body or the output (they carry secrets).
#
# UNPROVEN: /computers/<id>/bash has not been called from this repo yet (the
# watchdog only uses /computers/<id>/restart). Until the lifecycle slice runs
# it for real, this seam is built, not verified.

orgo() {
  local out crc
  if [ -n "${3:-}" ]; then
    out=$(curl -sS -X "$1" -m "${RESTORE_DRILL_CALL_TIMEOUT_S:-300}" \
      -H @<(printf 'Authorization: Bearer %s\n' "${ORGO_API_KEY:-}") \
      -H 'Content-Type: application/json' --data-binary @- \
      -w '\n%{http_code}' "${ORGO_API_BASE:-https://www.orgo.ai/api}$2" <<<"$3")
  else
    out=$(curl -sS -X "$1" -m "${RESTORE_DRILL_CALL_TIMEOUT_S:-300}" \
      -H @<(printf 'Authorization: Bearer %s\n' "${ORGO_API_KEY:-}") \
      -H 'Content-Type: application/json' \
      -w '\n%{http_code}' "${ORGO_API_BASE:-https://www.orgo.ai/api}$2" </dev/null)
  fi
  crc=$?
  ORGO_HTTP=${out##*$'\n'}
  if [ "$out" = "$ORGO_HTTP" ]; then ORGO_BODY=""; else ORGO_BODY=${out%$'\n'*}; fi
  if [ "$crc" != 0 ] || ! [[ "$ORGO_HTTP" =~ ^[0-9]{3}$ ]]; then
    ORGO_HTTP=000; ORGO_BODY=""
  fi
  [[ "$ORGO_HTTP" =~ ^2[0-9][0-9]$ ]]
}

remote() {
  local body n=255 output last pre re='^(.*)__RC=([0-9]{1,3})$'
  REMOTE_OUT=""
  body=$(jq -nc --arg c "$3; echo __RC=\$?" '{command:$c}')
  if orgo POST "/computers/$1/bash" "$body"; then
    if output=$(printf '%s' "$ORGO_BODY" | jq -r '.output // empty' 2>/dev/null); then
      # The last non-empty line carries the code ($(...) already dropped the
      # trailing blank lines); command output with no trailing newline leaves
      # it glued to the end of that line.
      last=${output##*$'\n'}
      if [[ "$last" =~ $re ]]; then
        n=$((10#${BASH_REMATCH[2]}))
        pre=""
        [ "$last" != "$output" ] && pre=${output%$'\n'*}
        if [ -n "${BASH_REMATCH[1]}" ]; then
          REMOTE_OUT="${pre:+$pre$'\n'}${BASH_REMATCH[1]}"
        else
          REMOTE_OUT=$pre
        fi
      else
        REMOTE_OUT=$output
      fi
    else
      REMOTE_OUT=$ORGO_BODY
    fi
  fi
  # No root, no log line; the rc is the same either way.
  if [ -n "${H:-${HARNESS:-}}" ]; then
    mkdir -p "${H:-${HARNESS:-}}/logs" 2>/dev/null
    printf '%s rc=%s\n' "$2" "$n" >> "${H:-${HARNESS:-}}/logs/restore-drill.log"
  fi
  return "$n"
}
