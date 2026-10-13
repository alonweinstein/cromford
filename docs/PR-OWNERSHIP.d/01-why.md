## 1. Why this exists

On 2026-09-15, with the fleet running four businesses:

| PR | opened | state |
|---|---|---|
| `example-org/project-7` #323, #324, #325, #326, #327 | June 2026 | open, harness-authored |
| `example-org/project-7` #359 | August 2026 | open, harness-authored |
| `example-org/project-1` #630 | — | open, head **DIRTY** since 2026-08-30 |

Not one of them had a ledger row, a merge-conductor state, a park or a close.
Nobody rebased them, nobody closed them, nobody reported them. No log line in
this harness had ever named them.

`bin/orphan-reconcile.sh` (#356) closed the matching hole on the TICKET side —
"is every open `ai-build` issue actually being worked" — and it is the reason
this hole was load-bearing rather than merely untidy. The reconciler's owner
rule says **an open PR owns its ticket** (owner class (b)): whatever state that
PR is in, red CI or clean green, it is the conductor's job and not a reason to
build the ticket twice. That is exactly right while the conductor is working the
PR. It is exactly wrong the moment the PR has been abandoned — then the
abandoned PR is not merely unhandled, it is actively holding its ticket hostage,
and the ticket looks owned to every lane that asks.

So the two scripts are halves of one rule:

```
orphan-reconcile.sh   every open TICKET has exactly one owner
pr-owner-sweep.sh     every open PR     has exactly one owner state
```

They share their doctrine deliberately: compute the answer from scratch every
tick, trust no event, fail closed when the inputs cannot be read, and give the
event path a grace window so the backstop never races the lane it backs up.

