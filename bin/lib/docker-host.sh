#!/bin/bash
# bin/lib/docker-host.sh — THE ONE PLACE this repo resolves the docker endpoint.
#
# WHY IT EXISTS (BH-1193). Ten local suites in containers SIGKILL each other in
# a Mac's memory, so the drain's agent limiter sits at 5 agents / 3 builds. The
# way out is to run the containers somewhere else: a box with spare RAM,
# `DOCKER_HOST=ssh://root@<host>`, the Mac orchestrating only. That knob has to
# be read in exactly one place, or the next script that wants it reads it a
# second way and the two disagree about what "not configured" means.
#
# Sourced, never executed. Nothing runs at source time, nothing is printed and
# nothing is exported — the caller decides what to do with the answer. Safe
# under the caller's `set -u`.
#
#   docker_host_resolve            print the endpoint, or nothing
#   docker_host_is_remote <ep>     rc 0 only if the tree has to be SHIPPED
#   docker_host_label <ep>         the endpoint, or "the local docker daemon"
#
# NOT CONFIGURED IS NOT BROKEN. No global.env, no env dir, a commented-out line,
# an empty or whitespace-only value: all of them mean the local daemon, which is
# what everybody who has not stood a host up gets. A value that IS set and does
# not answer is the opposite — the caller must fail rather than fall back, or
# the Mac quietly goes back to running the containers this knob exists to move.

# The endpoint, first hit wins:
#   1. a non-blank DOCKER_HOST already in the environment, so
#      `DOCKER_HOST=… bin/run-tests-in-docker.sh` behaves the way every other
#      docker tool behaves;
#   2. DOCKER_HOST set by <env dir>/global.env;
#   3. nothing — the local daemon.
docker_host_resolve() {
  local v envdir file
  v=$(__docker_host_strip "${DOCKER_HOST:-}")
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi

  envdir=$(__docker_host_env_dir) || { printf '\n'; return 0; }
  file="$envdir/global.env"
  [ -r "$file" ] || { printf '\n'; return 0; }

  # A SUBSHELL, the bin/backup-records-sync.sh idiom: callers of this library
  # write files and run other programs, and must not carry every credential in
  # global.env in their own environment. Only DOCKER_HOST comes back out. It is
  # also what makes a `#DOCKER_HOST=…` line a comment rather than a setting —
  # the file is sourced, not grepped. `set +u` because a global.env written for
  # a lane that tolerates unset variables must not abort a caller that does not.
  v=$(
    (
      set +u
      # shellcheck source=/dev/null
      . "$file" >/dev/null 2>&1 || exit 0
      printf '%s' "${DOCKER_HOST:-}"
    ) 2>/dev/null
  )
  printf '%s\n' "$(__docker_host_strip "$v")"
}

# Remote means "a bind mount would resolve on the wrong machine", which is the
# only question the runner asks. Blank is local; so are the two endpoint schemes
# that can only ever name a socket on this machine. Everything else — ssh://,
# tcp://, npipe:// — is remote. Misclassifying local as remote costs a pointless
# copy; misclassifying remote as local runs the suite against an EMPTY /repo and
# reports whatever that does, which is why the list is spelled out.
docker_host_is_remote() {
  local e
  e=$(__docker_host_strip "${1:-}")
  [ -n "$e" ] || return 1
  case "$e" in
    unix://*|fd://*) return 1 ;;
    *) return 0 ;;
  esac
}

# For messages. A DOCKER_HOST value carries no credentials (ssh:// names a user
# and a host; the key is ssh's business), so printing it is safe — and nothing
# else read out of global.env is ever printed.
docker_host_label() {
  local e
  e=$(__docker_host_strip "${1:-}")
  if docker_host_is_remote "$e"; then printf '%s\n' "$e"; else printf '%s\n' "the local docker daemon"; fi
}

__docker_host_strip() { # trim leading and trailing whitespace
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The env dir, through the repo's one resolver. HARNESS falls back to the
# CHECKOUT when /root/harness does not exist (the bin/testhost-tick.sh shape):
# the machine this knob is for is a Mac, which has no /root/harness, and a path
# under a directory that does not exist would read as "not configured" forever.
__docker_host_env_dir() {
  local libdir root
  libdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 1
  root="${HARNESS:-/root/harness}"
  [ -d "$root" ] || root=$(cd "$libdir/../.." 2>/dev/null && pwd) || return 1
  if ! command -v harness_env_dir >/dev/null 2>&1; then
    # shellcheck source=bin/lib/env-path.sh
    . "$libdir/env-path.sh" 2>/dev/null || return 1
  fi
  harness_env_dir "$root"
}
