# shellcheck shell=bash
# tests/lib/switch-fixture.sh — a scratch harness with a stub settings worker,
# for suites that read a kill switch through bin/lib/lane-switch.sh (BH-2426).
# Sourced AFTER tests/lib/scratch.sh, never executed; needs $DIR (the repo).
# Extracted from the setup in tests/lane-switch.bh-2320-test.sh.
#
#   swf_setup <root>       build the scratch harness at <root> (inside SCRATCH):
#                          the real bin/lib/lane-gate.sh + lane-switch.sh, the
#                          rendered catalog/lanes.json and the stub
#                          bin/jobs-client.sh; sets SWF_ROOT and exports
#                          HARNESS=<root>, CALLS, ROWS_FILE, JOBS_BOX (default
#                          hub-1) and LANE_GATE_NOW (default 1758300000)
#   swf_rows k=v [k=v...]  the settings table the stub serves; `seed:k=v` is a
#                          registry-seed row; no args = no rows. It also clears
#                          the settings cache and lane-gate state: with the
#                          clock pinned the 60s cache would serve the previous
#                          table forever. A suite testing "an outage keeps the
#                          cache" sets UNREACHABLE=1 WITHOUT calling it again.
#   swf_flag <name>        touch <root>/flags/<name>
#   swf_gets               how many GET /api/settings the stub has served
#   swf_install <rel>      copy $DIR/<rel> into <root>/<rel>, exec bit kept
#
# The stub: every request is appended to $CALLS; UNREACHABLE=1 makes it fail;
# flag_active exists only when STUB_FLAG_ACTIVE=1.
#
# Every function that writes refuses a root outside SCRATCH, with the predicate
# scratch.sh itself uses; without scratch.sh sourced first it refuses always.
# scratch.sh's own refusal (root beside a live harness) is inherited from it.

if ! declare -F rendered_registry >/dev/null; then
  . "$(dirname "${BASH_SOURCE[0]}")/rendered.sh" || return 1
fi

_swf_guard() {
  if [ -n "${SCRATCH:-}" ] && declare -F __scratch_inside >/dev/null && __scratch_inside "$1"; then
    return 0
  fi
  echo "switch-fixture: refusing $1 outside SCRATCH" >&2
  return 1
}

swf_setup() {
  local root="${1:-}" f
  [ -n "$root" ] || { echo "switch-fixture: swf_setup needs a root" >&2; return 1; }
  _swf_guard "$root" || return 1
  mkdir -p "$root"/bin/lib "$root"/flags "$root"/state "$root"/logs "$root"/catalog "$root"/locks "$root"/.swf || return 1
  for f in lane-gate.sh lane-switch.sh; do
    cp "$DIR/bin/lib/$f" "$root/bin/lib/" || { echo "switch-fixture: cannot copy bin/lib/$f" >&2; return 1; }
  done
  cp "$(rendered_registry)" "$root/catalog/lanes.json" || return 1
  cat > "$root/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_FLAG_ACTIVE:-}" = 1 ]; then
  flag_active() { echo "FLAG_ACTIVE $1" >> "$CALLS"; [ -f "$HARNESS/flags/$1" ]; }
fi
SH
  SWF_ROOT="$root"
  export HARNESS="$root" CALLS="$root/.swf/calls" ROWS_FILE="$root/.swf/rows.json"
  export JOBS_BOX="${JOBS_BOX:-hub-1}" LANE_GATE_NOW="${LANE_GATE_NOW:-1758300000}"
  printf '[]' > "$ROWS_FILE"
}

swf_rows() {
  local out='[]' kv k v actor
  _swf_guard "${SWF_ROOT:-}" || return 1
  for kv in "$@"; do
    actor=api
    case "$kv" in seed:*) actor=registry-seed; kv="${kv#seed:}" ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" --arg a "$actor" '. + [{key:$k,value:$v,actor:$a}]') || return 1
  done
  printf '%s' "$out" > "$ROWS_FILE"
  rm -rf "$SWF_ROOT/state/lane-gate" "$SWF_ROOT/state/settings-cache.json"
}

swf_flag() {
  _swf_guard "${SWF_ROOT:-}" || return 1
  case "${1:-}" in
    ''|*[!a-z0-9_-]*) echo "switch-fixture: bad flag name '${1:-}'" >&2; return 1 ;;
  esac
  touch "$SWF_ROOT/flags/$1"
}

swf_gets() {
  local n
  n=$(grep -c '^GET /api/settings$' "${CALLS:-/dev/null}" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

swf_install() {
  local rel="${1:-}"
  _swf_guard "${SWF_ROOT:-}" || return 1
  case "$rel" in
    ''|/*|..|../*|*/..|*/../*) echo "switch-fixture: swf_install needs a relative path without .., got '$rel'" >&2; return 1 ;;
  esac
  [ -f "$DIR/$rel" ] || { echo "switch-fixture: no $DIR/$rel" >&2; return 1; }
  mkdir -p "$(dirname "$SWF_ROOT/$rel")" && cp -p "$DIR/$rel" "$SWF_ROOT/$rel"
}
