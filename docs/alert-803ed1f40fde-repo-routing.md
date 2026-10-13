# Resolver discovery for repository aliases

The conductor identifies PRs as `owner/repository#number`. Resolver discovery
must map that repository through column 2 of `fleet.conf`; searching for a
fleet project name inside the key loses repositories whose names differ.

The incident probe was `project-of.sh example-org/project-2#531`: it returned
no project even though `fleet-conf.sh project-2 repo` returned
`example-org/project-2`. PR #531 remained open and conflicted, and discovery
never produced a resolver attempt for TK-274.

`project-of.sh --repo owner/repository` now performs an exact, case-insensitive
registry lookup. `br_conductor_emit` removes the PR-number suffix and uses that
mode. Prefix and free-text routing retain their existing behavior. Unknown
owners and repository suffixes do not inherit a known project's identity.

CodeGraph was queried before planning. Its current index returned no relevant
shell symbols; the source call path was checked directly:
`br_from_conductor` → `br_conductor_emit` → `project-of.sh` → `fleet-conf.sh`.
The changed production files are the resolver caller and the lookup helper.
Regression risks are missing or misrouting conductor candidates and changing
existing text/prefix routing. The project-of suite covers both, including the
actual discovery function with a registry alias and stubbed external readers.

Verification (docker, `cromford-tests:trixie`, on a `git archive` export —
the earlier 31 reported failures were BSD-tool artifacts of running the suite
natively on macOS, not real reds): `tests/project-of-test.sh` 63/0 on this
patch against 55/0 on main, and `tests/blocked-resolver-test.sh` 309/0 on both.
The conductor-emit neighbours are green on both sides too: `bh-1122` 100/0,
`bh-948` 54/0, `bh-488` 73/0, `conductor-sticky-handoff` 108/0 and
`rebuild-ledger.bh-946` 66/0. Shell syntax, shellcheck at error severity,
`bin/checks-run.sh --tree .`, `bin/verification-map-build.sh --check` and
`bin/test-determinism-lint.sh` all pass. The patched helper also resolved the
incident's registered slug to `project-2` directly.

`br_conductor_emit` gained a 4th `parked` argument on main (BH-1122) while this
change was open; the rebase keeps both, and the discovery regression asserts the
8-field tuple and stubs `br_pr_field`, which is the head-branch read main now
uses in place of `gh pr view`.

This change does not itself resolve branch
conflicts, approve a head, merge, or deploy a PR.
