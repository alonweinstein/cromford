#!/bin/bash
# bin/charge.sh <order> <amount> — record a charge on an order.
set -eu
. "$(dirname "$0")/../lib/ledger.sh"
[ $# -eq 2 ] || { echo "usage: bin/charge.sh <order> <amount>" >&2; exit 2; }
ledger_record "charge:$1" charge "$2"
echo "charged $2 on $1"
