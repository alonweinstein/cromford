# Acme payments

## Ledger rule

Every money movement is written with `ledger_record` from `lib/ledger.sh`. Never
append to `data/ledger.tsv` directly. `ledger_record` writes a row only once per
key, so a command that is re-run after a timeout can never charge or refund twice.

`bin/charge.sh` is the reference.
