# Ratchets by per-file marker (BH-1177)

**What it is:** the two guards that hold a line across the whole repo —
`tests/gh-app-ratchet-test.sh` (which scripts in `bin/` may call `gh` on the
fleet PAT) and `tests/rb-modules-source-test.sh` (which suites may read
`bin/run-build.sh` as raw text) — stopped holding it in SHARED state. Each file
now declares its own status in its own header, and the "this set only ever
shrinks" half is a directory with one file per entry.

Before: an allow-list whose length was asserted to be exactly six, four baseline
part files, and one pinned list of three absolute suite paths. Every PR that
converted a script, allow-listed one, or added a raw reader re-typed a line that
belonged to no ticket. Those two suites and that allow-list were touched by 13 of
the last 200 merges and sat in six of one day's conflicts, none of them about the
feature being built.

**How a user reaches it:** there is no screen and no cron line. Both suites run
in the `tests/ suite` job of `.github/workflows/harness-ci.yml` on every PR, and
in the local `for t in tests/*.sh` loop.

**Key routes/screens:**
- `# gh-identity: app-token` | `raw-pat (BH-<n>) — <why>` | `raw-by-design — <why>`
  — one line under the shebang of every script in `bin/` that calls `gh` raw
- `tests/gh-app-ratchet-baseline/<path under bin/>.txt` — one file per script
  still on the PAT, holding the slice note; `README` in that directory is the
  conversion recipe and is not an entry (an entry is a `.txt`)
- `tests/gh-app-ratchet-by-design/<path under bin/>.txt` — its twin, one file
  per script that is exempt forever. This is the reviewed artifact the old
  `ALLOW_COUNT -eq 6` pin stood for: a permanent exception is a decision
  somebody made, not a sentence a script writes about itself. A script is in
  exactly one of the two directories and the suite fails either way round
- `# reads-run-build: raw — <why>` in a suite's header, plus
  `tests/rb-raw-readers-baseline/<suite>.txt` — the same shape for the three
  suites that EXECUTE the build driver instead of reading the flatten
- `tests/ratchet-markers-test.sh` — the proof: two branches converting two
  different scripts merge clean and both ratchets stay green on the merge

**Selectors:** none (no UI). The markers are read from the HEADER BLOCK only —
shebang, blank lines and comments before the first line of code — so
`head -3 bin/<script>.sh` answers "what identity does this run on".

**Preconditions / seed needs:** none. No network, no clock, no LLM; `git` for
the merge block of `tests/ratchet-markers-test.sh` (it skips that block and says
so when git is missing), `jq` for block 7 of the gh ratchet, as before.

**Verify it works:**
`HARNESS_TEST_SANDBOX=1 bash tests/ratchet-markers-test.sh` builds a fixture repo
out of the real `bin/` and the two registries, converts one script on each of two
branches (the registry's own first two entries, so they are ADJACENT lines of the
sorted list the old shape used), merges them, and asserts: the merge is clean,
BOTH conversions survived it, and both production suites are green on the merged
tree. Block 2 then builds the same two deletions against one sorted list and
asserts they CONFLICT — that measurement is why the registry is a directory, and
it is executable so the next "a list would be simpler" proposal meets it.

Block 3 makes each guard fire in turn, against the tree block 1 proved green: an
unmarked raw `gh` call, a `raw-pat` marker with no registry entry, an entry whose
file converted, an `app-token` marker over a file that arms nothing, a
`raw-by-design` marker with no by-design entry (the self-bless the first cut of
BH-1177 allowed), a by-design entry for a file that arms, a `raw-pat` marker
whose ticket has shipped, a NEW raw reader of the driver, and a reader marker
with no entry. Every case runs the production suite unmodified and asserts both
that it goes red and that the failure names the file.

The owner check is the only part that touches the network, so it is advisory and
fails open — no `gh`, no origin remote, a timeout or an empty answer are all a
printed skip. That makes it a guard nobody would ever watch fire, so the suite
supplies both halves itself: a stub `gh` and a tree with a remote, and it pins
all three answers — `closed` goes red naming the ticket, `open` stays green, and
a `gh` that cannot answer prints the skip and stays green.

`HARNESS_TEST_SANDBOX=1 bash tests/gh-app-ratchet-test.sh` prints
`N raw files still in the registry, M raw-by-design`;
`GH_APP_RATCHET_STRICT=1` ignores the registry and the `raw-pat` markers and goes
red on every script still to convert.

**Manual-only / not automatable:** nothing. There is no live-box artifact — the
whole mechanism is text in the repo, and CI is the only place it runs.
