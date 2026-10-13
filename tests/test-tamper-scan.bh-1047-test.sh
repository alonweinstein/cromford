#!/bin/bash
# tests/test-tamper-scan.bh-1047-test.sh — BH-1047: a stub flip is not a deletion.
#
# Contract-first decompositions ship a `.0` child whose test bodies are named
# stubs, and a `.N` filler that flips them into real cases somewhere else. The
# scanner counted the flip as lost coverage, so every filler ended
# REVIEW_BLOCKED test-tamper and sat for a day or two waiting for a person
# (TK-1828, 1872, 1896, 1908, 1909 — five, all adjudicated legitimate by hand).
#
# What is pinned here: a stub case is only exempt when the same diff ADDS a case
# in a test file importing the same module, the pairing is named in the report,
# and everything that is not a marked stub with a replacement still blocks
# exactly as it did before. The negatives matter more than the positives — an
# exemption a builder can manufacture from the diff side is worse than the
# block it replaces.
#
# Real throwaway git repos, like tests/test-tamper-scan-test.sh next door: the
# whole script is a diff reader, so canned diff text would test the mock.
# Run from anywhere: tests/test-tamper-scan.bh-1047-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$DIR/bin/test-tamper-scan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BD=""   # BUILD_DIR for the scan, when the case wants lineage
# repo <name> — a throwaway repo on `main`, cwd moved into it
repo() {
  R="$T/$1"; mkdir -p "$R/tests" "$R/src"; cd "$R" || exit 1
  git init -q .; git symbolic-ref HEAD refs/heads/main
  git config user.email t@t; git config user.name t
  BD=""
}
commit() { git add -A; git commit -qm "$1"; }
# Capture, then match: `scan | grep -q` makes grep exit on the first match, the
# script takes SIGPIPE and pipefail reports 141 — every assertion would fail
# while the scanner behaved perfectly.
scan() { BUILD_DIR="$BD" "$SCAN" "$BASE" "$R" 2>/dev/null || true; }
rc()   { BUILD_DIR="$BD" "$SCAN" "$BASE" "$R" >/dev/null 2>&1; echo $?; }
has()  { grep -q "$1" <<<"$(scan)"; }

# The contract-first shape these five PRs all had: a `.0` child writes the
# stubs, the `.N` child implements them in a sibling file.
STUBFILE='import { cancel } from "../src/chan"
describe("community channel contract stubs (TK-1531.1 implements the bodies)", () => {
  it("is a stub that cancels nothing yet", () => { expect(cancel()).toBe(undefined) })
  it("is a stub that lists nothing yet", () => { expect(list()).toBe(undefined) })
})'
GUTTED='import { cancel } from "../src/chan"
describe("chan", () => {})'
IMPLFILE='import { cancel } from "../src/chan"
describe("cancel", () => {
  it("cancels the run", () => { expect(cancel(1)).toBe(true) })
  it("ignores unknown ids", () => { expect(cancel(9)).toBe(false) })
})'

# ============================================================================
# 1. THE REPRO. A stub describe deleted, the real cases added in a file that
#    imports the same module: no coverage was lost and nothing should block.
# ============================================================================
repo paired
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
printf '%s\n' "$IMPLFILE" > tests/chan.impl.test.ts
commit "TK-1531.1: implement cancel"
[ "$(rc)" = 0 ] && ok || bad "a paired stub flip must not block (rc=$(rc)): $(scan)"
has 'deleted_cases=0' && ok || bad "a paired stub flip is not a deleted case: $(scan | head -1)"
has 'stub_flips=2' && ok || bad "both flipped stub cases must be counted: $(scan | head -1)"
# The exchange rate is on the report: N flips paid for by M added cases, so the
# reviewer reads the ratio rather than the word "paired".
has '^STUB_FLIPS: 2 (paid for by 3 added case opener' && ok \
  || bad "the STUB_FLIPS line must state how many added cases paid for the flips: $(scan)"
[ "$(scan | grep -c '^stub-flip: .*-> tests/chan.impl.test.ts$')" = 2 ] && ok \
  || bad "each flipped case must name its replacement file: $(scan)"
has 'is a stub that cancels nothing yet' && ok \
  || bad "the pairing line must name the case that was flipped: $(scan)"
has 'VERDICT: no test DELETIONS' && ok || bad "the verdict must say no deletions: $(scan)"
grep -q 'DELETED_CASES:' <<<"$(scan)" && bad "nothing was deleted, so no DELETED_CASES block: $(scan)" || ok

# ============================================================================
# 2. The same deletion with NO replacement anywhere: still a deletion.
# ============================================================================
repo unpaired
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
commit "TK-1531.1: drop the stubs and implement nothing"
[ "$(rc)" = 1 ] && ok || bad "a stub deleted with no replacement must block (rc=$(rc)): $(scan)"
has 'stub-flip-unpaired: tests/chan.test.ts' && ok || bad "the unpaired flip must be named: $(scan)"
has 'deleted_cases=2' && ok || bad "an unpaired stub counts exactly as before: $(scan | head -1)"
has '  tests/chan.test.ts: .*is a stub that cancels nothing yet' && ok \
  || bad "DELETED_CASES must name the first lost case: $(scan)"
has '  tests/chan.test.ts: .*is a stub that lists nothing yet' && ok \
  || bad "DELETED_CASES must name the second lost case: $(scan)"

# ============================================================================
# 3. A "replacement" that imports a DIFFERENT module does not pay for the stub.
# ============================================================================
repo othermodule
echo "export const cancel = () => {}" > src/chan.ts
echo "export const other = () => {}" > src/other.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
printf 'import { other } from "../src/other"\ndescribe("other", () => {\n  it("does other things", () => { expect(other()).toBe(1) })\n})\n' > tests/other.impl.test.ts
commit "TK-1531.1: unrelated suite"
[ "$(rc)" = 1 ] && ok || bad "a replacement in an unrelated module must not pair (rc=$(rc)): $(scan)"
has 'stub-flip-unpaired' && ok || bad "the unpaired reason must be reported: $(scan)"

# ============================================================================
# 4. The marker lives in the comment ABOVE the case, not in the case name.
# ============================================================================
repo comment
echo "export const resolve = () => {}" > src/defaults.ts
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  // TK-1650.1 replaces this one and must flip this case then
  it("resolves the defaults and IGNORES operator parameters", () => { expect(resolve()).toBe(null) })
  it("keeps the real one", () => { expect(resolve(1)).toBe(1) })
})
EOF
commit "TK-1650.0: contract"; BASE=$(git rev-parse HEAD)
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  it("keeps the real one", () => { expect(resolve(1)).toBe(1) })
})
EOF
cat > tests/defaults.impl.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults, for real", () => {
  it("resolves the defaults and honours operator parameters", () => { expect(resolve(2)).toBe(2) })
})
EOF
commit "TK-1650.1: implement the defaults"
[ "$(rc)" = 0 ] && ok || bad "a marker in the adjacent comment must exempt the case (rc=$(rc)): $(scan)"
has 'stub_flips=1' && ok || bad "the comment-marked flip must be counted: $(scan | head -1)"

# ...and the marker stops at the case it was written about. A contract-first
# file has stubs and real cases side by side, so "any of the three preceding
# lines" would hand the exemption to whatever is written under a stub — the
# money test below would ride out of the gate on the stub above it.
repo neighbour
echo "export const pay = () => {}" > src/pay.ts
cat > tests/pay.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments", () => {
  // TK-1650.1 must flip this one
  it("is a stub that pays nobody yet", () => { expect(pay()).toBe(undefined) })
  it("refuses to move money twice for the same idempotency key", () => { expect(pay("k")).toBe(pay("k")) })
})
EOF
commit "TK-1650.0: contract"; BASE=$(git rev-parse HEAD)
cat > tests/pay.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments", () => {})
EOF
cat > tests/pay.impl.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments, implemented", () => {
  it("pays once", () => { expect(pay(1)).toBe(1) })
})
EOF
commit "TK-1650.1: implement pay"
[ "$(rc)" = 1 ] && ok \
  || bad "a real case under a stub must not inherit the stub's marker (rc=$(rc)): $(scan)"
has '  tests/pay.test.ts: .*refuses to move money twice' && ok \
  || bad "the real case must be named under DELETED_CASES: $(scan)"
has 'stub_flips=1' && ok || bad "the stub above it is still a flip: $(scan | head -1)"
grep -q 'stub-flip: .*refuses to move money' <<<"$(scan)" \
  && bad "the money case must not be reported as a flip: $(scan)" || ok

# ...and the window holds COMMENTS ONLY, immediately above. A `// placeholder`
# comment about the fixtures at the top of a suite must not reach a money case
# further down: a `const`, a `beforeEach`, any non-blank line that is neither a
# comment nor an opener ENDS the adjacency, which is the rule the feature doc,
# the note and the awk comment all state ("the three comment lines IMMEDIATELY
# above it"). Without it the distance is unbounded whenever the builder removes
# the intermediate lines in the same hunk (review round 2, 2026-09-20).
repo farcomment
echo "export const pay = () => {}" > src/pay.ts
cat > tests/money.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("money", () => {
  // placeholder fixtures until the seed lands
  const fx = seed()
  it("refuses to move money twice for the same idempotency key", () => { expect(pay("k")).toBe(pay("k")) })
  it("keeps the real one", () => { expect(pay(1)).toBe(1) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/money.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("money", () => {
  it("keeps the real one", () => { expect(pay(1)).toBe(1) })
})
EOF
cat > tests/money2.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("money, again", () => {
  it("pays once", () => { expect(pay(1)).toBe(1) })
})
EOF
commit "gut the money case that sits under a fixtures comment"
grep -q '^-  const fx' <<<"$(git diff "$BASE"...HEAD -- tests/money.test.ts)" && ok \
  || bad "fixture is not exercising the guard: the code line must be REMOVED between the marker and the case"
[ "$(rc)" = 1 ] && ok \
  || bad "a marker comment with a code line under it must not reach the case below (rc=$(rc)): $(scan)"
has '  tests/money.test.ts: .*refuses to move money twice' && ok \
  || bad "the money case must be named under DELETED_CASES: $(scan)"
grep -q 'stub-flip: .*refuses to move money' <<<"$(scan)" \
  && bad "a comment two lines up must not turn the money case into a flip: $(scan)" || ok

# ...and a marker on an ADDED line marks nothing. A builder must not be able to
# write the exemption into the diff side of the same hunk. Both fixtures below
# put the ADDED marker ABOVE the removed opener in the diff text, which is the
# only arrangement where a window or a scope stack that read `+` lines would
# actually exempt something.
repo addedcomment
echo "export const resolve = () => {}" > src/defaults.ts
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  it("resolves the defaults and honours operator parameters", () => { expect(resolve(2)).toBe(2) })
  it("keeps the real one", () => { expect(resolve(1)).toBe(1) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  // that was only ever a stub and must flip
  it("resolves the defaults and honours operator parameters", () => { expect(resolve(2)).toBe(2) })
})
EOF
cat > tests/defaults.impl.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults again", () => {
  it("resolves nothing in particular", () => { expect(resolve(2)).toBe(2) })
})
EOF
commit "claim it was a stub"
git diff "$BASE"...HEAD -- tests/defaults.test.ts | grep -B2 '^-  it' | grep -q '^+.*must flip' && ok \
  || bad "fixture is not exercising the guard: the added marker must sit ABOVE the removed opener"
[ "$(rc)" = 1 ] && ok || bad "a marker in an ADDED comment must not exempt anything (rc=$(rc)): $(scan)"

# The same, through the enclosing describe: an ADDED describe never pushes onto
# the scope stack, so it cannot mark the cases the diff removed under it.
repo addeddescribe
echo "export const resolve = () => {}" > src/defaults.ts
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("plain", () => {
  it("resolves one", () => { expect(resolve(1)).toBe(1) })
  it("resolves two", () => { expect(resolve(2)).toBe(2) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("plain stubs, must flip", () => {
  it("resolves one", () => { expect(resolve(1)).toBe(1) })
})
EOF
cat > tests/defaults.impl.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults again", () => {
  it("resolves nothing in particular", () => { expect(resolve(3)).toBe(3) })
})
EOF
commit "rename the describe into a stub"
[ "$(rc)" = 1 ] && ok || bad "an ADDED describe must not mark the cases removed under it (rc=$(rc)): $(scan)"

# ...and a marker comment at COLUMN ZERO is read like any other. A removed `--`
# comment reaches the awk pass as `--- …` — the same three characters a unified
# diff opens its old-file header with — so an unanchored header skip dropped it
# and the Lua/SQL stub it marked came out a real deletion (review round 1).
repo colzerocomment
echo "return { cancel = function() end }" > src/chan.lua
cat > tests/chan_spec.lua <<'EOF'
local chan = require("../src/chan")
describe("chan", function()
-- stub: TK-1650.1 must flip this one
  it("returns nothing yet", function() assert(chan.cancel() == nil) end)
  it("keeps the real one", function() assert(chan.keep() == true) end)
end)
EOF
commit "TK-1650.0: contract"; BASE=$(git rev-parse HEAD)
cat > tests/chan_spec.lua <<'EOF'
local chan = require("../src/chan")
describe("chan", function()
  it("keeps the real one", function() assert(chan.keep() == true) end)
end)
EOF
cat > tests/chan_impl_spec.lua <<'EOF'
local chan = require("../src/chan")
describe("chan, implemented", function()
  it("cancels the run", function() assert(chan.cancel(1) == true) end)
end)
EOF
commit "TK-1650.1: implement cancel"
grep -q '^--- stub: TK-1650.1' <<<"$(git diff "$BASE"...HEAD -- tests/chan_spec.lua)" && ok \
  || bad "fixture is not exercising the guard: the removed marker must reach awk as '--- …'"
[ "$(rc)" = 0 ] && ok \
  || bad "a column-zero comment marker must mark the case under it (rc=$(rc)): $(scan)"
has 'stub_flips=1' && ok || bad "the column-zero-marked flip must be counted: $(scan | head -1)"

# ============================================================================
# 5. Lineage from the build record: CONTRACT_CHILD, sibling keys, and the `.0`
#    child getting no exemption of its own.
# ============================================================================
MKBD() { # MKBD <dir> <title> — a build record with a ticket-meta title
  mkdir -p "$T/builds/$1"; printf '{"title":"%s","labels":[]}\n' "$2" > "$T/builds/$1/ticket-meta.json"
  printf '%s' "$T/builds/$1"
}
repo lineage
echo "export const resolve = () => {}" > src/defaults.ts
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  // TK-1650.2 owns this one from now on
  it("resolves the defaults and honours operator parameters", () => { expect(resolve(2)).toBe(2) })
  it("keeps the real one", () => { expect(resolve(1)).toBe(1) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/defaults.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults", () => {
  it("keeps the real one", () => { expect(resolve(1)).toBe(1) })
})
EOF
cat > tests/defaults.impl.test.ts <<'EOF'
import { resolve } from "../src/defaults"
describe("defaults again", () => {
  it("resolves the defaults from the database", () => { expect(resolve(2)).toBe(2) })
})
EOF
commit "TK-1908: implement"
BD=$(MKBD "project-4-TK-1908-202609190000" "TK-1650.1: implement the resolver")
has '^CONTRACT_CHILD: TK-1650.1' && ok || bad "the record's title must produce the lineage line: $(scan)"
has 'parent TK-1650, key TK-1908' && ok || bad "the lineage line must name parent and key: $(scan)"
[ "$(rc)" = 0 ] && ok || bad "a sibling key in the comment must mark the case (rc=$(rc)): $(scan)"
# The .0 contract child WRITES stubs, it does not flip them: no exemption.
BD=$(MKBD "project-4-TK-1908-202609190001" "TK-1650.0: the contract")
grep -q '^CONTRACT_CHILD:' <<<"$(scan)" && bad "the .0 child is not a contract CHILD: $(scan)" || ok
[ "$(rc)" = 1 ] && ok || bad "the .0 child gets no stub exemption (rc=$(rc)): $(scan)"
# No record at all: no lineage, and the generic markers still have to work.
BD=""
[ "$(rc)" = 1 ] && ok || bad "with no build record the sibling-key marker cannot apply (rc=$(rc)): $(scan)"

# ============================================================================
# 6. Marker (b): the file was CREATED by the `.0` CONTRACT CHILD this build
#    stacks on. No stub word anywhere — the provenance is the marker.
#
#    "Stacked" on its own proves nothing and must never be the marker:
#    bin/run-build.sh stacks a child on ANY blocked-by parent's branch and
#    bin/run-decompose.sh stacks siblings on each other, and a sibling's branch
#    carries REAL cases. So the ref this build is based on has to be the `.0`
#    record's own branch before a single case on it is read as a stub.
# ============================================================================
repo stacked
echo "export const curate = () => {}" > src/curator.ts
echo "app" > app.js
commit "main"
git checkout -q -b contract
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {
  it("returns nothing yet", () => { expect(curate()).toBe(undefined) })
  it("also returns nothing yet", () => { expect(curate(1)).toBe(undefined) })
})
EOF
commit "TK-1701.0: the curator contract"; BASE=$(git rev-parse HEAD)
git checkout -q -b filler
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {})
EOF
cat > tests/curator.impl.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator, implemented", () => {
  it("curates the list", () => { expect(curate([1])).toEqual([1]) })
  it("refuses an empty list", () => { expect(curate([])).toEqual([]) })
})
EOF
commit "TK-1701.1: implement the curator"
# The `.0` record on this box, naming the branch this build is stacked on.
C0=$(MKBD "project-4-TK-1801-202609180000" "TK-1701.0: the curator contract")
printf 'contract\n' > "$C0/branch"
BD=$(MKBD "project-4-TK-1802-202609190000" "TK-1701.1: implement the curator")
[ "$(rc)" = 0 ] && ok || bad "a case in a file the contract child's branch created must be a flip (rc=$(rc)): $(scan)"
has 'contract-file' && ok || bad "the pairing must say the provenance was the reason: $(scan)"

# ...the SAME stacked diff with no `.N` lineage at all. This is the shape every
# ordinary stacked child has, and it must get nothing: a child stacked on its
# parent's branch could otherwise delete every real case that parent added and
# pay with one `it()` in any file importing the same module.
BD=""
[ "$(rc)" = 1 ] && ok || bad "stacked with no lineage must not exempt anything (rc=$(rc)): $(scan)"
has '  tests/curator.test.ts: .*returns nothing yet' && ok \
  || bad "the cases a stacked build deleted must be named: $(scan)"

# ...and a `.N` child stacked on a branch that is NOT its `.0` contract child's
# (a sibling's branch, the `after:` shape run-decompose.sh files) gets nothing
# either: the lineage is right, the provenance is not.
printf 'ticket/TK-1701-2\n' > "$C0/branch"
BD=$(MKBD "project-4-TK-1802-202609190000" "TK-1701.1: implement the curator")
[ "$(rc)" = 1 ] && ok \
  || bad "stacked on a branch that is not the .0 child's must not exempt (rc=$(rc)): $(scan)"
# ...and with the `.0` record gone entirely, likewise.
printf 'contract\n' > "$C0/branch"; rm -f "$C0/ticket-meta.json"
[ "$(rc)" = 1 ] && ok || bad "with no .0 record the stacked deletion is real again (rc=$(rc)): $(scan)"
scratch_rm "$C0"
BD=""

# ...and a `.0` record that is ITSELF stacked on an unmerged parent lends no
# provenance to that parent's work. bin/run-build.sh stacks a child on ANY
# blocked-by parent's branch, so merge-base(main, the `.0` branch) can sit
# BELOW an unmerged ticket's commits and `--diff-filter=A` over that range
# handed this `.N` child every suite that OTHER ticket created. Provenance is
# "the `.0` record wrote this file", never "it is reachable from the `.0`
# branch" (review round 2, 2026-09-20).
repo stackedparent
echo "export const pay = () => {}" > src/pay.ts
commit "main"
git checkout -q -b blockedparent
cat > tests/pay.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments", () => {
  it("refuses to pay twice for the same idempotency key", () => { expect(pay("k")).toBe(pay("k")) })
  it("rejects a negative amount", () => { expect(pay(-1)).toBe(false) })
})
EOF
commit "TK-902: the real payments suite"
git checkout -q -b contract2
cat > tests/chan.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("chan", () => {
  it("returns nothing yet", () => { expect(pay()).toBe(undefined) })
})
EOF
commit "TK-901.0: the contract"; BASE=$(git rev-parse HEAD)
git checkout -q -b filler2
cat > tests/chan.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("chan", () => {})
EOF
cat > tests/pay.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments", () => {})
EOF
cat > tests/pay2.test.ts <<'EOF'
import { pay } from "../src/pay"
describe("payments, implemented", () => {
  it("pays once", () => { expect(pay(1)).toBe(1) })
})
EOF
commit "TK-906: implement"
C2=$(MKBD "project-4-TK-905-202609180000" "TK-901.0: the contract")
printf 'contract2\n' > "$C2/branch"
BD=$(MKBD "project-4-TK-906-202609190000" "TK-901.1: implement")
[ "$(rc)" = 1 ] && ok \
  || bad "a suite an unmerged parent created is not the .0 child's work (rc=$(rc)): $(scan)"
has '  tests/pay.test.ts: .*refuses to pay twice' && ok \
  || bad "the parent's money case must be named under DELETED_CASES: $(scan)"
grep -q '^stub-flip: tests/pay.test.ts' <<<"$(scan)" \
  && bad "an unmerged parent's suite must never be a contract-file flip: $(scan)" || ok
# ...while the file the `.0` record itself created on that same branch still is.
has '^stub-flip: tests/chan.test.ts' && ok \
  || bad "the .0 child's OWN file must still be a contract file: $(scan)"
scratch_rm "$C2"
BD=""

# ...the same unmarked deletion with the file already on main is a real one.
repo notstacked
echo "export const curate = () => {}" > src/curator.ts
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {
  it("returns nothing yet", () => { expect(curate()).toBe(undefined) })
  it("also returns nothing yet", () => { expect(curate(1)).toBe(undefined) })
})
EOF
commit "main carries the suite"; BASE=$(git rev-parse HEAD)
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {})
EOF
cat > tests/curator.impl.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator, implemented", () => {
  it("curates the list", () => { expect(curate([1])).toEqual([1]) })
})
EOF
commit "delete two, add one"
[ "$(rc)" = 1 ] && ok || bad "with no contract lineage the same deletion must block (rc=$(rc)): $(scan)"

# ============================================================================
# 7. Marker (b), second derivation: a local `.0` build record on this box whose
#    changed-files.txt names a file that record CREATED.
#
#    changed-files.txt is the record's FULL diff list (bin/run-build.sh writes
#    it as `git diff --name-only BASE...HEAD`, no --diff-filter=A), so "the
#    record names it" is NOT "the record wrote it": a contract child that merely
#    appended one stub to a suite main already carried would otherwise hand
#    every `.N` sibling a blanket exemption on every case in it. So a named path
#    only counts when it is ABSENT from the mainline — un-merged work the `.0`
#    child is the only plausible author of. Both halves are pinned below.
# ============================================================================
repo localzero
echo "export const curate = () => {}" > src/curator.ts
# The money suite main already carries. The `.0` child touches it (a stub
# appended, say) and so names it in changed-files.txt — it did not write it.
cat > tests/legacy.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator, on main", () => {
  it("refuses to curate twice for the same idempotency key", () => { expect(curate(1)).toBe(true) })
  it("rejects a negative id", () => { expect(curate(-1)).toBe(false) })
})
EOF
commit "main carries the legacy suite"
git checkout -q -b contract
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {
  it("returns nothing yet", () => { expect(curate()).toBe(undefined) })
  it("also returns nothing yet", () => { expect(curate(1)).toBe(undefined) })
})
EOF
commit "TK-1700.0: the curator contract"; BASE=$(git rev-parse HEAD)
git checkout -q -b filler
cat > tests/curator.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator", () => {})
EOF
cat > tests/curator.impl.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator, implemented", () => {
  it("curates the list", () => { expect(curate([1])).toEqual([1]) })
})
EOF
commit "TK-1911: implement the curator"
# No `branch` file in the record: derivation (i) cannot fire, so what is pinned
# here is derivation (ii) alone.
Z=$(MKBD "project-4-TK-1900-202609180000" "TK-1700.0: the curator contract")
printf '%s\n' tests/curator.test.ts src/curator.ts tests/legacy.test.ts > "$Z/changed-files.txt"
BD=$(MKBD "project-4-TK-1911-202609190000" "TK-1700.1: implement the curator")
[ "$(rc)" = 0 ] && ok || bad "the local .0 record's CREATED file must mark the stub file (rc=$(rc)): $(scan)"
has 'contract-file' && ok || bad "the provenance must be the reason the case was a stub: $(scan)"
# ...and without that record the same build blocks.
mv "$Z/ticket-meta.json" "$Z/ticket-meta.json.off"
[ "$(rc)" = 1 ] && ok || bad "with the .0 record gone the deletion is real again (rc=$(rc)): $(scan)"
mv "$Z/ticket-meta.json.off" "$Z/ticket-meta.json"

# THE NEGATIVE THIS DERIVATION EXISTS TO FAIL (review round 1, 2026-09-20).
# The same record, the same lineage — but the file gutted is the one main
# already carried and the record only TOUCHED. Two real money cases removed
# and one trivial `it()` added in a same-module file must block, and the lost
# cases must be named, exactly as they would with no lineage at all.
cat > tests/legacy.test.ts <<'EOF'
import { curate } from "../src/curator"
describe("curator, on main", () => {})
EOF
cat >> tests/curator.impl.test.ts <<'EOF'
describe("curator, refunds", () => {
  it("refunds", () => { expect(curate("r")).toBe(true) })
})
EOF
commit "TK-1911: gut the suite main carried"
[ "$(rc)" = 1 ] && ok \
  || bad "a file the .0 record only TOUCHED must not be a contract file (rc=$(rc)): $(scan)"
has '  tests/legacy.test.ts: .*refuses to curate twice for the same idempotency key' && ok \
  || bad "the money case gutted from the pre-existing suite must be named: $(scan)"
has '  tests/legacy.test.ts: .*rejects a negative id' && ok \
  || bad "the second gutted money case must be named too: $(scan)"
grep -q '^stub-flip: tests/legacy.test.ts' <<<"$(scan)" \
  && bad "a pre-existing suite must never be reported as a contract-file flip: $(scan)" || ok
BD=""

# ============================================================================
# 8. The adversarial negatives. Each of these must still block.
# ============================================================================
# "stubborn" contains "stub" and is not a marker.
repo stubborn
echo "export const retry = () => {}" > src/retry.ts
cat > tests/retry.test.ts <<'EOF'
import { retry } from "../src/retry"
describe("retry", () => {
  it("handles stubborn retries", () => { expect(retry(5)).toBe(5) })
  it("gives up", () => { expect(retry(0)).toBe(0) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/retry.test.ts <<'EOF'
import { retry } from "../src/retry"
describe("retry", () => {
  it("gives up", () => { expect(retry(0)).toBe(0) })
})
EOF
cat > tests/retry.impl.test.ts <<'EOF'
import { retry } from "../src/retry"
describe("retry, again", () => {
  it("retries twice", () => { expect(retry(2)).toBe(2) })
})
EOF
commit "drop the stubborn case"
[ "$(rc)" = 1 ] && ok || bad "'stubborn' is not 'stub' (rc=$(rc)): $(scan)"
has '  tests/retry.test.ts: .*handles stubborn retries' && ok \
  || bad "a real deletion must be named under DELETED_CASES: $(scan)"

# A test path carrying a sed metacharacter still renders its lost cases.
# `sed "s#^#  $f: #"` died with "unknown option to `s'" on a `#` in the path
# and silently substituted the match on an `&`, so DELETED_CASES came out
# EMPTY on a blocking scan — and bin/blocked-resolver.sh then adjudicates "the
# scanner named no cases; this is a pre-BH-1047 report" and pages a human with
# "(none named)", which is the one thing the naming exists to prevent.
repo hashpath
echo "export const pay = () => {}" > src/pay.ts
mkdir -p 'tests/a#b&c'
cat > 'tests/a#b&c/x.test.ts' <<'EOF'
import { pay } from "../../src/pay"
describe("payments", () => {
  it("refuses to pay twice for the same idempotency key", () => { expect(pay("k")).toBe(pay("k")) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > 'tests/a#b&c/x.test.ts' <<'EOF'
import { pay } from "../../src/pay"
describe("payments", () => {})
EOF
commit "gut the suite under an awkward path"
[ "$(rc)" = 1 ] && ok || bad "a gutted suite under a path with '#' must block (rc=$(rc)): $(scan)"
has '  tests/a#b&c/x.test.ts: .*refuses to pay twice' && ok \
  || bad "DELETED_CASES must name the case whatever the path spells: $(scan)"
[ "$(scan | grep -c 'unknown option to')" = 0 ] && ok \
  || bad "the path must not reach sed as a substitution delimiter: $(scan)"

# "placeholder" in a REAL assertion name is a marker word, so it flips — but
# without a replacement it blocks exactly like any other lost case.
repo placeholder
echo "export const check = () => {}" > src/email.ts
cat > tests/email.test.ts <<'EOF'
import { check } from "../src/email"
describe("email", () => {
  it("rejects placeholder emails", () => { expect(check("a@b")).toBe(false) })
  it("accepts real ones", () => { expect(check("a@b.c")).toBe(true) })
})
EOF
commit base; BASE=$(git rev-parse HEAD)
cat > tests/email.test.ts <<'EOF'
import { check } from "../src/email"
describe("email", () => {
  it("accepts real ones", () => { expect(check("a@b.c")).toBe(true) })
})
EOF
commit "drop the placeholder case"
[ "$(rc)" = 1 ] && ok || bad "a marker word with no replacement still blocks (rc=$(rc)): $(scan)"

# A whole stub FILE deleted is never a flip, however marked it is.
repo delstubfile
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
git rm -q tests/chan.test.ts
mkdir -p tests
printf '%s\n' "$IMPLFILE" > tests/chan.impl.test.ts
commit "TK-1531.1: replace the stub file"
[ "$(rc)" = 1 ] && ok || bad "deleting a whole stub file must still block (rc=$(rc)): $(scan)"
has 'deleted_files=1' && ok || bad "the deleted stub file must be counted: $(scan | head -1)"

# ============================================================================
# 9. Relative specifiers from different directories resolve to one module.
# ============================================================================
repo relpaths
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
mkdir -p tests/sub
cat > tests/sub/chan.impl.test.ts <<'EOF'
import { cancel } from "../../src/chan"
describe("cancel from a subdirectory", () => {
  it("cancels the run", () => { expect(cancel(1)).toBe(true) })
  it("ignores unknown ids", () => { expect(cancel(9)).toBe(false) })
})
EOF
commit "TK-1531.1: implement cancel one directory down"
[ "$(rc)" = 0 ] && ok || bad "../../src/chan and ../src/chan are the same module (rc=$(rc)): $(scan)"
has 'tests/sub/chan.impl.test.ts' && ok || bad "the replacement path must be named: $(scan)"

# ============================================================================
# 10. The counts contract every caller greps stays byte-identical in shape.
#     bin/run-build.sh keys its block on JUSTIFICATION: NONE + ^BLOCKING_COUNT:
#     [1-9]; bin/evidence-summary.sh greps ^BLOCKING_COUNT: [1-9];
#     bin/review-rescue.sh re-reads the same four lines.
# ============================================================================
repo contract
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
printf '%s\n' "$IMPLFILE" > tests/chan.impl.test.ts
commit "TK-1531.1: implement cancel"
[ "$(scan | sed -n 1p | grep -c '^TAMPER_COUNT: [0-9]* (deleted_files=[0-9]* deleted_cases=[0-9]* added_skips=[0-9]* stub_flips=[0-9]*)$')" = 1 ] && ok \
  || bad "line 1 must stay the TAMPER_COUNT line with only stub_flips added: $(scan | sed -n 1p)"
[ "$(scan | sed -n 2p | grep -c '^BLOCKING_COUNT: ')" = 1 ] && ok || bad "line 2 must stay BLOCKING_COUNT: $(scan | sed -n 2p)"
[ "$(scan | sed -n 3p | grep -c '^ASSERTION_DELTA: ')" = 1 ] && ok || bad "line 3 must stay ASSERTION_DELTA: $(scan | sed -n 3p)"
[ "$(scan | sed -n 4p | grep -c '^REWORDED_CASES: ')" = 1 ] && ok || bad "line 4 must stay REWORDED_CASES: $(scan | sed -n 4p)"
has '^BLOCKING_COUNT: 0' && ok || bad "a paired flip must report zero blocking: $(scan | sed -n 2p)"

# ...and on a blocked scan the JUSTIFICATION line run-build.sh keys on is intact.
repo contractblock
echo "export const cancel = () => {}" > src/chan.ts
printf '%s\n' "$STUBFILE" > tests/chan.test.ts
commit "TK-1531.0: contract stubs"; BASE=$(git rev-parse HEAD)
printf '%s\n' "$GUTTED" > tests/chan.test.ts
commit "TK-1531.1: drop them"
has '^JUSTIFICATION: NONE' && ok || bad "the JUSTIFICATION line run-build.sh keys on must survive: $(scan)"
has '^BLOCKING_COUNT: [1-9]' && ok || bad "the blocking count run-build.sh keys on must survive: $(scan)"
# A TEST-CHANGE justification still turns a real block into an adjudication.
git commit -q --allow-empty -m "note

TEST-CHANGE: the stubs are superseded by the contract."
[ "$(rc)" = 2 ] && ok || bad "a justified unpaired flip must still adjudicate, not block (rc=$(rc))"

cd "$DIR" || exit 1
echo "test-tamper-scan.bh-1047-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
