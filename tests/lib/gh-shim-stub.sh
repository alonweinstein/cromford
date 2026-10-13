#!/bin/bash
# tests/lib/gh-shim-stub.sh — the fixture harness every gh-rest-shim suite
# sources (#769 chunk 1). Sourced, never executed.
#
# WHAT IT BUILDS. A scratch world in which `gh` on PATH is the real
# bin/gh-rest-shim and the binary BEHIND it is a stub that answers from JSON
# files and writes down every call it was handed. That is what lets a suite
# assert on artifacts — the recorded argv, stdout, an exit code, a log line —
# instead of grepping the shim's source.
#
# ORDER MATTERS: source tests/lib/scratch.sh FIRST. It unsets HARNESS (among
# others), so a HARNESS set before it would be thrown away.
#
#   . "$(dirname "$0")/lib/scratch.sh" || exit 1
#   . "$(dirname "$0")/lib/gh-shim-stub.sh"
#   gshim_stub_setup
#
# THE API (the four sibling chunks import exactly this):
#   gshim_stub_setup            build $T/real, $T/shim, $T/h, $T/fixtures; set PATH+HARNESS
#   gshim_fixture <key> [rc]    stdin -> $T/fixtures/<key>.json, or <key>.rc + <key>.err
#   gshim_run <gh args…>        run gh; sets OUT, ERR, RC; never exits the suite
#   gshim_calls                 print $T/gh-calls.txt (empty when there is none)
#   gshim_env                   print $T/gh-env.txt (the depth marker per call)
#   gshim_reset                 forget the recorded calls and the pass-through log
#
# FIXTURE KEYS. The endpoint minus its query with `/` -> `_`:
#   repos/o/r/pulls/1            -> repos_o_r_pulls_1.json
#   repos/o/r/pulls?per_page=…   -> repos_o_r_pulls.json, or .p<N>.json per page
#   <key>.rc + <key>.err         -> that stderr and that exit code; when a
#                                   <key>.json is ALSO present it goes to stdout,
#                                   the way real gh prints an error body
#   <key>.diff                   -> served raw for `-H "Accept: …v3.diff"`
#   no fixture                   -> `HTTP 404: Not Found (…)` on stderr, rc 1
# `-q`/`--jq` pipes the fixture through `jq -r` the way real `gh api` does.
# A non-`api` subcommand records `PASSTHRU <argv…>` and exits 0 (or the rc in
# fixtures/passthru.rc).
#
# THE DEPTH MARKER. Every call also lands in $T/gh-env.txt as
# `depth=<GH_REST_SHIM_DEPTH> <argv…>` (`depth=none` when the shim did not export
# it). Without it a pass-through assertion passes just as well with NO shim on
# PATH at all — gh-calls.txt alone cannot tell "the shim handed this through"
# from "the call never met the shim". A block that expects a pass-through asserts
# depth=1 to prove the shim was the one that made it.
#
# THE GIT STUB answers `git remote get-url origin` from
# $T/fixtures/git-origin.txt and fails like git does when that file is absent,
# so a suite can pin origin parsing without a repo. It records every call and
# every GIT_CONFIG_* pair in $T/git-calls.txt.
#
# Everything it writes lives under $T. It reads no clock and no network.

GSHIM_STUB_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

gshim_stub_setup() {
  mkdir -p "$T/real" "$T/shim" "$T/h/logs" "$T/h/flags" "$T/fixtures" "$T/lib" "$T/tmp"
  # The shim's own temp dirs land under $T too, so a suite can count them and a
  # leaked one dies with the scratch tree instead of living in /tmp.
  export TMPDIR="$T/tmp"

  { printf '#!/bin/bash\n# stub: the real gh binary\nT=%q\n' "$T"
    cat <<'STUB'
CALLS="$T/gh-calls.txt"
FIX="$T/fixtures"

printf 'depth=%s %s\n' "${GH_REST_SHIM_DEPTH:-none}" "$*" >>"$T/gh-env.txt"

if [ "${1:-}" != "api" ]; then
  printf 'PASSTHRU %s\n' "$*" >>"$CALLS"
  if [ -f "$FIX/passthru.rc" ]; then
    [ -f "$FIX/passthru.err" ] && cat "$FIX/passthru.err" >&2
    exit "$(cat "$FIX/passthru.rc")"
  fi
  exit 0
fi

RAW="$*"
shift
ARGS=("$@")
EP=""; JQ=""; HDRS=""; INPUT=""
i=0
while [ "$i" -lt "${#ARGS[@]}" ]; do
  a="${ARGS[$i]}"
  case "$a" in
    -H|--header)  HDRS="$HDRS ${ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
    -q|--jq)      JQ="${ARGS[$((i+1))]:-}";         i=$((i+2)) ;;
    --input)      INPUT="${ARGS[$((i+1))]:-}";      i=$((i+2)) ;;
    -X|--method|-f|--field|-F|--raw-field|--template|--cache|--hostname)
                  i=$((i+2)) ;;
    -*)           i=$((i+1)) ;;
    *)            [ -n "$EP" ] || EP="$a"; i=$((i+1)) ;;
  esac
done

Q="${EP#*\?}"; [ "$Q" = "$EP" ] && Q=""
LINE="$RAW"
[ -n "$Q" ] && LINE="$LINE query=$Q"
if [ -n "$INPUT" ] && [ -f "$INPUT" ]; then
  BODY=$(cat "$INPUT")
  LINE="$LINE input=${BODY//$'\n'/\\n}"
fi
printf '%s\n' "$LINE" >>"$CALLS"

KEY="${EP%%\?*}"; KEY="${KEY//\//_}"
PAGE=""
case "$Q" in *page=*) PAGE="${Q##*page=}"; PAGE="${PAGE%%&*}" ;; esac

if [ -f "$FIX/$KEY.rc" ]; then
  [ -f "$FIX/$KEY.err" ] && cat "$FIX/$KEY.err" >&2
  # Real `gh api` prints the error BODY on stdout and its own message on stderr,
  # both, on a failing call. A stub that printed only stderr made every "no body
  # on failure" assertion vacuous: it passed because nothing had a body to leak.
  [ -f "$FIX/$KEY.json" ] && cat "$FIX/$KEY.json"
  exit "$(cat "$FIX/$KEY.rc")"
fi

case "$HDRS" in
  *vnd.github.v3.diff*)
    if [ -f "$FIX/$KEY.diff" ]; then cat "$FIX/$KEY.diff"; exit 0; fi ;;
esac

SRC=""
if [ -n "$PAGE" ] && [ -f "$FIX/$KEY.p$PAGE.json" ]; then
  SRC="$FIX/$KEY.p$PAGE.json"
elif [ -f "$FIX/$KEY.json" ]; then
  SRC="$FIX/$KEY.json"
fi
if [ -z "$SRC" ]; then
  echo "HTTP 404: Not Found (https://api.github.com/$EP)" >&2
  exit 1
fi
if [ -n "$JQ" ]; then jq -r "$JQ" <"$SRC"; else cat "$SRC"; fi
exit 0
STUB
  } >"$T/real/gh"
  chmod 755 "$T/real/gh"

  { printf '#!/bin/bash\n# stub: git\nT=%q\n' "$T"
    cat <<'STUB'
printf 'git %s\n' "$*" >>"$T/git-calls.txt"
while IFS= read -r kv; do
  printf 'env %s\n' "$kv" >>"$T/git-calls.txt"
done < <(env | grep '^GIT_CONFIG_' || true)
if [ "${1:-}" = "remote" ] && [ "${2:-}" = "get-url" ]; then
  if [ -f "$T/fixtures/git-origin.txt" ]; then
    cat "$T/fixtures/git-origin.txt"
    exit 0
  fi
  echo "error: No such remote 'origin'" >&2
  exit 2
fi
exit 0
STUB
  } >"$T/real/git"
  chmod 755 "$T/real/git"

  ln -sf "$GSHIM_STUB_REPO/bin/gh-rest-shim" "$T/shim/gh"

  export PATH="$T/shim:$T/real:$PATH"
  export HARNESS="$T/h"
  unset GH_REAL GH_SHIM_OFF GH_SHIM_LIB GH_SHIM_FALLBACK GH_SHIM_MAX_PAGES \
        GH_REST_SHIM_DEPTH GH_TOKEN
}

# gshim_fixture <key> [rc] — body on stdin.
gshim_fixture() {
  local key="$1" rc="${2:-}"
  if [ -n "$rc" ]; then
    cat >"$T/fixtures/$key.err"
    printf '%s\n' "$rc" >"$T/fixtures/$key.rc"
  else
    cat >"$T/fixtures/$key.json"
  fi
}

# gshim_run <gh args…> — drive the shim. Sets OUT/ERR/RC, returns 0 always, so a
# failing call never ends the suite before its assertion runs.
gshim_run() {
  gh "$@" >"$T/.out" 2>"$T/.err"
  RC=$?
  OUT=$(cat "$T/.out")
  ERR=$(cat "$T/.err")
  return 0
}

gshim_calls() {
  [ -f "$T/gh-calls.txt" ] && cat "$T/gh-calls.txt"
  return 0
}

gshim_env() {
  [ -f "$T/gh-env.txt" ] && cat "$T/gh-env.txt"
  return 0
}

gshim_reset() {
  rm -f "$T/gh-calls.txt" "$T/gh-env.txt" "$T/git-calls.txt" \
        "$T/h/logs/gh-passthrough.log"
  return 0
}
