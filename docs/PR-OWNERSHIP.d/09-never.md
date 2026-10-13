## 9. What it never does

Merge. Push. Approve. Close an EXTERNAL PR that is not superseded (§10) or
not aged out by the age ladder (§10, #3935; it ages only a PR with a conductor
row). Write to `state/merge-conductor/`, except through the conductor's own
writers: `mc_transition` / `mc_rebase`, which the age ladder and the enroll hook call (enroll under the conductor's
per-PR lock), and one
row for a PR the superseded hook just closed, `mc_transition <slug>#<n> CLOSED
superseded:<by>`, when the conductor already has a row for it.
It is a release-management sweep, not a merger — the
iron guardrail stands (CLAUDE.md §1: merging happens only through the gated
tier-1 step, the hub's merge sweep, or a command from the console).

