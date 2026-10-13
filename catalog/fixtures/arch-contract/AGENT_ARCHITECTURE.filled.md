# Agent architecture — demo-os (FIXTURE)

A FILLED-IN contract, in the shape `docs/AGENT-ARCHITECTURE-TEMPLATE.md`
produces once a repo's audit has answered its questions. It exists so
tests/arch-contract-test.sh can prove the real delivery path: an audit's output
lands at the repo root and bin/verification-map.sh carries its sections into the
primer a PLAN stage reads. Placeholders are gone here on purpose — a fixture
still full of `<PLACEHOLDER>` would prove only that the template copies.

## The five rules

### Rule 1 — The conventional path is cheaper than the shortcut

A new billing rule is added by dropping a file in `src/lib/billing/rules/` and
listing it in `rules/index.ts`. That is fewer edits than threading a condition
through the invoice builder, and it stays that way.

### Rule 2 — Forbidden dependencies fail mechanically

`src/lib/**` must never import from `src/app/**`. No cycles anywhere under
`src/lib/`.

### Rule 3 — One obvious writer per durable value

| durable value | its one writer |
|---|---|
| the invoice ledger | `src/lib/billing/ledger.ts` |
| the client-intake status column | `src/lib/intake/transition.ts` |

### Rule 4 — New product work is isolated files, not branches in shared roots

`src/lib/billing/invoice-builder.ts` does not grow another `if`. A new invoice
variant is a rule file, registered in `rules/index.ts`.

### Rule 5 — Exceptions are narrow, explicit, and reviewed as architecture changes

Breaking a rule costs a scoped exception in the PR, reviewed as a change to this
contract. Where a rule is backed by a check, the hatch is the standard one: the
`skip-guardrail` label plus a written `Guardrail-Justification:` line.

## Named nouns in demo-os

| concept | what it is called here | where it lives |
|---|---|---|
| the unit of product work | a Rule | `src/lib/billing/rules/` |
| the entry point(s) into the system | a Route | `src/app/` |
| the layer anything may import | Lib | `src/lib/` |
| the registry a new unit is announced in | the rule index | `src/lib/billing/rules/index.ts` |

## Mechanical backing

| rule | enforced by | where |
|---|---|---|
| Rule 1 — conventional path is cheaper | PROSE-ONLY (debt) | — |
| Rule 2 — forbidden dependencies | eslint `no-restricted-imports` + `madge --circular` | `.github/workflows/ci.yml` |
| Rule 3 — one obvious writer | PROSE-ONLY (debt) | — |
| Rule 4 — isolated files, not branches | PROSE-ONLY (debt) | — |
| Rule 5 — narrow explicit exceptions | `guardrails/lib/escape-hatch.sh` | every guardrail step |
