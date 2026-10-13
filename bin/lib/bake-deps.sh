#!/bin/bash
# bin/lib/bake-deps.sh — the ONE manifest of every dependency fly/Dockerfile
# bakes by version (BH-1528), and the resolver that turns a manifest row into
# the exact version a build pins. Sourced by bin/fly-image-build.sh,
# bin/fly-image-refresh.sh and bin/bake-seed.sh.
#
# WHY. BH-1517 found the claude/codex CLIs frozen for weeks: an unpinned install
# RUN line never changes its text, so Depot's layer cache serves the same layer
# on every nightly rebuild. Every other unpinned install in the image had the
# same trap (node via NodeSource setup_22.x, bun/codegraph via curl|sh, gh and
# tailscale via apt, semgrep via bare pip), and rtk/playwright were pinned by
# literals in the Dockerfile. Each one is now an ARG whose value comes from a
# settings row `bake.<name>.version`; a changed row changes that one RUN line's
# text, which busts that layer and (see fly/Dockerfile's stage layout) never
# the warm bake.
#
# The manifest holds NAMES, never versions (no-hardcode rule): the versions are
# DB rows, set by an operator (bin/bake-seed.sh) or by whatever updates that
# tool. The CLIs keep their own BH-1517 rows (cli.claude_code.version /
# cli.codex.version) and are not repeated here.
#
# Columns: <name> <Dockerfile ARG> <hub probe binary, or - >
#   hub probe: this host's own `<binary> --version` may stand in for a missing
#   row ONLY when the hub installs that tool from the same artifact the image
#   does. rtk (GitHub release binary) and codegraph (the versioned bundle its
#   installer and npm both ship) qualify. node, gh and tailscale do NOT: on the
#   hub they come from Ubuntu/NodeSource apt with their own cadence (probed
#   2026-09-22: hub node 22.22.3, gh 2.45.0, tailscale 1.98.9 vs image 22.23.2,
#   2.100.0, 1.102.3), so the probe would silently DOWNGRADE the image. bun,
#   semgrep and playwright are not installed on the hub at all.
bake_deps() {
  cat <<'EOF'
node NODE_VERSION -
playwright PLAYWRIGHT_VERSION -
semgrep SEMGREP_VERSION -
tailscale TAILSCALE_VERSION -
gh GH_VERSION -
bun BUN_VERSION -
codegraph CODEGRAPH_VERSION codegraph
rtk RTK_VERSION rtk
EOF
}

bake_dep_names() { bake_deps | awk '{print $1}'; }

# bake_row_version <name> -> the parsed bake.<name>.version row on stdout,
# empty when the row is missing or not a dotted version ("latest", a typo). The
# parse is BH-1531's: a dotted number inside other text ("v22.23.2") still pins.
# rc is setting_get's: 0 read, 2 no row, 1 outage — so a caller can tell "no
# row" from "could not ask" (the refresh lane must not alert on an outage).
bake_row_version() {
  local raw="" rc=0
  declare -F setting_get >/dev/null 2>&1 || return 2
  raw=$(setting_get "bake.$1.version" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  cli_version_parse "$raw" 2>/dev/null
  return 0
}

# bake_last_baked <file> <name> -> the version recorded for <name> by the last
# successful build of this project (state/fly/<project>.bake), empty if none.
bake_last_baked() {
  [ -f "${1:-}" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# bake_dep_resolve <name> <probe> <last-baked-file> -> the version to pin, on
# stdout; empty when nothing resolves (the caller refuses). Order:
#   1. the bake.<name>.version row                 (the wanted version)
#   2. what this project's last good image baked   (no change, never latest)
#   3. the hub's own install, manifest-approved probes only
# Every fallback says so on stderr, naming the source it used.
bake_dep_resolve() {
  local name="$1" probe="$2" last="$3" v=""
  v=$(bake_row_version "$name")
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(bake_last_baked "$last" "$name")
  if [ -n "$v" ]; then
    echo "== $name: no usable bake.$name.version row — keeping this image's last baked $name ($v) ==" >&2
    printf '%s' "$v"; return 0
  fi
  [ "$probe" != - ] && declare -F cli_version_of >/dev/null 2>&1 && v=$(cli_version_of "$probe" 2>/dev/null)
  [ "$v" = missing ] && v=""
  [ -n "$v" ] && echo "== $name: no usable bake.$name.version row — falling back to this host's installed $probe ($v) ==" >&2
  printf '%s' "$v"
}
