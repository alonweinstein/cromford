#!/bin/bash
# bin/issue-testhost-cert.sh — THE way to get a Fly test-host ssh cert by hand
# (BH-5210). Never run `flyctl ssh issue` yourself.
#
#   bin/issue-testhost-cert.sh [--key PATH] [--org ORG] [--hours N] [--force]
#
#   --key PATH   the private key; the cert goes beside it as PATH-cert.pub
#                (default TESTHOST_KEY, else $HOME/.fly/testhost-key)
#   --org ORG    the Fly org that issues it (default TESTHOST_ORG, else board-builders)
#   --hours N    how long the cert lives, a whole number >= 1 (default 72)
#   --force      issue even when the current cert still has time left
#
# EXIT CODES:
#   0    a new key and cert are in place, or the current cert is still fresh
#        and nothing was issued (without --force)
#   1    the issue failed, timed out or was held by another issuer, and the
#        current cert is still valid: it was left as it is (one WARNING line)
#   125  there is no valid cert after the attempt, or flyctl or a knob is missing
#   2    the command line was wrong
#   130/143  interrupted
#
# WHY THIS EXISTS. 2026-10-05 → 07: a session issued a cert by hand with
# --overwrite into a scratch path that already held a non-fly file. flyctl
# looped on "File exists, but isn't a fly.io ed25519 private key" for 44 hours
# into a redirect, which grew to 596 GB and filled the disk (ENOSPC).
#
# This script is a thin front on `bin/remote-gate.sh --issue-cert`, so a hand
# issue takes the gate's own path, not a copy of it: a temp dir beside the key,
# no --overwrite, stdin on /dev/null, the timeout from the settings row
# REMOTE_GATE_CERT_ISSUE_TIMEOUT_S with its whole process group killed past it,
# flyctl's output capped at 1 MiB and summed up in one line, the issue lock,
# and the key (mode 600) and then the cert renamed into place only once both
# exist. tests/flyctl-issue-guard.bh-5210-test.sh fails on any doc or script
# that spells the raw command with --overwrite.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

die2() { echo "issue-testhost-cert: $*" >&2; exit 2; }
usage() {
  cat <<'USAGE'
usage: bin/issue-testhost-cert.sh [--key PATH] [--org ORG] [--hours N] [--force]

Issues a Fly test-host ssh cert through bin/remote-gate.sh's bounded path.
Exit 0 = a cert is in place (issued, or still fresh). 1 = the issue failed but
the current cert is still valid. 125 = no valid cert. 2 = bad command line.
USAGE
}

FORCE=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --key)   [ $# -ge 2 ] || die2 "--key needs a path"; [ -n "$2" ] || die2 "--key is empty"
             export TESTHOST_KEY="$2"; shift 2 ;;
    --org)   [ $# -ge 2 ] || die2 "--org needs a name"; [ -n "$2" ] || die2 "--org is empty"
             export TESTHOST_ORG="$2"; shift 2 ;;
    --hours) [ $# -ge 2 ] || die2 "--hours needs a number"
             case "$2" in ''|*[!0-9]*) die2 "--hours wants a whole number, got '$2'" ;; esac
             [ "$2" -ge 1 ] || die2 "--hours must be at least 1"
             export REMOTE_GATE_ISSUE_HOURS="$2"; shift 2 ;;
    --force) FORCE=(--force); shift ;;
    *)       usage >&2; die2 "unknown argument '$1'" ;;
  esac
done

exec "$SELF_DIR/remote-gate.sh" --issue-cert ${FORCE[@]+"${FORCE[@]}"}
