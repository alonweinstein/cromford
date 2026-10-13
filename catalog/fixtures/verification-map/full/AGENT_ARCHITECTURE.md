# Agent architecture — demo-os (FIXTURE)

## Durable values and their one writer

The invoice ledger is written only by `src/lib/billing/ledger.ts`.

## Import directions that must fail mechanically

`src/lib/**` may not import from `src/app/**`.
