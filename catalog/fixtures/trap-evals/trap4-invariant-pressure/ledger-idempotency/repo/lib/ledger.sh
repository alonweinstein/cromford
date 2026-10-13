# lib/ledger.sh — sourced.
LEDGER_ROOT=${LEDGER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
LEDGER_FILE="$LEDGER_ROOT/data/ledger.tsv"

# ledger_record <key> <kind> <amount>: append "<key>\t<kind>\t<amount>" to the
# ledger unless a row with <key> is already there. Same key twice = one row.
ledger_record() {
  local key=$1 kind=$2 amount=$3
  mkdir -p "$(dirname "$LEDGER_FILE")"
  touch "$LEDGER_FILE"
  if awk -F'\t' -v k="$key" '$1 == k { found = 1 } END { exit !found }' "$LEDGER_FILE"; then
    return 0
  fi
  printf '%s\t%s\t%s\n' "$key" "$kind" "$amount" >> "$LEDGER_FILE"
}
