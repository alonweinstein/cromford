# CLAUDE.md — heading contract with subsections (FIXTURE)

The common shape: the contract is a `##` section whose actual commands live in
`###` subsections under it. An extractor that breaks at ANY heading level
amputates the section at its first subsection and silently drops the commands —
under a banner that tells the reader not to re-derive any of this.

## Verification Contract

The contract has parts, and the parts are where the commands are.

### Commands

- `npm run test:deep` — the domain suite that must pass before a PR.
- `npm run build` — always.

### Suites at regression risk

- `npm run test:roles` when auth is touched.

## Key Docs

Nothing below this line belongs to the contract, and the extractor must stop
here — swallowing the rest of CLAUDE.md is the other failure direction.
