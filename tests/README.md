# Running the tests without wrecking a harness

Every file in here is a bash script that prints its own pass and fail counts and
exits 0 when it is clean. There is no framework and no runner config. CI runs
them with `for t in tests/*.sh; do bash "$t"; done`.

That simplicity is also the hazard this file exists for. On 2026-09-15 a test
re-derived `$H` as the LIVE harness root and its EXIT trap removed it (#388,
root cause #404). The suite runs as root on machines that hold a real
`/root/harness`, so "just run the tests" is not a safe instruction and this page
is the safe one.

## How to run them

**The container, and this is the default.** It is what CONTRIBUTING.md tells you
to run before you push, and it is the only place the suite is known-good:

```sh
bin/run-tests-in-docker.sh                  # whole suite, names of failures
bin/run-tests-in-docker.sh tests/foo.sh     # one suite, full output
```

The repo is mounted read only and copied inside the container, so your checkout
is never modified. The container has no `/root/harness` to lose.

**On a box that has a live harness** (the hub, a watcher), run the suite in a
private mount namespace with a tmpfs over `/root`. The guard below then has
nothing to guard, because there really is no live install in that namespace:

```sh
sbx() { unshare -Urm bash -c 'mount -t tmpfs tmpfs /root && cd "$1" && shift && exec "$@"' _ "$(pwd -P)" "$@"; }
sbx bash tests/scratch-lib-test.sh
sbx bash -c 'for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done'
```

**On a machine with no `/root/harness` at all** (a laptop, a CI runner), the bare
loop is fine:

```sh
for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done
```

On macOS about 28 suites fail on `mapfile`, bash 3.2 syntax and GNU coreutils
flags. Those are the platform, not your change. Use the container.

## The root guard

`tests/lib/scratch.sh` refuses to load when it is running as root next to a
directory that looks like a live harness. It `exit`s rather than `return`s,
because almost no test in here runs under `errexit` and a `return` would let the
test carry on with `T` unset, which is how `rm -rf "$T/x"` becomes `rm -rf /x`.

`HARNESS_TEST_SANDBOX=1` overrides that guard, and it is set in exactly two
places:

- the `docker run` in `bin/run-tests-in-docker.sh`;
- the `tests/ suite` step of the `decisions` job in
  `.github/workflows/harness-ci.yml`.

Both are throwaway machines with nothing to lose. **Nothing in `bin/` on a real
box may set it**, and neither should you at a prompt on the hub: use the
namespace recipe above, which makes the guard's precondition false instead of
switching the guard off. `bin/test-trace-safety.sh` reads the same flag for the
same reason, and refuses without it.

`HARNESS_ROOT_OVERRIDE` points the guard at another path, which is how the
guard's own tests drive it.

## Writing a test

- **Source the scratch library first**, before your first `mktemp`, `trap`, `rm`
  or `cd`:

  ```sh
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
  ```

  It hands you `T` (also `SCRATCH`), a writable tree under `$TMPDIR`, removes it
  on exit, and unsets `HARNESS`, `H` and `HARNESS_CHECKOUT` so a stray reference
  cannot resolve to the real install. Do not roll your own
  `T=$(mktemp -d); trap 'rm -rf "$T"' EXIT` — that is the shape the static check
  flags.

- **Every recursive delete goes through `scratch_rm`**, which refuses a path
  outside the tree it handed you. `scratch_cleanup` does the same for the tree
  itself.

- **Copy a lane's libs with `scratch_install_closure <script> <dest>`**, never a
  hand list of `bin/lib` files. The `scratch-closure` lint is red on a new or
  edited hand list. `bin/closure-sweep.sh` converts old suites.

- **Drive the real script, not a paraphrase.** Copy the production script into a
  scratch `$HARNESS`, or extract the block verbatim by its
  `# >>> name` / `# <<< name` markers, and assert on the artifacts it wrote.
  Grepping a script for a string proves only that somebody typed it.

- **A `bin/` script must not `export HARNESS`.** Exporting it hands a live
  harness root to every child the lane starts, which is #388 one layer up. Keep
  `H="${HARNESS:-/root/harness}"` as a plain assignment and pass `HARNESS="$H"`
  on the command line of the children that need it.
  `tests/no-harness-export-test.sh` pins this for
  `bin/blocked-resolver.sh` and `bin/fleet-propagate.sh`.

- **A sourced lib resolves its own root, so rewrite its default too.**
  `bin/lib/merge-conductor-lib.sh` (`MC_H`) and `bin/jobs-client.sh`
  (`JOBS_HARNESS`) each read `${HARNESS:-/root/harness}` themselves instead of
  taking the lane's `$H`. In production that is fine — they only differ from the
  lane when `HARNESS` is in the environment, and then the child inherited it
  anyway. In a test it bites: copy a lane into a scratch root, unset `HARNESS`,
  and the lib you copied beside it still falls back to the real
  `/root/harness` and builds its state tree there. Rewrite the default in every
  copied file, assert the rewrite matched, and assert the directory the lib
  creates landed under your scratch root.

- **Stub anything that leaves the machine.** `ssh`, `curl`, `gh` and `flyctl` are
  fixture scripts on `PATH`. A test that reaches a box is a test that has already
  failed.

- **Mark a credential-shaped fixture inside its value.** Most of this repo ships
  to a public mirror, and the publisher's gates (`bin/share/leakcheck.py`, then
  gitleaks through `bin/share/gitleaks-gate.py`) refuse anything that looks like
  a key. They excuse a value that carries `fixture`, `do-not-ship` or `example`
  INSIDE it, like `hs-fixture-bh4917` (`FIXTURE_MARKERS` in
  `bin/share/mapping.py`). A marker in the variable name buys nothing. If the
  value can't carry one, build it at run time with `printf` so the literal never
  sits in the tree. `tests/share-publish-clean.bh-795-test.sh` runs those gates
  over the committed tree, so a missed one goes red there, not on the next
  publish.

- **Read the shared mirror build; do not sanitize the whole tree again.**
  `tests/lib/share-mirror.sh` builds the public mirror the way
  `bin/publish-share.sh` does, once per tree, and caches it in
  `$SHARE_MIRROR_CACHE` (default `$TMPDIR/bh-share-mirror`). The key is the
  committed tree, `bin/share/` as on disk, the library and the python3 on
  PATH. Source it after `scratch.sh`, call `share_mirror_get "$DIR"`, and read
  `$SM_MIRROR` and `$SM_SRC`. The cached tree is read-only: write into a
  `share_mirror_copy` copy. Every call logs `built`, `reused`, `failed` or
  `private (<reason>)` to stderr and to `share-mirror.log` in the cache. A failed
  sanitize is never cached. `SHARE_MIRROR_LOCK_WAIT_S` (default 600) bounds the
  wait for another suite's build. `SHARE_MIRROR_CACHE_KEEP` (default 2) is the
  number of builds that prune keeps (BH-5543).

- **Read the clock once.** One `NOW=$(date +%s)` and derive every fixture age
  from it.

## The two safety lanes

They are detection only. Neither writes to a box, and both are wired into the CI
job `Tests cannot touch a real harness`.

```sh
bin/checks-run.sh --tree .        # static: what the text of a test could delete
bin/test-trace-safety.sh .        # dynamic: what a test really deleted
```

**Static** (`checks/tests-scratch-only/check.sh`, run through
`bin/checks-run.sh --tree`) prints one line per hit:

```
CHECK-HIT tests-scratch-only tests/foo-test.sh:22 R1: does not source tests/lib/scratch.sh ...
CHECKS: clean (1 tree check(s), root .)
```

R1 is a test that made a temp tree before sourcing the library, R2 is a
recursive `rm` on a variable the library never handed out, R3 is a `bin/` script
deleting a `$HARNESS`-derived path with no prefix guard.

**Dynamic** (`bin/test-trace-safety.sh`) runs every suite with the harness
variables unset, traces the test and every child bash, and reports deletions and
redirects that land outside the allowed temp roots:

```
HIT   <test> <verb> <resolved target> (<src>:<line>, cwd <pwd>)
EXIT  <rc> <test>
TRACE: <n> tests, <m> nonzero exit(s), 0 hit(s)
```

Its verdict is hits. A test that exits nonzero is named and counted, and is the
`decisions` job's business, not this lane's.

Per-test timeout is `TRACE_SAFETY_TEST_TIMEOUT`, 600 s by default; CI passes
`TRACE_SAFETY_TEST_TIMEOUT=300` so a few hung suites cannot eat the job's budget
before the `TRACE:` line is reached. A timed-out suite prints `TIMEOUT <name>`
and is not a hit.

For both: **rc 0 is clean, rc 1 is hits, rc 2 is could-not-run** — a missing
root, no tests, a dead `awk`, an empty trace, or root next to a live harness. rc
2 prints `CHECK-ERROR` and no verdict line, so a scan that did not happen fails
the job instead of reading green.

Details and known gaps are in
[docs/verification-map/tests-scratch-only.md](../docs/verification-map/tests-scratch-only.md)
and [docs/verification-map/trace-safety.md](../docs/verification-map/trace-safety.md).

## Determinism lint

```sh
bin/test-determinism-lint.sh                 # the whole suite
bin/test-determinism-lint.sh tests/foo.sh    # one file
```

A test that reads the wall clock twice, or rolls dice, picks its own red day: in
September 2026 one of them went red on main overnight and four open PRs
inherited a failure none of them caused. The rules and the waiver syntax
(`# determinism: ok <why>`) are in [docs/TEST-DETERMINISM.md](../docs/TEST-DETERMINISM.md).
It runs as its own CI job, so a PR that adds one fails there and nowhere else.
