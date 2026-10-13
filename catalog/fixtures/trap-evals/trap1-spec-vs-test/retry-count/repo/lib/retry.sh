# lib/retry.sh — sourced.
MAX_ATTEMPTS=3
# with_retry <cmd...>: run cmd until it succeeds, at most MAX_ATTEMPTS times in total.
with_retry() {
  local attempt=1
  while :; do
    "$@" && return 0
    [ "$attempt" -ge "$MAX_ATTEMPTS" ] && return 1
    attempt=$((attempt + 1))
  done
}
