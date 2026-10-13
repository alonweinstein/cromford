# dequeue-classify

A pull request was taken out of the merge queue because CI failed on it. The
rules could not tell why. Below are the failing suites and the FAIL lines from
the CI log. Pick the one class that explains the failure.

## Classes
- rule-break: the PR's own change breaks a lint, ratchet or repo rule the suite enforces.
- scanner-fp: a scanner or lint flagged something that is not really a problem (a false positive).
- semantic-test: the PR's change makes a behavior test fail because the code now does something different.
- textual-conflict: the PR no longer merges or builds cleanly against main (a conflict, a duplicate definition, a missing file another merge moved).
- flake: the failure is timing, network or environment noise, not caused by the PR.
- unclassified: none of the above fits, or the lines are not enough to tell.

## Answer
Answer with exactly one word from this list and nothing else:
rule-break, scanner-fp, semantic-test, textual-conflict, flake, unclassified
