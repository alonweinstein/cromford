# Every open PR has an owner state

**The rule, in one line:** an open pull request on a repo this fleet works is
either **OWNED**, **EXTERNAL**, **PARKED with an expiry**, or **CLOSED**. There
is no fifth option, and "it has just been sitting there since June" is not one
of the four.

Enforced by `bin/pr-owner-sweep.sh`. Tested by `tests/pr-owner-sweep-test.sh`;
the hook seams of §10 by `tests/pr-health-lib.bh-3929-test.sh`; the superseded close
by `tests/pr-superseded.bh-3929-test.sh`, the health rollup by
`tests/daily-digest-pr-health.bh-3929-test.sh`, and enroll, the ownerless clock
and the keyed conductor run by `tests/pr-owner-enroll.bh-3929-test.sh`.

---

