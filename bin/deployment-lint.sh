#!/bin/bash
# bin/deployment-lint.sh — BH-4080: fail on a deployment literal (our GitHub
# org, a box hostname, the operator's login or email, a billing account, a
# tailnet address, the workers.dev subdomain) in production code outside its
# one documented-default home.
#
# The families are catalog/deployment-literals.tsv; the exceptions are
# tests/no-hardcoded-deployment-allowlist.txt (`<path> <family>[,family] <reason>`;
# an entry with no reason, for a missing file, or for a file that no longer
# carries that family fails). The scan itself is bin/config-inventory.py
# --deployment-lint, the same code that writes docs/config-inventory/deployment.md.
# Read-only: it writes nothing.
#
# Usage:
#   bin/deployment-lint.sh [--root <path>] [--families <file>] [--allowlist <file>]
#     --root       tree to scan (default: this repo's root)
#     --families   families catalog (default: this repo's catalog/deployment-literals.tsv)
#     --allowlist  exceptions (default: <root>/tests/no-hardcoded-deployment-allowlist.txt;
#                  none at all when that file does not exist)
#
# Output: one `path:line<TAB>family<TAB>text` per hit, one `allowlist:<n>: …`
# per allowlist problem.
# Exit: 0 clean, 1 hits or allowlist problems, 2 could not run.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # BH-1138
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
FAMILIES="$ROOT/catalog/deployment-literals.tsv"
ALLOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="${2:?--root needs a path}"; shift 2 ;;
    --families)  FAMILIES="${2:?--families needs a file}"; shift 2 ;;
    --allowlist) ALLOW="${2:?--allowlist needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "deployment-lint.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "deployment-lint.sh: python3 not found" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "deployment-lint.sh: no such root $ROOT" >&2; exit 2; }
if [ -z "$ALLOW" ]; then
  ALLOW="$ROOT/tests/no-hardcoded-deployment-allowlist.txt"
  [ -f "$ALLOW" ] || ALLOW=/dev/null
fi
python3 "$SELF/config-inventory.py" --deployment-lint --root "$ROOT" --families "$FAMILIES" --allowlist "$ALLOW"
